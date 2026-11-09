import AppKit

@MainActor
public final class CanvasRotationView: NSView {
    public let canvas: NSView
    private var storedDegrees = 0.0
    private var layingOut = false
    private weak var observedCanvas: NSView?

    public var surroundColor: NSColor = .gray { didSet { needsDisplay = true } }
    public override var isFlipped: Bool { true }
    public var rotationDegrees: Double { storedDegrees }
    private static let epsilon: CGFloat = 1e-6

    public init(canvas: NSView) {
        precondition(canvas.isFlipped, "CanvasRotationView requires a flipped canvas")
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = false
        canvas.removeFromSuperview()
        canvas.setFrameOrigin(.zero)
        addSubview(canvas)
        observeCanvas(canvas)
        layoutCanvas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        if let observedCanvas, let center = NotificationCenter.default as NotificationCenter? {
            center.removeObserver(self, name: NSView.frameDidChangeNotification, object: observedCanvas)
        }
    }

    @discardableResult
    public func setRotationDegrees(_ degrees: Double) -> Bool {
        guard degrees.isFinite else { return false }
        storedDegrees = Self.normalize(degrees)
        canvas.frameRotation = storedDegrees
        layoutCanvas()
        return true
    }

    public func layoutCanvas() {
        guard !layingOut else { return }
        layingOut = true
        defer { layingOut = false }
        canvas.setFrameOrigin(.zero)
        canvas.frameRotation = storedDegrees
        let box = canvas.convert(canvas.bounds, to: self)
        canvas.setFrameOrigin(NSPoint(x: -box.minX, y: -box.minY))
        let size = NSSize(width: max(0, box.width), height: max(0, box.height))
        if abs(frame.size.width - size.width) > Self.epsilon || abs(frame.size.height - size.height) > Self.epsilon {
            setFrameSize(size)
        }
    }

    public override func draw(_ dirtyRect: NSRect) {
        surroundColor.setFill()
        dirtyRect.fill()
    }

    private func observeCanvas(_ canvas: NSView) {
        guard observedCanvas !== canvas else { return }
        let center = NotificationCenter.default
        if let observedCanvas {
            center.removeObserver(self, name: NSView.frameDidChangeNotification, object: observedCanvas)
        }
        observedCanvas = canvas
        canvas.postsFrameChangedNotifications = true
        center.addObserver(forName: NSView.frameDidChangeNotification, object: canvas, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.layoutCanvas() }
        }
    }

    private static func normalize(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value >= 180 { value -= 360 }
        if value < -180 { value += 360 }
        if value == -0 { value = 0 }
        return value
    }
}
