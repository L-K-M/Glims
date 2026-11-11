import AppKit
import XCTest
@testable import GlimsKit

final class ToolMenuCatalogTests: XCTestCase {
    func testSlotGroupsMirrorPaletteSlotsAndTagsAreStable() {
        XCTAssertEqual(ToolMenuCatalog.slotGroups.map(\.tools), ToolID.paletteSlots)
        let stable: [(ToolID, Int)] = [
            (.move, 1), (.transform, 2), (.crop, 3), (.rectangleSelect, 4), (.ellipseSelect, 5),
            (.lasso, 6), (.magicWand, 7), (.selectByColor, 8), (.eyedropper, 9), (.text, 10),
            (.path, 11), (.paintbrush, 12), (.pencil, 13), (.airbrush, 14), (.eraser, 15),
            (.clone, 16), (.heal, 17), (.smudge, 18), (.blur, 19), (.sharpen, 20),
            (.dodge, 21), (.burn, 22), (.gradient, 23), (.bucketFill, 24), (.hand, 25), (.zoom, 26),
        ]
        for (tool, tag) in stable { XCTAssertEqual(ToolMenuCatalog.tag(for: tool), tag) }
        let tags = ToolID.allCases.map(ToolMenuCatalog.tag(for:))
        XCTAssertEqual(Set(tags).count, ToolID.allCases.count)
        XCTAssertTrue(tags.allSatisfy { $0 > 0 })
        XCTAssertFalse(tags.contains(ToolMenuCatalog.swapColorsTag))
        XCTAssertFalse(tags.contains(ToolMenuCatalog.defaultColorsTag))
        for tool in ToolID.allCases {
            XCTAssertEqual(ToolMenuCatalog.tool(forTag: ToolMenuCatalog.tag(for: tool)), tool)
        }
        XCTAssertNil(ToolMenuCatalog.tool(forTag: 0))
        XCTAssertNil(ToolMenuCatalog.tool(forTag: ToolMenuCatalog.swapColorsTag))
    }

    func testColorCommandTagsAreDistinct() {
        XCTAssertNotEqual(ToolMenuCatalog.swapColorsTag, ToolMenuCatalog.defaultColorsTag)
    }

    @MainActor
    func testGlobalContextRoutesRejectUnknownMenuIdentitiesWithoutAnEngine() throws {
        _ = NSApplication.shared
        let owner = AppController()
        let state = ToolState.shared
        let before = state.current
        let menu = MainMenu.make()
        let tools = try XCTUnwrap(menu.item(withTitle: "View")?.submenu?.item(withTitle: "Tools")?.submenu)
        let items = tools.items.flatMap { $0.submenu?.items ?? [$0] }.filter { !$0.isSeparatorItem }
        XCTAssertEqual(items.count, 30)
        XCTAssertTrue(items.allSatisfy(owner.validateMenuItem))
        XCTAssertNil(owner.session)
        let invalid = NSMenuItem(title: "Invalid tool", action: Selector(("selectToolFromMenu:")), keyEquivalent: "")
        invalid.identifier = MenuShortcutBridge.builtinIdentifier
        for tag in [-1, 0, 27, 1001, Int.max] {
            invalid.tag = tag
            XCTAssertFalse(owner.validateMenuItem(invalid))
            owner.selectToolFromMenu(invalid)
            XCTAssertEqual(state.current, before)
        }
        invalid.tag = 1; invalid.identifier = nil
        XCTAssertFalse(owner.validateMenuItem(invalid))
        owner.selectToolFromMenu(invalid)
        owner.selectToolFromMenu(nil)
        XCTAssertEqual(state.current, before)
    }

}
