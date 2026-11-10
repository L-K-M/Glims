import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class CloseAllMenuTests: XCTestCase {
    private let action = Selector(("closeAllDocuments:"))

    func testFileMenuOffersCloseAllAndRegistersItsShortcut() throws {
        let menu = MainMenu.make()
        let file = try XCTUnwrap(menu.item(withTitle: "File")?.submenu)
        let item = try XCTUnwrap(file.items.first { $0.action == action })
        XCTAssertEqual(item.title, "Close All")
        XCTAssertEqual(item.keyEquivalent, "w")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .option])
        let closeIndex = try XCTUnwrap(file.items.firstIndex { $0.action == #selector(NSWindow.performClose(_:)) })
        XCTAssertTrue(file.items[closeIndex + 1] === item)
        XCTAssertEqual(MenuShortcutBridge.collect(menu).records.filter { $0.item === item }.count, 1)
    }

    func testNoDocumentCloseAllIsDisabledAndQueuesNothing() {
        let owner = AppController()
        let item = NSMenuItem(title: "Close All", action: action, keyEquivalent: "w")
        XCTAssertFalse(owner.validateMenuItem(item))
        guard owner.responds(to: action) else {
            return XCTFail("Close All has no application command route")
        }
        let wasRunning = NSApp.isRunning
        XCTAssertTrue(NSApp.sendAction(action, to: owner, from: item))
        XCTAssertTrue(owner.documents.isEmpty)
        XCTAssertFalse(owner.validateMenuItem(item))
        XCTAssertEqual(NSApp.isRunning, wasRunning)
        if case .starting = owner.state {} else { XCTFail("Close All changed engine startup state") }
    }
}
