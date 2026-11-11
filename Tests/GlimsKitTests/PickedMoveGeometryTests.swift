import XCTest
@testable import GlimsKit

final class PickedMoveGeometryTests: XCTestCase {
    private let small = CGRect(x: 24, y: 24, width: 12, height: 12)

    private func row(_ id: Int32, parent: Int32 = 0, kind: EngineSession.LayerKind = .pixel,
                     bounds: CGRect) -> EngineSession.Layer {
        .init(id: id, parent: parent, depth: 0, kind: kind, name: "Literal \(id)", mode: "normal",
              isVisible: true, hasMask: false, isSelected: false, opacity: 1, bounds: bounds, filterCount: 0)
    }

    func testCoreRoundingUsesFloorWithNegativeTiesUp() {
        XCTAssertEqual(PickedMoveGeometry.roundedDelta(0.49), 0)
        XCTAssertEqual(PickedMoveGeometry.roundedDelta(0.5), 1)
        XCTAssertEqual(PickedMoveGeometry.roundedDelta(-0.5), 0)
        XCTAssertEqual(PickedMoveGeometry.roundedDelta(-0.51), -1)
        XCTAssertEqual(PickedMoveGeometry.roundedDelta(-1.5), -1)
        XCTAssertEqual(PickedMoveGeometry.roundedDelta(-1.51), -2)
    }

    func testRoundedDeltaInt32EdgesAndNonfiniteInputs() {
        XCTAssertEqual(PickedMoveGeometry.roundedDelta(2_147_483_647), Int32.max)
        XCTAssertEqual(PickedMoveGeometry.roundedDelta(2_147_483_647.49), Int32.max)
        XCTAssertEqual(PickedMoveGeometry.roundedDelta(-2_147_483_648), Int32.min)
        XCTAssertEqual(PickedMoveGeometry.roundedDelta(-2_147_483_648.5), Int32.min)
        XCTAssertNil(PickedMoveGeometry.roundedDelta(2_147_483_647.5))
        XCTAssertNil(PickedMoveGeometry.roundedDelta(-2_147_483_648.75))
        XCTAssertNil(PickedMoveGeometry.roundedDelta(.nan))
        XCTAssertNil(PickedMoveGeometry.roundedDelta(.infinity))
        XCTAssertNil(PickedMoveGeometry.roundedDelta(-.infinity))
        XCTAssertNil(PickedMoveGeometry.roundedDelta(.greatestFiniteMagnitude))
    }

    func testLargeOffsetsAreIndependentOfImageDimensions() {
        XCTAssertTrue(PickedMoveGeometry.canTranslate(bounds: small, by: CGSize(width: 600_000, height: 0)))
        XCTAssertTrue(PickedMoveGeometry.canTranslate(bounds: small, by: CGSize(width: -600_000, height: 600_000)))
        XCTAssertTrue(PickedMoveGeometry.canTranslate(bounds: CGRect(x: 600_024, y: -600_024, width: 12, height: 12),
                                                      by: CGSize(width: 7, height: -4)))
    }

    func testNativeRectanglesMustBeFiniteIntegralAndPositive() {
        let invalid = [CGRect(x: 0.5, y: 0, width: 12, height: 12),
                       CGRect(x: 0, y: 0, width: 12.5, height: 12),
                       CGRect(x: 0, y: 0, width: 0, height: 12),
                       CGRect(x: 0, y: 0, width: -12, height: 12),
                       CGRect(x: 0, y: 0, width: 12, height: -12),
                       CGRect(x: Double.nan, y: 0, width: 12, height: 12),
                       CGRect(x: 0, y: 0, width: Double.infinity, height: 12),
                       CGRect(x: 2_147_483_648, y: 0, width: 1, height: 1)]
        for rect in invalid {
            XCTAssertFalse(PickedMoveGeometry.canTranslate(bounds: rect, by: CGSize(width: 1, height: 1)), "\(rect)")
        }
    }

    func testTranslationMustFitAfterCoreRounding() {
        XCTAssertFalse(PickedMoveGeometry.canTranslate(bounds: small, by: CGSize(width: 2_147_483_647.5, height: 0)))
        XCTAssertFalse(PickedMoveGeometry.canTranslate(bounds: small, by: CGSize(width: 0, height: -2_147_483_648.75)))
        XCTAssertTrue(PickedMoveGeometry.canTranslate(bounds: small, by: CGSize(width: -0.5, height: -1.5)))
    }

    func testSafeDeltaCanOverflowTheTranslatedOrigin() {
        XCTAssertFalse(PickedMoveGeometry.canTranslate(bounds: CGRect(x: 2_147_483_630, y: 0, width: 12, height: 12),
                                                       by: CGSize(width: 18, height: 0)))
        XCTAssertFalse(PickedMoveGeometry.canTranslate(bounds: CGRect(x: -2_147_483_640, y: 0, width: 12, height: 12),
                                                       by: CGSize(width: -9, height: 0)))
    }

    func testSafeOriginCanOverflowRightOrBottomEndpoint() {
        XCTAssertFalse(PickedMoveGeometry.canTranslate(bounds: small, by: CGSize(width: 2_147_483_617, height: 0)))
        XCTAssertFalse(PickedMoveGeometry.canTranslate(bounds: small, by: CGSize(width: 0, height: 2_147_483_617)))
        XCTAssertFalse(PickedMoveGeometry.canTranslate(bounds: CGRect(x: 2_147_483_640, y: 0, width: 12, height: 12),
                                                       by: CGSize(width: -20, height: 0)), "unsafe old region is rejected too")
    }

    func testIntegralBoundaryRegionsAndLargeDeltaRemainAllowed() {
        XCTAssertTrue(PickedMoveGeometry.canTranslate(bounds: CGRect(x: 2_147_483_634, y: 0, width: 12, height: 12),
                                                      by: CGSize(width: 1, height: 0)))
        XCTAssertTrue(PickedMoveGeometry.canTranslate(bounds: CGRect(x: -2_147_483_647, y: 0, width: 12, height: 12),
                                                      by: CGSize(width: -1, height: 0)))
        XCTAssertTrue(PickedMoveGeometry.canTranslate(bounds: CGRect(x: -2_147_483_648, y: 0, width: 1, height: 1),
                                                      by: CGSize(width: 2_147_483_647, height: 0)))
    }

    func testNestedGroupChecksEveryTranslatedDescendant() {
        let group = row(1, kind: .group, bounds: CGRect(x: 0, y: 0, width: 40, height: 40))
        let nested = row(2, parent: 1, kind: .group, bounds: CGRect(x: 4, y: 4, width: 34, height: 34))
        let child = row(3, parent: 2, bounds: small)
        XCTAssertTrue(PickedMoveGeometry.canTranslate(group, in: [group, nested, child],
                                                      by: CGSize(width: 600_000, height: -600_000)))
    }

    func testNestedDescendantArithmeticIsCheckedEvenWhenGroupEnvelopeFits() {
        let group = row(1, kind: .group, bounds: CGRect(x: 0, y: 0, width: 40, height: 40))
        let nested = row(2, parent: 1, kind: .group, bounds: CGRect(x: 4, y: 4, width: 30, height: 30))
        let child = row(3, parent: 2, bounds: CGRect(x: 2_147_483_630, y: 0, width: 12, height: 12))
        XCTAssertTrue(PickedMoveGeometry.canTranslate(bounds: group.bounds, by: CGSize(width: 18, height: 0)))
        XCTAssertFalse(PickedMoveGeometry.canTranslate(group, in: [group, nested, child],
                                                       by: CGSize(width: 18, height: 0)))
    }

    func testUnrelatedLayerDoesNotConstrainTheCapturedMove() {
        let group = row(1, kind: .group, bounds: small)
        let child = row(2, parent: 1, bounds: small)
        let unrelated = row(3, bounds: CGRect(x: 2_147_483_630, y: 0, width: 12, height: 12))
        XCTAssertTrue(PickedMoveGeometry.canTranslate(group, in: [unrelated, child, group],
                                                      by: CGSize(width: 600_000, height: 0)))
    }

    func testMissingChangedOrAmbiguousCapturedRowIsRefused() {
        let captured = row(1, bounds: small)
        let changed = row(1, bounds: small.offsetBy(dx: 1, dy: 0))
        XCTAssertFalse(PickedMoveGeometry.canTranslate(captured, in: [], by: CGSize(width: 1, height: 0)))
        XCTAssertFalse(PickedMoveGeometry.canTranslate(captured, in: [changed], by: CGSize(width: 1, height: 0)))
        XCTAssertFalse(PickedMoveGeometry.canTranslate(captured, in: [captured, captured], by: CGSize(width: 1, height: 0)))
    }

    func testCyclicGroupMetadataRefusesWithoutUnboundedTraversal() {
        let group = row(1, parent: 2, kind: .group, bounds: small)
        let nested = row(2, parent: 1, kind: .group, bounds: small)
        XCTAssertFalse(PickedMoveGeometry.canTranslate(group, in: [group, nested], by: CGSize(width: 1, height: 0)))
    }
}
