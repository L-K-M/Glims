import AppKit
import XCTest
@testable import GlimsKit

/// Literal selectors keep the old-product menu baseline compilable.
@MainActor
final class ChannelMenuTests: XCTestCase {
    func testImageChannelsMirrorsTheFourContextCommands() throws {
        _ = NSApplication.shared
        let image = try XCTUnwrap(MainMenu.make().item(withTitle: "Image")?.submenu)
        let channels = try XCTUnwrap(image.item(withTitle: "Channels")?.submenu)
        XCTAssertEqual(channels.items.map(\.title),
                       ["Channel Attributes…", "Duplicate Channel", "Delete Channel", "Return to Layers"])
        let names = ["channelAttributesMenu:", "duplicateChannelMenu:", "deleteChannelMenu:", "returnToLayersMenu:"]
        for (item, name) in zip(channels.items, names) {
            XCTAssertEqual(item.action, Selector(name))
            XCTAssertNil(item.target)
            XCTAssertTrue(item.keyEquivalent.isEmpty)
        }
    }

    func testFromChannelOffersEverySelectionCombination() throws {
        _ = NSApplication.shared
        let select = try XCTUnwrap(MainMenu.make().item(withTitle: "Select")?.submenu)
        let from = try XCTUnwrap(select.item(withTitle: "From Channel")?.submenu)
        XCTAssertEqual(from.items.map(\.title),
                       ["Replace Selection", "Add to Selection", "Subtract from Selection", "Intersect with Selection"])
        XCTAssertEqual(from.items.map(\.tag), [0, 1, 2, 3])
        for item in from.items {
            XCTAssertEqual(item.action, Selector(("channelToSelectionMenu:")))
            XCTAssertNil(item.target)
        }
        XCTAssertEqual(select.item(withTitle: "Save Selection as Channel…")?.action,
                       #selector(DocumentWindowController.saveSelectionAsChannel(_:)))
        XCTAssertEqual(select.item(withTitle: "Quick Mask")?.action,
                       #selector(DocumentWindowController.toggleQuickMask(_:)))
    }
}
