import Foundation

/// The channel/path selection policy, as pure functions over the cached
/// ordered id lists the document keeps from the engine's slot-137
/// whole-list read-back. The document, the palettes and the Path tool all
/// share this one definition, so the single-target rules can be pinned by
/// unit tests without a UI.
///
/// Unlike layers, channels and paths have no "primary" semantics the
/// interface may lean on: with none or several selected there is no
/// single target, and nothing may silently fall back to the first
/// selected row, a remembered row or a label.
enum ItemSelectionPolicy {
    /// The one channel that is the paint/edit target: exactly one
    /// selected channel that still exists. None or several selected
    /// channels means no target (nil) — never the first selected row.
    static func channelTarget(_ ids: [Int32], existing: Set<Int32>) -> Int32? {
        guard ids.count == 1, let id = ids.first, existing.contains(id) else { return nil }
        return id
    }

    /// Whether any channel is selected, even when no single channel is
    /// the active target: with several selected the target-writing edits
    /// still refuse (a channel target is active, just ambiguous).
    static func isChannelTargetActive(_ ids: [Int32]) -> Bool { !ids.isEmpty }

    /// The path the Path tool edits and the palette commands use:
    /// exactly one selected path that still exists. None or several
    /// selected paths means no active path — never a stale remembered
    /// one.
    static func activePath(_ ids: [Int32], existing: Set<Int32>) -> Int32? {
        guard ids.count == 1, let id = ids.first, existing.contains(id) else { return nil }
        return id
    }

    /// Whether `count` selected items of `kind` make a single-item
    /// command ambiguous.
    static func isMulti(_ count: Int) -> Bool { count > 1 }

    /// The actionable refusal for a single-item command while `count`
    /// items of `kind` are selected, or nil for a single selection.
    /// Same shape as the layer policy's refusal, naming the kind.
    static func refusal(count: Int, kind: EngineSession.ItemSetKind, action: String) -> String? {
        guard count > 1 else { return nil }
        let what: String
        switch kind {
        case .layer: what = "layer"
        case .channel: what = "channel"
        case .path: what = "path"
        }
        return "Choose one \(what) first: \(action) works on a single \(what), and \(count) \(what)s are selected."
    }
}
