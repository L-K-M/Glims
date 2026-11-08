import Foundation

/// The persistent Edit ▸ Fill pattern choice: one `ResourceIdentity`,
/// stored through UserDefaults as Codable JSON. A session `ResourceID`
/// and rendered thumbnails are never stored — handles are local to the
/// running engine and a number can be reused after a restart — so the
/// fill resolves the identity fresh on the engine worker and a removed
/// pattern fails explicitly instead of filling with a different pattern.
///
/// Pure value storage (no AppKit, no engine): tests inject a suite's
/// UserDefaults, the app uses `shared`.
final class PatternFillStore {
    static let shared = PatternFillStore(defaults: .standard)

    /// The defaults key; internal so tests can inspect the raw encoded form.
    static let selectionKey = "editor.fillPattern"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The stored pattern identity, or nil when no pattern fill ran yet.
    var identity: EngineSession.ResourceIdentity? {
        guard let data = defaults.data(forKey: Self.selectionKey),
              let decoded = try? JSONDecoder().decode(EngineSession.ResourceIdentity.self, from: data) else {
            return nil
        }
        return decoded
    }

    /// Stores `identity`; nil removes the entry.
    func set(_ identity: EngineSession.ResourceIdentity?) {
        guard let identity else {
            defaults.removeObject(forKey: Self.selectionKey)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(identity) else { return }
        defaults.set(data, forKey: Self.selectionKey)
    }
}
