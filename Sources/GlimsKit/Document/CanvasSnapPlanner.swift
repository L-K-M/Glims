import CoreGraphics

/// Pure translation-snapping planning for the canvas: given a moving
/// layer's rect already at its proposed translated position in image
/// coordinates, decide how far (if at all) to correct the translation so
/// one of the rect's edges or its centre lands on a snap target.
///
/// Everything here is arithmetic over image coordinates: no AppKit view
/// state, no engine call, nothing that can mutate image pixels, the file,
/// the dirty flag, history, selection, export or print. The caller (a
/// future tool controller) applies `Result.dx`/`dy` to the translation
/// and draws the matched indicator lines at `AxisMatch.targetCoordinate`.
///
/// Deliberate fallback behavior for damaged input: when any geometry or
/// configuration value is non-finite or degenerate, or the canvas scale
/// is not finite and positive, `plan` returns `Result.none` — zero
/// corrections and no matches. Corrections are therefore never NaN or
/// overflow: a matched correction is bounded by the finite image-space
/// tolerance.
enum CanvasSnapPlanner {
    /// The default snap tolerance, in view points: a candidate line
    /// snaps when the nearest moving anchor is within this many view
    /// points of it, converted to image units by `canvasScale`.
    static let defaultViewPointTolerance: Double = 8

    /// The largest lattice index the grid math accepts: 2^53, the last
    /// magnitude at which every integer is exactly representable as a
    /// Double. Larger quotients are rejected, never looped over.
    private static let maximumLatticeIndex: Double = 9007199254740992

    /// Which candidate lines may snap. Each kind is configured
    /// independently; kinds not in `targets` contribute no candidates.
    struct Target: OptionSet, Equatable {
        let rawValue: Int
        /// The image bounds' edges on the axis (min and max).
        static let imageEdge = Target(rawValue: 1 << 0)
        /// The image bounds' centre on the axis.
        static let imageCenter = Target(rawValue: 1 << 1)
        /// Guide lines on the axis.
        static let guide = Target(rawValue: 1 << 2)
        /// The display grid's lattice lines on the axis.
        static let grid = Target(rawValue: 1 << 3)
        /// Other layers' edges on the axis (min and max of each rect).
        static let layerEdge = Target(rawValue: 1 << 4)
        /// Other layers' centres on the axis.
        static let layerCenter = Target(rawValue: 1 << 5)
        /// Every kind.
        static let all: Target = [.imageEdge, .imageCenter, .guide, .grid, .layerEdge, .layerCenter]
    }

    /// The display grid's lattice on both axes, in image coordinates:
    /// lines sit at `offset + k * spacing` for integer k. Spacings must
    /// be finite and strictly positive, offsets finite.
    struct Grid: Equatable {
        var spacingX: Double
        var spacingY: Double
        var offsetX: Double
        var offsetY: Double
    }

    /// One planning request, all in image coordinates.
    struct Input: Equatable {
        /// The moving layer's rect, already at the proposed translated
        /// position. Must be finite with positive width and height.
        var movingRect: CGRect
        /// The image's bounds. Must be finite with positive width and
        /// height; supplies the image edge and centre candidates.
        var imageBounds: CGRect
        /// Vertical guides' x positions.
        var verticalGuides: [Double]
        /// Horizontal guides' y positions.
        var horizontalGuides: [Double]
        /// The display grid, or nil when the image has none.
        var grid: Grid?
        /// Other layers' rects; the caller excludes the moving layer(s)
        /// itself. Each must be finite with positive width and height.
        var otherLayerRects: [CGRect]
    }

    /// What may snap and how far a line may be, in view points.
    struct Config: Equatable {
        var targets: Target = .all
        /// The tolerance in view points; converted to image units by
        /// dividing by the canvas scale. Must be finite and >= 0 (zero
        /// snaps exact coincidences only).
        var viewPointTolerance: Double = CanvasSnapPlanner.defaultViewPointTolerance
    }

    /// Which point of the moving rect matched, on one axis.
    enum Anchor: Equatable {
        /// The rect's min edge (leading) on the axis.
        case leading
        /// The rect's centre on the axis.
        case center
        /// The rect's max edge (trailing) on the axis.
        case trailing
    }

    /// One axis' winning match. `sourceCoordinate` is the moving rect's
    /// anchor coordinate on the axis, `targetCoordinate` the candidate
    /// line's coordinate; the caller draws the indicator line at
    /// `targetCoordinate`.
    struct AxisMatch: Equatable {
        let anchor: Anchor
        /// The single matched kind (exactly one element of `Target`).
        let target: Target
        let sourceCoordinate: Double
        let targetCoordinate: Double
    }

    /// The plan: independent per-axis corrections plus the matches for
    /// the caller's overlay. `dx`/`dy` are 0 when that axis has no
    /// match.
    struct Result: Equatable {
        let dx: Double
        let dy: Double
        let x: AxisMatch?
        let y: AxisMatch?
        /// No correction at all; also returned for invalid input.
        static let none = Result(dx: 0, dy: 0, x: nil, y: nil)
    }

    /// Plans the snap correction for one translation.
    ///
    /// - Parameters:
    ///   - input: the moving rect at its proposed translated position
    ///     plus the candidate geometry, all in image coordinates.
    ///   - config: which target kinds are enabled and the tolerance in
    ///     view points.
    ///   - canvasScale: view points per image unit at the current zoom
    ///     (CanvasGeometry.pointScale). Must be finite and positive; the
    ///     image-space tolerance is `viewPointTolerance / canvasScale`.
    /// - Returns: the per-axis corrections and matches, or `Result.none`
    ///   when any input is non-finite or degenerate.
    ///
    /// Each axis is planned independently: the moving rect's leading,
    /// centre and trailing coordinate on the axis are compared against
    /// every enabled candidate line on that axis, and the pair with the
    /// smallest distance wins when that distance is within the
    /// image-space tolerance (inclusive). The correction is
    /// `targetCoordinate - sourceCoordinate`, so applying it moves the
    /// anchor exactly onto the line. Non-grid geometry is never rounded
    /// to pixels.
    ///
    /// Deterministic tie priority: smallest distance wins; on equal
    /// distance the earlier anchor in leading, centre, trailing order
    /// wins; then the earlier candidate kind in imageEdge, imageCenter,
    /// guide, grid, layerEdge, layerCenter order; then input order
    /// within a kind (guides and layer rects as given). Grid half-way
    /// ties round the lattice index away from zero
    /// (Double.rounded's default rule).
    static func plan(input: Input, config: Config, canvasScale: Double) -> Result {
        guard isUsable(input: input, config: config, canvasScale: canvasScale),
              !config.targets.isEmpty else { return .none }
        let tolerance = config.viewPointTolerance / canvasScale
        guard tolerance.isFinite else { return .none }

        let moving = input.movingRect
        let x = planAxis(anchors: (moving.minX, centre(moving.minX, moving.maxX), moving.maxX),
                         imageMin: input.imageBounds.minX, imageMax: input.imageBounds.maxX,
                         guides: input.verticalGuides,
                         grid: input.grid.map { (spacing: $0.spacingX, offset: $0.offsetX) },
                         otherSpans: input.otherLayerRects.map { ($0.minX, $0.maxX) },
                         targets: config.targets, tolerance: tolerance)
        let y = planAxis(anchors: (moving.minY, centre(moving.minY, moving.maxY), moving.maxY),
                         imageMin: input.imageBounds.minY, imageMax: input.imageBounds.maxY,
                         guides: input.horizontalGuides,
                         grid: input.grid.map { (spacing: $0.spacingY, offset: $0.offsetY) },
                         otherSpans: input.otherLayerRects.map { ($0.minY, $0.maxY) },
                         targets: config.targets, tolerance: tolerance)
        return Result(dx: x.map { $0.targetCoordinate - $0.sourceCoordinate } ?? 0,
                      dy: y.map { $0.targetCoordinate - $0.sourceCoordinate } ?? 0,
                      x: x, y: y)
    }

    /// Plans one axis. `anchors` are the moving rect's leading, centre
    /// and trailing coordinate; candidates are gathered per anchor in
    /// the documented priority order, and the first strictly-smallest
    /// distance wins, so iteration order alone breaks ties.
    private static func planAxis(anchors: (leading: Double, center: Double, trailing: Double),
                                 imageMin: Double, imageMax: Double,
                                 guides: [Double],
                                 grid: (spacing: Double, offset: Double)?,
                                 otherSpans: [(min: Double, max: Double)],
                                 targets: Target, tolerance: Double) -> AxisMatch? {
        let anchorValues: [(Anchor, Double)] = [
            (.leading, anchors.leading),
            (.center, anchors.center),
            (.trailing, anchors.trailing),
        ]
        var best: (distance: Double, match: AxisMatch)? = nil
        for (anchor, anchorValue) in anchorValues {
            var candidates: [(target: Target, coordinate: Double)] = []
            if targets.contains(.imageEdge) {
                candidates.append((.imageEdge, imageMin))
                candidates.append((.imageEdge, imageMax))
            }
            if targets.contains(.imageCenter) {
                candidates.append((.imageCenter, centre(imageMin, imageMax)))
            }
            if targets.contains(.guide) {
                candidates.append(contentsOf: guides.map { (.guide, $0) })
            }
            if targets.contains(.grid), let grid,
               let line = nearestGridLine(value: anchorValue, spacing: grid.spacing, offset: grid.offset) {
                candidates.append((.grid, line))
            }
            if targets.contains(.layerEdge) {
                for span in otherSpans {
                    candidates.append((.layerEdge, span.min))
                    candidates.append((.layerEdge, span.max))
                }
            }
            if targets.contains(.layerCenter) {
                candidates.append(contentsOf: otherSpans.map { (.layerCenter, centre($0.min, $0.max)) })
            }
            for (target, coordinate) in candidates {
                // Both operands are finite, so the difference is finite
                // or ±inf, never NaN; an overflowing distance simply
                // exceeds the tolerance.
                let distance = abs(anchorValue - coordinate)
                guard distance <= tolerance else { continue }
                if let best, distance >= best.distance { continue }
                best = (distance, AxisMatch(anchor: anchor, target: target,
                                            sourceCoordinate: anchorValue, targetCoordinate: coordinate))
            }
        }
        return best?.match
    }

    /// Reconstruct actual lattice lines with one rounded multiply-add.
    /// A residual derived from the quotient can invent a line when
    /// subtracting a large offset loses the moving coordinate's low bits.
    /// Check a fixed neighborhood because the rounded quotient itself can
    /// lose a few indices near the exact-integer limit. This is bounded
    /// work per anchor, independent of grid density or image span.
    private static func nearestGridLine(value: Double, spacing: Double, offset: Double) -> Double? {
        let quotient = (value - offset) / spacing
        guard quotient.isFinite else { return nil }
        let index = quotient.rounded()
        guard index.magnitude <= maximumLatticeIndex else { return nil }
        var nearest: Double?
        var distance = Double.infinity
        // Prefer the rounded index on a tie, retaining the ordinary grid's
        // halfway rule; other candidates only replace a strictly farther line.
        for step in [0, -1, 1, -2, 2, -3, 3] {
            let candidate = index + Double(step)
            guard candidate.magnitude <= maximumLatticeIndex else { continue }
            let line = offset.addingProduct(candidate, spacing)
            let separation = (line - value).magnitude
            if line.isFinite && separation < distance {
                nearest = line
                distance = separation
            }
        }
        return nearest
    }

    /// The midpoint of two finite coordinates, computed as
    /// `min + (max - min) / 2` so it stays finite whenever `max` is.
    private static func centre(_ min: Double, _ max: Double) -> Double {
        min + (max - min) / 2
    }

    /// Whether every input is finite and non-degenerate: the canvas
    /// scale is finite and positive, the tolerance finite and >= 0, both
    /// rects and every other rect finite with positive size, every guide
    /// finite, and a present grid's spacings finite and strictly positive
    /// with finite offsets. Any failure means `plan` returns no
    /// correction at all rather than a correction built on bad geometry.
    private static func isUsable(input: Input, config: Config, canvasScale: Double) -> Bool {
        guard canvasScale.isFinite, canvasScale > 0,
              config.viewPointTolerance.isFinite, config.viewPointTolerance >= 0,
              isUsableRect(input.movingRect), isUsableRect(input.imageBounds),
              input.verticalGuides.allSatisfy({ $0.isFinite }),
              input.horizontalGuides.allSatisfy({ $0.isFinite }),
              input.otherLayerRects.allSatisfy(isUsableRect) else { return false }
        if let grid = input.grid {
            guard grid.spacingX.isFinite, grid.spacingX > 0,
                  grid.spacingY.isFinite, grid.spacingY > 0,
                  grid.offsetX.isFinite, grid.offsetY.isFinite else { return false }
        }
        return true
    }

    /// A rect is usable when all four stored values and both derived max
    /// corners are finite and the size is strictly positive.
    private static func isUsableRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
            && rect.size.width > 0 && rect.size.height > 0
    }
}
