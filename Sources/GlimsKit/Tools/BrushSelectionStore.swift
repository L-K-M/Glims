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

    enum MigrationError: Error, LocalizedError, Equatable {
        case malformed(String)
        case invalidIdentity(String)
        var errorDescription: String? {
            switch self {
            case .malformed(let detail):
                return "The stored brush selections could not be read: \(detail). The stored data was left untouched."
            case .invalidIdentity(let reason):
                return "The brush resource identity is invalid: \(reason)."
            }
        }
    }

    func migrateIdentity(from: EngineSession.ResourceIdentity,
                        to: EngineSession.ResourceIdentity) throws -> Int {
        try validateIdentity(from)
        try validateIdentity(to)
        let key = Self.selectionsKey
        guard let stored = defaults.object(forKey: key) else { return 0 }
        guard let data = stored as? Data else {
            throw MigrationError.malformed("the stored value is not brush selection data")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw MigrationError.malformed("not a readable brush selection document")
        }
        let decoded: [String: EngineSession.ResourceIdentity]
        do { decoded = try JSONDecoder().decode([String: EngineSession.ResourceIdentity].self, from: data) }
        catch { throw MigrationError.malformed("not a readable brush selection document: \(error)") }
        for identity in decoded.values { try validateIdentity(identity) }
        guard from != to else { return 0 }
        var patched = dictionary
        var changed = 0
        for (toolKey, rawValue) in dictionary {
            guard let identityDictionary = rawValue as? [String: Any],
                  let decodedIdentity = decoded[toolKey],
                  decodedIdentity == from else { continue }
            var next = identityDictionary
            next["name"] = to.name
            if let collection = to.collection { next["collection"] = collection }
            else { next["collection"] = NSNull() }
            next["isInternal"] = to.isInternal
            patched[toolKey] = next
            changed += 1
        }
        guard changed > 0 else { return 0 }
        let output: Data
        do { output = try JSONSerialization.data(withJSONObject: patched, options: [.sortedKeys]) }
        catch { throw MigrationError.malformed("the migrated brush selections could not be encoded: \(error)") }
        do { _ = try JSONDecoder().decode([String: EngineSession.ResourceIdentity].self, from: output) }
        catch { throw MigrationError.malformed("the migrated brush selections could not be validated: \(error)") }
        defaults.set(output, forKey: key)
        return changed
    }

    private func validateIdentity(_ identity: EngineSession.ResourceIdentity) throws {
        guard !identity.name.isEmpty else {
            throw MigrationError.invalidIdentity("the resource name is empty")
        }
        guard !identity.name.utf8.contains(0) else {
            throw MigrationError.invalidIdentity("the resource name contains a NUL byte")
        }
        if let collection = identity.collection, collection.utf8.contains(0) {
            throw MigrationError.invalidIdentity("the resource collection contains a NUL byte")
        }
    }
}
