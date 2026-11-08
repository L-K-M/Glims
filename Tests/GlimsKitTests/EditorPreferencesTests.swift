import AppKit
import RigiUI
import XCTest
@testable import GlimsKit

@MainActor
final class EditorPreferencesTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults, String) throws -> Void) rethrows {
        let suite = "ch.lkmc.Glims.tests.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults, suite)
    }

    func testChoicesPersistAcrossPreferenceInstances() {
        withDefaults { defaults, _ in
            let preferences = EditorPreferences(defaults: defaults)
            XCTAssertEqual(preferences.appearance, .classicLight)
            XCTAssertEqual(preferences.surround, .medium)
            XCTAssertEqual(preferences.initialView, .fit)
            preferences.appearance = .dark
            preferences.surround = .light
            preferences.initialView = .actualPixels
            let reopened = EditorPreferences(defaults: defaults)
            XCTAssertEqual(reopened.appearance, .dark)
            XCTAssertEqual(reopened.surround, .light)
            XCTAssertEqual(reopened.initialView, .actualPixels)
        }
    }

    func testInvalidStoredChoicesUseDefaults() {
        withDefaults { defaults, _ in
            defaults.set("missing", forKey: "editor.appearance")
            defaults.set(1000, forKey: "editor.canvasSurround")
            defaults.set(["unexpected"], forKey: "editor.initialView")
            defaults.set(7, forKey: "editor.recoveryInterval")
            defaults.set("yes", forKey: "editor.recoveryCopies")
            let preferences = EditorPreferences(defaults: defaults)
            XCTAssertEqual(preferences.appearance, .classicLight)
            XCTAssertEqual(preferences.surround, .medium)
            XCTAssertEqual(preferences.initialView, .fit)
            XCTAssertEqual(preferences.recoveryInterval, .twoMinutes)
            XCTAssertTrue(preferences.recoveryCopiesEnabled)
        }
    }

    /// Recovery copies are on at two minutes by default, persist, and
    /// reset with the rest of the editor-owned keys.
    func testRecoveryChoicesPersistAndReset() {
        withDefaults { defaults, _ in
            let preferences = EditorPreferences(defaults: defaults)
            XCTAssertTrue(preferences.recoveryCopiesEnabled)
            XCTAssertEqual(preferences.recoveryInterval, .twoMinutes)
            preferences.recoveryCopiesEnabled = false
            preferences.recoveryInterval = .tenMinutes
            let reopened = EditorPreferences(defaults: defaults)
            XCTAssertFalse(reopened.recoveryCopiesEnabled)
            XCTAssertEqual(reopened.recoveryInterval, .tenMinutes)
            reopened.reset()
            XCTAssertTrue(reopened.recoveryCopiesEnabled)
            XCTAssertEqual(reopened.recoveryInterval, .twoMinutes)
        }
    }

    func testResetKeepsUnrelatedSettingsAndNotifiesOnce() {
        withDefaults { defaults, _ in
            let center = NotificationCenter()
            let preferences = EditorPreferences(defaults: defaults, notifications: center)
            preferences.appearance = .neutralGray
            preferences.surround = .dark
            preferences.initialView = .actualPixels
            defaults.set("kept", forKey: "other.setting")
            var count = 0
            let token = center.addObserver(forName: EditorPreferences.didChange, object: preferences, queue: nil) { _ in
                count += 1
            }
            defer { center.removeObserver(token) }
            preferences.reset()
            XCTAssertEqual(count, 1)
            XCTAssertEqual(preferences.appearance, .classicLight)
            XCTAssertEqual(preferences.surround, .medium)
            XCTAssertEqual(preferences.initialView, .fit)
            XCTAssertEqual(defaults.string(forKey: "other.setting"), "kept")
            preferences.appearance = .classicLight
            XCTAssertEqual(count, 1, "an unchanged choice does not repaint every window")
        }
    }

    func testPreferencesControlsChangeAndRestoreStoredChoices() {
        _ = NSApplication.shared
        withDefaults { defaults, _ in
            let preferences = EditorPreferences(defaults: defaults)
            let controller = PreferencesWindowController(preferences: preferences)
            defer { controller.close() }
            controller.appearancePicker.selectItem(at: 2)
            NSApp.sendAction(controller.appearancePicker.action!, to: controller.appearancePicker.target,
                             from: controller.appearancePicker)
            controller.surroundPicker.selectItem(at: 0)
            NSApp.sendAction(controller.surroundPicker.action!, to: controller.surroundPicker.target,
                             from: controller.surroundPicker)
            controller.initialViewPicker.selectItem(at: 1)
            NSApp.sendAction(controller.initialViewPicker.action!, to: controller.initialViewPicker.target,
                             from: controller.initialViewPicker)
            controller.recoveryCopiesCheck.performClick(nil)
            controller.recoveryIntervalPicker.selectItem(at: 3)
            NSApp.sendAction(controller.recoveryIntervalPicker.action!,
                             to: controller.recoveryIntervalPicker.target,
                             from: controller.recoveryIntervalPicker)
            XCTAssertEqual(preferences.appearance, .dark)
            XCTAssertEqual(preferences.surround, .light)
            XCTAssertEqual(preferences.initialView, .actualPixels)
            XCTAssertFalse(preferences.recoveryCopiesEnabled)
            XCTAssertFalse(controller.recoveryIntervalPicker.isEnabled,
                           "the interval follows the enabled choice")
            XCTAssertEqual(preferences.recoveryInterval, .tenMinutes)
            preferences.reset()
            XCTAssertEqual(controller.appearancePicker.indexOfSelectedItem, 0)
            XCTAssertEqual(controller.surroundPicker.indexOfSelectedItem, 1)
            XCTAssertEqual(controller.initialViewPicker.indexOfSelectedItem, 0)
            XCTAssertEqual(controller.recoveryCopiesCheck.state, .on)
            XCTAssertTrue(controller.recoveryIntervalPicker.isEnabled)
            XCTAssertEqual(controller.recoveryIntervalPicker.indexOfSelectedItem, 1)
        }
    }

    func testPreferencesWindowLeavesTheDocumentMain() {
        _ = NSApplication.shared
        withDefaults { defaults, _ in
            let controller = PreferencesWindowController(preferences: EditorPreferences(defaults: defaults))
            defer { controller.close() }
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            XCTAssertFalse(controller.window!.canBecomeMain,
                           "Preferences must not retarget document palettes to the last-created image")
        }
    }

    func testPreferencesMenuUsesTheStandardShortcut() throws {
        let menu = MainMenu.make()
        let app = try XCTUnwrap(menu.items.first?.submenu)
        let item = try XCTUnwrap(app.items.first { $0.action == #selector(AppController.showPreferences(_:)) })
        XCTAssertEqual(item.title, "Preferences…")
        XCTAssertEqual(item.keyEquivalent, ",")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command])
    }
}
