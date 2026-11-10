import Foundation

/// Version-one file values. File UUIDs identify recordings/symbols only; no
/// native identity, executable closure or runtime epoch can enter this model.
struct RecorderFileValue: Equatable {
    struct Origin: Equatable {
        let imageLabel: String
        let initialWidth: Int
        let initialHeight: Int
    }
    struct Symbol: Equatable {
        let id: UUID
        let description: RecorderTargetDescription
    }
    enum Outcome: Equatable {
        case success(RecorderFileCommand, RecorderBindingDescription)
        case failure(String)
        case cancelled(String)
    }
    struct Record: Equatable {
        let ordinal: Int
        let outcome: Outcome
    }

    let recordingID: UUID
    let name: String
    let origin: Origin
    let symbols: [Symbol]
    let records: [Record]
}

enum RecorderFileCommand: Equatable {
    struct Point: Equatable { let x: Double; let y: Double }
    struct Rect: Equatable { let x: Double; let y: Double; let width: Double; let height: Double }
    enum Operation: String { case replace, add, subtract, intersect }
    enum Selection: String { case all, none, invert, feather, grow, shrink, border, sharpen, fromAlpha }
    enum Transform: String { case rotate90, rotate180, rotate270, flipHorizontal, flipVertical }
    struct Options: Equatable {
        let operation: Operation
        let antialias: Bool
        let feather: Double
        let cornerRadius: Double
        let threshold: Double
        let contiguous: Bool
        let sampleMerged: Bool
    }
    enum Shape: Equatable { case rectangle(Rect), ellipse(Rect), polygon([Point]) }
    struct LayerProperties: Equatable {
        let name: String?
        let visible: Bool?
        let opacity: Double?
        let mode: RecorderFileLayerMode?
    }

    case selectionShape(Shape, Options)
    case selectColor(Point, Options)
    case selectCommand(Selection, radius: Double)
    case transformImage(Transform)
    case scale(width: Int, height: Int)
    case resizeCanvas(width: Int, height: Int, offset: Point, fill: RecorderColor)
    case crop(Rect)
    case layerProperties(LayerProperties)

    var isTargetIndependent: Bool {
        switch self {
        case .layerProperties: return false
        case .selectColor(_, let options): return options.sampleMerged
        case .selectCommand(.fromAlpha, _): return false
        case .selectCommand, .selectionShape, .transformImage, .scale, .resizeCanvas, .crop: return true
        }
    }
}

/// Glims' version-one string catalog, not native enum ordinals. These 59 tags
/// cover the layer/group contexts in both pinned 3.0.8 and 3.2.8 tables.
struct RecorderFileLayerMode: Equatable {
    let name: String

    init(_ name: String) throws {
        guard Self.names.contains(name) else { throw RecorderFileError.invalid("Unknown layer mode: \(name)") }
        self.name = name
    }

    static let names: Set<String> = [
        "normal-legacy", "dissolve", "multiply-legacy", "screen-legacy", "overlay-legacy",
        "difference-legacy", "addition-legacy", "subtract-legacy", "darken-only-legacy",
        "lighten-only-legacy", "hsv-hue-legacy", "hsv-saturation-legacy", "hsl-color-legacy",
        "hsv-value-legacy", "divide-legacy", "dodge-legacy", "burn-legacy", "hardlight-legacy",
        "softlight-legacy", "grain-extract-legacy", "grain-merge-legacy", "overlay", "lch-hue",
        "lch-chroma", "lch-color", "lch-lightness", "normal", "multiply", "screen", "difference",
        "addition", "subtract", "darken-only", "lighten-only", "hsv-hue", "hsv-saturation",
        "hsl-color", "hsv-value", "divide", "dodge", "burn", "hardlight", "softlight",
        "grain-extract", "grain-merge", "vivid-light", "pin-light", "linear-light", "hard-mix",
        "exclusion", "linear-burn", "luma-darken-only", "luma-lighten-only", "luminance",
        "color-erase", "erase", "merge", "split", "pass-through",
    ]
}

enum RecorderFileError: Error, LocalizedError, Equatable {
    case invalid(String)
    var errorDescription: String? { switch self { case .invalid(let reason): return reason } }
}

/// File-format resource policy, not limits of the native image engine.
enum RecorderFileLimits {
    static let bytes = 16 * 1024 * 1024
    static let records = 10_000
    static let symbols = 10_000
    static let polygonPoints = 100_000
    static let stringBytes = 64 * 1024
    static let depth = 64
    static let values = 1_000_000
    static let numberBytes = 128
}
