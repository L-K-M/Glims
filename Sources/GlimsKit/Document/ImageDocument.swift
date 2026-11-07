import AppKit
import CoreGraphics

/// One open image in the engine, as the interface sees it.
///
/// The document keeps the state the interface shows (size, layers, undo)
/// and routes work to the engine off the main thread: pointer input and
/// filter edits go through one serial queue so they reach the engine in
/// order, and long operations (export, save) run on their own queue behind
/// everything already pending, so they never sit in front of painting yet
/// still write its result.
@MainActor
final class ImageDocument {
    let session: EngineSession
    let image: Int32
    /// The display name; a successful native save replaces it with the
    /// file's name.
    private(set) var name: String
    /// The file the image belongs to and whether it needs saving.
    private(set) var fileState: DocumentFileState

    private(set) var info: EngineSession.ImageInfo
    private(set) var layers: [EngineSession.Layer] = []
    private(set) var undoInfo = EngineSession.UndoInfo(undoCount: 0, redoCount: 0, nextUndo: "", nextRedo: "")

    /// The layer painting and filters apply to.
    private(set) var activeLayer: Int32?
    /// The selection outline in image pixels, for marching ants.
    private(set) var selectionOutline: [EngineSession.Segment] = []
    /// The image's paths, top first.
    private(set) var paths: [EngineSession.PathInfo] = []
    /// The path the Path tool edits and the Paths palette's commands use.
    private(set) var activePath: Int32?
    /// The shapes the canvas draws: visible paths and the active one.
    private(set) var pathShapes: [Int32: VectorPath] = [:]
    /// Edits sent to the engine and not yet done, per path; until they
    /// are, a reload keeps the shape the edit set rather than the engine's
    /// older one.
    private var pendingPathEdits: [Int32: Int] = [:]

    /// Called after layers or undo state changed.
    var onStateChange: (() -> Void)?
    /// Called with the changed area in image pixels.
    var onProjectionChange: ((CGRect) -> Void)?
    /// Called with engine errors that the interface should show.
    var onError: ((String) -> Void)?
    /// Called after the selection changed.
    var onSelectionChange: (() -> Void)?
    /// Called after the image's size changed (crop, canvas size, undo).
    var onSizeChange: (() -> Void)?

    nonisolated let inputQueue = DispatchQueue(label: "ch.lkmc.Glims.document.input", qos: .userInteractive)
    private nonisolated let clipboardQueue = DispatchQueue(label: "ch.lkmc.Glims.document.clipboard", qos: .userInitiated)
    nonisolated let longQueue = DispatchQueue(label: "ch.lkmc.Glims.document.long", qos: .userInitiated)

    /// Engine jobs queued and not yet finished. Touched on the main actor
    /// only: every enqueue happens here and each job reports its end back
    /// here, so a close can wait for the count to reach zero before the
    /// engine image is destroyed.
    private(set) var pendingWork = 0
    /// Input-queue jobs in flight — all of them edits, so each counts as
    /// an unsaved change until the engine's dirty flag comes back.
    private var pendingInput = 0
    /// Once the image starts closing, nothing new is queued.
    private(set) var isClosing = false
    private(set) var isTransferringClipboard = false
    private(set) var isSavingForClose = false
    private var onQueueDrained: (() -> Void)?

    var acceptsEdits: Bool {
        !isClosing && !isSavingForClose && !isTransferringClipboard && !PlugInCommands.isRunning
    }

    /// Touched only on `inputQueue`.
    private nonisolated(unsafe) var currentStroke: Int32?
    private(set) var strokeIsActive = false

    /// Which plug-in commands can run on the selected layers, by name;
    /// nil until asked for after a change.
    private var procedureSensitivity: [String: Bool]?

    /// `source` is the file the image was opened from — native XCF or a
    /// foreign file it was imported from; `nil` for a new image.
    init(session: EngineSession, image: Int32, name: String, openedFrom source: URL? = nil) throws {
        self.session = session
        self.image = image
        self.name = name
        self.fileState = DocumentFileState(openedFrom: source)
        self.info = try session.info(image)
        try reload()
    }

    /// Re-reads layers, undo state and size from the engine.
    func reload() throws {
        procedureSensitivity = nil
        info = try session.info(image)
        fileState.syncDirty(info.isDirty)
        layers = try session.layers(image)
        undoInfo = try session.undoInfo(image)
        if activeLayer == nil || !layers.contains(where: { $0.id == activeLayer }) {
            activeLayer = layers.first(where: { $0.isSelected && $0.kind != .group })?.id
                ?? layers.first(where: { $0.kind != .group })?.id
        }
        reloadPaths()
        onStateChange?()
    }

    private func reloadPaths() {
        paths = (try? session.paths(image)) ?? []
        if activePath == nil || !paths.contains(where: { $0.id == activePath }) {
            activePath = paths.first(where: \.isSelected)?.id
        }
        var shapes: [Int32: VectorPath] = [:]
        for path in paths where path.isVisible || path.id == activePath {
            if pendingPathEdits[path.id, default: 0] > 0, let pending = pathShapes[path.id] {
                shapes[path.id] = pending
            } else {
                shapes[path.id] = try? session.path(path.id, image: image)
            }
        }
        pathShapes = shapes
    }

    /// Makes `id` the layer painting, fills, filters, plug-ins and the
    /// Layer commands act on, here and in the engine.
    enum SelectionSource { case user, engine }

    func selectLayer(_ id: Int32, source: SelectionSource = .user) {
        guard !isClosing else { return }
        if source == .user && refuseWhileEditingUnavailable() { return }
        guard layers.contains(where: { $0.id == id && $0.kind != .group }) else { return }
        activeLayer = id
        run(effect: .readsPixels) { session, image in try session.selectLayer(id, image: image) }
        onStateChange?()
    }

    func handle(_ event: EngineSession.Event) {
        switch event {
        case .projectionChanged(let image, let rect) where image == self.image:
            onProjectionChange?(rect)
        case .layersChanged(let image) where image == self.image,
             .undoChanged(let image) where image == self.image:
            try? reload()
        case .selectionChanged(let image) where image == self.image:
            refreshSelection()
        case .sizeChanged(let image) where image == self.image:
            try? reload()
            onSizeChange?()
        default:
            break
        }
    }

    // MARK: Painting

    func beginStroke(at point: EngineSession.StrokePoint, brush: EngineSession.Brush = EngineSession.Brush()) {
        guard let layer = activeLayer, !refuseWhileEditingUnavailable() else { return }
        strokeIsActive = true
        enqueue(on: inputQueue, input: true) { [session, image] in
            do {
                self.currentStroke = try session.beginStroke(image: image, layer: layer, brush: brush, first: point)
            } catch {
                self.currentStroke = nil
                self.report(error)
            }
        }
    }

    func continueStroke(_ points: [EngineSession.StrokePoint]) {
        enqueue(on: inputQueue, input: true) { [session] in
            guard let stroke = self.currentStroke else { return }
            do { try session.continueStroke(stroke, points: points) } catch { self.report(error) }
        }
    }

    func endStroke() {
        strokeIsActive = false
        enqueue(on: inputQueue, input: true) { [session] in
            guard let stroke = self.currentStroke else { return }
            self.currentStroke = nil
            do { try session.endStroke(stroke) } catch { self.report(error) }
        }
    }

    // MARK: Selection

    func select(_ shape: EngineSession.SelectShape, options: EngineSession.SelectOptions) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.select(shape, image: image, options: options) }
    }

    func selectColor(at point: CGPoint, options: EngineSession.SelectOptions) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.selectColor(at: point, image: image, options: options) }
    }

    func select(_ command: EngineSession.SelectCommand, radius: Double = 0) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.select(command, image: image, radius: radius) }
    }

    // MARK: Editing

    func fill(at point: CGPoint, mode: EngineSession.FillMode, color: NSColor, threshold: Double,
              sampleMerged: Bool) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in
            try session.fill(image: image, at: point, mode: mode, color: color,
                             threshold: threshold, sampleMerged: sampleMerged)
        }
    }

    func gradient(from: CGPoint, to: CGPoint, shape: EngineSession.GradientShape, fromColor: NSColor, toColor: NSColor) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in
            try session.gradient(image: image, from: from, to: to, shape: shape, fromColor: fromColor, toColor: toColor)
        }
    }

    func layerCommand(_ command: EngineSession.LayerCommand) {
        guard !refuseWhileEditingUnavailable() else { return }
        let layer = activeLayer ?? 0
        run { session, image in
            let created = try session.layerCommand(command, image: image, layer: layer)
            if let created {
                // The engine selects what it created; keep the interface in step.
                DispatchQueue.main.async {
                    try? self.reload()
                    if self.layers.contains(where: { $0.id == created }) { self.selectLayer(created, source: .engine) }
                }
            }
        }
    }

    func changeLayer(_ layer: Int32, _ change: EngineSession.LayerChange) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.changeLayer(layer, image: image, change) }
    }

    func moveActiveLayer(by offset: CGSize) {
        guard let layer = activeLayer, offset != .zero, !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.moveLayer(layer, image: image, by: offset) }
    }

    func transformImage(_ transform: EngineSession.Transform) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.transformImage(image, transform) }
    }

    func transformActiveLayer(_ transform: EngineSession.Transform) {
        guard let layer = activeLayer, !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.transformLayer(layer, image: image, transform) }
    }

    // MARK: Text

    /// Adds a text layer at `position` and makes it the active layer.
    func addText(_ text: String, settings: EngineSession.TextSettings, at position: CGPoint) {
        guard !text.isEmpty, !refuseWhileEditingUnavailable() else { return }
        enqueue(on: inputQueue, input: true) { [session, image] in
            do {
                let layer = try session.addTextLayer(image: image, text: text, settings: settings, at: position)
                DispatchQueue.main.async { self.selectLayer(layer, source: .engine) }
            } catch {
                self.report(error)
            }
        }
    }

    /// Changes a text layer's text, its look, or both, as one undo step.
    func updateText(_ layer: Int32, text: String?, settings: EngineSession.TextSettings?) {
        guard text != nil || settings != nil, !refuseWhileEditingUnavailable() else { return }
        run { session, image in
            try session.setTextLayer(image: image, layer: layer, text: text, settings: settings)
        }
    }

    /// A text layer's text and look, read on the engine thread's queue.
    func textLayer(_ layer: Int32) -> (text: String, settings: EngineSession.TextSettings)? {
        inputQueue.sync { [session, image] in try? session.textLayer(image: image, layer: layer) }
    }

    /// Commits the Transform tool: `matrix` maps the layer's pixels to
    /// where its handles put them.
    func transformLayer(_ layer: Int32, matrix: CGAffineTransform,
                        interpolation: EngineSession.Interpolation) {
        guard !matrix.isIdentity, !refuseWhileEditingUnavailable() else { return }
        run { session, image in
            try session.transformLayer(layer, image: image, matrix: matrix, interpolation: interpolation)
        }
    }

    func scale(toWidth width: Int, height: Int) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.scaleImage(image, width: width, height: height) }
    }

    func resizeCanvas(width: Int, height: Int, offset: CGPoint, fill: NSColor) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.resizeCanvas(image, width: width, height: height, offset: offset, fill: fill) }
    }

    func crop(to rect: CGRect) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.crop(image: image, to: rect) }
    }

    // MARK: Paths

    /// Makes `id` the path the Path tool edits, here and in the engine.
    func selectPath(_ id: Int32) {
        guard paths.contains(where: { $0.id == id }), !refuseWhileEditingUnavailable() else { return }
        activePath = id
        if pathShapes[id] == nil { pathShapes[id] = try? session.path(id, image: image) }
        run { session, image in try session.changePath(id, image: image, select: true) }
        onStateChange?()
    }

    /// Adds a path with `shape` and makes it the active one. Waits for the
    /// engine, so the next edit knows the path.
    @discardableResult
    func addPath(_ shape: VectorPath) -> Int32? {
        guard !refuseWhileEditingUnavailable() else { return nil }
        let result = inputQueue.sync { [session, image] in
            Result { try session.setPath(nil, image: image, shape) }
        }
        switch result {
        case .success(let id):
            activePath = id
            pathShapes[id] = shape
            try? reload()
            return id
        case .failure(let error):
            report(error)
            return nil
        }
    }

    /// Replaces the shape of path `id` as one undo step. The canvas shows
    /// the new shape at once.
    func updatePath(_ id: Int32, to shape: VectorPath) {
        guard !refuseWhileEditingUnavailable() else { return }
        pathShapes[id] = shape
        pendingPathEdits[id, default: 0] += 1
        enqueue(on: inputQueue, input: true) { [session, image] in
            let result = Result { try session.setPath(id, image: image, shape) }
            DispatchQueue.main.async {
                self.pendingPathEdits[id, default: 1] -= 1
                if case .failure(let error) = result {
                    self.report(error)
                    try? self.reload()
                }
            }
        }
        onStateChange?()
    }

    func renamePath(_ id: Int32, to name: String) {
        guard !name.isEmpty, !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.changePath(id, image: image, name: name) }
    }

    func setPathVisible(_ id: Int32, _ visible: Bool) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.changePath(id, image: image, visible: visible) }
    }

    func deletePath(_ id: Int32) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.deletePath(id, image: image) }
    }

    /// Select ▸ From Path: the active path's area, combined by `operation`.
    func selectFromPath(_ id: Int32, operation: EngineSession.SelectOperation = .replace) {
        guard !refuseWhileEditingUnavailable() else { return }
        var options = EngineSession.SelectOptions()
        options.operation = operation
        run { session, image in try session.selectPath(id, image: image, options: options) }
    }

    /// Edit ▸ Stroke Path: draws the path on the active layer.
    func strokePath(_ id: Int32, settings: EngineSession.LineSettings) {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.strokePath(id, image: image, settings: settings) }
    }

    /// Re-reads the outline; the engine caches it until the selection changes.
    func refreshSelection() {
        selectionOutline = (try? session.selectionOutline(image: image)) ?? []
        onSelectionChange?()
    }

    // MARK: Undo

    func undo() {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.undo(image) }
    }

    func redo() {
        guard !refuseWhileEditingUnavailable() else { return }
        run { session, image in try session.redo(image) }
    }

    /// The engine refuses edits while a plug-in command runs (its dialog
    /// acts as a modal filter dialog); say why instead of failing later.
    private func refuseWhileEditingUnavailable() -> Bool {
        if isClosing || isSavingForClose || isTransferringClipboard {
            onError?(isClosing ? DocumentError.closed.localizedDescription : DocumentError.busy.localizedDescription)
            return true
        }
        guard let running = PlugInCommands.running else { return false }
        let title = running.procedure.label.replacingOccurrences(of: "…", with: "")
        onError?("Finish or cancel \u{201C}\(title)\u{201D} first.")
        NSSound.beep()
        return true
    }

    // MARK: Plug-in commands

    /// Whether the command can run on the selected layers. Asks the engine
    /// once per change of the image.
    func canRun(_ procedure: EngineSession.Procedure) -> Bool {
        if procedureSensitivity == nil {
            let rows = (try? session.procedures(image: image)) ?? []
            procedureSensitivity = Dictionary(rows.map { ($0.name, $0.isSensitive) }, uniquingKeysWith: { a, _ in a })
        }
        return procedureSensitivity?[procedure.name] ?? false
    }

    /// Runs a plug-in command on the selected layers. Interactively the
    /// plug-in shows its own dialog; the call completes when it finished.
    func run(_ procedure: EngineSession.Procedure, mode: EngineSession.RunMode,
             completion: @escaping @MainActor (Result<EngineSession.RunOutcome, Error>) -> Void) {
        guard !isClosing else { return completion(.failure(DocumentError.closed)) }
        guard !isTransferringClipboard, !isSavingForClose else { return completion(.failure(DocumentError.busy)) }
        enqueueAfterInput { [session, image] in
            let result = Result { try session.runProcedure(procedure.name, image: image, mode: mode) }
            DispatchQueue.main.async {
                try? self.reload()
                completion(result)
            }
        }
    }

    enum DocumentError: LocalizedError {
        case closed, busy
        var errorDescription: String? {
            switch self {
            case .closed: return "This image has already closed."
            case .busy: return "Wait for the current clipboard transfer or save to finish."
            }
        }
    }

    /// After Save was chosen on close, stop accepting new edits until
    /// the write either fails/cancels or the image is destroyed.
    func beginCloseSave() -> Bool {
        guard !refuseWhileEditingUnavailable() else { return false }
        isSavingForClose = true
        onStateChange?()
        return true
    }

    func cancelCloseSave() {
        isSavingForClose = false
        onStateChange?()
    }

    enum ClipboardOperation { case layer, merged, cutLayer }

    /// Pixel work stays serial with input; the pasteboard transaction is
    /// asynchronous on the main actor. Never block this queue waiting for
    /// AppKit, which can synchronously read text/path metadata from it.
    func copyPixels(_ operation: ClipboardOperation, background: NSColor,
                    consume: @escaping @MainActor (ClipboardImage.Encoded) throws -> Void,
                    completion: @escaping @MainActor (Error?) -> Void) {
        guard !isClosing else { return completion(DocumentError.closed) }
        guard !isTransferringClipboard, !isSavingForClose, !PlugInCommands.isRunning else {
            return completion(DocumentError.busy)
        }
        isTransferringClipboard = true
        let cutting = operation == .cutLayer
        // Track the encoding/main-actor stage independently of the short
        // pixel-read job; it must also drain before destroying the image.
        pendingWork += 1
        if cutting { pendingInput += 1 }
        onStateChange?()
        enqueue(on: inputQueue) { [session, image] in
            let pixels = Result { try session.copyPixels(image, merged: operation == .merged) }
            self.clipboardQueue.async {
                let result = pixels.flatMap { image in Result { try image.encoded() } }
                DispatchQueue.main.async {
                    defer { self.jobDidFinish(input: cutting) }
                    guard !self.isClosing else { return self.finishClipboard(DocumentError.closed, completion: completion) }
                    do { try consume(result.get()) } catch {
                        return self.finishClipboard(error, completion: completion)
                    }
                    guard cutting else { return self.finishClipboard(nil, completion: completion) }
                    // No edits were accepted between the copy and clear.
                    self.enqueue(on: self.inputQueue, input: true) {
                        let error: Error?
                        do { try session.clearPixels(image, background: background); error = nil }
                        catch let failure { error = failure }
                        DispatchQueue.main.async { self.finishClipboard(error, completion: completion) }
                    }
                }
            }
        }
    }

    private func finishClipboard(_ error: Error?, completion: @MainActor (Error?) -> Void) {
        isTransferringClipboard = false
        if !isClosing { try? reload() }
        completion(error)
    }

    // MARK: Files

    /// Whether closing now could lose work: edits the engine counted, an
    /// imported image never written as XCF, edits still queued on their
    /// way to the engine, or a plug-in command still working on it.
    var hasUnsavedChanges: Bool {
        fileState.hasUnsavedChanges || pendingInput > 0
            || PlugInCommands.running?.document === self
    }

    func export(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        guard !isClosing else { return completion(DocumentError.closed) }
        guard !isTransferringClipboard else { return completion(DocumentError.busy) }
        enqueueAfterInput { [session, image] in
            let result: Error?
            do { try session.export(image, to: url.path); result = nil } catch { result = error }
            DispatchQueue.main.async {
                if result == nil { self.fileState.noteExported(to: url) }
                completion(result)
            }
        }
    }

    func save(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        guard !isClosing else { return completion(DocumentError.closed) }
        guard !isTransferringClipboard else { return completion(DocumentError.busy) }
        enqueueAfterInput { [session, image] in
            let result: Error?
            do { try session.save(image, to: url.path); result = nil } catch { result = error }
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// A native save to `url` succeeded: it becomes the image's file —
    /// name, dirty state and all.
    func noteSaved(to url: URL) {
        fileState.noteSaved(to: url)
        name = url.lastPathComponent
        try? reload()
    }

    /// Stops taking work and destroys the engine image once everything
    /// queued has run, so a close never tears the image from under a job.
    /// The teardown cannot rely on `self` — the controller may already be
    /// gone — so the session and image id travel in the closure.
    func closeImageWhenDrained(completion: @escaping @MainActor () -> Void = {}) {
        guard !isClosing else { return }
        if strokeIsActive { endStroke() }
        isClosing = true
        let close = { [session, image, longQueue] in
            longQueue.async {
                do { try session.closeImage(image) } catch { self.report(error) }
                DispatchQueue.main.async { completion() }
            }
        }
        if pendingWork == 0 { close() } else { onQueueDrained = close }
    }

    // MARK: Helpers

    /// Runs engine work on the input queue, after any pending pointer input.
    enum CommandEffect { case readsPixels, changesImage, changesPreview }

    /// Aborting a preview is cleanup, so clipboard/save edit gates must
    /// never suppress it. It still joins pending work to protect teardown.
    /// A commit is an edit and leaves its session available if refused.
    func finishFilter(_ filter: Int32, commit: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        guard !isClosing else { return completion(false) }
        if commit && refuseWhileEditingUnavailable() { return completion(false) }
        enqueue(on: inputQueue, input: commit) { [session] in
            let success: Bool
            do {
                if commit { try session.commitFilter(filter) } else { try session.abortFilter(filter) }
                success = true
            } catch {
                if commit { self.report(error) }
                success = false
            }
            DispatchQueue.main.async { completion(success) }
        }
    }

    @discardableResult
    func run(effect: CommandEffect = .changesImage, _ work: @escaping (EngineSession, Int32) throws -> Void) -> Bool {
        guard !isClosing else { return false }
        if effect != .readsPixels && refuseWhileEditingUnavailable() { return false }
        enqueue(on: inputQueue, input: effect == .changesImage) { [session, image] in
            do { try work(session, image) } catch { self.report(error) }
        }
        return true
    }

    /// Queues engine work; the document counts it until it ran so a close
    /// can wait. `input` jobs go through the input queue — all edits —
    /// and count as unsaved changes while they wait or run.
    private func enqueue(on queue: DispatchQueue, input: Bool = false, _ work: @escaping () -> Void) {
        guard !isClosing else { return }
        pendingWork += 1
        if input { pendingInput += 1 }
        queue.async {
            work()
            DispatchQueue.main.async { self.jobDidFinish(input: input) }
        }
    }

    /// Queues `work` on the long queue behind everything the input queue
    /// already holds: a save or export then writes every edit that was
    /// pending when it was asked for.
    private func enqueueAfterInput(_ work: @escaping () -> Void) {
        guard !isClosing else { return }
        pendingWork += 1
        inputQueue.async { [longQueue] in
            longQueue.async {
                work()
                DispatchQueue.main.async { self.jobDidFinish(input: false) }
            }
        }
    }

    private func jobDidFinish(input: Bool) {
        pendingWork -= 1
        if input {
            pendingInput -= 1
            // An in-flight edit can hold the dirty bullet up; refresh it.
            if pendingInput == 0 { onStateChange?() }
        }
        if pendingWork == 0, let drained = onQueueDrained {
            onQueueDrained = nil
            drained()
        }
    }

    private nonisolated func report(_ error: Error) {
        let message = String(describing: error)
        DispatchQueue.main.async { self.onError?(message) }
    }
}
