import CoreGraphics
import XCTest
@testable import GlimsKit

/// The projective modes of `LayerTransformSession`: the `A · W · N`
/// unit-square warp owned by the session on top of its affine frame.
/// Expectations are analytic, derived by hand from the homographies, not
/// round trips through the code under test.
final class ProjectiveTransformSessionTests: XCTestCase {
    /// A 100×100 layer at the origin keeps the arithmetic readable.
    private let square = CGRect(x: 0, y: 0, width: 100, height: 100)

    private func assertEqual(_ a: CGPoint?, _ b: CGPoint, accuracy: Double = 1e-6,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let a else {
            XCTFail("nil point, expected \(b)", file: file, line: line)
            return
        }
        XCTAssertEqual(a.x, b.x, accuracy: accuracy, "x", file: file, line: line)
        XCTAssertEqual(a.y, b.y, accuracy: accuracy, "y", file: file, line: line)
    }

    private func assertEqual(_ a: ProjectiveTransform, _ coefficients: [Double],
                             accuracy: Double = 1e-9,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.coefficients.count, coefficients.count, file: file, line: line)
        for (value, expected) in zip(a.coefficients, coefficients) {
            XCTAssertEqual(value, expected, accuracy: accuracy, file: file, line: line)
        }
    }

    // MARK: 1. Default session stays pure affine

    func testDefaultSessionKeepsPureAffineBehavior() {
        var session = LayerTransformSession(layer: 1, bounds: square)

        XCTAssertEqual(session.mode, .scaleRotate)
        XCTAssertTrue(session.isIdentity)
        XCTAssertTrue(session.matrix.isIdentity)
        // The homography degrades exactly to the affine frame.
        assertEqual(session.projectiveMatrix, [1, 0, 0, 0, 1, 0, 0, 0, 1])
        assertEqual(session.corners[2], CGPoint(x: 100, y: 100))
        XCTAssertEqual(session.corners, session.frameCorners)
        XCTAssertEqual(session.corners, session.imageCorners)

        // Scale, rotate and the value-taking update behave as before.
        session.update(session.beginDrag(.corner(2), at: CGPoint(x: 100, y: 100)),
                       to: CGPoint(x: 200, y: 150), constrained: false)
        XCTAssertEqual(session.box, CGRect(x: 0, y: 0, width: 200, height: 150))
        let affine = session.matrix
        assertEqual(session.projectiveMatrix,
                    [affine.a, affine.c, affine.tx, affine.b, affine.d, affine.ty, 0, 0, 1])

        XCTAssertTrue(session.setGeometry(origin: .zero, width: 100,
                                          height: 100, degrees: 0))
        XCTAssertTrue(session.isIdentity)
    }

    // MARK: 2. Distort

    func testDistortTranslatesOneCornerOnly() {
        var session = LayerTransformSession(layer: 7, bounds: square)
        session.setMode(.distort)
        var drag = session.beginDrag(.corner(1), at: CGPoint(x: 100, y: 0))

        session.update(&drag, to: CGPoint(x: 80, y: 0), constrained: false)

        // Solved by hand: the unique homography sending the 100×100
        // square onto (0,0), (80,0), (100,100), (0,100).
        assertEqual(session.projectiveMatrix,
                    [0.8, 0, 0, 0, 0.8, 0, 0, -0.002, 1])
        // Corner order is TL, TR, BR, BL.
        assertEqual(session.imageCorners[0], CGPoint(x: 0, y: 0))
        assertEqual(session.imageCorners[1], CGPoint(x: 80, y: 0))
        assertEqual(session.imageCorners[2], CGPoint(x: 100, y: 100))
        assertEqual(session.imageCorners[3], CGPoint(x: 0, y: 100))

        // The center maps through H, not to the corner average (45, 50).
        assertEqual(session.imagePoint(atUnit: CGPoint(x: 0.5, y: 0.5)),
                    CGPoint(x: 400.0 / 9, y: 400.0 / 9))

        // The frame is untouched: only the warp moved.
        XCTAssertEqual(session.box, square)
        XCTAssertEqual(session.angle, 0)
        XCTAssertTrue(session.matrix.isIdentity)
        XCTAssertFalse(session.isIdentity)
        // In a warped mode the handle corners are the warped quad.
        XCTAssertEqual(session.corners, session.imageCorners)
        XCTAssertNotEqual(session.corners, session.frameCorners)
    }

    func testDistortGridSegmentsAreTrueProjectiveThirds() {
        var session = LayerTransformSession(layer: 7, bounds: square)
        session.setMode(.distort)
        var drag = session.beginDrag(.corner(1), at: CGPoint(x: 100, y: 0))
        session.update(&drag, to: CGPoint(x: 80, y: 0), constrained: false)

        let segments = session.gridSegments
        XCTAssertEqual(segments.count, 4)
        // First vertical third: (100/3,0)→(80/3,0) and
        // (100/3,100)→(100/3,100) under H.
        assertEqual(segments[0].start, CGPoint(x: 80.0 / 3, y: 0))
        assertEqual(segments[0].end, CGPoint(x: 100.0 / 3, y: 100))
        // First horizontal third: (0,100/3)→(0,200/7) and
        // (100,100/3)→(600/7,200/7). Linear interpolation between the
        // destination edges would give y = 100/3 instead.
        assertEqual(segments[2].start, CGPoint(x: 0, y: 200.0 / 7))
        assertEqual(segments[2].end, CGPoint(x: 600.0 / 7, y: 200.0 / 7))

        // The checked inverse takes the mapped center back to (50, 50).
        let inverse = session.projectiveMatrix.inverse
        XCTAssertNotNil(inverse)
        assertEqual(inverse?.project(CGPoint(x: 400.0 / 9, y: 400.0 / 9)),
                    CGPoint(x: 50, y: 50))
    }

    func testDistortEdgeSlideTranslatesBothCorners() {
        var session = LayerTransformSession(layer: 7, bounds: square)
        session.setMode(.distort)
        // An edge drag translates its two corners together.
        var edge = session.beginDrag(.edge(2), at: CGPoint(x: 50, y: 100))
        session.update(&edge, to: CGPoint(x: 70, y: 100), constrained: false)
        assertEqual(session.imageCorners[2], CGPoint(x: 120, y: 100))
        assertEqual(session.imageCorners[3], CGPoint(x: 20, y: 100))
        assertEqual(session.imageCorners[0], CGPoint(x: 0, y: 0))
        assertEqual(session.imageCorners[1], CGPoint(x: 100, y: 0))
    }

    // MARK: 3. Skew

    func testSkewSlidesTopEdgeAlongItself() {
        var session = LayerTransformSession(layer: 3, bounds: square)
        session.setMode(.skew)
        // The press point need not sit exactly on the handle: deltas, not
        // absolute positions, drive the edit, so tolerance does not jump.
        var drag = session.beginDrag(.edge(0), at: CGPoint(x: 48, y: 2))
        session.update(&drag, to: CGPoint(x: 68, y: 2), constrained: false)

        assertEqual(session.imageCorners[0], CGPoint(x: 20, y: 0))
        assertEqual(session.imageCorners[1], CGPoint(x: 120, y: 0))
        // The opposite edge is exactly fixed.
        assertEqual(session.imageCorners[2], CGPoint(x: 100, y: 100))
        assertEqual(session.imageCorners[3], CGPoint(x: 0, y: 100))
        // Affine shear + translate: x' = 20 + x - 0.2y, y' = y.
        assertEqual(session.imagePoint(atUnit: CGPoint(x: 0.5, y: 0.5)),
                    CGPoint(x: 60, y: 50))
    }

    func testSkewIgnoresPerpendicularPointerComponent() {
        var session = LayerTransformSession(layer: 3, bounds: square)
        session.setMode(.skew)
        var drag = session.beginDrag(.edge(0), at: CGPoint(x: 50, y: 0))
        session.update(&drag, to: CGPoint(x: 70, y: 40), constrained: false)

        // Only the along-edge component (20 px) moves the edge.
        assertEqual(session.imageCorners[0], CGPoint(x: 20, y: 0))
        assertEqual(session.imageCorners[1], CGPoint(x: 120, y: 0))
    }

    func testPerpendicularSkewPreservesExactCapturedWarp() {
        var session = LayerTransformSession(
            layer: 3, bounds: CGRect(x: -37, y: 201, width: 117, height: 81))
        session.setMode(.distort)
        var distort = session.beginDrag(.corner(1), at: CGPoint(x: 80, y: 201))
        session.update(&distort, to: CGPoint(x: 63, y: 201), constrained: false)
        session.setMode(.skew)
        let captured = session
        var drag = session.beginDrag(.edge(0), at: session.edgeMiddles[0])
        let start = drag.start
        session.update(&drag, to: CGPoint(x: start.x + 10, y: start.y), constrained: false)
        XCTAssertNotEqual(session, captured)
        // The top edge is horizontal. A purely vertical sample has no
        // effective skew, even after the same gesture moved it earlier.
        session.update(&drag, to: CGPoint(x: start.x, y: start.y + 25), constrained: false)
        XCTAssertEqual(session, captured)
    }

    func testSkewFollowsCapturedEdgeDirectionInTurnedFrame() {
        var session = LayerTransformSession(layer: 3,
                                            bounds: CGRect(x: 0, y: 0,
                                                           width: 200, height: 100))
        // Turn 90° clockwise: the top edge runs straight down the image.
        session.update(session.beginDrag(.rotate, at: CGPoint(x: 300, y: 50)),
                       to: CGPoint(x: 100, y: 250), constrained: false)
        XCTAssertEqual(session.angle, .pi / 2, accuracy: 1e-9)
        assertEqual(session.frameCorners[0], CGPoint(x: 150, y: -50))
        assertEqual(session.frameCorners[1], CGPoint(x: 150, y: 150))

        session.setMode(.skew)
        var drag = session.beginDrag(.edge(0), at: CGPoint(x: 150, y: 50))
        session.update(&drag, to: CGPoint(x: 150, y: 80), constrained: false)

        // The captured edge direction is vertical, so the whole 30 px
        // delta slides the edge down; the opposite edge stays fixed.
        assertEqual(session.imageCorners[0], CGPoint(x: 150, y: -20))
        assertEqual(session.imageCorners[1], CGPoint(x: 150, y: 180))
        assertEqual(session.imageCorners[2], CGPoint(x: 50, y: 150))
        assertEqual(session.imageCorners[3], CGPoint(x: 50, y: -50))
        // The frame itself was not scaled or moved.
        assertEqual(session.frameCorners[0], CGPoint(x: 150, y: -50))
        XCTAssertEqual(session.angle, .pi / 2, accuracy: 1e-9)
    }

    // MARK: 4. Perspective

    func testPerspectiveHorizontalDragPairsSameEdge() {
        var session = LayerTransformSession(layer: 5, bounds: square)
        session.setMode(.perspective)
        var drag = session.beginDrag(.corner(0), at: CGPoint(x: 0, y: 0))
        session.update(&drag, to: CGPoint(x: 20, y: 0), constrained: false)

        // TL and TR move in opposite equal directions along the top edge;
        // the bottom edge is fixed.
        assertEqual(session.imageCorners[0], CGPoint(x: 20, y: 0))
        assertEqual(session.imageCorners[1], CGPoint(x: 80, y: 0))
        assertEqual(session.imageCorners[2], CGPoint(x: 100, y: 100))
        assertEqual(session.imageCorners[3], CGPoint(x: 0, y: 100))
    }

    func testPerspectiveAxisLocksAndNeverSwitches() {
        var session = LayerTransformSession(layer: 5, bounds: square)
        session.setMode(.perspective)
        var drag = session.beginDrag(.corner(0), at: CGPoint(x: 0, y: 0))
        session.update(&drag, to: CGPoint(x: 20, y: 0), constrained: false)
        let locked = session.imageCorners

        // A later, larger vertical component must not switch the pairing:
        // the vertical component is simply unused.
        session.update(&drag, to: CGPoint(x: 20, y: 60), constrained: false)
        XCTAssertEqual(session.imageCorners, locked)
        assertEqual(session.imageCorners[3], CGPoint(x: 0, y: 100))
    }

    func testPerspectiveVerticalDragPairsLeftRightEdge() {
        var session = LayerTransformSession(layer: 5, bounds: square)
        session.setMode(.perspective)
        var drag = session.beginDrag(.corner(0), at: CGPoint(x: 0, y: 0))
        session.update(&drag, to: CGPoint(x: 0, y: 20), constrained: false)

        // TL and BL move in opposite equal directions along the left edge.
        assertEqual(session.imageCorners[0], CGPoint(x: 0, y: 20))
        assertEqual(session.imageCorners[1], CGPoint(x: 100, y: 0))
        assertEqual(session.imageCorners[2], CGPoint(x: 100, y: 100))
        assertEqual(session.imageCorners[3], CGPoint(x: 0, y: 80))
    }

    func testPerspectiveAxisTieChoosesHorizontal() {
        var session = LayerTransformSession(layer: 5, bounds: square)
        session.setMode(.perspective)
        var drag = session.beginDrag(.corner(0), at: CGPoint(x: 0, y: 0))
        session.update(&drag, to: CGPoint(x: 15, y: 15), constrained: false)

        assertEqual(session.imageCorners[0], CGPoint(x: 15, y: 0))
        assertEqual(session.imageCorners[1], CGPoint(x: 85, y: 0))
        assertEqual(session.imageCorners[2], CGPoint(x: 100, y: 100))
        assertEqual(session.imageCorners[3], CGPoint(x: 0, y: 100))
    }

    func testPerspectiveEdgeDragIsInactive() {
        var session = LayerTransformSession(layer: 5, bounds: square)
        session.setMode(.perspective)
        var drag = session.beginDrag(.edge(0), at: CGPoint(x: 50, y: 0))
        session.update(&drag, to: CGPoint(x: 90, y: 0), constrained: false)
        XCTAssertTrue(session.isIdentity)
    }

    // MARK: 5. Numeric edits and mode switches keep the warp

    func testNumericFrameEditPreservesWarpedShape() {
        var session = LayerTransformSession(layer: 9, bounds: square)
        session.setMode(.distort)
        var drag = session.beginDrag(.corner(1), at: CGPoint(x: 100, y: 0))
        session.update(&drag, to: CGPoint(x: 80, y: 0), constrained: false)
        let mapping = session.projectiveMatrix
        let oldMatrix = session.matrix
        let oldCorners = session.imageCorners

        XCTAssertTrue(session.setGeometry(origin: .zero, width: 200,
                                          height: 100, degrees: 0))

        // The new frame is twice as wide; the warp is unchanged, so the
        // image quad is the old quad under the frame delta A'·A⁻¹.
        let frameDelta = oldMatrix.inverted().concatenating(session.matrix)
        for (old, new) in zip(oldCorners, session.imageCorners) {
            assertEqual(new, old.applying(frameDelta))
        }
        assertEqual(session.imageCorners[1], CGPoint(x: 160, y: 0))
        assertEqual(session.imageCorners[2], CGPoint(x: 200, y: 100))
        let expected = mapping.followed(by: ProjectiveTransform(affine: frameDelta))
        assertEqual(session.projectiveMatrix, expected.coefficients)
    }

    func testModeSwitchPreservesMappingAndStaleDragCannotOverwrite() {
        var session = LayerTransformSession(layer: 9, bounds: square)
        session.setMode(.distort)
        var drag = session.beginDrag(.corner(1), at: CGPoint(x: 100, y: 0))
        session.update(&drag, to: CGPoint(x: 80, y: 0), constrained: false)
        let mapping = session.projectiveMatrix
        var stale = session.beginDrag(.corner(1), at: CGPoint(x: 80, y: 0))

        session.setMode(.scaleRotate)
        XCTAssertEqual(session.projectiveMatrix, mapping)
        // Frame-only handles return: rectangular corners, warped image.
        XCTAssertEqual(session.corners, session.frameCorners)
        assertEqual(session.corners[1], CGPoint(x: 100, y: 0))
        assertEqual(session.imageCorners[1], CGPoint(x: 80, y: 0))

        // The drag was captured under distort: it must not write back.
        session.update(&stale, to: CGPoint(x: 10, y: 10), constrained: false)
        XCTAssertEqual(session.mode, .scaleRotate)
        XCTAssertEqual(session.projectiveMatrix, mapping)
        assertEqual(session.imageCorners[1], CGPoint(x: 80, y: 0))
    }

    func testMoveKeepsTheWarp() {
        var session = LayerTransformSession(layer: 9, bounds: square)
        session.setMode(.distort)
        var corner = session.beginDrag(.corner(1), at: CGPoint(x: 100, y: 0))
        session.update(&corner, to: CGPoint(x: 80, y: 0), constrained: false)
        let quad = session.imageCorners

        var move = session.beginDrag(.move, at: CGPoint(x: 50, y: 50))
        session.update(&move, to: CGPoint(x: 60, y: 40), constrained: false)
        // The whole warped quad moved by the frame delta.
        for (old, new) in zip(quad, session.imageCorners) {
            assertEqual(new, CGPoint(x: old.x + 10, y: old.y - 10))
        }
        XCTAssertEqual(session.box, square.offsetBy(dx: 10, dy: -10))
    }

    func testNumericTranslationAndNonuniformScaleHaveAnalyticWarpedResult() {
        var session = LayerTransformSession(layer: 9, bounds: square)
        session.setMode(.distort)
        var drag = session.beginDrag(.corner(1), at: CGPoint(x: 100, y: 0))
        session.update(&drag, to: CGPoint(x: 80, y: 0), constrained: false)
        XCTAssertTrue(session.setGeometry(origin: CGPoint(x: 10, y: 20),
                                          width: 200, height: 300, degrees: 0))
        for (actual, expected) in zip(session.imageCorners, [
            CGPoint(x: 10, y: 20), CGPoint(x: 170, y: 20),
            CGPoint(x: 210, y: 320), CGPoint(x: 10, y: 320),
        ]) { assertEqual(actual, expected) }
        assertEqual(session.imagePoint(atUnit: CGPoint(x: 0.5, y: 0.5)),
                    CGPoint(x: 890.0 / 9, y: 460.0 / 3))
        session.setMode(.scaleRotate)
        assertEqual(session.corners[1], CGPoint(x: 210, y: 20))
        assertEqual(session.imageCorners[1], CGPoint(x: 170, y: 20))
    }

    func testScaleAndRotateUseAffineFrameWhilePreservingWarp() {
        var session = LayerTransformSession(layer: 9, bounds: square)
        session.setMode(.distort)
        var drag = session.beginDrag(.corner(1), at: CGPoint(x: 100, y: 0))
        session.update(&drag, to: CGPoint(x: 80, y: 0), constrained: false)
        session.setMode(.scaleRotate)
        var scale = session.beginDrag(.corner(1), at: CGPoint(x: 100, y: 0))
        session.update(&scale, to: CGPoint(x: 200, y: 0), constrained: false)
        XCTAssertEqual(session.box, CGRect(x: 0, y: 0, width: 200, height: 100))
        assertEqual(session.imageCorners[1], CGPoint(x: 160, y: 0))
        // Rotate the frame 90 degrees about its (100, 50) center.
        var rotate = session.beginDrag(.rotate, at: CGPoint(x: 200, y: 50))
        session.update(&rotate, to: CGPoint(x: 100, y: 150), constrained: false)
        for (actual, expected) in zip(session.imageCorners, [
            CGPoint(x: 150, y: -50), CGPoint(x: 150, y: 110),
            CGPoint(x: 50, y: 150), CGPoint(x: 50, y: -50),
        ]) { assertEqual(actual, expected) }
    }

    func testInvalidFrameDragsRetainLastValidWarpedState() {
        var base = LayerTransformSession(layer: 9, bounds: square)
        base.setMode(.distort)
        var distort = base.beginDrag(.corner(1), at: CGPoint(x: 100, y: 0))
        base.update(&distort, to: CGPoint(x: 80, y: 0), constrained: false)
        base.setMode(.scaleRotate)
        let cases: [(LayerTransformSession.Handle, CGPoint, CGPoint, CGPoint)] = [
            (.move, .zero, CGPoint(x: 10, y: 20), CGPoint(x: 2_000_000, y: 0)),
            (.corner(2), CGPoint(x: 100, y: 100), CGPoint(x: 120, y: 100),
             CGPoint(x: 600_000, y: 100)),
            (.rotate, CGPoint(x: 100, y: 50), CGPoint(x: 50, y: 100),
             CGPoint(x: Double.nan, y: 0)),
        ]
        for (handle, start, good, bad) in cases {
            var session = base
            var drag = session.beginDrag(handle, at: start)
            session.update(&drag, to: good, constrained: false)
            XCTAssertNotEqual(session, base)
            let valid = session
            session.update(&drag, to: bad, constrained: false)
            XCTAssertEqual(session, valid, "\(handle) admitted an invalid frame")
            XCTAssertNotNil(session.projectiveMatrix.projectedBounds(forSource: square))
        }
    }

    func testPerspectiveRejectsNonfiniteFirstSampleWithoutPoisoningAxis() {
        var session = LayerTransformSession(layer: 9, bounds: square)
        session.setMode(.perspective)
        var drag = session.beginDrag(.corner(0), at: .zero)
        let captured = session
        session.update(&drag, to: CGPoint(x: Double.infinity, y: 0), constrained: false)
        XCTAssertEqual(session, captured)
        session.update(&drag, to: CGPoint(x: 5, y: 20), constrained: false)
        assertEqual(session.imageCorners[0], CGPoint(x: 0, y: 20))
        assertEqual(session.imageCorners[3], CGPoint(x: 0, y: 80))
    }

    func testPerspectiveUsesProjectiveCenterAndRejectsNearPlaneCollapse() {
        var session = LayerTransformSession(layer: 9, bounds: square)
        session.setMode(.perspective)
        var drag = session.beginDrag(.corner(0), at: .zero)
        session.update(&drag, to: CGPoint(x: 20, y: 5), constrained: false)
        assertEqual(session.imagePoint(atUnit: CGPoint(x: 0.5, y: 0.5)),
                    CGPoint(x: 50, y: 37.5))
        session.update(&drag, to: CGPoint(x: 10, y: 40), constrained: false)
        assertEqual(session.imageCorners[0], CGPoint(x: 10, y: 0))
        assertEqual(session.imageCorners[1], CGPoint(x: 90, y: 0))
        let valid = session
        // Still convex, but normalized W at the far source edge < 0.02.
        session.update(&drag, to: CGPoint(x: 49.99, y: 0), constrained: false)
        XCTAssertEqual(session, valid)
        session.update(&drag, to: CGPoint(x: 60, y: 0), constrained: false)
        XCTAssertEqual(session, valid)
    }

    // MARK: 6. Rejection keeps the last valid state

    func testInvalidCandidatesKeepLastValidState() {
        var session = LayerTransformSession(layer: 11, bounds: square)
        session.setMode(.distort)
        var drag = session.beginDrag(.corner(1), at: CGPoint(x: 100, y: 0))
        session.update(&drag, to: CGPoint(x: 80, y: 0), constrained: false)
        let valid = session

        var next = session.beginDrag(.corner(1), at: CGPoint(x: 80, y: 0))
        let rejected: [(CGPoint, String)] = [
            (CGPoint(x: 10, y: 90), "folds the quad"),
            (CGPoint(x: 0, y: 0), "lands on the top-left corner"),
            (CGPoint(x: Double.nan, y: 0), "non-finite"),
            (CGPoint(x: Double.infinity, y: 0), "non-finite"),
            (CGPoint(x: 1e9, y: 0), "outside the coordinate bound"),
            // W at the bottom-left source corner drops to ~1% < near plane.
            (CGPoint(x: 0.5, y: 0), "crosses the horizon"),
        ]
        for (point, reason) in rejected {
            session.update(&next, to: point, constrained: false)
            XCTAssertEqual(session, valid, "accepted a candidate that \(reason)")
        }
    }

    func testZeroMotionAndReturnToStartRestoreCapturedGeometry() {
        let configurations: [(LayerTransformSession.Mode,
                              LayerTransformSession.Handle, CGPoint)] = [
            (.skew, .edge(0), CGPoint(x: 50, y: 0)),
            (.distort, .corner(1), CGPoint(x: 100, y: 0)),
            (.perspective, .corner(0), CGPoint(x: 0, y: 0)),
        ]
        for (mode, handle, press) in configurations {
            var session = LayerTransformSession(layer: 13, bounds: square)
            session.setMode(mode)
            let pristine = session
            var drag = session.beginDrag(handle, at: press)

            session.update(&drag, to: press, constrained: false)
            XCTAssertEqual(session, pristine, "\(mode): zero motion changed state")

            session.update(&drag, to: CGPoint(x: press.x + 15, y: press.y),
                           constrained: false)
            session.update(&drag, to: press, constrained: false)
            XCTAssertEqual(session, pristine,
                           "\(mode): returning to the press did not restore state")
        }
    }

    func testNegativeAndOffsetSourceOrigins() {
        var session = LayerTransformSession(
            layer: 15, bounds: CGRect(x: -50, y: 200, width: 100, height: 100))
        session.setMode(.distort)
        var drag = session.beginDrag(.corner(2), at: CGPoint(x: 50, y: 300))
        session.update(&drag, to: CGPoint(x: 60, y: 310), constrained: false)

        assertEqual(session.imageCorners[0], CGPoint(x: -50, y: 200))
        assertEqual(session.imageCorners[1], CGPoint(x: 50, y: 200))
        assertEqual(session.imageCorners[2], CGPoint(x: 60, y: 310))
        assertEqual(session.imageCorners[3], CGPoint(x: -50, y: 300))

        // The homography works on the real source coordinates.
        let transform = session.projectiveMatrix
        assertEqual(transform.project(CGPoint(x: 50, y: 300)),
                    CGPoint(x: 60, y: 310))
        let center = transform.project(CGPoint(x: 0, y: 250))
        XCTAssertNotNil(center)
        if let center {
            assertEqual(transform.inverse?.project(center), CGPoint(x: 0, y: 250))
        }
    }

    func testHitTestingInsideFrameButOutsideWarpedQuad() {
        var session = LayerTransformSession(layer: 17, bounds: square)
        session.setMode(.distort)
        var drag = session.beginDrag(.corner(1), at: CGPoint(x: 100, y: 0))
        session.update(&drag, to: CGPoint(x: 60, y: 10), constrained: false)

        // (90, 5) is inside the rectangular frame but above the quad's
        // top edge (0,0)→(60,10).
        XCTAssertTrue(square.contains(CGPoint(x: 90, y: 5)))
        XCTAssertFalse(session.containsImagePoint(CGPoint(x: 90, y: 5)))
        XCTAssertTrue(session.containsImagePoint(CGPoint(x: 50, y: 60)))

        // In distort mode the outside point rotates; after setMode the
        // same point inside the frame moves.
        XCTAssertEqual(session.handle(at: CGPoint(x: 90, y: 5), tolerance: 3),
                       .rotate)
        session.setMode(.scaleRotate)
        XCTAssertEqual(session.handle(at: CGPoint(x: 90, y: 5), tolerance: 3),
                       .move)
    }

    func testEdgeMiddlesAreArithmeticNotSourceMidpointImages() {
        var session = LayerTransformSession(layer: 19, bounds: square)
        session.setMode(.distort)
        var drag = session.beginDrag(.corner(1), at: CGPoint(x: 100, y: 0))
        session.update(&drag, to: CGPoint(x: 60, y: 10), constrained: false)

        // Arithmetic midpoint of the warped top edge (0,0)→(60,10).
        assertEqual(session.edgeMiddles[0], CGPoint(x: 30, y: 5))
        // The image of the source top-edge midpoint (50,0) is elsewhere:
        // (600/19, 100/19) under the solved homography.
        assertEqual(session.imagePoint(atUnit: CGPoint(x: 0.5, y: 0)),
                    CGPoint(x: 600.0 / 19, y: 100.0 / 19))
    }
    func testHiddenHandleKindsDoNotCapturePointerHits() {
        var session = LayerTransformSession(layer: 1, bounds: square)
        session.setMode(.skew)
        XCTAssertEqual(session.handle(at: CGPoint(x: 0, y: 0), tolerance: 3), .move)
        XCTAssertEqual(session.handle(at: CGPoint(x: 50, y: 0), tolerance: 3), .edge(0))
        session.setMode(.perspective)
        XCTAssertEqual(session.handle(at: CGPoint(x: 50, y: 0), tolerance: 3), .move)
        XCTAssertEqual(session.handle(at: CGPoint(x: 0, y: 0), tolerance: 3), .corner(0))
    }

    func testModeMenuIdentityIsStableAndRejectsUnknownTags() {
        XCTAssertEqual(LayerTransformSession.Mode.allCases.map(\.menuTag), [2001, 2002, 2003, 2004])
        XCTAssertEqual(Set(LayerTransformSession.Mode.allCases.map(\.title)).count, 4)
        for mode in LayerTransformSession.Mode.allCases {
            XCTAssertEqual(LayerTransformSession.Mode.from(menuTag: mode.menuTag), mode)
        }
        XCTAssertNil(LayerTransformSession.Mode.from(menuTag: 0))
        XCTAssertNil(LayerTransformSession.Mode.from(menuTag: 2005))
    }

}
