import CoreGraphics

/// Pure geometry for a selection drag: the rectangle spanned between two
/// raw image-point coordinates, with no clipping or rounding.
enum SelectionDragGeometry {
    /// The drag rectangle from `start` to `end`. Shift (`constrained`) squares
    /// the drag by using the larger absolute axis extent on both axes;
    /// Option (`fromCenter`) treats `start` as the center and doubles the
    /// chosen extents. Returns nil when any input or intermediate bound
    /// (difference, extent, origin, far edge, size) is non-finite.
    static func rect(
        start: CGPoint,
        end: CGPoint,
        constrained: Bool,
        fromCenter: Bool
    ) -> CGRect? {
        guard start.x.isFinite, start.y.isFinite,
              end.x.isFinite, end.y.isFinite else { return nil }

        let dx = end.x - start.x
        let dy = end.y - start.y
        guard dx.isFinite, dy.isFinite else { return nil }

        let extentX: CGFloat
        let extentY: CGFloat
        if constrained {
            let extent = max(abs(dx), abs(dy))
            guard extent.isFinite else { return nil }
            extentX = directed(extent, along: dx)
            extentY = directed(extent, along: dy)
        } else {
            extentX = dx
            extentY = dy
        }
        guard extentX.isFinite, extentY.isFinite else { return nil }

        let size: CGSize
        let origin: CGPoint
        if fromCenter {
            size = CGSize(width: 2 * abs(extentX), height: 2 * abs(extentY))
            origin = CGPoint(x: start.x - abs(extentX),
                             y: start.y - abs(extentY))
        } else {
            size = CGSize(width: abs(extentX), height: abs(extentY))
            let far = CGPoint(x: start.x + extentX, y: start.y + extentY)
            guard far.x.isFinite, far.y.isFinite else { return nil }
            origin = CGPoint(x: min(start.x, far.x), y: min(start.y, far.y))
        }

        guard isFinite(origin: origin, size: size) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// `magnitude` signed in `delta`'s direction; a zero delta (including
    /// -0.0) deterministically takes the positive direction.
    private static func directed(_ magnitude: CGFloat, along delta: CGFloat) -> CGFloat {
        if delta == 0 { return magnitude }
        return delta > 0 ? magnitude : -magnitude
    }

    /// Validates the raw origin and size; the normalized accessors would mask
    /// invalid negative extents and non-finite far edges.
    private static func isFinite(origin: CGPoint, size: CGSize) -> Bool {
        guard origin.x.isFinite, origin.y.isFinite,
              size.width.isFinite, size.height.isFinite else { return false }
        return (origin.x + size.width).isFinite
            && (origin.y + size.height).isFinite
    }
}
