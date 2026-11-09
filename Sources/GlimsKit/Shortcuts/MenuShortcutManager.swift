import AppKit

/// Manager-side errors for commands the catalog or the system reserves.
enum MenuShortcutManagerError: Error, LocalizedError, Equatable {
    /// The manager is not attached to a menu yet.
    case notAttached
    /// The id is not a built-in command of the attached menu.
    case unknownCommand(String)
    /// A macOS-reserved owner (Hide, Minimize, Quit, ...): read-only, no
    /// assign, no disable, no reset — via the UI or stored data.
    case reservedOwner(String)
    /// The collected factory catalog is unusable (a visible conflict).
    case unusableCatalog(String)

    var errorDescription: String? {
        switch self {
        case .notAttached:
            return "The shortcut manager is not attached to the menu bar yet."
        case .unknownCommand(let id):
            return "\"\(id)\" is not a built-in menu command."
        case .reservedOwner(let id):
            return "\"\(id)\" keeps its macOS-reserved system shortcut; it cannot be changed."
        case .unusableCatalog(let detail):
            return "The menu's factory shortcuts are inconsistent: \(detail)"
        }
    }
}

/// Owns the keyboard shortcut customization of the real menu bar: collects
/// the built-in commands once, applies the persisted overrides to the actual
/// `NSMenuItem`s, persists new choices through the validated store and shows
/// the one customization panel.
///
/// AppController attaches the shared manager exactly once, after the real
/// `NSApp.mainMenu` is installed. `MainMenu.make()` never attaches, applies
/// or rewrites anything global; tests inject their own menu and
/// UserDefaults-backed store.
///
/// Every successful mutation validates the FULL catalog and persists FIRST
/// (through `KeyboardShortcutOverrideStore`), and only then updates the
/// actual menu items and the panel. A failed mutation leaves the stored
/// bytes and the menu untouched. Load errors (corrupt or future stored
/// bytes, factory conflicts) keep the factory menu and the stored bytes and
/// are surfaced when the panel opens — never auto-reset, never a startup
/// alert.
@MainActor
final class MenuShortcutManager {
    static let shared = MenuShortcutManager(store: .shared)

    let store: KeyboardShortcutOverrideStore
    /// Injected menu for tests and the smoke test; the app uses
    /// `NSApp.mainMenu`.
    private let fixedMenu: NSMenu?

    private(set) var collection: MenuShortcutBridge.Collection?
    private(set) var overrides: [String: CommandShortcutOverride] = [:]
    private(set) var effective: EffectiveShortcuts?
    /// A load/apply error to surface when the panel opens; the factory menu
    /// and the stored bytes are kept.
    private(set) var loadError: Error?
    private(set) var panel: KeyboardShortcutsPanelController?
    private var attached = false

    init(store: KeyboardShortcutOverrideStore, menu: NSMenu? = nil) {
        self.store = store
        self.fixedMenu = menu
    }

    var isAttached: Bool { attached }

    /// Attaches at most once, and only to an installed menu: the injected
    /// one, else the real `NSApp.mainMenu`. Never called by
    /// `MainMenu.make()`.
    func attach() {
        guard !attached else { return }
        guard let menu = fixedMenu ?? NSApp.mainMenu else { return }
        attached = true
        reload(menu: menu)
    }

    /// Re-collects the menu, re-reads the stored bytes and reapplies. Any
    /// error keeps the factory items and the stored bytes and is recorded
    /// in `loadError`.
    func reload() {
        guard attached, let menu = fixedMenu ?? NSApp.mainMenu else { return }
        reload(menu: menu)
    }

    private func reload(menu: NSMenu) {
        collection = MenuShortcutBridge.collect(from: menu)
        loadError = nil
        overrides = [:]
        effective = nil
        if let errors = collection?.errors, !errors.isEmpty {
            loadError = errors.first
            restoreFactory()
            return
        }
        do {
            overrides = try store.load()
            applyOverrides()
        } catch {
            loadError = error
            restoreFactory()
        }
        panel?.reloadFromManager()
    }

    /// Applies the current overrides to the actual menu items. Reserved
    /// system owners always keep their factory shortcut — no override from
    /// stored data is ever applied to them.
    private func applyOverrides() {
        guard let collection, let catalog = collection.catalog else { return }
        do {
            effective = try catalog.effectiveShortcuts(overrides: overrides)
        } catch {
            loadError = error
            restoreFactory()
            return
        }
        loadError = nil
        for record in collection.records {
            guard !record.reservedOwner else {
                MenuShortcutBridge.apply(.factory, to: record.item, snapshot: record.snapshot)
                continue
            }
            switch overrides[record.id] {
            case .none:
                MenuShortcutBridge.apply(.factory, to: record.item, snapshot: record.snapshot)
            case .some(.disable):
                MenuShortcutBridge.apply(.disabled, to: record.item, snapshot: record.snapshot)
            case .some(.assign(let shortcut)):
                MenuShortcutBridge.apply(.assigned(shortcut), to: record.item, snapshot: record.snapshot)
            }
        }
    }

    private func restoreFactory() {
        guard let collection else { return }
        for record in collection.records {
            MenuShortcutBridge.apply(.factory, to: record.item, snapshot: record.snapshot)
        }
    }

    // MARK: - Rows for the panel

    /// One display row: the command, its menu path, its effective shortcut
    /// and its override state.
    struct Row: Equatable {
        let id: String
        let pathLabel: String
        let shortcut: KeyboardShortcut?
        let override: CommandShortcutOverride?
        let reservedOwner: Bool
        let base: KeyboardShortcut?
    }

    var rows: [Row] {
        guard let collection else { return [] }
        return collection.byID.keys.sorted().map { id in
            let group = collection.byID[id]!
            let record = group[0]
            return Row(id: id,
                       pathLabel: record.pathLabel,
                       shortcut: effective?.shortcut(forCommand: id),
                       override: overrides[id],
                       reservedOwner: record.reservedOwner,
                       base: record.base)
        }
    }

    // MARK: - Mutations (validate + persist first, then menu and panel)

    private func editableCatalog(for command: String) throws -> (MenuShortcutBridge.Collection, KeyboardShortcutCatalog) {
        guard attached, let collection = collection else { throw MenuShortcutManagerError.notAttached }
        guard let catalog = collection.catalog else {
            throw MenuShortcutManagerError.unusableCatalog(collection.errors.first?.localizedDescription ?? "unknown conflict")
        }
        guard let group = collection.byID[command] else {
            throw MenuShortcutManagerError.unknownCommand(command)
        }
        guard !group.contains(where: \.reservedOwner) else {
            throw MenuShortcutManagerError.reservedOwner(command)
        }
        return (collection, catalog)
    }

    /// Assigns `shortcut` to `command`: the store validates the full
    /// prospective catalog and persists before anything on screen changes.
    func assign(_ shortcut: KeyboardShortcut, to command: String) throws {
        let (_, catalog) = try editableCatalog(for: command)
        try store.assign(shortcut, to: command, catalog: catalog)
        refreshAfterMutation()
    }

    func disable(_ command: String) throws {
        let (_, catalog) = try editableCatalog(for: command)
        try store.disable(command, catalog: catalog)
        refreshAfterMutation()
    }

    func reset(_ command: String) throws {
        let (_, catalog) = try editableCatalog(for: command)
        try store.reset(command, catalog: catalog)
        refreshAfterMutation()
    }

    func resetAll() throws {
        guard attached, let collection = collection, let catalog = collection.catalog else {
            throw MenuShortcutManagerError.notAttached
        }
        try store.resetAll(catalog: catalog)
        refreshAfterMutation()
    }

    /// Re-reads the persisted bytes and only then updates the actual menu
    /// items, the effective map and the panel.
    private func refreshAfterMutation() {
        do {
            overrides = try store.load()
            applyOverrides()
        } catch {
            loadError = error
            restoreFactory()
        }
        panel?.reloadFromManager()
    }

    // MARK: - Panel (one at a time)

    /// The one panel, created on first use; repeated calls return the same
    /// controller, so two simultaneous panels never exist.
    func ensurePanel() -> KeyboardShortcutsPanelController {
        if panel == nil {
            panel = KeyboardShortcutsPanelController(manager: self)
            panel?.onClose = { [weak self] in self?.panel = nil }
        }
        return panel!
    }

    var panelCount: Int { panel == nil ? 0 : 1 }

    func showPanel() {
        let controller = ensurePanel()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        panel?.window?.close()
        panel = nil
    }
}
