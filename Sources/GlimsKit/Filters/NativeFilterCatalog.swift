import AppKit

/// The engine's filter-operation catalog, loaded once per engine start.
///
/// Listing operations and their properties instantiates engine nodes, so
/// the catalog queries on a background queue and reports on the main
/// actor; the Filter menu's entries install only when the answers land.
@MainActor
final class NativeFilterCatalog {
    static let shared = NativeFilterCatalog()

    /// The engine's operations in catalog order; empty until `load` lands.
    private(set) var operations: [EngineSession.FilterOperation] = []

    /// The catalog's operation with `name` — what a committed effect's
    /// `operation` string resolves to; nil until `load` lands or for an
    /// operation the engine does not list.
    func operation(named name: String) -> EngineSession.FilterOperation? {
        operations.first { $0.name == name }
    }

    /// Installs a freshly fetched operation list into the same cache
    /// `load` fills at engine start. The adjustment-creation sheet's
    /// counted read uses this, so `operation(named:)` — and through it
    /// `editEffectParameters` — resolves exactly the operation the sheet
    /// offered. Menus are untouched: only `load` rebuilds them.
    func install(_ operations: [EngineSession.FilterOperation]) {
        self.operations = operations
    }

    /// Properties already fetched, by operation name; enum choices included.
    private var properties: [String: [EngineSession.FilterProperty]] = [:]
    /// Fetch completions waiting on the same operation's properties.
    private var fetching: [String: [@MainActor ([EngineSession.FilterProperty]?) -> Void]] = [:]
    private nonisolated let queue = DispatchQueue(label: "ch.lkmc.Glims.filter-catalog", qos: .userInitiated)

    /// Queries the operation list off the main thread, then installs the
    /// Native submenu — AppKit menus change on the main actor only.
    func load(using session: EngineSession) {
        queue.async { [session] in
            let operations = (try? session.filterOperations()) ?? []
            DispatchQueue.main.async {
                self.operations = operations
                guard let mainMenu = NSApp.mainMenu else { return }
                NativeFilterMenus.install(operations, in: mainMenu)
            }
        }
    }

    /// One operation's editable properties with enum choices filled in,
    /// fetched off the main queue and cached by operation name; `nil` is
    /// reported when the engine cannot describe the operation.
    func properties(for operation: EngineSession.FilterOperation, using session: EngineSession,
                    completion: @escaping @MainActor ([EngineSession.FilterProperty]?) -> Void) {
        if let cached = properties[operation.name] { return completion(cached) }
        fetching[operation.name, default: []].append(completion)
        queue.async { [session, name = operation.name] in
            let fetched: [EngineSession.FilterProperty]? = {
                guard var rows = try? session.filterOperationProperties(name) else { return nil }
                for index in rows.indices where rows[index].kind == .enumeration {
                    rows[index].choices = (try? session.filterEnumChoices(name, property: rows[index].name)) ?? []
                }
                return rows
            }()
            DispatchQueue.main.async {
                if let fetched { self.properties[name] = fetched }
                for reply in self.fetching.removeValue(forKey: name) ?? [] { reply(fetched) }
            }
        }
    }
}

/// A Native menu item's operation; `NSMenuItem.representedObject` needs
/// an object.
final class NativeFilterCommand: NSObject {
    let operation: EngineSession.FilterOperation

    init(_ operation: EngineSession.FilterOperation) {
        self.operation = operation
    }
}

/// The catalog-to-menu grouping: which Filter category an operation
/// lands in, and how unavailable operations present.
///
/// The engine's categories are ':'-separated keys ("distort:map"); the
/// first key with a GIMP Filters menu name picks the category, the rest
/// land in "Other".
struct NativeFilterMenuLayout: Equatable {
    static func usesBrightnessContrastEditor(_ operation: EngineSession.FilterOperation) -> Bool {
        operation.name == "gimp:brightness-contrast" && operation.support == .needsConfig
    }

    static func usesCurvesEditor(_ operation: EngineSession.FilterOperation) -> Bool {
        operation.name == "gimp:curves" && operation.support == .needsConfig
    }

    static func usesLevelsEditor(_ operation: EngineSession.FilterOperation) -> Bool {
        operation.name == "gimp:levels" && operation.support == .needsConfig
    }

    static func usesHueSaturationEditor(_ operation: EngineSession.FilterOperation) -> Bool {
        operation.name == "gimp:hue-saturation" && operation.support == .needsConfig
    }

    static func usesColorBalanceEditor(_ operation: EngineSession.FilterOperation) -> Bool {
        operation.name == "gimp:color-balance" && operation.support == .needsConfig
    }

    static func supportsParameterEditor(_ operation: EngineSession.FilterOperation?) -> Bool {
        guard let operation else { return false }
        return operation.support == .supported || usesBrightnessContrastEditor(operation) || usesColorBalanceEditor(operation) || usesHueSaturationEditor(operation) || usesLevelsEditor(operation) || usesCurvesEditor(operation)
    }

    struct Section: Equatable {
        let title: String
        let entries: [EngineSession.FilterOperation]
    }

    /// Submenu titles in display order; "Other" always last.
    let sections: [Section]

    init(operations: [EngineSession.FilterOperation]) {
        // Gaussian Blur has its own command and panel; the catalog's row
        // would be a second, generic version of it.
        var buckets: [String: [EngineSession.FilterOperation]] = [:]
        for operation in operations where operation.name != GaussianBlurPanel.operation {
            buckets[Self.submenuTitle(for: operation.categories) ?? "Other", default: []].append(operation)
        }
        let ordered = buckets.keys.sorted { $0 != "Other" && ($1 == "Other" || $0 < $1) }
        sections = ordered.map { title in
            Section(title: title, entries: (buckets[title] ?? []).sorted { $0.title < $1.title })
        }
    }

    /// GEGL category keys mapped to GIMP's Filters menu names.
    static let submenuTitles: [String: String] = [
        "artistic": "Artistic",
        "blur": "Blur",
        "color": "Color",
        "distort": "Distort",
        "edge": "Edge",
        "enhance": "Enhance",
        "generic": "Generic",
        "light": "Light and Shadow",
        "map": "Map",
        "noise": "Noise",
        "render": "Render",
        "tonemapping": "Color",
        "transform": "Transform",
    ]

    static func submenuTitle(for categories: [String]) -> String? {
        categories.lazy.compactMap { submenuTitles[$0] }.first
    }

    /// Why an unavailable operation cannot run, for its disabled item's
    /// title and tooltip — it stays listed so the catalog is honest about
    /// what the engine has.
    static func unavailableReason(_ support: EngineSession.FilterOpSupport) -> String? {
        switch support {
        case .needsAuxInput: return "needs a second layer as its source"
        case .needsConfig: return "needs a dedicated editor"
        case .supported: return nil
        }
    }

    /// The item's menu title: `Title…` when it opens a form, `Title
    /// (reason)` when it cannot run yet.
    static func itemTitle(_ operation: EngineSession.FilterOperation) -> String {
        if usesBrightnessContrastEditor(operation) || usesColorBalanceEditor(operation) || usesHueSaturationEditor(operation) || usesLevelsEditor(operation) || usesCurvesEditor(operation) { return "\(operation.title)…" }
        if usesSourceChooser(operation) { return "\(operation.title)…" }
        if let reason = unavailableReason(operation.support) {
            return "\(operation.title) (\(reason))"
        }
        return "\(operation.title)…"
    }

    static func usesSourceChooser(_ operation: EngineSession.FilterOperation) -> Bool {
        operation.name == "gegl:bump-map" && operation.support == .needsAuxInput
    }
}

/// Merges the catalog's operations into the Filter menu's categories.
///
/// The catalog has no menu of its own (docs/design.md): every section
/// lands in the existing Filter category of the same name, ahead of the
/// plug-in merge's generated content, or in a new category item placed
/// alphabetically. Items carry a `NativeFilterCommand` and send
/// `DocumentWindowController.runNativeFilter(_:)` through the responder
/// chain, which validates them against the front document. Operations
/// the form cannot drive stay listed but disabled — a future slice will
/// own them, and the reason is part of their title.
@MainActor
enum NativeFilterMenus {
    /// Marks generated items so a rebuild can replace them — its own tag,
    /// so a plug-in refresh removes only plug-in items and vice versa.
    private static let generatedTag = 0x6C_6D_74

    /// Image ▸ Adjust's dedicated native entries: scalar operations the
    /// shared preview drives, by engine operation name with the menu title
    /// each gets. Operations the engine does not list are simply omitted,
    /// and the support gates stay — a gated operation never appears here.
    private static let adjustOperations: [(name: String, title: String)] = [
        ("gimp:brightness-contrast", "Brightness/Contrast"),
        ("gimp:color-balance", "Color Balance"),
        ("gimp:hue-saturation", "Hue/Saturation"),
        ("gimp:levels", "Levels"),
        ("gimp:curves", "Curves"),
        ("gimp:threshold", "Threshold"),
        ("gegl:invert-gamma", "Invert Perceptual"),
        ("gegl:invert-linear", "Invert Linear"),
    ]

    /// Installs or refreshes the catalog's sections inside the Filter
    /// menu's categories and its dedicated entries inside Image ▸ Adjust.
    /// Each menu is handled independently, so one missing menu never
    /// blocks the other. Dedicated commands, Recently Used and the
    /// plug-in merge's items are left alone; a category the catalog
    /// created goes away once nothing but generated items filled it.
    static func install(_ operations: [EngineSession.FilterOperation], in mainMenu: NSMenu) {
        if let filterMenu = mainMenu.item(withTitle: GlimsMenu.filter.rawValue)?.submenu {
            installFilter(operations, in: filterMenu)
        }
        if let imageMenu = mainMenu.item(withTitle: GlimsMenu.image.rawValue)?.submenu {
            installAdjust(operations, in: imageMenu)
        }
    }

    private static func installFilter(_ operations: [EngineSession.FilterOperation], in menu: NSMenu) {
        for item in menu.items where item.submenu != nil {
            removeGenerated(from: item.submenu!)
            if item.submenu!.items.isEmpty && item.tag == generatedTag { menu.removeItem(item) }
        }
        // Strays without a submenu, if any, are safe to drop wholesale.
        menu.items.filter { $0.tag == generatedTag && $0.submenu == nil }.forEach(menu.removeItem)

        for section in NativeFilterMenuLayout(operations: operations).sections {
            let submenu: NSMenu
            if let existing = menu.item(withTitle: section.title)?.submenu {
                submenu = existing
            } else {
                let parent = tagged(NSMenuItem(title: section.title, action: nil, keyEquivalent: ""))
                parent.submenu = NSMenu(title: section.title)
                submenu = parent.submenu!
                // Keep categories alphabetical among the submenu items,
                // like the plug-in merge does; Recently Used stands aside.
                let categories = menu.items.indices.filter { menu.items[$0].submenu != nil }
                let next = categories.first {
                    menu.items[$0].title.localizedStandardCompare(section.title) == .orderedDescending
                        && menu.items[$0].title != MainMenu.recentlyUsedTitle
                }
                if let next { menu.insertItem(parent, at: next) } else { menu.addItem(parent) }
            }
            merge(section.entries.map { tagged(commandItem($0)) }, into: submenu)
        }
    }

    /// Merges the catalog's dedicated adjustment entries into the static
    /// Image ▸ Adjust submenu, ahead of any plug-in content there.
    private static func installAdjust(_ operations: [EngineSession.FilterOperation], in imageMenu: NSMenu) {
        guard let adjust = imageMenu.item(withTitle: MainMenu.adjustTitle)?.submenu else { return }
        removeGenerated(from: adjust)
        let items = adjustOperations.compactMap { entry -> NSMenuItem? in
            guard let operation = operations.first(where: { $0.name == entry.name }),
                  NativeFilterMenuLayout.supportsParameterEditor(operation) else { return nil }
            return tagged(commandItem(operation, title: "\(entry.title)…"))
        }
        merge(items, into: adjust)
    }

    /// Drops generated items from a category and the separators that
    /// stranded at an edge or doubled up where they stood.
    private static func removeGenerated(from submenu: NSMenu) {
        submenu.items.filter { $0.tag == generatedTag }.forEach(submenu.removeItem)
        while submenu.items.first?.isSeparatorItem == true { submenu.removeItem(submenu.items[0]) }
        while submenu.items.last?.isSeparatorItem == true {
            submenu.removeItem(at: submenu.numberOfItems - 1)
        }
        var previousWasSeparator = false
        for item in submenu.items {
            if item.isSeparatorItem && previousWasSeparator { submenu.removeItem(item) }
            previousWasSeparator = item.isSeparatorItem
        }
    }

    /// The native items join a category ahead of its plug-in content —
    /// generated items and plug-in submenus — with one separator between
    /// the two groups; dedicated commands (untagged) stay ahead of both.
    private static func merge(_ items: [NSMenuItem], into submenu: NSMenu) {
        guard !items.isEmpty else { return }
        guard let boundary = submenu.items.firstIndex(where: {
            $0.tag == PlugInMenus.generatedTag || $0.submenu != nil
        }) else {
            items.forEach(submenu.addItem)
            return
        }
        for (offset, item) in items.enumerated() {
            submenu.insertItem(item, at: boundary + offset)
        }
        if !submenu.items[boundary + items.count].isSeparatorItem {
            submenu.insertItem(tagged(.separator()), at: boundary + items.count)
        }
    }

    private static func commandItem(_ operation: EngineSession.FilterOperation,
                                    title: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title ?? NativeFilterMenuLayout.itemTitle(operation),
                              action: #selector(DocumentWindowController.runNativeFilter(_:)),
                              keyEquivalent: "")
        item.representedObject = NativeFilterCommand(operation)
        if !NativeFilterMenuLayout.supportsParameterEditor(operation),
           !NativeFilterMenuLayout.usesSourceChooser(operation),
           let reason = NativeFilterMenuLayout.unavailableReason(operation.support) {
            item.toolTip = "\(operation.title) \(reason) — not supported yet."
        } else {
            item.toolTip = operation.blurb.isEmpty ? nil : operation.blurb
        }
        return item
    }

    private static func tagged(_ item: NSMenuItem) -> NSMenuItem {
        item.tag = generatedTag
        return item
    }
}
