import Foundation

/// The persistent paint tool presets: an ordered list of immutable
/// `PaintToolPreset` values, stored through UserDefaults as versioned
/// Codable JSON (docs/paint-tool-presets.md).
///
/// Like `BrushSelectionStore`: pure value storage (no AppKit, no engine),
/// tests inject a suite's UserDefaults, the app uses `shared`. This store
/// owns its defaults key exclusively; every mutation re-reads the stored
/// bytes, so externally changed data is picked up — and a document this
/// version cannot read (a future schema version, corrupt bytes) makes the
/// mutation fail WITHOUT touching the stored bytes.
final class PaintToolPresetStore {
    static let shared = PaintToolPresetStore(defaults: .standard)

    /// The defaults key; internal so tests can inspect and seed the raw form.
    static let presetsKey = "editor.paintToolPresets"

    /// The schema version this store reads and writes.
    static let schemaVersion = 1

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// Every stored preset, in stored (creation) order. An absent key is an
    /// empty store; unreadable or unknown-schema bytes throw, never reset.
    func load() throws -> [PaintToolPreset] {
        try document().presets
    }

    /// The stored presets of one paint tool, in stored order.
    func presets(for tool: ToolID) throws -> [PaintToolPreset] {
        guard tool.paintTool != nil else { throw PaintToolPresetError.nonPaintTool(tool) }
        return try load().filter { $0.tool == tool }
    }

    /// The raw stored bytes, or nil when nothing is stored; internal so tests
    /// can compare bytes and seed malformed documents.
    var storedData: Data? { defaults.data(forKey: Self.presetsKey) }

    /// Appends a new preset with a fresh UUID and returns it. The name is
    /// stored trimmed and must be unique within the tool.
    @discardableResult
    func create(tool: ToolID, name: String, settings: PaintToolPreset.Settings,
                brushResource: PaintToolPreset.BrushResource? = nil,
                foregroundColor: PaintToolPreset.SRGBColor? = nil) throws -> PaintToolPreset {
        let preset = try PaintToolPreset(tool: tool, name: name, settings: settings,
                                         brushResource: brushResource, foregroundColor: foregroundColor)
        try mutate { presets in presets.append(preset) }
        return preset
    }

    /// Renames the preset `id`; the UUID, position and snapshot stay.
    func rename(id: UUID, to name: String) throws {
        try mutate { presets in
            let index = try presets.index(of: id)
            let old = presets[index]
            presets[index] = try PaintToolPreset(id: old.id, tool: old.tool, name: name,
                                                 settings: old.settings, brushResource: old.brushResource,
                                                 foregroundColor: old.foregroundColor,
                                                 unknownFields: old.unknownFields)
        }
    }

    /// Replaces the snapshot of the preset `id`; the UUID, name, tool and
    /// position stay.
    func replace(id: UUID, settings: PaintToolPreset.Settings,
                 brushResource: PaintToolPreset.BrushResource?,
                 foregroundColor: PaintToolPreset.SRGBColor?) throws {
        try mutate { presets in
            let index = try presets.index(of: id)
            let old = presets[index]
            presets[index] = try PaintToolPreset(id: old.id, tool: old.tool, name: old.name,
                                                 settings: settings, brushResource: brushResource,
                                                 foregroundColor: foregroundColor,
                                                 unknownFields: old.unknownFields)
        }
    }

    /// Deletes the preset `id`.
    func delete(id: UUID) throws {
        try mutate { presets in
            presets.remove(at: try presets.index(of: id))
        }
    }

    /// Removes every stored preset.
    func reset() {
        defaults.removeObject(forKey: Self.presetsKey)
    }

    /// Loads the stored document, applies `change`, checks the result and
    /// only then writes the single encoded document back. Any load,
    /// validation or encoding failure throws before the write, so the
    /// stored bytes — and the snapshot they decode to — are untouched.
    private func mutate(_ change: (inout [PaintToolPreset]) throws -> Void) throws {
        let current = try document()
        var presets = current.presets
        try change(&presets)
        try Self.validateUniqueNames(presets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(PresetDocument(presets: presets, unknownFields: current.unknownFields))
        } catch {
            throw PaintToolPresetError.malformed("the preset document could not be encoded: \(error)")
        }
        defaults.set(data, forKey: Self.presetsKey)
    }

    /// Reads the stored bytes strictly: an absent key is an empty document;
    /// present bytes must be a readable document of the supported schema
    /// version, otherwise the error says why and nothing is written.
    private func document() throws -> PresetDocument {
        guard let data = defaults.data(forKey: Self.presetsKey) else {
            return PresetDocument(presets: [], unknownFields: [:])
        }
        do {
            return try JSONDecoder().decode(PresetDocument.self, from: data)
        } catch let error as PaintToolPresetError {
            throw error
        } catch {
            throw PaintToolPresetError.malformed("not a readable preset document: \(error)")
        }
    }

    /// Names must be unique within a tool; exact match on the stored
    /// (trimmed) name.
    private static func validateUniqueNames(_ presets: [PaintToolPreset]) throws {
        var seen: [(name: String, tool: ToolID)] = []
        for preset in presets {
            if seen.contains(where: { $0.name == preset.name && $0.tool == preset.tool }) {
                throw PaintToolPresetError.duplicateName(preset.name, tool: preset.tool)
            }
            seen.append((preset.name, preset.tool))
        }
    }
}

private extension Array where Element == PaintToolPreset {
    func index(of id: UUID) throws -> Index {
        guard let index = firstIndex(where: { $0.id == id }) else {
            throw PaintToolPresetError.unknownPreset(id)
        }
        return index
    }
}

/// The persisted envelope: a schema version plus the preset array plus the
/// top-level keys this version does not know, kept verbatim so a rewrite
/// under the same schema never erases them.
private struct PresetDocument: Codable {
    var presets: [PaintToolPreset]
    var unknownFields: [String: JSONValue]

    static let schemaVersionKey = "schemaVersion"
    static let presetsKey = "presets"

    init(presets: [PaintToolPreset], unknownFields: [String: JSONValue]) {
        self.presets = presets
        self.unknownFields = unknownFields
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyCodingKey.self)
        let versionKey = AnyCodingKey(stringValue: Self.schemaVersionKey)!
        guard container.contains(versionKey) else {
            throw PaintToolPresetError.missingSchemaVersion
        }
        let version = try container.decode(Int.self, forKey: versionKey)
        guard version == PaintToolPresetStore.schemaVersion else {
            throw PaintToolPresetError.unsupportedSchemaVersion(found: version,
                                                                supported: PaintToolPresetStore.schemaVersion)
        }
        let presetsKey = AnyCodingKey(stringValue: Self.presetsKey)!
        guard container.contains(presetsKey) else {
            throw PaintToolPresetError.malformed("the preset document has no \"\(Self.presetsKey)\" array")
        }
        presets = try container.decode([PaintToolPreset].self, forKey: presetsKey)
        var unknown: [String: JSONValue] = [:]
        for key in container.allKeys
            where key.stringValue != Self.schemaVersionKey && key.stringValue != Self.presetsKey {
            unknown[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
        }
        unknownFields = unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AnyCodingKey.self)
        try container.encode(PaintToolPresetStore.schemaVersion, forKey: AnyCodingKey(stringValue: Self.schemaVersionKey)!)
        try container.encode(presets, forKey: AnyCodingKey(stringValue: Self.presetsKey)!)
        for (key, value) in unknownFields
            where key != Self.schemaVersionKey && key != Self.presetsKey {
            try container.encode(value, forKey: AnyCodingKey(stringValue: key)!)
        }
    }
}
