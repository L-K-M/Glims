import XCTest
@testable import GlimsKit

final class ZoomLadderTests: XCTestCase {
    func testFitUsesDevicePixelsOnRetinaDisplays() {
        XCTAssertEqual(ZoomLadder.fit(imageWidth: 2000, imageHeight: 1000,
                                     viewportWidth: 800, viewportHeight: 600, backingFactor: 2), 80)
        XCTAssertEqual(ZoomLadder.fit(imageWidth: 2000, imageHeight: 1000,
                                     viewportWidth: 800, viewportHeight: 600, backingFactor: 1), 40)
        XCTAssertEqual(ZoomLadder.fit(imageWidth: 300, imageHeight: 200,
                                     viewportWidth: 800, viewportHeight: 600, backingFactor: 2), 100)
    }
    func testStepsAreAscendingAndContainActualPixels() {
        XCTAssertEqual(ZoomLadder.steps, ZoomLadder.steps.sorted())
        XCTAssertEqual(Set(ZoomLadder.steps).count, ZoomLadder.steps.count)
        XCTAssertTrue(ZoomLadder.steps.contains(ZoomLadder.actualPixels))
    }

    func testStepsFromALadderValue() {
        XCTAssertEqual(ZoomLadder.zoomIn(from: 100), 150)
        XCTAssertEqual(ZoomLadder.zoomOut(from: 100), 67)
    }

    func testATypedZoomStaysWithinTheLadder() {
        XCTAssertEqual(ZoomLadder.clamped(1), 5)
        XCTAssertEqual(ZoomLadder.clamped(250), 250)
        XCTAssertEqual(ZoomLadder.clamped(100_000), 3200)
    }

    func testStepsFromBetweenTwoValues() {
        XCTAssertEqual(ZoomLadder.zoomIn(from: 61), 67)
        XCTAssertEqual(ZoomLadder.zoomOut(from: 61), 50)
    }

    func testFitUsesBothAxesAndDoesNotEnlargeSmallImages() {
        XCTAssertEqual(ZoomLadder.fit(imageWidth: 1600, imageHeight: 1200,
                                     viewportWidth: 900, viewportHeight: 600), 50)
        XCTAssertEqual(ZoomLadder.fit(imageWidth: 100, imageHeight: 100,
                                     viewportWidth: 900, viewportHeight: 600), 100)
        XCTAssertEqual(ZoomLadder.fit(imageWidth: 0, imageHeight: 1,
                                     viewportWidth: 900, viewportHeight: 600), 100)
        XCTAssertEqual(ZoomLadder.fit(imageWidth: .infinity, imageHeight: 1,
                                     viewportWidth: 900, viewportHeight: 600), 100)
    }

    func testClampsAtTheEnds() {
        XCTAssertEqual(ZoomLadder.zoomIn(from: 3200), 3200)
        XCTAssertEqual(ZoomLadder.zoomOut(from: 5), 5)
    }
}
