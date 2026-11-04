import XCTest
@testable import GlimsKit

final class ZoomLadderTests: XCTestCase {
    func testStepsAreAscendingAndContainActualPixels() {
        XCTAssertEqual(ZoomLadder.steps, ZoomLadder.steps.sorted())
        XCTAssertEqual(Set(ZoomLadder.steps).count, ZoomLadder.steps.count)
        XCTAssertTrue(ZoomLadder.steps.contains(ZoomLadder.actualPixels))
    }

    func testStepsFromALadderValue() {
        XCTAssertEqual(ZoomLadder.zoomIn(from: 100), 150)
        XCTAssertEqual(ZoomLadder.zoomOut(from: 100), 67)
    }

    func testStepsFromBetweenTwoValues() {
        XCTAssertEqual(ZoomLadder.zoomIn(from: 61), 67)
        XCTAssertEqual(ZoomLadder.zoomOut(from: 61), 50)
    }

    func testClampsAtTheEnds() {
        XCTAssertEqual(ZoomLadder.zoomIn(from: 3200), 3200)
        XCTAssertEqual(ZoomLadder.zoomOut(from: 5), 5)
    }
}
