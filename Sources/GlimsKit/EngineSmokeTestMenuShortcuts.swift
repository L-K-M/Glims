import AppKit

@MainActor
extension EngineSmokeTest {
    /// `GLIMS_SMOKE_CASE=menu-shortcuts` (and one step of the default full
    /// run): the menu shortcut customization panel and manager against a
    /// private UserDefaults suite and a freshly made, non-app menu.
    ///
    /// Drives actual panel actions (assign / disable / reset selected /
    /// reset all through the panel's buttons) on an injected manager, checks
    /// the persisted bytes and the actual `NSMenuItem` key equivalents, and
    /// invokes one real NSMenu item action on a target. It NEVER sends the
    /// Quit, Hide or Minimize actions and never terminates the app; the
    /// system-reserved items must keep their factory key equivalents.
    static func exerciseMenuShortcuts(_ session: EngineSession, work: URL,
                                      documents: DocumentList) throws {
        _ = session
        _ = documents
        let suite = "ch.lkmc.Glims.smoke.menuShortcuts.\(ProcessInfo.processInfo.processIdentifier)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            check(false, "private UserDefaults suite for the smoke test")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.removeObject(forKey: KeyboardShortcutOverrideStore.overridesKey)
        let store = KeyboardShortcutOverrideStore(defaults: defaults)
        let menu = MainMenu.make()
        let manager = MenuShortcutManager(store: store, menu: menu)
        manager.attach()
        check(manager.isAttached, "the injected manager attaches to its own menu once")

        // Collection: built-in static commands only.
        let collection = manager.collection
        check(collection != nil && collection!.errors.isEmpty && collection!.catalog != nil,
              "the static menu collects without factory conflicts (\(collection?.errors ?? []))")
        check((collection?.records.count ?? 0) > 40,
              "the built-in menu commands are collected (\(collection?.records.count ?? 0) records)")
        let ids: Set<String> = Set(collection?.byID.keys.map { $0 } ?? [])
        check(ids.contains("saveDocument:#0") && ids.contains("saveDocumentAs:#0")
                && ids.contains("newDocument:#0") && ids.contains("deleteBackward:#0"),
              "stable ids are NSStringFromSelector plus the final item tag")
        check(ids.allSatisfy { !$0.hasPrefix("runPlugIn") },
              "dynamic plug-in commands are excluded from the catalog")
        check(collection?.records.allSatisfy { record in
            !record.path.contains("Workspaces") && !record.path.contains("Open Recent")
        } ?? false, "workspaces and recent documents are excluded from the catalog")

        // Canonical bases: Save vs Save As must not collide; the unmodified
        // DEL factory base is nil but snapshotted; system owners are reserved.
        let save = collection?.byID["saveDocument:#0"]?.first
        let saveAs = collection?.byID["saveDocumentAs:#0"]?.first
        check(save?.base == KeyboardShortcut(keyInput: "s", modifiers: [.command]),
              "Save's canonical base is s + Command")
        check(saveAs?.base == KeyboardShortcut(keyInput: "s", modifiers: [.command, .shift]),
              "Save As…'s uppercase factory letter adds Shift in the model (no collision with Save)")
        let clear = collection?.byID["deleteBackward:#0"]?.first
        check(clear?.base == nil && clear?.snapshot.keyEquivalent == "\u{7f}"
                && clear?.snapshot.modifierMask == [],
              "the unmodified DEL factory base is nil while the snapshot keeps 0x7F exactly")
        for id in ["hide:#0", "terminate:#0", "performMiniaturize:#0"] {
            check(collection?.byID[id]?.first?.reservedOwner == true,
                  "\(id) is a read-only macOS-reserved system owner")
        }

        // Actual panel actions on the injected manager.
        let panel = manager.ensurePanel()
        check(manager.panelCount == 1 && manager.ensurePanel() === panel,
              "a second panel request retains the one panel")
        panel.reloadFromManager()
        check(panel.numberOfRows(in: panel.table) == manager.rows.count,
              "the panel lists every collected command")

        func item(_ id: String) -> NSMenuItem? { collection?.byID[id]?.first?.item }

        // Assign through the panel's own controls and button.
        panel.selectCommand("newDocument:#0")
        panel.keyField.stringValue = "k"
        panel.commandCheck.state = .on
        panel.assignButton.performClick(nil)
        check(panel.errorText.isEmpty, "assigning ⌘K to New reports no error (\(panel.errorText))")
        check(item("newDocument:#0")?.keyEquivalent == "k"
                && item("newDocument:#0")?.keyEquivalentModifierMask == [.command],
              "a successful assign updates the actual menu item after persisting")
        check(store.storedData != nil
                && String(data: store.storedData!, encoding: .utf8)?.contains("newDocument:#0") == true,
              "the assign persisted the override in the private defaults")

        // Uppercase: Shift + letter writes the upper-case key equivalent.
        panel.selectCommand("openDocument:#0")
        panel.keyField.stringValue = "k"
        panel.commandCheck.state = .on
        panel.shiftCheck.state = .on
        panel.assignButton.performClick(nil)
        check(item("openDocument:#0")?.keyEquivalent == "K"
                && item("openDocument:#0")?.keyEquivalentModifierMask == [.command, .shift],
              "an assigned Shift-letter writes the upper-case key equivalent (⌘⇧K)")
        check(String(data: store.storedData!, encoding: .utf8)?.contains("\"key\":\"k\"") == true,
              "the model stores the lower-case letter form")

        // Exercise AppKit key matching itself with safe, local targets.
        // No document, Open dialog, Hide or Quit action is dispatched.
        let dispatchProbe = ShortcutDispatchProbe()
        let originalNewTarget = item("newDocument:#0")?.target
        let originalOpenTarget = item("openDocument:#0")?.target
        item("newDocument:#0")?.target = dispatchProbe
        item("openDocument:#0")?.target = dispatchProbe
        func keyEvent(_ shifted: Bool) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero,
                             modifierFlags: shifted ? [.command, .shift] : [.command],
                             timestamp: 0, windowNumber: 0, context: nil,
                             characters: shifted ? "K" : "k", charactersIgnoringModifiers: shifted ? "K" : "k",
                             isARepeat: false, keyCode: 40)
        }
        let plainHandled = keyEvent(false).map { menu.performKeyEquivalent(with: $0) } ?? false
        check(plainHandled && dispatchProbe.newCount == 1 && dispatchProbe.openCount == 0,
              "AppKit dispatches assigned Command-K to its own command")
        let shiftedHandled = keyEvent(true).map { menu.performKeyEquivalent(with: $0) } ?? false
        check(shiftedHandled && dispatchProbe.newCount == 1 && dispatchProbe.openCount == 1,
              "AppKit distinguishes assigned Command-Shift-K from Command-K")
        item("newDocument:#0")?.target = originalNewTarget
        item("openDocument:#0")?.target = originalOpenTarget

        // Conflict: ⌘N is Save's… actually New's assigned key now; assigning
        // ⌘K to another command must fail visibly and keep the stored bytes.
        let bytesBeforeConflict = store.storedData
        panel.selectCommand("recoverDocuments:#0")
        panel.keyField.stringValue = "k"
        panel.commandCheck.state = .on
        panel.shiftCheck.state = .off
        panel.assignButton.performClick(nil)
        check(!panel.errorText.isEmpty && panel.errorText.contains("newDocument:#0"),
              "a conflicting assign is a visible error naming both commands (\(panel.errorText))")
        check(store.storedData == bytesBeforeConflict && item("recoverDocuments:#0")?.keyEquivalent == "",
              "a failed assign changes neither the stored bytes nor the menu item")

        // Reserved owners refuse assign/disable through the panel.
        panel.selectCommand("terminate:#0")
        check(!panel.assignButton.isEnabled && !panel.disableButton.isEnabled && !panel.resetSelectedButton.isEnabled,
              "the Quit row is read-only in the panel (no assign, disable or reset)")
        check(item("terminate:#0")?.keyEquivalent == "q"
                && item("terminate:#0")?.keyEquivalentModifierMask == [.command],
              "Quit keeps its factory ⌘Q")

        // Persistence across a new manager on a fresh menu.
        let menu2 = MainMenu.make()
        let manager2 = MenuShortcutManager(store: store, menu: menu2)
        manager2.attach()
        let newItem2 = manager2.collection?.byID["newDocument:#0"]?.first?.item
        check(newItem2?.keyEquivalent == "k" && newItem2?.keyEquivalentModifierMask == [.command],
              "a new manager on the same store reapplies the persisted overrides")

        // Disable and reset selected through the panel.
        panel.selectCommand("saveDocument:#0")
        panel.disableButton.performClick(nil)
        check(item("saveDocument:#0")?.keyEquivalent == ""
                && item("saveDocument:#0")?.keyEquivalentModifierMask == [],
              "Disable clears the actual menu item's key equivalent")
        panel.resetSelectedButton.performClick(nil)
        check(item("saveDocument:#0")?.keyEquivalent == "s"
                && item("saveDocument:#0")?.keyEquivalentModifierMask == [.command],
              "Reset Selected restores the factory snapshot exactly (s + Command)")

        // Reset All through the panel.
        panel.resetAllButton.performClick(nil)
        check(store.storedData == nil, "Reset All removes the stored document")
        check(item("saveAs:#0") == nil && item("saveDocumentAs:#0")?.keyEquivalent == "S"
                && item("saveDocumentAs:#0")?.keyEquivalentModifierMask == [.command],
              "after Reset All the factory items are exact again (Save As… keeps \"S\" + Command)")

        // A corrupt store keeps its bytes and surfaces the load error in
        // the panel; the factory menu is kept, nothing is auto-reset.
        let corrupt = Data("this is not a shortcut document".utf8)
        defaults.set(corrupt, forKey: KeyboardShortcutOverrideStore.overridesKey)
        manager.reload()
        check(manager.loadError != nil, "a corrupt stored document produces a load error")
        check(store.storedData == corrupt, "the corrupt stored bytes are kept, not reset")
        panel.reloadFromManager()
        check(!panel.errorText.isEmpty, "the load error is visible in the panel when it opens")
        check(item("newDocument:#0")?.keyEquivalent == "n"
                && item("newDocument:#0")?.keyEquivalentModifierMask == [.command],
              "after a load error the factory menu is kept (New is ⌘N again)")
        defaults.removeObject(forKey: KeyboardShortcutOverrideStore.overridesKey)
        manager.reload()
        check(manager.loadError == nil, "removing the corrupt bytes clears the load error")

        // The real app-menu action: invoke the Keyboard Shortcuts… item on
        // an AppController target. NEVER Quit/Hide/Minimize — those actions
        // are never sent, and their items must stay factory.
        MenuShortcutManager.shared.attach()
        let appMenu = NSApp.mainMenu?.items.first { $0.title == AppIdentity.name }?.submenu
        let shortcutsItem = appMenu?.items.first { $0.action == #selector(AppController.showKeyboardShortcuts(_:)) }
        check(shortcutsItem != nil, "the app menu retains the Keyboard Shortcuts… action")
        let appController = AppController()
        if let shortcutsItem, let action = shortcutsItem.action {
            NSApp.sendAction(action, to: appController, from: shortcutsItem)
        }
        check(MenuShortcutManager.shared.panel != nil
                && MenuShortcutManager.shared.panel?.numberOfRows(in: MenuShortcutManager.shared.panel!.table) ?? 0 > 0,
              "the app-menu action opens the panel through the shared manager")
        MenuShortcutManager.shared.closePanel()
        check(MenuShortcutManager.shared.panel == nil, "the shared panel closes cleanly")
        for id in ["hide:#0", "terminate:#0", "performMiniaturize:#0"] {
            let record = collection?.byID[id]?.first
            check(record?.item.keyEquivalent == record?.snapshot.keyEquivalent
                    && record?.item.keyEquivalentModifierMask == record?.snapshot.modifierMask,
                  "\(id) still holds its factory key equivalent (never Quit/Hide/Minimize was invoked)")
        }
    }
}

@MainActor
private final class ShortcutDispatchProbe: NSObject {
    private(set) var newCount = 0
    private(set) var openCount = 0
    @objc func newDocument(_ sender: Any?) { newCount += 1 }
    @objc func openDocument(_ sender: Any?) { openCount += 1 }
}
