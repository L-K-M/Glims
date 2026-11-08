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

/// The state of the chooser's one bounded catalog load.
enum BrushChooserState: Equatable {
    case loading
    /// The exclusive engine gate was held by another activity; the load
    /// has not run. The panel shows this and offers one retry.
    case busy
    case ready
    case error(String)
}

/// The pure, UI-free model of the one brush chooser: the tool captured at
/// open, the loaded rows and thumbnails, the search filter and the pending
/// selection. Applying writes ONLY the captured tool's `ToolState` brush
/// resource, so switching tools while the chooser is open never retargets
/// the selection; cancel applies nothing and preserves the previous choice.
///
/// `generation` invalidates in-flight native results: closing the picker
/// (or the document/parent going away) bumps it, and a late delivery whose
/// generation no longer matches is dropped without touching any view.
final class BrushChooserModel {
    /// The chooser never lists more than this many resources; the pinned
    /// runtime ships 58 brushes, so this bounds one batch well above the
    /// stock catalog without letting a huge user brush folder stall the
    /// engine gate for long.
    static let maxResources = 512

    /// The paint tool whose brush this chooser edits, captured at open.
    let capturedTool: ToolID
    /// The identity chosen when the chooser opened (nil = native default).
    let currentIdentity: EngineSession.ResourceIdentity?

    private(set) var state: BrushChooserState = .loading
    private(set) var rows: [BrushRow] = []
    private(set) var thumbnails: [EngineSession.ResourceID: CGImage] = [:]
    private(set) var selection: BrushSelection = .none
    /// Set when the persisted identity did not resolve: shown visibly,
    /// never silently replaced by the default (beginStroke reports it).
    private(set) var missingIdentity: EngineSession.ResourceIdentity?
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
    }

    func setLoading(_ state: BrushChooserState) {
        self.state = state
    }

    /// Replaces the loaded catalog. Returns false — changing nothing — when
    /// `generation` is stale, i.e. the picker closed (or its document went
    /// away) after the batch started, so late native results are dropped.
    @discardableResult
    func deliver(generation: Int, rows: [BrushRow], thumbnails: [EngineSession.ResourceID: CGImage],
                 resolvedCurrent: EngineSession.ResourceID?, error: String?) -> Bool {
        guard generation == self.generation else { return false }
        if let error {
            state = .error(error)
            return true
        }
        self.rows = rows
        self.thumbnails = thumbnails
        state = .ready
        if let currentIdentity {
            if let resolvedCurrent, rows.contains(where: { $0.id == resolvedCurrent }) {
                selection = .resource(resolvedCurrent)
            } else {
                // The persisted choice is missing from this engine: show
                // it and let the user reset or rechoose.
                missingIdentity = currentIdentity
                selection = .none
            }
        } else {
            selection = .nativeDefault
        }
        return true
    }

    /// In-memory search over the loaded rows: case-insensitive substring on
    /// the display name; an empty query returns every row.
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
    /// identity, nil for the native Default, or — with no row highlighted —
    /// the unchanged current identity (applying is then a no-op).
    func pendingIdentity() -> EngineSession.ResourceIdentity? {
        switch selection {
        case .none: return currentIdentity
        case .nativeDefault: return nil
        case .resource(let id): return rows.first { $0.id == id }?.identity
        }
    }

    /// The thumbnail of `id`, if the batch rendered one.
    func thumbnail(_ id: EngineSession.ResourceID) -> CGImage? {
        thumbnails[id]
    }
}
