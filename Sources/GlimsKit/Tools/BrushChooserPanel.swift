import AppKit

/// The one brush chooser, owned while open. `ToolOptionsPaletteController`
/// opens it for a paint tool; closing (choosing, cancelling, the document or
/// the palette going away, app shutdown) invalidates the model's generation
/// so a late native result can never restore a stale view, and releases the
/// panel. The Tool Options button reads back the resolved choice's thumbnail
/// and the missing-identity marker from here.
@MainActor
final class BrushChooser {
    static let shared = BrushChooser()

    private var panel: BrushChooserPanel?
    private(set) var isOpen = false
    private var choiceCache = BrushChoiceCache()
    private(set) var presentationRevision = 0

    private init() {}

    /// Opens the chooser for `tool`, capturing the tool NOW: applying later
    /// writes only this tool's `ToolState` brush resource, never whichever
    /// tool happens to be current then.
    func open(document: ImageDocument?, tool: ToolID) {
        close()
        let model = BrushChooserModel(capturedTool: tool,
                                      currentIdentity: ToolState.shared.brush(for: tool).resource)
        let panel = BrushChooserPanel(document: document, model: model)
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

    func thumbnail(for tool: ToolID, choice: EngineSession.ResourceIdentity?) -> NSImage? {
        choiceCache.preview(for: tool, choice: choice).map {
            NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
        }
    }

    func missingIdentity(for tool: ToolID, choice: EngineSession.ResourceIdentity?) -> EngineSession.ResourceIdentity? {
        choiceCache.missingIdentity(for: tool, choice: choice)
    }

    func resetChoice(for tool: ToolID) {
        choiceCache.reset(tool)
        presentationRevision += 1
        ToolState.shared.setBrushResource(nil, for: tool)
    }

    fileprivate func noteChoiceThumbnail(_ tool: ToolID, identity: EngineSession.ResourceIdentity?, _ image: CGImage?) {
        choiceCache.setPreview(image, identity: identity, for: tool)
        presentationRevision += 1
        ToolState.shared.notifyChange()
    }

    fileprivate func noteMissing(_ tool: ToolID, _ identity: EngineSession.ResourceIdentity?) {
        choiceCache.setMissing(identity, for: tool)
        presentationRevision += 1
        ToolState.shared.notifyChange()
    }

    fileprivate func didClose(_ panel: BrushChooserPanel) {
        if self.panel === panel {
            self.panel = nil
            isOpen = false
        }
    }
}

/// The owned panel: a search field over a one-column list of native 32 px
/// thumbnails and names, a status line for the loading/busy/error states,
/// and Choose (Return) / Cancel (Escape). Choosing applies the selection to
/// the captured tool only; Cancel and window closing preserve the previous
/// selection. All engine reads (catalog, identities, thumbnails) run off
/// the main thread through the global exclusive gate — `resources`,
/// `resourceIdentifiers`, `resource_resolve` and `resourceThumbnail` are
/// synchronous RPCs and are never called on main. The catalog load takes
/// EVERY brush (names and identities only); thumbnails render lazily in
/// small bounded batches as rows appear.
@MainActor
final class BrushChooserPanel: NSWindowController, NSWindowDelegate,
                               NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let model: BrushChooserModel
    private weak var sourceDocument: ImageDocument?
    private var isClosed = false
    private var autoRetryScheduled = false
    /// True while a catalog load is on the engine: no overlapping loads.
    private var loadInFlight = false
    /// Guards the single whenIdle re-pump of the thumbnail queue.
    private var thumbnailPumpScheduled = false
    private var updatingTable = false

    private let searchField = NSSearchField()
    private let table = BrushChooserTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private let duplicateButton = NSButton(title: "Duplicate…", target: nil, action: nil)
    /// The shared Duplicate… form while open; the panel owns its lifecycle
    /// and invalidates it on dismissal.
    private var duplicateForm: ResourceDuplicateFormController?
    /// A highlight to restore after a duplicate-triggered catalog reload.
    private var pendingRestoreSelection: BrushSelection?

    init(document: ImageDocument?, model: BrushChooserModel) {
        self.sourceDocument = document
        self.model = model
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 420),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "\(model.capturedTool.name) Brush"
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    private func buildContent(in panel: NSPanel) {
        searchField.placeholderString = "Search brushes"
        searchField.font = .systemFont(ofSize: 12)
        searchField.delegate = self
        searchField.focusRingType = .none
        searchField.setAccessibilityLabel("Search brushes")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("brush"))
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
        table.setAccessibilityLabel("Brushes")

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let choose = NSButton(title: "Choose", target: self, action: #selector(choose(_:)))
        choose.keyEquivalent = "\r"
        retryButton.target = self
        retryButton.action = #selector(load)
        retryButton.isHidden = true
        duplicateButton.target = self
        duplicateButton.action = #selector(duplicate(_:))
        duplicateButton.setAccessibilityLabel("Duplicate brush")
        let buttons = NSStackView(views: [retryButton, duplicateButton, cancel, choose])
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
        guard !isClosed, !loadInFlight else { return }
        guard let session = sourceDocument?.session else {
            model.setLoading(.error("Open a document to load the brush catalog."))
            refresh()
            return
        }
        loadInFlight = true
        model.setLoading(.loading)
        refresh()
        // Plain values only: the model is main-actor state and must not be
        // captured by the worker closure.
        let generation = model.generation
        let foreground = ToolState.shared.foreground
        let background = ToolState.shared.background
        let current = model.currentIdentity
        var outRows: [BrushRow] = []
        var outError: String?
        var resolvedCurrent: EngineSession.ResourceID?
        var resolutionError: EngineSession.EngineError?
        let accepted = EngineActivity.shared.perform(label: "Loading brushes", work: {
            do {
                // The FULL catalog — every brush, no cap: names, handles
                // and persistent identities. Thumbnails stay lazy
                // (pumpThumbnails) so a huge user brush folder never holds
                // the engine gate for long.
                for row in try session.resources(.brush) {
                    let identity = try session.resourceIdentifiers(row.id)
                    outRows.append(BrushRow(id: row.id, name: row.displayName, identity: identity))
                }
                if let current {
                    do {
                        resolvedCurrent = try session.resolveResource(current, kind: .brush)
                    } catch {
                        // Only NOT_FOUND means the brush is really gone; any
                        // other failure is reported distinctly, never as
                        // "missing" (the model checks isNotFound).
                        resolutionError = EngineSession.EngineError.coerce(error)
                    }
                }
            } catch {
                outError = (error as? EngineSession.EngineError)?.message ?? String(describing: error)
            }
        }, completion: { [weak self] in
            self?.loadInFlight = false
            self?.deliver(generation: generation, rows: outRows, resolvedCurrent: resolvedCurrent,
                          resolutionError: resolutionError, error: outError)
        })
        if !accepted {
            // The exclusive gate is held elsewhere: show the busy state and
            // retry once automatically when the engine frees up; a further
            // refusal becomes an error with a manual Retry.
            loadInFlight = false
            model.setLoading(.busy)
            refresh()
            if !autoRetryScheduled {
                autoRetryScheduled = true
                EngineActivity.shared.whenIdle { [weak self] in
                    guard let self, !self.isClosed, case .busy = self.model.state else { return }
                    self.autoRetryScheduled = false
                    self.load()
                }
            }
        }
    }

    private func deliver(generation: Int, rows: [BrushRow],
                         resolvedCurrent: EngineSession.ResourceID?,
                         resolutionError: EngineSession.EngineError?, error: String?) {
        // Stale delivery: the picker (or its document) closed meanwhile.
        guard !isClosed, generation == model.generation else { return }
        guard let sourceDocument, !sourceDocument.isClosing else {
            dismiss()
            return
        }
        guard model.deliver(generation: generation, rows: rows, thumbnails: [:],
                            resolvedCurrent: resolvedCurrent, resolutionError: resolutionError,
                            error: error) else { return }
        // A duplicate-triggered reload keeps the explicit highlight when its
        // row survives the fresh catalog.
        if let keep = pendingRestoreSelection {
            pendingRestoreSelection = nil
            if case .resource(let id) = keep, model.rows.contains(where: { $0.id == id }) {
                model.select(keep)
            }
        }
        BrushChooser.shared.noteMissing(model.capturedTool, model.missingIdentity)
        // Prime the lazy thumbnail queue: the resolved current brush first
        // (the Tool Options button shows its preview), then only the
        // initial visible batch — the rest render as rows scroll into view.
        if let resolvedCurrent {
            model.thumbnailQueue.request([resolvedCurrent], priority: true)
        }
        model.thumbnailQueue.request(visibleRows.prefix(BrushThumbnailQueue.batchSize).map { $0.id })
        pumpThumbnails()
        refresh()
    }

    // MARK: Lazy thumbnails (bounded native batches, off the main thread)

    /// Starts one bounded native thumbnail batch when the queue has pending
    /// ids and no batch is in flight. A refused batch (gate busy) is
    /// requeued and re-pumped once when the engine goes idle.
    private func pumpThumbnails() {
        guard !isClosed, case .ready = model.state else { return }
        let queue = model.thumbnailQueue
        guard queue.pendingCount > 0, queue.inFlightCount == 0 else { return }
        let batch = queue.beginBatch()
        guard !batch.isEmpty, let session = sourceDocument?.session else {
            queue.requeue(batch)
            return
        }
        let generation = model.generation
        let foreground = ToolState.shared.foreground
        let background = ToolState.shared.background
        var rendered: [EngineSession.ResourceID: CGImage] = [:]
        var failed: [EngineSession.ResourceID: String] = [:]
        let accepted = EngineActivity.shared.perform(label: "Rendering brush previews", work: {
            // One bounded batch; a single bad thumbnail fails only its own
            // entry and is cached as failed by the queue (never retried).
            for id in batch {
                do {
                    rendered[id] = try session.resourceThumbnail(id, maxSize: 32,
                                                                  foreground: foreground,
                                                                  background: background).image
                } catch {
                    failed[id] = EngineSession.EngineError.coerce(error).message
                }
            }
        }, completion: { [weak self] in
            self?.deliverThumbnails(generation: generation, rendered: rendered, failed: failed)
        })
        if !accepted {
            queue.requeue(batch)
            if !thumbnailPumpScheduled {
                thumbnailPumpScheduled = true
                EngineActivity.shared.whenIdle { [weak self] in
                    guard let self, !self.isClosed else { return }
                    self.thumbnailPumpScheduled = false
                    self.pumpThumbnails()
                }
            }
        }
    }

    private func deliverThumbnails(generation: Int,
                                   rendered: [EngineSession.ResourceID: CGImage],
                                   failed: [EngineSession.ResourceID: String]) {
        // Stale delivery: the picker (or its document) closed meanwhile.
        guard !isClosed, generation == model.generation else { return }
        guard let sourceDocument, !sourceDocument.isClosing else {
            dismiss()
            return
        }
        guard model.deliverThumbnails(generation: generation, rendered: rendered, failed: failed) else { return }
        if let resolved = model.resolvedCurrentID, let cgImage = rendered[resolved] {
            BrushChooser.shared.noteChoiceThumbnail(model.capturedTool, identity: model.currentIdentity, cgImage)
        }
        // Rows without a preview yet stay placeholders; reloading re-enters
        // viewFor, which re-requests them (deduplicated by the queue).
        reloadTable(scrollToSelection: false)
        pumpThumbnails()
    }

    // MARK: Display

    private var visibleRows: [BrushRow] { model.rows(matching: model.query) }

    private func reloadTable(scrollToSelection: Bool) {
        let selection = model.selection
        updatingTable = true
        defer { updatingTable = false }
        table.reloadData()
        // Row 0 is the native Default; then the filtered catalog.
        let selectedRow: Int
        switch selection {
        case .nativeDefault: selectedRow = 0
        case .none: selectedRow = -1
        case .resource(let id):
            let filtered = visibleRows
            selectedRow = filtered.firstIndex { $0.id == id }.map { $0 + 1 } ?? -1
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
            statusLabel.stringValue = "Loading brushes…"
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
                text = "No brushes found in the engine's catalog."
            } else if shown != total {
                text = "\(shown) of \(total) brushes"
            } else {
                text = "\(total) brushes"
            }
            if let missing = model.missingIdentity {
                text += " (current brush \"\(missing.name)\" is missing)"
            } else if let failure = model.resolutionError {
                text += " (could not verify the current brush: \(failure))"
            }
            statusLabel.stringValue = text
            retryButton.isHidden = true
        }
    }

    // MARK: Table

    /// Row 0 is the native Default brush; rows 1... are the filtered list.
    func numberOfRows(in tableView: NSTableView) -> Int {
        1 + visibleRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = tableView.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: self)
            as? NSTableCellView ?? makeCell()
        cell.identifier = NSUserInterfaceItemIdentifier("cell")
        if row == 0 {
            cell.textField?.stringValue = "Default"
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
                model.thumbnailQueue.request([item.id])
                pumpThumbnails()
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
            model.select(.nativeDefault)
        } else if visibleRows.indices.contains(row - 1) {
            model.select(.resource(visibleRows[row - 1].id))
        }
        updateDuplicateButton()
        // A hidden or temporarily deselected row is not a new choice.
        // Default is selected explicitly through row zero above.
    }

    // MARK: Duplicate…

    /// The duplicatable source of a Duplicate… right now: the highlighted
    /// catalog row's identity, native handle and kind. The Default row (and
    /// no highlight) is not a saved resource and is refused with a reason.
    private func duplicateSource() -> ResourceDuplicateValidation.Source? {
        guard case .resource(let id) = model.selection,
              let row = model.rows.first(where: { $0.id == id }) else { return nil }
        return ResourceDuplicateValidation.Source(kind: .brush, id: row.id, identity: row.identity)
    }

    private func updateDuplicateButton() {
        let source = duplicateSource()
        duplicateButton.isEnabled = !isClosed && source != nil
        duplicateButton.toolTip = ResourceDuplicateValidation.sourceRefusal(source, kind: .brush)
            ?? "Duplicate the selected brush under a new name"
    }

    /// Opens the shared Duplicate… form, capturing the document and the
    /// source NOW: later highlight, tool or front-window changes cannot
    /// alter them.
    @objc private func duplicate(_ sender: Any?) {
        guard !isClosed, let document = sourceDocument, !document.isClosing else { return }
        if let form = duplicateForm, !form.isInvalidated {
            form.show()
            return
        }
        guard let source = duplicateSource() else { return }
        let form = ResourceDuplicateFormController(document: document, source: source, hostWindow: window)
        form.onSucceeded = { [weak self] _ in self?.reloadAfterDuplicate() }
        form.onClosed = { [weak self] in self?.duplicateForm = nil }
        duplicateForm = form
        form.show()
    }

    /// After a successful duplicate: refetch the catalog off the main
    /// thread, keeping the current highlight; the new item is NOT chosen.
    private func reloadAfterDuplicate() {
        guard !isClosed else { return }
        pendingRestoreSelection = model.selection
        load()
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

    /// Applies the pending selection to the captured tool ONLY, then closes.
    @objc private func choose(_ sender: Any?) {
        guard !isClosed else { return }
        switch model.selection {
        case .none:
            // Closing an unselected/missing choice preserves its marker.
            break
        case .nativeDefault:
            BrushChooser.shared.resetChoice(for: model.capturedTool)
        case .resource(let id):
            guard let identity = model.pendingIdentity() else { return }
            ToolState.shared.setBrushResource(identity, for: model.capturedTool)
            BrushChooser.shared.noteChoiceThumbnail(model.capturedTool, identity: identity, model.thumbnail(id))
            BrushChooser.shared.noteMissing(model.capturedTool, nil)
        }
        dismiss()
    }

    /// Cancel and window closing: nothing was written, so the previous
    /// selection is preserved.
    @objc private func cancel(_ sender: Any?) {
        dismiss()
    }

    func dismiss() {
        guard !isClosed else { return }
        isClosed = true
        // Late native results must not restore this stale view; the open
        // Duplicate… form is invalidated with the panel (its accepted work,
        // if any, still drains on the document).
        model.invalidate()
        duplicateForm?.invalidate()
        duplicateForm = nil
        window?.orderOut(nil)
        BrushChooser.shared.didClose(self)
    }

    func windowWillClose(_ notification: Notification) {
        cancel(nil)
    }
}

/// The list: Return/Enter commits, Escape cancels, and the first click is
/// accepted even when the panel is not key.
private final class BrushChooserTableView: NSTableView {
    var onCommit: (() -> Void)?
    var onCancel: (() -> Void)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 36, 76: onCommit?()        // return / keypad enter
        case 53: onCancel?()            // escape
        default: super.keyDown(with: event)
        }
    }
}
