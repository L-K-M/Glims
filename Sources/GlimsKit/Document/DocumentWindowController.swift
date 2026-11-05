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
    let statusBar = StatusBarView(frame: .zero)
    private let scrollView = NSScrollView()
    private let progressView = PlugInProgressView(frame: .zero)
    private lazy var engineUndoManager = EngineUndoManager(document: imageDocument)
    private var blurPanel: GaussianBlurPanel?
    var onClose: ((DocumentWindowController) -> Void)?

    init(document imageDocument: ImageDocument) {
        self.imageDocument = imageDocument
        self.canvas = EngineCanvasView(document: imageDocument)

        let window = ClassicWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.minSize = NSSize(width: 360, height: 240)
        super.init(window: window)
        window.delegate = self

        layOutContent(in: window)
        imageDocument.onProjectionChange = { [weak self] rect in self?.canvas.imageDidChange(in: rect) }
        imageDocument.onStateChange = { [weak self] in self?.stateDidChange() }
        imageDocument.onError = { [weak self] message in self?.statusBar.message = message }
        imageDocument.onSelectionChange = { [weak self] in
            guard let self else { return }
            self.canvas.selectionOutline = self.imageDocument.selectionOutline
        }
        imageDocument.onSizeChange = { [weak self] in
            self?.canvas.imageSizeDidChange()
            self?.stateDidChange()
        }
        canvas.tools.onStatus = { [weak self] message in self?.statusBar.message = message }
        canvas.tools.onZoom = { [weak self] zoomIn, point in
            guard let self else { return }
            self.zoom(to: zoomIn ? ZoomLadder.zoomIn(from: self.canvas.zoomPercent)
                                 : ZoomLadder.zoomOut(from: self.canvas.zoomPercent))
            self.center(on: point)
        }
        statusBar.onZoomIn = { [weak self] in self?.zoom(to: ZoomLadder.zoomIn(from: self?.canvas.zoomPercent ?? 100)) }
        statusBar.onZoomOut = { [weak self] in self?.zoom(to: ZoomLadder.zoomOut(from: self?.canvas.zoomPercent ?? 100)) }
        statusBar.onZoomReset = { [weak self] in self?.zoom(to: ZoomLadder.actualPixels) }
        statusBar.setZoom(percent: canvas.zoomPercent)
        stateDidChange()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func layOutContent(in window: NSWindow) {
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

        progressView.translatesAutoresizingMaskIntoConstraints = false
        progressView.onStop = { [weak self] in self?.imageDocument.session.cancelProcedure() }
        statusBar.addSubview(progressView)
        NSLayoutConstraint.activate([
            progressView.trailingAnchor.constraint(equalTo: statusBar.trailingAnchor,
                                                   constant: -PlugInProgressView.zoomControlAllowance),
            progressView.centerYAnchor.constraint(equalTo: statusBar.centerYAnchor),
        ])
        window.contentView = content
    }

    @objc private func viewportChanged() {
        canvas.setNeedsRender()
    }

    /// Scrolls so `point` (image pixels) is in the middle of the view.
    func center(on point: CGPoint) {
        let visible = scrollView.contentView.bounds
        canvas.scroll(NSPoint(x: point.x * canvas.scale - visible.width / 2,
                              y: point.y * canvas.scale - visible.height / 2))
    }

    func zoom(to percent: Int) {
        canvas.setZoom(percent: percent)
        statusBar.setZoom(percent: percent)
        stateDidChange()
    }

    /// Classic title and status: `name @ 100% (RGB, u8-non-linear)`.
    static func title(name: String, zoomPercent: Int, info: EngineSession.ImageInfo) -> String {
        "\(info.isDirty ? "• " : "")\(name) @ \(zoomPercent)% (RGB, \(info.precision))"
    }

    private func stateDidChange() {
        window?.title = Self.title(name: imageDocument.name, zoomPercent: canvas.zoomPercent, info: imageDocument.info)
        let undo = imageDocument.undoInfo.nextUndo.isEmpty ? "" : " · Undo \(imageDocument.undoInfo.nextUndo)"
        statusBar.message = "\(imageDocument.info.width) × \(imageDocument.info.height) px · \(imageDocument.info.layerCount) layer\(imageDocument.info.layerCount == 1 ? "" : "s")\(undo)"
        (PaletteCenter.shared.registeredPalette(for: LayersPaletteController.definition.kind))?.retarget()
    }

    // MARK: Menu commands

    @objc func zoomIn(_ sender: Any?) { zoom(to: ZoomLadder.zoomIn(from: canvas.zoomPercent)) }
    @objc func zoomOut(_ sender: Any?) { zoom(to: ZoomLadder.zoomOut(from: canvas.zoomPercent)) }
    @objc func actualPixels(_ sender: Any?) { zoom(to: ZoomLadder.actualPixels) }

    @objc func gaussianBlur(_ sender: Any?) {
        guard blurPanel == nil else { return }
        guard let panel = GaussianBlurPanel(document: imageDocument) else {
            statusBar.message = "Gaussian Blur could not start on this layer."
            NSSound.beep()
            return
        }
        panel.onFinish = { [weak self] in self?.blurPanel = nil }
        blurPanel = panel
        panel.showWindow(nil)
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
    static let blendModes = ["normal", "dissolve", "behind",
                             "lighten-only", "luma-lighten-only", "screen", "dodge", "addition",
                             "darken-only", "luma-darken-only", "multiply", "burn", "linear-burn",
                             "overlay", "softlight", "hardlight", "vivid-light", "pin-light", "linear-light", "hard-mix",
                             "difference", "exclusion", "subtract", "grain-extract", "grain-merge", "divide",
                             "hsv-hue", "hsv-saturation", "hsl-color", "hsv-value",
                             "lch-hue", "lch-chroma", "lch-color", "lch-lightness", "luminance"]

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
        guard !PlugInCommands.isRunning else { return }
        let title = procedure.label.replacingOccurrences(of: "…", with: "")
        PlugInCommands.willRun(procedure, on: imageDocument)
        statusBar.message = mode == .interactive && procedure.label.hasSuffix("…")
            ? "\(title): waiting for its settings window" : "\(title)…"
        imageDocument.run(procedure, mode: mode) { [weak self] result in
            PlugInCommands.didRun(procedure, outcome: try? result.get())
            guard let self else { return }
            self.progressView.show(nil)
            switch result {
            case .success(.completed): self.stateDidChange()
            case .success(.cancelled): self.statusBar.message = "\(title) was cancelled."
            case .failure(let error): self.statusBar.message = "\(title): \(error)"
            }
        }
    }

    /// Progress of the plug-in command running on this document.
    func showProgress(_ progress: EngineSession.Progress?) {
        progressView.show(progress)
        if let progress, !progress.text.isEmpty {
            statusBar.message = progress.text
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(gaussianBlur(_:)):
            return !PlugInCommands.isRunning
        case #selector(runPlugIn(_:)):
            // The engine runs no plug-in while a filter preview is open.
            guard let command = menuItem.representedObject as? PlugInCommand else { return false }
            return !PlugInCommands.isRunning && blurPanel == nil && imageDocument.canRun(command.procedure)
        case #selector(repeatLastFilter(_:)), #selector(reshowLastFilter(_:)):
            let base = menuItem.action == #selector(repeatLastFilter(_:)) ? "Last Filter" : "Last Filter Settings…"
            guard let last = PlugInCommands.last else {
                menuItem.title = base
                return false
            }
            let title = last.label.replacingOccurrences(of: "…", with: "")
            menuItem.title = menuItem.action == #selector(repeatLastFilter(_:))
                ? "Last Filter: \(title)" : "Last Filter Settings: \(title)…"
            return !PlugInCommands.isRunning && blurPanel == nil && imageDocument.canRun(last)
        default:
            return true
        }
    }

    @objc func exportDocument(_ sender: Any?) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.png, .jpeg, .tiff]
        savePanel.nameFieldStringValue = (imageDocument.name as NSString).deletingPathExtension + ".png"
        savePanel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self else { return }
            self.statusBar.message = "Exporting \(url.lastPathComponent)…"
            self.imageDocument.export(to: url) { error in
                self.statusBar.message = error.map { String(describing: $0) } ?? "Exported \(url.lastPathComponent)"
            }
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [UTType(filenameExtension: "xcf") ?? .data]
        savePanel.nameFieldStringValue = (imageDocument.name as NSString).deletingPathExtension + ".xcf"
        savePanel.beginSheetModal(for: window!) { [weak self] response in
            guard response == .OK, let url = savePanel.url, let self else { return }
            self.imageDocument.save(to: url) { error in
                self.statusBar.message = error.map { String(describing: $0) } ?? "Saved \(url.lastPathComponent)"
                try? self.imageDocument.reload()
            }
        }
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
        blurPanel?.cancel()
        try? imageDocument.session.closeImage(imageDocument.image)
        onClose?(self)
    }
}
