import Foundation

/// The structural preconditions of Layer > Group with Previous, Ungroup
/// and Merge Group as a pure function over the cached layer rows and their
/// clipping roles. `ImageDocument.clippingRefusal` adds the document gates
/// (slot support, layout, busy, floating selection, single selection)
/// around this, so the rules are pinned by unit tests without a document
/// or an engine.
enum ClippingCommandRules {
    /// Why `command` cannot run on `layerID`, or nil. `layers` is the
    /// document's cached tree in the engine's top-first, depth-first
    /// order; filtering it by parent keeps a sibling's order.
    static func refusal(command: EngineSession.ClippingCommand,
                        layerID: Int32,
                        layers: [EngineSession.Layer]) -> String? {
        guard let layer = layers.first(where: { $0.id == layerID }) else {
            return "Select a layer first."
        }
        let siblings = layers.filter { $0.parent == layer.parent }

        switch command {
        case .groupWithPrevious:
            guard layer.kind == .pixel else {
                return layer.kind == .group
                    ? "A layer group cannot be clipped."
                    : "Rasterize the \(layer.kind) layer before clipping it."
            }
            guard layer.clipping.role != .clipped else {
                return "The layer is already clipped."
            }
            guard let index = siblings.firstIndex(where: { $0.id == layerID }),
                  index + 1 < siblings.count else {
                return "There is no layer below to clip to."
            }
            let below = siblings[index + 1]
            // Directly above a clipping group, the layer joins that group
            // above its top clipped layer, as the engine does.
            if below.kind == .group && below.clipping.role == .group { return nil }
            guard below.kind == .pixel else {
                return below.kind == .group
                    ? "The layer below must be a pixel layer or a clipping group."
                    : "Rasterize the layer below before clipping to it."
            }
            return nil
        case .ungroup:
            switch layer.clipping.role {
            case .base, .clipped, .group:
                return ungroupDissolveRefusal(layer: layer, layers: layers)
            case .none: return "Choose a clipping group, its base or one of its clipped layers."
            }
        case .mergeGroup:
            switch layer.clipping.role {
            case .base, .clipped, .group: return nil
            case .none: return "Choose a clipping group or one of its layers."
            }
        }
    }

    /// The engine's Ungroup refuses when the release would dissolve the
    /// group while it still holds a layer that is not clipped, since that
    /// layer would go with it. Ungroup of the group or its base releases
    /// every clipped layer; Ungroup of a clipped layer releases it and
    /// those above it, so the group survives while a clipped layer remains
    /// below it.
    private static func ungroupDissolveRefusal(layer: EngineSession.Layer,
                                               layers: [EngineSession.Layer]) -> String? {
        let members = layers.filter {
            $0.parent == layer.clipping.group && $0.id != layer.clipping.base
        }
        if layer.clipping.role == .clipped,
           let index = members.firstIndex(where: { $0.id == layer.id }),
           members[(index + 1)...].contains(where: { $0.clipping.role == .clipped }) {
            return nil
        }
        guard members.contains(where: { $0.clipping.role != .clipped }) else { return nil }
        return "The clipping group has layers that are not clipped to its base."
    }
}
