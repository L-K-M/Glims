import CoreGraphics
import Foundation

/// The transform being built with the Transform tool: the selected layer's
/// box scaled, moved, turned and warped by its handles until it is applied
/// or cancelled. Everything is in image pixels with y down, as the canvas
/// draws; nothing touches the engine until the pending transform is
/// applied.
///
/// The pending mapping of the layer's pixels is
///
///     H = A(box, angle) · W · N(original ──▶ unit square)
///
/// in column-vector order: `N` normalizes the original rectangle to the
/// unit square, `W` is a general unit-square warp owned by the skew,
/// distort and perspective modes, and `A` maps the unit square onto `box`,
/// then turns the result by `angle` around the box's center:
///
///     original ──N──▶ unit square ──W──▶ quad ──A──▶ result
///
/// `matrix` stays the affine frame `A · N` only — mathematically
/// unchanged from the pre-warp session and ignorant of `W`, so identity
/// warp reproduces the old affine coefficients and behavior exactly.
/// All new raster commit consumers must use `projectiveMatrix`, the full
/// homography.
struct LayerTransformSession: Equatable {

    enum Handle: Equatable {
        /// 0 top-left, 1 top-right, 2 bottom-right, 3 bottom-left.
        case corner(Int)
        /// 0 top, 1 right, 2 bottom, 3 left.
        case edge(Int)
        case move
        case rotate
    }

    /// Which handle geometry and drag semantics the session uses.
    /// `setMode` changes only this; all pending geometry carries over.
    enum Mode: CaseIterable, Equatable {
        /// The classic turned rectangle: handles sit on the affine frame
        /// and corner/edge drags scale it. Any warp stays attached to the
        /// frame unchanged.
        case scaleRotate
        /// Edge drags slide an edge along its own captured image
        /// direction; both endpoints follow and the opposite edge stays
        /// fixed. Corner handles are inactive.
        case skew
        /// Corner drags translate one image corner independently; edge
        /// drags translate both of the edge's corners by the same delta.
        case distort
        /// Corner drags move a corner pair symmetrically along one locked
        /// frame axis, forming a trapezoid. Edge handles are inactive.
        case perspective

        var title: String {
            switch self {
            case .scaleRotate: return "Scale / Rotate"
            case .skew: return "Skew"
            case .distort: return "Distort"
            case .perspective: return "Perspective"
            }
        }

        var menuTag: Int {
            switch self {
            case .scaleRotate: return 2001
            case .skew: return 2002
            case .distort: return 2003
            case .perspective: return 2004
            }
        }

        static func from(menuTag: Int) -> Self? {
            allCases.first { $0.menuTag == menuTag }
        }
    }

    /// The frame axis a perspective drag locked onto.
    enum PerspectiveAxis: Equatable {
        case horizontal, vertical
    }

    /// One line of the preview grid in image coordinates: the true image
    /// of a source third line under the homography.
    struct GridSegment: Equatable {
        let start: CGPoint
        let end: CGPoint
    }

    /// A drag in progress: where it started and the complete state it
    /// started from — frame, warp and mode — so returning to the press
    /// restores it exactly and a stale mode cannot write back.
    struct Drag: Equatable {
        let handle: Handle
        let start: CGPoint
        fileprivate let box: CGRect
        fileprivate let angle: Double
        fileprivate let warp: ProjectiveTransform
        fileprivate let mode: Mode
        /// The axis a perspective drag locked onto, kept here so it
        /// persists across the samples of one gesture when the caller
        /// holds the drag `inout` — no reference objects or globals fake
        /// that persistence.
        fileprivate var perspectiveAxis: PerspectiveAxis?
    }

    /// The smallest box a scale handle can make, so the matrix stays
    /// invertible.
    static let minimumSide: Double = 1
    /// The largest coordinate or side a numeric box edit accepts, so the
    /// derived matrix and turned corners stay well inside what the
    /// native affine transform can represent.
    static let maximumCoordinate: Double = 524288
    /// Shift-rotation snaps to multiples of this.
    static let rotationStep: Double = .pi / 12

    let layer: Int32
    /// The layer's bounds when the session began.
    let original: CGRect
    private(set) var box: CGRect
    /// Radians; positive turns clockwise on screen.
    private(set) var angle: Double = 0
    /// Which interaction mode owns the handles. Changed by `setMode`;
    /// drags captured under another mode are stale and ignored.
    private(set) var mode: Mode = .scaleRotate
    /// The unit-square warp `W` in `H = A · W · N`: identity for a pure
    /// scale/rotate session. Stored independently of the numeric frame so
    /// frame edits keep the warped shape.
    private var warp: ProjectiveTransform = .identity

    init(layer: Int32, bounds: CGRect) {
        precondition(bounds.width > 0 && bounds.height > 0, "A layer to transform has an area")
        self.layer = layer
        original = bounds
        box = bounds
    }

    var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }

    var isIdentity: Bool { box == original && angle == 0 && warp == .identity }

    /// The affine frame `A · N` only: maps the layer's original pixels
    /// onto the box, then turns them, ignoring `W`. Source-compatible and
    /// mathematically unchanged. **New raster commit consumers must use
    /// `projectiveMatrix`**; the two agree exactly when `W` is identity.
    var matrix: CGAffineTransform {
        let fit = CGAffineTransform(translationX: -original.minX, y: -original.minY)
            .concatenating(CGAffineTransform(scaleX: box.width / original.width,
                                             y: box.height / original.height))
            .concatenating(CGAffineTransform(translationX: box.minX, y: box.minY))
        return fit.concatenating(Self.turn(angle, around: center))
    }

    /// The full pending homography `A · W · N` mapping the layer's
    /// original pixels to the image — what a raster commit must apply.
    var projectiveMatrix: ProjectiveTransform {
        // Direct affine conversion: an identity warp is the frame exactly.
        if warp == .identity { return ProjectiveTransform(affine: matrix) }
        return Self.sourceToUnit(original)
            .followed(by: warp)
            .followed(by: ProjectiveTransform(affine: Self.frameAffine(box: box, angle: angle)))
    }

    /// The affine frame's corners on the image (the turned box):
    /// top-left, top-right, bottom-right, bottom-left. Independent of
    /// `warp`.
    var frameCorners: [CGPoint] {
        let turn = Self.turn(angle, around: center)
        return Self.corners(of: box).map { $0.applying(turn) }
    }

    /// The warped quad's corners on the image: the images of the original
    /// rectangle's corners under `projectiveMatrix`, in the same
    /// top-left, top-right, bottom-right, bottom-left order.
    var imageCorners: [CGPoint] {
        Self.imageQuad(warp: warp, box: box, angle: angle)
    }

    /// The handle corners for the current mode: the affine frame in
    /// `scaleRotate`, the actual warped quad otherwise.
    var corners: [CGPoint] {
        mode == .scaleRotate ? frameCorners : imageCorners
    }

    /// The middles of the top, right, bottom and left edges on the image.
    /// These are arithmetic midpoints of the edge's endpoint handles —
    /// deliberately not the images of the source edge midpoints, which a
    /// projective warp moves elsewhere.
    var edgeMiddles: [CGPoint] {
        let points = corners
        return (0..<4).map { index in
            let a = points[index], b = points[(index + 1) % 4]
            return CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
    }

    /// The image position of the point at normalized source position
    /// `unit` — (0,0) is the original top-left, (1,1) the bottom-right —
    /// or nil when it has no finite image.
    func imagePoint(atUnit unit: CGPoint) -> CGPoint? {
        warp.project(unit)?.applying(Self.frameAffine(box: box, angle: angle))
    }

    /// The transformed source third lines for the preview grid: two
    /// vertical, two horizontal, each mapped through the real homography.
    /// Straight lines stay straight under a homography, so endpoints
    /// suffice; interpolating between destination edges would not be the
    /// projective image of a third.
    var gridSegments: [GridSegment] {
        let thirds: [(CGPoint, CGPoint)] = [
            (CGPoint(x: 1.0 / 3, y: 0), CGPoint(x: 1.0 / 3, y: 1)),
            (CGPoint(x: 2.0 / 3, y: 0), CGPoint(x: 2.0 / 3, y: 1)),
            (CGPoint(x: 0, y: 1.0 / 3), CGPoint(x: 1, y: 1.0 / 3)),
            (CGPoint(x: 0, y: 2.0 / 3), CGPoint(x: 1, y: 2.0 / 3)),
        ]
        return thirds.compactMap { a, b in
            guard let start = imagePoint(atUnit: a), let end = imagePoint(atUnit: b)
            else { return nil }
            return GridSegment(start: start, end: end)
        }
    }

    /// Whether `point` lies inside the warped quad, boundary included,
    /// tested on the finite convex polygon itself.
    func containsImagePoint(_ point: CGPoint) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        let quad = imageCorners
        var sign = 0
        for index in 0..<4 {
            let a = quad[index], b = quad[(index + 1) % 4]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            guard cross.isFinite else { return false }
            if cross > 0 {
                if sign < 0 { return false }
                sign = 1
            } else if cross < 0 {
                if sign > 0 { return false }
                sign = -1
            }
        }
        return true
    }

    // MARK: Handles

    /// What a press at `point` grabs: a corner or an edge within
    /// `tolerance`, the shape itself, or, outside it, the rotation. The
    /// interior is the turned box in `scaleRotate` and the warped quad in
    /// the other modes.
    func handle(at point: CGPoint, tolerance: Double) -> Handle {
        if mode != .skew, let index = corners.firstIndex(where: { Self.distance($0, point) <= tolerance }) {
            return .corner(index)
        }
        if mode != .perspective, let index = edgeMiddles.firstIndex(where: { Self.distance($0, point) <= tolerance }) {
            return .edge(index)
        }
        let inside = mode == .scaleRotate
            ? box.contains(local(point, center: center, angle: angle))
            : containsImagePoint(point)
        return inside ? .move : .rotate
    }

    func beginDrag(_ handle: Handle, at point: CGPoint) -> Drag {
        Drag(handle: handle, start: point, box: box, angle: angle,
             warp: warp, mode: mode)
    }

    /// Follows `drag` to `point`. `constrained` (Shift) keeps a
    /// scale/rotate corner's proportions and snaps rotation to 15°.
    ///
    /// `drag` is `inout` so state the gesture latches — the perspective
    /// axis — persists across samples without reference objects or
    /// globals. A drag captured under another `mode` is stale and changes
    /// nothing, so it cannot overwrite a `setMode` that happened after
    /// the press.
    mutating func update(_ drag: inout Drag, to point: CGPoint, constrained: Bool) {
        guard drag.mode == mode,
              point.x.isFinite, point.y.isFinite,
              drag.start.x.isFinite, drag.start.y.isFinite else { return }
        switch drag.handle {
        case .corner(let index), .edge(let index):
            guard (0..<4).contains(index) else { return }
        default: break
        }
        // Validate the complete composed result for every mode, including
        // affine-frame movement, rotation and scaling after a warp. A bad
        // pointer sample must leave the last valid session intact. This
        // also checks the actual recomposed H after quad factorization.
        var candidate = self
        candidate.applyCapturedDrag(&drag, to: point, constrained: constrained)
        guard candidate.projectiveMatrix.projectedBounds(forSource: original) != nil
        else { return }
        self = candidate
    }

    /// Builds a candidate from the gesture capture. Only `update` assigns
    /// that candidate to the live session, after complete admission.
    private mutating func applyCapturedDrag(_ drag: inout Drag, to point: CGPoint,
                                           constrained: Bool) {
        // A handle can be picked within a tolerance of its exact position.
        // Stationary modifiers and a click/release must keep the captured
        // geometry; returning to the press restores it after movement too,
        // even after candidate updates that were rejected.
        if point == drag.start {
            restoreCapturedGeometry(drag)
            return
        }
        switch (drag.mode, drag.handle) {
        case (_, .move):
            box = drag.box.offsetBy(dx: point.x - drag.start.x, dy: point.y - drag.start.y)
            angle = drag.angle
            warp = drag.warp

        case (_, .rotate):
            let pivot = CGPoint(x: drag.box.midX, y: drag.box.midY)
            var turned = drag.angle + atan2(point.y - pivot.y, point.x - pivot.x)
                - atan2(drag.start.y - pivot.y, drag.start.x - pivot.x)
            if constrained {
                turned = (turned / Self.rotationStep).rounded() * Self.rotationStep
            }
            box = drag.box
            angle = turned
            warp = drag.warp

        case (.scaleRotate, .corner(let index)):
            scale(drag, cornerIndex: index, edgeIndex: nil, to: point, constrained: constrained)
            warp = drag.warp

        case (.scaleRotate, .edge(let index)):
            scale(drag, cornerIndex: nil, edgeIndex: index, to: point, constrained: false)
            warp = drag.warp

        case (.distort, _):
            distort(drag, to: point)
        case (.skew, _):
            skew(drag, to: point)
        case (.perspective, _):
            perspective(&drag, to: point)
        }
    }

    /// Compatibility wrapper for existing scale/rotate callers, which hold
    /// `Drag` by value. Perspective integration must keep a `var` `Drag`
    /// for the gesture and pass it `inout` (`update(&drag, ...)`): with
    /// this wrapper the latched axis is dropped after every sample and the
    /// drag could switch pairing mid-gesture.
    mutating func update(_ drag: Drag, to point: CGPoint, constrained: Bool) {
        var drag = drag
        update(&drag, to: point, constrained: constrained)
    }

    /// Switches handle semantics without touching pending geometry: frame,
    /// angle and warp all carry over, so `projectiveMatrix` is unchanged.
    /// Drags begun under the old mode are stale — `update` ignores them.
    mutating func setMode(_ newMode: Mode) {
        mode = newMode
    }

    /// Atomically replaces the box's origin, unrotated size and turn —
    /// the numeric fields in the Transform options. `degrees` is
    /// clockwise on screen and normalized to (-180, 180] before the
    /// radians conversion; width and height anchor the box at `origin`,
    /// so a size edit never moves the X/Y values. Refuses without
    /// changing anything when a value is non-finite, a side falls below
    /// `minimumSide`, a coordinate lies outside ±`maximumCoordinate`, or
    /// the derived matrix or turned corners could not be represented.
    @discardableResult
    mutating func setGeometry(origin: CGPoint, width: Double, height: Double,
                              degrees: Double) -> Bool {
        let bound = Self.maximumCoordinate
        guard origin.x.isFinite, origin.y.isFinite,
              width.isFinite, height.isFinite, degrees.isFinite,
              width >= Self.minimumSide, height >= Self.minimumSide,
              width <= bound, height <= bound,
              abs(origin.x) <= bound, abs(origin.y) <= bound,
              abs(origin.x + width) <= bound, abs(origin.y + height) <= bound
        else { return false }

        var normalized = degrees.truncatingRemainder(dividingBy: 360)
        if normalized <= -180 { normalized += 360 }
        else if normalized > 180 { normalized -= 360 }
        let radians = normalized * .pi / 180
        guard radians.isFinite else { return false }

        var candidate = self
        candidate.box = CGRect(x: origin.x, y: origin.y, width: width, height: height)
        candidate.angle = radians

        let matrix = candidate.matrix
        let determinant = matrix.a * matrix.d - matrix.b * matrix.c
        guard [matrix.a, matrix.b, matrix.c, matrix.d, matrix.tx, matrix.ty]
                .allSatisfy(\.isFinite),
              determinant.isFinite, abs(determinant) >= 1e-9 else { return false }
        // A turn around the center can swing a corner up to the half
        // diagonal past the box, so bound the result, not just the inputs.
        guard candidate.frameCorners.allSatisfy({
            $0.x.isFinite && $0.y.isFinite
                && abs($0.x) <= 2 * bound && abs($0.y) <= 2 * bound
        }) else { return false }

        let corners = candidate.frameCorners
        guard let minX = corners.map(\.x).min(), let maxX = corners.map(\.x).max(),
              let minY = corners.map(\.y).min(), let maxY = corners.map(\.y).max(),
              ceil(maxX) - floor(minX) <= bound, ceil(maxY) - floor(minY) <= bound else { return false }
        // A numeric edit keeps the warp: the composed homography must
        // still pass the shared projective admission (near plane,
        // determinant and output bounds) over the real source rectangle.
        guard candidate.projectiveMatrix
                .projectedBounds(forSource: candidate.original) != nil
        else { return false }
        self = candidate
        return true
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

    // MARK: Quad edits

    /// Distort: a corner drag translates just that captured image corner
    /// by the pointer delta — delta-based, so a press inside the handle
    /// tolerance does not jump. An edge drag translates the edge's two
    /// corners together by the same delta (a rigid slide); it never
    /// touches the frame. All other handles are inactive.
    private mutating func distort(_ drag: Drag, to point: CGPoint) {
        var quad = Self.imageQuad(warp: drag.warp, box: drag.box, angle: drag.angle)
        let delta = CGPoint(x: point.x - drag.start.x, y: point.y - drag.start.y)
        switch drag.handle {
        case .corner(let index):
            quad[index] = CGPoint(x: quad[index].x + delta.x, y: quad[index].y + delta.y)
        case .edge(let index):
            quad[index] = CGPoint(x: quad[index].x + delta.x, y: quad[index].y + delta.y)
            let next = (index + 1) % 4
            quad[next] = CGPoint(x: quad[next].x + delta.x, y: quad[next].y + delta.y)
        default:
            return
        }
        commit(warpedQuad: quad, captured: drag)
    }

    /// Skew: an edge drag slides the edge parallel to its captured image
    /// direction — the pointer delta is projected onto the edge's unit
    /// tangent and both endpoints move by that projection, so the opposite
    /// edge stays exactly fixed and a press inside the handle tolerance
    /// does not jump. Corner handles are inactive.
    private mutating func skew(_ drag: Drag, to point: CGPoint) {
        guard case .edge(let index) = drag.handle else { return }
        let captured = Self.imageQuad(warp: drag.warp, box: drag.box, angle: drag.angle)
        let a = captured[index], b = captured[(index + 1) % 4]
        let length = hypot(b.x - a.x, b.y - a.y)
        guard length.isFinite, length > 0 else { return }
        let tangent = CGPoint(x: (b.x - a.x) / length, y: (b.y - a.y) / length)
        let along = (point.x - drag.start.x) * tangent.x
            + (point.y - drag.start.y) * tangent.y
        guard along.isFinite else { return }
        if along == 0 {
            restoreCapturedGeometry(drag)
            return
        }
        var quad = captured
        quad[index] = CGPoint(x: a.x + tangent.x * along, y: a.y + tangent.y * along)
        quad[(index + 1) % 4] = CGPoint(x: b.x + tangent.x * along,
                                        y: b.y + tangent.y * along)
        commit(warpedQuad: quad, captured: drag)
    }

    /// Perspective: a corner drag moves the dragged corner and its paired
    /// corner in opposite equal directions along one axis of the captured
    /// frame, leaving the opposite edge fixed — a symmetric trapezoid.
    /// Horizontal movement pairs corners on the same top/bottom edge,
    /// vertical movement corners on the same left/right edge. The axis
    /// latches from the first nonzero local-frame movement (deterministic
    /// tie: horizontal) and lives in `drag`, so it can never switch
    /// mid-gesture. Edge handles are inactive.
    private mutating func perspective(_ drag: inout Drag, to point: CGPoint) {
        guard case .corner(let index) = drag.handle else { return }
        let pivot = CGPoint(x: drag.box.midX, y: drag.box.midY)
        // The pointer delta measured in the captured unturned frame.
        let from = local(drag.start, center: pivot, angle: drag.angle)
        let now = local(point, center: pivot, angle: drag.angle)
        let dx = now.x - from.x, dy = now.y - from.y
        guard dx.isFinite, dy.isFinite else { return }
        if drag.perspectiveAxis == nil {
            guard dx != 0 || dy != 0 else { return }
            drag.perspectiveAxis = abs(dx) >= abs(dy) ? .horizontal : .vertical
        }
        guard let axis = drag.perspectiveAxis else { return }
        if (axis == .horizontal ? dx : dy) == 0 {
            restoreCapturedGeometry(drag)
            return
        }
        // Horizontal: the other corner on the same top/bottom edge;
        // vertical: on the same left/right edge.
        let pair = axis == .horizontal ? [1, 0, 3, 2] : [3, 2, 1, 0]
        let toImage = Self.turn(drag.angle, around: .zero)
        let movement = (axis == .horizontal
                        ? CGPoint(x: dx, y: 0)
                        : CGPoint(x: 0, y: dy)).applying(toImage)
        var quad = Self.imageQuad(warp: drag.warp, box: drag.box, angle: drag.angle)
        quad[index] = CGPoint(x: quad[index].x + movement.x,
                              y: quad[index].y + movement.y)
        let partner = pair[index]
        quad[partner] = CGPoint(x: quad[partner].x - movement.x,
                                y: quad[partner].y - movement.y)
        commit(warpedQuad: quad, captured: drag)
    }

    /// Atomically replaces the warp so `A(captured frame) · W' · N`
    /// carries the original rectangle onto `points`. The candidate
    /// homography is solved and validated in actual source/image
    /// coordinates by `ProjectiveTransform.transform(from:toQuad:)` —
    /// strict convexity, preserved winding, near-plane, determinant and
    /// output-size admission — and only then factored into a unit warp,
    /// so the unit-square factor inherits the composed transform's
    /// admission rather than imposing its own. A rejected candidate
    /// leaves the last valid state untouched.
    private mutating func commit(warpedQuad points: [CGPoint], captured drag: Drag) {
        let quad = ProjectiveTransform.Quad(topLeft: points[0], topRight: points[1],
                                            bottomRight: points[2], bottomLeft: points[3])
        guard let transform = ProjectiveTransform.transform(from: original, toQuad: quad),
              let frameInverse = ProjectiveTransform(
                affine: Self.frameAffine(box: drag.box, angle: drag.angle)).inverse
        else { return }
        // W' = A⁻¹ · H' · N⁻¹: apply N⁻¹, then H', then A⁻¹.
        let candidate = Self.unitToSource(original)
            .followed(by: transform)
            .followed(by: frameInverse)
        guard candidate.coefficients.allSatisfy(\.isFinite) else { return }
        box = drag.box
        angle = drag.angle
        warp = candidate
    }

    // MARK: Geometry

    private mutating func restoreCapturedGeometry(_ drag: Drag) {
        box = drag.box
        angle = drag.angle
        warp = drag.warp
    }

    /// `point` in the frame where the box is not turned.
    private func local(_ point: CGPoint, center: CGPoint, angle: Double) -> CGPoint {
        point.applying(Self.turn(-angle, around: center))
    }

    private static func turn(_ angle: Double, around center: CGPoint) -> CGAffineTransform {
        CGAffineTransform(translationX: -center.x, y: -center.y)
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: center.x, y: center.y))
    }

    /// The unit square's corners — (0,0), (1,0), (1,1), (0,1) — matching
    /// the TL, TR, BR, BL order of `corners`.
    private static let unitCorners = [
        CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
        CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1),
    ]

    /// `N`: the original rectangle normalized to the unit square.
    private static func sourceToUnit(_ rect: CGRect) -> ProjectiveTransform {
        ProjectiveTransform(h00: 1 / rect.width, h01: 0, h02: -rect.minX / rect.width,
                            h10: 0, h11: 1 / rect.height, h12: -rect.minY / rect.height,
                            h20: 0, h21: 0, h22: 1)
    }

    /// `N⁻¹`: the unit square mapped back onto the original rectangle.
    private static func unitToSource(_ rect: CGRect) -> ProjectiveTransform {
        ProjectiveTransform(affine: CGAffineTransform(a: rect.width, b: 0, c: 0,
                                                    d: rect.height,
                                                    tx: rect.minX, ty: rect.minY))
    }

    /// `A`: the unit square mapped onto `box`, then turned by `angle`
    /// around the box's center — the frame part of `H = A · W · N`.
    private static func frameAffine(box: CGRect, angle: Double) -> CGAffineTransform {
        CGAffineTransform(a: box.width, b: 0, c: 0, d: box.height,
                          tx: box.minX, ty: box.minY)
            .concatenating(Self.turn(angle, around: CGPoint(x: box.midX, y: box.midY)))
    }

    /// The warped quad `A · W` applied to the unit square's corners, in
    /// TL, TR, BR, BL order — the image corners for a given frame/warp
    /// state, current or drag-captured. A stored warp is always
    /// admissible, so `warp.project` cannot fail; the frame corner is a
    /// defensive fallback that keeps the quad four-cornered.
    private static func imageQuad(warp: ProjectiveTransform, box: CGRect,
                                  angle: Double) -> [CGPoint] {
        let frame = frameAffine(box: box, angle: angle)
        let fallback = corners(of: box).map {
            $0.applying(Self.turn(angle, around: CGPoint(x: box.midX, y: box.midY)))
        }
        return unitCorners.enumerated().map { index, unit in
            warp.project(unit).map { $0.applying(frame) } ?? fallback[index]
        }
    }

    private static func corners(of rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }

    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }
}

/// The Transform options' numeric drafts: strict parsing and the
/// per-field reason a value cannot go into the box. Pure so the rules
/// are unit-testable without the palette.
enum TransformNumericInput {
    enum Field {
        case x, y, width, height, angle
    }

    /// Strictly parses a decimal number: an optional sign, digits, one
    /// decimal point or an exponent, with surrounding whitespace allowed.
    /// Non-finite results such as "1e999" are not numbers here.
    static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        // Double() also accepts hexadecimal floats ("0x10"), which a
        // decimal field must not.
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isNumber || "+-.eE".contains($0) }),
              let value = Double(trimmed), value.isFinite else { return nil }
        return value
    }

    /// Why `value` cannot go into `field`, or nil when it can. Geometry
    /// built from individually valid values is still validated as a
    /// whole by `LayerTransformSession.setGeometry`.
    static func problem(_ value: Double, for field: Field) -> String? {
        let bound = Int(LayerTransformSession.maximumCoordinate)
        switch field {
        case .x, .y:
            return abs(value) <= LayerTransformSession.maximumCoordinate ? nil
                : "Keep the position between \(-bound) and \(bound) px."
        case .width, .height:
            if value < LayerTransformSession.minimumSide {
                return "Keep the size at least \(Int(LayerTransformSession.minimumSide)) px."
            }
            return value <= LayerTransformSession.maximumCoordinate ? nil
                : "Keep the size at most \(bound) px."
        case .angle:
            return nil
        }
    }
}
