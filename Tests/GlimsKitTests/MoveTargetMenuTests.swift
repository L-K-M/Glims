import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class MoveTargetMenuTests: XCTestCase {
    func testInstalledMoveTargetMenuAndOptionsShareTheSettingWithoutADocument() throws {
        let app = NSApplication.shared
        let state = ToolState.shared
        let originalTool = state.current, originalMode = state.moveTargetMode
        let originalMenu = app.mainMenu, originalDelegate = app.delegate
        let owner = AppController()
        let menu = MainMenu.make()
        state.select(shortcut: ToolID.move.shortcut, cycle: false)
        let originalMoveGroupTool = state.current
        app.delegate = owner
        app.mainMenu = menu
        defer {
            app.mainMenu = originalMenu
            app.delegate = originalDelegate
            state.setMoveTargetMode(originalMode)
            state.select(originalMoveGroupTool)
            state.select(originalTool)
        }

        XCTAssertNil(owner.session)
        XCTAssertNil(owner.frontDocument)
        let view = try XCTUnwrap(menu.item(withTitle: "View")?.submenu)
        let toolsIndex = try XCTUnwrap(view.items.firstIndex { $0.title == "Tools" })
        let targetIndex = try XCTUnwrap(view.items.firstIndex { $0.title == "Move Target" })
        XCTAssertEqual(targetIndex, toolsIndex + 1)
        let target = try XCTUnwrap(view.items[targetIndex].submenu)
        XCTAssertEqual(target.items.map(\.title), ["Current Layer", "Pick Layer or Guide"])
        let current = try XCTUnwrap(target.item(withTitle: "Current Layer"))
        let pick = try XCTUnwrap(target.item(withTitle: "Pick Layer or Guide"))
        let currentAction = try XCTUnwrap(current.action)
        let pickAction = try XCTUnwrap(pick.action)

        let commands = MenuShortcutBridge.collect(from: menu).records.filter { $0.item === current || $0.item === pick }
        XCTAssertEqual(commands.map(\.id), ["selectMoveTargetFromMenu:#1003", "selectMoveTargetFromMenu:#1004"])
        XCTAssertTrue(commands.allSatisfy { $0.base == nil && $0.snapshot.keyEquivalent.isEmpty
            && $0.snapshot.modifierMask.isEmpty })
        XCTAssertTrue(target.items.allSatisfy { $0.target == nil })

        state.setMoveTargetMode(.currentLayer)
        state.select(.zoom)
        let zoomRevision = state.selectionRevision
        target.update()
        XCTAssertTrue(current.isEnabled && pick.isEnabled)
        XCTAssertEqual(target.items.map(\.state), [.on, .off])
        XCTAssertTrue(app.sendAction(pickAction, to: nil, from: pick))
        XCTAssertEqual(state.moveTargetMode, .pickLayerOrGuide)
        XCTAssertEqual(state.current, .zoom)
        XCTAssertEqual(state.selectionRevision, zoomRevision)
        target.update()
        XCTAssertEqual(target.items.map(\.state), [.off, .on])

        state.select(.move)
        let moveRevision = state.selectionRevision
        let options = ToolOptionsPaletteController()
        func findPopup(in view: NSView) -> NSPopUpButton? {
            if let popup = view as? NSPopUpButton, popup.identifier?.rawValue == "move-target-mode" { return popup }
            for child in view.subviews {
                if let popup = findPopup(in: child) { return popup }
            }
            return nil
        }
        XCTAssertEqual(try XCTUnwrap(findPopup(in: options.view)).selectedItem?.title, "Pick Layer or Guide")
        XCTAssertTrue(app.sendAction(currentAction, to: nil, from: current))
        let popup = try XCTUnwrap(findPopup(in: options.view))
        XCTAssertEqual(popup.selectedItem?.title, "Current Layer")
        target.update()
        XCTAssertEqual(target.items.map(\.state), [.on, .off])

        popup.selectItem(withTitle: "Pick Layer or Guide")
        XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
        XCTAssertEqual(state.moveTargetMode, .pickLayerOrGuide)
        XCTAssertEqual(state.selectionRevision, moveRevision)
        target.update()
        XCTAssertEqual(target.items.map(\.state), [.off, .on])

        let invalid = NSMenuItem(title: "Invalid move target", action: currentAction, keyEquivalent: "")
        invalid.identifier = MenuShortcutBridge.builtinIdentifier
        invalid.tag = -1
        XCTAssertFalse(owner.validateMenuItem(invalid))
        XCTAssertEqual(invalid.state, .off)
        XCTAssertTrue(app.sendAction(currentAction, to: nil, from: invalid))
        XCTAssertEqual(state.moveTargetMode, .pickLayerOrGuide)
        invalid.identifier = nil
        invalid.tag = current.tag
        XCTAssertFalse(owner.validateMenuItem(invalid))
        XCTAssertTrue(app.sendAction(currentAction, to: nil, from: invalid))
        XCTAssertEqual(state.moveTargetMode, .pickLayerOrGuide)
    }
}
