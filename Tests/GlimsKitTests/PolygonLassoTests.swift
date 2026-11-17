import AppKit
import XCTest
@testable import GlimsKit

final class PolygonLassoTests: XCTestCase {
    func testShiftKeepsEdgesAtMultiplesOf45Degrees() {
        let anchor = CGPoint(x: 10, y: 10)
        XCTAssertEqual(PolygonLassoGeometry.constrained(CGPoint(x: 50, y: 13), from: anchor), CGPoint(x: 50, y: 10))
        XCTAssertEqual(PolygonLassoGeometry.constrained(CGPoint(x: 11, y: -30), from: anchor), CGPoint(x: 10, y: -30))
        XCTAssertEqual(PolygonLassoGeometry.constrained(CGPoint(x: -20, y: 9), from: anchor), CGPoint(x: -20, y: 10))
        let diagonal = PolygonLassoGeometry.constrained(CGPoint(x: 30, y: 32), from: anchor)
        XCTAssertEqual(diagonal.x - anchor.x, diagonal.y - anchor.y, accuracy: 1e-9)
        XCTAssertEqual(diagonal.x, 31, accuracy: 1e-9)
        let antidiagonal = PolygonLassoGeometry.constrained(CGPoint(x: -10, y: 30), from: anchor)
        XCTAssertEqual(antidiagonal.x - anchor.x, -(antidiagonal.y - anchor.y), accuracy: 1e-9)
        XCTAssertEqual(PolygonLassoGeometry.constrained(anchor, from: anchor), anchor)
    }

    func testClosingNeedsThreeCornersAndAClickNearTheFirst() {
        let corners = [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 10), CGPoint(x: 50, y: 40)]
        XCTAssertTrue(PolygonLassoGeometry.closes(corners, at: CGPoint(x: 13, y: 14), scale: 1))
        XCTAssertFalse(PolygonLassoGeometry.closes(corners, at: CGPoint(x: 13, y: 14), scale: 2))
        XCTAssertTrue(PolygonLassoGeometry.closes(corners, at: CGPoint(x: 20, y: 10), scale: 0.5))
        XCTAssertFalse(PolygonLassoGeometry.closes(Array(corners.prefix(2)), at: CGPoint(x: 10, y: 10), scale: 1))
        XCTAssertFalse(PolygonLassoGeometry.closes(corners, at: CGPoint(x: 10, y: 10), scale: 0))
        XCTAssertFalse(PolygonLassoGeometry.closes(corners, at: CGPoint(x: 10, y: 10), scale: .nan))
    }

    func testPolygonLassoSharesTheLassoGroup() {
        XCTAssertEqual(ToolID.group(forShortcut: "L"), [.lasso, .polygonLasso])
        XCTAssertEqual(ToolID.polygonLasso.name, "Polygon Lasso")
        XCTAssertTrue(ToolID.polygonLasso.isSelectionTool)
        XCTAssertNil(ToolID.polygonLasso.paintTool)
        XCTAssertTrue(ToolID.polygonLasso.isAvailable(in: .lab))
        XCTAssertTrue(ToolID.polygonLasso.isAvailable(in: .rgb))
    }

    func testHintsFollowTheOpenPolygon() {
        XCTAssertEqual(ToolHintPolicy.hint(tool: .polygonLasso, phase: .idle, flags: []),
                       "Select straight-edged area. Shift adds; Option subtracts; Shift-Option intersects.")
        XCTAssertTrue(ToolHintPolicy.hint(tool: .polygonLasso, phase: .polygonOpen(corners: 2), flags: [])
            .hasPrefix("Click to add corners."))
        XCTAssertTrue(ToolHintPolicy.hint(tool: .polygonLasso, phase: .polygonOpen(corners: 3), flags: [.shift])
            .hasPrefix("Double-click, click the first corner or press Return to close."))
    }
}
