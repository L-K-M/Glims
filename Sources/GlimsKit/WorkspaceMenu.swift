import AppKit
import RigiUI

/// Window ▸ Workspaces: the saved palette arrangements by name, Save
/// Workspace… and Delete Workspace, as Rigi's guidelines describe. The
/// submenu is rebuilt from the saved names each time it opens.
@MainActor
final class WorkspaceMenu: NSObject, NSMenuDelegate {
    static let shared = WorkspaceMenu()

    /// Where workspaces are kept; tests substitute their own.
    var store: WorkspaceStore = PaletteCenter.shared

    func makeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Workspaces")
        menu.delegate = self
        item.submenu = menu
        rebuild(menu)
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    /// The saved names (choosing one applies it), then Save Workspace… and
    /// a Delete Workspace submenu of the same names.
    func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        let names = store.workspaceNames
        for name in names {
            let item = NSMenuItem(title: name, action: #selector(apply(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        if !names.isEmpty { menu.addItem(.separator()) }

        let save = NSMenuItem(title: "Save Workspace…", action: #selector(save(_:)), keyEquivalent: "")
        save.target = self
        menu.addItem(save)

        let delete = NSMenuItem(title: "Delete Workspace", action: nil, keyEquivalent: "")
        let deleteMenu = NSMenu(title: "Delete Workspace")
        for name in names {
            let item = NSMenuItem(title: name, action: #selector(delete(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            deleteMenu.addItem(item)
        }
        delete.submenu = deleteMenu
        delete.isEnabled = !names.isEmpty
        menu.addItem(delete)
    }

    @objc private func apply(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        if !store.applyWorkspace(named: name) {
            NSSound.beep()
        }
    }

    @objc private func delete(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        store.deleteWorkspace(named: name)
    }

    @objc private func save(_ sender: Any?) {
        guard let name = askName() else { return }
        store.saveWorkspace(named: name)
    }

    /// The name for Save Workspace…; asks before replacing a saved one.
    private func askName() -> String? {
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Name the current arrangement of palettes."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        field.placeholderString = "Workspace name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }

        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        guard store.workspaceNames.contains(name) else { return name }

        let replace = NSAlert()
        replace.messageText = "Replace the workspace “\(name)”?"
        replace.informativeText = "It will keep the current arrangement instead of its own."
        replace.addButton(withTitle: "Replace")
        replace.addButton(withTitle: "Cancel")
        return replace.runModal() == .alertFirstButtonReturn ? name : nil
    }
}

/// The workspace calls the menu needs, which PaletteCenter provides.
@MainActor
protocol WorkspaceStore: AnyObject {
    var workspaceNames: [String] { get }
    func saveWorkspace(named name: String)
    func applyWorkspace(named name: String) -> Bool
    func deleteWorkspace(named name: String)
}

extension PaletteCenter: WorkspaceStore {}
