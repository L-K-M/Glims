import CoreGraphics
import XCTest
@testable import GlimsKit

final class ProjectiveTransformTests: XCTestCase {
    private func assertPoint(_ actual: CGPoint?, _ expected: CGPoint,
                             accuracy: Double = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            return XCTFail("expected \(expected), got nil", file: file, line: line)
        }
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, "y", file: file, line: line)
    }

    private func assertNormalized(_ transform: ProjectiveTransform, in rect: CGRect,
                                  equals expected: [Double], accuracy: Double = 1e-9,
                                  file: StaticString = #filePath, line: UInt = #line) {
        guard let normalized = transform.normalizedToSourceCenter(of: rect) else {
            return XCTFail("expected a normalized matrix", file: file, line: line)
        }
        for (actual, wanted) in zip(normalized.coefficients, expected) {
            XCTAssertEqual(actual, wanted, accuracy: accuracy, file: file, line: line)
        }
    }

    // MARK: Identity, affine, composition

    func testIdentityMapsEveryPointToItself() {
        let identity = ProjectiveTransform.identity
        assertPoint(identity.project(CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 0))
        assertPoint(identity.project(CGPoint(x: -7.25, y: 42.5)), CGPoint(x: -7.25, y: 42.5))
        XCTAssertEqual(identity.inverse, identity)
        XCTAssertNotNil(identity.projectedBounds(forSource: CGRect(x: 3, y: 4, width: 5, height: 6)))
    }

    func testAffineConversionAndCompositionOrderMatchHandCalculations() {
        let translate = ProjectiveTransform(affine: CGAffineTransform(translationX: 10, y: 20))
        assertPoint(translate.project(CGPoint(x: 1, y: 2)), CGPoint(x: 11, y: 22))
        XCTAssertEqual(translate.coefficients, [1, 0, 10, 0, 1, 20, 0, 0, 1])

        let scale = ProjectiveTransform(affine: CGAffineTransform(scaleX: 2, y: 3))
        assertPoint(scale.project(CGPoint(x: 1, y: 2)), CGPoint(x: 2, y: 6))

        let shear = ProjectiveTransform(affine: CGAffineTransform(a: 1, b: 0, c: 0.5, d: 1, tx: 0, ty: 0))
        assertPoint(shear.project(CGPoint(x: 2, y: 4)), CGPoint(x: 4, y: 4))

        // Translate then scale: (1,1) → (11,21) → (22,63).
        assertPoint(translate.followed(by: scale).project(CGPoint(x: 1, y: 1)),
                    CGPoint(x: 22, y: 63))
        // Scale then translate: (1,1) → (2,3) → (12,23).
        assertPoint(scale.followed(by: translate).project(CGPoint(x: 1, y: 1)),
                    CGPoint(x: 12, y: 23))
        // followed(by:) agrees with CGAffineTransform.concatenating.
        let cg = CGAffineTransform(translationX: 10, y: 20)
            .concatenating(CGAffineTransform(scaleX: 2, y: 3))
        XCTAssertEqual(translate.followed(by: scale).coefficients,
                       ProjectiveTransform(affine: cg).coefficients)
    }

    func testGeneralMatrixPathAdmitsMirrors() {
        // Flips x around x=50 of a 100-wide rectangle.
        let mirror = ProjectiveTransform(h00: -1, h01: 0, h02: 100,
                                         h10: 0, h11: 1, h12: 0,
                                         h20: 0, h21: 0, h22: 1)
        assertPoint(mirror.project(CGPoint(x: 25, y: 10)), CGPoint(x: 75, y: 10))
        XCTAssertEqual(mirror.projectedBounds(forSource: CGRect(x: 0, y: 0, width: 100, height: 40)),
                       .init(x: 0, y: 0, width: 100, height: 40))
    }

    // MARK: Analytic perspective example

    func testPerspectiveTransformMatchesAnalyticValues() {
        // H = [[1,0,0],[0,1,0],[0,.01,1]] on a 100×100 rect at the origin.
        let h = ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                                    h10: 0, h11: 1, h12: 0,
                                    h20: 0, h21: 0.01, h22: 1)
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)

        assertPoint(h.project(CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 0))
        assertPoint(h.project(CGPoint(x: 100, y: 0)), CGPoint(x: 100, y: 0))
        // W = 1 + .01·100 = 2 at the bottom edge.
        assertPoint(h.project(CGPoint(x: 100, y: 100)), CGPoint(x: 50, y: 50))
        assertPoint(h.project(CGPoint(x: 0, y: 100)), CGPoint(x: 0, y: 50))
        // Interior: W = 1.5 at the center.
        assertPoint(h.project(CGPoint(x: 50, y: 50)), CGPoint(x: 100.0 / 3, y: 100.0 / 3))

        let bounds = h.projectedBounds(forSource: rect)
        XCTAssertEqual(bounds, .init(x: 0, y: 0, width: 100, height: 50))
        XCTAssertEqual(bounds?.pixelArea, 5_000)

        // Inverse of [[1,0,0],[0,1,0],[0,.01,1]] is [[1,0,0],[0,1,0],[0,-.01,1]].
        let inverse = h.inverse
        assertPoint(inverse?.project(CGPoint(x: 100.0 / 3, y: 100.0 / 3)), CGPoint(x: 50, y: 50))
        assertPoint(inverse?.project(CGPoint(x: 0, y: 50)), CGPoint(x: 0, y: 100))
        assertPoint(inverse?.project(CGPoint(x: 50, y: 50)), CGPoint(x: 100, y: 100))
    }

    // MARK: Scalar equivalence and offsets

    func testScalarMultiplesNormalizeToTheSameTransform() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        // Center W is 1.5; normalized matrix is [[2/3,0,0],[0,2/3,0],[0,1/150,2/3]].
        let expected = [2.0 / 3, 0, 0, 0, 2.0 / 3, 0, 0, 1.0 / 150, 2.0 / 3]
        let h = ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                                    h10: 0, h11: 1, h12: 0,
                                    h20: 0, h21: 0.01, h22: 1)
        let h2 = ProjectiveTransform(h00: 2, h01: 0, h02: 0,
                                     h10: 0, h11: 2, h12: 0,
                                     h20: 0, h21: 0.02, h22: 2)
        let hm3 = ProjectiveTransform(h00: -3, h01: 0, h02: 0,
                                      h10: 0, h11: -3, h12: 0,
                                      h20: 0, h21: -0.03, h22: -3)
        assertNormalized(h, in: rect, equals: expected)
        assertNormalized(h2, in: rect, equals: expected)
        assertNormalized(hm3, in: rect, equals: expected)
        XCTAssertEqual(h.projectedBounds(forSource: rect), h2.projectedBounds(forSource: rect))
        XCTAssertEqual(h.projectedBounds(forSource: rect), hm3.projectedBounds(forSource: rect))
    }

    func testOffsetAndNegativeSourceOrigins() {
        let h = ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                                    h10: 0, h11: 1, h12: 0,
                                    h20: 0, h21: 0.01, h22: 1)
        // Negative origin: y in [50,150] keeps W positive.
        let negative = CGRect(x: -50, y: 50, width: 100, height: 100)
        assertPoint(h.project(CGPoint(x: -50, y: 50)), CGPoint(x: -100.0 / 3, y: 100.0 / 3))
        assertPoint(h.project(CGPoint(x: 50, y: 150)), CGPoint(x: 20, y: 60))
        XCTAssertNotNil(h.projectedBounds(forSource: negative))

        // Large positive origin does not destabilize anything.
        let offset = CGRect(x: 1_000, y: 500, width: 100, height: 100)
        assertPoint(h.project(CGPoint(x: 1_000, y: 500)),
                    CGPoint(x: 500.0 / 3, y: 250.0 / 3))
        XCTAssertNotNil(h.projectedBounds(forSource: offset))
    }

    func testOffsetSourceCanValidlyHaveZeroH22() {
        // W = .01·y: h22 is exactly 0, yet W stays in [0.1, 1.1] over the
        // rect, well above the near plane after center normalization.
        let h = ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                                    h10: 0, h11: 1, h12: 5,
                                    h20: 0, h21: 0.01, h22: 0)
        let rect = CGRect(x: 0, y: 10, width: 100, height: 100)
        // (0,10): X=0, Y=15, W=0.1 → (0,150).
        assertPoint(h.project(CGPoint(x: 0, y: 10)), CGPoint(x: 0, y: 150))
        XCTAssertNotNil(h.projectedBounds(forSource: rect))
    }

    // MARK: Rectangle-to-quad solver

    func testQuadSolverRecoversAnAffineTransform() {
        let solved = ProjectiveTransform.transform(
            from: CGRect(x: 0, y: 0, width: 100, height: 100),
            toQuad: .init(topLeft: CGPoint(x: 10, y: 20),
                          topRight: CGPoint(x: 110, y: 20),
                          bottomRight: CGPoint(x: 110, y: 120),
                          bottomLeft: CGPoint(x: 10, y: 120)))
        XCTAssertNotNil(solved)
        // Translation by (10,20); center W is 1, so normalized == raw.
        assertNormalized(solved!, in: CGRect(x: 0, y: 0, width: 100, height: 100),
                         equals: [1, 0, 10, 0, 1, 20, 0, 0, 1])
    }

    func testQuadSolverMatchesAnalyticPerspective() {
        // Unit square → quad (0,0), (2,0), (1.5,1), (0,1).
        // Solving by hand gives H = [[2,0,0],[0,4/3,0],[0,1/3,1]]:
        //   W(1,0)=1, W(0,1)=4/3, W(1,1)=4/3; center W = 7/6.
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let solved = ProjectiveTransform.transform(
            from: rect,
            toQuad: .init(topLeft: CGPoint(x: 0, y: 0),
                          topRight: CGPoint(x: 2, y: 0),
                          bottomRight: CGPoint(x: 1.5, y: 1),
                          bottomLeft: CGPoint(x: 0, y: 1)))
        XCTAssertNotNil(solved)
        assertNormalized(solved!, in: rect,
                         equals: [12.0 / 7, 0, 0,
                                  0, 8.0 / 7, 0,
                                  0, 2.0 / 7, 6.0 / 7])
        // (0.5,0.5): X=1, Y=2/3, W=7/6 → (6/7, 4/7).
        assertPoint(solved?.project(CGPoint(x: 0.5, y: 0.5)),
                    CGPoint(x: 6.0 / 7, y: 4.0 / 7))
    }

    func testQuadSolverCornerOrderingIsSignificant() {
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        let quad = ProjectiveTransform.Quad(
            topLeft: CGPoint(x: 0, y: 0), topRight: CGPoint(x: 2, y: 0),
            bottomRight: CGPoint(x: 1.5, y: 1), bottomLeft: CGPoint(x: 0, y: 1))
        let forward = ProjectiveTransform.transform(from: rect, toQuad: quad)
        // The same four points relabeled one step around the ring are still
        // convex, but source TL must now land on the old TR.
        let rotated = ProjectiveTransform.transform(
            from: rect,
            toQuad: .init(topLeft: quad.topRight, topRight: quad.bottomRight,
                          bottomRight: quad.bottomLeft, bottomLeft: quad.topLeft))
        XCTAssertNotNil(rotated)
        assertPoint(rotated?.project(CGPoint(x: 0, y: 0)), quad.topRight)
        XCTAssertNotEqual(forward?.coefficients, rotated?.coefficients)
    }

    func testQuadSolverRejectsInvalidQuads() {
        let rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        func quad(_ tl: CGPoint, _ tr: CGPoint, _ br: CGPoint, _ bl: CGPoint)
            -> ProjectiveTransform.Quad {
            .init(topLeft: tl, topRight: tr, bottomRight: br, bottomLeft: bl)
        }
        // Folded (bow-tie): corner order crosses itself.
        XCTAssertNil(ProjectiveTransform.transform(
            from: rect, toQuad: quad(CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1),
                                     CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1))))
        // Concave: bottom-right pulled inside the triangle of the others.
        XCTAssertNil(ProjectiveTransform.transform(
            from: rect, toQuad: quad(CGPoint(x: 0, y: 0), CGPoint(x: 2, y: 0),
                                     CGPoint(x: 0.5, y: 0.5), CGPoint(x: 0, y: 2))))
        // Degenerate: all four points collinear.
        XCTAssertNil(ProjectiveTransform.transform(
            from: rect, toQuad: quad(CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                                     CGPoint(x: 2, y: 0), CGPoint(x: 3, y: 0))))
        // Degenerate: coincident corners.
        XCTAssertNil(ProjectiveTransform.transform(
            from: rect, toQuad: quad(CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
                                     CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 1))))
        // Reversed winding: same square listed counterclockwise.
        XCTAssertNil(ProjectiveTransform.transform(
            from: rect, toQuad: quad(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1),
                                     CGPoint(x: 1, y: 1), CGPoint(x: 1, y: 0))))
        // Unsafe output still fails through the shared validation.
        XCTAssertNil(ProjectiveTransform.transform(
            from: rect, toQuad: quad(CGPoint(x: 0, y: 0), CGPoint(x: 2_000_000, y: 0),
                                     CGPoint(x: 2_000_000, y: 1), CGPoint(x: 0, y: 1))))
    }

    // MARK: Rejection cases

    func testPointMappingRejectsNonfiniteDenominators() {
        let infinite = ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                                           h10: 0, h11: 1, h12: 0,
                                           h20: .infinity, h21: 0, h22: 1)
        XCTAssertNil(infinite.project(CGPoint(x: 2, y: 1)))

        // All coefficients are finite, but computing W overflows. Dividing
        // finite numerators by infinity must not report a valid (0, 0).
        let overflowing = ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                                              h10: 0, h11: 1, h12: 0,
                                              h20: .greatestFiniteMagnitude, h21: 0, h22: 1)
        XCTAssertNil(overflowing.project(CGPoint(x: 2, y: 1)))
    }

    func testNegativeStoredSourceSizesAreRejected() {
        let quad = ProjectiveTransform.Quad(topLeft: .zero, topRight: CGPoint(x: 10, y: 0),
                                             bottomRight: CGPoint(x: 10, y: 10),
                                             bottomLeft: CGPoint(x: 0, y: 10))
        for rect in [CGRect(x: 0, y: 0, width: -10, height: 10),
                     CGRect(x: 0, y: 0, width: 10, height: -10)] {
            // CGRect.width/height standardize; its stored size retains the
            // negative value, so validate size rather than those accessors.
            XCTAssertTrue(rect.size.width < 0 || rect.size.height < 0)
            XCTAssertNil(ProjectiveTransform.identity.projectedBounds(forSource: rect))
            XCTAssertNil(ProjectiveTransform.transform(from: rect, toQuad: quad))
        }
    }

    func testQuadSolverUsesOffsetSourceCoordinates() throws {
        // In local source coordinates u=x+80, v=y+40, the analytic map is
        // (u/(1+.01v), v/(1+.01v)). At (x,y)=(-20,5), u=60, v=45.
        let rect = CGRect(x: -80, y: -40, width: 120, height: 90)
        let solved = try XCTUnwrap(ProjectiveTransform.transform(
            from: rect,
            toQuad: .init(topLeft: .zero, topRight: CGPoint(x: 120, y: 0),
                          bottomRight: CGPoint(x: 1200.0 / 19, y: 900.0 / 19),
                          bottomLeft: CGPoint(x: 0, y: 900.0 / 19))))
        assertPoint(solved.project(CGPoint(x: -80, y: -40)), .zero)
        assertPoint(solved.project(CGPoint(x: 40, y: -40)), CGPoint(x: 120, y: 0))
        assertPoint(solved.project(CGPoint(x: -20, y: 5)),
                    CGPoint(x: 1200.0 / 29, y: 900.0 / 29))
        // The analytic inverse is [[1,.8,-80],[0,1.4,-40],[0,-.01,1]].
        assertPoint(solved.inverse?.project(CGPoint(x: 1200.0 / 29, y: 900.0 / 29)),
                    CGPoint(x: -20, y: 5))
    }

    func testRejectsInvalidSourceRectangles() {
        let identity = ProjectiveTransform.identity
        XCTAssertNil(identity.projectedBounds(forSource: CGRect(x: 0, y: 0, width: 0, height: 100)))
        XCTAssertNil(identity.projectedBounds(forSource: CGRect(x: 0, y: 0, width: Double.nan, height: 100)))
        XCTAssertNil(identity.projectedBounds(forSource: CGRect(x: 0, y: 0, width: 100, height: Double.infinity)))
        XCTAssertNil(identity.projectedBounds(forSource: CGRect(x: Double.infinity, y: 0, width: 10, height: 10)))
    }

    func testRejectsNonfiniteAndSingularInputs() {
        let nonfinite = ProjectiveTransform(h00: 1, h01: Double.nan, h02: 0,
                                            h10: 0, h11: 1, h12: 0,
                                            h20: 0, h21: 0, h22: 1)
        XCTAssertNil(nonfinite.project(CGPoint(x: 1, y: 1)))
        XCTAssertNil(nonfinite.projectedBounds(forSource: CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertNil(nonfinite.inverse)

        let singular = ProjectiveTransform(h00: 1, h01: 2, h02: 0,
                                           h10: 2, h11: 4, h12: 0,
                                           h20: 0, h21: 0, h22: 1)
        XCTAssertNil(singular.inverse)
        XCTAssertNil(singular.projectedBounds(forSource: CGRect(x: 0, y: 0, width: 10, height: 10)))

        // Finite coefficients whose products overflow.
        let overflowing = ProjectiveTransform(h00: 1e308, h01: 0, h02: 0,
                                              h10: 0, h11: 1e308, h12: 0,
                                              h20: 0, h21: 0, h22: 1)
        XCTAssertNil(overflowing.projectedBounds(forSource: CGRect(x: 0, y: 0, width: 1, height: 1)))

        // Nonfinite points never map.
        XCTAssertNil(ProjectiveTransform.identity.project(CGPoint(x: Double.infinity, y: 0)))
        XCTAssertNil(ProjectiveTransform.identity.project(CGPoint(x: 0, y: Double.nan)))
    }

    func testRejectsUnsafeOutputBoundsAndDimensions() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        // Coordinates beyond ±1048576.
        let far = ProjectiveTransform(affine: CGAffineTransform(scaleX: 20_000, y: 20_000))
        XCTAssertNil(far.projectedBounds(forSource: rect))
        let distant = ProjectiveTransform(affine: CGAffineTransform(translationX: 2_000_000, y: 0))
        XCTAssertNil(distant.projectedBounds(forSource: rect))
        // Dimensions beyond 524288 while coordinates stay in range.
        let wide = ProjectiveTransform(affine: CGAffineTransform(scaleX: 6_000, y: 6_000))
        XCTAssertNil(wide.projectedBounds(forSource: rect))
    }

    func testRejectsHorizonCrossingAndNearPlane() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        // Horizon exactly through the source: W(center) is 0.
        let horizon = ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                                          h10: 0, h11: 1, h12: 0,
                                          h20: 0, h21: -0.02, h22: 1)
        XCTAssertNil(horizon.projectedBounds(forSource: rect))
        // Horizon inside the right edge: normalized corner W is negative.
        let crossing = ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                                           h10: 0, h11: 1, h12: 0,
                                           h20: -0.015, h21: 0, h22: 1)
        XCTAssertNil(crossing.projectedBounds(forSource: rect))
        // Everywhere positive but a normalized corner W ≈ 0.0198 < 0.02.
        let nearPlane = ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                                            h10: 0, h11: 1, h12: 0,
                                            h20: 0, h21: -0.0099, h22: 1)
        XCTAssertNil(nearPlane.projectedBounds(forSource: rect))
    }

    func testNormalizedDeterminantMatchesNativeAdmissionFloor() {
        let rect = CGRect(x: 0, y: 0, width: 100, height: 100)
        // The normalized local area scale is exactly scaleY here. Native
        // transforms refuse values below 1e-9, even with finite inverses.
        let below = ProjectiveTransform(affine: CGAffineTransform(scaleX: 1, y: 1e-10))
        XCTAssertNil(below.projectedBounds(forSource: rect))
        let boundary = ProjectiveTransform(affine: CGAffineTransform(scaleX: 1, y: 1e-9))
        XCTAssertEqual(boundary.projectedBounds(forSource: rect),
                       .init(x: 0, y: 0, width: 100, height: 1))
    }

    func testCheckedPointMappingDiffersFromRectangleAdmissibility() {
        let h = ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                                    h10: 0, h11: 1, h12: 0,
                                    h20: 0, h21: 0.01, h22: 1)
        // W = 0 at y = -100: the point sits on the horizon and cannot map.
        XCTAssertNil(h.project(CGPoint(x: 0, y: -100)))
        // Beyond the horizon W is negative, but the single-point image is
        // still finite: project admits it while rectangle validation would not.
        assertPoint(h.project(CGPoint(x: 0, y: -200)), CGPoint(x: 0, y: 200))
    }

    func testNoAreaCapBeyondTheDimensionLimit() {
        // The largest admissible output: 524288×524288 pixels. Only the
        // per-axis dimension cap applies; there is no pixel-area policy.
        let scale = ProjectiveTransform(affine: CGAffineTransform(scaleX: 524_288, y: 524_288))
        let bounds = scale.projectedBounds(forSource: CGRect(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(bounds, .init(x: 0, y: 0, width: 524_288, height: 524_288))
        XCTAssertEqual(bounds?.pixelArea, 274_877_906_944)

        let tooWide = ProjectiveTransform(affine: CGAffineTransform(scaleX: 524_289, y: 1))
        XCTAssertNil(tooWide.projectedBounds(forSource: CGRect(x: 0, y: 0, width: 1, height: 1)))
    }
}
