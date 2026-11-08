import CoreGraphics
import XCTest
@testable import GlimsKit

/// Pure tests for direct guide dragging: the axis/extent/rounding rules a
/// drop commits with, the view-point hit tolerance of the Move tool, and
/// the ghost line's image-to-view geometry across zoom, backing factor and
/// out-of-image positions. No engine, window or document involved.
final class GuideDraggingTests: XCTestCase {
    private static let accuracy = 1e-9

    private func guide(_ id: Int32, _ orientation: EngineSession.GuideOrientation,
                       _ position: Int32) -> EngineSession.Guide {
        EngineSession.Guide(id: id, orientation: orientation, position: position)
    }

    // MARK: Axis coordinate and extent

    func testDropContainmentIncludesBothImageAxes() {
        XCTAssertTrue(GuideDragLogic.containsImagePoint(CGPoint(x: 0, y: 0), width: 400, height: 300))
        XCTAssertTrue(GuideDragLogic.containsImagePoint(CGPoint(x: 400, y: 300), width: 400, height: 300))
        for point in [CGPoint(x: -1, y: 60), CGPoint(x: 401, y: 60),
                      CGPoint(x: 60, y: -1), CGPoint(x: 60, y: 301),
                      CGPoint(x: Double.nan, y: 60), CGPoint(x: 60, y: Double.infinity)] {
            XCTAssertFalse(GuideDragLogic.containsImagePoint(point, width: 400, height: 300))
        }
    }

    func testAxisCoordinateReadsTheGuidesOwnAxis() {
        // A horizontal guide's position is a y coordinate, a vertical one's
        // an x coordinate.
        XCTAssertEqual(GuideDragLogic.axisCoordinate(.horizontal, of: CGPoint(x: 11, y: 42)), 42)
        XCTAssertEqual(GuideDragLogic.axisCoordinate(.vertical, of: CGPoint(x: 11, y: 42)), 11)
    }

    func testExtentMatchesTheSheetAndNativeRange() {
        XCTAssertEqual(GuideDragLogic.extent(.horizontal, width: 400, height: 300), 300)
        XCTAssertEqual(GuideDragLogic.extent(.vertical, width: 400, height: 300), 400)
    }

    func testIsInsideImageUsesTheInclusiveRawRange() {
        // The raw fractional coordinate decides inside/outside, before any
        // rounding: the surround (negative or past the extent) is outside.
        XCTAssertTrue(GuideDragLogic.isInsideImage(0, orientation: .horizontal, width: 400, height: 300))
        XCTAssertTrue(GuideDragLogic.isInsideImage(300, orientation: .horizontal, width: 400, height: 300))
        XCTAssertTrue(GuideDragLogic.isInsideImage(123.75, orientation: .horizontal, width: 400, height: 300))
        XCTAssertFalse(GuideDragLogic.isInsideImage(-0.01, orientation: .horizontal, width: 400, height: 300))
        XCTAssertFalse(GuideDragLogic.isInsideImage(300.01, orientation: .horizontal, width: 400, height: 300))
        XCTAssertFalse(GuideDragLogic.isInsideImage(.nan, orientation: .horizontal, width: 400, height: 300))
        XCTAssertFalse(GuideDragLogic.isInsideImage(.infinity, orientation: .vertical, width: 400, height: 300))
        // The other axis's extent does not apply.
        XCTAssertFalse(GuideDragLogic.isInsideImage(350, orientation: .horizontal, width: 400, height: 300))
        XCTAssertTrue(GuideDragLogic.isInsideImage(350, orientation: .vertical, width: 400, height: 300))
    }

    // MARK: Commit rounding: safe float-to-integer, bounded range

    func testCommitPositionRoundsToNearestPixelInsideTheRange() {
        XCTAssertEqual(GuideDragLogic.commitPosition(120.0, orientation: .horizontal, width: 400, height: 300), 120)
        XCTAssertEqual(GuideDragLogic.commitPosition(120.4, orientation: .horizontal, width: 400, height: 300), 120)
        XCTAssertEqual(GuideDragLogic.commitPosition(120.5, orientation: .horizontal, width: 400, height: 300), 121,
                       "half rounds away from zero")
        XCTAssertEqual(GuideDragLogic.commitPosition(299.6, orientation: .horizontal, width: 400, height: 300), 300,
                       "the far boundary is inclusive after rounding")
        XCTAssertEqual(GuideDragLogic.commitPosition(0, orientation: .vertical, width: 400, height: 300), 0)
        XCTAssertEqual(GuideDragLogic.commitPosition(400, orientation: .vertical, width: 400, height: 300), 400)
    }

    func testCommitPositionRefusesOutsideAndDamagedInput() {
        XCTAssertNil(GuideDragLogic.commitPosition(-0.5, orientation: .horizontal, width: 400, height: 300))
        XCTAssertNil(GuideDragLogic.commitPosition(300.5, orientation: .horizontal, width: 400, height: 300),
                     "rounds past the extent: refused")
        XCTAssertNil(GuideDragLogic.commitPosition(401, orientation: .vertical, width: 400, height: 300))
        XCTAssertNil(GuideDragLogic.commitPosition(.nan, orientation: .horizontal, width: 400, height: 300))
        XCTAssertNil(GuideDragLogic.commitPosition(.infinity, orientation: .horizontal, width: 400, height: 300))
        XCTAssertNil(GuideDragLogic.commitPosition(1e18, orientation: .horizontal, width: 400, height: 300),
                     "no unsafe float-to-integer conversion: Int32(exactly:) refuses")
    }

    // MARK: Hit testing in view points

    func testViewDistanceIsMeasuredInViewPointsOnTheGuideAxis() {
        let horizontal = guide(1, .horizontal, 100)
        // 10 image pixels off at 2 pt/px is 20 view points.
        XCTAssertEqual(GuideDragLogic.viewDistance(of: horizontal, at: CGPoint(x: 5, y: 110), scale: 2) ?? .nan, 20,
                       accuracy: Self.accuracy)
        // The other axis is irrelevant: a horizontal guide cares only about y.
        XCTAssertEqual(GuideDragLogic.viewDistance(of: horizontal, at: CGPoint(x: 9999, y: 100), scale: 2) ?? .nan, 0,
                       accuracy: Self.accuracy)
        XCTAssertNil(GuideDragLogic.viewDistance(of: horizontal, at: CGPoint(x: 0, y: 100), scale: 0))
        XCTAssertNil(GuideDragLogic.viewDistance(of: horizontal, at: CGPoint(x: 0, y: 100), scale: .nan))
    }

    func testHitTestFindsTheNearestGuideWithinTheViewPointTolerance() {
        let guides = [guide(1, .horizontal, 100), guide(2, .vertical, 50), guide(3, .horizontal, 104)]
        // At 1 pt/px the tolerance is 8 view points = 8 image pixels.
        let hit = GuideDragLogic.hitTest(guides: guides, guidesVisible: true,
                                         at: CGPoint(x: 80, y: 103), scale: 1)
        XCTAssertEqual(hit?.id, 3, "the nearest guide wins")
        XCTAssertNil(GuideDragLogic.hitTest(guides: guides, guidesVisible: true,
                                            at: CGPoint(x: 80, y: 120), scale: 1),
                     "nothing within tolerance")
        // At 8 pt/px the same image distance is 8x the view distance.
        XCTAssertNotNil(GuideDragLogic.hitTest(guides: guides, guidesVisible: true,
                                               at: CGPoint(x: 80, y: 101), scale: 8),
                        "at high zoom the tolerance covers only one image pixel")
        XCTAssertNil(GuideDragLogic.hitTest(guides: guides, guidesVisible: true,
                                            at: CGPoint(x: 80, y: 102), scale: 8),
                     "16 view points away is still a miss")
        // The tolerance edge itself is a hit.
        XCTAssertNotNil(GuideDragLogic.hitTest(guides: [guide(1, .horizontal, 100)], guidesVisible: true,
                                               at: CGPoint(x: 0, y: 100 + GuideDragLogic.hitTolerancePoints), scale: 1))
    }

    func testHitTestNeverHitsHiddenGuides() {
        let guides = [guide(1, .horizontal, 100)]
        XCTAssertNil(GuideDragLogic.hitTest(guides: guides, guidesVisible: false,
                                            at: CGPoint(x: 0, y: 100), scale: 1),
                     "with the guides overlay hidden the Move tool must not grab a guide")
        XCTAssertNil(GuideDragLogic.hitTest(guides: [], guidesVisible: true,
                                            at: CGPoint(x: 0, y: 100), scale: 1))
        XCTAssertNil(GuideDragLogic.hitTest(guides: guides, guidesVisible: true,
                                            at: CGPoint(x: 0, y: 100), scale: 1, tolerancePoints: -1))
    }

    // MARK: Ghost line geometry

    func testGhostLineSpansTheImageAtTheScaledPosition() {
        let image = CGSize(width: 400, height: 300)
        // 200% on a 2x screen: 1 view point per image pixel.
        let h = GuideDragLogic.lineEndpoints(orientation: .horizontal, position: 120, imageSize: image,
                                             zoomPercent: 200, backingFactor: 2)
        XCTAssertEqual(h?.0, CGPoint(x: 0, y: 120))
        XCTAssertEqual(h?.1, CGPoint(x: 400, y: 120))
        let v = GuideDragLogic.lineEndpoints(orientation: .vertical, position: 250.5, imageSize: image,
                                             zoomPercent: 200, backingFactor: 2)
        XCTAssertEqual(v?.0, CGPoint(x: 250.5, y: 0))
        XCTAssertEqual(v?.1, CGPoint(x: 250.5, y: 300))
    }

    func testGhostLineTracksZoomAndBackingThroughTheSharedPointScale() {
        let image = CGSize(width: 400, height: 300)
        // 100% on 1x: 1 pt/px; 100% on 2x: 0.5 pt/px; 800% on 2x: 4 pt/px.
        for (zoom, backing) in [(100, 1.0), (100, 2.0), (800, 2.0), (50, 1.0)] {
            let scale = CanvasGeometry.pointScale(zoomPercent: zoom, backingFactor: backing)
            let h = GuideDragLogic.lineEndpoints(orientation: .horizontal, position: 60, imageSize: image,
                                                 zoomPercent: zoom, backingFactor: backing)
            XCTAssertEqual(Double(h?.0.y ?? .nan), 60 * scale, accuracy: Self.accuracy, "zoom \(zoom) at \(backing)x")
            XCTAssertEqual(Double(h?.0.x ?? .nan), 0, accuracy: Self.accuracy)
            XCTAssertEqual(Double(h?.1.x ?? .nan), 400 * scale, accuracy: Self.accuracy)
        }
    }

    func testGhostLineIsNilOutsideTheDisplayedImageOrWithDamagedGeometry() {
        let image = CGSize(width: 400, height: 300)
        XCTAssertNil(GuideDragLogic.lineEndpoints(orientation: .horizontal, position: -0.5, imageSize: image,
                                                  zoomPercent: 100, backingFactor: 2))
        XCTAssertNil(GuideDragLogic.lineEndpoints(orientation: .horizontal, position: 300.5, imageSize: image,
                                                  zoomPercent: 100, backingFactor: 2))
        XCTAssertNil(GuideDragLogic.lineEndpoints(orientation: .vertical, position: 400.1, imageSize: image,
                                                  zoomPercent: 100, backingFactor: 2))
        XCTAssertNil(GuideDragLogic.lineEndpoints(orientation: .horizontal, position: .nan, imageSize: image,
                                                  zoomPercent: 100, backingFactor: 2))
        // Boundary positions are still drawn.
        XCTAssertNotNil(GuideDragLogic.lineEndpoints(orientation: .horizontal, position: 0, imageSize: image,
                                                     zoomPercent: 100, backingFactor: 2))
        XCTAssertNotNil(GuideDragLogic.lineEndpoints(orientation: .horizontal, position: 300, imageSize: image,
                                                     zoomPercent: 100, backingFactor: 2))
    }
}
