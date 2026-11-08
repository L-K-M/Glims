import Foundation

/// The persistent keyboard shortcut overrides: per-command choices stored
/// through UserDefaults as versioned Codable JSON (docs/keyboard-shortcuts.md).
///
/// Like `PaintToolPresetStore`: pure value storage (no AppKit, no engine), the
/// app uses `shared`, tests inject a suite's UserDefaults. This store owns its
/// defaults key exclusively; every mutation re-reads the stored bytes, so a
/// document this version cannot read (a future schema version, corrupt bytes,
/// unknown fields, duplicate ids) makes the mutation fail WITHOUT touching
/// the stored bytes — load errors throw, never reset.
final class KeyboardShortcutOverrideStore {
    static let shared = KeyboardShortcutOverrideStore(defaults: .standard)

    /// The defaults key; internal so tests can inspect and seed the raw form.
    static let overridesKey = "editor.keyboardShortcutOverrides"

    /// The schema version this store reads and writes.
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Every stored override, keyed by command id. An absent key is an empty
    /// store; unreadable or unknown-schema bytes throw, never reset.
    ///
    /// Overrides whose command the current catalog does not know (orphans from
    /// a catalog that changed) load fine and stay stored; they are inactive
    /// until the command is known again.
    func load() throws -> [String: CommandShortcutOverride] {
        try document().overrides
    }

    /// The raw stored bytes, or nil when nothing is stored; internal so tests
    /// can compare bytes and seed malformed documents.
    var storedData: Data? { defaults.data(forKey: Self.overridesKey) }

    /// Assigns `shortcut` to `command`. The command must be in `catalog`; the
    /// prospective full override set is validated against the catalog's
    /// effective shortcuts (Command/Control required, macOS reservations,
    /// conflicts naming both commands) BEFORE anything is written. A conflict
    /// never silently unbinds the other command.
    func assign(_ shortcut: KeyboardShortcut, to command: String, catalog: KeyboardShortcutCatalog) throws {
        guard catalog.byID[command] != nil else { throw KeyboardShortcutError.unknownCommand(command) }
        try mutate(catalog: catalog) { overrides in
            overrides[command] = .assign(shortcut)
        }
    }

    /// Explicitly disables `command`'s shortcut.
    func disable(_ command: String, catalog: KeyboardShortcutCatalog) throws {
        guard catalog.byID[command] != nil else { throw KeyboardShortcutError.unknownCommand(command) }
        try mutate(catalog: catalog) { overrides in
            overrides[command] = .disable
        }
    }

    /// Removes the override of `command`, restoring its factory base (or no
    /// shortcut when it has none). Also removes an orphaned override of a
    /// command the catalog no longer knows. The removal itself is validated
    /// and persisted like every mutation.
    func reset(_ command: String) throws {
        try mutate(catalog: nil) { overrides in
            overrides.removeValue(forKey: command)
        }
    }

    /// Removes every stored override. The stored document is read strictly
    /// first: a corrupt or future document throws and the bytes stay.
    func resetAll() throws {
        _ = try document()
        defaults.removeObject(forKey: Self.overridesKey)
    }

    /// Loads the stored document, applies `change`, validates the result
    /// against `catalog` (when given) and only then writes the single encoded
    /// document back. Any load, validation or encoding failure throws before
    /// the write, so the stored bytes are untouched.
    private func mutate(catalog: KeyboardShortcutCatalog?,
                        _ change: (inout [String: CommandShortcutOverride]) throws -> Void) throws {
        var overrides = try document().overrides
        try change(&overrides)
        // Validate the prospective set BEFORE writing: known overrides are
        // revalidated against the catalog's effective shortcuts (this is
        // also where an override of a command that became known again is
        // rechecked); stored orphans stay untouched and inactive.
        if let catalog {
            _ = try catalog.effectiveShortcuts(overrides: overrides)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(OverrideDocument(overrides: overrides))
        } catch {
            throw KeyboardShortcutError.malformed("the override document could not be encoded: \(error)")
        }
        defaults.set(data, forKey: Self.overridesKey)
    }

    /// Reads the stored bytes strictly: an absent key is an empty document;
    /// present bytes must be a readable document of the supported schema
    /// version with no unknown fields, otherwise the error says why and
    /// nothing is written.
    private func document() throws -> OverrideDocument {
        guard let stored = defaults.object(forKey: Self.overridesKey) else {
            return OverrideDocument(overrides: [:])
        }
        guard let data = stored as? Data else {
            throw KeyboardShortcutError.malformed("the stored value is not a shortcut override data document")
        }
        do {
            return try JSONDecoder().decode(OverrideDocument.self, from: data)
        } catch let error as KeyboardShortcutError {
            throw error
        } catch {
            throw KeyboardShortcutError.malformed("not a readable shortcut override document: \(error)")
        }
    }
}

// MARK: - Stored document (strict schema one)

/// One stored entry: the command id plus its override.
private struct StoredOverride: Codable {
    let command: String
    let override: CommandShortcutOverride

    enum CodingKeys: String, CodingKey { case command, override }

    init(command: String, override: CommandShortcutOverride) {
        self.command = command
        self.override = override
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownShortcutKeys(decoder, allowed: ["command", "override"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.command = try container.decode(String.self, forKey: .command)
        self.override = try container.decode(CommandShortcutOverride.self, forKey: .override)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(command, forKey: .command)
        try container.encode(override, forKey: .override)
    }
}

/// Strict schema-one envelope, stored as an array so duplicate command ids
/// are detectable (a JSON object would silently keep the last one). Unknown
/// fields require a compatible reader; every failure leaves the original
/// bytes untouched.
private struct OverrideDocument: Codable {
    let schemaVersion: Int
    let overrides: [String: CommandShortcutOverride]

    init(overrides: [String: CommandShortcutOverride]) {
        self.schemaVersion = KeyboardShortcutOverrideStore.schemaVersion
        self.overrides = overrides
    }

    private enum CodingKeys: String, CodingKey { case schemaVersion, overrides }

    init(from decoder: Decoder) throws {
        try rejectUnknownShortcutKeys(decoder, allowed: ["schemaVersion", "overrides"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.schemaVersion) else { throw KeyboardShortcutError.missingSchemaVersion }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == KeyboardShortcutOverrideStore.schemaVersion else {
            throw KeyboardShortcutError.unsupportedSchemaVersion(found: schemaVersion,
                                                                  supported: KeyboardShortcutOverrideStore.schemaVersion)
        }
        let stored = try container.decode([StoredOverride].self, forKey: .overrides)
        var overrides: [String: CommandShortcutOverride] = [:]
        for entry in stored {
            guard !entry.command.isEmpty else { throw KeyboardShortcutError.emptyCommandID }
            guard !entry.command.contains(where: { $0.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) }) else {
                throw KeyboardShortcutError.invalidCommandID(entry.command)
            }
            guard overrides[entry.command] == nil else {
                throw KeyboardShortcutError.duplicateStoredOverride(entry.command)
            }
            overrides[entry.command] = entry.override
        }
        self.overrides = overrides
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        let stored = overrides
            .map { StoredOverride(command: $0.key, override: $0.value) }
            .sorted { $0.command < $1.command }
        try container.encode(stored, forKey: .overrides)
    }
}
