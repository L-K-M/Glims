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
                                                 foregroundColor: old.foregroundColor)
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
                                                 foregroundColor: foregroundColor)
        }
    }

    /// Deletes the preset `id`.
    func delete(id: UUID) throws {
        try mutate { presets in
            presets.remove(at: try presets.index(of: id))
        }
    }

    /// Removes every stored preset.
    func reset() throws {
        _ = try document()
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
        try Self.validateCollection(presets)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(PresetDocument(presets: presets))
        } catch {
            throw PaintToolPresetError.malformed("the preset document could not be encoded: \(error)")
        }
        defaults.set(data, forKey: Self.presetsKey)
    }

    /// Reads the stored bytes strictly: an absent key is an empty document;
    /// present bytes must be a readable document of the supported schema
    /// version, otherwise the error says why and nothing is written.
    private func document() throws -> PresetDocument {
        guard let stored = defaults.object(forKey: Self.presetsKey) else {
            return PresetDocument(presets: [])
        }
        guard let data = stored as? Data else {
            throw PaintToolPresetError.malformed("the stored value is not a preset data document")
        }
        do {
            let document = try JSONDecoder().decode(PresetDocument.self, from: data)
            try Self.validateCollection(document.presets)
            return document
        } catch let error as PaintToolPresetError {
            throw error
        } catch {
            throw PaintToolPresetError.malformed("not a readable preset document: \(error)")
        }
    }

    /// Names must be unique within a tool; exact match on the stored
    /// (trimmed) name.
    private static func validateCollection(_ presets: [PaintToolPreset]) throws {
        var ids = Set<UUID>()
        var names: [ToolID: Set<String>] = [:]
        for preset in presets {
            guard ids.insert(preset.id).inserted else {
                throw PaintToolPresetError.malformed("duplicate preset identifier \(preset.id)")
            }
            guard names[preset.tool, default: []].insert(preset.name).inserted else {
                throw PaintToolPresetError.duplicateName(preset.name, tool: preset.tool)
            }
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

/// Strict schema-one envelope. Unknown fields require a compatible reader;
/// every failure leaves the original bytes untouched.
private struct PresetDocument: Codable {
    let schemaVersion: Int
    let presets: [PaintToolPreset]

    init(presets: [PaintToolPreset]) {
        self.schemaVersion = PaintToolPresetStore.schemaVersion
        self.presets = presets
    }

    enum CodingKeys: String, CodingKey { case schemaVersion, presets }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.schemaVersion) else { throw PaintToolPresetError.missingSchemaVersion }
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == PaintToolPresetStore.schemaVersion else {
            throw PaintToolPresetError.unsupportedSchemaVersion(found: schemaVersion,
                                                                supported: PaintToolPresetStore.schemaVersion)
        }
        try rejectUnknownPresetKeys(decoder, allowed: ["schemaVersion", "presets"])
        presets = try container.decode([PaintToolPreset].self, forKey: .presets)
    }
}
