import Foundation

/// Cached admission for a captured resize. Native code repeats every check
/// after queued edits; menu validation never calls the engine.
enum LayerFitPolicy {
    static func refusal(ids: [Int32], kinds: [Int32: EngineSession.LayerKind],
                        locks: [Int32: EngineSession.LayerLockState]) -> String? {
        guard !ids.isEmpty else { return "Select the layers to resize." }
        guard ids.count <= 256 else { return "Resize at most 256 layers together." }
        guard ids.allSatisfy({ $0 > 0 }), Set(ids).count == ids.count else {
            return "Refresh the layer selection before resizing."
        }
        for id in ids {
            guard let kind = kinds[id], let state = locks[id] else {
                return "Refresh the layer state before resizing."
            }
            guard kind == .pixel else {
                return "Select pixel layers. Rasterize editable sources first; resize layers inside groups individually."
            }
            guard state.effective.isDisjoint(with: [.pixels, .position]) else {
                return "Unlock pixels and position on every selected layer and its parent groups."
            }
        }
        return nil
    }
}
