import XCTest
@testable import GlimsKit

final class ChannelFormsTests: XCTestCase {
    func testNamesPreserveWholeUTF8Characters() async {
        await MainActor.run {
            XCTAssertEqual(ChannelForms.validName("  Saved area\n"), "Saved area")
            XCTAssertNil(ChannelForms.validName(" \n "))
            XCTAssertNil(ChannelForms.validName("a\0b"))
            XCTAssertEqual(ChannelForms.validName(String(repeating: "é", count: 127))?.utf8.count, 254)
            XCTAssertNil(ChannelForms.validName(String(repeating: "é", count: 128)))
        }
    }

    func testOpacityRequiresACompleteBoundedNumber() async {
        await MainActor.run {
            XCTAssertEqual(ChannelForms.opacityValue("0"), 0)
            XCTAssertEqual(ChannelForms.opacityValue("100"), 1)
            for text in ["", "-1", "101", "NaN", "Infinity", "50 junk", "50%", "1/2"] {
                XCTAssertNil(ChannelForms.opacityValue(text), text)
            }
        }
    }
}
