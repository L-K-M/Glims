import CoreGraphics
import Foundation

/// One row of the brush chooser's list: the engine's display name, the
/// session-local handle (in memory only, never persisted) and the
/// persistent identity a pick commits.
struct BrushRow: Equatable {
    let id: EngineSession.ResourceID
    let name: String
    let identity: EngineSession.ResourceIdentity
}

/// What the chooser list has highlighted: nothing yet, the native Default
/// brush (nil identity), or one catalog row.
enum BrushSelection: Equatable {
    case none
    case nativeDefault
    case resource(EngineSession.ResourceID)
}

/// The state of the chooser's catalog load.
enum BrushChooserState: Equatable {
    case loading
    /// The exclusive engine gate was held by another activity; the load
    /// has not run. The panel shows this and offers one retry.
    case busy
    case ready
    case error(String)
}

/// The pure, UI-free model of the one brush chooser: the tool captured at
/// open, the FULL loaded catalog (every brush, never truncated) and its
/// lazily rendered thumbnails, the search filter and the pending selection.
/// Applying writes ONLY the captured tool's `ToolState` brush resource, so
/// switching tools while the chooser is open never retargets the selection;
/// cancel applies nothing and preserves the previous choice.
///
/// `generation` invalidates in-flight native results: closing the picker
/// (or the document/parent going away) bumps it, and a late delivery whose
/// generation no longer matches is dropped without touching any view.
final class BrushChooserModel {
    /// The paint tool whose brush this chooser edits, captured at open.
    let capturedTool: ToolID
    /// The identity chosen when the chooser opened (nil = native default).
    let currentIdentity: EngineSession.ResourceIdentity?

    /// The lazy thumbnail pipeline; driven by the panel with bounded native
    /// batches. Invalidated together with `generation`.
    let thumbnailQueue = BrushThumbnailQueue()

    private(set) var state: BrushChooserState = .loading
    private(set) var rows: [BrushRow] = []
    private(set) var thumbnails: [EngineSession.ResourceID: CGImage] = [:]
    private(set) var selection: BrushSelection = .none
    /// Set only when native resolution returned NOT_FOUND: shown visibly,
    /// never silently replaced by the default (beginStroke reports it).
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

    init(capturedTool: ToolID, currentIdentity: EngineSession.ResourceIdentity?) {
        self.capturedTool = capturedTool
        self.currentIdentity = currentIdentity
    }

    /// Drops every in-flight result: the next delivery checks its captured
    /// generation against this and is discarded when they differ.
    func invalidate() {
        generation += 1
        thumbnailQueue.invalidate()
    }

    func setLoading(_ state: BrushChooserState) {
        self.state = state
    }

    /// Replaces the loaded catalog with the FULL list of engine brushes.
    /// Returns false — changing nothing — when `generation` is stale, i.e.
    /// the picker closed (or its document went away) after the batch
    /// started, so late native results are dropped.
    ///
    /// `resolvedCurrent`/`resolutionError` describe how the engine resolved
    /// the persisted current identity: a non-nil `resolvedCurrent` is valid
    /// even when its row is not among `rows` (never marked missing, never
    /// reset to Default); `resolutionError` marks the choice missing only
    /// when it is NOT_FOUND, and is shown distinctly otherwise. A nil
    /// `resolvedCurrent` with a nil `resolutionError` is the legacy
    /// NOT_FOUND form.
    @discardableResult
    func deliver(generation: Int, rows: [BrushRow], thumbnails: [EngineSession.ResourceID: CGImage],
                 resolvedCurrent: EngineSession.ResourceID?,
                 resolutionError: EngineSession.EngineError? = nil,
                 error: String?) -> Bool {
        guard generation == self.generation else { return false }
        if let error {
            state = .error(error)
            return true
        }
        self.rows = rows
        for (id, image) in thumbnails { self.thumbnails[id] = image }
        state = .ready
        // Arm the lazy thumbnail queue for this catalog generation.
        thumbnailQueue.begin(generation: generation)
        if let currentIdentity {
            if let resolvedCurrent {
                // The engine resolved the persisted identity: the choice is
                // valid even outside the loaded rows.
                self.resolvedCurrentID = resolvedCurrent
                missingIdentity = nil
                self.resolutionError = nil
                selection = rows.contains(where: { $0.id == resolvedCurrent })
                    ? .resource(resolvedCurrent) : .none
            } else if let resolutionError, !resolutionError.isNotFound {
                // A failure other than NOT_FOUND: not "missing"; the
                // current choice is preserved unchanged.
                self.resolvedCurrentID = nil
                missingIdentity = nil
                self.resolutionError = resolutionError.message
                selection = .none
            } else {
                // NOT_FOUND (or the legacy nil/nil form): the resource is
                // really gone — show it and let the user reset or rechoose.
                self.resolvedCurrentID = nil
                missingIdentity = currentIdentity
                self.resolutionError = nil
                selection = .none
            }
        } else {
            resolvedCurrentID = nil
            missingIdentity = nil
            self.resolutionError = nil
            selection = .nativeDefault
        }
        return true
    }

    /// Merges one lazy thumbnail batch into the cache. Returns false —
    /// changing nothing — on a stale generation or when the catalog is not
    /// ready, so results arriving after the panel closed are dropped.
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
    func rows(matching query: String) -> [BrushRow] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return rows }
        return rows.filter { $0.name.lowercased().contains(needle) }
    }

    func setQuery(_ query: String) {
        self.query = query
    }

    func select(_ selection: BrushSelection) {
        self.selection = selection
    }

    /// The identity the chooser would commit right now: the selected row's
    /// identity, nil for the native Default, or — with no row highlighted,
    /// or a highlighted row absent from the loaded rows — the unchanged
    /// current identity (applying is then a no-op, never a reset to
    /// Default).
    func pendingIdentity() -> EngineSession.ResourceIdentity? {
        switch selection {
        case .none: return currentIdentity
        case .nativeDefault: return nil
        case .resource(let id): return rows.first { $0.id == id }?.identity ?? currentIdentity
        }
    }

    /// The thumbnail of `id`, if one has been rendered yet.
    func thumbnail(_ id: EngineSession.ResourceID) -> CGImage? {
        thumbnails[id]
    }
}
