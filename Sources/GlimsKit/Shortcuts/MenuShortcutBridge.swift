import AppKit

/// The AppKit seam between the pure shortcut model
/// (`KeyboardShortcutModel.swift`) and the real menu bar.
///
/// `MainMenu.make()` marks every item it creates statically with
/// `builtinIdentifier`; the bridge collects exactly those items. Dynamic
/// content — plug-in commands, workspaces, the recent-documents list — is
/// never marked and is excluded. A command's stable id is
/// `NSStringFromSelector(action)` plus the item's final tag, never a
/// localized title.
///
/// Factory snapshots keep each item's original `keyEquivalent` and
/// `modifierMask` in memory only — raw AppKit modifier flags are never
/// serialized — so an unoverridden item is restored exactly ("S" + Command,
/// an unmodified DEL, ...).
///
/// Pure menu-object code: no window, no event capture, no global state.
/// `MainMenu.make()` never calls into the store or this bridge.
@MainActor
enum MenuShortcutBridge {
    /// The mark `MainMenu.item(_:_:_:)` puts on every statically built
    /// command item.
    static let builtinIdentifier = NSUserInterfaceItemIdentifier("ch.lkmc.Glims.builtinMenuCommand")

    /// One collected command. Several items may share an id (aliases) and
    /// are merged into one record group.
    struct Record {
        let item: NSMenuItem
        let id: String
        /// Menu titles from the top-level menu down to the item.
        let path: [String]
        let snapshot: FactorySnapshot
        let base: KeyboardShortcut?
        /// True when the factory base is a macOS reservation (Hide,
        /// Minimize, Quit, ...): the owner keeps it, read-only.
        let reservedOwner: Bool

        var pathLabel: String { path.joined(separator: " ▸ ") }
    }

    /// The factory state of one item, for exact restores.
    struct FactorySnapshot {
        let keyEquivalent: String
        let modifierMask: NSEvent.ModifierFlags
    }

    /// The collected built-in menu commands plus any factory conflicts.
    struct Collection {
        let records: [Record]
        let byID: [String: [Record]]
        /// Nil when a factory conflict makes the catalog unusable; the
        /// conflict is in `errors` and nothing is unbound.
        let catalog: KeyboardShortcutCatalog?
        let errors: [Error]
    }

    /// How one item's key equivalent is written back.
    enum ItemApplication {
        /// Restore the factory snapshot exactly.
        case factory
        /// The command's shortcut is explicitly disabled.
        case disabled
        /// An assigned override.
        case assigned(KeyboardShortcut)
    }

    /// Bridge-local collection errors; the validated model is untouched.
    enum BridgeError: Error, LocalizedError, Equatable {
        /// Aliases (same id) disagree about their factory shortcut.
        case inconsistentFactoryBases(id: String, paths: [String])

        var errorDescription: String? {
            switch self {
            case .inconsistentFactoryBases(let id, let paths):
                return "The menu items \"\(paths.joined(separator: "\", \""))\" share the command \"\(id)\" but disagree about its factory shortcut; both keep their factory keys until the menu is fixed."
            }
        }
    }

    /// The stable id of a command: the selector's name plus the item's
    /// final tag. Never a localized title.
    static func commandID(action: Selector, tag: Int) -> String {
        "\(NSStringFromSelector(action))#\(tag)"
    }

    /// Collects the built-in commands of a statically created menu, in
    /// traversal order, top-level menus first.
    static func collect(from menu: NSMenu) -> Collection {
        var records: [Record] = []
        func walk(_ menu: NSMenu, path: [String]) {
            for item in menu.items {
                if item.isSeparatorItem { continue }
                if let submenu = item.submenu { walk(submenu, path: path + [item.title]) }
                guard let action = item.action,
                      item.identifier == builtinIdentifier,
                      item.tag != PlugInMenus.generatedTag else { continue }
                let snapshot = FactorySnapshot(keyEquivalent: item.keyEquivalent,
                                               modifierMask: item.keyEquivalentModifierMask)
                let base = canonicalBase(keyEquivalent: item.keyEquivalent,
                                         mask: item.keyEquivalentModifierMask)
                records.append(Record(item: item,
                                      id: commandID(action: action, tag: item.tag),
                                      path: path + [item.title],
                                      snapshot: snapshot,
                                      base: base,
                                      reservedOwner: base.map { KeyboardShortcut.reserved.contains($0) } ?? false))
            }
        }
        walk(menu, path: [])

        var byID: [String: [Record]] = [:]
        for record in records { byID[record.id, default: []].append(record) }

        var errors: [Error] = []
        var entries: [CommandShortcutEntry] = []
        var aliasConflict = false
        for id in byID.keys.sorted() {
            let group = byID[id]!
            let bases = Set(group.compactMap(\.base))
            if bases.count > 1 {
                // Inconsistent factory conflict: visible, never silently
                // unbound — both aliases keep their factory keys.
                errors.append(BridgeError.inconsistentFactoryBases(id: id,
                            paths: group.map { $0.path.joined(separator: " ▸ ") }))
                aliasConflict = true
                continue
            }
            if let entry = try? CommandShortcutEntry(id: id, base: group.first?.base) {
                entries.append(entry)
            }
        }
        var catalog: KeyboardShortcutCatalog? = nil
        if !aliasConflict {
            do {
                catalog = try KeyboardShortcutCatalog(entries: entries)
            } catch let error as KeyboardShortcutError {
                errors.append(error)
            } catch {
                errors.append(error)
            }
        }
        return Collection(records: records, byID: byID, catalog: catalog, errors: errors)
    }

    /// The canonical model base of a factory item. An uppercase factory
    /// letter means Shift in AppKit's convention, so the model base adds
    /// Shift and keeps the lower-case letter: Save As… ("S" + Command)
    /// becomes s + Command-Shift and never collides with Save (s + Command).
    /// A key the model cannot represent (an unmodified DEL, 0x7F, ...) has
    /// no model base; the snapshot still restores the item exactly.
    static func canonicalBase(keyEquivalent: String, mask: NSEvent.ModifierFlags) -> KeyboardShortcut? {
        guard !keyEquivalent.isEmpty else { return nil }
        guard let key = ShortcutKey(input: keyEquivalent) else { return nil }
        var modifiers = modifiers(from: mask)
        if keyEquivalent.count == 1, let character = keyEquivalent.first, character.isUppercase {
            modifiers.insert(.shift)
        }
        return KeyboardShortcut(key: key, modifiers: modifiers)
    }

    /// The four classic modifiers of an AppKit mask; device-dependent bits
    /// are dropped and the raw mask is never stored.
    static func modifiers(from mask: NSEvent.ModifierFlags) -> ShortcutModifiers {
        var result: ShortcutModifiers = []
        if mask.contains(.command) { result.insert(.command) }
        if mask.contains(.shift) { result.insert(.shift) }
        if mask.contains(.option) { result.insert(.option) }
        if mask.contains(.control) { result.insert(.control) }
        return result
    }

    /// The AppKit mask for a model modifier set (in memory only).
    static func modifierMask(for modifiers: ShortcutModifiers) -> NSEvent.ModifierFlags {
        var mask: NSEvent.ModifierFlags = []
        if modifiers.contains(.command) { mask.insert(.command) }
        if modifiers.contains(.shift) { mask.insert(.shift) }
        if modifiers.contains(.option) { mask.insert(.option) }
        if modifiers.contains(.control) { mask.insert(.control) }
        return mask
    }

    /// Function tag -> AppKit function-key unicode scalar (reverse of the
    /// model's map), so no AppKit constant is stored.
    static let tagUnicodes: [String: UInt32] = Dictionary(uniqueKeysWithValues:
        ShortcutKey.functionKeyTags.map { ($0.value, $0.key) })

    /// The key equivalent to write for an assigned shortcut: a function
    /// key's unicode scalar, an upper-case letter when Shift is part of the
    /// shortcut (AppKit's convention), otherwise the model key itself.
    static func keyEquivalent(for shortcut: KeyboardShortcut) -> String {
        if let scalar = tagUnicodes[shortcut.key.value] {
            return String(UnicodeScalar(scalar)!)
        }
        if shortcut.modifiers.contains(.shift),
           shortcut.key.value.count == 1,
           let character = shortcut.key.value.first, character.isLetter,
           String(character).uppercased().count == 1 {
            return String(character).uppercased()
        }
        return shortcut.key.value
    }

    /// Writes one application case onto an item. Only the key equivalent
    /// and its modifier mask change — never the action, target or responder
    /// chain.
    static func apply(_ application: ItemApplication, to item: NSMenuItem, snapshot: FactorySnapshot) {
        switch application {
        case .factory:
            item.keyEquivalent = snapshot.keyEquivalent
            item.keyEquivalentModifierMask = snapshot.modifierMask
        case .disabled:
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
        case .assigned(let shortcut):
            item.keyEquivalent = keyEquivalent(for: shortcut)
            item.keyEquivalentModifierMask = modifierMask(for: shortcut.modifiers)
        }
    }
}
