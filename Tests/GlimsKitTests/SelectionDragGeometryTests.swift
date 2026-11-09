import CoreGraphics
import XCTest
@testable import GlimsKit

final class SelectionDragGeometryTests: XCTestCase {
    // MARK: - Anchor drag, no modifiers, all four quadrants

    func testAnchorDownRightQuadrant() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 10, y: 20), end: CGPoint(x: 30, y: 50),
            constrained: false, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 20, height: 30))
    }

    func testAnchorUpLeftQuadrant() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 30, y: 50), end: CGPoint(x: 10, y: 20),
            constrained: false, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 20, height: 30))
    }

    func testAnchorDownLeftQuadrant() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 30, y: 20), end: CGPoint(x: 10, y: 50),
            constrained: false, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 20, height: 30))
    }

    func testAnchorUpRightQuadrant() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 10, y: 50), end: CGPoint(x: 30, y: 20),
            constrained: false, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 10, y: 20, width: 20, height: 30))
    }

    // MARK: - Constrained (Shift), all four quadrants

    func testConstrainedDownRightTakesLargerExtent() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 5, y: 5), end: CGPoint(x: 25, y: 15),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 5, y: 5, width: 20, height: 20))
    }

    func testConstrainedUpLeftPreservesBothNegativeDirections() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 30, y: 30), end: CGPoint(x: 10, y: 5),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 5, y: 5, width: 25, height: 25))
    }

    func testConstrainedDownLeftKeepsMixedDirections() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 30, y: 5), end: CGPoint(x: 10, y: 25),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 10, y: 5, width: 20, height: 20))
    }

    func testConstrainedUpRightKeepsMixedDirections() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 5, y: 30), end: CGPoint(x: 25, y: 10),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 5, y: 10, width: 20, height: 20))
    }

    // MARK: - Constrained zero-axis sign

    func testConstrainedZeroXWithPositiveYStaysPositive() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 5, y: 5), end: CGPoint(x: 5, y: 25),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 5, y: 5, width: 20, height: 20))
    }

    func testConstrainedZeroXWithNegativeYStaysPositive() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 5, y: 25), end: CGPoint(x: 5, y: 5),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 5, y: 5, width: 20, height: 20))
    }

    func testConstrainedZeroYWithPositiveXStaysPositive() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 5, y: 5), end: CGPoint(x: 25, y: 5),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 5, y: 5, width: 20, height: 20))
    }

    func testConstrainedZeroYWithNegativeXStaysPositive() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 25, y: 5), end: CGPoint(x: 5, y: 5),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 5, y: 5, width: 20, height: 20))
    }

    func testConstrainedNegativeZeroXTakesPositiveDirection() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: -0.0, y: 20),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    func testConstrainedNegativeZeroYTakesPositiveDirection() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 20, y: -0.0),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 20, height: 20))
    }

    // MARK: - From center (Option)

    func testFromCenterDoublesExtents() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 10, y: 10), end: CGPoint(x: 20, y: 30),
            constrained: false, fromCenter: true)
        XCTAssertEqual(rect, CGRect(x: 0, y: -10, width: 20, height: 40))
    }

    func testFromCenterIgnoresDragDirection() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 10, y: 10), end: CGPoint(x: 0, y: -10),
            constrained: false, fromCenter: true)
        XCTAssertEqual(rect, CGRect(x: 0, y: -10, width: 20, height: 40))
    }

    func testFromCenterAndConstrainedUsesLargerExtent() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 10, y: 20), end: CGPoint(x: 40, y: 25),
            constrained: true, fromCenter: true)
        XCTAssertEqual(rect, CGRect(x: -20, y: -10, width: 60, height: 60))
    }

    func testFromCenterAndConstrainedWithNegativeDirection() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 10, y: 20), end: CGPoint(x: -20, y: 25),
            constrained: true, fromCenter: true)
        XCTAssertEqual(rect, CGRect(x: -20, y: -10, width: 60, height: 60))
    }

    func testCenteredModifiersInEveryQuadrant() {
        let endpoints = [CGPoint(x: 13, y: 25), CGPoint(x: 7, y: 25),
                         CGPoint(x: 7, y: 15), CGPoint(x: 13, y: 15)]
        for end in endpoints {
            XCTAssertEqual(SelectionDragGeometry.rect(
                start: CGPoint(x: 10, y: 20), end: end,
                constrained: false, fromCenter: true),
                CGRect(x: 7, y: 15, width: 6, height: 10))
            XCTAssertEqual(SelectionDragGeometry.rect(
                start: CGPoint(x: 10, y: 20), end: end,
                constrained: true, fromCenter: true),
                CGRect(x: 5, y: 15, width: 10, height: 10))
        }
    }

    func testZeroAxisWithEveryModifierCombination() {
        let cases: [(CGPoint, CGRect, CGRect, CGRect)] = [
            (CGPoint(x: 10, y: 25), CGRect(x: 10, y: 20, width: 0, height: 5),
             CGRect(x: 10, y: 20, width: 5, height: 5), CGRect(x: 10, y: 15, width: 0, height: 10)),
            (CGPoint(x: 10, y: 15), CGRect(x: 10, y: 15, width: 0, height: 5),
             CGRect(x: 10, y: 15, width: 5, height: 5), CGRect(x: 10, y: 15, width: 0, height: 10)),
            (CGPoint(x: 15, y: 20), CGRect(x: 10, y: 20, width: 5, height: 0),
             CGRect(x: 10, y: 20, width: 5, height: 5), CGRect(x: 5, y: 20, width: 10, height: 0)),
            (CGPoint(x: 5, y: 20), CGRect(x: 5, y: 20, width: 5, height: 0),
             CGRect(x: 5, y: 20, width: 5, height: 5), CGRect(x: 5, y: 20, width: 10, height: 0))
        ]
        for (end, plain, square, centered) in cases {
            let start = CGPoint(x: 10, y: 20)
            XCTAssertEqual(SelectionDragGeometry.rect(start: start, end: end,
                constrained: false, fromCenter: false), plain)
            XCTAssertEqual(SelectionDragGeometry.rect(start: start, end: end,
                constrained: true, fromCenter: false), square)
            XCTAssertEqual(SelectionDragGeometry.rect(start: start, end: end,
                constrained: false, fromCenter: true), centered)
            XCTAssertEqual(SelectionDragGeometry.rect(start: start, end: end,
                constrained: true, fromCenter: true), CGRect(x: 5, y: 15, width: 10, height: 10))
        }
    }

    // MARK: - Fractional coordinates are not rounded

    func testFractionalAnchorDrag() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 0.25, y: 0.5), end: CGPoint(x: 1.75, y: 3.25),
            constrained: false, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 0.25, y: 0.5, width: 1.5, height: 2.75))
    }

    func testFractionalReverseDrag() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 1.75, y: 3.25), end: CGPoint(x: 0.25, y: 0.5),
            constrained: false, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 0.25, y: 0.5, width: 1.5, height: 2.75))
    }

    func testFractionalConstrainedDrag() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1.25, y: 0.5),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 0, y: 0, width: 1.25, height: 1.25))
    }

    func testFractionalFromCenterDrag() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 0.5, y: 0.5), end: CGPoint(x: 1.25, y: 0.75),
            constrained: false, fromCenter: true)
        XCTAssertEqual(rect, CGRect(x: -0.25, y: 0.25, width: 1.5, height: 0.5))
    }

    // MARK: - Zero displacement

    func testZeroDisplacement() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 7.5, y: -3.25), end: CGPoint(x: 7.5, y: -3.25),
            constrained: false, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 7.5, y: -3.25, width: 0, height: 0))
    }

    func testZeroDisplacementConstrained() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 7.5, y: -3.25), end: CGPoint(x: 7.5, y: -3.25),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: 7.5, y: -3.25, width: 0, height: 0))
    }

    func testZeroDisplacementFromCenter() {
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 7.5, y: -3.25), end: CGPoint(x: 7.5, y: -3.25),
            constrained: true, fromCenter: true)
        XCTAssertEqual(rect, CGRect(x: 7.5, y: -3.25, width: 0, height: 0))
    }

    // MARK: - Non-finite inputs

    func testRejectsNaNInEachInputComponent() {
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: CGFloat.nan, y: 0), end: CGPoint(x: 1, y: 1),
            constrained: false, fromCenter: false))
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: CGFloat.nan), end: CGPoint(x: 1, y: 1),
            constrained: false, fromCenter: true))
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: CGFloat.nan, y: 1),
            constrained: true, fromCenter: false))
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: CGFloat.nan),
            constrained: true, fromCenter: true))
    }

    func testRejectsPositiveInfinityInEachInputComponent() {
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: CGFloat.infinity, y: 0), end: CGPoint(x: 1, y: 1),
            constrained: false, fromCenter: false))
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: CGFloat.infinity), end: CGPoint(x: 1, y: 1),
            constrained: false, fromCenter: true))
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: CGFloat.infinity, y: 1),
            constrained: true, fromCenter: false))
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: CGFloat.infinity),
            constrained: true, fromCenter: true))
    }

    func testRejectsNegativeInfinityInEachInputComponent() {
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: -CGFloat.infinity, y: 0), end: CGPoint(x: 1, y: 1),
            constrained: true, fromCenter: false))
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: -CGFloat.infinity), end: CGPoint(x: 1, y: 1),
            constrained: false, fromCenter: false))
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: -CGFloat.infinity, y: 1),
            constrained: false, fromCenter: true))
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: 1, y: -CGFloat.infinity),
            constrained: true, fromCenter: true))
    }

    // MARK: - Overflowing bounds

    func testRejectsSubtractionOverflow() {
        let g = CGFloat.greatestFiniteMagnitude
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: -g, y: 0), end: CGPoint(x: g, y: 0),
            constrained: false, fromCenter: false))
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: -g), end: CGPoint(x: 0, y: g),
            constrained: true, fromCenter: true))
    }

    func testRejectsConstrainedFarEdgeOverflow() {
        let g = CGFloat.greatestFiniteMagnitude
        let t = g / 2 + g / 4
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: t, y: 0), end: CGPoint(x: t, y: g / 2),
            constrained: true, fromCenter: false))
        // Unconstrained, the same drag stays within finite bounds.
        XCTAssertEqual(SelectionDragGeometry.rect(
            start: CGPoint(x: t, y: 0), end: CGPoint(x: t, y: g / 2),
            constrained: false, fromCenter: false),
            CGRect(x: t, y: 0, width: 0, height: g / 2))
    }

    func testRejectsCenteredDoublingOverflow() {
        let g = CGFloat.greatestFiniteMagnitude
        let t = g / 2 + g / 4
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: t, y: 0),
            constrained: false, fromCenter: true))
        // The same drag as an anchor drag stays within finite bounds.
        XCTAssertEqual(SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: t, y: 0),
            constrained: false, fromCenter: false),
            CGRect(x: 0, y: 0, width: t, height: 0))
    }

    func testRejectsCenteredOriginOverflow() {
        // Exact binary values isolate origin overflow without a rounded
        // greatestFiniteMagnitude fraction changing the finite oracle.
        let unit: CGFloat = 0x1p1022
        let anchor = -3 * unit
        let endpoint = -1.5 * unit
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: anchor, y: 0), end: CGPoint(x: endpoint, y: 0),
            constrained: false, fromCenter: true))
        XCTAssertEqual(SelectionDragGeometry.rect(
            start: CGPoint(x: anchor, y: 0), end: CGPoint(x: endpoint, y: 0),
            constrained: false, fromCenter: false),
            CGRect(x: anchor, y: 0, width: 1.5 * unit, height: 0))
    }

    func testRejectsCenteredFarEdgeOverflow() {
        let unit: CGFloat = 0x1p1022
        let anchor = 3 * unit
        let endpoint = 1.5 * unit
        XCTAssertNil(SelectionDragGeometry.rect(
            start: CGPoint(x: anchor, y: 0), end: CGPoint(x: endpoint, y: 0),
            constrained: false, fromCenter: true))
        XCTAssertEqual(SelectionDragGeometry.rect(
            start: CGPoint(x: anchor, y: 0), end: CGPoint(x: endpoint, y: 0),
            constrained: false, fromCenter: false),
            CGRect(x: endpoint, y: 0, width: 1.5 * unit, height: 0))
    }

    // MARK: - Extreme but valid bounds are accepted

    func testExtremeAnchorDragIsValid() {
        let g = CGFloat.greatestFiniteMagnitude
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: -g / 2, y: -g / 2), end: CGPoint(x: g / 2, y: g / 2),
            constrained: false, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: -g / 2, y: -g / 2, width: g, height: g))
    }

    func testExtremeConstrainedDragIsValid() {
        let g = CGFloat.greatestFiniteMagnitude
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: -g / 2, y: -g / 2), end: CGPoint(x: g / 2, y: g / 2),
            constrained: true, fromCenter: false)
        XCTAssertEqual(rect, CGRect(x: -g / 2, y: -g / 2, width: g, height: g))
    }

    func testExtremeFromCenterDragIsValid() {
        let g = CGFloat.greatestFiniteMagnitude
        let rect = SelectionDragGeometry.rect(
            start: CGPoint(x: 0, y: 0), end: CGPoint(x: g / 2, y: g / 2),
            constrained: false, fromCenter: true)
        XCTAssertEqual(rect, CGRect(x: -g / 2, y: -g / 2, width: g, height: g))
    }
}
