import Foundation

/// The persistent per-tool brush choice: a `ResourceIdentity` per `ToolID`,
/// stored through UserDefaults as Codable JSON. A session `ResourceID` is
/// never stored — handles are local to the running engine and a number can
/// be reused after a restart — so `EngineSession.beginStroke` resolves the
/// identity fresh on the engine worker and a removed resource fails
/// explicitly instead of painting with a different brush.
///
/// Pure value storage (no AppKit, no engine): tests inject a suite's
/// UserDefaults, the app uses `shared`.
final class BrushSelectionStore {
    static let shared = BrushSelectionStore(defaults: .standard)

    /// The defaults key; internal so tests can inspect the raw encoded form.
    static let selectionsKey = "editor.brushSelections"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The identity stored for `tool`, or nil for the native default brush.
    func identity(for tool: ToolID) -> EngineSession.ResourceIdentity? {
        selections[tool.rawValue]
    }

    /// Every stored choice, keyed by the tool's raw value.
    var all: [String: EngineSession.ResourceIdentity] { selections }

    /// Stores `identity` for `tool`; nil removes the entry, which means the
    /// original native default brush.
    func set(_ identity: EngineSession.ResourceIdentity?, for tool: ToolID) {
        var next = selections
        next[tool.rawValue] = identity
        persist(next)
    }

    /// Removes every stored brush choice.
    func reset() {
        defaults.removeObject(forKey: Self.selectionsKey)
    }

    private var selections: [String: EngineSession.ResourceIdentity] {
        guard let data = defaults.data(forKey: Self.selectionsKey),
              let decoded = try? JSONDecoder().decode([String: EngineSession.ResourceIdentity].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persist(_ selections: [String: EngineSession.ResourceIdentity]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(selections) else { return }
        defaults.set(data, forKey: Self.selectionsKey)
    }
}
