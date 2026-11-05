import Foundation

/// The Glims menus that receive plug-in commands (docs/design.md, section 4).
enum GlimsMenu: String, CaseIterable {
    case file = "File"
    case edit = "Edit"
    case image = "Image"
    case layer = "Layer"
    case select = "Select"
    case filter = "Filter"
    case view = "View"
}

/// Where one engine menu path goes in Glims's menus.
///
/// Engine paths look like "<Image>/Filters/Light and Shadow/[Shadow]": the
/// root, the engine's top-level menu, submenus, and bracketed placeholders
/// that name a section inside a menu rather than a submenu.
struct PlugInMenuPlacement: Equatable {
    let menu: GlimsMenu
    let submenus: [String]
    /// The section inside the innermost submenu, or nil for its main part.
    let section: String?
}

extension PlugInMenuPlacement {
    /// Engine top-level menus and where Glims shows them. GIMP's Colors menu
    /// is Image > Adjust; menus Glims lacks go to Filter > Other.
    private static let topLevels: [String: (GlimsMenu, [String])] = [
        "Filters": (.filter, []),
        "Colors": (.image, ["Adjust"]),
        "Image": (.image, []),
        "Layer": (.layer, []),
        "Select": (.select, []),
        "File": (.file, []),
        "Edit": (.edit, []),
        "View": (.view, []),
    ]

    /// Returns nil for paths outside the image window's menus (for example
    /// the engine's layer or brush context menus).
    init?(menuPath: String) {
        var components = menuPath.split(separator: "/").map(String.init)
        guard components.first == "<Image>", components.count >= 2 else { return nil }
        components.removeFirst()

        let topLevel = components.removeFirst()
        let (menu, prefix) = Self.topLevels[topLevel] ?? (.filter, ["Other", Self.title(topLevel)])
        let isSection = { (component: String) in component.hasPrefix("[") && component.hasSuffix("]") }

        self.menu = menu
        self.submenus = prefix + components.filter { !isSection($0) }.map(Self.title)
        self.section = components.last(where: isSection).map { String($0.dropFirst().dropLast()) }
    }

    /// Engine submenu names may carry mnemonics ("_Render").
    private static func title(_ component: String) -> String {
        component.replacingOccurrences(of: "__", with: "\u{0}")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: "\u{0}", with: "_")
    }
}

/// A menu's plug-in commands as a tree, ready to become `NSMenu`s.
struct PlugInMenuNode: Equatable {
    struct Entry: Equatable {
        let procedure: EngineSession.Procedure
    }

    var submenus: [String: PlugInMenuNode] = [:]
    /// Commands by section; the nil section is the menu's main part.
    var sections: [String?: [Entry]] = [:]

    var isEmpty: Bool { submenus.isEmpty && sections.isEmpty }

    /// Submenus first, then the main part's commands, then each named section
    /// after a separator; everything sorted by title, as a reader scans.
    var orderedSubmenus: [(title: String, node: PlugInMenuNode)] {
        submenus.keys.sorted(by: Self.titleOrder).map { ($0, submenus[$0]!) }
    }

    var orderedSections: [(name: String?, entries: [Entry])] {
        let named = sections.keys.compactMap { $0 }.sorted(by: Self.titleOrder)
        let order: [String?] = (sections[nil] == nil ? [] : [nil]) + named.map { Optional($0) }
        return order.map { name in
            (name, sections[name]!.sorted { Self.titleOrder($0.procedure.label, $1.procedure.label) })
        }
    }

    mutating func insert(_ procedure: EngineSession.Procedure, at placement: PlugInMenuPlacement) {
        insert(Entry(procedure: procedure), path: placement.submenus[...], section: placement.section)
    }

    private mutating func insert(_ entry: Entry, path: ArraySlice<String>, section: String?) {
        guard let head = path.first else {
            sections[section, default: []].append(entry)
            return
        }
        submenus[head, default: PlugInMenuNode()].insert(entry, path: path.dropFirst(), section: section)
    }

    private static func titleOrder(_ a: String, _ b: String) -> Bool {
        a.localizedStandardCompare(b) == .orderedAscending
    }

    /// Groups procedures by the Glims menu they belong in.
    static func layout(_ procedures: [EngineSession.Procedure]) -> [GlimsMenu: PlugInMenuNode] {
        var menus: [GlimsMenu: PlugInMenuNode] = [:]
        for procedure in procedures {
            guard let placement = PlugInMenuPlacement(menuPath: procedure.menuPath) else { continue }
            menus[placement.menu, default: PlugInMenuNode()].insert(procedure, at: placement)
        }
        return menus
    }
}
