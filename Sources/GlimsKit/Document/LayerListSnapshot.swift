import Foundation

/// Rows stay bound to their displayed items while a rename defers
/// reloads. Resolving through the live engine list during that interval
/// could select another layer after a reorder, or crash after deletion.
struct LayerListSnapshot {
    let document: AnyObject?
    let tree: LayerTree

    init(document: AnyObject?, layers: [EngineSession.Layer]) {
        self.document = document
        self.tree = LayerTree(layers: layers)
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
}
