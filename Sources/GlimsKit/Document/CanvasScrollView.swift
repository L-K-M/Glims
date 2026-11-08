import AppKit

/// Keeps native ruler slots outside the editable viewport, including on
/// AppKit versions that tile them over the clip view with zero insets.
final class CanvasScrollView: NSScrollView {
    override func tile() {
        let previousFrame = contentView.frame
        let previousBounds = contentView.bounds
        super.tile()
        guard rulersVisible else { return }

        let base = contentView.frame
        let horizontal = hasHorizontalRuler ? horizontalRulerView : nil
        let vertical = hasVerticalRuler ? verticalRulerView : nil
        let reserveHorizontal = horizontal.map { base.intersects($0.frame) } ?? false
        let reserveVertical = vertical.map { base.intersects($0.frame) } ?? false
        guard reserveHorizontal || reserveVertical else { return }

        let height = reserveHorizontal ? min(base.height, horizontal?.requiredThickness ?? 0) : 0
        let width = reserveVertical ? min(base.width, vertical?.requiredThickness ?? 0) : 0
        var viewport = base
        viewport.origin.x += width
        viewport.size.width -= width
        viewport.size.height -= height
        if isFlipped { viewport.origin.y += height }
        contentView.frame = viewport

        if reserveHorizontal, let horizontal {
            horizontal.frame = NSRect(x: viewport.minX,
                                      y: isFlipped ? base.minY : base.maxY - height,
                                      width: viewport.width, height: height)
        }
        if reserveVertical, let vertical {
            vertical.frame = NSRect(x: base.minX, y: viewport.minY,
                                    width: width, height: viewport.height)
        }

        // A tile with unchanged final geometry must not nudge a scrolled
        // image when the superclass temporarily expands its clip view.
        if viewport == previousFrame {
            contentView.scroll(to: contentView.constrainBoundsRect(previousBounds).origin)
        }
    }
}
