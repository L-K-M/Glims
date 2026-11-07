import AppKit

/// Stands in for the engine-backed canvas until the adapter exists: a neutral
/// gray surround with an empty image frame drawn at the current zoom. It owns
/// no image data and edits nothing.
final class CanvasPlaceholderView: NSView {

    /// The size of the empty frame at 100%, in points.
    private static let imageSize = NSSize(width: 640, height: 480)
    private static let surround = NSColor(calibratedWhite: 0.42, alpha: 1)

    var message = "Starting Glims…" { didSet { needsDisplay = true } }

    var zoomPercent = ZoomLadder.actualPixels {
        didSet { needsDisplay = true }
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        Self.surround.setFill()
        bounds.fill()

        let scale = CGFloat(zoomPercent) / 100
        let size = NSSize(width: Self.imageSize.width * scale, height: Self.imageSize.height * scale)
        let frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(),
                           y: ((bounds.height - size.height) / 2).rounded(),
                           width: size.width.rounded(), height: size.height.rounded())
        NSColor.white.setFill()
        frame.fill()
        NSColor(calibratedWhite: 0, alpha: 0.35).setStroke()
        NSBezierPath(rect: frame.insetBy(dx: -0.5, dy: -0.5)).stroke()

        let caption = message as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1)
        ]
        let captionSize = caption.size(withAttributes: attributes)
        guard frame.width > captionSize.width, frame.height > captionSize.height else { return }

        caption.draw(at: NSPoint(x: frame.midX - captionSize.width / 2,
                                 y: frame.midY - captionSize.height / 2),
                     withAttributes: attributes)
    }
}
