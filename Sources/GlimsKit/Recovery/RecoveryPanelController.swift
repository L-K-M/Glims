import AppKit
import RigiUI

/// The recovery panel: the list of document copies a crashed earlier run
/// left in the private store. It is a non-activating panel — it can take
/// keyboard focus but never becomes main, so it does not retarget the
/// document palettes while it is open.
///
/// Rows are informational only: every action re-validates the selected
/// record against the store (`recoverableDocument(matching:)`,
/// `discardRecoverable`) rather than trusting the row's fields. Closing
/// the panel keeps every record; only Discard deletes one, behind an
/// explicit confirmation.
@MainActor
final class RecoveryPanelController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    /// The records the last reload showed; stale rows refuse safely at
    /// action time instead of acting on vanished files.
    private(set) var records: [RecoveryStore.RecoveredDocument] = []
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    let recoverButton = NSButton(title: "Recover", target: nil, action: nil)
    let discardButton = NSButton(title: "Discard…", target: nil, action: nil)
    let laterButton = NSButton(title: "Later", target: nil, action: nil)
    /// Sent the selected records to open as new unsaved documents.
    var onRecover: (([RecoveryStore.RecoveredDocument]) -> Void)?
    /// Sent the selected records to delete; the panel has already run
    /// its confirmation alert.
    var onDiscard: (([RecoveryStore.RecoveredDocument]) -> Void)?
    private(set) var busy = false

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// The original file as display text, or a note when there is none.
    static func sourceDescription(_ record: RecoveryStore.RecoveredDocument) -> String {
        if let url = record.nativeURL { return (url.path as NSString).abbreviatingWithTildeInPath }
        if let url = record.importedSourceURL {
            return "Imported from \((url.path as NSString).abbreviatingWithTildeInPath)"
        }
        return "Never saved to a file"
    }

    init() {
        let panel = RecoveryPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
                                  styleMask: [.titled, .closable, .resizable],
                                  backing: .buffered, defer: false)
        panel.title = "Recover Documents"
        panel.minSize = NSSize(width: 460, height: 240)
        super.init(window: panel)
        panel.isReleasedWhenClosed = false
        panel.appearance = EditorPreferences.shared.chromeAppearance
        let chrome = ClassicPanelView(frame: NSRect(x: 0, y: 0, width: 560, height: 320))
        panel.contentView = chrome

        let intro = NSTextField(wrappingLabelWithString:
            "These images were being edited when \(AppIdentity.name) last quit unexpectedly. "
            + "Recover opens each as a new unsaved document; its copy is kept until that document closes.")
        intro.font = .systemFont(ofSize: 11)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Document"
        nameColumn.width = 170
        let dateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("date"))
        dateColumn.title = "Copy Saved"
        dateColumn.width = 150
        let sourceColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("source"))
        sourceColumn.title = "Original File"
        sourceColumn.width = 210
        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(dateColumn)
        tableView.addTableColumn(sourceColumn)
        tableView.headerView = NSTableHeaderView()
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.setAccessibilityLabel("Recovery copies")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        for button in [recoverButton, discardButton, laterButton] {
            button.bezelStyle = .rounded
            button.target = self
        }
        recoverButton.action = #selector(recover(_:))
        recoverButton.keyEquivalent = "\r"
        discardButton.action = #selector(askDiscard(_:))
        laterButton.action = #selector(later(_:))
        laterButton.keyEquivalent = "\u{1b}"

        let buttons = NSStackView(views: [laterButton, discardButton, recoverButton])
        buttons.orientation = .horizontal
        buttons.spacing = 12
        for view in [intro, scrollView, statusLabel, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            chrome.addSubview(view)
        }
        NSLayoutConstraint.activate([
            intro.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 16),
            intro.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 20),
            intro.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -20),
            scrollView.topAnchor.constraint(equalTo: intro.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -20),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 110),
            statusLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 20),
            statusLabel.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            buttons.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -16),
        ])
        updateButtons()
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The currently selected records, in row order.
    var selectedRecords: [RecoveryStore.RecoveredDocument] {
        tableView.selectedRowIndexes.sorted().compactMap { records.indices.contains($0) ? records[$0] : nil }
    }

    /// Replaces the listed records. An empty list shows the empty state;
    /// the caller sets further status text with `showStatus`.
    func setRecords(_ newRecords: [RecoveryStore.RecoveredDocument]) {
        records = newRecords
        tableView.reloadData()
        updateButtons()
        if records.isEmpty { showStatus("No recovery copies were found.") }
    }

    /// Disables the action buttons while an operation runs; the list
    /// stays readable and the panel closable — in-flight work finishes
    /// independently.
    func setBusy(_ flag: Bool) {
        busy = flag
        updateButtons()
    }

    /// A nonmodal status or failure line under the list.
    func showStatus(_ message: String) {
        statusLabel.stringValue = message
    }

    /// What the status line currently says.
    var statusText: String { statusLabel.stringValue }

    private func updateButtons() {
        let hasSelection = !tableView.selectedRowIndexes.isEmpty
        recoverButton.isEnabled = !busy && hasSelection
        discardButton.isEnabled = !busy && hasSelection
    }

    @objc private func recover(_ sender: Any?) {
        guard !busy else { return }
        let selected = selectedRecords
        guard !selected.isEmpty else { return }
        onRecover?(selected)
    }

    /// Discard asks once, explicitly: the copies are the only fallback a
    /// crash has left, so deleting them is confirmed before the owner is
    /// told.
    @objc private func askDiscard(_ sender: Any?) {
        guard !busy, let window else { return }
        let selected = selectedRecords
        guard !selected.isEmpty else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = selected.count == 1
            ? "Discard the recovery copy of \u{201C}\(selected[0].name)\u{201D}?"
            : "Discard \(selected.count) recovery copies?"
        alert.informativeText = "The recovery copies will be permanently deleted. The original files are not touched."
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.onDiscard?(selected)
        }
    }

    @objc private func later(_ sender: Any?) { close() }

    // MARK: NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { records.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard records.indices.contains(row) else { return nil }
        let record = records[row]
        let text: String
        let note: String
        switch tableColumn?.identifier.rawValue {
        case "name":
            text = record.name
            note = text
        case "date":
            text = Self.dateFormatter.string(from: record.date)
            note = text
        default:
            text = Self.sourceDescription(record)
            note = text
        }
        let cell = NSTableCellView()
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingMiddle
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.textField = field
        cell.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            field.trailingAnchor.constraint(lessThanOrEqualTo: cell.trailingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        cell.toolTip = note
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtons()
    }
}

/// The recovery panel takes keyboard focus while the current document
/// remains main, so document palettes keep their target.
private final class RecoveryPanel: NSPanel {
    override var canBecomeMain: Bool { false }
}
