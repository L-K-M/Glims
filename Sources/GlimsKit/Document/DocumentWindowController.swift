import AppKit
import RigiUI
import UniformTypeIdentifiers

/// A document window: the engine canvas in a scroll view above Rigi's status
/// strip. It handles the imageDocument's menu commands through the responder
/// chain.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let imageDocument: ImageDocument
    let canvas: EngineCanvasView
    private let preferences: EditorPreferences
    let statusBar = StatusBarView(frame: .zero)
    private let scrollView = NSScrollView()
    private lazy var engineUndoManager = EngineUndoManager(document: imageDocument)
    /// The open filter preview, generic or dedicated; one at a time.
    private(set) var previewPanel: FilterPreviewPanel?
    /// Bumped by every filter start and every cancellation, so a begin
    /// that lands late can tell it is stale and abort its session.
    private var previewRequest = 0
    /// A begin job is queued behind pending input; while it waits, edits
    /// and file writes gate exactly as if the panel were already open.
    private var previewStartIsPending = false
    /// An open panel or a start still queued on the input queue.
    private var previewBusy: Bool { previewPanel != nil || previewStartIsPending }
    /// A print job anywhere between Print… and the end of the run: a
    /// second Print is refused, and a close asked for during the engine
    /// render drops the snapshot instead of attaching a sheet.
    private(set) var printJobIsOpen = false
    /// A close asked for while the snapshot still renders; the job ends
    /// without attaching the print sheet and the close goes on.
    private var printJobDropped = false
    private var activePrintOperation: NSPrintOperation?
    private var pageLayout: NSPageLayout?
    /// Substitute for the print-panel sheet (tests); whoever runs the
    /// job must report back through `printJobDidFinish(printed:)`.
    var printJobRunner: ((ImagePrintView, NSPrintInfo, NSWindow,
                         @escaping @MainActor (Bool) -> Void) -> Void)?
    /// Substitute for the NSPageLayout sheet (tests).
    var pageSetupRunner: ((NSPrintInfo, NSWindow,
                          @escaping @MainActor (NSPrintInfo?) -> Void) -> Void)?
    var onClose: ((DocumentWindowController) -> Void)?
    let fileAccessID = UUID()
    var reserveWrite: ((URL) throws -> (() -> Void))?
    /// Whoever owns the open documents binds this: a confirmed Revert
    /// asks it to reload `URL` from disk and replace this window's
    /// document with the result. `nil` where nothing can adopt a
    /// document — the menu item stays disabled then.
    var revertHandler: ((URL, @escaping @MainActor (Result<DocumentWindowController, Error>) -> Void) -> Void)?

    init(document imageDocument: ImageDocument, preferences: EditorPreferences? = nil) {
        self.imageDocument = imageDocument
        self.preferences = preferences ?? .shared
        self.canvas = EngineCanvasView(document: imageDocument)

        let window = ClassicWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.minSize = NSSize(width: 360, height: 240)
        super.init(window: window)
        window.delegate = self
        window.representedURL = imageDocument.fileState.nativeURL

        layOutContent(in: window)
        NotificationCenter.default.addObserver(self, selector: #selector(applyPreferences),
                                               name: EditorPreferences.didChange, object: self.preferences)
        applyPreferences()
        imageDocument.onProjectionChange = { [weak self] rect in self?.canvas.imageDidChange(in: rect) }
        imageDocument.onStateChange = { [weak self] in self?.stateDidChange() }
        imageDocument.onError = { [weak self] message in
            self?.showStatusError(message)
            self?.previewPanel?.showError(message)
        }
        // Palette picks and structural or lock changes first commit any
        // field/text edit and end an active stroke; each command also
        // lets a remembered refusal go.
        imageDocument.onWillChangeLayers = { [weak self] in self?.endPendingEdits() }
        imageDocument.onUserCommand = { [weak self] in self?.statusIsError = false }
        imageDocument.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.canvas.selectionOutline = self.imageDocument.selectionOutline
        }
        imageDocument.onSizeChange = { [weak self] in
            self?.canvas.imageSizeDidChange()
            self?.stateDidChange()
        }
        canvas.tools.onStatus = { [weak self] message in
            self?.statusIsError = false
            self?.statusBar.message = message
        }
        canvas.tools.onZoom = { [weak self] zoomIn, point in
            guard let self else { return }
            self.zoom(to: zoomIn ? ZoomLadder.zoomIn(from: self.canvas.zoomPercent)
                                 : ZoomLadder.zoomOut(from: self.canvas.zoomPercent))
            self.center(on: point)
        }
        statusBar.onZoomIn = { [weak self] in self?.zoom(to: ZoomLadder.zoomIn(from: self?.canvas.zoomPercent ?? 100)) }
        statusBar.onZoomOut = { [weak self] in self?.zoom(to: ZoomLadder.zoomOut(from: self?.canvas.zoomPercent ?? 100)) }
        statusBar.onZoomReset = { [weak self] in self?.zoom(to: ZoomLadder.actualPixels) }
        statusBar.isZoomEditable = true
        statusBar.onZoomTo = { [weak self] percent in self?.zoom(to: ZoomLadder.clamped(percent)) }
        statusBar.setZoom(percent: canvas.zoomPercent)
        stateDidChange()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func applyPreferences() {
        let color = preferences.surround.color
        canvas.surroundColor = color
        scrollView.backgroundColor = color
    }

    /// How far each new document window steps from the previous one.
    static let cascadeStep: CGFloat = 22

    /// Where a new document window's top-left goes, given the previous
    /// window's frame: one step down and right, or back near the top-left
    /// of the visible screen area when that step would leave it.
    static func cascadedTopLeft(after previous: CGRect, size: CGSize, in visible: CGRect) -> CGPoint {
        let stepped = CGPoint(x: previous.minX + cascadeStep, y: previous.maxY - cascadeStep)
        let fits = stepped.x + size.width <= visible.maxX && stepped.y - size.height >= visible.minY
        return fits ? stepped : CGPoint(x: visible.minX + cascadeStep, y: visible.maxY)
    }

    private func layOutContent(in window: NSWindow) {
        scrollView.contentView = CanvasClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.backgroundColor = NSColor(calibratedWhite: 0.42, alpha: 1)
        scrollView.drawsBackground = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)

        let content = NSView()
        for view in [scrollView, statusBar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: ClassicMetrics.statusBarHeight),
        ])

        window.contentView = content
    }

    @objc private func viewportChanged() {
        canvas.setNeedsRender()
    }

    /// The image-space point at the viewport's center; a revert
    /// restores it on the replacement document.
    var canvasCenter: CGPoint {
        let visible = scrollView.contentView.bounds
        return CGPoint(x: visible.midX / canvas.scale, y: visible.midY / canvas.scale)
    }

    /// Scrolls so `point` (image pixels) is in the middle of the view.
    func center(on point: CGPoint) {
        let visible = scrollView.contentView.bounds
        canvas.scroll(NSPoint(x: point.x * canvas.scale - visible.width / 2,
                              y: point.y * canvas.scale - visible.height / 2))
    }

    func zoom(to percent: Int) {
        let visible = scrollView.contentView.bounds
        let imageCenter = CGPoint(x: visible.midX / canvas.scale, y: visible.midY / canvas.scale)
        canvas.setZoom(percent: percent)
        center(on: imageCenter)
        statusBar.setZoom(percent: percent)
        stateDidChange()
    }

    /// Classic title and status: `name @ 100% (RGB, u8-non-linear)`.
    static func title(name: String, zoomPercent: Int, isDirty: Bool, precision: String) -> String {
        "\(isDirty ? "• " : "")\(name) @ \(zoomPercent)% (RGB, \(precision))"
    }

    /// While true the status bar shows a refusal the user should read;
    /// generic state reloads leave it alone until the next command.
    private var statusIsError = false

    private func showStatusError(_ message: String) {
        statusIsError = true
        statusBar.message = message
    }

    /// Commits in-flight field and canvas-text edits and ends an active
    /// stroke; runs before a user layer selection or a structural/lock
    /// change so those never race a half-committed edit. Only edits that
    /// belong to this document end: its own window and dialogs plus the
    /// palettes aimed at it — a routine layer command must not commit
    /// another document's field or palette edits.
    private func endPendingEdits() {
        window?.endEditing(for: nil)
        previewPanel?.window?.endEditing(for: nil)
        for paletteWindow in PaletteEditScope.windowsEditing(imageDocument) {
            paletteWindow.endEditing(for: nil)
        }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
    }

    /// Whether a background recovery copy may start now. The engine-wide
    /// input drain that precedes a file call commits every open
    /// document's in-flight text and field edits — the same ones
    /// `endPendingEdits` commits — so a recovery pass must not admit
    /// this document while any of them is open. It checks the same
    /// scope instead of committing, and the scheduler checks every
    /// tracked window before it admits any.
    var isReadyForRecoveryCopy: Bool {
        guard !canvas.tools.hasPendingInteraction else { return false }
        let scoped = [window, previewPanel?.window].compactMap { $0 }
            + PaletteEditScope.windowsEditing(imageDocument)
        return scoped.allSatisfy { !PaletteEditScope.isFieldEditing($0) }
    }

    private func stateDidChange() {
        window?.title = Self.title(name: imageDocument.name, zoomPercent: canvas.zoomPercent,
                                   isDirty: imageDocument.hasUnsavedChanges,
                                   precision: imageDocument.info.precision)
        let undo = imageDocument.undoInfo.nextUndo.isEmpty ? "" : " · Undo \(imageDocument.undoInfo.nextUndo)"
        if !statusIsError {
            statusBar.message = EngineActivity.shared.label.map { "\($0)…" } ?? "\(imageDocument.info.width) × \(imageDocument.info.height) px · \(imageDocument.info.layerCount) layer\(imageDocument.info.layerCount == 1 ? "" : "s")\(undo)"
        }
        (PaletteCenter.shared.registeredPalette(for: LayersPaletteController.definition.kind))?.retarget()
        (PaletteCenter.shared.registeredPalette(for: ChannelsPaletteController.definition.kind))?.retarget()
        (PaletteCenter.shared.registeredPalette(for: PathsPaletteController.definition.kind))?.retarget()
        (PaletteCenter.shared.registeredPalette(for: HistoryPaletteController.definition.kind))?.retarget()
        // Path shapes arrive with the state; the canvas draws them.
        canvas.needsDisplay = true
    }

    // MARK: Menu commands

    @objc override func deleteBackward(_ sender: Any?) { clearPixels(sender) }
    @objc override func cancelOperation(_ sender: Any?) {
        if let previewPanel { previewPanel.cancel() }
        else if previewStartIsPending { cancelPendingPreview() }
        else { super.cancelOperation(sender) }
    }

    /// Cancels a filter start still waiting behind pending input; its
    /// begin completion lands stale and unwinds whatever it created.
    private func cancelPendingPreview() {
        guard previewStartIsPending else { return }
        previewRequest += 1
        previewStartIsPending = false
        imageDocument.filterPreviewIsOpen = false
        stateDidChange()
    }

    /// The shared start every filter preview takes: pending edits commit
    /// first, the begin job queues behind them on the input queue, and
    /// only its main-actor completion may build a panel. The document's
    /// `filterPreviewIsOpen` marks the wait so edits, file writes and
    /// other filters refuse before a session exists; Escape, close or a
    /// stale request unwinds the begun session instead of showing it.
    private func startPreview(title: String,
                              begin: (@escaping @MainActor (Result<ImageDocument.FilterPreviewStart, Error>) -> Void) -> Void,
                              buildPanel: @escaping @MainActor (Int32, [String: EngineSession.FilterValue]) -> FilterPreviewPanel?) {
        // A catalog reply may arrive after windowWillClose cancels
        // previews, while rendering still drains before isClosing flips.
        guard !closeStarted, !imageDocument.isClosing else { return }
        previewRequest += 1
        let request = previewRequest
        previewStartIsPending = true
        imageDocument.filterPreviewIsOpen = true
        statusBar.message = "\(title)…"
        begin {
            [weak self, imageDocument] result in
            guard let self, self.previewStartIsPending, self.previewRequest == request else {
                // Stale: cancelled, closed or superseded after the begin
                // was queued. A begun session is teardown-aborted — that
                // job counts toward the close drain too.
                if case .success(let start) = result {
                    imageDocument.finishFilter(start.filter, commit: false) { _ in }
                }
                return
            }
            self.previewStartIsPending = false
            switch result {
            case .failure:
                self.imageDocument.filterPreviewIsOpen = false
                self.statusBar.message = "\(title) could not start on this layer."
                NSSound.beep()
            case .success(let start):
                guard let panel = buildPanel(start.filter, start.values) else {
                    self.imageDocument.finishFilter(start.filter, commit: false) { _ in }
                    self.imageDocument.filterPreviewIsOpen = false
                    self.statusBar.message = "\(title) could not start on this layer."
                    NSSound.beep()
                    return
                }
                panel.onFinish = { [weak self] in
                    self?.previewPanel = nil
                    self?.imageDocument.filterPreviewIsOpen = false
                }
                self.previewPanel = panel
                panel.showWindow(nil)
            }
        }
    }

    private func startFilterPreview(title: String, operation: String,
                                    properties: [EngineSession.FilterProperty] = [],
                                    buildPanel: @escaping @MainActor (Int32, [String: EngineSession.FilterValue]) -> FilterPreviewPanel?) {
        startPreview(title: title, begin: { [imageDocument] completion in
            imageDocument.beginFilterPreview(operation: operation, properties: properties,
                                             completion: completion)
        }, buildPanel: buildPanel)
    }

    /// A begin on a committed effect's own edit session; the shared
    /// start is identical from there.
    private func startEffectPreview(title: String, effect: Int32, drawable: Int32,
                                    properties: [EngineSession.FilterProperty],
                                    buildPanel: @escaping @MainActor (Int32, [String: EngineSession.FilterValue]) -> FilterPreviewPanel?) {
        startPreview(title: title, begin: { [imageDocument] completion in
            imageDocument.beginEffectPreview(effect: effect, on: drawable, properties: properties,
                                             completion: completion)
        }, buildPanel: buildPanel)
    }

    /// The Layers palette's Edit Parameters on a committed effect: the
    /// generic form drives a live edit session on the effect's own
    /// stack position — the same nonmodal preview lifecycle a new
    /// filter takes. `effect` and `drawable` name the row explicitly;
    /// the begin job re-validates them behind pending input.
    func editEffectParameters(_ effect: Int32, on drawable: Int32, operationName: String) {
        guard !previewBusy, !imageDocument.isClosing, !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
              !imageDocument.isSavingForClose, !imageDocument.isTransferringClipboard else { return }
        guard let operation = NativeFilterCatalog.shared.operation(named: operationName),
              operation.support == .supported else {
            statusBar.message = "This filter's parameters cannot be edited here yet."
            return
        }
        endPendingEdits()
        statusBar.message = "\(operation.title)…"
        NativeFilterCatalog.shared.properties(for: operation, using: imageDocument.session) { [weak self] properties in
            guard let self, !self.imageDocument.isClosing else { return }
            guard let properties else {
                self.statusBar.message = "\(operation.title) is not available."
                NSSound.beep()
                return
            }
            // The gates can have changed while the catalog answered.
            guard !self.previewBusy, !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
                  !self.imageDocument.isSavingForClose, !self.imageDocument.isTransferringClipboard else {
                self.statusBar.message = "Apply or cancel the current filter first."
                return
            }
            self.startEffectPreview(title: operation.title, effect: effect, drawable: drawable,
                                    properties: properties) { [imageDocument] filter, values in
                NativeFilterPanel(document: imageDocument, operation: operation,
                                  properties: properties, filter: filter, initialValues: values)
            }
        }
    }

    @objc func zoomIn(_ sender: Any?) { zoom(to: ZoomLadder.zoomIn(from: canvas.zoomPercent)) }
    @objc func zoomOut(_ sender: Any?) { zoom(to: ZoomLadder.zoomOut(from: canvas.zoomPercent)) }
    @objc func actualPixels(_ sender: Any?) { zoom(to: ZoomLadder.actualPixels) }
    @objc func fitImage(_ sender: Any?) {
        window?.contentView?.layoutSubtreeIfNeeded()
        let viewport = scrollView.contentSize
        zoom(to: ZoomLadder.fit(imageWidth: Double(imageDocument.info.width), imageHeight: Double(imageDocument.info.height),
                               viewportWidth: Double(viewport.width), viewportHeight: Double(viewport.height),
                               backingFactor: Double(window?.backingScaleFactor ?? 1)))
        center(on: CGPoint(x: Double(imageDocument.info.width) / 2, y: Double(imageDocument.info.height) / 2))
    }

    @objc func gaussianBlur(_ sender: Any?) {
        guard !previewBusy, !imageDocument.isClosing, !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
              !imageDocument.isSavingForClose, !imageDocument.isTransferringClipboard else { return }
        endPendingEdits()
        startFilterPreview(title: "Gaussian Blur", operation: GaussianBlurPanel.operation) { [imageDocument] filter, _ in
            GaussianBlurPanel(document: imageDocument, filter: filter)
        }
    }

    /// Image ▸ New Snapshot: an independent copy opened as a new document.
    @objc func newSnapshot(_ sender: Any?) { imageDocument.newSnapshot() }

    /// A catalog item in a Filter category: opens its generic form.
    @objc func runNativeFilter(_ sender: Any?) {
        guard let command = (sender as? NSMenuItem)?.representedObject as? NativeFilterCommand else { return }
        openNativeFilter(command.operation)
    }

    /// Opens the operation's form after committing in-flight edits, so
    /// the filter session begins on the committed layer. Property rows
    /// load off the main queue through the catalog; the shared preview
    /// start then queues the session's begin and initial reads behind
    /// pending input, and the panel builds when they land.
    func openNativeFilter(_ operation: EngineSession.FilterOperation) {
        guard !previewBusy, !imageDocument.isClosing, !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
              !imageDocument.isSavingForClose, !imageDocument.isTransferringClipboard else { return }
        guard operation.support == .supported else {
            if let reason = NativeFilterMenuLayout.unavailableReason(operation.support) {
                statusBar.message = "\(operation.title) \(reason) — not supported yet."
            }
            return
        }
        endPendingEdits()
        statusBar.message = "\(operation.title)…"
        NativeFilterCatalog.shared.properties(for: operation, using: imageDocument.session) { [weak self] properties in
            guard let self, !self.imageDocument.isClosing else { return }
            guard let properties else {
                self.statusBar.message = "\(operation.title) is not available."
                NSSound.beep()
                return
            }
            // The gates can have changed while the catalog answered.
            guard !self.previewBusy, !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
                  !self.imageDocument.isSavingForClose, !self.imageDocument.isTransferringClipboard else {
                self.statusBar.message = "Apply or cancel the current filter first."
                return
            }
            self.startFilterPreview(title: operation.title, operation: operation.name,
                                    properties: properties) { [imageDocument] filter, values in
                NativeFilterPanel(document: imageDocument, operation: operation,
                                  properties: properties, filter: filter, initialValues: values)
            }
        }
    }

    // MARK: Layer menu

    @objc func newLayer(_ sender: Any?) { imageDocument.layerCommand(.new) }
    @objc func duplicateLayer(_ sender: Any?) { imageDocument.layerCommand(.duplicate) }
    @objc func deleteLayer(_ sender: Any?) { imageDocument.layerCommand(.delete) }
    @objc func bringLayerToFront(_ sender: Any?) { imageDocument.layerCommand(.toTop) }
    @objc func bringLayerForward(_ sender: Any?) { imageDocument.layerCommand(.raise) }
    @objc func sendLayerBackward(_ sender: Any?) { imageDocument.layerCommand(.lower) }
    @objc func sendLayerToBack(_ sender: Any?) { imageDocument.layerCommand(.toBottom) }
    @objc func mergeDown(_ sender: Any?) { imageDocument.layerCommand(.mergeDown) }
    @objc func flattenImage(_ sender: Any?) { imageDocument.layerCommand(.flatten) }

    /// Layer ▸ New Layer Group.
    @objc func newLayerGroup(_ sender: Any?) { imageDocument.createGroup() }

    // MARK: Layer mask menu

    /// Layer ▸ Mask ▸ Add…: the native source form on the active layer.
    @objc func addLayerMask(_ sender: Any?) {
        guard let window, let id = imageDocument.activeLayer else { return }
        AddMaskForm.present(for: imageDocument, on: window)
    }
    @objc func applyLayerMask(_ sender: Any?) { imageDocument.applyMask() }
    @objc func deleteLayerMask(_ sender: Any?) { imageDocument.deleteMask() }
    @objc func toggleMaskEnabled(_ sender: Any?) { imageDocument.toggleMaskEnabled() }
    @objc func toggleMaskEditing(_ sender: Any?) { imageDocument.toggleMaskEditing() }

    @objc func toggleQuickMask(_ sender: Any?) {
        imageDocument.setQuickMask(!(imageDocument.quickMaskState?.enabled ?? false))
    }

    @objc func saveSelectionAsChannel(_ sender: Any?) {
        guard let window else { return }
        endPendingEdits()
        ChannelForms.saveSelection(in: imageDocument, on: window)
    }

    func editChannelAttributes(_ id: Int32) {
        guard let window else { return }
        endPendingEdits()
        ChannelForms.edit(id, in: imageDocument, on: window)
    }
    @objc func toggleMaskShowing(_ sender: Any?) { imageDocument.toggleMaskShowing() }

    /// Layer ▸ Mask ▸ Mask to Selection ▸ …; the item's tag carries the
    /// operation's raw value.
    @objc func maskToSelection(_ sender: NSMenuItem) {
        guard let operation = EngineSession.SelectOperation(rawValue: UInt32(sender.tag)) else { return }
        imageDocument.maskToSelection(operation)
    }

    /// The active layer's mask state, when it has one.
    private var activeMask: EngineSession.MaskState? {
        guard let id = imageDocument.activeLayer else { return nil }
        return imageDocument.maskStates[id]
    }

    /// The active layer, when the menu has one to act on.
    private var activeLayerInfo: EngineSession.Layer? {
        guard let id = imageDocument.activeLayer else { return nil }
        return imageDocument.layers.first(where: { $0.id == id })
    }

    /// Layer ▸ Lock ▸ …: toggles the active item's own lock; the item's
    /// tag carries the lock's raw value.
    @objc func toggleLayerLock(_ sender: NSMenuItem) {
        guard let id = imageDocument.activeLayer else { return }
        imageDocument.toggleLocks(id, EngineSession.LayerLocks(rawValue: UInt32(sender.tag)))
    }

    /// What a lock item cannot see from its checkmark alone: locks a
    /// parent group or a layer inside enforces.
    static func lockNote(_ lock: EngineSession.LayerLocks,
                         sources: LayerTree.LockSources?) -> String? {
        guard let sources else { return nil }
        var notes: [String] = []
        if sources.inherited.contains(lock) { notes.append("locked by a parent group") }
        if sources.descendant.contains(lock) { notes.append("a layer inside is locked") }
        return notes.isEmpty ? nil : "\(LayerRowView.lockNames(lock).capitalized): \(notes.joined(separator: "; "))"
    }

    /// Name, opacity, blend mode and visibility of the selected layer.
    @objc func layerProperties(_ sender: Any?) {
        guard let window, let id = imageDocument.activeLayer,
              let layer = imageDocument.layers.first(where: { $0.id == id }) else { return }
        let name = NSTextField(string: layer.name)
        let opacity = NSTextField(string: String(Int((layer.opacity * 100).rounded())))
        let mode = NSPopUpButton(frame: .zero, pullsDown: false)
        mode.addItems(withTitles: Self.blendModes)
        mode.selectItem(withTitle: layer.mode)
        let visible = NSButton(checkboxWithTitle: "Visible", target: nil, action: nil)
        visible.state = layer.isVisible ? .on : .off
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Name:"), name],
            [NSTextField(labelWithString: "Opacity (%):"), opacity],
            [NSTextField(labelWithString: "Mode:"), mode],
            [NSGridCell.emptyContentView, visible],
        ])
        grid.column(at: 0).xPlacement = .trailing
        name.widthAnchor.constraint(equalToConstant: 180).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 280, height: 110)

        let alert = NSAlert()
        alert.messageText = "Layer Properties"
        alert.accessoryView = grid
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            var change = EngineSession.LayerChange()
            if name.stringValue != layer.name, !name.stringValue.isEmpty { change.name = name.stringValue }
            let newOpacity = min(max(opacity.doubleValue, 0), 100) / 100
            if abs(newOpacity - layer.opacity) > 0.001 { change.opacity = newOpacity }
            if let title = mode.titleOfSelectedItem, title != layer.mode { change.mode = title }
            if (visible.state == .on) != layer.isVisible { change.isVisible = visible.state == .on }
            if change != EngineSession.LayerChange() { self.imageDocument.changeLayer(id, change) }
        }
    }

    /// GIMP's default (non-legacy) layer modes by their engine nicks
    /// (GimpLayerMode in app/operations/operations-enums.c), in the order
    /// GIMP's mode menu groups them.
    /// Layer blend modes only: the engine's paint-only modes (behind,
    /// erase, merge, split) do not apply to layers.
    static let blendModes = ["normal", "dissolve",
                             "lighten-only", "luma-lighten-only", "screen", "dodge", "addition",
                             "darken-only", "luma-darken-only", "multiply", "burn", "linear-burn",
                             "overlay", "softlight", "hardlight", "vivid-light", "pin-light", "linear-light", "hard-mix",
                             "difference", "exclusion", "subtract", "grain-extract", "grain-merge", "divide",
                             "hsv-hue", "hsv-saturation", "hsl-color", "hsv-value",
                             "lch-hue", "lch-chroma", "lch-color", "lch-lightness", "luminance"]

    // MARK: Image size and transforms

    @objc func rotateImage90(_ sender: Any?) { imageDocument.transformImage(.rotate90) }
    @objc func rotateImage270(_ sender: Any?) { imageDocument.transformImage(.rotate270) }
    @objc func rotateImage180(_ sender: Any?) { imageDocument.transformImage(.rotate180) }
    @objc func flipImageHorizontally(_ sender: Any?) { imageDocument.transformImage(.flipHorizontal) }
    @objc func flipImageVertically(_ sender: Any?) { imageDocument.transformImage(.flipVertical) }
    @objc func rotateLayer90(_ sender: Any?) { imageDocument.transformActiveLayer(.rotate90) }
    @objc func rotateLayer270(_ sender: Any?) { imageDocument.transformActiveLayer(.rotate270) }
    @objc func rotateLayer180(_ sender: Any?) { imageDocument.transformActiveLayer(.rotate180) }
    @objc func flipLayerHorizontally(_ sender: Any?) { imageDocument.transformActiveLayer(.flipHorizontal) }
    @objc func flipLayerVertically(_ sender: Any?) { imageDocument.transformActiveLayer(.flipVertical) }

    @objc func imageSize(_ sender: Any?) {
        askSize("Image Size", constrain: true) { [weak self] width, height in
            self?.imageDocument.scale(toWidth: width, height: height)
        }
    }

    /// The canvas grows or shrinks around the image's center; the new area
    /// takes the background color, as in classic editors.
    @objc func canvasSize(_ sender: Any?) {
        askSize("Canvas Size", constrain: false) { [weak self] width, height in
            guard let self else { return }
            let info = self.imageDocument.info
            let offset = CGPoint(x: ((width - info.width) / 2), y: ((height - info.height) / 2))
            self.imageDocument.resizeCanvas(width: width, height: height, offset: offset,
                                            fill: ToolState.shared.background)
        }
    }

    /// A sheet asking for a width and height in pixels; with `constrain`
    /// the proportions stay linked until the box is unchecked.
    private func askSize(_ title: String, constrain: Bool, _ apply: @escaping (Int, Int) -> Void) {
        guard let window else { return }
        let info = imageDocument.info
        let width = NSTextField(string: String(info.width))
        let height = NSTextField(string: String(info.height))
        let link = NSButton(checkboxWithTitle: "Constrain proportions", target: nil, action: nil)
        link.state = constrain ? .on : .off
        let linker = ProportionLinker(width: width, height: height, ratio: Double(info.width) / Double(info.height), link: link)
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Width (px):"), width],
            [NSTextField(labelWithString: "Height (px):"), height],
            [NSGridCell.emptyContentView, link],
        ])
        grid.column(at: 0).xPlacement = .trailing
        width.widthAnchor.constraint(equalToConstant: 90).isActive = true
        grid.frame = NSRect(x: 0, y: 0, width: 260, height: 80)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Now \(info.width) × \(info.height) px."
        alert.accessoryView = grid
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = width
        alert.beginSheetModal(for: window) { response in
            withExtendedLifetime(linker) {}
            guard response == .alertFirstButtonReturn, width.integerValue > 0, height.integerValue > 0 else { return }
            apply(width.integerValue, height.integerValue)
        }
    }

    @objc func cropToSelection(_ sender: Any?) {
        guard let bounds = try? imageDocument.session.selectionBounds(image: imageDocument.image) else {
            statusBar.message = "Select the area to keep first."
            NSSound.beep()
            return
        }
        imageDocument.crop(to: bounds)
    }

    // MARK: Select menu

    @objc override func selectAll(_ sender: Any?) { imageDocument.select(.all) }
    @objc func selectNone(_ sender: Any?) { imageDocument.select(.none) }
    @objc func selectInverse(_ sender: Any?) { imageDocument.select(.invert) }
    @objc func sharpenSelection(_ sender: Any?) { imageDocument.select(.sharpen) }
    @objc func selectFromAlpha(_ sender: Any?) { imageDocument.select(.fromAlpha) }
    @objc func featherSelection(_ sender: Any?) { askRadius("Feather Selection", .feather, default: 5) }
    @objc func growSelection(_ sender: Any?) { askRadius("Grow Selection", .grow, default: 1) }
    @objc func shrinkSelection(_ sender: Any?) { askRadius("Shrink Selection", .shrink, default: 1) }
    @objc func borderSelection(_ sender: Any?) { askRadius("Border Selection", .border, default: 5) }

    /// A small sheet asking for a radius in pixels.
    private func askRadius(_ title: String, _ command: EngineSession.SelectCommand, default value: Double) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "Radius in pixels:"
        let field = NSTextField(string: String(Int(value)))
        field.frame = NSRect(x: 0, y: 0, width: 80, height: 22)
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn, field.doubleValue > 0 else { return }
            self?.imageDocument.select(command, radius: field.doubleValue)
        }
    }

    // MARK: Plug-in commands

    @objc func runPlugIn(_ sender: Any?) {
        guard let command = (sender as? NSMenuItem)?.representedObject as? PlugInCommand else { return }
        run(command.procedure, mode: .interactive)
    }

    @objc func repeatLastFilter(_ sender: Any?) {
        guard let last = PlugInCommands.last else { return }
        run(last, mode: .withLastValues)
    }

    @objc func reshowLastFilter(_ sender: Any?) {
        guard let last = PlugInCommands.last else { return }
        run(last, mode: .interactive)
    }

    /// Runs a plug-in command on this document, as its menu item does.
    func run(_ procedure: EngineSession.Procedure, mode: EngineSession.RunMode) {
        guard !PlugInCommands.isRunning, !EngineActivity.shared.isBusy, !imageDocument.isClosing else { return }
        guard !imageDocument.filterPreviewIsOpen else {
            statusBar.message = "Apply or cancel the filter preview first."
            return
        }
        NSApp.windows.forEach { $0.endEditing(for: nil) }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        let title = procedure.label.replacingOccurrences(of: "…", with: "")
        EngineActivity.shared.finishPendingInput()
        PlugInCommands.willRun(procedure, on: imageDocument)
        statusBar.message = mode == .interactive && procedure.label.hasSuffix("…")
            ? "\(title): waiting for its settings window" : "\(title)…"
        imageDocument.run(procedure, mode: mode) { [weak self] result in
            PlugInCommands.didRun(procedure, outcome: try? result.get())
            guard let self else { return }
            self.statusBar.hideProgress()
            switch result {
            case .success(.completed): self.stateDidChange()
            case .success(.cancelled): self.statusBar.message = "\(title) was cancelled."
            case .failure(let error): self.statusBar.message = "\(title): \(error)"
            }
        }
    }

    /// Progress of the plug-in command running on this document.
    func showProgress(_ progress: EngineSession.Progress?) {
        guard let progress else { return statusBar.hideProgress() }
        statusBar.showProgress(fraction: progress.fraction) { [weak self] in
            _ = self?.imageDocument.session.cancelProcedure()
        }
        if !progress.text.isEmpty {
            statusBar.message = progress.text
        }
    }

    /// Select ▸ From Path: the active path's area becomes the selection.
    @objc func selectFromPath(_ sender: Any?) {
        guard let path = imageDocument.activePath else { return }
        imageDocument.selectFromPath(path)
    }

    /// Edit ▸ Stroke Path: draws the active path on the active layer in the
    /// foreground color at the Path tool's stroke width.
    @objc func strokePath(_ sender: Any?) {
        guard let path = imageDocument.activePath else { return }
        imageDocument.strokePath(path, settings: ToolState.shared.pathLine)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let editingBlocked = imageDocument.isClosing || imageDocument.isSavingForClose
            || imageDocument.isTransferringClipboard || PlugInCommands.isRunning || EngineActivity.shared.isBusy || window?.attachedSheet != nil
        switch menuItem.action {
        case #selector(toggleQuickMask(_:)):
            menuItem.state = imageDocument.quickMaskState?.enabled == true ? .on : .off
            return !editingBlocked && !previewBusy
        case #selector(saveSelectionAsChannel(_:)):
            return !editingBlocked && !previewBusy
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualPixels(_:)), #selector(fitImage(_:)):
            return !imageDocument.isClosing
        case #selector(cut(_:)), #selector(copy(_:)), #selector(copyMerged(_:)),
             #selector(paste(_:)), #selector(pasteInPlace(_:)), #selector(deleteBackward(_:)):
            return canPerformClipboardCommand(menuItem.action)
        case #selector(selectFromPath(_:)), #selector(strokePath(_:)):
            return imageDocument.activePath != nil && !editingBlocked
        case #selector(newLayerGroup(_:)):
            return !editingBlocked && !previewBusy
        case #selector(toggleLayerLock(_:)):
            guard !editingBlocked, !previewBusy, let id = imageDocument.activeLayer else { return false }
            let lock = EngineSession.LayerLocks(rawValue: UInt32(menuItem.tag))
            let tree = LayerTree(layers: imageDocument.layers)
            let sources = tree.nodesByID[id].map { tree.lockSources(for: $0, states: imageDocument.layerLocks) }
            menuItem.state = sources?.local.contains(lock) == true ? .on : .off
            menuItem.toolTip = Self.lockNote(lock, sources: sources)
            return true
        case #selector(addLayerMask(_:)):
            guard !editingBlocked, !previewBusy, let layer = activeLayerInfo else { return false }
            return !layer.hasMask
        case #selector(applyLayerMask(_:)):
            guard !editingBlocked, !previewBusy, let layer = activeLayerInfo,
                  activeMask != nil else { return false }
            // Apply is raster-only: the engine refuses groups and text,
            // link and vector layers, so they never offer it.
            return layer.kind == .pixel
        case #selector(deleteLayerMask(_:)), #selector(maskToSelection(_:)):
            guard !editingBlocked, !previewBusy, let layer = activeLayerInfo else { return false }
            return layer.hasMask
        case #selector(toggleMaskEnabled(_:)), #selector(toggleMaskEditing(_:)),
             #selector(toggleMaskShowing(_:)):
            guard !editingBlocked, !previewBusy, let mask = activeMask else { return false }
            switch menuItem.action {
            case #selector(toggleMaskEnabled(_:)): menuItem.state = mask.enabled ? .on : .off
            case #selector(toggleMaskEditing(_:)): menuItem.state = mask.editing ? .on : .off
            default: menuItem.state = mask.showing ? .on : .off
            }
            return true
        case #selector(newSnapshot(_:)):
            // Without an app to adopt the copy there is nothing to run.
            return imageDocument.snapshotHandler != nil && !editingBlocked && !previewBusy
        case #selector(gaussianBlur(_:)):
            return !editingBlocked && !previewBusy
        case #selector(runNativeFilter(_:)):
            // Auxiliary-input and config operations stay listed but can't
            // open a form yet; their titles carry the reason.
            guard let command = menuItem.representedObject as? NativeFilterCommand,
                  command.operation.support == .supported else { return false }
            return !editingBlocked && !previewBusy && imageDocument.activeLayer != nil
        case #selector(repeatExport(_:)):
            menuItem.title = imageDocument.fileState.lastExportURL.map { "Export to \($0.lastPathComponent)" } ?? "Export Again…"
            return !editingBlocked && !previewBusy
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(exportDocument(_:)), #selector(saveDocumentCopy(_:)),
             #selector(openLayersFromFile(_:)):
            // A plug-in dialog is modal for the engine; file calls get BUSY.
            return !editingBlocked && !previewBusy
        case #selector(revertDocument(_:)):
            let source = imageDocument.fileState.revertSource
            menuItem.title = source?.menuTitle ?? "Revert…"
            // Untitled images and open previews have nothing to revert
            // or too much to discard silently; the sheet asks anyway,
            // so a pending load and every busy gate also refuse.
            return source != nil && revertHandler != nil && !revertIsPending
                && !editingBlocked && !previewBusy
        case #selector(placeLinkFromFile(_:)):
            // Link layers need GIMP 3.2; an unknown version stays enabled
            // and the facade's own UNSUPPORTED answer reports the rest.
            return !editingBlocked && !previewBusy && imageDocument.supportsLinkLayers != false
        case #selector(runPlugIn(_:)):
            // The engine runs no plug-in while a filter preview is open.
            guard let command = menuItem.representedObject as? PlugInCommand else { return false }
            return !editingBlocked && !previewBusy && imageDocument.canRun(command.procedure)
        case #selector(repeatLastFilter(_:)), #selector(reshowLastFilter(_:)):
            let base = menuItem.action == #selector(repeatLastFilter(_:)) ? "Last Filter" : "Last Filter Settings…"
            guard let last = PlugInCommands.last else {
                menuItem.title = base
                return false
            }
            let title = last.label.replacingOccurrences(of: "…", with: "")
            menuItem.title = menuItem.action == #selector(repeatLastFilter(_:))
                ? "Last Filter: \(title)" : "Last Filter Settings: \(title)…"
            return !editingBlocked && !previewBusy && imageDocument.canRun(last)
        case #selector(runGlimsPageSetup(_:)):
            // Page setup edits only the document's print info; it just
            // must not compete with another sheet on the same window.
            return !imageDocument.isClosing && pageLayout == nil && window?.attachedSheet == nil
        case #selector(printGlimsImage(_:)):
            return !editingBlocked && !previewBusy && !printJobIsOpen
        default:
            return !editingBlocked
        }
    }

    // MARK: Printing

    /// File ▸ Page Setup…: edits only this document's page layout —
    /// paper, orientation and margins. The image, its history and its
    /// file identity are untouched.
    @objc func runGlimsPageSetup(_ sender: Any?) {
        guard let window, !imageDocument.isClosing, pageLayout == nil,
              window.attachedSheet == nil else { return }
        // A copy: the sheet may edit the object it gets while it is up,
        // and only OK may change the document's settings.
        let printInfo = (imageDocument.printInfo.copy() as? NSPrintInfo) ?? imageDocument.printInfo
        if let runner = pageSetupRunner {
            runner(printInfo, window) { [weak self] newInfo in
                guard let self, let newInfo else { return }
                self.imageDocument.printInfo = newInfo
            }
            return
        }
        let layout = NSPageLayout()
        pageLayout = layout
        layout.beginSheet(with: printInfo, modalFor: window, delegate: self,
                          didEnd: #selector(pageLayoutDidEnd(_:returnCode:contextInfo:)),
                          contextInfo: nil)
    }

    @objc private func pageLayoutDidEnd(_ layout: NSPageLayout, returnCode: Int,
                                        contextInfo: UnsafeMutableRawPointer?) {
        pageLayout = nil
        guard returnCode == NSApplication.ModalResponse.OK.rawValue,
              let newInfo = layout.printInfo else { return }
        imageDocument.printInfo = newInfo
    }

    /// File ▸ Print…: renders the committed composite once behind every
    /// accepted edit, then opens the standard print panel as a sheet.
    /// The page shows the state Print was chosen at; later edits cannot
    /// smear across a page the way a live render could.
    @objc func printGlimsImage(_ sender: Any?) {
        guard let window, !imageDocument.isClosing, !printJobIsOpen, !previewBusy,
              !PlugInCommands.isRunning, !imageDocument.isSavingForClose,
              !imageDocument.isTransferringClipboard else { return }
        // A copy so later Page Setup changes cannot rewrite a page
        // that is already rendering.
        let printInfo = (imageDocument.printInfo.copy() as? NSPrintInfo) ?? imageDocument.printInfo
        printJobIsOpen = true
        statusBar.message = "Preparing to print…"
        imageDocument.preparePrintSnapshot(imageablePoints: printInfo.imageablePageBounds.size) {
            [weak self] result in
            self?.printPreparationDidFinish(result, printInfo: printInfo)
        }
    }

    private func printPreparationDidFinish(_ result: Result<PrintSnapshot, Error>,
                                           printInfo: NSPrintInfo) {
        // A close requested while the engine rendered takes precedence
        // over showing the panel.
        guard let window, !imageDocument.isClosing, !printJobDropped, closeCompletion == nil else {
            printJobDidFinish(printed: false)
            return
        }
        switch result {
        case .failure(let error):
            printJobIsOpen = false
            showStatusError(error.localizedDescription)
        case .success(let snapshot):
            let view = ImagePrintView(snapshot: snapshot, printInfo: printInfo,
                                      title: imageDocument.name)
            if let runner = printJobRunner {
                runner(view, printInfo, window) { [weak self] printed in
                    self?.printJobDidFinish(printed: printed)
                }
            } else {
                let operation = NSPrintOperation(view: view, printInfo: printInfo)
                operation.jobTitle = imageDocument.name
                activePrintOperation = operation
                operation.runModal(for: window, delegate: self,
                                   didRun: #selector(printOperation(_:didRunToSuccess:contextInfo:)),
                                   contextInfo: nil)
            }
        }
    }

    @objc private func printOperation(_ operation: NSPrintOperation, didRunToSuccess success: Bool,
                                      contextInfo: UnsafeMutableRawPointer?) {
        printJobDidFinish(printed: success)
    }

    /// The run ended — printed, cancelled or failed — or the job was
    /// dropped: the operation and its snapshot are released on every
    /// path. Cancellation stays silent like everywhere on macOS; the
    /// preparation status goes back to the document's either way.
    func printJobDidFinish(printed: Bool) {
        activePrintOperation = nil
        printJobIsOpen = false
        printJobDropped = false
        stateDidChange()
    }

    // MARK: File imports

    /// File ▸ Open as Layers…: one file, imported as layers.
    @objc func openLayersFromFile(_ sender: Any?) {
        askForImportFile(prompt: "Open", message: "Choose a file to open as layers.") { [weak self] url in
            self?.importChosenFile(url, asLink: false)
        }
    }

    /// File ▸ Place…: one file, placed as a link layer.
    /// Engines before GIMP 3.2 have no link layers; the menu already
    /// refuses them, and this guard keeps a programmatic trigger honest.
    @objc func placeLinkFromFile(_ sender: Any?) {
        guard imageDocument.supportsLinkLayers != false else {
            statusBar.message = "Linked layers are unavailable in this build. Use Open as Layers to import a copy."
            NSSound.beep()
            return
        }
        askForImportFile(prompt: "Place", message: "Choose a file to place as a link layer.") { [weak self] url in
            self?.importChosenFile(url, asLink: true)
        }
    }

    /// The import's file panel: one local file, presented as a sheet like
    /// Save's. Choosing commits in-flight edits first so the load sees
    /// the finished state; cancelling changes nothing.
    private func askForImportFile(prompt: String, message: String,
                                  _ chosen: @escaping (URL) -> Void) {
        guard let window, !imageDocument.isClosing else { return }
        endPendingEdits()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = prompt
        panel.message = message
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            chosen(url)
        }
    }

    /// Hands the chosen file to the document, which owns admission, the
    /// engine-wide busy gate and the facade call; the status line reports
    /// the outcome and any native error.
    private func importChosenFile(_ url: URL, asLink: Bool) {
        let name = url.lastPathComponent
        let completion: @MainActor (Result<ImageDocument.ImportOutcome, Error>) -> Void = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(.openedLayers):
                self.statusBar.message = "Opened layers from \(name)"
            case .success(.placedLink):
                self.statusBar.message = "Placed \(name) as a link layer"
            case .success(.cancelled):
                self.statusBar.message = asLink ? "Placing \(name) was cancelled."
                    : "Opening \(name) as layers was cancelled."
            case .failure(let error):
                self.showStatusError(String(describing: error))
            }
            self.stateDidChange()
        }
        if asLink {
            imageDocument.placeLink(from: url, completion: completion)
        } else {
            imageDocument.openLayers(from: url, completion: completion)
        }
    }

    // MARK: Saving, exporting and closing

    /// File ▸ Save: writes the image's native XCF; new and imported
    /// images have none yet, so Save falls through to Save As.
    @objc func saveDocument(_ sender: Any?) {
        performSave { _ in }
    }

    /// File ▸ Save As: always asks for the XCF file to write.
    @objc func saveDocumentAs(_ sender: Any?) {
        askSaveTarget { _ in }
    }

    /// The save flow Cmd-S and the close prompt share; `done` gets
    /// whether a file was actually written.
    private enum WritePurpose { case ordinary, closing }

    private func performSave(purpose: WritePurpose = .ordinary, done: @escaping @MainActor (Bool) -> Void) {
        guard canStartFileWrite(purpose: purpose) else { return done(false) }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        switch imageDocument.fileState.saveRoute {
        case .write(let url): saveTo(url, purpose: purpose, done: done)
        case .askForFile: askSaveTarget(purpose: purpose, done: done)
        }
    }

    private func askSaveTarget(purpose: WritePurpose = .ordinary, done: @escaping @MainActor (Bool) -> Void) {
        guard canStartFileWrite(purpose: purpose) else { return done(false) }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        guard let window else { return done(false) }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(importedAs: "org.gimp.xcf", conformingTo: .image)]
        savePanel.allowsOtherFileTypes = false
        savePanel.nameFieldStringValue = DocumentFileState.suggestedBaseName(imageDocument.name) + ".xcf"
        savePanel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self else { return done(false) }
            self.saveTo(url, purpose: purpose, done: done)
        }
    }

    /// Writes the XCF, then moves the name, the represented file and the
    /// dirty flag to it — a failed or cancelled save changes nothing.
    private func saveTo(_ url: URL, purpose: WritePurpose = .ordinary, done: @escaping @MainActor (Bool) -> Void) {
        guard canStartFileWrite(purpose: purpose) else { return done(false) }
        let release: () -> Void
        do { release = try reserveWrite?(url) ?? {} } catch {
            statusBar.message = error.localizedDescription
            return done(false)
        }
        statusBar.message = "Saving \(url.lastPathComponent)…"
        imageDocument.save(to: url) { [weak self] error in
            defer { release() }
            guard let self else { return done(false) }
            if let error {
                self.imageDocument.onError?(String(describing: error))
                return done(false)
            }
            self.imageDocument.noteSaved(to: url)
            self.window?.representedURL = url
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            self.statusBar.message = "Saved \(url.lastPathComponent)"
            self.stateDidChange()
            return done(true)
        }
    }

    private func canStartFileWrite(purpose: WritePurpose = .ordinary) -> Bool {
        guard !previewBusy, !PlugInCommands.isRunning, !EngineActivity.shared.isBusy, !imageDocument.isClosing,
              !imageDocument.isTransferringClipboard,
              !imageDocument.isSavingForClose || purpose == .closing else {
            statusBar.message = "Apply or cancel the current operation before saving or exporting."
            return false
        }
        // Commit field editors in floating palettes before taking a file
        // snapshot, just as the canvas text editor is committed below.
        NSApp.windows.forEach { $0.endEditing(for: nil) }
        return true
    }

    @objc func exportDocument(_ sender: Any?) {
        guard canStartFileWrite() else { return }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png, .jpeg, .tiff]
        savePanel.nameFieldStringValue = DocumentFileState.suggestedBaseName(imageDocument.name) + ".png"
        savePanel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self else { return }
            self.exportTo(url)
        }
    }

    @objc func repeatExport(_ sender: Any?) {
        guard let url = imageDocument.fileState.lastExportURL else { return exportDocument(sender) }
        exportTo(url)
    }

    private func exportTo(_ url: URL) {
        guard canStartFileWrite() else { return }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        let release: () -> Void
        do { release = try reserveWrite?(url) ?? {} } catch {
            statusBar.message = error.localizedDescription
            return
        }
        statusBar.message = "Exporting \(url.lastPathComponent)…"
        imageDocument.export(to: url) { [self] error in
            defer { release() }
            if let error { imageDocument.onError?(String(describing: error)) }
            else { statusBar.message = "Exported \(url.lastPathComponent)" }
        }
    }

    @objc func saveDocumentCopy(_ sender: Any?) {
        guard canStartFileWrite(), let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(importedAs: "org.gimp.xcf", conformingTo: .image)]
        panel.allowsOtherFileTypes = false
        panel.nameFieldStringValue = DocumentFileState.suggestedBaseName(imageDocument.name) + " copy.xcf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self, self.canStartFileWrite() else { return }
            self.canvas.tools.finishTextEditing()
            if self.imageDocument.strokeIsActive { self.imageDocument.endStroke() }
            let release: () -> Void
            do { release = try self.reserveWrite?(url) ?? {} } catch {
                self.statusBar.message = error.localizedDescription
                return
            }
            self.statusBar.message = "Saving a copy…"
            self.imageDocument.saveCopy(to: url) { error in
                defer { release() }
                if let error { self.imageDocument.onError?(String(describing: error)) }
                else { self.statusBar.message = "Saved a copy to \(url.lastPathComponent)" }
            }
        }
    }

    /// File ▸ Revert…: reloads the saved XCF — or the original file an
    /// imported image came from — from disk. The sheet is the only
    /// approval for discarding this document's edits; the confirmed
    /// load runs through the app's file admission, which replaces this
    /// window's document only once the new image is valid. A failed or
    /// refused load leaves this document fully usable.
    @objc func revertDocument(_ sender: Any?) {
        guard let window, window.attachedSheet == nil, !revertIsPending, !previewBusy,
              let revertHandler, let source = imageDocument.fileState.revertSource,
              !PlugInCommands.isRunning, !EngineActivity.shared.isBusy,
              !imageDocument.isClosing, !imageDocument.isSavingForClose,
              !imageDocument.isTransferringClipboard else { return }
        endPendingEdits()
        let fileName = source.url.lastPathComponent
        let alert = NSAlert()
        switch source {
        case .native:
            alert.messageText = "Revert to \u{201C}\(fileName)\u{201D}?"
            alert.informativeText = "All changes to \u{201C}\(imageDocument.name)\u{201D} since it was last saved will be lost, including the undo history."
        case .imported:
            alert.messageText = "Re-import \u{201C}\(fileName)\u{201D}?"
            alert.informativeText = "All changes to \u{201C}\(imageDocument.name)\u{201D} will be lost, including the undo history. The document is imported again from its original file."
        }
        alert.addButton(withTitle: "Revert")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn, !self.revertIsPending else { return }
            // The document's file cannot change under a sheet, but its
            // lifetime can; the source check also guards a re-open.
            guard let current = self.imageDocument.fileState.revertSource, current == source,
                  !self.imageDocument.isClosing else { return }
            self.revertIsPending = true
            revertHandler(source.url) { [weak self] result in
                guard let self else { return }
                self.revertIsPending = false
                if case .failure(let error) = result {
                    self.showStatusError(error.localizedDescription)
                }
            }
        }
    }

    /// A confirmed Revert's discard approval: no close path may ask to
    /// save this document again.
    func approveDiscard() { closeApproved = true }

    /// Closes the window without an unsaved-changes prompt; a
    /// confirmed revert already holds the discard approval. The
    /// ordinary close drain — preview cancellation, render reads and
    /// queued engine work — still applies.
    func closeDiscardingChanges() {
        closeApproved = true
        window?.close()
    }

    /// A confirmed revert's load is in flight: edits stay consented to
    /// discard, so a close during the load must not prompt again.
    private(set) var revertIsPending = false

    /// Whether the user already agreed to close: Don't Save, or a save
    /// that succeeded. The next close request goes through.
    private var closeApproved = false
    private var savePromptVisible = false
    private var closeCompletion: ((Bool) -> Void)?
    /// Set the moment the window begins closing, before the async
    /// teardown; a revert landing meanwhile must not adopt into it.
    private(set) var closeStarted = false
    /// A close asked for while the engine was busy waits for the idle
    /// gate; an adoption landing first must yield to it.
    private(set) var waitingForActivityToClose = false

    /// Quit and Close All share the same save/cancel flow as the close dot.
    /// Completion waits for both render reads and engine work to finish.
    func requestClose(completion: @escaping (Bool) -> Void) {
        guard closeCompletion == nil else { return completion(false) }
        closeCompletion = completion
        guard let window else { return finishCloseRequest(true) }
        if closeStarted { return }
        if windowShouldClose(window) { window.close() }
    }

    private func finishCloseRequest(_ closed: Bool) {
        let completion = closeCompletion
        closeCompletion = nil
        completion?(closed)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if EngineActivity.shared.isBusy {
            // A close during the snapshot render drops the print job;
            // the deferred close then continues without a print sheet.
            if printJobIsOpen { printJobDropped = true }
            if !waitingForActivityToClose {
                waitingForActivityToClose = true
                EngineActivity.shared.whenIdle { [weak self, weak sender] in
                    guard let self, let sender else { return }
                    self.waitingForActivityToClose = false
                    if self.windowShouldClose(sender) { sender.close() }
                }
            }
            return false
        }
        if imageDocument.isSavingForClose || savePromptVisible { return false }
        if sender.attachedSheet != nil {
            statusBar.message = "Finish or cancel the dialog before closing this image."
            finishCloseRequest(false)
            return false
        }
        guard !PlugInCommands.isRunning else {
            statusBar.message = "Finish or cancel the running filter before closing this image."
            NSSound.beep()
            finishCloseRequest(false)
            return false
        }
        NSApp.windows.forEach { $0.endEditing(for: nil) }
        canvas.tools.finishTextEditing()
        previewPanel?.cancel()
        cancelPendingPreview()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        if closeApproved || revertIsPending || !imageDocument.hasUnsavedChanges { return true }
        askToSaveChanges()
        return false
    }

    /// Save / Don't Save / Cancel for a document with unsaved changes.
    /// A cancelled or failed save keeps the window open.
    private func askToSaveChanges() {
        guard let window, !savePromptVisible else { return }
        savePromptVisible = true
        let alert = NSAlert()
        alert.messageText = "Do you want to keep the changes to \u{201C}\(imageDocument.name)\u{201D}?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.keyEquivalent = "\u{7f}"
        dontSave.keyEquivalentModifierMask = .command
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.savePromptVisible = false
            switch response {
            case .alertFirstButtonReturn: self?.saveThenClose()
            case .alertThirdButtonReturn: self?.approveClose()
            default: self?.finishCloseRequest(false)
            }
        }
    }

    private func saveThenClose() {
        guard canStartFileWrite() else { return finishCloseRequest(false) }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        guard imageDocument.beginCloseSave() else { return finishCloseRequest(false) }
        performSave(purpose: .closing) { [weak self] saved in
            guard let self else { return }
            if saved {
                self.approveClose()
            } else {
                let message = self.statusBar.message
                self.imageDocument.cancelCloseSave()
                self.statusBar.message = message
                self.finishCloseRequest(false)
            }
        }
    }

    private func approveClose() {
        closeApproved = true
        window?.close()
    }

    /// Edit ▸ Undo and Redo reach the engine through this (see
    /// `EngineUndoManager`).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        engineUndoManager
    }

    func windowDidBecomeMain(_ notification: Notification) {
        PaletteCenter.shared.frontDocumentDidChange()
    }

    func windowWillClose(_ notification: Notification) {
        closeStarted = true
        previewPanel?.cancel()
        cancelPendingPreview()
        canvas.stopRendering { [self] in
            imageDocument.closeImageWhenDrained {
                self.onClose?(self)
                self.finishCloseRequest(true)
            }
        }
    }
}

/// Keeps a width and height field in proportion while `link` is checked.
@MainActor
private final class ProportionLinker: NSObject, NSTextFieldDelegate {
    private let width: NSTextField
    private let height: NSTextField
    private let ratio: Double
    private let link: NSButton

    init(width: NSTextField, height: NSTextField, ratio: Double, link: NSButton) {
        self.width = width
        self.height = height
        self.ratio = ratio
        self.link = link
        super.init()
        width.delegate = self
        height.delegate = self
    }

    func controlTextDidChange(_ notification: Notification) {
        guard link.state == .on, ratio > 0, let field = notification.object as? NSTextField else { return }
        if field === width, width.integerValue > 0 {
            height.integerValue = max(1, Int((Double(width.integerValue) / ratio).rounded()))
        } else if field === height, height.integerValue > 0 {
            width.integerValue = max(1, Int((Double(height.integerValue) * ratio).rounded()))
        }
    }
}
