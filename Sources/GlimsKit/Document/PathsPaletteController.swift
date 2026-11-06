import AppKit
import RigiUI

/// The Paths palette: the front document's paths, top first. Selecting a
/// row makes that path the one the Path tool edits; the checkbox shows or
/// hides it on the canvas; double-clicking the name renames it. The
/// buttons add an empty path, delete the selected one, make its area the
/// selection, and draw it on the active layer in the foreground color at
/// the Path tool's stroke width.
@MainActor
final class PathsPaletteController: NSViewController, PaletteContent, NSTableViewDataSource,
                                     NSTableViewDelegate, NSTextFieldDelegate {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.paths"),
        title: "Paths",
        contentSize: NSSize(width: 240, height: 300),
        sizing: .resizable(minimumContentSize: NSSize(width: 200, height: 140)),
        frameAutosaveName: "Glims.palette.paths")

    /// The commands under the list, in order.
    enum Command: Int, CaseIterable {
        case new, delete, toSelection, stroke

        var title: String {
            switch self {
            case .new: return "New"
            case .delete: return "Delete"
            case .toSelection: return "Select"
            case .stroke: return "Stroke"
            }
        }

        var help: String {
            switch self {
            case .new: return "Add an empty path for the Path tool to draw in"
            case .delete: return "Delete the selected path"
            case .toSelection: return "Make the area the path encloses the selection"
            case .stroke: return "Draw the path on the active layer in the foreground color"
            }
        }
    }

    private weak var document: ImageDocument?
    private let table = NSTableView()
    private var buttons: [Command: NSButton] = [:]
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

        let bar = NSStackView(views: Command.allCases.map(makeButton))
        bar.spacing = 4
        bar.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        view = stack
    }

    private func makeButton(_ command: Command) -> NSButton {
        let button = NSButton(title: command.title, target: self, action: #selector(runCommand(_:)))
        button.tag = command.rawValue
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.bezelStyle = .rounded
        button.toolTip = command.help
        buttons[command] = button
        return button
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

        let hasPath = document?.activePath != nil
        buttons[.new]?.isEnabled = document != nil
        for command in [Command.delete, .toSelection, .stroke] {
            buttons[command]?.isEnabled = hasPath
        }
    }

    // MARK: Commands

    @objc private func runCommand(_ sender: NSButton) {
        guard let command = Command(rawValue: sender.tag) else { return }
        run(command)
    }

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
