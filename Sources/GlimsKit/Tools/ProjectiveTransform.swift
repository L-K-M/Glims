import CoreGraphics

/// A two-dimensional projective transform (homography) on image pixel
/// coordinates: the projective generalization of `CGAffineTransform`.
///
/// The matrix is stored as nine coefficients in row-major order and acts on
/// column-vector homogeneous coordinates:
///
///     | h00 h01 h02 |   | x |   | X |
///     | h10 h11 h12 | × | y | = | Y |,   x' = X/W, y' = Y/W
///     | h20 h21 h22 |   | 1 |   | W |
///
/// This is the transpose of `CGAffineTransform`'s storage layout (whose
/// `a b c d tx ty` are read as x' = a·x + c·y + tx, y' = b·x + d·y + ty);
/// `init(affine:)` performs the conversion. Do not confuse the two.
///
/// Any nonzero scalar multiple of a matrix describes the same projective
/// mapping. `normalizedToSourceCenter(of:)` returns a canonical
/// representative with W(source center) = +1, which all safety validation
/// uses, so scalar representation never affects admissibility.
///
/// The type is an immutable value type owning only its coefficients. It has
/// no GIMP or engine dependencies; the nine `coefficients` are what the
/// engine facade consumes.
struct ProjectiveTransform: Equatable {
    let h00, h01, h02: Double
    let h10, h11, h12: Double
    let h20, h21, h22: Double

    /// The nine coefficients in row-major order, for handoff to the engine
    /// facade's matrix representation.
    var coefficients: [Double] {
        [h00, h01, h02, h10, h11, h12, h20, h21, h22]
    }

    /// The identity transform.
    static let identity = ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                                              h10: 0, h11: 1, h12: 0,
                                              h20: 0, h21: 0, h22: 1)

    init(h00: Double, h01: Double, h02: Double,
         h10: Double, h11: Double, h12: Double,
         h20: Double, h21: Double, h22: Double) {
        self.h00 = h00; self.h01 = h01; self.h02 = h02
        self.h10 = h10; self.h11 = h11; self.h12 = h12
        self.h20 = h20; self.h21 = h21; self.h22 = h22
    }

    /// Builds the homography of a CoreGraphics affine transform:
    /// rows (a, c, tx), (b, d, ty), (0, 0, 1).
    init(affine t: CGAffineTransform) {
        self.init(h00: t.a, h01: t.c, h02: t.tx,
                  h10: t.b, h11: t.d, h12: t.ty,
                  h20: 0, h21: 0, h22: 1)
    }

    // MARK: - Single-point mapping

    /// Maps one point through the transform, or nil when the result is not
    /// finite: the point, an intermediate product, the homogeneous
    /// denominator W, or the divided coordinates are non-finite.
    ///
    /// This checks only that one point has a finite image. A point behind
    /// the horizon (negative W) still maps to finite coordinates and is
    /// returned; whether a whole rectangle stays on the near side of the
    /// horizon is a stricter admissibility question answered by
    /// `projectedBounds(forSource:)`.
    func project(_ point: CGPoint) -> CGPoint? {
        guard isFinite, point.x.isFinite, point.y.isFinite else { return nil }
        let w = h20 * point.x + h21 * point.y + h22
        guard w.isFinite, w != 0 else { return nil }
        let x = (h00 * point.x + h01 * point.y + h02) / w
        let y = (h10 * point.x + h11 * point.y + h12) / w
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// The inverse mapping, or nil when the matrix is singular or the
    /// determinant/inversion arithmetic overflows. There is no threshold on
    /// the raw determinant: a raw determinant's magnitude depends on the
    /// matrix's arbitrary scalar, so only exact singularity and finiteness
    /// are meaningful here. Conditioning is judged on the normalized matrix
    /// inside `projectedBounds(forSource:)`.
    var inverse: ProjectiveTransform? {
        let det = determinant
        guard det.isFinite, det != 0 else { return nil }
        let inverse = ProjectiveTransform(
            h00: (h11 * h22 - h12 * h21) / det,
            h01: (h02 * h21 - h01 * h22) / det,
            h02: (h01 * h12 - h02 * h11) / det,
            h10: (h12 * h20 - h10 * h22) / det,
            h11: (h00 * h22 - h02 * h20) / det,
            h12: (h02 * h10 - h00 * h12) / det,
            h20: (h10 * h21 - h11 * h20) / det,
            h21: (h01 * h20 - h00 * h21) / det,
            h22: (h00 * h11 - h01 * h10) / det)
        guard inverse.isFinite else { return nil }
        return inverse
    }

    /// Composition with explicit ordering: `a.followed(by: b)` applies `a`
    /// first, then `b` — the matrix product b·a.
    func followed(by next: ProjectiveTransform) -> ProjectiveTransform {
        let a = self, b = next
        return ProjectiveTransform(
            h00: b.h00 * a.h00 + b.h01 * a.h10 + b.h02 * a.h20,
            h01: b.h00 * a.h01 + b.h01 * a.h11 + b.h02 * a.h21,
            h02: b.h00 * a.h02 + b.h01 * a.h12 + b.h02 * a.h22,
            h10: b.h10 * a.h00 + b.h11 * a.h10 + b.h12 * a.h20,
            h11: b.h10 * a.h01 + b.h11 * a.h11 + b.h12 * a.h21,
            h12: b.h10 * a.h02 + b.h11 * a.h12 + b.h12 * a.h22,
            h20: b.h20 * a.h00 + b.h21 * a.h10 + b.h22 * a.h20,
            h21: b.h20 * a.h01 + b.h21 * a.h11 + b.h22 * a.h21,
            h22: b.h20 * a.h02 + b.h21 * a.h12 + b.h22 * a.h22)
    }

    // MARK: - Rectangle admissibility

    /// The same transform expressed so that W at the given rectangle's
    /// center is exactly +1, or nil when that W is zero or non-finite.
    /// Projectively equivalent inputs (H, 2H, −3H) produce identical
    /// results. Normalizing by `h22` alone would be wrong: an offset source
    /// can validly have `h22 == 0` while W stays positive over the rect.
    func normalizedToSourceCenter(of rect: CGRect) -> ProjectiveTransform? {
        let w = h20 * rect.midX + h21 * rect.midY + h22
        guard w.isFinite, w != 0 else { return nil }
        let normalized = ProjectiveTransform(
            h00: h00 / w, h01: h01 / w, h02: h02 / w,
            h10: h10 / w, h11: h11 / w, h12: h12 / w,
            h20: h20 / w, h21: h21 / w, h22: h22 / w)
        guard normalized.isFinite else { return nil }
        return normalized
    }

    /// Conservative raster bounds of the transform applied to a source
    /// rectangle, or nil when the mapping is inadmissible. Outward floor/ceil
    /// rounding may exceed the engine's epsilon-adjusted bounds by a pixel;
    /// native commit remains authoritative for the exact result bounds.
    ///
    /// A transform is admissible for a finite source rectangle with
    /// positive size when, on the source-center normalized matrix:
    ///
    ///   - all coefficients, the determinant and the inverse are finite,
    ///   - the normalized determinant clears `Self.minimumDeterminant`
    ///     (the local area scale at the source center is det/W³; this
    ///     rejects near-zero area scale, not every ill-conditioned matrix),
    ///   - every source corner's normalized W exceeds
    ///     `Self.nearPlaneW + Self.nearPlaneMargin` — W is affine over the
    ///     rectangle, so a positive corner minimum proves no horizon
    ///     crosses the source,
    ///   - the projected corner extrema stay within
    ///     ±`Self.coordinateBound`, and the rounded raster size stays
    ///     within `Self.maximumDimension` on each axis.
    ///
    /// Mirrors are admissible: orientation is not restricted on this
    /// general matrix path (the quad solver is stricter). There is
    /// deliberately no pixel-area or memory cap beyond the dimension
    /// limit — allocation policy belongs to the caller, which can read
    /// `ProjectedBounds.pixelArea` before admitting an allocation.
    func projectedBounds(forSource rect: CGRect) -> ProjectedBounds? {
        guard rect.minX.isFinite, rect.minY.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0 else { return nil }
        guard let normalized = normalizedToSourceCenter(of: rect),
              normalized.isFinite else { return nil }

        let det = normalized.determinant
        guard det.isFinite, det.magnitude >= Self.minimumDeterminant,
              normalized.inverse != nil else { return nil }

        let corners = [rect.topLeft, rect.topRight,
                       rect.bottomRight, rect.bottomLeft]
        var minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        for corner in corners {
            let w = normalized.h20 * corner.x + normalized.h21 * corner.y + normalized.h22
            guard w.isFinite, w > Self.nearPlaneW + Self.nearPlaneMargin else { return nil }
            guard let projected = normalized.project(corner) else { return nil }
            guard projected.x.isFinite, projected.y.isFinite,
                  abs(projected.x) <= Self.coordinateBound,
                  abs(projected.y) <= Self.coordinateBound else { return nil }
            minX = min(minX, projected.x); maxX = max(maxX, projected.x)
            minY = min(minY, projected.y); maxY = max(maxY, projected.y)
        }

        // The extrema are already range-checked, so the rounded values are
        // small integral doubles; Int(exactly:) converts without trapping.
        guard let x = Int(exactly: minX.rounded(.down)),
              let y = Int(exactly: minY.rounded(.down)),
              let farX = Int(exactly: maxX.rounded(.up)),
              let farY = Int(exactly: maxY.rounded(.up)) else { return nil }
        let width = farX - x, height = farY - y
        guard width > 0, height > 0,
              width <= Self.maximumDimension, height <= Self.maximumDimension
        else { return nil }
        return ProjectedBounds(x: x, y: y, width: width, height: height)
    }

    // MARK: - Rectangle-to-quad solving

    /// A destination quadrilateral for `transform(from:toQuad:)`, with
    /// explicit corner roles.
    struct Quad: Equatable {
        /// Corner order matches the source rectangle's: top-left,
        /// top-right, bottom-right, bottom-left.
        let topLeft, topRight, bottomRight, bottomLeft: CGPoint
    }

    /// Conservative raster bounds of a transformed source rectangle, in
    /// output pixels. The rect is floored at the near edges and ceiled at
    /// the far edges; `pixelArea` is an estimate for allocation admission,
    /// not a promise of the native engine's epsilon-adjusted dimensions.
    struct ProjectedBounds: Equatable {
        let x, y, width, height: Int
        var pixelArea: Int64 { Int64(width) * Int64(height) }
        var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    }

    /// Solves the unique homography taking the source rectangle's corners to
    /// the quad's corners in matching order (source top-left →
    /// `quad.topLeft`, top-right → `topRight`, bottom-right →
    /// `bottomRight`, bottom-left → `bottomLeft`), or nil when no safe
    /// transform exists.
    ///
    /// Unlike the general matrix path, the quad must preserve the source's
    /// winding: every turn between consecutive edges must be strictly
    /// positive (strictly convex, no folding, concavity, reversed winding,
    /// or coincident/collinear corners). Reversed-winding quads are
    /// rejected even though a mirror matrix is admissible through
    /// `projectedBounds(forSource:)`, because handle-driven quads that flip
    /// orientation are almost certainly a UI error.
    ///
    /// The solve is performed in source-normalized (unit-square)
    /// coordinates so large source origins do not destabilize it, and the
    /// result must pass the same `projectedBounds(forSource:)` validation
    /// as any other transform — including near-plane, determinant and
    /// output-size checks. Failure never yields a partial transform.
    static func transform(from rect: CGRect, toQuad quad: Quad) -> ProjectiveTransform? {
        guard rect.minX.isFinite, rect.minY.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0 else { return nil }
        let p0 = quad.topLeft, p1 = quad.topRight
        let p2 = quad.bottomRight, p3 = quad.bottomLeft
        guard [p0, p1, p2, p3].allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return nil }

        // Strict convexity with preserved winding: the four turns between
        // consecutive edges must all exceed a minimum relative sine.
        let edges = [CGPoint.delta(from: p0, to: p1), CGPoint.delta(from: p1, to: p2),
                     CGPoint.delta(from: p2, to: p3), CGPoint.delta(from: p3, to: p0)]
        for i in 0..<4 {
            let a = edges[i], b = edges[(i + 1) % 4]
            let turn = a.x * b.y - a.y * b.x
            let scale = a.magnitude * b.magnitude
            guard turn.isFinite, scale.isFinite,
                  turn > Self.convexityMargin * scale else { return nil }
        }

        // Solve on the unit square: p0..p3 are the images of
        // (0,0), (1,0), (1,1), (0,1). This is the standard direct solution
        // for a projective basis; `denominator` is the negated turn at p2,
        // already proven strictly negative by the convexity check.
        let dx1 = p1.x - p2.x, dy1 = p1.y - p2.y
        let dx2 = p3.x - p2.x, dy2 = p3.y - p2.y
        let sx = p0.x - p1.x + p2.x - p3.x
        let sy = p0.y - p1.y + p2.y - p3.y
        let denominator = dx1 * dy2 - dx2 * dy1
        guard denominator.isFinite, denominator != 0 else { return nil }
        let g = (sx * dy2 - sy * dx2) / denominator
        let h = (dx1 * sy - dy1 * sx) / denominator
        let unitToQuad = ProjectiveTransform(
            h00: p1.x - p0.x + g * p1.x, h01: p3.x - p0.x + h * p3.x, h02: p0.x,
            h10: p1.y - p0.y + g * p1.y, h11: p3.y - p0.y + h * p3.y, h12: p0.y,
            h20: g, h21: h, h22: 1)
        guard unitToQuad.isFinite else { return nil }

        // Compose with the source→unit normalization; a large source origin
        // therefore never enters the solve itself.
        let sourceToUnit = ProjectiveTransform(
            h00: 1 / rect.width, h01: 0, h02: -rect.minX / rect.width,
            h10: 0, h11: 1 / rect.height, h12: -rect.minY / rect.height,
            h20: 0, h21: 0, h22: 1)
        let transform = sourceToUnit.followed(by: unitToQuad)

        // Admit only what the common rectangle validation accepts.
        guard transform.projectedBounds(forSource: rect) != nil else { return nil }
        return transform
    }

    // MARK: - Numeric policy

    /// Largest permitted projected output coordinate magnitude, in pixels.
    static let coordinateBound: Double = 1_048_576
    /// Largest permitted output width or height, in pixels.
    static let maximumDimension = 524_288
    /// Minimum normalized corner W: the engine's near-plane distance (0.02).
    static let nearPlaneW = 0.02
    /// Extra floating-point margin above `nearPlaneW`, so a corner W that
    /// merely rounds to 0.02 still fails.
    static let nearPlaneMargin = 1e-9
    /// Minimum |det| of the source-center normalized matrix, matching native
    /// transform admission. With W(center) fixed at 1 this is the local area
    /// scale and is independent of the matrix's arbitrary scalar. It is not
    /// a complete condition-number bound or an allocation policy.
    static let minimumDeterminant = 1e-9
    /// Minimum sine of the turn angle between consecutive quad edges.
    static let convexityMargin = 1e-9

    private var isFinite: Bool {
        coefficients.allSatisfy { $0.isFinite }
    }

    /// The determinant of the raw stored matrix. Its magnitude is
    /// meaningless across scalar-equivalent matrices; only the normalized
    /// determinant is validated.
    private var determinant: Double {
        h00 * (h11 * h22 - h12 * h21)
            - h01 * (h10 * h22 - h12 * h20)
            + h02 * (h10 * h21 - h11 * h20)
    }
}

private extension CGPoint {
    static func delta(from a: CGPoint, to b: CGPoint) -> CGPoint {
        CGPoint(x: b.x - a.x, y: b.y - a.y)
    }

    var magnitude: Double {
        (x * x + y * y).squareRoot()
    }
}

private extension CGRect {
    var topLeft: CGPoint { CGPoint(x: minX, y: minY) }
    var topRight: CGPoint { CGPoint(x: maxX, y: minY) }
    var bottomRight: CGPoint { CGPoint(x: maxX, y: maxY) }
    var bottomLeft: CGPoint { CGPoint(x: minX, y: maxY) }
}
