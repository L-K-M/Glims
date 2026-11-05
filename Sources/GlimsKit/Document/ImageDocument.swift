import AppKit
import CoreGraphics

/// One open image in the engine, as the interface sees it.
///
/// The document keeps the state the interface shows (size, layers, undo)
/// and routes work to the engine off the main thread: pointer input and
/// filter edits go through one serial queue so they reach the engine in
/// order, and long operations (export, save) run on their own queue so they
/// never sit in front of painting.
@MainActor
final class ImageDocument {
    let session: EngineSession
    let image: Int32
    let name: String

    private(set) var info: EngineSession.ImageInfo
    private(set) var layers: [EngineSession.Layer] = []
    private(set) var undoInfo = EngineSession.UndoInfo(undoCount: 0, redoCount: 0, nextUndo: "", nextRedo: "")

    /// The layer painting and filters apply to.
    private(set) var activeLayer: Int32?
    /// The selection outline in image pixels, for marching ants.
    private(set) var selectionOutline: [EngineSession.Segment] = []

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
    nonisolated let longQueue = DispatchQueue(label: "ch.lkmc.Glims.document.long", qos: .userInitiated)

    /// Touched only on `inputQueue`.
    private nonisolated(unsafe) var currentStroke: Int32?

    /// Which plug-in commands can run on the selected layers, by name;
    /// nil until asked for after a change.
    private var procedureSensitivity: [String: Bool]?

    init(session: EngineSession, image: Int32, name: String) throws {
        self.session = session
        self.image = image
        self.name = name
        self.info = try session.info(image)
        try reload()
    }

    /// Re-reads layers, undo state and size from the engine.
    func reload() throws {
        procedureSensitivity = nil
        info = try session.info(image)
        layers = try session.layers(image)
        undoInfo = try session.undoInfo(image)
        if activeLayer == nil || !layers.contains(where: { $0.id == activeLayer }) {
            activeLayer = layers.first(where: { $0.isSelected && $0.kind != .group })?.id
                ?? layers.first(where: { $0.kind != .group })?.id
        }
        onStateChange?()
    }

    /// Makes `id` the layer painting, fills, filters, plug-ins and the
    /// Layer commands act on, here and in the engine.
    func selectLayer(_ id: Int32) {
        guard layers.contains(where: { $0.id == id && $0.kind != .group }) else { return }
        activeLayer = id
        run { session, image in try session.selectLayer(id, image: image) }
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
        guard let layer = activeLayer, !refuseWhilePlugInRuns() else { return }
        inputQueue.async { [session, image] in
            do {
                self.currentStroke = try session.beginStroke(image: image, layer: layer, brush: brush, first: point)
            } catch {
                self.currentStroke = nil
                self.report(error)
            }
        }
    }

    func continueStroke(_ points: [EngineSession.StrokePoint]) {
        inputQueue.async { [session] in
            guard let stroke = self.currentStroke else { return }
            do { try session.continueStroke(stroke, points: points) } catch { self.report(error) }
        }
    }

    func endStroke() {
        inputQueue.async { [session] in
            guard let stroke = self.currentStroke else { return }
            self.currentStroke = nil
            do { try session.endStroke(stroke) } catch { self.report(error) }
        }
    }

    // MARK: Selection

    func select(_ shape: EngineSession.SelectShape, options: EngineSession.SelectOptions) {
        guard !refuseWhilePlugInRuns() else { return }
        run { session, image in try session.select(shape, image: image, options: options) }
    }

    func selectColor(at point: CGPoint, options: EngineSession.SelectOptions) {
        guard !refuseWhilePlugInRuns() else { return }
        run { session, image in try session.selectColor(at: point, image: image, options: options) }
    }

    func select(_ command: EngineSession.SelectCommand, radius: Double = 0) {
        guard !refuseWhilePlugInRuns() else { return }
        run { session, image in try session.select(command, image: image, radius: radius) }
    }

    // MARK: Editing

    func fill(at point: CGPoint, mode: EngineSession.FillMode, color: NSColor, threshold: Double,
              sampleMerged: Bool) {
        guard !refuseWhilePlugInRuns() else { return }
        run { session, image in
            try session.fill(image: image, at: point, mode: mode, color: color,
                             threshold: threshold, sampleMerged: sampleMerged)
        }
    }

    func gradient(from: CGPoint, to: CGPoint, shape: EngineSession.GradientShape, fromColor: NSColor, toColor: NSColor) {
        guard !refuseWhilePlugInRuns() else { return }
        run { session, image in
            try session.gradient(image: image, from: from, to: to, shape: shape, fromColor: fromColor, toColor: toColor)
        }
    }

    func layerCommand(_ command: EngineSession.LayerCommand) {
        guard !refuseWhilePlugInRuns() else { return }
        let layer = activeLayer ?? 0
        run { session, image in
            let created = try session.layerCommand(command, image: image, layer: layer)
            if let created {
                // The engine selects what it created; keep the interface in step.
                DispatchQueue.main.async {
                    try? self.reload()
                    if self.layers.contains(where: { $0.id == created }) { self.selectLayer(created) }
                }
            }
        }
    }

    func changeLayer(_ layer: Int32, _ change: EngineSession.LayerChange) {
        guard !refuseWhilePlugInRuns() else { return }
        run { session, image in try session.changeLayer(layer, image: image, change) }
    }

    func moveActiveLayer(by offset: CGSize) {
        guard let layer = activeLayer, offset != .zero, !refuseWhilePlugInRuns() else { return }
        run { session, image in try session.moveLayer(layer, image: image, by: offset) }
    }

    func transformImage(_ transform: EngineSession.Transform) {
        guard !refuseWhilePlugInRuns() else { return }
        run { session, image in try session.transformImage(image, transform) }
    }

    func transformActiveLayer(_ transform: EngineSession.Transform) {
        guard let layer = activeLayer, !refuseWhilePlugInRuns() else { return }
        run { session, image in try session.transformLayer(layer, image: image, transform) }
    }

    func scale(toWidth width: Int, height: Int) {
        guard !refuseWhilePlugInRuns() else { return }
        run { session, image in try session.scaleImage(image, width: width, height: height) }
    }

    func resizeCanvas(width: Int, height: Int, offset: CGPoint, fill: NSColor) {
        guard !refuseWhilePlugInRuns() else { return }
        run { session, image in try session.resizeCanvas(image, width: width, height: height, offset: offset, fill: fill) }
    }

    func crop(to rect: CGRect) {
        guard !refuseWhilePlugInRuns() else { return }
        run { session, image in try session.crop(image: image, to: rect) }
    }

    /// Re-reads the outline; the engine caches it until the selection changes.
    func refreshSelection() {
        selectionOutline = (try? session.selectionOutline(image: image)) ?? []
        onSelectionChange?()
    }

    // MARK: Undo

    func undo() {
        guard !refuseWhilePlugInRuns() else { return }
        run { session, image in try session.undo(image) }
    }

    func redo() {
        guard !refuseWhilePlugInRuns() else { return }
        run { session, image in try session.redo(image) }
    }

    /// The engine refuses edits while a plug-in command runs (its dialog
    /// acts as a modal filter dialog); say why instead of failing later.
    private func refuseWhilePlugInRuns() -> Bool {
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
        longQueue.async { [session, image] in
            let result = Result { try session.runProcedure(procedure.name, image: image, mode: mode) }
            DispatchQueue.main.async {
                try? self.reload()
                completion(result)
            }
        }
    }

    // MARK: Files

    func export(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        longQueue.async { [session, image] in
            let result: Error?
            do { try session.export(image, to: url.path); result = nil } catch { result = error }
            DispatchQueue.main.async { completion(result) }
        }
    }

    func save(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        longQueue.async { [session, image] in
            let result: Error?
            do { try session.save(image, to: url.path); result = nil } catch { result = error }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: Helpers

    /// Runs engine work on the input queue, after any pending pointer input.
    func run(_ work: @escaping (EngineSession, Int32) throws -> Void) {
        inputQueue.async { [session, image] in
            do { try work(session, image) } catch { self.report(error) }
        }
    }

    private nonisolated func report(_ error: Error) {
        let message = String(describing: error)
        DispatchQueue.main.async { self.onError?(message) }
    }
}
