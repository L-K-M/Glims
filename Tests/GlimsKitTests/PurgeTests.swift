import AppKit
import CGlimsEngine
import XCTest
@testable import GlimsKit

/// Edit > Purge: the target bits, the clipboard ownership rule and the
/// menu wiring. The engine transport is covered by the purge smoke case.
@MainActor
final class PurgeTests: XCTestCase {
    func testPurgeTargetRawValuesMatchTheFacade() {
        XCTAssertEqual(EngineSession.PurgeTargets.undo.rawValue, GLIMS_PURGE_UNDO.rawValue)
        XCTAssertEqual(EngineSession.PurgeTargets.clipboard.rawValue, GLIMS_PURGE_CLIPBOARD.rawValue)
        XCTAssertEqual(EngineSession.PurgeTargets.histories.rawValue, GLIMS_PURGE_HISTORIES.rawValue)
        let all = EngineSession.PurgeTargets.undo.union(.clipboard).union(.histories)
        XCTAssertEqual(all.rawValue, 7)
        XCTAssertTrue(EngineSession.PurgeTargets.undo.isDisjoint(with: .clipboard))
    }

    func testClipboardOwnershipRule() {
        XCTAssertFalse(ClipboardImage.clipboardIsOwned(current: 5, owned: nil),
                       "Glims has not written, so nothing is its own copy")
        XCTAssertTrue(ClipboardImage.clipboardIsOwned(current: 5, owned: 5))
        XCTAssertFalse(ClipboardImage.clipboardIsOwned(current: 6, owned: 5),
                       "another application replaced the pasteboard")
    }

    func testTheEditMenuListsPurgeWithItsActions() {
        let menu = MainMenu.make()
        let edit = menu.items.first { $0.title == "Edit" }?.submenu
        let purge = edit?.items.first { $0.title == "Purge" }?.submenu
        XCTAssertEqual(purge?.items.map(\.title), ["Undo", "Clipboard", "Histories", "All"])
        XCTAssertEqual(purge?.items[0].action, #selector(DocumentWindowController.purgeUndo(_:)))
        XCTAssertEqual(purge?.items[1].action, #selector(AppController.purgeClipboard(_:)))
        XCTAssertEqual(purge?.items[2].action, #selector(AppController.purgeHistories(_:)))
        XCTAssertEqual(purge?.items[3].action, #selector(AppController.purgeAll(_:)))
        for item in purge?.items ?? [] {
            XCTAssertEqual(item.keyEquivalent, "", "\(item.title) takes no shortcut")
        }
    }

    func testAppWidePurgeItemsValidateWithoutAnEngine() {
        let controller = AppController()
        let items = [
            NSMenuItem(title: "Clipboard", action: #selector(AppController.purgeClipboard(_:)), keyEquivalent: ""),
            NSMenuItem(title: "Histories", action: #selector(AppController.purgeHistories(_:)), keyEquivalent: ""),
            NSMenuItem(title: "All", action: #selector(AppController.purgeAll(_:)), keyEquivalent: ""),
        ]
        for item in items {
            XCTAssertFalse(controller.validateMenuItem(item), "\(item.title) is offered without an engine")
        }
    }
}
