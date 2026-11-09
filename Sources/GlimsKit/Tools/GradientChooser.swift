import AppKit

/// The one gradient chooser, owned while open. `ToolOptionsPaletteController`
/// opens it for the Gradient tool; closing (choosing, cancelling, the
/// document or the palette going away, app shutdown) invalidates the model's
/// generation so a late native result can never restore a stale view, and
/// releases the panel. The Tool Options button reads back the resolved
/// choice's name, thumbnail and the missing-identity marker from here.
///
/// The panel captures the document at open, so a retarget cannot redirect
/// the load or the apply; applying writes only the global gradient choice
/// (`ToolState.setGradientResource`), never whichever tool happens to be
/// current then.
@MainActor
final class GradientChooser {
    static let shared = GradientChooser()

    private var panel: GradientChooserPanel?
    private(set) var isOpen = false
    private var choiceCache = ResourceChoiceCache<EngineSession.ResourceKind>()
    private(set) var presentationRevision = 0

    private init() {
        ResourceCatalogChanges.observe(owner: self) { [weak self] change in
            guard let self, change.kind == .gradient else { return }
            self.choiceCache.invalidate(identity: change.oldIdentity)
            self.presentationRevision += 1
            ToolState.shared.notifyChange()
        }
    }

    /// Opens the chooser, capturing `document` NOW: a later retarget or
    /// close invalidates the panel instead of redirecting it.
    func open(document: ImageDocument?) {
        close()
        let model = ResourceChooserModel(kind: .gradient,
                                         currentIdentity: ToolState.shared.gradientResource)
        let panel = GradientChooserPanel(document: document, model: model)
        self.panel = panel
        isOpen = true
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
        panel.load()
    }

    /// Closes and releases the chooser, invalidating its generation.
    func close() {
        panel?.dismiss()
    }

    /// The focused catalog refresh after a create or duplicate published a
    /// new gradient: the open chooser refetches its rows off the main
    /// thread with the picker's stale-generation discipline, keeping its
    /// pending highlight and the committed choice untouched — the new
    /// gradient is never auto-selected. A closed chooser ignores this; its
    /// next open loads the fresh catalog anyway.
    func reloadCatalog() {
        panel?.reloadCatalog()
    }

    /// The preview of exactly `choice`, if one was rendered for it — an old
    /// image is never reused for a changed choice.
    func thumbnail(choice: EngineSession.ResourceIdentity?) -> NSImage? {
        choiceCache.preview(for: .gradient, choice: choice).map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }
    }

    func missingIdentity(choice: EngineSession.ResourceIdentity?) -> EngineSession.ResourceIdentity? {
        choiceCache.missingIdentity(for: .gradient, choice: choice)
    }

    /// Explicit reset to the Foreground-to-Background Default (nil
    /// persistent resource choice).
    func resetChoice() {
        choiceCache.reset(.gradient)
        presentationRevision += 1
        ToolState.shared.setGradientResource(nil)
    }

    fileprivate func noteChoiceThumbnail(_ identity: EngineSession.ResourceIdentity?, _ image: CGImage?) {
        choiceCache.setPreview(image, identity: identity, for: .gradient)
        presentationRevision += 1
        ToolState.shared.notifyChange()
    }

    fileprivate func noteMissing(_ identity: EngineSession.ResourceIdentity?) {
        choiceCache.setMissing(identity, for: .gradient)
        presentationRevision += 1
        ToolState.shared.notifyChange()
    }

    fileprivate func didClose(_ panel: GradientChooserPanel) {
        if self.panel === panel {
            self.panel = nil
            isOpen = false
        }
    }
}

/// The owned panel: a search field over a one-column list of native 32 px
/// thumbnails and names, row 0 being the Foreground-to-Background Default,
/// a status line for the loading/busy/error states, and Choose (Return) /
/// Cancel (Escape). Choosing applies the selection — a resource identity,
/// or nil for Default — to the global gradient choice only; Cancel and
/// window closing preserve the previous choice. All engine reads (catalog,
/// identities, thumbnails) run off the main thread through the shared
/// `ResourcePickerController`; gradient thumbnails preview with the current
/// foreground/background colors, captured by value before each batch.
@MainActor
final class GradientChooserPanel: NSWindowController, NSWindowDelegate,
                                  NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    let model: ResourceChooserModel
    private let controller: ResourcePickerController
    private weak var sourceDocument: ImageDocument?
    /// Row 0 (the Foreground-to-Background Default, nil identity) selected.
    private var defaultSelected: Bool
    private var updatingTable = false

    private let searchField = NSSearchField()
    private let table = ResourcePickerTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let duplicateButton = NSButton(title: "Duplicate…", target: nil, action: nil)
    /// The shared Duplicate… form while open; the panel owns its lifecycle
    /// and invalidates it on dismissal.
    private var duplicateForm: ResourceDuplicateFormController?
    /// Shared rename/delete controls beside the Duplicate… affordance.
    private lazy var controls: ResourceManagementControls = {
        ResourceManagementControls(
            document: { [weak self] in self?.sourceDocument },
            source: { [weak self] in self?.duplicateSource() },
            hostWindow: { [weak self] in self?.window },
            onCatalogChanged: { [weak self] change in
                guard let self else { return }
                guard change.kind == .gradient else { return }
                if let newIdentity = change.newIdentity {
                    self.model.remapIdentity(from: change.oldIdentity, to: newIdentity)
                }
                self.controller.reloadCatalog()
            }
        )
    }()

    init(document: ImageDocument?, model: ResourceChooserModel) {
        self.sourceDocument = document
        self.model = model
        self.defaultSelected = model.currentIdentity == nil
        self.controller = ResourcePickerController(document: document, model: model)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Gradient"
        super.init(window: panel)
        panel.delegate = self
        controller.thumbnailColors = { (ToolState.shared.foreground, ToolState.shared.background) }
        controller.onChange = { [weak self] in self?.refresh() }
        controller.onCatalogDelivered = { [weak self] in self?.catalogDelivered() }
        controller.onThumbnailsDelivered = { [weak self] in self?.thumbnailsDelivered() }
        controller.onAbandoned = { [weak self] in self?.dismiss() }
        buildContent(in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    private func buildContent(in panel: NSPanel) {
        searchField.placeholderString = "Search gradients"
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.setAccessibilityLabel("Search gradients")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("gradient"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 40
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(choose(_:))
        table.onCommit = { [weak self] in self?.choose(nil) }
        table.onCancel = { [weak self] in self?.cancel(nil) }
        table.setAccessibilityLabel("Gradients")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityLabel("Gradient status")

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let choose = NSButton(title: "Choose", target: self, action: #selector(choose(_:)))
        choose.keyEquivalent = "\r"
        retryButton.target = self
        retryButton.action = #selector(load)
        retryButton.isHidden = true
        duplicateButton.target = self
        duplicateButton.action = #selector(duplicate(_:))
        duplicateButton.setAccessibilityLabel("Duplicate gradient")
        let buttons = NSStackView(views: [retryButton, duplicateButton, controls, cancel, choose])
        buttons.spacing = 8
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [searchField, scroll, statusLabel, buttons])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
        ])
        refresh()
    }

    // MARK: Loading (off the main thread; full catalog, lazy thumbnails)

    @objc func load() {
        controller.load()
    }

    /// Refetches the catalog after a create or duplicate published a new
    /// gradient. The picker's stale-generation discipline applies: a late
    /// delivery for a closed or replaced view is dropped. The highlighted
    /// row survives when its row does; the new item is never chosen and
    /// the committed choice is untouched.
    func reloadCatalog() {
        guard !controller.isClosed else { return }
        controller.reloadCatalog()
    }

    private func catalogDelivered() {
        // With no persisted choice the Default row is the pending one.
        if model.selection != nil { defaultSelected = false }
        else if model.currentIdentity == nil { defaultSelected = true }
        GradientChooser.shared.noteMissing(model.missingIdentity)
        refresh()
    }

    private func thumbnailsDelivered() {
        if let resolved = model.resolvedCurrentID, let cgImage = model.thumbnail(resolved) {
            GradientChooser.shared.noteChoiceThumbnail(model.currentIdentity, cgImage)
        }
        // Rows without a preview yet stay placeholders; reloading re-enters
        // viewFor, which re-requests them (deduplicated by the queue).
        reloadTable(scrollToSelection: false)
    }

    // MARK: Display

    private var visibleRows: [ResourceRow] { model.rows(matching: model.query) }

    private func reloadTable(scrollToSelection: Bool) {
        let selection = model.selection
        updatingTable = true
        defer { updatingTable = false }
        table.reloadData()
        // Row 0 is the Foreground-to-Background Default; then the filtered catalog.
        let selectedRow: Int
        if defaultSelected {
            selectedRow = 0
        } else if let selection,
                  let row = visibleRows.firstIndex(where: { $0.id == selection }) {
            selectedRow = row + 1
        } else {
            selectedRow = -1
        }
        if selectedRow >= 0 {
            table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            if scrollToSelection { table.scrollRowToVisible(selectedRow) }
        } else {
            table.deselectAll(nil)
        }
    }

    private func refresh() {
        reloadTable(scrollToSelection: true)
        updateDuplicateButton()
        switch model.state {
        case .loading:
            statusLabel.stringValue = "Loading gradients…"
            retryButton.isHidden = true
        case .busy:
            statusLabel.stringValue = "The engine is busy with another task."
            retryButton.isHidden = false
        case .error(let message):
            statusLabel.stringValue = message
            retryButton.isHidden = false
        case .ready:
            // The status reflects the FULL catalog and the current search
            // results — never a misleading "missing" for a valid choice.
            let total = model.rows.count
            let shown = visibleRows.count
            var text: String
            if total == 0 {
                text = "No gradients found in the engine's catalog."
            } else if shown != total {
                text = "\(shown) of \(total) gradients"
            } else {
                text = "\(total) gradients"
            }
            if let missing = model.missingIdentity {
                text += " (last gradient \"\(missing.name)\" is missing)"
            } else if let failure = model.resolutionError {
                text += " (could not verify the last gradient: \(failure))"
            }
            statusLabel.stringValue = text
            retryButton.isHidden = true
        }
    }

    // MARK: Table

    /// Row 0 is the Foreground-to-Background Default; rows 1... are the filtered list.
    func numberOfRows(in tableView: NSTableView) -> Int {
        1 + visibleRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: self)
            as? NSTableCellView ?? makeCell()
        cell.identifier = NSUserInterfaceItemIdentifier("cell")
        if row == 0 {
            cell.textField?.stringValue = "Foreground to Background (Default)"
            cell.imageView?.image = nil
        } else {
            let rows = visibleRows
            guard rows.indices.contains(row - 1) else { return nil }
            let item = rows[row - 1]
            cell.textField?.stringValue = item.name
            if let cgImage = model.thumbnail(item.id) {
                cell.imageView?.image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
            } else {
                // No preview yet: a placeholder until the lazy queue renders
                // this row in a bounded native batch.
                cell.imageView?.image = nil
                controller.requestThumbnails([item.id])
            }
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
        for view in [preview, name] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(view)
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
        if row == 0 {
            // The explicit Default: nil persistent resource choice.
            defaultSelected = true
            model.select(nil)
        } else if visibleRows.indices.contains(row - 1) {
            defaultSelected = false
            model.select(visibleRows[row - 1].id)
        }
        updateDuplicateButton()
        // A hidden or temporarily deselected row is not a new choice; the
        // pending identity is retained through search and reloads.
    }

    // MARK: Duplicate…

    /// The duplicatable source of a Duplicate… right now: the highlighted
    /// catalog row's identity, native handle and kind. The Foreground to
    /// Background Default row (and no highlight) is not a saved resource and
    /// is refused with a reason.
    private func duplicateSource() -> ResourceDuplicateValidation.Source? {
        guard let selection = model.selection,
              let row = model.rows.first(where: { $0.id == selection }) else { return nil }
        return ResourceDuplicateValidation.Source(kind: .gradient, id: row.id, identity: row.identity)
    }

    private func updateDuplicateButton() {
        let source = duplicateSource()
        duplicateButton.isEnabled = !controller.isClosed && source != nil
        duplicateButton.toolTip = ResourceDuplicateValidation.sourceRefusal(source, kind: .gradient)
            ?? "Duplicate the selected gradient under a new name"
        controls.update()
    }

    /// Opens the shared Duplicate… form, capturing the document and the
    /// source NOW: later highlight, tool or front-window changes cannot
    /// alter them.
    @objc private func duplicate(_ sender: Any?) {
        guard !controller.isClosed, let document = sourceDocument, !document.isClosing else { return }
        if let form = duplicateForm, !form.isInvalidated {
            form.show()
            return
        }
        guard let source = duplicateSource() else { return }
        let form = ResourceDuplicateFormController(document: document, source: source, hostWindow: window)
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

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            choose(nil)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel(nil)
            return true
        default:
            return false
        }
    }

    // MARK: Choose / cancel / close

    /// Applies the pending selection — a resource identity, or nil for the
    /// Foreground-to-Background Default — then closes. With nothing
    /// highlighted (e.g. a missing persisted choice) nothing is written:
    /// the previous choice is preserved, never substituted.
    @objc private func choose(_ sender: Any?) {
        guard !controller.isClosed else { return }
        if defaultSelected {
            GradientChooser.shared.resetChoice()
        } else if let selection = model.selection,
                  let identity = model.rows.first(where: { $0.id == selection })?.identity {
            ToolState.shared.setGradientResource(identity)
            GradientChooser.shared.noteChoiceThumbnail(identity, model.thumbnail(selection))
            GradientChooser.shared.noteMissing(nil)
        }
        dismiss()
    }

    /// Cancel and window closing: nothing was written, so the previous
    /// selection is preserved.
    @objc private func cancel(_ sender: Any?) {
        dismiss()
    }

    func dismiss() {
        guard !controller.isClosed else { return }
        // Late native results must not restore this stale view; the open
        // Duplicate… form is invalidated with the panel (its accepted work,
        // if any, still drains on the document).
        controller.invalidate()
        duplicateForm?.invalidate()
        duplicateForm = nil
        controls.invalidate()
        window?.orderOut(nil)
        GradientChooser.shared.didClose(self)
    }

    func windowWillClose(_ notification: Notification) {
        cancel(nil)
    }
}
