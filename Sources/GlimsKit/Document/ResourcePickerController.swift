import AppKit
import CoreGraphics

/// Drives one `ResourceChooserModel`'s catalog load and lazy thumbnail
/// batches. Every engine read — `resources`, `resource_identifiers`,
/// `resource_resolve` and `resourceThumbnail` — is a synchronous RPC and
/// runs OFF the main thread through the global exclusive `EngineActivity`
/// gate; this controller admits them on the main actor and delivers the
/// results back on it. The document is captured at creation, so a retarget
/// cannot redirect a load.
///
/// Close-generation invalidation: `invalidate()` bumps the model's
/// generation, so a late native delivery is dropped without touching the
/// owner. When the captured document is closing, deliveries abandon the
/// owner through `onAbandoned`. There is never more than one catalog load
/// or one thumbnail batch in flight, a refused admission is retried once
/// when the engine idles, and failed thumbnail attempts are cached for the
/// generation — never retried unboundedly.
///
/// The owner (an embedded picker view or an owned panel) supplies the
/// callbacks that refresh its views; this controller owns no AppKit views.
@MainActor
final class ResourcePickerController {
    let model: ResourceChooserModel
    private weak var document: ImageDocument?
    private(set) var isClosed = false
    private var autoRetryScheduled = false
    /// True while a catalog load is on the engine: no overlapping loads.
    private var loadInFlight = false
    /// Guards the single whenIdle re-pump of the thumbnail queue.
    private var thumbnailPumpScheduled = false

    /// When true, an already-ready catalog is not loaded again (the
    /// embedded pattern picker loads once per sheet); a fresh chooser
    /// (false) loads again, e.g. from its Retry button.
    var loadOnlyOnce = false
    /// Recolor inputs for thumbnails — brushes and gradients with
    /// foreground/background segments preview with explicit colors,
    /// patterns render without them. Evaluated on the main actor right
    /// before each native batch, so no mutable state crosses into the
    /// worker closure.
    var thumbnailColors: (() -> (foreground: NSColor, background: NSColor)?)?
    /// The model's visible state changed (busy, error, delivered).
    var onChange: (() -> Void)?
    /// A catalog delivery landed (ready or error).
    var onCatalogDelivered: (() -> Void)?
    /// One thumbnail batch was merged into the model.
    var onThumbnailsDelivered: (() -> Void)?
    /// The captured document closed or went away mid-flight.
    var onAbandoned: (() -> Void)?

    init(document: ImageDocument?, model: ResourceChooserModel) {
        self.document = document
        self.model = model
    }

    // MARK: Catalog load (off the main thread, through the engine gate)

    /// Starts the one catalog load. Every resource's name and identity are
    /// read — the list is never capped — while thumbnails stay lazy. A
    /// refused admission (gate busy) shows the busy state and retries once
    /// when the engine idles.
    func load() {
        guard !isClosed, !loadInFlight, let session = document?.session else { return }
        if loadOnlyOnce, case .ready = model.state { return }
        loadInFlight = true
        let generation = model.generation
        let kind = model.kind
        let current = model.currentIdentity
        var outRows: [ResourceRow] = []
        var resolvedCurrent: EngineSession.ResourceID?
        var resolutionError: EngineSession.EngineError?
        var outError: String?
        let accepted = EngineActivity.shared.perform(label: "Loading \(kind.catalogNoun)", work: {
            do {
                for row in try session.resources(kind) {
                    let identity = try session.resourceIdentifiers(row.id)
                    outRows.append(ResourceRow(id: row.id, name: row.displayName, identity: identity))
                }
                if let current {
                    do {
                        resolvedCurrent = try session.resolveResource(current, kind: kind)
                    } catch {
                        // Only NOT_FOUND means the resource is really gone;
                        // any other failure is reported distinctly, never
                        // as "missing" (the model checks the status).
                        resolutionError = EngineSession.EngineError.coerce(error)
                    }
                }
            } catch {
                outError = EngineSession.EngineError.coerce(error).message
            }
        }, completion: { [weak self] in
            self?.loadInFlight = false
            self?.deliver(generation: generation, rows: outRows, resolvedCurrent: resolvedCurrent,
                          resolutionError: resolutionError, error: outError)
        })
        if !accepted {
            loadInFlight = false
            model.setLoading(.busy)
            onChange?()
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

    private func deliver(generation: Int, rows: [ResourceRow],
                         resolvedCurrent: EngineSession.ResourceID?,
                         resolutionError: EngineSession.EngineError?, error: String?) {
        // Stale delivery: the picker (or its document) closed meanwhile.
        guard !isClosed, generation == model.generation else { return }
        guard let document, !document.isClosing else {
            onAbandoned?()
            return
        }
        guard model.deliver(generation: generation, rows: rows, resolvedCurrent: resolvedCurrent,
                            resolutionError: resolutionError, error: error) else { return }
        // Prime the lazy thumbnail queue: the resolved current resource
        // first, then only the initial visible batch — the rest render as
        // rows scroll into view.
        if case .ready = model.state {
            if let resolvedCurrent {
                model.thumbnailQueue.request([resolvedCurrent], priority: true)
            }
            model.thumbnailQueue.request(
                model.rows(matching: model.query).prefix(ResourceThumbnailQueue.batchSize).map { $0.id })
        }
        pumpThumbnails()
        onCatalogDelivered?()
    }

    // MARK: Lazy thumbnails (bounded native batches, off the main thread)

    /// Enqueues ids for lazy rendering (deduplicated by the queue) and
    /// starts a batch if none is in flight.
    func requestThumbnails(_ ids: [EngineSession.ResourceID], priority: Bool = false) {
        model.thumbnailQueue.request(ids, priority: priority)
        pumpThumbnails()
    }

    /// Starts one bounded native thumbnail batch when the queue has
    /// pending ids and no batch is in flight. A refused batch (gate busy)
    /// is requeued and re-pumped once when the engine goes idle.
    func pumpThumbnails() {
        guard !isClosed, case .ready = model.state else { return }
        let queue = model.thumbnailQueue
        guard queue.pendingCount > 0, queue.inFlightCount == 0 else { return }
        let batch = queue.beginBatch()
        guard !batch.isEmpty, let session = document?.session else {
            queue.requeue(batch)
            return
        }
        let generation = model.generation
        // Plain values only: the model is main-actor state and must not be
        // captured by the worker closure.
        let colors = thumbnailColors?()
        var rendered: [EngineSession.ResourceID: CGImage] = [:]
        var failed: [EngineSession.ResourceID: String] = [:]
        let accepted = EngineActivity.shared.perform(label: "Rendering \(model.kind.singular) previews", work: {
            // One bounded batch; a single bad thumbnail fails only its own
            // entry and is cached as failed by the queue (never retried).
            for id in batch {
                do {
                    if let colors {
                        rendered[id] = try session.resourceThumbnail(id, maxSize: 32,
                                foreground: colors.foreground, background: colors.background).image
                    } else {
                        rendered[id] = try session.resourceThumbnail(id, maxSize: 32).image
                    }
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
        guard let document, !document.isClosing else {
            onAbandoned?()
            return
        }
        guard model.deliverThumbnails(generation: generation, rendered: rendered, failed: failed) else { return }
        onThumbnailsDelivered?()
        pumpThumbnails()
    }

    // MARK: Close

    /// The picker ended: no in-flight native result may touch the stale
    /// owner again. Idempotent.
    func invalidate() {
        guard !isClosed else { return }
        isClosed = true
        model.invalidate()
    }
}

/// The chooser list: Return/Enter commits, Escape cancels, and the first
/// click is accepted even when the panel is not key.
final class ResourcePickerTableView: NSTableView {
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
