import Foundation

/// One saved paint tool preset: an owned, named, UUID-identified immutable
/// snapshot of a paint tool's stable brush settings (docs/paint-tool-presets.md).
///
/// Scope: value model and validation only. Nothing here applies a preset to
/// `ToolState`; that is a later slice. The preset is per paint-tool `ToolID`
/// only (`tool.paintTool != nil`); the engine paint tool behind it is derived
/// from the tool, so `EngineSession.Brush.Tool` is not stored separately.
///
/// Deliberately NOT captured: `EngineSession.Brush.Source` (the clone/heal
/// source point: a native drawable id and transient image coordinates),
/// session `ResourceID` handles, and any transient target coordinates. A
/// clone/heal preset therefore does not restore its source point; the user
/// sets it again with Option-click after applying the preset.
///
/// Persisted tags are Glims's own strings ("paintbrush", "shadows", ...),
/// never the engine's raw enum numbers.
struct PaintToolPreset: Identifiable, Equatable {

    /// The stable settings captured from `EngineSession.Brush`, minus the
    /// transient fields. `nil` for hardness/rate/flow/exposure means "the
    /// engine's default", exactly as in `Brush` (Engine/paint.c treats a
    /// negative number as "keep the default").
    struct Settings: Equatable {
        /// Brush diameter in image pixels.
        var size: Double
        /// 0 ... 1.
        var opacity: Double
        /// Pen pressure scales the size.
        var pressureSize: Bool
        /// 0 ... 1, or nil for the engine's default.
        var hardness: Double?
        /// 0 ... 100, or nil for the engine's default.
        var rate: Double?
        /// 0 ... 100, or nil for the engine's default.
        var flow: Double?
        /// 0 ... 100, or nil for the engine's default.
        var exposure: Double?
        /// The tonal range dodge/burn act on.
        var tones: ToneRange
        /// Eraser: restore erased opacity instead.
        var antiErase: Bool
    }

    /// The tonal range as Glims's own tag, never the engine's raw number.
    enum ToneRange: String, Equatable {
        case midtones, shadows, highlights

        /// The engine-side value this tag stands for.
        var brushTones: EngineSession.Brush.Tones {
            switch self {
            case .midtones: return .midtones
            case .shadows: return .shadows
            case .highlights: return .highlights
            }
        }

        init(brushTones: EngineSession.Brush.Tones) {
            switch brushTones {
            case .midtones: self = .midtones
            case .shadows: self = .shadows
            case .highlights: self = .highlights
            }
        }
    }

    /// A brush resource reference. `EngineSession.ResourceIdentity` carries
    /// no resource kind, so this typed wrapper pins the kind to `.brush`:
    /// the identity is meant to be resolved with
    /// `EngineSession.resolveResource(_:kind: .brush)`. A persisted kind tag
    /// other than "brush" is rejected, never silently reinterpreted.
    struct BrushResource: Equatable {
        enum Kind: String, Equatable {
            case brush
        }

        let kind: Kind
        let identity: EngineSession.ResourceIdentity

        /// The kind this reference resolves against: always a brush.
        var resourceKind: EngineSession.ResourceKind { .brush }
    }

    /// An optional foreground color capture, as sRGB components 0 ... 1.
    /// An explicit schema field: color capture is deliberate, not implied by
    /// the brush settings.
    struct SRGBColor: Equatable {
        var red: Double
        var green: Double
        var blue: Double
    }

    let id: UUID
    /// The paint tool this preset belongs to; always one with
    /// `paintTool != nil`.
    let tool: ToolID
    /// Trimmed, nonempty, at most `PaintToolPresetLimits.maxNameLength`
    /// characters.
    let name: String
    let settings: Settings
    /// The chosen brush resource, or nil for the native default brush.
    let brushResource: BrushResource?
    /// The optional captured foreground color.
    let foregroundColor: SRGBColor?

    /// Creates a validated immutable snapshot. Schema extensions require
    /// a new version; this version never rewrites fields it cannot read.
    init(id: UUID = UUID(), tool: ToolID, name: String, settings: Settings,
         brushResource: BrushResource? = nil, foregroundColor: SRGBColor? = nil) throws {
        self.id = id
        self.tool = tool
        self.name = Self.trimmed(name)
        self.settings = settings
        self.brushResource = brushResource
        self.foregroundColor = foregroundColor
        try validate()
    }

    /// The stored form of a name: trimmed of whitespace and newlines.
    static func trimmed(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Validates the whole value; every initializer and the decoder run it.
    func validate() throws {
        guard tool.paintTool != nil else { throw PaintToolPresetError.nonPaintTool(tool) }
        guard !name.isEmpty else { throw PaintToolPresetError.emptyName }
        guard name.count <= PaintToolPresetLimits.maxNameLength else {
            throw PaintToolPresetError.nameTooLong(length: name.count, max: PaintToolPresetLimits.maxNameLength)
        }
        guard name == Self.trimmed(name) else {
            throw PaintToolPresetError.malformed("preset name is not stored trimmed: \(name)")
        }
        try settings.validate()
        try brushResource?.validate()
        try foregroundColor?.validate()
    }

    /// Equality over the complete saved value.
    static func == (lhs: PaintToolPreset, rhs: PaintToolPreset) -> Bool {
        lhs.id == rhs.id && lhs.tool == rhs.tool && lhs.name == rhs.name
            && lhs.settings == rhs.settings && lhs.brushResource == rhs.brushResource
            && lhs.foregroundColor == rhs.foregroundColor
    }
}

// MARK: - Codable

/// A coding key that accepts any string, used to read the keys a schema
/// version does not know.
struct PresetCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

/// Reject extensions at every object boundary before decoding values.
/// Unknown data, including numeric precision this version cannot represent,
/// stays in the original stored bytes until a compatible version reads it.
func rejectUnknownPresetKeys(_ decoder: Decoder, allowed: Set<String>) throws {
    let container = try decoder.container(keyedBy: PresetCodingKey.self)
    let unknown = container.allKeys.map(\.stringValue).filter { !allowed.contains($0) }.sorted()
    guard unknown.isEmpty else {
        let path = decoder.codingPath.map(\.stringValue).joined(separator: ".")
        throw PaintToolPresetError.malformed("unsupported fields in \(path.isEmpty ? "document" : path): \(unknown.joined(separator: ", ")). Use a compatible Glims version")
    }
}

extension PaintToolPreset {
    private static let knownKeys: Set<String> = ["id", "tool", "name", "settings", "brushResource", "foregroundColor"]

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, tool, name, settings, brushResource, foregroundColor
    }
}

extension PaintToolPreset: Codable {
    init(from decoder: Decoder) throws {
        try rejectUnknownPresetKeys(decoder, allowed: Self.knownKeys)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let toolTag = try container.decode(String.self, forKey: .tool)
        guard let tool = ToolID(rawValue: toolTag) else {
            throw PaintToolPresetError.unknownToolTag(toolTag)
        }
        try self.init(id: try container.decode(UUID.self, forKey: .id),
                      tool: tool,
                      name: try container.decode(String.self, forKey: .name),
                      settings: try container.decode(Settings.self, forKey: .settings),
                      brushResource: try container.decodeIfPresent(BrushResource.self, forKey: .brushResource),
                      foregroundColor: try container.decodeIfPresent(SRGBColor.self, forKey: .foregroundColor))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(tool.rawValue, forKey: .tool)
        try container.encode(name, forKey: .name)
        try container.encode(settings, forKey: .settings)
        try container.encodeIfPresent(brushResource, forKey: .brushResource)
        try container.encodeIfPresent(foregroundColor, forKey: .foregroundColor)

    }
}

extension PaintToolPreset.BrushResource {
    /// A reference to a brush resource: the kind is pinned to `.brush`.
    init(_ identity: EngineSession.ResourceIdentity) {
        self.init(kind: .brush, identity: identity)
    }
}

extension PaintToolPreset.Settings: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case size, opacity, pressureSize, hardness, rate, flow, exposure, tones, antiErase
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownPresetKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(size: try container.decode(Double.self, forKey: .size),
                  opacity: try container.decode(Double.self, forKey: .opacity),
                  pressureSize: try container.decode(Bool.self, forKey: .pressureSize),
                  hardness: try container.decodeIfPresent(Double.self, forKey: .hardness),
                  rate: try container.decodeIfPresent(Double.self, forKey: .rate),
                  flow: try container.decodeIfPresent(Double.self, forKey: .flow),
                  exposure: try container.decodeIfPresent(Double.self, forKey: .exposure),
                  tones: try container.decode(PaintToolPreset.ToneRange.self, forKey: .tones),
                  antiErase: try container.decode(Bool.self, forKey: .antiErase))
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(size, forKey: .size)
        try container.encode(opacity, forKey: .opacity)
        try container.encode(pressureSize, forKey: .pressureSize)
        // nil optionals persist as no key, like ResourceIdentity.collection.
        try container.encodeIfPresent(hardness, forKey: .hardness)
        try container.encodeIfPresent(rate, forKey: .rate)
        try container.encodeIfPresent(flow, forKey: .flow)
        try container.encodeIfPresent(exposure, forKey: .exposure)
        try container.encode(tones, forKey: .tones)
        try container.encode(antiErase, forKey: .antiErase)
    }

    func validate() throws {
        try PaintToolPresetLimits.validateSize(size)
        try PaintToolPresetLimits.validateUnit(opacity, field: "settings.opacity")
        try PaintToolPresetLimits.validateOptionalUnit(hardness, field: "settings.hardness")
        try PaintToolPresetLimits.validateOptionalPercent(rate, field: "settings.rate")
        try PaintToolPresetLimits.validateOptionalPercent(flow, field: "settings.flow")
        try PaintToolPresetLimits.validateOptionalPercent(exposure, field: "settings.exposure")
    }
}

extension PaintToolPreset.ToneRange: Codable {
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let tone = PaintToolPreset.ToneRange(rawValue: raw) else {
            throw PaintToolPresetError.unknownToneRange(raw)
        }
        self = tone
    }
}

extension PaintToolPreset.BrushResource: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, identity
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownPresetKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let tag = try container.decode(String.self, forKey: .kind)
        guard let kind = Kind(rawValue: tag) else {
            throw PaintToolPresetError.invalidResourceKind(tag)
        }
        let identityDecoder = try container.superDecoder(forKey: .identity)
        try rejectUnknownPresetKeys(identityDecoder, allowed: ["name", "collection", "isInternal"])
        self.init(kind: kind, identity: try EngineSession.ResourceIdentity(from: identityDecoder))
        try validate()
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind.rawValue, forKey: .kind)
        try container.encode(identity, forKey: .identity)
    }

    /// Mirrors the text checks of `EngineSession.resolveResource(_:kind:)`:
    /// a nonempty name and no NUL bytes in the name or collection.
    func validate() throws {
        guard !identity.name.isEmpty else {
            throw PaintToolPresetError.invalidResourceIdentity(reason: "the brush name is empty")
        }
        guard !identity.name.utf8.contains(0), identity.collection?.utf8.contains(0) != true else {
            throw PaintToolPresetError.invalidResourceIdentity(reason: "the brush identity contains a NUL byte")
        }
    }
}

extension PaintToolPreset.SRGBColor: Codable {
    enum CodingKeys: String, CodingKey, CaseIterable {
        case red, green, blue
    }

    init(from decoder: Decoder) throws {
        try rejectUnknownPresetKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(red: try container.decode(Double.self, forKey: .red),
                  green: try container.decode(Double.self, forKey: .green),
                  blue: try container.decode(Double.self, forKey: .blue))
        try validate()
    }

    func validate() throws {
        try PaintToolPresetLimits.validateUnit(red, field: "foregroundColor.red")
        try PaintToolPresetLimits.validateUnit(green, field: "foregroundColor.green")
        try PaintToolPresetLimits.validateUnit(blue, field: "foregroundColor.blue")
    }
}

// MARK: - Limits and errors

/// The accepted numeric limits, taken from the existing UI and native
/// sources (docs/paint-tool-presets.md lists the exact references):
/// native brush-size accepts 1...10,000 px; the facade's field comments
/// (`glims_engine.h`, `GlimsBrushSettings`: opacity, hardness and the sRGB
/// components 0...1, rate/flow/exposure 0...100), and the engine's own
/// check (`Engine/paint.c`, `stroke_begin_common`: `size > 0.0`, opacity
/// clamped to 0...1).
enum PaintToolPresetLimits {
    /// Native brush-size range, shared by all supported engine versions.
    static let maxSize: Double = 10_000
    /// Opacity, hardness and each sRGB component.
    static let unitInterval: ClosedRange<Double> = 0...1
    /// Rate, flow and exposure.
    static let percentRange: ClosedRange<Double> = 0...100
    /// Preset name length, in characters.
    static let maxNameLength = 64

    static func validateSize(_ value: Double) throws {
        guard value.isFinite else { throw PaintToolPresetError.nonFinite(field: "settings.size") }
        guard value >= 1, value <= maxSize else {
            throw PaintToolPresetError.sizeOutOfRange(value)
        }
    }

    static func validateUnit(_ value: Double, field: String) throws {
        guard value.isFinite else { throw PaintToolPresetError.nonFinite(field: field) }
        guard unitInterval.contains(value) else {
            throw PaintToolPresetError.outOfRange(field: field, value: value, range: unitInterval)
        }
    }

    static func validateOptionalUnit(_ value: Double?, field: String) throws {
        if let value { try validateUnit(value, field: field) }
    }

    static func validatePercent(_ value: Double, field: String) throws {
        guard value.isFinite else { throw PaintToolPresetError.nonFinite(field: field) }
        guard percentRange.contains(value) else {
            throw PaintToolPresetError.outOfRange(field: field, value: value, range: percentRange)
        }
    }

    static func validateOptionalPercent(_ value: Double?, field: String) throws {
        if let value { try validatePercent(value, field: field) }
    }
}

/// Every way a preset value or a stored preset document can be invalid.
/// Messages are meant to be shown to the user as-is.
enum PaintToolPresetError: Error, LocalizedError, Equatable, CustomStringConvertible {
    /// A persisted `tool` tag that is not a `ToolID` at all.
    case unknownToolTag(String)
    /// A `ToolID` that is not a paint tool (no `paintTool`).
    case nonPaintTool(ToolID)
    /// A persisted `tones` tag that is not a `ToneRange`.
    case unknownToneRange(String)
    /// The name is empty after trimming.
    case emptyName
    /// The name is longer than `PaintToolPresetLimits.maxNameLength`.
    case nameTooLong(length: Int, max: Int)
    /// Another preset of the same tool already has this name.
    case duplicateName(String, tool: ToolID)
    /// No preset with this UUID is stored.
    case unknownPreset(UUID)
    /// A numeric field is NaN or infinite.
    case nonFinite(field: String)
    /// A numeric field is outside its accepted range.
    case outOfRange(field: String, value: Double, range: ClosedRange<Double>)
    /// `size` must be positive and at most `PaintToolPresetLimits.maxSize`.
    case sizeOutOfRange(Double)
    /// A persisted brush resource `kind` tag other than "brush".
    case invalidResourceKind(String)
    /// The brush resource identity fails its text checks.
    case invalidResourceIdentity(reason: String)
    /// The stored document's schema version is not the supported one.
    case unsupportedSchemaVersion(found: Int, supported: Int)
    /// The stored document has no schema version.
    case missingSchemaVersion
    /// The stored bytes are not a readable document.
    case malformed(String)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .unknownToolTag(let tag):
            return "Unknown paint tool tag \"\(tag)\" in a stored preset."
        case .nonPaintTool(let tool):
            return "\"\(tool.name)\" is not a paint tool; presets exist for paint tools only."
        case .unknownToneRange(let tag):
            return "Unknown tonal range tag \"\(tag)\" in a stored preset."
        case .emptyName:
            return "A preset name must not be empty."
        case .nameTooLong(let length, let max):
            return "A preset name must be at most \(max) characters (got \(length))."
        case .duplicateName(let name, let tool):
            return "The \(tool.name) tool already has a preset named \"\(name)\"."
        case .unknownPreset(let id):
            return "No stored preset has the id \(id.uuidString)."
        case .nonFinite(let field):
            return "The preset field \(field) must be a finite number."
        case .outOfRange(let field, let value, let range):
            return "The preset field \(field) must be between \(range.lowerBound) and \(range.upperBound) (got \(value))."
        case .sizeOutOfRange(let value):
            return "The brush size must be at least 1 and at most \(PaintToolPresetLimits.maxSize) px (got \(value))."
        case .invalidResourceKind(let tag):
            return "A paint tool preset can only reference a brush resource, not \"\(tag)\"."
        case .invalidResourceIdentity(let reason):
            return "The brush resource identity is invalid: \(reason)."
        case .unsupportedSchemaVersion(let found, let supported):
            return "The stored paint tool presets use schema version \(found); this version reads only \(supported). The stored data was left untouched."
        case .missingSchemaVersion:
            return "The stored paint tool presets have no schema version. The stored data was left untouched."
        case .malformed(let detail):
            return "The stored paint tool presets could not be read: \(detail). The stored data was left untouched."
        }
    }
}
