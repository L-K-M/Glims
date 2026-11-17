import CoreGraphics
import Foundation

/// The Polygon Lasso's click-to-place rules, free of AppKit state so they
/// can be unit-tested. Points are image pixels; the canvas supplies its
/// view-point scale where a rule is measured on screen.
enum PolygonLassoGeometry {
    /// How near the first corner, in view points, a click closes the
    /// polygon; the same reach the canvas uses for handles.
    static let closeReach: Double = 6

    /// The eight edge directions Shift allows, as exact unit vectors so a
    /// horizontal or vertical edge keeps its corner's other coordinate.
    private static let directions: [CGVector] = {
        let d = 0.5.squareRoot()
        return [CGVector(dx: 1, dy: 0), CGVector(dx: d, dy: d), CGVector(dx: 0, dy: 1), CGVector(dx: -d, dy: d),
                CGVector(dx: -1, dy: 0), CGVector(dx: -d, dy: -d), CGVector(dx: 0, dy: -1), CGVector(dx: d, dy: -d)]
    }()

    /// `point` constrained to the nearest multiple of 45 degrees from
    /// `anchor`, keeping its distance along that direction, as Shift does
    /// for the next edge in Photoshop's Polygon Lasso.
    static func constrained(_ point: CGPoint, from anchor: CGPoint) -> CGPoint {
        let dx = point.x - anchor.x, dy = point.y - anchor.y
        guard dx.isFinite, dy.isFinite, dx != 0 || dy != 0 else { return point }
        let octant = Int((atan2(dy, dx) / (Double.pi / 4)).rounded())
        let direction = directions[(octant % 8 + 8) % 8]
        let length = dx * direction.dx + dy * direction.dy
        return CGPoint(x: anchor.x + length * direction.dx, y: anchor.y + length * direction.dy)
    }

    /// Whether a click at `point` closes `corners`: there are at least
    /// three, and the click is within `closeReach` view points of the
    /// first at `scale` view points per image pixel.
    static func closes(_ corners: [CGPoint], at point: CGPoint, scale: Double) -> Bool {
        guard corners.count >= 3, let first = corners.first, scale.isFinite, scale > 0 else { return false }
        return hypot(point.x - first.x, point.y - first.y) * scale <= closeReach
    }
}
