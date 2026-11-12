import AppKit
import RigiUI

/// The rows a History palette rendered, bound to the document and the
/// history revision they were read under, so picking a stale row is
/// refused instead of silently selecting a different state.
struct HistoryListSnapshot {
    /// What picking a row asks for. A stale row is never resent under the
    /// newer revision.
    enum Pick: Equatable {
        case move(position: Int32, revision: UInt64)
        case stale
    }

    let document: AnyObject?
    let revision: UInt64
    let rows: [EngineSession.HistoryRow]
    let currentPosition: Int32

    init(document: AnyObject?, history: EngineSession.History?) {
        self.document = document
        revision = history?.revision ?? 0
        rows = history?.rows ?? []
        currentPosition = history?.currentPosition ?? -1
    }

    /// What picking table row `row` asks for: `.stale` when the list does
    /// not belong to `currentDocument`, when the document's history has
    /// already moved past this revision, or when the row is out of range.
    func pick(row: Int, for currentDocument: AnyObject?, currentRevision: UInt64?) -> Pick {
        guard let document, let currentDocument, document === currentDocument,
              let currentRevision, currentRevision == revision,
              rows.indices.contains(row) else { return .stale }
        return .move(position: rows[row].position, revision: revision)
    }

    /// The shape distinguishing the current state — a shape, not color
    /// alone (docs/design.md, accessibility).
    static func marker(isCurrent: Bool) -> String { isCurrent ? "●" : "○" }

    /// What VoiceOver says for a row: its name and what picking it does.
    static func accessibilityLabel(for row: EngineSession.HistoryRow, currentPosition: Int32) -> String {
        if row.position == currentPosition { return "\(row.name), current state" }
        return row.position < currentPosition ? "\(row.name), undo to this state" : "\(row.name), redo to this state"
    }
}

/// The History palette: the front document's undo states, earliest first.
/// The current state is marked with a filled marker and read to VoiceOver;
/// states after it were undone and stay readable and pickable to redo.
/// Picking a row queues a move through undo/redo to that state; a pick
/// whose revision went stale is refused without changing the image, the
/// list reloads and the user picks again. The button bar and the title
/// bar menu snapshot the image: an independent copy opened as a new
/// document.
@MainActor
final class HistoryPaletteController: NSViewController, PaletteContent, NSTableViewDataSource,
                                      NSTableViewDelegate, NSMenuItemValidation {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.history"),
        title: "History",
        contentSize: NSSize(width: 240, height: 300),
        sizing: .resizable(minimumContentSize: NSSize(width: 200, height: 140)),
        frameAutosaveName: "Glims.palette.history")

    /// What a stale pick reports, matching the engine's refusal.
    static let staleMessage = "The image history changed. Select the state again."

    private weak var document: ImageDocument?
    private let table = NSTableView()
    private var reloading = false
    /// The rows on screen, bound to their document and revision; clicks
    /// resolve against them, never a live lookup.
    private var displayed = HistoryListSnapshot(document: nil, history: nil)
    private lazy var buttonBar = ClassicPaletteButtonBar(items: [
        ClassicPaletteButtonBar.Item(id: "snapshot", title: "New Snapshot", image: Self.symbol()) { [weak self] in
            self?.document?.newSnapshot()
        },
    ])

    private static func symbol() -> NSImage {
        let image = ["camera", "rectangle.on.rectangle", "plus.square.on.square"].lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: "New Snapshot") }
            .first ?? NSImage()
        image.isTemplate = true
        return image
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("History")

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

    /// The title bar triangle's menu: the same command as the button.
    var paletteMenu: NSMenu? {
        let menu = NSMenu(title: "History")
        let item = NSMenuItem(title: "New Snapshot", action: #selector(newSnapshot(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func newSnapshot(_ sender: NSMenuItem) {
        document?.newSnapshot()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(newSnapshot(_:)) else { return true }
        return document?.acceptsEdits == true && document?.snapshotHandler != nil && document?.colorInfo.mode != .lab
    }

    func retarget(to target: ImageDocument?) {
        document = target
        reload()
    }

    func reload() {
        buttonBar.setEnabled(document?.acceptsEdits == true && document?.snapshotHandler != nil && document?.colorInfo.mode != .lab,
                             forItem: "snapshot")
        reloading = true
        defer { reloading = false }
        displayed = HistoryListSnapshot(document: document, history: document?.history)
        table.reloadData()
        if let row = displayed.rows.firstIndex(where: { $0.position == displayed.currentPosition }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            table.deselectAll(nil)
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        displayed.rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayed.rows.indices.contains(row) else { return nil }
        let state = displayed.rows[row]
        let isCurrent = state.position == displayed.currentPosition

        let marker = NSTextField(string: HistoryListSnapshot.marker(isCurrent: isCurrent))
        marker.isBordered = false
        marker.drawsBackground = false
        marker.isEditable = false
        marker.font = .systemFont(ofSize: 11)
        marker.setAccessibilityLabel(isCurrent ? "Current state" : "Selectable state")

        let name = NSTextField(string: state.name)
        name.isBordered = false
        name.drawsBackground = false
        name.isEditable = false
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        name.setAccessibilityLabel(HistoryListSnapshot.accessibilityLabel(for: state,
                                                                        currentPosition: displayed.currentPosition))

        let rowView = NSStackView(views: [marker, name])
        rowView.spacing = 4
        return rowView
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !reloading, let document else { return }
        switch displayed.pick(row: table.selectedRow, for: document,
                              currentRevision: document.history?.revision) {
        case .move(let position, let revision):
            document.moveToHistoryState(position, revision: revision)
        case .stale:
            // A row that is not this document's or whose revision the
            // engine already left behind: say why and reload, never retry.
            document.onError?(Self.staleMessage)
            reload()
        }
    }
}
