import AppKit

/// Keeps a small canvas centered in its surround while retaining ordinary
/// scrolling when the zoomed image is larger than the viewport.
final class CanvasClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        let constrained = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrained }
        return Self.centeredBounds(constrained, documentFrame: documentView.frame)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        scroll(to: constrainBoundsRect(bounds).origin)
    }

    static func centeredBounds(_ constrained: CGRect, documentFrame: CGRect) -> CGRect {
        var result = constrained
        if documentFrame.width < result.width {
            result.origin.x = (documentFrame.midX - result.width / 2).rounded(.down)
        }
        if documentFrame.height < result.height {
            result.origin.y = (documentFrame.midY - result.height / 2).rounded(.down)
        }
        return result
    }
}
