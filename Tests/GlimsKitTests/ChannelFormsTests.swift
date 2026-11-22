import AppKit
import XCTest
@testable import GlimsKit

final class ChannelFormsTests: XCTestCase {
    @MainActor
    func testApplySendsOnlyTheEditedAttributes() {
        let shown = ChannelForms.AttributeFields(name: "Mask", opacity: "50.196", color: .red)
        func change(_ edit: (inout ChannelForms.AttributeFields) -> Void) -> EngineSession.ChannelChange? {
            var entered = shown
            edit(&entered)
            return ChannelForms.attributesChange(from: shown, to: entered, storedOpacity: 128.0 / 255)
        }
        XCTAssertNil(change { _ in })
        XCTAssertNil(change { $0.name = " Mask " })
        XCTAssertNil(change { $0.opacity = "50.1960" })
        let padded = ChannelForms.AttributeFields(name: " Mask", opacity: "50", color: .red)
        var trimmed = padded
        trimmed.name = "Mask"
        XCTAssertEqual(ChannelForms.attributesChange(from: padded, to: trimmed, storedOpacity: 0.5),
                       .init(name: "Mask"), "removing a stored space is a real rename")
        XCTAssertEqual(change { $0.name = " Edges " }, .init(name: "Edges"))
        XCTAssertEqual(change { $0.opacity = "25" }, .init(opacity: 0.25))
        XCTAssertEqual(change { $0.color = .blue },
                       .init(color: NSColor.blue.withAlphaComponent(128.0 / 255)))
    }

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
