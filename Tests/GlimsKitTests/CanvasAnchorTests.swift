import AppKit
import XCTest
@testable import GlimsKit

final class CanvasAnchorTests: XCTestCase {
    func testEveryAnchorPlacesTheImageWhenGrowing() {
        let old = (width: 100, height: 60), new = (width: 140, height: 90)
        let expected: [CanvasAnchor: CGPoint] = [
            .topLeft: CGPoint(x: 0, y: 0), .top: CGPoint(x: 20, y: 0), .topRight: CGPoint(x: 40, y: 0),
            .left: CGPoint(x: 0, y: 15), .center: CGPoint(x: 20, y: 15), .right: CGPoint(x: 40, y: 15),
            .bottomLeft: CGPoint(x: 0, y: 30), .bottom: CGPoint(x: 20, y: 30), .bottomRight: CGPoint(x: 40, y: 30),
        ]
        for anchor in CanvasAnchor.allCases {
            XCTAssertEqual(anchor.offset(from: old, to: new), expected[anchor], anchor.title)
        }
    }

    func testShrinkingCropsAwayFromTheAnchor() {
        let old = (width: 100, height: 60), new = (width: 70, height: 40)
        XCTAssertEqual(CanvasAnchor.topLeft.offset(from: old, to: new), CGPoint(x: 0, y: 0))
        XCTAssertEqual(CanvasAnchor.bottomRight.offset(from: old, to: new), CGPoint(x: -30, y: -20))
        XCTAssertEqual(CanvasAnchor.top.offset(from: old, to: new), CGPoint(x: -15, y: 0))
        XCTAssertEqual(CanvasAnchor.left.offset(from: old, to: new), CGPoint(x: 0, y: -10))
    }

    func testCenterKeepsTheEarlierIntegerArithmetic() {
        for (old, new) in [((100, 60), (141, 91)), ((100, 60), (99, 59)), ((7, 5), (2, 2)), ((3, 3), (3, 3))] {
            XCTAssertEqual(CanvasAnchor.center.offset(from: old, to: new),
                           CGPoint(x: (new.0 - old.0) / 2, y: (new.1 - old.1) / 2))
        }
    }

    @MainActor
    func testPickerDefaultsToCenterAndFollowsClicks() throws {
        let picker = CanvasAnchorPicker()
        XCTAssertEqual(picker.anchor, .center)
        let buttons = picker.buttons
        XCTAssertEqual(buttons.count, 9)
        XCTAssertEqual(Set(buttons.map { $0.accessibilityLabel() ?? "" }),
                       Set(CanvasAnchor.allCases.map { "Anchor \($0.title)" }))
        let topRight = try XCTUnwrap(buttons.first { $0.tag == CanvasAnchor.topRight.rawValue })
        topRight.performClick(nil)
        XCTAssertEqual(picker.anchor, .topRight)
        XCTAssertEqual(buttons.filter { $0.state == .on }.map(\.tag), [CanvasAnchor.topRight.rawValue])
        picker.select(.bottomLeft)
        XCTAssertEqual(buttons.filter { $0.state == .on }.map(\.tag), [CanvasAnchor.bottomLeft.rawValue])
    }
}
