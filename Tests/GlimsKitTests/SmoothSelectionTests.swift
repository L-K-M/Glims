import AppKit
import XCTest
@testable import GlimsKit

final class SmoothSelectionTests: XCTestCase {
    func testRadiusAcceptsWholePixelsOneToOneHundred() {
        XCTAssertEqual(EngineSession.selectionSmoothMaxRadius, 100)
        XCTAssertEqual(DocumentWindowController.smoothRadius("1"), 1)
        XCTAssertEqual(DocumentWindowController.smoothRadius(" 100 "), 100)
        XCTAssertNil(DocumentWindowController.smoothRadius("0"))
        XCTAssertNil(DocumentWindowController.smoothRadius("101"))
        XCTAssertNil(DocumentWindowController.smoothRadius("-2"))
        XCTAssertNil(DocumentWindowController.smoothRadius("2.5"))
        XCTAssertNil(DocumentWindowController.smoothRadius(""))
    }

    @MainActor
    func testSmoothFollowsBorderInTheSelectMenu() throws {
        _ = NSApplication.shared
        let select = try XCTUnwrap(MainMenu.make().item(withTitle: "Select")?.submenu)
        let titles = select.items.map(\.title)
        let border = try XCTUnwrap(titles.firstIndex(of: "Border…"))
        XCTAssertEqual(titles[border + 1], "Smooth…")
        let item = try XCTUnwrap(select.item(withTitle: "Smooth…"))
        XCTAssertEqual(item.action, #selector(DocumentWindowController.smoothSelection(_:)))
        XCTAssertEqual(item.keyEquivalent, "")
    }
}
