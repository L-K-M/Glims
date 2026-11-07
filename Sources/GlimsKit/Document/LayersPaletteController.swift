import AppKit
import RigiUI

/// The Layers palette: the front document's layer tree, top of the stack
/// first. Selecting a row makes that layer or group the paint, metadata
/// and filter target. Groups open and close with the disclosure triangle;
/// dragging a row reorders it inside its parent or moves it into a group.
/// Each row carries a visibility checkbox, a lock badge when locks apply,
/// and a name that edits in place. The button bar adds a layer or a group,
/// duplicates and deletes.
@MainActor
final class LayersPaletteController: NSViewController, PaletteContent, NSOutlineViewDataSource,
                                     NSOutlineViewDelegate, NSMenuItemValidation {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.layers"),
        title: "Layers",
        contentSize: NSSize(width: 240, height: 300),
        sizing: .resizable(minimumContentSize: NSSize(width: 200, height: 160)),
        frameAutosaveName: "Glims.palette.layers")

    /// The pasteboard type drags inside the outline write: the layer id.
    private static let dragType = NSPasteboard.PasteboardType("ch.lkmc.Glims.layerID")

    private weak var document: ImageDocument?
    private let outline = NSOutlineView()
    private var reloading = false
    private var snapshot = LayerListSnapshot(document: nil, layers: [])
    /// Which document the outline's rows currently show, for expansion
    /// memory; groups reopen after a reload and after a retarget back.
    private var displayedDocument: ObjectIdentifier?
    private var expandedGroupIDs = Set<Int32>()
    private var expansionByDocument: [ObjectIdentifier: Set<Int32>] = [:]
    /// The selection the outline last applied; a new selection inside a
    /// collapsed group opens its parents, an unchanged one does not.
    private var lastSyncedSelection: Int32?
    private lazy var buttonBar = ClassicPaletteButtonBar(
        items: [Self.item("new", "New Layer", ["plus"]) { $0.layerCommand(.new) },
                Self.item("group", "New Layer Group", ["folder.badge.plus", "folder", "plus"]) { $0.createGroup() },
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
        outline.addTableColumn(column)
        outline.headerView = nil
        outline.usesAlternatingRowBackgroundColors = false
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(editNameOfClickedRow(_:))
        outline.rowHeight = LayerRowView.rowHeight
        outline.setAccessibilityLabel("Layers")
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = outline
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
        let group = NSMenuItem(title: "New Layer Group", action: #selector(newLayerGroup(_:)), keyEquivalent: "")
        group.target = self
        menu.addItem(group)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Layer Properties…", action: #selector(DocumentWindowController.layerProperties(_:)),
                     keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(commandItem("Bring Forward", .raise))
        menu.addItem(commandItem("Send Backward", .lower))
        menu.addItem(.separator())
        for (lock, title) in EngineSession.LayerLocks.menuOrder {
            let item = NSMenuItem(title: "Lock \(title)", action: #selector(toggleLock(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(lock.rawValue)
            menu.addItem(item)
        }
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

    @objc private func newLayerGroup(_ sender: NSMenuItem) {
        document?.createGroup()
    }

    @objc private func toggleLock(_ sender: NSMenuItem) {
        document?.toggleLocks(document?.activeLayer ?? 0, EngineSession.LayerLocks(rawValue: UInt32(sender.tag)))
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(runLayerCommand(_:)):
            guard let document, document.acceptsEdits else { return false }
            return menuItem.tag == Int(EngineSession.LayerCommand.new.rawValue) || document.activeLayer != nil
        case #selector(newLayerGroup(_:)):
            return document?.acceptsEdits == true
        case #selector(toggleLock(_:)):
            guard let document, let active = document.activeLayer else { return false }
            let lock = EngineSession.LayerLocks(rawValue: UInt32(menuItem.tag))
            let sources = snapshot.tree.nodesByID[active]
                .map { snapshot.tree.lockSources(for: $0, states: document.layerLocks) }
            menuItem.state = sources?.local.contains(lock) == true ? .on : .off
            menuItem.toolTip = DocumentWindowController.lockNote(lock, sources: sources)
            return document.acceptsEdits
        default:
            return true
        }
    }

    func retarget(to target: ImageDocument?) {
        document = target
        lastSyncedSelection = nil
        reload()
    }

    func reload() {
        let editable = document?.acceptsEdits == true
        let hasLayer = editable && document?.activeLayer != nil
        buttonBar.setEnabled(editable, forItem: "new")
        buttonBar.setEnabled(editable, forItem: "group")
        buttonBar.setEnabled(hasLayer, forItem: "duplicate")
        buttonBar.setEnabled(hasLayer, forItem: "delete")

        // Reloading the rows would end a rename being typed and commit it
        // half done; the list catches up when the rename ends.
        guard !isRenaming else { return }

        reloading = true
        defer { reloading = false }
        let shown = document.map { ObjectIdentifier($0) }
        if shown == displayedDocument {
            expandedGroupIDs = visibleExpandedIDs()
        } else {
            if let previous = displayedDocument {
                expansionByDocument[previous] = visibleExpandedIDs()
            }
            expandedGroupIDs = shown.flatMap { expansionByDocument[$0] } ?? []
        }
        displayedDocument = shown

        snapshot = LayerListSnapshot(document: document, layers: document?.layers ?? [])
        outline.reloadData()
        for id in expandedGroupIDs {
            if let node = snapshot.tree.nodesByID[id] { outline.expandItem(node) }
        }

        if let document, let active = document.activeLayer,
           let node = snapshot.tree.nodesByID[active] {
            if active != lastSyncedSelection {
                // A selection that landed inside a collapsed group opens
                // its parents once so the row can be seen.
                var parent = node.parent
                while let group = parent {
                    outline.expandItem(group)
                    parent = group.parent
                }
            }
            let row = outline.row(forItem: node)
            if row >= 0 {
                outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            } else {
                outline.deselectAll(nil)
            }
            lastSyncedSelection = active
        } else {
            outline.deselectAll(nil)
            lastSyncedSelection = nil
        }
    }

    /// The expanded groups the outline currently shows.
    private func visibleExpandedIDs() -> Set<Int32> {
        var ids = Set<Int32>()
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? LayerTree.Node,
                  outline.isItemExpanded(node) else { continue }
            ids.insert(node.id)
        }
        return ids
    }

    /// Whether a layer name in the list is being edited.
    private var isRenaming: Bool {
        LayerRowView.isRenaming(in: outline)
    }

    /// The outline's double-click: edit the clicked row's name in place.
    @objc private func editNameOfClickedRow(_ sender: NSOutlineView) {
        guard sender.clickedRow >= 0,
              let row = sender.view(atColumn: 0, row: sender.clickedRow, makeIfNecessary: true) as? LayerRowView
        else { return }
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

    // MARK: Outline data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        item == nil ? snapshot.tree.roots.count : (item as? LayerTree.Node)?.children.count ?? 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item == nil ? snapshot.tree.roots : (item as? LayerTree.Node)?.children ?? [])[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? LayerTree.Node else { return false }
        return node.layer.kind == .group && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let document,
              let layer = snapshot.layer(for: item, for: document, currentLayers: document.layers),
              let node = item as? LayerTree.Node else { return nil }
        let locks = snapshot.tree.lockSources(for: node, states: document.layerLocks)
        let rowView = LayerRowView(layer: layer,
                                   context: LayerRowView.Context(document: document, layerID: layer.id),
                                   details: Self.detailsSuffix(for: layer),
                                   locks: locks) { [weak self] context, change in
            self?.commitLayerChange(context, change) ?? false
        }
        rowView.checkbox.isEnabled = document.acceptsEdits
        rowView.nameField.isEditable = document.acceptsEdits
        rowView.onEditEnded = { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        }
        return rowView
    }

    // MARK: Selection

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let document, let layer = snapshot.layer(for: item, for: document,
                                                       currentLayers: document.layers) else { return false }
        guard document.acceptsEdits else {
            // The pick is refused; asking the document still shows why.
            document.selectLayer(layer.id)
            return false
        }
        return true
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let document,
              let item = outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) : nil,
              let layer = snapshot.layer(for: item, for: document, currentLayers: document.layers) else { return }
        document.selectLayer(layer.id)
        lastSyncedSelection = document.activeLayer
        // A refused pick leaves the active layer; the list shows it again.
        if document.activeLayer != layer.id { reload() }
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let document, document.acceptsEdits,
              let layer = snapshot.layer(for: item, for: document, currentLayers: document.layers)
        else { return nil }
        let writer = NSPasteboardItem()
        writer.setString("\(layer.id)", forType: Self.dragType)
        return writer
    }

    /// Where the drop lands, as the document's `moveLayer` understands it:
    /// a parent id (0: the top level) and a raw index among its children.
    /// Drops onto a group go to its first child.
    private func dropTarget(item: Any?, childIndex index: Int) -> (parent: Int32, index: Int32)? {
        if index == NSOutlineViewDropOnItemIndex {
            guard let node = item as? LayerTree.Node, node.layer.kind == .group else { return nil }
            return (node.id, 0)
        }
        return ((item as? LayerTree.Node)?.id ?? 0, Int32(index))
    }

    private func draggedID(_ info: NSDraggingInfo) -> Int32? {
        info.draggingPasteboard.string(forType: Self.dragType).flatMap(Int32.init)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        guard let document, document.acceptsEdits, let dragged = draggedID(info),
              let target = dropTarget(item: item, childIndex: index),
              snapshot.tree.resolveDrop(item: dragged, ontoParent: target.parent, at: target.index) != .invalid
        else { return [] }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let document, document.acceptsEdits, let dragged = draggedID(info),
              let target = dropTarget(item: item, childIndex: index) else { return false }
        document.moveLayer(dragged, toParent: target.parent, atIndex: target.index)
        if let node = item as? LayerTree.Node { outline.expandItem(node) }
        return true
    }
}
