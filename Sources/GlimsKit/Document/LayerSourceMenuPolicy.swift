import Foundation

/// Cached-state gating for Layer ▸ Rasterize Layer… and Layer ▸ Restore
/// Layer Source…. Pure functions over the document's cached `layerSources`,
/// `layerLocks` and paint-target state, so menu validation and the
/// confirmation sheet never run a synchronous native call.
enum LayerSourceMenuPolicy {
    enum Command {
        case rasterize, restore
    }

    /// Whether `command` may be offered on a layer right now, from cached
    /// state only. `source` and `locks` are the document's cached entries
    /// for the layer id (`nil` for a layer the last reload never saw);
    /// `targetIsLayer` is false while a mask or a channel is the paint
    /// target; `stateBlocked` covers the caller-composed closing, busy,
    /// plug-in, engine-activity, pending-target-command, filter-preview
    /// and attached-sheet states.
    ///
    /// Rasterize is offered only on genuine text, link or vector content
    /// whose source is retained and not yet pixel-behaving; Restore only
    /// on a rasterized layer whose source survived. Ordinary pixels and
    /// groups offer neither. Inherited PIXELS or POSITION locks (a parent
    /// group's included) hide the engine's LOCKED refusal.
    static func isEnabled(_ command: Command,
                          source: EngineSession.LayerSource?,
                          locks: EngineSession.LayerLockState?,
                          targetIsLayer: Bool,
                          stateBlocked: Bool) -> Bool {
        guard !stateBlocked, targetIsLayer, let source else { return false }
        switch command {
        case .rasterize:
            guard source.hasSource, !source.isRasterized,
                  source.kind == .text || source.kind == .link || source.kind == .vector else {
                return false
            }
        case .restore:
            guard source.hasSource, source.isRasterized else { return false }
        }
        return locks?.effective.isDisjoint(with: [.pixels, .position]) != false
    }
}
