import AppKit
import XCTest
@testable import GlimsKit

/// The Help menu's commands, the Help window's policy and its search state.
@MainActor
final class HelpWindowTests: XCTestCase {
    func testHelpMenuOffersTheThreeCommands() {
        let menu = MainMenu.make()
        let help = menu.items.first { $0.title == "Help" }?.submenu
        XCTAssertNotNil(help, "the menu bar has no Help menu")
        guard let help else { return }
        let actions = help.items.compactMap(\.action)
        for action in [#selector(AppController.showHelp(_:)),
                       #selector(AppController.showKeyboardReference(_:)),
                       #selector(AppController.openEngineManual(_:))] {
            XCTAssertTrue(actions.contains(action), "Help has no item for \(action)")
        }
        let helpItem = help.items.first { $0.action == #selector(AppController.showHelp(_:)) }
        XCTAssertEqual(helpItem?.keyEquivalent, "?", "Glims Help keeps the macOS Command-? convention")
    }

    /// Help works without the engine: its items must not wait for a session.
    func testHelpCommandsAreAvailableWithoutTheEngine() {
        let controller = AppController()
        for action in [#selector(AppController.showHelp(_:)),
                       #selector(AppController.showKeyboardReference(_:)),
                       #selector(AppController.openEngineManual(_:))] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            XCTAssertTrue(controller.validateMenuItem(item), "\(action) is disabled without an engine")
        }
    }

    /// Opening Help must preserve the current document target: the window
    /// takes key focus but never becomes main (like PreferencesPanel).
    func testHelpWindowNeverBecomesMain() {
        let controller = HelpWindowController()
        guard let window = controller.window else { return XCTFail("the Help window did not build") }
        XCTAssertFalse(window.canBecomeMain)
        XCTAssertTrue(window.canBecomeKey)
    }

    func testKeyboardReferenceSectionOpens() {
        let controller = HelpWindowController()
        controller.show(section: HelpManual.keyboardReferenceTitle)
        XCTAssertTrue(controller.displayedText.hasPrefix(HelpManual.keyboardReferenceTitle))
        XCTAssertTrue(controller.displayedText.contains("Command-S"))
    }

    func testSearchSelectsAndStepsThroughMatches() {
        let controller = HelpWindowController()
        controller.query = "THE"
        controller.findNext()
        let first = controller.selection
        XCTAssertGreaterThan(first.length, 0, "the search found nothing to select")
        XCTAssertNil(controller.noResultsQuery)

        controller.findNext()
        let second = controller.selection
        XCTAssertGreaterThan(second.location, first.location, "find next did not advance")
    }

    func testNoResultsStateEntersAndClears() {
        let controller = HelpWindowController()
        let before = controller.selection

        controller.query = "zzz-no-such-text"
        controller.findNext()
        XCTAssertEqual(controller.noResultsQuery, "zzz-no-such-text")
        XCTAssertEqual(controller.selection, before, "a failed search moved the selection")

        controller.query = "the"
        controller.findNext()
        XCTAssertNil(controller.noResultsQuery, "a successful search kept the no-results state")
        XCTAssertGreaterThan(controller.selection.length, 0)

        controller.query = ""
        controller.findNext()
        XCTAssertNil(controller.noResultsQuery, "clearing the query kept the no-results state")
    }
}
