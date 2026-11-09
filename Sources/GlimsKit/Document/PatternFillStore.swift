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

    enum MigrationError: Error, LocalizedError, Equatable {
        case malformed(String)
        case invalidIdentity(String)
        var errorDescription: String? {
            switch self {
            case .malformed(let detail):
                return "The stored fill pattern could not be read: \(detail). The stored data was left untouched."
            case .invalidIdentity(let reason):
                return "The pattern resource identity is invalid: \(reason)."
            }
        }
    }

    func migrateIdentity(from: EngineSession.ResourceIdentity,
                        to: EngineSession.ResourceIdentity) throws -> Int {
        try validateIdentity(from)
        try validateIdentity(to)
        let key = Self.selectionKey
        guard let stored = defaults.object(forKey: key) else { return 0 }
        guard let data = stored as? Data else {
            throw MigrationError.malformed("the stored value is not pattern data")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any] else {
            throw MigrationError.malformed("not a readable pattern identity")
        }
        let decoded: EngineSession.ResourceIdentity
        do { decoded = try JSONDecoder().decode(EngineSession.ResourceIdentity.self, from: data) }
        catch { throw MigrationError.malformed("not a readable pattern identity: \(error)") }
        try validateIdentity(decoded)
        guard dictionary["schemaVersion"] == nil else { throw MigrationError.malformed("an unsupported schema version is present") }
        guard from != to else { return 0 }
        guard decoded == from else { return 0 }
        var patched = dictionary
        patched["name"] = to.name
        if let collection = to.collection { patched["collection"] = collection }
        else { patched["collection"] = NSNull() }
        patched["isInternal"] = to.isInternal
        let output: Data
        do { output = try JSONSerialization.data(withJSONObject: patched, options: [.sortedKeys]) }
        catch { throw MigrationError.malformed("the migrated pattern identity could not be encoded: \(error)") }
        do { _ = try JSONDecoder().decode(EngineSession.ResourceIdentity.self, from: output) }
        catch { throw MigrationError.malformed("the migrated pattern identity could not be validated: \(error)") }
        defaults.set(output, forKey: key)
        return 1
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
