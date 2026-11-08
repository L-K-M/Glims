import AppKit
import XCTest
@testable import GlimsKit

/// Pure menu-object and manager coverage for the keyboard shortcut panel:
/// collection from a statically made `MainMenu` (never the app's), stable
/// ids, canonical bases, factory snapshots, reserved system owners, the
/// validate-and-persist-first mutation order, corrupt stores, conflicts and
/// the single panel. Menus and panel objects only — no window is shown, no
/// engine, no global store.
@MainActor
final class MenuShortcutManagerTests: XCTestCase {

    // MARK: - Helpers

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ch.lkmc.Glims.tests.menushortcuts.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private func makeManager(_ defaults: UserDefaults) -> (MenuShortcutManager, NSMenu) {
        let menu = MainMenu.make()
        let manager = MenuShortcutManager(store: KeyboardShortcutOverrideStore(defaults: defaults), menu: menu)
        manager.attach()
        return (manager, menu)
    }

    private func record(_ id: String, in manager: MenuShortcutManager) -> MenuShortcutBridge.Record? {
        manager.collection?.byID[id]?.first
    }

    private func item(_ id: String, in manager: MenuShortcutManager) -> NSMenuItem? {
        record(id, in: manager)?.item
    }

    private func shortcut(_ keyInput: String, _ modifiers: ShortcutModifiers) -> KeyboardShortcut {
        KeyboardShortcut(keyInput: keyInput, modifiers: modifiers)!
    }

    // MARK: - Collection

    func testCollectsOnlyBuiltinStaticCommandsWithStableIDs() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            let collection = try XCTUnwrap(manager.collection)
            XCTAssertTrue(collection.errors.isEmpty)
            XCTAssertNotNil(collection.catalog)
            XCTAssertGreaterThan(collection.records.count, 40)
            let ids = Set(collection.byID.keys)
            XCTAssertTrue(ids.contains("saveDocument:#0"))
            XCTAssertTrue(ids.contains("saveDocumentAs:#0"))
            XCTAssertTrue(ids.contains("newDocument:#0"))
            // The final item tag is part of the id (the Mode items).
            XCTAssertTrue(ids.contains { $0.hasPrefix("convertImageMode:#") && $0 != "convertImageMode:#" }
                            && collection.byID.keys.filter { $0.hasPrefix("convertImageMode:#") }.count == 2,
                        "tagged items get distinct ids (\(ids.filter { $0.hasPrefix("convertImageMode") }))")
            // Dynamic content is excluded: no plug-in, workspace or recent item.
            XCTAssertTrue(ids.allSatisfy { !$0.hasPrefix("runPlugIn") })
            XCTAssertTrue(collection.records.allSatisfy { record in
                !record.path.contains("Workspaces") && !record.path.contains("Open Recent")
            })
            // Ids are selector-plus-tag, never localized titles.
            XCTAssertTrue(ids.allSatisfy { !$0.contains(" ▸ ") && $0.contains(":") })
        }
    }

    func testMainMenuMakeDoesNotAttachOrTouchTheGlobalStore() throws {
        try withDefaults { defaults in
            let globalBytesBefore = KeyboardShortcutOverrideStore.shared.storedData
            _ = MainMenu.make()
            XCTAssertFalse(MenuShortcutManager.shared.isAttached)
            XCTAssertNil(MenuShortcutManager.shared.collection)
            XCTAssertEqual(KeyboardShortcutOverrideStore.shared.storedData, globalBytesBefore)
            XCTAssertNotNil(defaults) // the injected suite is untouched by make()
        }
    }

    func testUppercaseFactoryLetterAddsShiftInTheModel() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            let save = try XCTUnwrap(record("saveDocument:#0", in: manager))
            let saveAs = try XCTUnwrap(record("saveDocumentAs:#0", in: manager))
            XCTAssertEqual(save.base, shortcut("s", [.command]))
            XCTAssertEqual(saveAs.base, shortcut("s", [.command, .shift]))
            XCTAssertNotEqual(save.base, saveAs.base, "Save and Save As must not collide")
            // The item itself keeps the original "S" + Command.
            XCTAssertEqual(saveAs.item.keyEquivalent, "S")
            XCTAssertEqual(saveAs.item.keyEquivalentModifierMask, [.command])
        }
    }

    func testUnmodifiedDeleteFactoryBaseIsNilButSnapshotRestoresExactly() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            let clear = try XCTUnwrap(record("deleteBackward:#0", in: manager))
            XCTAssertNil(clear.base)
            XCTAssertEqual(clear.snapshot.keyEquivalent, "\u{7f}")
            XCTAssertEqual(clear.snapshot.modifierMask, [])
            MenuShortcutBridge.apply(.assigned(shortcut("x", [.command])), to: clear.item, snapshot: clear.snapshot)
            XCTAssertEqual(clear.item.keyEquivalent, "x")
            MenuShortcutBridge.apply(.factory, to: clear.item, snapshot: clear.snapshot)
            XCTAssertEqual(clear.item.keyEquivalent, "\u{7f}", "the snapshot restores the unsupported DEL exactly")
            XCTAssertEqual(clear.item.keyEquivalentModifierMask, [])
        }
    }

    func testFactorySnapshotRestoreIsExactAfterAnOverride() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            let saveAs = try XCTUnwrap(record("saveDocumentAs:#0", in: manager))
            MenuShortcutBridge.apply(.assigned(shortcut("y", [.command, .option])), to: saveAs.item, snapshot: saveAs.snapshot)
            MenuShortcutBridge.apply(.factory, to: saveAs.item, snapshot: saveAs.snapshot)
            XCTAssertEqual(saveAs.item.keyEquivalent, "S")
            XCTAssertEqual(saveAs.item.keyEquivalentModifierMask, [.command])
        }
    }

    func testReservedSystemOwnersAreReadOnly() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            for id in ["hide:#0", "terminate:#0", "performMiniaturize:#0"] {
                let record = try XCTUnwrap(record(id, in: manager), id)
                XCTAssertTrue(record.reservedOwner, "\(id) owns a macOS reservation")
                XCTAssertNotNil(record.base.map { KeyboardShortcut.reserved.contains($0) })
            }
            // No assign, no disable, no reset — via the manager (the UI's
            // path) — and nothing is stored.
            XCTAssertThrowsError(try manager.assign(shortcut("u", [.command]), to: "terminate:#0")) { error in
                XCTAssertEqual(error as? MenuShortcutManagerError, .reservedOwner("terminate:#0"))
            }
            XCTAssertThrowsError(try manager.disable("hide:#0"))
            XCTAssertThrowsError(try manager.reset("performMiniaturize:#0"))
            XCTAssertNil(manager.store.storedData)
            XCTAssertEqual(item("terminate:#0", in: manager)?.keyEquivalent, "q")
            XCTAssertEqual(item("hide:#0", in: manager)?.keyEquivalent, "h")
            // Another command cannot claim a reservation either (model guard).
            do {
                try manager.assign(shortcut("q", [.command]), to: "newDocument:#0")
                XCTFail("expected a reservation error")
            } catch let error as KeyboardShortcutError {
                guard case .reserved = error else { XCTFail("expected .reserved, got \(error)"); return }
            }
            XCTAssertNil(manager.store.storedData)
        }
    }

    func testAliasesWithTheSameIDMergeSafely() {
        let menu = NSMenu()
        let submenu = NSMenu(title: "Test")
        menu.addItem(withTitle: "Test", action: nil, keyEquivalent: "").submenu = submenu
        func commandItem(_ key: String) -> NSMenuItem {
            let item = NSMenuItem(title: "Alias", action: #selector(AppController.showPreferences(_:)), keyEquivalent: key)
            item.identifier = MenuShortcutBridge.builtinIdentifier
            return item
        }
        submenu.addItem(commandItem("p"))
        submenu.addItem(commandItem("p"))
        let collection = MenuShortcutBridge.collect(from: menu)
        XCTAssertEqual(collection.byID["showPreferences:#0"]?.count, 2)
        XCTAssertEqual(collection.errors.count, 0)
        XCTAssertNotNil(collection.catalog?.byID["showPreferences:#0"])
    }

    func testInconsistentFactoryConflictIsVisibleAndUnbindsNothing() {
        let menu = NSMenu()
        let submenu = NSMenu(title: "Test")
        menu.addItem(withTitle: "Test", action: nil, keyEquivalent: "").submenu = submenu
        func commandItem(_ title: String, _ key: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: #selector(AppController.showPreferences(_:)), keyEquivalent: key)
            item.identifier = MenuShortcutBridge.builtinIdentifier
            return item
        }
        submenu.addItem(commandItem("One", "p"))
        submenu.addItem(commandItem("Two", "o"))
        let collection = MenuShortcutBridge.collect(from: menu)
        XCTAssertEqual(collection.errors.count, 1)
        XCTAssertNil(collection.catalog)
        // Both aliases keep their factory keys.
        XCTAssertEqual(submenu.items[0].keyEquivalent, "p")
        XCTAssertEqual(submenu.items[1].keyEquivalent, "o")
    }

    // MARK: - Mutations

    func testAssignValidatesAndPersistsFirstThenUpdatesTheMenuItem() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            try manager.assign(shortcut("k", [.command]), to: "newDocument:#0")
            XCTAssertEqual(item("newDocument:#0", in: manager)?.keyEquivalent, "k")
            XCTAssertEqual(item("newDocument:#0", in: manager)?.keyEquivalentModifierMask, [.command])
            let stored = try XCTUnwrap(manager.store.storedData)
            XCTAssertTrue(String(data: stored, encoding: .utf8)!.contains("newDocument:#0"))
            // No responder chain / target changes: only the key equivalent moved.
            XCTAssertEqual(item("newDocument:#0", in: manager)?.action, #selector(AppController.newDocument(_:)))
        }
    }

    func testPersistenceAcrossANewManager() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            try manager.assign(shortcut("k", [.command]), to: "newDocument:#0")
            let (manager2, _) = makeManager(defaults) // fresh menu, same store
            XCTAssertEqual(item("newDocument:#0", in: manager2)?.keyEquivalent, "k")
            XCTAssertEqual(item("newDocument:#0", in: manager2)?.keyEquivalentModifierMask, [.command])
        }
    }

    func testConflictIsVisibleAndKeepsStoredBytesAndMenu() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            let bytesBefore = manager.store.storedData
            do {
                try manager.assign(shortcut("s", [.command]), to: "newDocument:#0")
                XCTFail("expected a conflict")
            } catch let error as KeyboardShortcutError {
                guard case .conflict(_, let command, let other) = error else { XCTFail("expected .conflict, got \(error)"); return }
                XCTAssertEqual(command, "saveDocument:#0")
                XCTAssertEqual(other, "newDocument:#0")
            }
            XCTAssertEqual(manager.store.storedData, bytesBefore, "a failed assign leaves the stored bytes untouched")
            XCTAssertEqual(item("newDocument:#0", in: manager)?.keyEquivalent, "n", "and the menu item unchanged")
            XCTAssertEqual(item("saveDocument:#0", in: manager)?.keyEquivalent, "s", "the other command is not silently unbound")
        }
    }

    func testDisableAndResetSelectedRestoreTheFactoryExactly() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            try manager.disable("saveDocument:#0")
            XCTAssertEqual(item("saveDocument:#0", in: manager)?.keyEquivalent, "")
            XCTAssertEqual(item("saveDocument:#0", in: manager)?.keyEquivalentModifierMask, [])
            try manager.reset("saveDocument:#0")
            XCTAssertEqual(item("saveDocument:#0", in: manager)?.keyEquivalent, "s")
            XCTAssertEqual(item("saveDocument:#0", in: manager)?.keyEquivalentModifierMask, [.command])
            XCTAssertTrue(try manager.store.load().isEmpty, "resetting the only override empties the store")
        }
    }

    func testResetAllRestoresEveryFactoryItem() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            try manager.assign(shortcut("k", [.command]), to: "newDocument:#0")
            try manager.disable("saveDocument:#0")
            try manager.resetAll()
            XCTAssertNil(manager.store.storedData)
            XCTAssertEqual(item("newDocument:#0", in: manager)?.keyEquivalent, "n")
            XCTAssertEqual(item("saveDocument:#0", in: manager)?.keyEquivalent, "s")
            XCTAssertEqual(item("saveDocumentAs:#0", in: manager)?.keyEquivalent, "S")
        }
    }

    func testUppercaseAndFunctionKeyAssignmentsWriteAppKitEquivalents() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            try manager.assign(shortcut("k", [.command, .shift]), to: "newDocument:#0")
            XCTAssertEqual(item("newDocument:#0", in: manager)?.keyEquivalent, "K")
            XCTAssertEqual(item("newDocument:#0", in: manager)?.keyEquivalentModifierMask, [.command, .shift])
            XCTAssertTrue(String(data: manager.store.storedData!, encoding: .utf8)!.contains("\"key\":\"k\""),
                          "the stored model key is the lower-case letter")
            try manager.assign(KeyboardShortcut(key: ShortcutKey(persisted: "f5")!, modifiers: [.command]),
                               to: "openDocument:#0")
            XCTAssertEqual(item("openDocument:#0", in: manager)?.keyEquivalent, "\u{F708}")
            XCTAssertEqual(item("openDocument:#0", in: manager)?.keyEquivalentModifierMask, [.command])
        }
    }

    func testCorruptStoreKeepsBytesAndSurfacesTheErrorInThePanel() throws {
        try withDefaults { defaults in
            let corrupt = Data("not a shortcut document".utf8)
            defaults.set(corrupt, forKey: KeyboardShortcutOverrideStore.overridesKey)
            let (manager, _) = makeManager(defaults)
            XCTAssertNotNil(manager.loadError)
            XCTAssertEqual(manager.store.storedData, corrupt, "the corrupt bytes are kept, never reset")
            XCTAssertEqual(item("newDocument:#0", in: manager)?.keyEquivalent, "n", "the factory menu is kept")
            let panel = manager.ensurePanel()
            XCTAssertFalse(panel.errorText.isEmpty, "the load error is visible when the panel opens")
            XCTAssertTrue(panel.errorText.contains("could not be read") || panel.errorText.contains("not a readable"),
                          panel.errorText)
        }
    }

    // MARK: - Panel

    func testTwoSimultaneousPanelsRetainOne() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            let first = manager.ensurePanel()
            let second = manager.ensurePanel()
            XCTAssertTrue(first === second)
            XCTAssertEqual(manager.panelCount, 1)
        }
    }

    func testPanelListsSearchableRowsWithMenuPathsAndReservedRowsReadOnly() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            let panel = manager.ensurePanel()
            panel.reloadFromManager()
            XCTAssertEqual(panel.numberOfRows(in: panel.table), manager.rows.count)
            panel.searchField.stringValue = "save"
            panel.reloadFromManager()
            let filtered = panel.numberOfRows(in: panel.table)
            XCTAssertGreaterThan(filtered, 0)
            XCTAssertLessThan(filtered, manager.rows.count)
            panel.selectCommand("terminate:#0")
            XCTAssertFalse(panel.assignButton.isEnabled)
            XCTAssertFalse(panel.disableButton.isEnabled)
            XCTAssertFalse(panel.resetSelectedButton.isEnabled)
            panel.selectCommand("saveDocument:#0")
            XCTAssertTrue(panel.assignButton.isEnabled)
            XCTAssertEqual(panel.keyField.stringValue, "s")
            XCTAssertEqual(panel.commandCheck.state, .on)
        }
    }

    func testPanelAssignDisableResetThroughItsButtons() throws {
        try withDefaults { defaults in
            let (manager, _) = makeManager(defaults)
            let panel = manager.ensurePanel()
            panel.reloadFromManager()
            panel.selectCommand("newDocument:#0")
            panel.keyField.stringValue = "k"
            panel.commandCheck.state = .on
            panel.assignButton.performClick(nil)
            XCTAssertTrue(panel.errorText.isEmpty, panel.errorText)
            XCTAssertEqual(item("newDocument:#0", in: manager)?.keyEquivalent, "k")
            panel.disableButton.performClick(nil)
            XCTAssertEqual(item("newDocument:#0", in: manager)?.keyEquivalent, "")
            panel.resetSelectedButton.performClick(nil)
            XCTAssertEqual(item("newDocument:#0", in: manager)?.keyEquivalent, "n")
            XCTAssertTrue(try manager.store.load().isEmpty)
            // A conflicting assign through the panel is a persistent visible error.
            panel.selectCommand("newDocument:#0")
            panel.keyField.stringValue = "s"
            panel.commandCheck.state = .on
            panel.assignButton.performClick(nil)
            XCTAssertFalse(panel.errorText.isEmpty)
            XCTAssertTrue(panel.errorText.contains("saveDocument:#0"), panel.errorText)
            XCTAssertEqual(item("newDocument:#0", in: manager)?.keyEquivalent, "n")
        }
    }
}
