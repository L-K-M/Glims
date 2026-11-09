import CGlimsEngine
import CoreGraphics
import Foundation

/// One row of a resource chooser's catalog list: the engine's display name,
/// the session-local handle (in memory only, never persisted) and the
/// persistent identity a pick commits.
struct ResourceRow: Equatable {
    let id: EngineSession.ResourceID
    let name: String
    let identity: EngineSession.ResourceIdentity
}

/// The state of a resource chooser's catalog load.
enum ResourceChooserState: Equatable {
    case loading
    /// The exclusive engine gate was held by another activity; the load
    /// has not run. The picker shows this and retries once when idle.
    case busy
    case ready
    case error(String)
}

/// The pure, UI-free model of a resource chooser (brush, pattern or
/// gradient): the FULL loaded catalog (every resource, never truncated),
/// its lazily rendered thumbnails, the search filter and the pending
/// selection. Applying commits only a persistent `ResourceIdentity`; the
/// consumer resolves it fresh on the engine worker at execution, and a
/// removed resource is reported, never silently substituted.
///
/// `generation` invalidates in-flight native results: closing the picker
/// (or the document going away) bumps it, and a late delivery whose
/// generation no longer matches is dropped without touching any view.
final class ResourceChooserModel {
    /// The resource kind this chooser lists (`resources(_:)`,
    /// `resolveResource(_:kind:)`); the load runs with exactly this kind.
    let kind: EngineSession.ResourceKind
    /// The identity persisted when the chooser opened (nil = none chosen
    /// yet, or the chooser's own default).
    private(set) var currentIdentity: EngineSession.ResourceIdentity?

    /// The lazy thumbnail pipeline; driven by the picker with bounded
    /// native batches. Invalidated together with `generation`.
    let thumbnailQueue = ResourceThumbnailQueue()

    private(set) var state: ResourceChooserState = .loading
    private(set) var rows: [ResourceRow] = []
    private(set) var thumbnails: [EngineSession.ResourceID: CGImage] = [:]
    /// The highlighted row; `none` before any pick and while the choice
    /// resolves outside the loaded rows.
    private(set) var selection: EngineSession.ResourceID?
    /// Set only when native resolution returned NOT_FOUND: shown visibly,
    /// never silently replaced by another resource (the consumer is
    /// refused until the user picks a live one).
    private(set) var missingIdentity: EngineSession.ResourceIdentity?
    /// Set when resolving the current identity failed with anything other
    /// than NOT_FOUND (busy, engine error): reported distinctly, never as
    /// "missing"; the choice itself is preserved unchanged.
    private(set) var resolutionError: String?
    /// The handle the engine resolved the current identity to, if any.
    /// Valid even when its row is outside the loaded rows.
    private(set) var resolvedCurrentID: EngineSession.ResourceID?
    private(set) var query = ""
    private(set) var generation = 0

    init(kind: EngineSession.ResourceKind = .pattern, currentIdentity: EngineSession.ResourceIdentity?) {
        self.kind = kind
        self.currentIdentity = currentIdentity
    }

    /// Remaps the stored current identity only when it exactly equals `old`.
    /// Used by resource rename/mutation callbacks; no other model state,
    /// selection or generation semantics change.
    func remapIdentity(from old: EngineSession.ResourceIdentity,
                       to new: EngineSession.ResourceIdentity) {
        if currentIdentity == old {
            currentIdentity = new
        }
    }

    /// Drops every in-flight result: the next delivery checks its captured
    /// generation against this and is discarded when they differ.
    func invalidate() {
        generation += 1
        thumbnailQueue.invalidate()
    }

    func setLoading(_ state: ResourceChooserState) {
        self.state = state
    }

    /// Replaces the loaded catalog with the FULL list of engine resources of
    /// `kind`. Returns false — changing nothing — when `generation` is
    /// stale, i.e. the chooser closed after the load started, so late
    /// native results are dropped.
    ///
    /// `resolvedCurrent`/`resolutionError` describe how the engine
    /// resolved the persisted identity: a non-nil `resolvedCurrent` is
    /// valid even when its row is not among `rows`; `resolutionError`
    /// marks the choice missing only when it is NOT_FOUND, and is shown
    /// distinctly otherwise. A nil `resolvedCurrent` with a nil
    /// `resolutionError` is the plain NOT_FOUND form.
    @discardableResult
    func deliver(generation: Int, rows: [ResourceRow],
                 resolvedCurrent: EngineSession.ResourceID?,
                 resolutionError: EngineSession.EngineError? = nil,
                 error: String?) -> Bool {
        guard generation == self.generation else { return false }
        if let error {
            state = .error(error)
            return true
        }
        self.rows = rows
        state = .ready
        thumbnailQueue.begin(generation: generation)
        if let currentIdentity {
            if let resolvedCurrent {
                resolvedCurrentID = resolvedCurrent
                missingIdentity = nil
                self.resolutionError = nil
                selection = rows.contains(where: { $0.id == resolvedCurrent }) ? resolvedCurrent : nil
            } else if let resolutionError,
                      resolutionError.status != Int32(GLIMS_STATUS_NOT_FOUND.rawValue) {
                // A failure other than NOT_FOUND: not "missing"; the
                // current choice is preserved unchanged.
                resolvedCurrentID = nil
                missingIdentity = nil
                self.resolutionError = resolutionError.message
                selection = nil
            } else {
                // NOT_FOUND: the resource is really gone — show it and let
                // the user pick another; nothing is substituted.
                resolvedCurrentID = nil
                missingIdentity = currentIdentity
                self.resolutionError = nil
                selection = nil
            }
        } else {
            resolvedCurrentID = nil
            missingIdentity = nil
            self.resolutionError = nil
            selection = nil
        }
        return true
    }

    /// Merges one lazy thumbnail batch into the cache. Returns false —
    /// changing nothing — on a stale generation or when the catalog is
    /// not ready, so results arriving after the chooser closed are dropped.
    @discardableResult
    func deliverThumbnails(generation: Int, rendered: [EngineSession.ResourceID: CGImage],
                           failed: [EngineSession.ResourceID: String]) -> Bool {
        guard generation == self.generation, case .ready = state else { return false }
        guard thumbnailQueue.complete(generation: generation,
                                      rendered: Array(rendered.keys), failed: failed) else { return false }
        for (id, image) in rendered { thumbnails[id] = image }
        return true
    }

    /// In-memory search over the FULL loaded catalog: case-insensitive
    /// substring on the display name; an empty query returns every row.
    /// The catalog is never truncated, so every match is reported.
    func rows(matching query: String) -> [ResourceRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { $0.name.lowercased().contains(needle) }
    }

    func setQuery(_ query: String) {
        self.query = query
    }

    func select(_ id: EngineSession.ResourceID?) {
        selection = id
    }

    /// The identity a consumer would commit right now: the selected row's
    /// identity, or — with no row highlighted — the persisted identity
    /// only when it still resolves. A missing or unresolved choice
    /// returns nil: the consumer is refused, never substituted.
    func pendingIdentity() -> EngineSession.ResourceIdentity? {
        if let selection, let row = rows.first(where: { $0.id == selection }) {
            return row.identity
        }
        return resolvedCurrentID != nil ? currentIdentity : nil
    }

    /// The thumbnail of `id`, if one has been rendered yet.
    func thumbnail(_ id: EngineSession.ResourceID) -> CGImage? {
        thumbnails[id]
    }
}

/// The resource chooser's lazy thumbnail pipeline. Pure bookkeeping — it
/// never touches the engine or AppKit: which catalog rows still need a
/// native render, which batch is in flight, and which attempts finished.
/// Both succeeded and failed attempts are cached for the current
/// generation, so a single bad thumbnail is never retried and never
/// disturbs the rest of the catalog. The picker drives the queue with
/// small bounded native batches through the global engine gate.
final class ResourceThumbnailQueue {
    enum Status: Equatable {
        case pending
        case inFlight
        case rendered
        case failed(String)
    }

    /// One native batch renders at most this many thumbnails, so a huge
    /// catalog is previewed incrementally as rows appear, never eagerly.
    static let batchSize = 32

    private(set) var generation = 0
    private var order: [EngineSession.ResourceID] = []
    private var status: [EngineSession.ResourceID: Status] = [:]

    var pendingCount: Int { order.count }
    var inFlightCount: Int { status.values.reduce(0) { count, entry in
        if case .inFlight = entry { return count + 1 }
        return count
    } }
    /// Nothing left to render and nothing on the engine.
    var isIdle: Bool { order.isEmpty && inFlightCount == 0 }

    /// Arms the queue for a fresh catalog delivery: drops every previous
    /// attempt cache and adopts `generation`.
    func begin(generation: Int) {
        self.generation = generation
        order.removeAll()
        status.removeAll()
    }

    /// Closing the chooser invalidates everything; a late native batch is
    /// dropped by the generation check in `complete`.
    func invalidate() {
        generation += 1
        order.removeAll()
        status.removeAll()
    }

    /// Enqueues ids never requested this generation; duplicates (already
    /// pending, in flight, rendered or failed) are ignored. `priority`
    /// ids (the resolved current resource) jump to the front of the queue.
    /// Returns how many ids were newly enqueued.
    @discardableResult
    func request(_ ids: [EngineSession.ResourceID], priority: Bool = false) -> Int {
        var added = 0
        for id in ids where status[id] == nil {
            status[id] = .pending
            if priority { order.insert(id, at: 0) } else { order.append(id) }
            added += 1
        }
        return added
    }

    /// Takes the next bounded batch for a native render and marks it in
    /// flight. Returns [] while a previous batch is still in flight (no
    /// overlapping batches) or when nothing is pending.
    func beginBatch(max: Int = batchSize) -> [EngineSession.ResourceID] {
        guard inFlightCount == 0, !order.isEmpty else { return [] }
        let count = min(max, order.count)
        let batch = Array(order.prefix(count))
        order.removeFirst(count)
        for id in batch { status[id] = .inFlight }
        return batch
    }

    /// Returns a refused batch (the engine gate was busy) to the front of
    /// the pending queue, preserving its order.
    func requeue(_ ids: [EngineSession.ResourceID]) {
        for id in ids.reversed() {
            guard case .inFlight = status[id] else { continue }
            status[id] = .pending
            order.insert(id, at: 0)
        }
    }

    /// Records one native batch's outcome. Returns false — changing
    /// nothing — when `generation` is stale (the chooser closed meanwhile).
    /// Rendered and failed ids are cached; neither is ever requested
    /// again this generation.
    @discardableResult
    func complete(generation: Int, rendered: [EngineSession.ResourceID],
                  failed: [EngineSession.ResourceID: String]) -> Bool {
        guard generation == self.generation else { return false }
        for id in rendered where isInFlight(id) { status[id] = .rendered }
        for (id, message) in failed where isInFlight(id) { status[id] = .failed(message) }
        return true
    }

    func status(of id: EngineSession.ResourceID) -> Status? { status[id] }

    private func isInFlight(_ id: EngineSession.ResourceID) -> Bool {
        guard let entry = status[id] else { return false }
        if case .inFlight = entry { return true }
        return false
    }
}

// MARK: Resource-kind labels

extension EngineSession.ResourceKind {
    /// Singular noun, for activity labels ("Loading patterns").
    var singular: String {
        switch self {
        case .brush: return "brush"
        case .pattern: return "pattern"
        case .gradient: return "gradient"
        }
    }

    /// Plural noun, for activity labels and status lines.
    var catalogNoun: String {
        switch self {
        case .brush: return "brushes"
        case .pattern: return "patterns"
        case .gradient: return "gradients"
        }
    }
}

// MARK: Pattern compatibility aliases

/// The Fill sheet's pattern picker used these names before the model was
/// parameterized by resource kind; they keep that code (and its tests)
/// compiling unchanged.
typealias PatternRow = ResourceRow
typealias PatternChooserState = ResourceChooserState
typealias PatternChooserModel = ResourceChooserModel
typealias PatternThumbnailQueue = ResourceThumbnailQueue
