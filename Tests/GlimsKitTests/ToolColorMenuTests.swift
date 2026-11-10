import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class ToolColorMenuTests: XCTestCase {
    private func toolsSubmenu(in menu: NSMenu) -> NSMenu? {
        menu.items.first { $0.title == "View" }?.submenu?.items.first { $0.title == "Tools" }?.submenu
    }

    func testViewMenuHasToolsSubmenuWithPaletteGroupsAndColorCommands() throws {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        let tools = try XCTUnwrap(toolsSubmenu(in: menu))
        let topItems = tools.items
        XCTAssertEqual(topItems.count, 19)

        let directCrops = try XCTUnwrap(topItems.first { $0.title == "Crop" })
        XCTAssertEqual(directCrops.action, Selector(("selectToolFromMenu:")))
        XCTAssertNil(directCrops.submenu)
        XCTAssertTrue(directCrops.tag != 0)

        let moveGroup = try XCTUnwrap(topItems.first { $0.title == "Move" }?.submenu)
        XCTAssertEqual(moveGroup.items.map(\.title), ["Move", "Transform"])
        for item in moveGroup.items {
            XCTAssertEqual(item.action, Selector(("selectToolFromMenu:")))
            XCTAssertTrue(item.tag != 0)
        }

        XCTAssertTrue(topItems.dropFirst(16).first?.isSeparatorItem == true)
        let swap = try XCTUnwrap(topItems.first { $0.title == "Swap Colors" })
        XCTAssertEqual(swap.action, Selector(("swapColorsFromMenu:")))
        let reset = try XCTUnwrap(topItems.first { $0.title == "Default Colors" })
        XCTAssertEqual(reset.action, Selector(("resetColorsFromMenu:")))

        let allTags = topItems.flatMap { item -> [Int] in
            if let submenu = item.submenu { return submenu.items.map(\.tag) }
            return item.isSeparatorItem ? [] : [item.tag]
        }
        XCTAssertEqual(allTags.count, 28)
        XCTAssertEqual(Set(allTags).count, 28)
        XCTAssertEqual(tools.items.filter(\.isSeparatorItem).count, 1)
    }

    func testToolMenuItemsHaveNoKeyEquivalentsByDefault() throws {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        let tools = try XCTUnwrap(toolsSubmenu(in: menu))
        for item in tools.items where !item.isSeparatorItem {
            if let submenu = item.submenu {
                for leaf in submenu.items {
                    XCTAssertEqual(leaf.keyEquivalent, "")
                    XCTAssertEqual(leaf.keyEquivalentModifierMask, [])
                }
            } else {
                XCTAssertEqual(item.keyEquivalent, "")
                XCTAssertEqual(item.keyEquivalentModifierMask, [])
            }
        }
    }

    func testShortcutRegistryKeepsAllToolAndColorDefaultsUnassigned() throws {
        _ = NSApplication.shared
        let menu = MainMenu.make()
        let tools = try XCTUnwrap(toolsSubmenu(in: menu))
        let collection = MenuShortcutBridge.collect(from: menu)
        let leaves = tools.items.flatMap { $0.submenu?.items ?? [$0] }.filter { !$0.isSeparatorItem }
        let records = collection.records.filter { record in leaves.contains { $0 === record.item } }
        XCTAssertEqual(records.count, 28)
        XCTAssertEqual(Set(records.map(\.id)).count, 28)
        XCTAssertTrue(records.allSatisfy { $0.base == nil && $0.snapshot.keyEquivalent.isEmpty
            && $0.snapshot.modifierMask.isEmpty })
        XCTAssertEqual(Set(records.filter { $0.item.action == Selector(("selectToolFromMenu:")) }.map { $0.item.tag }), Set(1...26))
        XCTAssertEqual(collection.byID["saveDocumentAs:#0"]?.first?.snapshot.keyEquivalent, "S")
        XCTAssertEqual(collection.byID["saveDocumentAs:#0"]?.first?.snapshot.modifierMask, [.command])
    }

}
