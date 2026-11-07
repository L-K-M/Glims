import AppKit
import XCTest
@testable import GlimsKit

final class CanvasClipViewTests: XCTestCase {
    func testSmallImageIsCenteredInBothDirections() {
        let bounds = CanvasClipView.centeredBounds(CGRect(x: 0, y: 0, width: 900, height: 600),
                                                   documentFrame: CGRect(x: 0, y: 0, width: 320, height: 240))
        XCTAssertEqual(bounds.origin, CGPoint(x: -290, y: -180))
    }

    func testLargeAxisKeepsItsScrollPosition() {
        let bounds = CanvasClipView.centeredBounds(CGRect(x: 10, y: 200, width: 900, height: 600),
                                                   documentFrame: CGRect(x: 0, y: 0, width: 320, height: 1200))
        XCTAssertEqual(bounds.origin, CGPoint(x: -290, y: 200))
    }
}
