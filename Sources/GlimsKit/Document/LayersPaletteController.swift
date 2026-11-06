import AppKit
import RigiUI

/// The Layers palette: the front document's layer tree, top of the stack
/// first. Selecting a row makes that layer the paint and filter target.
/// Groups cannot be painted on and are not selectable. The button bar adds,
/// duplicates and deletes layers.
@MainActor
final class LayersPaletteController: NSViewController, PaletteContent, NSTableViewDataSource, NSTableViewDelegate {
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
        table.rowHeight = 22
        table.usesAlternatingRowBackgroundColors = false
        table.dataSource = self
        table.delegate = self
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

    /// The title bar triangle's menu: the Layer menu's commands, which the
    /// front document window answers through the responder chain.
    var paletteMenu: NSMenu? {
        let menu = NSMenu(title: "Layers")
        let commands: [(String, Selector)] = [
            ("New Layer", #selector(DocumentWindowController.newLayer(_:))),
            ("Duplicate Layer", #selector(DocumentWindowController.duplicateLayer(_:))),
            ("Delete Layer", #selector(DocumentWindowController.deleteLayer(_:))),
            ("Layer Properties…", #selector(DocumentWindowController.layerProperties(_:))),
            ("Bring Forward", #selector(DocumentWindowController.bringLayerForward(_:))),
            ("Send Backward", #selector(DocumentWindowController.sendLayerBackward(_:))),
        ]
        for (index, (title, action)) in commands.enumerated() {
            if index == 3 || index == 4 { menu.addItem(.separator()) }
            menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        }
        return menu
    }

    func retarget(to target: ImageDocument?) {
        document = target
        reload()
    }

    func reload() {
        reloading = true
        table.reloadData()
        if let document, let active = document.activeLayer,
           let row = document.layers.firstIndex(where: { $0.id == active }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
        reloading = false

        let hasLayer = document?.activeLayer != nil
        buttonBar.setEnabled(document != nil, forItem: "new")
        buttonBar.setEnabled(hasLayer, forItem: "duplicate")
        buttonBar.setEnabled(hasLayer, forItem: "delete")
    }

    /// The text of one row, also used by the engine smoke test.
    static func title(for layer: EngineSession.Layer) -> String {
        let indent = String(repeating: "    ", count: layer.depth)
        let eye = layer.isVisible ? "●" : "○"
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
        let suffix = details.isEmpty ? "" : "  (\(details.joined(separator: ", ")))"
        return "\(indent)\(eye) \(layer.name)\(suffix)"
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        document?.layers.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let layer = document?.layers[row] else { return nil }
        let field = NSTextField(labelWithString: Self.title(for: layer))
        field.font = .systemFont(ofSize: 12)
        field.lineBreakMode = .byTruncatingTail
        field.textColor = layer.kind == .group ? .secondaryLabelColor : .labelColor
        field.setAccessibilityLabel("\(layer.name), \(layer.isVisible ? "visible" : "hidden")")
        return field
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        document?.layers[row].kind != .group
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let document, table.selectedRow >= 0 else { return }
        document.selectLayer(document.layers[table.selectedRow].id)
    }
}
