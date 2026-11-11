import Foundation

/// Owned file values. File UUIDs identify recordings and symbols only. No
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
    /// The six absolute image-pixel affine coefficients, y down. Owned file
    /// values keep CoreGraphics and native matrix layouts out of the model.
    struct Affine: Equatable {
        let a: Double
        let b: Double
        let c: Double
        let d: Double
        let tx: Double
        let ty: Double

        /// Pure preflight against the freshly bound layer's native bounds.
        /// Symbol descriptions are hints and are never used for this check.
        func outputBounds(for bounds: Rect) -> Rect? {
            let determinant = a * d - b * c
            guard [a, b, c, d, tx, ty].allSatisfy(\.isFinite), determinant.isFinite,
                  abs(determinant) >= 1e-9,
                  a != 1 || b != 0 || c != 0 || d != 1 || tx != 0 || ty != 0 else { return nil }
            guard [bounds.x, bounds.y, bounds.width, bounds.height].allSatisfy(\.isFinite),
                  bounds.width >= 1, bounds.height >= 1 else { return nil }
            let maximumDimension = 524288.0
            let maximumCoordinate = 2 * maximumDimension
            var minX = Double.infinity, minY = Double.infinity
            var maxX = -Double.infinity, maxY = -Double.infinity
            for (x, y) in [(bounds.x, bounds.y), (bounds.x + bounds.width, bounds.y),
                           (bounds.x, bounds.y + bounds.height),
                           (bounds.x + bounds.width, bounds.y + bounds.height)] {
                let resultX = a * x + c * y + tx
                let resultY = b * x + d * y + ty
                guard resultX.isFinite, resultY.isFinite,
                      abs(resultX) <= maximumCoordinate, abs(resultY) <= maximumCoordinate else { return nil }
                minX = min(minX, resultX); maxX = max(maxX, resultX)
                minY = min(minY, resultY); maxY = max(maxY, resultY)
            }
            // Native layer storage grows outward to whole pixel bounds.
            let left = floor(minX), top = floor(minY)
            let width = ceil(maxX) - left, height = ceil(maxY) - top
            guard width.isFinite, height.isFinite, width >= 1, height >= 1,
                  width <= maximumDimension, height <= maximumDimension else { return nil }
            return Rect(x: left, y: top, width: width, height: height)
        }
    }
    /// Glims' owned interpolation tags, not native enum ordinals.
    enum LayerInterpolation: String { case none, linear, cubic, noHalo, loHalo }

    case selectionShape(Shape, Options)
    case selectColor(Point, Options)
    case selectCommand(Selection, radius: Double)
    /// Channel ▸ To Selection: only the combination operation is a command
    /// value; the explicit source channel is the record's `channel` binding.
    case channelToSelection(Operation)
    case transformImage(Transform)
    case scale(width: Int, height: Int)
    case resizeCanvas(width: Int, height: Int, offset: Point, fill: RecorderColor)
    case crop(Rect)
    case layerProperties(LayerProperties)
    /// A committed Transform-tool affine. The explicit layer is the record's
    /// `layer` binding; the command itself carries no native identity.
    case transformLayer(Affine, interpolation: LayerInterpolation)
    case completeStroke(RecorderStrokeCommand)

    var isTargetIndependent: Bool {
        switch self {
        case .layerProperties, .transformLayer, .completeStroke, .channelToSelection: return false
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
    // Successful polygons and strokes share the file's point budget.
    static let points = 100_000
    static let stringBytes = 64 * 1024
    static let depth = 64
    static let values = 1_000_000
    static let numberBytes = 128

    static func strokePointCount(_ trace: RecorderStrokeTrace, remaining: Int) throws -> Int {
        let maximum = min(remaining, RecorderStrokeAccumulator.maximumPoints)
        guard maximum >= 1 else { throw RecorderFileError.invalid("Invalid stroke point count.") }
        var count = 1
        for batch in trace.batches {
            guard !batch.isEmpty, batch.count <= maximum - count else {
                throw RecorderFileError.invalid("Invalid stroke point count or empty batch.")
            }
            count += batch.count
        }
        return count
    }
}
