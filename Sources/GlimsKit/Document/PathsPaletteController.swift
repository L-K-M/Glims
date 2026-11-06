import AppKit
import RigiUI

/// The Paths palette: the front document's paths, top first. Selecting a
/// row makes that path the one the Path tool edits; the checkbox shows or
/// hides it on the canvas; double-clicking the name renames it. The button
/// bar and the title bar menu add an empty path, make the selected one's
/// area the selection, draw it on the active layer in the foreground color
/// at the Path tool's stroke width, and delete it.
@MainActor
final class PathsPaletteController: NSViewController, PaletteContent, NSTableViewDataSource,
                                     NSTableViewDelegate, NSTextFieldDelegate, NSMenuItemValidation {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.paths"),
        title: "Paths",
        contentSize: NSSize(width: 240, height: 300),
        sizing: .resizable(minimumContentSize: NSSize(width: 200, height: 140)),
        frameAutosaveName: "Glims.palette.paths")

    /// The palette's commands.
    enum Command: Int, CaseIterable {
        case new, delete, toSelection, stroke

        /// SF Symbols names, first available wins.
        var symbolNames: [String] {
            switch self {
            case .new: return ["plus"]
            case .delete: return ["trash"]
            case .toSelection: return ["rectangle.dashed", "lasso"]
            case .stroke: return ["scribble", "pencil"]
            }
        }

        /// The command's name in the palette's menu, as its button's tool
        /// tip and to VoiceOver.
        var menuTitle: String {
            switch self {
            case .new: return "New Path"
            case .delete: return "Delete Path"
            case .toSelection: return "Path to Selection"
            case .stroke: return "Stroke Path"
            }
        }
    }

    private weak var document: ImageDocument?
    private let table = NSTableView()
    private lazy var buttonBar = ClassicPaletteButtonBar(
        items: [Command.new, .toSelection, .stroke].map(barItem),
        trailingItems: [barItem(.delete)])
    private var reloading = false

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("path"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Paths")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let stack = NSStackView(views: [scroll, buttonBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        view = stack
    }

    private func barItem(_ command: Command) -> ClassicPaletteButtonBar.Item {
        let image = command.symbolNames.lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: command.menuTitle) }
            .first ?? NSImage()
        image.isTemplate = true
        return ClassicPaletteButtonBar.Item(id: "\(command)", title: command.menuTitle, image: image) { [weak self] in
            self?.run(command)
        }
    }

    /// The title bar triangle's menu: the same commands as the buttons.
    var paletteMenu: NSMenu? {
        let menu = NSMenu(title: "Paths")
        for command in Command.allCases {
            if command == .toSelection { menu.addItem(.separator()) }
            let item = NSMenuItem(title: command.menuTitle, action: #selector(runMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.tag = command.rawValue
            menu.addItem(item)
        }
        return menu
    }

    @objc private func runMenuCommand(_ sender: NSMenuItem) {
        guard let command = Command(rawValue: sender.tag) else { return }
        run(command)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(runMenuCommand(_:)), let command = Command(rawValue: menuItem.tag) else {
            return true
        }
        return isEnabled(command)
    }

    private func isEnabled(_ command: Command) -> Bool {
        guard let document else { return false }
        return command == .new || document.activePath != nil
    }

    func retarget(to target: ImageDocument?) {
        document = target
        reload()
    }

    func reload() {
        reloading = true
        table.reloadData()
        if let document, let active = document.activePath,
           let row = document.paths.firstIndex(where: { $0.id == active }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        reloading = false

        for command in Command.allCases {
            buttonBar.setEnabled(isEnabled(command), forItem: "\(command)")
        }
    }

    // MARK: Commands

    /// One command on the front document, also used by the menus and the
    /// engine smoke test.
    func run(_ command: Command) {
        guard let document else { return }
        if command == .new {
            document.addPath(VectorPath())
            return
        }
        guard let path = document.activePath else { return }
        switch command {
        case .new:
            break
        case .delete:
            document.deletePath(path)
        case .toSelection:
            document.selectFromPath(path)
        case .stroke:
            document.strokePath(path, settings: ToolState.shared.pathLine)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        document?.paths.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let path = document?.paths[row] else { return nil }

        let visible = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleVisible(_:)))
        visible.state = path.isVisible ? .on : .off
        visible.tag = Int(path.id)
        visible.setAccessibilityLabel("Show \(path.name)")

        let name = NSTextField(string: path.name)
        name.isBordered = false
        name.drawsBackground = false
        name.isEditable = true
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        name.tag = Int(path.id)
        name.delegate = self
        name.setAccessibilityLabel("Path name")

        let row = NSStackView(views: [visible, name])
        row.spacing = 2
        return row
    }

    @objc private func toggleVisible(_ sender: NSButton) {
        document?.setPathVisible(Int32(sender.tag), sender.state == .on)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField, let document else { return }
        let id = Int32(field.tag)
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard let path = document.paths.first(where: { $0.id == id }) else { return }
        if name.isEmpty {
            field.stringValue = path.name
        } else if name != path.name {
            document.renamePath(id, to: name)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let document, table.selectedRow >= 0 else { return }
        document.selectPath(document.paths[table.selectedRow].id)
    }
}
