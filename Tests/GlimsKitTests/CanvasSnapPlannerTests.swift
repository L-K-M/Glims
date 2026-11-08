import CoreGraphics
import XCTest
@testable import GlimsKit

/// Deterministic tests of the pure snap planner. Every expected value is
/// computed by hand from the documented rules (nearest anchor-to-line
/// distance within the image-space tolerance, per-axis independent,
/// documented tie priority), never by calling the planner.
final class CanvasSnapPlannerTests: XCTestCase {
    private static let accuracy = 1e-9

    private func plan(_ input: CanvasSnapPlanner.Input,
                      targets: CanvasSnapPlanner.Target = .all,
                      viewPointTolerance: Double = CanvasSnapPlanner.defaultViewPointTolerance,
                      canvasScale: Double = 1) -> CanvasSnapPlanner.Result {
        CanvasSnapPlanner.plan(input: input,
                               config: CanvasSnapPlanner.Config(targets: targets,
                                                                viewPointTolerance: viewPointTolerance),
                               canvasScale: canvasScale)
    }

    private func input(moving: CGRect,
                       imageBounds: CGRect = CGRect(x: 0, y: 0, width: 100, height: 80),
                       verticalGuides: [Double] = [],
                       horizontalGuides: [Double] = [],
                       grid: CanvasSnapPlanner.Grid? = nil,
                       otherLayerRects: [CGRect] = []) -> CanvasSnapPlanner.Input {
        CanvasSnapPlanner.Input(movingRect: moving, imageBounds: imageBounds,
                                verticalGuides: verticalGuides, horizontalGuides: horizontalGuides,
                                grid: grid, otherLayerRects: otherLayerRects)
    }

    /// XCTAssertEqual with an accuracy for a Double? (the stdlib overload
    /// takes non-optional values); nil fails the test.
    private func assertEqual(_ actual: Double?, _ expected: Double, accuracy: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let actual else {
            XCTFail("expected \(expected), got nil", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, accuracy: accuracy, file: file, line: line)
    }

    // MARK: Image edges and centre

    func testTrailingEdgeSnapsToImageMaxEdge() {
        // Anchors x: 90.5, 94.5, 98.5. Closest line: image max 100 at
        // distance 1.5 (94.5 is 5.5 away, leading is 9.5 away).
        let result = plan(input(moving: CGRect(x: 90.5, y: 10, width: 8, height: 8)))
        XCTAssertEqual(result.dx, 1.5, accuracy: Self.accuracy)
        XCTAssertEqual(result.dy, 0, accuracy: Self.accuracy)
        XCTAssertEqual(result.x?.anchor, .trailing)
        XCTAssertEqual(result.x?.target, .imageEdge)
        assertEqual(result.x?.sourceCoordinate, 98.5, accuracy: Self.accuracy)
        assertEqual(result.x?.targetCoordinate, 100, accuracy: Self.accuracy)
        // y anchors 10/14/18 are all more than 8 from 0, 40 and 80.
        XCTAssertNil(result.y)
    }

    func testLeadingEdgeSnapsToImageMinEdge() {
        // Anchors x: 3, 7, 11. Closest line: image min 0 at distance 3.
        let result = plan(input(moving: CGRect(x: 3, y: 10, width: 8, height: 8)))
        XCTAssertEqual(result.dx, -3, accuracy: Self.accuracy)
        XCTAssertEqual(result.x?.anchor, .leading)
        XCTAssertEqual(result.x?.target, .imageEdge)
        assertEqual(result.x?.targetCoordinate, 0, accuracy: Self.accuracy)
    }

    func testImageCentreSnapsOnBothAxesIndependently() {
        // Image centre (50, 40). Moving centre (48, 38): dx = +2, dy = +2.
        let result = plan(input(moving: CGRect(x: 44, y: 34, width: 8, height: 8)))
        XCTAssertEqual(result.dx, 2, accuracy: Self.accuracy)
        XCTAssertEqual(result.dy, 2, accuracy: Self.accuracy)
        XCTAssertEqual(result.x?.anchor, .center)
        XCTAssertEqual(result.x?.target, .imageCenter)
        assertEqual(result.x?.sourceCoordinate, 48, accuracy: Self.accuracy)
        assertEqual(result.x?.targetCoordinate, 50, accuracy: Self.accuracy)
        XCTAssertEqual(result.y?.anchor, .center)
        XCTAssertEqual(result.y?.target, .imageCenter)
        assertEqual(result.y?.sourceCoordinate, 38, accuracy: Self.accuracy)
        assertEqual(result.y?.targetCoordinate, 40, accuracy: Self.accuracy)
    }

    func testFractionalImageOriginIsSnappedWithoutPixelRounding() {
        // Image x extent 10.5 ... 110.5. Trailing anchor 109.25 is 1.25
        // from 110.5; the correction stays fractional, never rounded.
        let result = plan(input(moving: CGRect(x: 101.25, y: 30, width: 8, height: 8),
                               imageBounds: CGRect(x: 10.5, y: 20.25, width: 100, height: 80)))
        XCTAssertEqual(result.dx, 1.25, accuracy: 1e-12)
        XCTAssertEqual(result.x?.target, .imageEdge)
        assertEqual(result.x?.targetCoordinate, 110.5, accuracy: 1e-12)
        XCTAssertEqual(result.dy, 0, accuracy: Self.accuracy)
        XCTAssertNil(result.y)
    }

    // MARK: Tolerance conversion by canvas scale

    func testViewPointToleranceIsDividedByTheCanvasScale() {
        // 8 view points at 4 points per image unit = 2 image units.
        // A trailing anchor exactly 2 units from the guide snaps
        // (inclusive), 3.5 does not.
        let guide = input(moving: CGRect(x: 46, y: 10, width: 2, height: 2), verticalGuides: [50])
        let snapped = plan(guide, targets: [.guide], canvasScale: 4)
        XCTAssertEqual(snapped.dx, 2, accuracy: Self.accuracy)
        XCTAssertEqual(snapped.x?.anchor, .trailing)
        assertEqual(snapped.x?.sourceCoordinate, 48, accuracy: Self.accuracy)
        assertEqual(snapped.x?.targetCoordinate, 50, accuracy: Self.accuracy)

        let missed = plan(input(moving: CGRect(x: 44.5, y: 10, width: 2, height: 2), verticalGuides: [50]),
                          targets: [.guide], canvasScale: 4)
        XCTAssertEqual(missed, .none)
        // At scale 1 the same 3.5-unit distance is within 8 units.
        let wide = plan(input(moving: CGRect(x: 44.5, y: 10, width: 2, height: 2), verticalGuides: [50]),
                        targets: [.guide], canvasScale: 1)
        XCTAssertEqual(wide.dx, 3.5, accuracy: Self.accuracy)
    }

    // MARK: Two axes and target kinds

    func testAxesSnapIndependentlyToDifferentTargetKinds() {
        // x: anchors 24/28/32; guide 31 — trailing 32 is 1 away (dx -1).
        // y: anchors 64/68/72; layer edge 70 — centre 68 is 2 away (dy +2).
        let result = plan(input(moving: CGRect(x: 24, y: 64, width: 8, height: 8),
                               verticalGuides: [31],
                               otherLayerRects: [CGRect(x: 60, y: 50, width: 20, height: 20)]))
        XCTAssertEqual(result.dx, -1, accuracy: Self.accuracy)
        XCTAssertEqual(result.dy, 2, accuracy: Self.accuracy)
        XCTAssertEqual(result.x?.anchor, .trailing)
        XCTAssertEqual(result.x?.target, .guide)
        assertEqual(result.x?.sourceCoordinate, 32, accuracy: Self.accuracy)
        assertEqual(result.x?.targetCoordinate, 31, accuracy: Self.accuracy)
        XCTAssertEqual(result.y?.anchor, .center)
        XCTAssertEqual(result.y?.target, .layerEdge)
        assertEqual(result.y?.sourceCoordinate, 68, accuracy: Self.accuracy)
        assertEqual(result.y?.targetCoordinate, 70, accuracy: Self.accuracy)
    }

    func testOtherLayerCentreSnaps() {
        // Layer centre x is 70; leading anchor 73 is 3 away (dx -3).
        let result = plan(input(moving: CGRect(x: 73, y: 10, width: 8, height: 8),
                               otherLayerRects: [CGRect(x: 60, y: 50, width: 20, height: 20)]),
                          targets: [.layerCenter])
        XCTAssertEqual(result.dx, -3, accuracy: Self.accuracy)
        XCTAssertEqual(result.x?.anchor, .leading)
        XCTAssertEqual(result.x?.target, .layerCenter)
        assertEqual(result.x?.targetCoordinate, 70, accuracy: Self.accuracy)
        XCTAssertNil(result.y)
    }

    // MARK: Deterministic ties

    func testTieBetweenKindsPrefersImageEdgeOverGuide() {
        // Leading anchor 50 is exactly 2 from image max 48 and from guide
        // 52; imageEdge has priority, so dx = 48 - 50 = -2.
        let result = plan(input(moving: CGRect(x: 50, y: 10, width: 8, height: 8),
                               imageBounds: CGRect(x: 0, y: 0, width: 48, height: 80),
                               verticalGuides: [52]))
        XCTAssertEqual(result.dx, -2, accuracy: Self.accuracy)
        XCTAssertEqual(result.x?.target, .imageEdge)
        assertEqual(result.x?.targetCoordinate, 48, accuracy: Self.accuracy)
    }

    func testTieBetweenAnchorsPrefersLeadingOverCentre() {
        // Anchors 10/12/14; guide 11 is 1 from both 10 and 12. Leading
        // comes first in anchor order, so dx = 11 - 10 = +1.
        let result = plan(input(moving: CGRect(x: 10, y: 10, width: 4, height: 4),
                               verticalGuides: [11]))
        XCTAssertEqual(result.dx, 1, accuracy: Self.accuracy)
        XCTAssertEqual(result.x?.anchor, .leading)
        assertEqual(result.x?.sourceCoordinate, 10, accuracy: Self.accuracy)
        assertEqual(result.x?.targetCoordinate, 11, accuracy: Self.accuracy)
    }

    // MARK: Disabled targets

    func testDisabledTargetKindsContributeNoCandidates() {
        let moving = CGRect(x: 97, y: 10, width: 8, height: 8)
        // Guides only: leading 97 snaps to guide 99 (dx +2); image max
        // 100 at distance 3 is not considered.
        let guideOnly = plan(input(moving: moving, verticalGuides: [99]), targets: [.guide])
        XCTAssertEqual(guideOnly.dx, 2, accuracy: Self.accuracy)
        XCTAssertEqual(guideOnly.x?.target, .guide)
        assertEqual(guideOnly.x?.targetCoordinate, 99, accuracy: Self.accuracy)
        // Image edges only: centre 101 is 1 from image max 100 (dx -1).
        let edgeOnly = plan(input(moving: moving), targets: [.imageEdge])
        XCTAssertEqual(edgeOnly.dx, -1, accuracy: Self.accuracy)
        XCTAssertEqual(edgeOnly.x?.anchor, .center)
        XCTAssertEqual(edgeOnly.x?.target, .imageEdge)
        // No targets at all: no plan.
        XCTAssertEqual(plan(input(moving: moving), targets: []), .none)
        // Enabled kind with no nearby line: no plan.
        XCTAssertEqual(plan(input(moving: CGRect(x: 50, y: 10, width: 8, height: 8)),
                            targets: [.guide]), .none)
    }

    // MARK: Grid: nearest lattice line with an offset, above and below

    func testGridSnapsToNearestLatticeLineAboveTheAnchor() {
        // Lattice at 3 + 10k. Anchors x: 4.4, 8.4, 12.4. Nearest lines:
        // 3 (1.4), 13 (4.6), 13 (0.6) — trailing wins, dx = 13 - 12.4.
        let grid = CanvasSnapPlanner.Grid(spacingX: 10, spacingY: 10, offsetX: 3, offsetY: 3)
        let result = plan(input(moving: CGRect(x: 4.4, y: 10, width: 8, height: 8), grid: grid),
                          targets: [.grid])
        XCTAssertEqual(result.dx, 0.6, accuracy: Self.accuracy)
        XCTAssertEqual(result.x?.anchor, .trailing)
        XCTAssertEqual(result.x?.target, .grid)
        assertEqual(result.x?.sourceCoordinate, 12.4, accuracy: Self.accuracy)
        assertEqual(result.x?.targetCoordinate, 13, accuracy: Self.accuracy)
        // y anchors 10/14/18: nearest lines 13 (3), 13 (1), 23 (5).
        XCTAssertEqual(result.dy, -1, accuracy: Self.accuracy)
        XCTAssertEqual(result.y?.anchor, .center)
        assertEqual(result.y?.targetCoordinate, 13, accuracy: Self.accuracy)
    }

    func testGridSnapsToNearestLatticeLineBelowTheAnchor() {
        // Anchors x: 2.5, 6.5, 10.5. Nearest lines: 3 (0.5), 3 (3.5),
        // 13 (2.5) — leading wins, dx = 3 - 2.5 = +0.5.
        let grid = CanvasSnapPlanner.Grid(spacingX: 10, spacingY: 10, offsetX: 3, offsetY: 3)
        let result = plan(input(moving: CGRect(x: 2.5, y: 10, width: 8, height: 8), grid: grid),
                          targets: [.grid])
        XCTAssertEqual(result.dx, 0.5, accuracy: Self.accuracy)
        XCTAssertEqual(result.x?.anchor, .leading)
        assertEqual(result.x?.targetCoordinate, 3, accuracy: Self.accuracy)
    }

    // MARK: Extreme grid geometry: index precision, no enumeration

    func testHugeSpanOverTinySpacingRejectsTheGridSafely() {
        // quotient = 1e300 / 1e-3 = 1e303, far beyond 2^53: the lattice
        // index is unrepresentable, so the grid contributes nothing and
        // the result is a clean no-correction.
        let grid = CanvasSnapPlanner.Grid(spacingX: 1e-3, spacingY: 1e-3, offsetX: 0, offsetY: 0)
        let result = plan(input(moving: CGRect(x: 1e300, y: 1e300, width: 8, height: 8), grid: grid),
                          targets: [.grid])
        XCTAssertEqual(result, .none)
        XCTAssertTrue(result.dx.isFinite && result.dy.isFinite)
    }

    func testOverflowingGridQuotientRejectsTheGridSafely() {
        // value - offset = 1e308 - (-1e308) overflows to +inf: rejected
        // before any index is formed.
        let grid = CanvasSnapPlanner.Grid(spacingX: 10, spacingY: 10, offsetX: -1e308, offsetY: -1e308)
        let result = plan(input(moving: CGRect(x: 1e308, y: 1e308, width: 8, height: 8), grid: grid),
                          targets: [.grid])
        XCTAssertEqual(result, .none)
    }

    func testLatticeIndexAtExactly2ToThe53IsAccepted() {
        // quotient = 2^53 exactly: representable, accepted; the nearest
        // line is the anchor itself, dx = 0. The centre/trailing anchors
        // (2^53 + 4, 2^53 + 8) exceed 2^53 and are rejected without harm.
        let grid = CanvasSnapPlanner.Grid(spacingX: 1, spacingY: 1, offsetX: 0, offsetY: 0)
        let result = plan(input(moving: CGRect(x: 9007199254740992, y: 10, width: 8, height: 8),
                               grid: grid),
                          targets: [.grid])
        XCTAssertEqual(result.dx, 0, accuracy: Self.accuracy)
        XCTAssertEqual(result.x?.target, .grid)
        assertEqual(result.x?.targetCoordinate, 9007199254740992, accuracy: 0)
    }

    func testLatticeIndexBeyond2ToThe53IsRejected() {
        // quotient = 2^54 > 2^53: unrepresentable index, no grid match.
        let grid = CanvasSnapPlanner.Grid(spacingX: 1, spacingY: 1, offsetX: 0, offsetY: 0)
        let result = plan(input(moving: CGRect(x: 18014398509481984, y: 1e300, width: 8, height: 8),
                               grid: grid),
                          targets: [.grid])
        XCTAssertEqual(result, .none)
    }

    // MARK: Invalid, non-finite or degenerate input returns no correction

    func testNonFiniteAndDegenerateInputsReturnNone() {
        let grid = CanvasSnapPlanner.Grid(spacingX: 10, spacingY: 10, offsetX: 0, offsetY: 0)
        let valid = input(moving: CGRect(x: 10, y: 10, width: 8, height: 8), grid: grid)

        var broken = valid
        broken.movingRect = CGRect(x: Double.nan, y: 10, width: 8, height: 8)
        XCTAssertEqual(plan(broken), .none)

        broken = valid
        broken.movingRect = CGRect(x: 10, y: Double.infinity, width: 8, height: 8)
        XCTAssertEqual(plan(broken), .none)

        broken = valid
        broken.movingRect = CGRect(x: 10, y: 10, width: 0, height: 8)
        XCTAssertEqual(plan(broken), .none)

        broken = valid
        broken.imageBounds = CGRect(x: 0, y: 0, width: -5, height: 80)
        XCTAssertEqual(plan(broken), .none)

        broken = valid
        broken.verticalGuides = [Double.infinity]
        XCTAssertEqual(plan(broken), .none)

        broken = valid
        broken.horizontalGuides = [Double.nan]
        XCTAssertEqual(plan(broken), .none)

        broken = valid
        broken.otherLayerRects = [CGRect(x: 0, y: 0, width: Double.nan, height: 10)]
        XCTAssertEqual(plan(broken), .none)

        broken = valid
        broken.grid = CanvasSnapPlanner.Grid(spacingX: 0, spacingY: 10, offsetX: 0, offsetY: 0)
        XCTAssertEqual(plan(broken), .none)

        broken = valid
        broken.grid = CanvasSnapPlanner.Grid(spacingX: -1, spacingY: 10, offsetX: 0, offsetY: 0)
        XCTAssertEqual(plan(broken), .none)

        broken = valid
        broken.grid = CanvasSnapPlanner.Grid(spacingX: Double.nan, spacingY: 10, offsetX: 0, offsetY: 0)
        XCTAssertEqual(plan(broken), .none)

        broken = valid
        broken.grid = CanvasSnapPlanner.Grid(spacingX: 10, spacingY: 10, offsetX: Double.infinity, offsetY: 0)
        XCTAssertEqual(plan(broken), .none)
    }

    func testNonPositiveOrNonFiniteCanvasScaleReturnsNone() {
        let validInput = self.input(moving: CGRect(x: 90.5, y: 10, width: 8, height: 8))
        for scale: Double in [0, -1, -0.5, Double.nan, Double.infinity, -Double.infinity] {
            let result = plan(validInput, canvasScale: scale)
            XCTAssertEqual(result, .none, "scale \(scale)")
            XCTAssertTrue(result.dx.isFinite && result.dy.isFinite)
        }
    }

    func testDenormalScaleThatOverflowsTheToleranceReturnsNone() {
        // 8 / 5e-324 overflows to +inf; the planner refuses to plan with
        // an infinite image-space tolerance.
        let validInput = self.input(moving: CGRect(x: 90.5, y: 10, width: 8, height: 8))
        XCTAssertEqual(plan(validInput, canvasScale: 5e-324), .none)
    }

    func testInvalidToleranceReturnsNone() {
        let validInput = self.input(moving: CGRect(x: 90.5, y: 10, width: 8, height: 8))
        for tolerance: Double in [-1, Double.nan, Double.infinity] {
            XCTAssertEqual(plan(validInput, viewPointTolerance: tolerance), .none, "tolerance \(tolerance)")
        }
        // Zero tolerance is valid: exact coincidences still snap.
        let exact = plan(input(moving: CGRect(x: 92, y: 10, width: 8, height: 8),
                            verticalGuides: [100]),
                         targets: [.guide], viewPointTolerance: 0)
        XCTAssertEqual(exact.dx, 0, accuracy: Self.accuracy)
        XCTAssertEqual(exact.x?.anchor, .trailing)
        assertEqual(exact.x?.targetCoordinate, 100, accuracy: Self.accuracy)
        let off = plan(input(moving: CGRect(x: 92.5, y: 10, width: 8, height: 8),
                             verticalGuides: [100]),
                       targets: [.guide], viewPointTolerance: 0)
        XCTAssertEqual(off, .none)
    }
}
