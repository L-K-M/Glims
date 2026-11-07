import Foundation

/// Rows stay bound to their displayed ids while a rename defers reloads.
/// Indexing the live engine list during that interval could select another
/// layer after a reorder, or crash after deletion.
struct LayerListSnapshot {
    let document: AnyObject?
    let layers: [EngineSession.Layer]

    func layer(at row: Int, for currentDocument: AnyObject?, currentLayers: [EngineSession.Layer]) -> EngineSession.Layer? {
        guard let document, let currentDocument, document === currentDocument,
              layers.indices.contains(row), currentLayers.contains(where: { $0.id == layers[row].id }) else { return nil }
        return layers[row]
    }
}
