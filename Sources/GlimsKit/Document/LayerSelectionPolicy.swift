import Foundation

/// The multi-layer selection policy, as pure functions over cached layer
/// ids. The document, the Layers palette and the menus all share this one
/// definition, so the primary-layer rule and the command gates can be
/// pinned by unit tests without a UI.
///
/// The selection is an ordered id list with the **primary layer first**.
/// The engine keeps the first selected layer active
/// (`image_selected_layers` read-back order is the order written), so
/// primary-first order is what the document writes through
/// `selectLayers(_:image:)` and what every single-layer command acts on.
enum LayerSelectionPolicy {
    /// The primary layer of an ordered selection: the first id.
    static func primary(of ids: [Int32]) -> Int32? { ids.first }

    /// Whether `count` selected layers gate single-layer commands.
    static func isMulti(_ count: Int) -> Bool { count > 1 }

    /// The actionable refusal for a single-layer command while `count`
    /// layers are selected, or nil for a single selection.
    static func refusal(count: Int, action: String) -> String? {
        guard count > 1 else { return nil }
        return "Choose one layer first: \(action) works on a single layer, and \(count) layers are selected."
    }

    /// Whether `command` is a single-layer command that a multi-selection
    /// gates. `.new` is not: it creates a fresh row the engine selects,
    /// which is safe under a multi-selection.
    static func gates(_ command: EngineSession.LayerCommand) -> Bool {
        command != .new
    }

    /// The menu title a gated layer command refuses with.
    static func actionTitle(for command: EngineSession.LayerCommand) -> String {
        switch command {
        case .new: return "New Layer"
        case .duplicate: return "Duplicate Layer"
        case .delete: return "Delete Layer"
        case .raise: return "Bring Forward"
        case .lower: return "Send Backward"
        case .toTop: return "Bring to Front"
        case .toBottom: return "Send to Back"
        case .mergeDown: return "Merge Down"
        case .flatten: return "Flatten Image"
        case .fitToImage: return "Layer to Image Size"
        case .trimToContent: return "Trim Layer to Content"
        case .rasterize: return "Rasterize Layer"
        case .restoreSource: return "Restore Layer Source"
        }
    }

    /// Reconciles a selection — the engine's read-back or a mirrored
    /// pick — against the layer ids that still exist: stale ids and
    /// duplicates drop out, the order (primary first) is kept.
    static func reconcile(_ ids: [Int32], existing: Set<Int32>) -> [Int32] {
        var seen = Set<Int32>()
        var result: [Int32] = []
        for id in ids where id != 0 && existing.contains(id) && seen.insert(id).inserted {
            result.append(id)
        }
        return result
    }

    /// The ordered selection after a user selection gesture. `rowIDs`
    /// are the layer ids of the outline's selected rows in row order
    /// (top first); `previous` is the selection that stood before it,
    /// primary first.
    ///
    /// Policy: the row the gesture added last becomes the primary — the
    /// row the user just clicked is the one single-layer commands act
    /// on — and the remaining selected rows follow in row order. A
    /// gesture that only removed rows keeps the previous primary unless
    /// it was the row removed, in which case the topmost remaining row
    /// takes over. An empty `rowIDs` is a refusal (nil), never a
    /// selection: the palette restores the native selection instead of
    /// clearing it.
    static func resolveSelection(previous: [Int32], rowIDs: [Int32]) -> [Int32]? {
        guard !rowIDs.isEmpty else { return nil }
        let previousSet = Set(previous)
        let currentSet = Set(rowIDs)
        let added = rowIDs.filter { !previousSet.contains($0) }
        let primary: Int32
        if let lastAdded = added.last {
            primary = lastAdded
        } else if let first = previous.first, currentSet.contains(first) {
            primary = first
        } else {
            primary = rowIDs[0]
        }
        return [primary] + rowIDs.filter { $0 != primary }
    }
}
