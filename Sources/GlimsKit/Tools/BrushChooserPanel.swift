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
    private(set) var choiceThumbnails: [ToolID: NSImage] = [:]
    private(set) var missing: [ToolID: EngineSession.ResourceIdentity] = [:]

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

    func thumbnail(for tool: ToolID) -> NSImage? {
        choiceThumbnails[tool]
    }

    fileprivate func noteChoiceThumbnail(_ tool: ToolID, _ image: NSImage?) {
        choiceThumbnails[tool] = image
    }

    fileprivate func noteMissing(_ tool: ToolID, _ identity: EngineSession.ResourceIdentity?) {
        missing[tool] = identity
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
/// the main thread in ONE bounded batch through the global exclusive gate —
/// `resourceThumbnail` is a synchronous RPC and is never called on main.
@MainActor
final class BrushChooserPanel: NSWindowController, NSWindowDelegate,
                               NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let model: BrushChooserModel
    private weak var sourceDocument: ImageDocument?
    private var isClosed = false
    private var autoRetryScheduled = false

    private let searchField = NSSearchField()
    private let table = BrushChooserTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)

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
        let buttons = NSStackView(views: [retryButton, cancel, choose])
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

    // MARK: Loading (off the main thread, one bounded batch)

    @objc func load() {
        guard !isClosed else { return }
        guard let session = sourceDocument?.session else {
            model.setLoading(.error("Open a document to load the brush catalog."))
            refresh()
            return
        }
        model.setLoading(.loading)
        refresh()
        // Plain values only: the model is main-actor state and must not be
        // captured by the worker closure.
        let generation = model.generation
        let foreground = ToolState.shared.foreground
        let background = ToolState.shared.background
        let current = model.currentIdentity
        var outRows: [BrushRow] = []
        var outThumbnails: [EngineSession.ResourceID: CGImage] = [:]
        var outError: String?
        var resolvedCurrent: EngineSession.ResourceID?
        let accepted = EngineActivity.shared.perform(label: "Loading brushes", work: {
            do {
                // One bounded batch: names, identities and fresh 32 px
                // thumbnails (recolored with the captured FG/BG) for at
                // most maxResources brushes, all on the engine worker.
                for row in try session.resources(.brush).prefix(BrushChooserModel.maxResources) {
                    let identity = try session.resourceIdentifiers(row.id)
                    outRows.append(BrushRow(id: row.id, name: row.displayName, identity: identity))
                    outThumbnails[row.id] =
                        try session.resourceThumbnail(row.id, maxSize: 32,
                                                      foreground: foreground, background: background).image
                }
                if let current {
                    // A missing persisted identity is detected here and
                    // shown, never silently replaced by the default.
                    resolvedCurrent = try? session.resolveResource(current, kind: .brush)
                }
            } catch {
                outError = (error as? EngineSession.EngineError)?.message ?? String(describing: error)
            }
        }, completion: { [weak self] in
            self?.deliver(generation: generation, rows: outRows, thumbnails: outThumbnails,
                          resolvedCurrent: resolvedCurrent, error: outError)
        })
        if !accepted {
            // The exclusive gate is held elsewhere: show the busy state and
            // retry once automatically when the engine frees up; a further
            // refusal becomes an error with a manual Retry.
            model.setLoading(.busy)
            refresh()
            if !autoRetryScheduled {
                autoRetryScheduled = true
                EngineActivity.shared.whenIdle { [weak self] in
                    guard let self, !self.isClosed, case .busy = self.model.state else { return }
                    self.load()
                }
            }
        }
    }

    private func deliver(generation: Int, rows: [BrushRow],
                         thumbnails: [EngineSession.ResourceID: CGImage],
                         resolvedCurrent: EngineSession.ResourceID?, error: String?) {
        // Stale delivery: the picker (or its document) closed meanwhile.
        guard !isClosed, generation == model.generation else { return }
        guard let sourceDocument, !sourceDocument.isClosing else {
            dismiss()
            return
        }
        guard model.deliver(generation: generation, rows: rows, thumbnails: thumbnails,
                            resolvedCurrent: resolvedCurrent, error: error) else { return }
        BrushChooser.shared.noteMissing(model.capturedTool, model.missingIdentity)
        if let resolvedCurrent, let cgImage = thumbnails[resolvedCurrent] {
            BrushChooser.shared.noteChoiceThumbnail(model.capturedTool,
                                                    NSImage(cgImage: cgImage, size: NSSize(width: 32, height: 32)))
        }
        refresh()
    }

    // MARK: Display

    private var visibleRows: [BrushRow] { model.rows(matching: model.query) }

    private func refresh() {
        table.reloadData()
        // Row 0 is the native Default; then the filtered catalog.
        let selectedRow: Int
        switch model.selection {
        case .nativeDefault: selectedRow = 0
        case .none: selectedRow = -1
        case .resource(let id):
            let filtered = visibleRows
            selectedRow = filtered.firstIndex { $0.id == id }.map { $0 + 1 } ?? -1
        }
        if selectedRow >= 0 {
            table.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
            table.scrollRowToVisible(selectedRow)
        } else {
            table.deselectAll(nil)
        }
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
            statusLabel.stringValue = model.rows.isEmpty
                ? "No brushes found in the engine's catalog."
                : "\(model.rows.count) brushes"
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
                cell.imageView?.image = NSImage(cgImage: cgImage, size: NSSize(width: 32, height: 32))
            } else {
                cell.imageView?.image = nil
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
        let row = table.selectedRow
        if row == 0 {
            model.select(.nativeDefault)
        } else if visibleRows.indices.contains(row - 1) {
            model.select(.resource(visibleRows[row - 1].id))
        } else {
            model.select(.none)
        }
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
        let identity = model.pendingIdentity()
        ToolState.shared.setBrushResource(identity, for: model.capturedTool)
        if case .resource(let id) = model.selection, let cgImage = model.thumbnail(id) {
            BrushChooser.shared.noteChoiceThumbnail(model.capturedTool,
                                                    NSImage(cgImage: cgImage, size: NSSize(width: 32, height: 32)))
        } else if identity == nil {
            BrushChooser.shared.noteChoiceThumbnail(model.capturedTool, nil)
        }
        if identity != nil || model.missingIdentity == nil {
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
        // Late native results must not restore this stale view.
        model.invalidate()
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
