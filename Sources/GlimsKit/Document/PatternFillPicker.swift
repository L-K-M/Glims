import AppKit

/// The embedded pattern picker of the Edit ▸ Fill sheet, owned for the
/// sheet's lifetime. It lists the FULL native pattern catalog (names and
/// identities only) behind a search field and a one-column table of lazy
/// 32 px thumbnails; the catalog and every render run off the main
/// thread through the global exclusive engine gate — `resources`,
/// `resource_identifiers`, `resource_resolve` and `resourceThumbnail`
/// are synchronous RPCs and are never called on main.
///
/// The document is captured at open, so a retarget cannot redirect the
/// load. When the sheet ends — Fill, Cancel, or the document closing —
/// `invalidate()` bumps the model's generation so a late native delivery
/// is dropped without touching any view. The picker opens no child
/// panel or nested sheet of its own.
@MainActor
final class PatternFillPicker: NSObject, NSTableViewDataSource, NSTableViewDelegate,
                               NSSearchFieldDelegate {
    let model: PatternChooserModel
    private weak var document: ImageDocument?
    private(set) var isClosed = false
    private var autoRetryScheduled = false
    /// True while a catalog load is on the engine: no overlapping loads.
    private var loadInFlight = false
    /// Guards the single whenIdle re-pump of the thumbnail queue.
    private var thumbnailPumpScheduled = false
    private var updatingTable = false

    let view: NSView
    private let searchField = NSSearchField()
    private let table = NSTableView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    init(document: ImageDocument, currentIdentity: EngineSession.ResourceIdentity?) {
        self.document = document
        self.model = PatternChooserModel(currentIdentity: currentIdentity)
        self.view = NSView()
        super.init()
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

        for subview in [searchField, scroll, statusLabel] as [NSView] {
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
            statusLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 4),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    // MARK: Catalog load (off the main thread, through the engine gate)

    /// Starts the one catalog load; call when the picker becomes visible.
    /// Every pattern's name and identity are read — the list is never
    /// capped — while thumbnails stay lazy. A refused admission (gate
    /// busy) shows the busy state and retries once when the engine idles.
    func load() {
        guard !isClosed, !loadInFlight, let session = document?.session else { return }
        // Switching fill sources keeps the explicit pending choice and
        // its previews. A fresh catalog is loaded when a new sheet opens.
        if case .ready = model.state { return }
        loadInFlight = true
        let generation = model.generation
        let current = model.currentIdentity
        var outRows: [PatternRow] = []
        var resolvedCurrent: EngineSession.ResourceID?
        var resolutionError: EngineSession.EngineError?
        var outError: String?
        let accepted = EngineActivity.shared.perform(label: "Loading patterns", work: {
            do {
                for row in try session.resources(.pattern) {
                    let identity = try session.resourceIdentifiers(row.id)
                    outRows.append(PatternRow(id: row.id, name: row.displayName, identity: identity))
                }
                if let current {
                    do {
                        resolvedCurrent = try session.resolveResource(current, kind: .pattern)
                    } catch {
                        // Only NOT_FOUND means the pattern is really gone;
                        // any other failure is reported distinctly, never
                        // as "missing" (the model checks the status).
                        resolutionError = (error as? EngineSession.EngineError)
                            ?? EngineSession.EngineError(status: 0, message: String(describing: error))
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

    private func deliver(generation: Int, rows: [PatternRow],
                         resolvedCurrent: EngineSession.ResourceID?,
                         resolutionError: EngineSession.EngineError?, error: String?) {
        // Stale delivery: the sheet (or its document) closed meanwhile.
        guard !isClosed, generation == model.generation else { return }
        guard let document, !document.isClosing else {
            invalidate()
            return
        }
        guard model.deliver(generation: generation, rows: rows, resolvedCurrent: resolvedCurrent,
                            resolutionError: resolutionError, error: error) else { return }
        // Prime the lazy thumbnail queue: the resolved current pattern
        // first, then only the initial visible batch — the rest render as
        // rows scroll into view.
        if let resolvedCurrent {
            model.thumbnailQueue.request([resolvedCurrent], priority: true)
        }
        model.thumbnailQueue.request(visibleRows.prefix(PatternThumbnailQueue.batchSize).map { $0.id })
        pumpThumbnails()
        refresh()
    }

    // MARK: Lazy thumbnails (bounded native batches, off the main thread)

    /// Starts one bounded native thumbnail batch when the queue has
    /// pending ids and no batch is in flight. A refused batch (gate busy)
    /// is requeued and re-pumped once when the engine goes idle.
    private func pumpThumbnails() {
        guard !isClosed, case .ready = model.state else { return }
        let queue = model.thumbnailQueue
        guard queue.pendingCount > 0, queue.inFlightCount == 0 else { return }
        let batch = queue.beginBatch()
        guard !batch.isEmpty, let session = document?.session else {
            queue.requeue(batch)
            return
        }
        let generation = model.generation
        var rendered: [EngineSession.ResourceID: CGImage] = [:]
        var failed: [EngineSession.ResourceID: String] = [:]
        let accepted = EngineActivity.shared.perform(label: "Rendering pattern previews", work: {
            // One bounded batch; a single bad thumbnail fails only its own
            // entry and is cached as failed by the queue (never retried).
            for id in batch {
                do {
                    rendered[id] = try session.resourceThumbnail(id, maxSize: 32).image
                } catch {
                    failed[id] = ((error as? EngineSession.EngineError)?.message) ?? String(describing: error)
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
        // Stale delivery: the sheet (or its document) closed meanwhile.
        guard !isClosed, generation == model.generation else { return }
        guard let document, !document.isClosing else {
            invalidate()
            return
        }
        guard model.deliverThumbnails(generation: generation, rendered: rendered, failed: failed) else { return }
        // Rows without a preview yet stay placeholders; reloading re-enters
        // viewFor, which re-requests them (deduplicated by the queue).
        reloadTable(scrollToSelection: false)
        pumpThumbnails()
    }

    // MARK: Display

    private var visibleRows: [PatternRow] { model.rows(matching: model.query) }

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
            model.thumbnailQueue.request([item.id])
            pumpThumbnails()
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
    }

    // MARK: Search

    func controlTextDidChange(_ notification: Notification) {
        model.setQuery(searchField.stringValue)
        refresh()
    }

    // MARK: Close

    /// The sheet ended: no in-flight native result may touch this stale
    /// view again. Idempotent.
    func invalidate() {
        guard !isClosed else { return }
        isClosed = true
        model.invalidate()
    }
}
