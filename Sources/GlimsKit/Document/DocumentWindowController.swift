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
    private lazy var engineUndoManager = EngineUndoManager(document: imageDocument)
    private var blurPanel: GaussianBlurPanel?
    var onClose: ((DocumentWindowController) -> Void)?
    let fileAccessID = UUID()
    var reserveWrite: ((URL) throws -> (() -> Void))?

    init(document imageDocument: ImageDocument) {
        self.imageDocument = imageDocument
        self.canvas = EngineCanvasView(document: imageDocument)

        let window = ClassicWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 680),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.minSize = NSSize(width: 360, height: 240)
        super.init(window: window)
        window.delegate = self
        window.representedURL = imageDocument.fileState.nativeURL

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
        statusBar.isZoomEditable = true
        statusBar.onZoomTo = { [weak self] percent in self?.zoom(to: ZoomLadder.clamped(percent)) }
        statusBar.setZoom(percent: canvas.zoomPercent)
        stateDidChange()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

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

    private func stateDidChange() {
        window?.title = Self.title(name: imageDocument.name, zoomPercent: canvas.zoomPercent,
                                   isDirty: imageDocument.hasUnsavedChanges,
                                   precision: imageDocument.info.precision)
        let undo = imageDocument.undoInfo.nextUndo.isEmpty ? "" : " · Undo \(imageDocument.undoInfo.nextUndo)"
        statusBar.message = "\(imageDocument.info.width) × \(imageDocument.info.height) px · \(imageDocument.info.layerCount) layer\(imageDocument.info.layerCount == 1 ? "" : "s")\(undo)"
        (PaletteCenter.shared.registeredPalette(for: LayersPaletteController.definition.kind))?.retarget()
        (PaletteCenter.shared.registeredPalette(for: PathsPaletteController.definition.kind))?.retarget()
        // Path shapes arrive with the state; the canvas draws them.
        canvas.needsDisplay = true
    }

    // MARK: Menu commands

    @objc override func deleteBackward(_ sender: Any?) { clearPixels(sender) }
    @objc override func cancelOperation(_ sender: Any?) {
        if let blurPanel { blurPanel.cancel() } else { super.cancelOperation(sender) }
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
        guard blurPanel == nil, !imageDocument.isClosing, !PlugInCommands.isRunning,
              !imageDocument.isSavingForClose, !imageDocument.isTransferringClipboard else { return }
        if canvas.tools.textEditor != nil {
            canvas.tools.finishTextEditing()
            imageDocument.inputQueue.async { [weak self] in
                DispatchQueue.main.async { self?.gaussianBlur(sender) }
            }
            return
        }
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
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
        guard !PlugInCommands.isRunning, !imageDocument.isClosing else { return }
        NSApp.windows.forEach { $0.endEditing(for: nil) }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        let title = procedure.label.replacingOccurrences(of: "…", with: "")
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
            || imageDocument.isTransferringClipboard || PlugInCommands.isRunning || window?.attachedSheet != nil
        switch menuItem.action {
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)), #selector(actualPixels(_:)), #selector(fitImage(_:)):
            return !imageDocument.isClosing
        case #selector(cut(_:)), #selector(copy(_:)), #selector(copyMerged(_:)),
             #selector(paste(_:)), #selector(pasteInPlace(_:)), #selector(deleteBackward(_:)):
            return canPerformClipboardCommand(menuItem.action)
        case #selector(selectFromPath(_:)), #selector(strokePath(_:)):
            return imageDocument.activePath != nil && !editingBlocked
        case #selector(gaussianBlur(_:)):
            return !editingBlocked
        case #selector(repeatExport(_:)):
            menuItem.title = imageDocument.fileState.lastExportURL.map { "Export to \($0.lastPathComponent)" } ?? "Export Again…"
            return !editingBlocked && blurPanel == nil
        case #selector(saveDocument(_:)), #selector(saveDocumentAs(_:)), #selector(exportDocument(_:)), #selector(saveDocumentCopy(_:)):
            // A plug-in dialog is modal for the engine; file calls get BUSY.
            return !editingBlocked && blurPanel == nil
        case #selector(runPlugIn(_:)):
            // The engine runs no plug-in while a filter preview is open.
            guard let command = menuItem.representedObject as? PlugInCommand else { return false }
            return !editingBlocked && blurPanel == nil && imageDocument.canRun(command.procedure)
        case #selector(repeatLastFilter(_:)), #selector(reshowLastFilter(_:)):
            let base = menuItem.action == #selector(repeatLastFilter(_:)) ? "Last Filter" : "Last Filter Settings…"
            guard let last = PlugInCommands.last else {
                menuItem.title = base
                return false
            }
            let title = last.label.replacingOccurrences(of: "…", with: "")
            menuItem.title = menuItem.action == #selector(repeatLastFilter(_:))
                ? "Last Filter: \(title)" : "Last Filter Settings: \(title)…"
            return !editingBlocked && blurPanel == nil && imageDocument.canRun(last)
        default:
            return !editingBlocked
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
                self.statusBar.message = String(describing: error)
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
        guard blurPanel == nil, !PlugInCommands.isRunning, !imageDocument.isClosing,
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
            statusBar.message = error.map { String(describing: $0) } ?? "Exported \(url.lastPathComponent)"
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
                self.statusBar.message = error.map { String(describing: $0) } ?? "Saved a copy to \(url.lastPathComponent)"
            }
        }
    }

    /// Whether the user already agreed to close: Don't Save, or a save
    /// that succeeded. The next close request goes through.
    private var closeApproved = false
    private var savePromptVisible = false
    private var closeCompletion: ((Bool) -> Void)?
    private var closeStarted = false

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
        blurPanel?.cancel()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        if closeApproved || !imageDocument.hasUnsavedChanges { return true }
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
        blurPanel?.cancel()
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
