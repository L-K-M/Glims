import AppKit
import RigiUI

/// The Layers palette: the front document's layer tree, top of the stack
/// first. Selecting a row makes that layer the paint and filter target.
/// Groups cannot be painted on and are not selectable. Each row carries a
/// visibility checkbox and a name that edits in place. The button bar adds,
/// duplicates and deletes layers.
@MainActor
final class LayersPaletteController: NSViewController, PaletteContent, NSTableViewDataSource, NSTableViewDelegate,
                                     NSMenuItemValidation {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.layers"),
        title: "Layers",
        contentSize: NSSize(width: 240, height: 300),
        sizing: .resizable(minimumContentSize: NSSize(width: 200, height: 160)),
        frameAutosaveName: "Glims.palette.layers")

    private weak var document: ImageDocument?
    private let table = NSTableView()
    private var reloading = false
    private var snapshot = LayerListSnapshot(document: nil, layers: [])
    private lazy var buttonBar = ClassicPaletteButtonBar(
        items: [Self.item("new", "New Layer", ["plus"]) { $0.layerCommand(.new) },
                Self.item("duplicate", "Duplicate Layer", ["plus.square.on.square"]) { $0.layerCommand(.duplicate) }]
            .map(bind),
        trailingItems: [bind(Self.item("delete", "Delete Layer", ["trash"]) { $0.layerCommand(.delete) })])

    /// A button bar command before it knows the palette's document.
    private struct Command {
        let id: String
        let title: String
        let image: NSImage
        let run: (ImageDocument) -> Void
    }

    private static func item(_ id: String, _ title: String, _ symbols: [String],
                             _ run: @escaping (ImageDocument) -> Void) -> Command {
        let image = symbols.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
            .first ?? NSImage()
        image.isTemplate = true
        return Command(id: id, title: title, image: image, run: run)
    }

    private func bind(_ command: Command) -> ClassicPaletteButtonBar.Item {
        ClassicPaletteButtonBar.Item(id: command.id, title: command.title, image: command.image) { [weak self] in
            guard let document = self?.document else { return }
            command.run(document)
        }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(editNameOfClickedRow(_:))
        table.rowHeight = LayerRowView.rowHeight
        table.setAccessibilityLabel("Layers")

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

    /// The title bar triangle's menu: the layer commands, on the document
    /// the palette shows, as its buttons are, so they work while that
    /// document's window is minimized. Layer Properties… opens the document
    /// window's dialog and goes there through the responder chain.
    var paletteMenu: NSMenu? {
        let menu = NSMenu(title: "Layers")
        let commands: [(String, EngineSession.LayerCommand)] = [
            ("New Layer", .new), ("Duplicate Layer", .duplicate), ("Delete Layer", .delete),
        ]
        for (title, command) in commands {
            menu.addItem(commandItem(title, command))
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Layer Properties…", action: #selector(DocumentWindowController.layerProperties(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(commandItem("Bring Forward", .raise))
        menu.addItem(commandItem("Send Backward", .lower))
        return menu
    }

    private func commandItem(_ title: String, _ command: EngineSession.LayerCommand) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runLayerCommand(_:)), keyEquivalent: "")
        item.target = self
        item.tag = Int(command.rawValue)
        return item
    }

    @objc private func runLayerCommand(_ sender: NSMenuItem) {
        guard let command = EngineSession.LayerCommand(rawValue: UInt32(sender.tag)) else { return }
        document?.layerCommand(command)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(runLayerCommand(_:)) else { return true }
        guard let document, document.acceptsEdits else { return false }
        return menuItem.tag == Int(EngineSession.LayerCommand.new.rawValue) || document.activeLayer != nil
    }

    func retarget(to target: ImageDocument?) {
        document = target
        reload()
    }

    func reload() {
        let editable = document?.acceptsEdits == true
        let hasLayer = editable && document?.activeLayer != nil
        buttonBar.setEnabled(editable, forItem: "new")
        buttonBar.setEnabled(hasLayer, forItem: "duplicate")
        buttonBar.setEnabled(hasLayer, forItem: "delete")

        // Reloading the rows would end a rename being typed and commit it
        // half done; the list catches up when the rename ends.
        guard !isRenaming else { return }

        reloading = true
        snapshot = LayerListSnapshot(document: document, layers: document?.layers ?? [])
        table.reloadData()
        if let document, let active = document.activeLayer,
           let row = document.layers.firstIndex(where: { $0.id == active }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        reloading = false
    }

    /// Whether a layer name in the list is being edited.
    private var isRenaming: Bool {
        LayerRowView.isRenaming(in: table)
    }

    /// The table's double-click: edit the clicked row's name in place.
    @objc private func editNameOfClickedRow(_ sender: NSTableView) {
        guard sender.clickedRow >= 0,
              let row = sender.view(atColumn: 0, row: sender.clickedRow, makeIfNecessary: true) as? LayerRowView else { return }
        row.startEditingName()
    }

    /// Applies a row's change to the layer it was made for, and only while
    /// that layer is still in the document the palette shows. Returns false
    /// when the change was refused, so the row shows the layer's
    /// authoritative state again.
    private func commitLayerChange(_ context: LayerRowView.Context, _ change: EngineSession.LayerChange) -> Bool {
        guard let document, document.acceptsEdits,
              LayerRowView.canChange(context, document: document, layers: document.layers) else { return false }
        document.changeLayer(context.layerID, change)
        return true
    }

    /// The text of one row, also used by the engine smoke test.
    static func title(for layer: EngineSession.Layer) -> String {
        let indent = String(repeating: "    ", count: layer.depth)
        let eye = layer.isVisible ? "●" : "○"
        return "\(indent)\(eye) \(layer.name)\(Self.detailsSuffix(for: layer))"
    }

    /// The trailing row details: kind, mask and filter count.
    static func detailsSuffix(for layer: EngineSession.Layer) -> String {
        var details: [String] = []
        switch layer.kind {
        case .group: details.append("group")
        case .text: details.append("text")
        case .link: details.append("linked")
        case .vector: details.append("vector")
        case .pixel: break
        }
        if layer.hasMask { details.append("mask") }
        if layer.filterCount > 0 { details.append("\(layer.filterCount) filter\(layer.filterCount == 1 ? "" : "s")") }
        return details.isEmpty ? "" : "  (\(details.joined(separator: ", ")))"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        snapshot.layers.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let document,
              let layer = snapshot.layer(at: row, for: document, currentLayers: document.layers) else { return nil }
        let rowView = LayerRowView(layer: layer,
                                   context: LayerRowView.Context(document: document, layerID: layer.id),
                                   details: Self.detailsSuffix(for: layer)) { [weak self] context, change in
            self?.commitLayerChange(context, change) ?? false
        }
        rowView.checkbox.isEnabled = document.acceptsEdits
        rowView.nameField.isEditable = document.acceptsEdits
        rowView.onEditEnded = { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        }
        return rowView
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard let document, document.acceptsEdits,
              let layer = snapshot.layer(at: row, for: document, currentLayers: document.layers) else { return false }
        return layer.kind != .group
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let document,
              let layer = snapshot.layer(at: table.selectedRow, for: document, currentLayers: document.layers) else { return }
        document.selectLayer(layer.id)
        if document.activeLayer != layer.id { reload() }
    }
}
