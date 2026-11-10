import Foundation

/// Cached admission for explicit retained-source restore vectors. Native code
/// repeats admission after queued input; neither menu nor sheet validation
/// calls it.
enum LayerRestorePolicy {
    enum Request {
        /// A confirmed explicit command may become an all-no-op request.
        case explicitCommand
        /// Offer consent only when at least one member is actually rasterized.
        case confirmation
    }

    static func refusal(ids: [Int32], layerIDs: Set<Int32>,
                        sources: [Int32: EngineSession.LayerSource],
                        locks: [Int32: EngineSession.LayerLockState],
                        request: Request) -> String? {
        guard !ids.isEmpty else { return "Select the layers to restore." }
        guard ids.count <= 256 else { return "Restore at most 256 layers together." }
        guard ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else {
            return "Refresh the layer selection before restoring."
        }
        var hasRasterizedSource = false
        for id in ids {
            guard layerIDs.contains(id), let source = sources[id], let state = locks[id] else {
                return "Refresh the layer state before restoring."
            }
            guard source.hasSource,
                  source.kind == .text || source.kind == .link || source.kind == .vector else {
                return "Select layers with retained text, link or vector sources; select the layers inside a group."
            }
            guard state.effective.isDisjoint(with: [.pixels, .position]) else {
                return "Unlock pixels and position on every selected layer and its parent groups."
            }
            hasRasterizedSource = hasRasterizedSource || source.isRasterized
        }
        if case .confirmation = request, !hasRasterizedSource {
            return "The selected layers are already editable."
        }
        return nil
    }
}
