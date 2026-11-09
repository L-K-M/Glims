import AppKit

/// App-wide state of plug-in commands: the one that is running (the engine
/// runs one at a time) and the recently used ones for the Filter menu.
@MainActor
enum PlugInCommands {
    static let maximumRecent = 8
    static let didFinishNotification = Notification.Name("ch.lkmc.Glims.plugInDidFinish")

    /// The running command and the document it works on.
    private(set) static var running: (procedure: EngineSession.Procedure, document: ImageDocument)?
    /// Most recent first. Only image commands count, as in GIMP's history.
    private(set) static var recent: [EngineSession.Procedure] = []

    static var isRunning: Bool { running != nil }
    static var last: EngineSession.Procedure? { recent.first }

    static func willRun(_ procedure: EngineSession.Procedure, on document: ImageDocument) {
        running = (procedure, document)
    }

    static func didRun(_ procedure: EngineSession.Procedure, outcome: EngineSession.RunOutcome?) {
        running = nil
        // Defer queued Finder opens until the command completion updates its UI.
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: didFinishNotification, object: nil)
        }
        guard outcome == .completed else { return }
        recent.removeAll { $0.name == procedure.name }
        recent.insert(procedure, at: 0)
        recent = Array(recent.prefix(maximumRecent))
        PlugInMenus.updateRecent()
    }
}

/// Builds the plug-in parts of the menu bar from the engine's commands.
///
/// Each command item carries its procedure and sends
/// `DocumentWindowController.runPlugIn(_:)` through the responder chain,
/// which also validates it against the front document.
@MainActor
enum PlugInMenus {
    /// Marks generated items so a rebuild can replace them. The catalog's
    /// native merge reads it to tell plug-in content from dedicated items.
    static let generatedTag = 0x6C_6D_73

    /// Installs the commands into the menus named by `GlimsMenu`.
    static func install(_ procedures: [EngineSession.Procedure], in mainMenu: NSMenu) {
        let layout = PlugInMenuNode.layout(procedures)
        for glimsMenu in GlimsMenu.allCases {
            guard let menu = mainMenu.item(withTitle: glimsMenu.rawValue)?.submenu else { continue }
            removeGenerated(from: menu)
            guard let node = layout[glimsMenu], !node.isEmpty else { continue }

            if glimsMenu == .filter {
                // Categories merge with the native filters already in the
                // menu (for example Blur > Gaussian Blur…).
                merge(node, into: menu)
            } else {
                // A category already in the menu (the static Image ▸ Adjust)
                // absorbs its plug-in content, so only entries landing at the
                // menu's own top level need the dividing separator.
                let landsAtTopLevel = !node.sections.isEmpty
                    || node.orderedSubmenus.contains { menu.item(withTitle: $0.title)?.submenu == nil }
                if landsAtTopLevel && !menu.items.isEmpty && menu.items.last?.isSeparatorItem != true {
                    menu.addItem(tagged(.separator()))
                }
                append(node, to: menu)
            }
        }
    }

    /// Rebuilds the Filter menu's Recently Used submenu.
    static func updateRecent() {
        guard let menu = NSApp.mainMenu?.item(withTitle: GlimsMenu.filter.rawValue)?.submenu?
            .item(withTitle: MainMenu.recentlyUsedTitle)?.submenu else { return }
        menu.removeAllItems()
        for procedure in PlugInCommands.recent {
            menu.addItem(commandItem(procedure))
        }
    }

    // MARK: Building

    /// Drops this producer's generated items throughout the menu tree,
    /// including inside shared submenus such as the static Image ▸ Adjust.
    /// A generated submenu item drops only once nothing but generated
    /// content filled it, so a category the native merge shares survives.
    private static func removeGenerated(from menu: NSMenu) {
        for item in menu.items {
            guard let submenu = item.submenu else {
                if item.tag == generatedTag { menu.removeItem(item) }
                continue
            }
            removeGenerated(from: submenu)
            if item.tag == generatedTag && submenu.items.isEmpty { menu.removeItem(item) }
        }
        removeStrandedSeparators(from: menu)
    }

    private static func removeStrandedSeparators(from menu: NSMenu) {
        while menu.items.first?.isSeparatorItem == true { menu.removeItem(at: 0) }
        while menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.numberOfItems - 1) }
        var previousWasSeparator = false
        for item in menu.items {
            if item.isSeparatorItem && previousWasSeparator { menu.removeItem(item) }
            previousWasSeparator = item.isSeparatorItem
        }
    }

    private static func append(_ node: PlugInMenuNode, to menu: NSMenu) {
        for (title, child) in node.orderedSubmenus {
            if let submenu = menu.item(withTitle: title)?.submenu {
                // Shared categories retain their identity even when this
                // producer originally created the parent item.
                merge(child, into: submenu)
            } else {
                menu.addItem(tagged(submenuItem(title, child)))
            }
        }
        for (index, section) in node.orderedSections.enumerated() {
            if (index > 0 || !node.submenus.isEmpty) && menu.items.last?.isSeparatorItem != true {
                menu.addItem(tagged(.separator()))
            }
            section.entries.forEach { menu.addItem(tagged(commandItem($0.procedure))) }
        }
        removeStrandedSeparators(from: menu)
    }

    /// Adds categories to an existing menu, reusing submenus it already has.
    private static func merge(_ node: PlugInMenuNode, into menu: NSMenu) {
        for (title, child) in node.orderedSubmenus {
            if let existing = menu.item(withTitle: title)?.submenu {
                // install already recursively removed this producer's
                // leaves; retained categories contain somebody else's items.
                // A trailing separator the native merge left behind
                // already divides its entries from the plug-in block.
                if !existing.items.isEmpty && existing.items.last?.isSeparatorItem != true {
                    existing.addItem(tagged(.separator()))
                }
                append(child, to: existing)
            } else {
                // Keep categories alphabetical among the native ones.
                let categories = menu.items.indices.filter { menu.items[$0].submenu != nil }
                let next = categories.first { index in
                    menu.items[index].title.localizedStandardCompare(title) == .orderedDescending
                        && menu.items[index].title != MainMenu.recentlyUsedTitle
                }
                let item = tagged(submenuItem(title, child))
                if let next { menu.insertItem(item, at: next) } else { menu.addItem(item) }
            }
        }
        let topLevel = PlugInMenuNode(submenus: [:], sections: node.sections)
        if !topLevel.isEmpty {
            // A separator the other producer left behind already divides
            // the blocks; an empty menu gets none at its leading edge.
            if !menu.items.isEmpty && menu.items.last?.isSeparatorItem != true {
                menu.addItem(tagged(.separator()))
            }
            append(topLevel, to: menu)
        }
        removeStrandedSeparators(from: menu)
    }

    private static func submenuItem(_ title: String, _ node: PlugInMenuNode) -> NSMenuItem {
        let submenu = NSMenu(title: title)
        append(node, to: submenu)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    static func commandItem(_ procedure: EngineSession.Procedure) -> NSMenuItem {
        let item = NSMenuItem(title: procedure.label,
                              action: #selector(DocumentWindowController.runPlugIn(_:)),
                              keyEquivalent: "")
        item.representedObject = PlugInCommand(procedure)
        item.toolTip = procedure.blurb.isEmpty ? nil : procedure.blurb
        return item
    }

    private static func tagged(_ item: NSMenuItem) -> NSMenuItem {
        item.tag = generatedTag
        return item
    }
}

/// A menu item's procedure; `NSMenuItem.representedObject` needs an object.
final class PlugInCommand: NSObject {
    let procedure: EngineSession.Procedure

    init(_ procedure: EngineSession.Procedure) {
        self.procedure = procedure
    }
}
