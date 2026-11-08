import Foundation

/// Rows stay bound to their displayed items while a rename defers
/// reloads. Resolving through the live engine list during that interval
/// could select another layer after a reorder, or crash after deletion.
struct LayerListSnapshot {
    let document: AnyObject?
    let tree: LayerTree
    /// Each layer's effect rows by layer id, built once for the
    /// snapshot's lifetime — same staleness argument as the tree.
    private let effectItems: [Int32: [EffectItem]]

    init(document: AnyObject?, layers: [EngineSession.Layer],
         effects: [Int32: [EngineSession.Effect]] = [:]) {
        self.document = document
        self.tree = LayerTree(layers: layers)
        var items: [Int32: [EffectItem]] = [:]
        if let document {
            for (id, effects) in effects where !effects.isEmpty {
                items[id] = effects.map { EffectItem(document: document, drawable: id, effect: $0) }
            }
        }
        self.effectItems = items
    }

    /// The effect rows `node` shows ahead of its layer children, top first.
    func effects(of node: LayerTree.Node) -> [EffectItem] {
        effectItems[node.id] ?? []
    }

    /// `node`'s displayed children: its committed effect rows first,
    /// then (for a group) its layer children.
    func displayedChildren(of node: LayerTree.Node) -> [Any] {
        effects(of: node) + node.children
    }

    /// `index` among a parent's displayed children counts its effect
    /// rows first; this is the position among its layer children, or nil
    /// when the index is inside the effect prefix — where a layer drop
    /// is refused.
    static func layerChildIndex(forDisplayedIndex index: Int, effectCount: Int) -> Int? {
        index >= effectCount ? index - effectCount : nil
    }

    /// The layer an outline item still shows: only while the snapshot's
    /// document is the palette's target and the layer is still in it.
    /// `currentLayers` is the document's live list.
    func layer(for item: Any?, for currentDocument: AnyObject?,
               currentLayers: [EngineSession.Layer]) -> EngineSession.Layer? {
        guard let node = item as? LayerTree.Node, let document, let currentDocument,
              document === currentDocument,
              currentLayers.contains(where: { $0.id == node.id }) else { return nil }
        return node.layer
    }

    /// The effect an outline item still shows: only while the snapshot's
    /// document is the palette's target and the effect is still on its
    /// drawable. `currentEffects` is the document's live map.
    func effect(for item: Any?, for currentDocument: AnyObject?,
                currentEffects: [Int32: [EngineSession.Effect]]) -> EffectItem? {
        guard let row = item as? EffectItem, let document, let currentDocument,
              document === currentDocument, row.document === currentDocument,
              currentEffects[row.drawable]?.contains(where: { $0.id == row.effect.id }) == true
        else { return nil }
        return row
    }
}

/// One committed effect row under a layer. The document and drawable it
/// belongs to travel with it, so a command issued from it can never
/// reach another document or another drawable's stack.
final class EffectItem {
    /// The document whose palette shows the row; compared by identity.
    let document: AnyObject
    /// The layer the effect is committed on.
    let drawable: Int32
    let effect: EngineSession.Effect

    init(document: AnyObject, drawable: Int32, effect: EngineSession.Effect) {
        self.document = document
        self.drawable = drawable
        self.effect = effect
    }
}
