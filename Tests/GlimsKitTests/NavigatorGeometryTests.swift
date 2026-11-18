import XCTest
@testable import GlimsKit

final class NavigatorGeometryTests: XCTestCase {
    func testThumbnailFitsAndCentersTheImage() {
        let wide = NavigatorGeometry.thumbnailRect(imageSize: CGSize(width: 400, height: 200),
                                                   in: CGRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(wide, CGRect(x: 0, y: 50, width: 200, height: 100))
        let tall = NavigatorGeometry.thumbnailRect(imageSize: CGSize(width: 10, height: 20),
                                                   in: CGRect(x: 10, y: 0, width: 100, height: 100))
        XCTAssertEqual(tall, CGRect(x: 35, y: 0, width: 50, height: 100))
        XCTAssertEqual(NavigatorGeometry.thumbnailRect(imageSize: .zero, in: CGRect(x: 0, y: 0, width: 10, height: 10)),
                       .zero)
    }

    func testPointsMapBothWaysAndClampToTheImage() {
        let thumbnail = CGRect(x: 0, y: 50, width: 200, height: 100)
        let size = CGSize(width: 400, height: 200)
        XCTAssertEqual(NavigatorGeometry.imagePoint(CGPoint(x: 100, y: 100), thumbnail: thumbnail, imageSize: size),
                       CGPoint(x: 200, y: 100))
        XCTAssertEqual(NavigatorGeometry.imagePoint(CGPoint(x: -20, y: 400), thumbnail: thumbnail, imageSize: size),
                       CGPoint(x: 0, y: 200))
        XCTAssertNil(NavigatorGeometry.imagePoint(CGPoint(x: 1, y: 1), thumbnail: .zero, imageSize: size))
        XCTAssertEqual(NavigatorGeometry.viewPoint(CGPoint(x: 200, y: 100), thumbnail: thumbnail, imageSize: size),
                       CGPoint(x: 100, y: 100))
    }

    func testRenderScaleNeverEnlarges() {
        XCTAssertEqual(NavigatorGeometry.renderScale(imageSize: CGSize(width: 100, height: 50)), 1)
        XCTAssertEqual(NavigatorGeometry.renderScale(imageSize: CGSize(width: 960, height: 4800)), 0.1, accuracy: 1e-9)
        XCTAssertEqual(NavigatorGeometry.renderScale(imageSize: .zero), 0)
    }

    func testSliderCoversTheZoomLadderLogarithmically() {
        XCTAssertEqual(NavigatorGeometry.sliderValue(zoomPercent: 5), 0, accuracy: 1e-9)
        XCTAssertEqual(NavigatorGeometry.sliderValue(zoomPercent: 3200), 1, accuracy: 1e-9)
        XCTAssertEqual(NavigatorGeometry.sliderValue(zoomPercent: 1), 0, accuracy: 1e-9)
        for step in ZoomLadder.steps {
            XCTAssertEqual(NavigatorGeometry.zoomPercent(sliderValue: NavigatorGeometry.sliderValue(zoomPercent: step)),
                           step)
        }
        XCTAssertEqual(NavigatorGeometry.zoomPercent(sliderValue: .nan), 5)
        XCTAssertEqual(NavigatorGeometry.zoomPercent(sliderValue: 2), 3200)
    }

    func testTypedZoomAcceptsAPercentSignAndClamps() {
        XCTAssertEqual(NavigatorGeometry.typedZoom(" 200% "), 200)
        XCTAssertEqual(NavigatorGeometry.typedZoom("150"), 150)
        XCTAssertEqual(NavigatorGeometry.typedZoom("99999"), 3200)
        XCTAssertEqual(NavigatorGeometry.typedZoom("2"), 5)
        XCTAssertNil(NavigatorGeometry.typedZoom("0"))
        XCTAssertNil(NavigatorGeometry.typedZoom("abc"))
        XCTAssertNil(NavigatorGeometry.typedZoom(""))
    }
}
