import AppKit
import RigiUI
import UniformTypeIdentifiers

/// A document window: the engine canvas in a scroll view above Rigi's status
/// strip. It handles the imageDocument's menu commands through the responder
/// chain.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let imageDocument: ImageDocument
    let canvas: EngineCanvasView
    let statusBar = StatusBarView(frame: .zero)
    private let scrollView = NSScrollView()
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
        window.contentView = content
    }

    @objc private func viewportChanged() {
        canvas.setNeedsRender()
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

    @objc func undo(_ sender: Any?) { imageDocument.undo() }
    @objc func redo(_ sender: Any?) { imageDocument.redo() }
    @objc func zoomIn(_ sender: Any?) { zoom(to: ZoomLadder.zoomIn(from: canvas.zoomPercent)) }
    @objc func zoomOut(_ sender: Any?) { zoom(to: ZoomLadder.zoomOut(from: canvas.zoomPercent)) }
    @objc func actualPixels(_ sender: Any?) { zoom(to: ZoomLadder.actualPixels) }

    @objc func gaussianBlur(_ sender: Any?) {
        guard blurPanel == nil, let panel = GaussianBlurPanel(document: imageDocument) else { return }
        panel.onFinish = { [weak self] in self?.blurPanel = nil }
        blurPanel = panel
        panel.showWindow(nil)
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

    func windowDidBecomeMain(_ notification: Notification) {
        PaletteCenter.shared.frontDocumentDidChange()
    }

    func windowWillClose(_ notification: Notification) {
        blurPanel?.cancel()
        try? imageDocument.session.closeImage(imageDocument.image)
        onClose?(self)
    }
}
