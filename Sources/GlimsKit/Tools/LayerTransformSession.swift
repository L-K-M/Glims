import CoreGraphics

/// The transform being built with the Transform tool: the selected layer's
/// box scaled, moved and turned by its handles until it is applied or
/// cancelled. Everything is in image pixels with y down, as the canvas
/// draws; nothing touches the engine until `matrix` is applied.
///
/// The box is scaled and moved first, then turned around its own center:
///
///     original ──fit──▶ box ──turn by `angle` around box center──▶ result
struct LayerTransformSession: Equatable {

    enum Handle: Equatable {
        /// 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left.
        case corner(Int)
        /// 0 top, 1 right, 2 bottom, 3 left.
        case edge(Int)
        case move
        case rotate
    }

    /// A drag in progress: where it started and the state it started from.
    struct Drag: Equatable {
        let handle: Handle
        let start: CGPoint
        fileprivate let box: CGRect
        fileprivate let angle: Double
    }

    /// The smallest box a scale handle can make, so the matrix stays
    /// invertible.
    static let minimumSide: Double = 1
    /// Shift-rotation snaps to multiples of this.
    static let rotationStep: Double = .pi / 12

    let layer: Int32
    /// The layer's bounds when the session began.
    let original: CGRect
    private(set) var box: CGRect
    /// Radians; positive turns clockwise on screen.
    private(set) var angle: Double = 0

    init(layer: Int32, bounds: CGRect) {
        precondition(bounds.width > 0 && bounds.height > 0, "A layer to transform has an area")
        self.layer = layer
        original = bounds
        box = bounds
    }

    var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }

    var isIdentity: Bool { box == original && angle == 0 }

    /// Maps the layer's pixels from where they are to where the handles put
    /// them.
    var matrix: CGAffineTransform {
        let fit = CGAffineTransform(translationX: -original.minX, y: -original.minY)
            .concatenating(CGAffineTransform(scaleX: box.width / original.width,
                                             y: box.height / original.height))
            .concatenating(CGAffineTransform(translationX: box.minX, y: box.minY))
        return fit.concatenating(Self.turn(angle, around: center))
    }

    /// The box's corners on the image: top-left, top-right, bottom-right,
    /// bottom-left.
    var corners: [CGPoint] {
        let turn = Self.turn(angle, around: center)
        return Self.corners(of: box).map { $0.applying(turn) }
    }

    /// The middles of the top, right, bottom and left edges on the image.
    var edgeMiddles: [CGPoint] {
        let points = corners
        return (0..<4).map { index in
            let a = points[index], b = points[(index + 1) % 4]
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
    }

    // MARK: Handles

    /// What a press at `point` grabs: a corner or an edge within
    /// `tolerance`, the box itself, or, outside it, the rotation.
    func handle(at point: CGPoint, tolerance: Double) -> Handle {
        if let index = corners.firstIndex(where: { Self.distance($0, point) <= tolerance }) {
            return .corner(index)
        }
        if let index = edgeMiddles.firstIndex(where: { Self.distance($0, point) <= tolerance }) {
            return .edge(index)
        }
        return box.contains(local(point, center: center, angle: angle)) ? .move : .rotate
    }

    func beginDrag(_ handle: Handle, at point: CGPoint) -> Drag {
        Drag(handle: handle, start: point, box: box, angle: angle)
    }

    /// Follows `drag` to `point`. `constrained` (Shift) keeps a corner's
    /// proportions and snaps rotation to 15°.
    mutating func update(_ drag: Drag, to point: CGPoint, constrained: Bool) {
        switch drag.handle {
        case .move:
            box = drag.box.offsetBy(dx: point.x - drag.start.x, dy: point.y - drag.start.y)
            angle = drag.angle

        case .rotate:
            let pivot = CGPoint(x: drag.box.midX, y: drag.box.midY)
            var turned = drag.angle + atan2(point.y - pivot.y, point.x - pivot.x)
                - atan2(drag.start.y - pivot.y, drag.start.x - pivot.x)
            if constrained {
                turned = (turned / Self.rotationStep).rounded() * Self.rotationStep
            }
            box = drag.box
            angle = turned

        case .corner(let index):
            scale(drag, cornerIndex: index, edgeIndex: nil, to: point, constrained: constrained)

        case .edge(let index):
            scale(drag, cornerIndex: nil, edgeIndex: index, to: point, constrained: false)
        }
    }

    /// Scales from the opposite corner or edge, which stays where it is on
    /// the image, measured in the box's own unturned frame.
    private mutating func scale(_ drag: Drag, cornerIndex: Int?, edgeIndex: Int?,
                                to point: CGPoint, constrained: Bool) {
        let start = drag.box
        let pivot = CGPoint(x: start.midX, y: start.midY)
        let p = local(point, center: pivot, angle: drag.angle)

        var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
        // Which sides follow the pointer: left/right and top/bottom.
        let (movesLeft, movesRight, movesTop, movesBottom): (Bool, Bool, Bool, Bool)
        switch (cornerIndex, edgeIndex) {
        case (0?, _): (movesLeft, movesRight, movesTop, movesBottom) = (true, false, true, false)
        case (1?, _): (movesLeft, movesRight, movesTop, movesBottom) = (false, true, true, false)
        case (2?, _): (movesLeft, movesRight, movesTop, movesBottom) = (false, true, false, true)
        case (3?, _): (movesLeft, movesRight, movesTop, movesBottom) = (true, false, false, true)
        case (_, 0?): (movesLeft, movesRight, movesTop, movesBottom) = (false, false, true, false)
        case (_, 1?): (movesLeft, movesRight, movesTop, movesBottom) = (false, true, false, false)
        case (_, 2?): (movesLeft, movesRight, movesTop, movesBottom) = (false, false, false, true)
        default: (movesLeft, movesRight, movesTop, movesBottom) = (true, false, false, false)
        }

        let side = Self.minimumSide
        if movesLeft { minX = min(p.x, maxX - side) }
        if movesRight { maxX = max(p.x, minX + side) }
        if movesTop { minY = min(p.y, maxY - side) }
        if movesBottom { maxY = max(p.y, minY + side) }

        if constrained, cornerIndex != nil {
            // The larger of the two stretches wins, for both sides.
            let factor = max((maxX - minX) / start.width, (maxY - minY) / start.height)
            let width = start.width * factor, height = start.height * factor
            if movesLeft { minX = maxX - width } else { maxX = minX + width }
            if movesTop { minY = maxY - height } else { maxY = minY + height }
        }

        var scaled = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // Turning happens around the box's center, which moved with the
        // scale; shift the box so the fixed side stays put on the image.
        let anchor = CGPoint(x: movesLeft ? start.maxX : (movesRight ? start.minX : start.midX),
                             y: movesTop ? start.maxY : (movesBottom ? start.minY : start.midY))
        let before = anchor.applying(Self.turn(drag.angle, around: pivot))
        let after = anchor.applying(Self.turn(drag.angle, around: CGPoint(x: scaled.midX, y: scaled.midY)))
        scaled = scaled.offsetBy(dx: before.x - after.x, dy: before.y - after.y)

        box = scaled
        angle = drag.angle
    }

    // MARK: Geometry

    /// `point` in the frame where the box is not turned.
    private func local(_ point: CGPoint, center: CGPoint, angle: Double) -> CGPoint {
        point.applying(Self.turn(-angle, around: center))
    }

    private static func turn(_ angle: Double, around center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}
