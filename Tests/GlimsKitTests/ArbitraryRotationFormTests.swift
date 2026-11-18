import XCTest
import AppKit
@testable import GlimsKit

@MainActor
final class ArbitraryRotationFormTests: XCTestCase {
    func testAngleParsingAndDirection() {
        XCTAssertEqual(ArbitraryRotationForm.clockwiseDegrees("30", clockwise: true), 30)
        XCTAssertEqual(ArbitraryRotationForm.clockwiseDegrees(" 12,5 ", clockwise: false), -12.5)
        XCTAssertEqual(ArbitraryRotationForm.clockwiseDegrees("-45", clockwise: true), -45)
        XCTAssertEqual(ArbitraryRotationForm.clockwiseDegrees("359.99", clockwise: true), 359.99)
        for text in ["0", "", "abc", "360", "-400", "nan", "inf"] {
            XCTAssertNil(ArbitraryRotationForm.clockwiseDegrees(text, clockwise: true), text)
        }
    }

    func testDirectionRadiosStayExclusive() {
        let form = ArbitraryRotationForm()
        form.angle.stringValue = "15"
        XCTAssertEqual(form.clockwiseDegrees, 15)
        form.counterclockwise.performClick(nil)
        XCTAssertEqual(form.clockwise.state, .off)
        XCTAssertEqual(form.clockwiseDegrees, -15)
        form.clockwise.performClick(nil)
        XCTAssertEqual(form.counterclockwise.state, .off)
        XCTAssertEqual(form.clockwiseDegrees, 15)
    }
}
