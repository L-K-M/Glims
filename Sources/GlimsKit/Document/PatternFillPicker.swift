import AppKit

/// The embedded pattern picker of the Edit ▸ Fill sheet, owned for the
/// sheet's lifetime. It lists the FULL native pattern catalog (names and
/// identities only) behind a search field and a one-column table of lazy
/// 32 px thumbnails; the catalog and every render run off the main
/// thread through the global exclusive engine gate via the shared
/// `ResourcePickerController` — `resources`, `resource_identifiers`,
/// `resource_resolve` and `resourceThumbnail` are synchronous RPCs and
/// are never called on main.
///
/// The document is captured at open, so a retarget cannot redirect the
/// load. When the sheet ends — Fill, Cancel, or the document closing —
/// `invalidate()` bumps the model's generation so a late native delivery
/// is dropped without touching any view. The picker opens no nested sheet
/// of its own; its Duplicate… form is a nonmodal child panel owned by the
/// picker for the sheet's lifetime.
@MainActor
final class PatternFillPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                               NSSearchFieldDelegate {
    let model: ResourceChooserModel
    private let controller: ResourcePickerController
    var isClosed: Bool { controller.isClosed }

    let view: NSView
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let duplicateButton = NSButton(title: "Duplicate…", target: nil, action: nil)
    private weak var sourceDocument: ImageDocument?
    /// The shared Duplicate… form while open; the picker (owned by the Fill
    /// sheet) owns its lifecycle and invalidates it when the sheet ends.
    private var duplicateForm: ResourceDuplicateFormController?
    private var updatingTable = false

    init(document: ImageDocument, currentIdentity: EngineSession.ResourceIdentity?) {
        self.model = ResourceChooserModel(kind: .pattern, currentIdentity: currentIdentity)
        self.controller = ResourcePickerController(document: document, model: model)
        self.sourceDocument = document
        self.view = NSView()
        super.init()
        // The catalog loads once per sheet, the first time the list shows;
        // switching fill sources keeps the explicit pending choice.
        controller.loadOnlyOnce = true
        controller.onChange = { [weak self] in self?.refresh() }
        controller.onCatalogDelivered = { [weak self] in self?.refresh() }
        controller.onThumbnailsDelivered = { [weak self] in self?.reloadTable(scrollToSelection: false) }
        controller.onAbandoned = { [weak self] in self?.invalidate() }
        buildContent()
        refresh()
    }

    // MARK: Content

    private func buildContent() {
        searchField.placeholderString = "Search patterns"
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search patterns")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("pattern"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 38
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Patterns")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("Pattern status")

        // The picker is embedded in the Fill sheet, so Duplicate… opens the
        // shared form as a nonmodal child panel of the sheet's window —
        // never a nested AppKit sheet.
        duplicateButton.target = self
        duplicateButton.action = #selector(duplicate(_:))
        duplicateButton.setAccessibilityLabel("Duplicate pattern")
        duplicateButton.font = .systemFont(ofSize: 11)

        for subview in [searchField, scroll, duplicateButton, statusLabel] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: 300),
            searchField.topAnchor.constraint(equalTo: view.topAnchor),
            searchField.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.heightAnchor.constraint(equalToConstant: 150),
            duplicateButton.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            duplicateButton.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLabel.topAnchor.constraint(equalTo: duplicateButton.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: Catalog load (off the main thread, through the engine gate)

    /// Starts the one catalog load; call when the picker becomes visible.
    func load() {
        controller.load()
    }

    // MARK: Display

    private var visibleRows: [ResourceRow] { model.rows(matching: model.query) }

    private func reloadTable(scrollToSelection: Bool) {
        let selection = model.selection
        updatingTable = true
        defer { updatingTable = false }
        table.reloadData()
        if let selection,
           let row = visibleRows.firstIndex(where: { $0.id == selection }) {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            if scrollToSelection { table.scrollRowToVisible(row) }
        } else {
            table.deselectAll(nil)
        }
    }

    private func refresh() {
        reloadTable(scrollToSelection: true)
        updateDuplicateButton()
        switch model.state {
        case .loading:
            statusLabel.stringValue = "Loading patterns…"
        case .busy:
            statusLabel.stringValue = "The engine is busy with another task."
        case .error(let message):
            statusLabel.stringValue = message
        case .ready:
            // The status reflects the FULL catalog and the current search
            // results — never a misleading "missing" for a valid choice.
            let total = model.rows.count
            let shown = visibleRows.count
            var text: String
            if total == 0 {
                text = "No patterns found in the engine's catalog."
            } else if shown != total {
                text = "\(shown) of \(total) patterns"
            } else {
                text = "\(total) patterns"
            }
            if let missing = model.missingIdentity {
                text += " (last pattern \"\(missing.name)\" is missing)"
            } else if let failure = model.resolutionError {
                text += " (could not verify the last pattern: \(failure))"
            }
            statusLabel.stringValue = text
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        visibleRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: self)
            as? NSTableCellView ?? makeCell()
        cell.identifier = NSUserInterfaceItemIdentifier("cell")
        guard visibleRows.indices.contains(row) else { return nil }
        let item = visibleRows[row]
        cell.textField?.stringValue = item.name
        if let cgImage = model.thumbnail(item.id) {
            // Native aspect ratio: the preview is the rendered size.
            cell.imageView?.image = NSImage(cgImage: cgImage,
                                            size: NSSize(width: cgImage.width, height: cgImage.height))
        } else {
            // No preview yet: a placeholder until the lazy queue renders
            // this row in a bounded native batch.
            cell.imageView?.image = nil
            controller.requestThumbnails([item.id])
        }
        return cell
    }

    private func makeCell() -> NSTableCellView {
        let cell = NSTableCellView()
        let preview = NSImageView()
        preview.imageScaling = .scaleProportionallyDown
        preview.setAccessibilityElement(false)
        let name = NSTextField(labelWithString: "")
        name.font = .systemFont(ofSize: 12)
        name.lineBreakMode = .byTruncatingTail
        for subview in [preview, name] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(subview)
        }
        cell.imageView = preview
        cell.textField = name
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            preview.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            preview.widthAnchor.constraint(equalToConstant: 32),
            preview.heightAnchor.constraint(equalToConstant: 32),
            name.leadingAnchor.constraint(equalTo: preview.trailingAnchor, constant: 8),
            name.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            name.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !updatingTable else { return }
        let row = table.selectedRow
        // Filtering or refreshing can hide the highlighted row. That is
        // not a new resource choice; retain the explicit pending identity.
        guard visibleRows.indices.contains(row) else { return }
        model.select(visibleRows[row].id)
        updateDuplicateButton()
    }

    // MARK: Duplicate…

    /// The duplicatable source of a Duplicate… right now: the highlighted
    /// catalog row's identity, native handle and kind. No highlight is
    /// refused with a reason.
    private func duplicateSource() -> ResourceDuplicateValidation.Source? {
        guard let selection = model.selection,
              let row = model.rows.first(where: { $0.id == selection }) else { return nil }
        return ResourceDuplicateValidation.Source(kind: .pattern, id: row.id, identity: row.identity)
    }

    private func updateDuplicateButton() {
        let source = duplicateSource()
        duplicateButton.isEnabled = !isClosed && source != nil
        duplicateButton.toolTip = ResourceDuplicateValidation.sourceRefusal(source, kind: .pattern)
            ?? "Duplicate the selected pattern under a new name"
    }

    /// Opens the shared Duplicate… form, capturing the picker's document and
    /// the source NOW: later highlight, document or front-window changes
    /// cannot alter them.
    @objc private func duplicate(_ sender: Any?) {
        guard !isClosed, let document = sourceDocument, !document.isClosing else { return }
        if let form = duplicateForm, !form.isInvalidated {
            form.show()
            return
        }
        guard let source = duplicateSource() else { return }
        let form = ResourceDuplicateFormController(document: document, source: source, hostWindow: view.window)
        form.onSucceeded = { [weak self] _ in self?.controller.reloadCatalog() }
        form.onClosed = { [weak self] in self?.duplicateForm = nil }
        duplicateForm = form
        form.show()
    }

    // MARK: Search

    func controlTextDidChange(_ notification: Notification) {
        model.setQuery(searchField.stringValue)
        refresh()
    }

    // MARK: Close

    /// The sheet ended: no in-flight native result may touch this stale
    /// view again, and the open Duplicate… form is invalidated with the
    /// picker (its accepted work, if any, still drains on the document).
    /// Idempotent.
    func invalidate() {
        duplicateForm?.invalidate()
        duplicateForm = nil
        controller.invalidate()
    }
}
