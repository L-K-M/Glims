import AppKit

/// The document canvas: shows the engine's composited image at the current
/// zoom and turns pointer input into paint strokes.
///
/// Only the visible part is rendered, at the screen's backing scale, on a
/// background queue. Renders are coalesced: while one is in flight, further
/// requests mark the view stale and one more render follows.
@MainActor
final class EngineCanvasView: NSView {
    private static let surround = NSColor(calibratedWhite: 0.42, alpha: 1)

    let document: ImageDocument
    private let renderQueue = DispatchQueue(label: "ch.lkmc.Glims.canvas.render", qos: .userInteractive)

    private(set) var zoomPercent = ZoomLadder.actualPixels
    private var rendered: (image: CGImage, rect: CGRect)?
    private var renderInFlight = false
    private var renderStale = false

    /// Duration of the last completed render, for the performance pass.
    private(set) var lastRenderMilliseconds: Double = 0

    init(document: ImageDocument) {
        self.document = document
        super.init(frame: .zero)
        updateFrameSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var scale: Double { Double(zoomPercent) / 100 }

    func setZoom(percent: Int) {
        zoomPercent = percent
        rendered = nil
        updateFrameSize()
        setNeedsRender()
    }

    private func updateFrameSize() {
        setFrameSize(NSSize(width: (Double(document.info.width) * scale).rounded(.up),
                            height: (Double(document.info.height) * scale).rounded(.up)))
    }

    /// Called when the image changed (`rect` in image pixels) or the view moved.
    func imageDidChange(in rect: CGRect? = nil) {
        if let rect {
            let viewRect = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                  width: rect.width * scale, height: rect.height * scale)
            guard viewRect.intersects(visibleRect) else { return }
        }
        setNeedsRender()
    }

    func setNeedsRender() {
        if renderInFlight {
            renderStale = true
            return
        }
        startRender()
    }

    /// The visible area in device pixels of the scaled image, clipped to it.
    private func renderArea() -> (area: CGRect, viewRect: CGRect, deviceScale: Double)? {
        let backing = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
        let visible = visibleRect.intersection(bounds)
        guard !visible.isEmpty else { return nil }
        let area = CGRect(x: floor(visible.minX * backing), y: floor(visible.minY * backing),
                          width: ceil(visible.maxX * backing) - floor(visible.minX * backing),
                          height: ceil(visible.maxY * backing) - floor(visible.minY * backing))
        let viewRect = CGRect(x: area.minX / backing, y: area.minY / backing,
                              width: area.width / backing, height: area.height / backing)
        return (area, viewRect, scale * backing)
    }

    private func startRender() {
        guard let (area, viewRect, deviceScale) = renderArea() else { return }
        renderInFlight = true
        renderStale = false
        let session = document.session, image = document.image
        renderQueue.async {
            let start = DispatchTime.now()
            let result = try? session.render(image, scale: deviceScale, area: area)
            let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
            DispatchQueue.main.async {
                self.renderInFlight = false
                self.lastRenderMilliseconds = milliseconds
                if let result { self.rendered = (result, viewRect) }
                self.needsDisplay = true
                if self.renderStale { self.setNeedsRender() }
            }
        }
    }

    /// Renders the visible area synchronously; used by the engine smoke test.
    func renderNow() throws -> CGImage? {
        guard let (area, viewRect, deviceScale) = renderArea() else { return nil }
        let image = try document.session.render(document.image, scale: deviceScale, area: area)
        rendered = (image, viewRect)
        needsDisplay = true
        return image
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setNeedsRender()
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.surround.setFill()
        dirtyRect.fill()
        guard let rendered, let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // The view is flipped; CGImage draws bottom-up.
        context.translateBy(x: rendered.rect.minX, y: rendered.rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .none
        context.draw(rendered.image, in: CGRect(origin: .zero, size: rendered.rect.size))
        context.restoreGState()
    }

    // MARK: Painting

    private func strokePoint(for event: NSEvent) -> EngineSession.StrokePoint {
        let location = convert(event.locationInWindow, from: nil)
        let isTablet = event.subtype == .tabletPoint
        return EngineSession.StrokePoint(
            x: Double(location.x) / scale, y: Double(location.y) / scale,
            pressure: isTablet ? Double(event.pressure) : 1,
            xTilt: isTablet ? Double(event.tilt.x) : 0,
            yTilt: isTablet ? Double(event.tilt.y) : 0,
            timeMilliseconds: UInt32(truncatingIfNeeded: Int(event.timestamp * 1000)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        document.beginStroke(at: strokePoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        document.continueStroke([strokePoint(for: event)])
    }

    override func mouseUp(with event: NSEvent) {
        document.continueStroke([strokePoint(for: event)])
        document.endStroke()
    }
}
