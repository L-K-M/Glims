import AppKit
import RigiUI

/// The phase 0 workspace: one classic document window with a placeholder
/// canvas and the status strip. It becomes the document window once the
/// engine adapter can open images.
@MainActor
final class WorkspaceWindowController: NSWindowController {

    let canvas = CanvasPlaceholderView()
    let statusBar = StatusBarView(frame: .zero)

    private(set) var zoomPercent = ZoomLadder.actualPixels {
        didSet {
            canvas.zoomPercent = zoomPercent
            statusBar.setZoom(percent: zoomPercent)
        }
    }

    init() {
        let window = ClassicWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
                                   styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                   backing: .buffered, defer: false)
        window.title = AppIdentity.name
        window.minSize = NSSize(width: 480, height: 320)
        window.setFrameAutosaveName("Glims.workspace")
        super.init(window: window)

        layOutContent(in: window)
        statusBar.message = "Engine not connected (phase 0)"
        statusBar.onZoomIn = { [weak self] in self?.zoomIn() }
        statusBar.onZoomOut = { [weak self] in self?.zoomOut() }
        statusBar.onZoomReset = { [weak self] in self?.resetZoom() }
        statusBar.setZoom(percent: zoomPercent)
        if !window.setFrameUsingName("Glims.workspace") { window.center() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func zoomIn() { zoomPercent = ZoomLadder.zoomIn(from: zoomPercent) }
    func zoomOut() { zoomPercent = ZoomLadder.zoomOut(from: zoomPercent) }
    func resetZoom() { zoomPercent = ZoomLadder.actualPixels }

    private func layOutContent(in window: NSWindow) {
        let content = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(canvas)
        content.addSubview(statusBar)

        NSLayoutConstraint.activate([
            canvas.topAnchor.constraint(equalTo: content.topAnchor),
            canvas.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            canvas.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: ClassicMetrics.statusBarHeight)
        ])
        window.contentView = content
    }
}
