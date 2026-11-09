import AppKit

@MainActor
final class CanvasRotationView: NSView {
    let canvas: NSView
    private var storedDegrees = 0.0
    private var layingOut = false

    var surroundColor: NSColor = .gray { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    var rotationDegrees: Double { storedDegrees }
    private static let epsilon: CGFloat = 1e-6

    init(canvas: NSView) {
        precondition(canvas.isFlipped, "CanvasRotationView requires a flipped canvas")
        self.canvas = canvas
        super.init(frame: .zero)
        wantsLayer = false
        canvas.removeFromSuperview()
        canvas.setFrameOrigin(.zero)
        addSubview(canvas)
        observeCanvas()
        layoutCanvas()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit { NotificationCenter.default.removeObserver(self) }

    @discardableResult
    func setRotationDegrees(_ degrees: Double) -> Bool {
        guard degrees.isFinite else { return false }
        storedDegrees = Self.normalize(degrees)
        layoutCanvas()
        return true
    }

    func layoutCanvas() {
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

    override func draw(_ dirtyRect: NSRect) {
        surroundColor.setFill()
        dirtyRect.fill()
    }

    private func observeCanvas() {
        canvas.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(canvasFrameChanged(_:)),
                                               name: NSView.frameDidChangeNotification, object: canvas)
    }

    @objc private func canvasFrameChanged(_ notification: Notification) {
        // NSView geometry changes happen synchronously on the main actor.
        // Origin corrections from layout must hit the same reentrancy guard.
        layoutCanvas()
    }

    static func rotatedSize(_ size: CGSize, degrees: Double) -> CGSize {
        let radians = degrees * .pi / 180
        let c = abs(cos(radians)), s = abs(sin(radians))
        return CGSize(width: size.width * c + size.height * s,
                      height: size.width * s + size.height * c)
    }

    private static func normalize(_ degrees: Double) -> Double {
        var value = degrees.truncatingRemainder(dividingBy: 360)
        if value >= 180 { value -= 360 }
        if value < -180 { value += 360 }
        if value == -0 { value = 0 }
        return value
    }
}
