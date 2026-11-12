import CoreGraphics
import Foundation

/// Owned file values. UUIDs identify recordings, symbols and validated,
/// document-scoped persisted ink identity. They never establish a global
/// cross-image binding or carry native runtime IDs, closures or epochs.
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
    /// The nine absolute image-pixel projective coefficients, y down, in
    /// row-major homogeneous order. Projective H and any nonzero scalar
    /// multiple kH describe the same mapping. Stored coefficients are exact
    /// and are never normalized; normalization happens only inside the
    /// source-independent admissibility check.
    struct Projective: Equatable {
        let h00, h01, h02: Double
        let h10, h11, h12: Double
        let h20, h21, h22: Double

        init(h00: Double, h01: Double, h02: Double,
             h10: Double, h11: Double, h12: Double,
             h20: Double, h21: Double, h22: Double) {
            self.h00 = h00; self.h01 = h01; self.h02 = h02
            self.h10 = h10; self.h11 = h11; self.h12 = h12
            self.h20 = h20; self.h21 = h21; self.h22 = h22
        }

        init(_ transform: ProjectiveTransform) {
            h00 = transform.h00; h01 = transform.h01; h02 = transform.h02
            h10 = transform.h10; h11 = transform.h11; h12 = transform.h12
            h20 = transform.h20; h21 = transform.h21; h22 = transform.h22
        }

        /// The same coefficients as a pure `ProjectiveTransform`.
        var projectiveTransform: ProjectiveTransform {
            ProjectiveTransform(h00: h00, h01: h01, h02: h02,
                                h10: h10, h11: h11, h12: h12,
                                h20: h20, h21: h21, h22: h22)
        }

        /// Source-independent admissibility: finite coefficients, a nonzero
        /// matrix, a nonsingular normalized matrix, and not a scalar identity.
        /// The file has no authoritative source rectangle, so no source-center
        /// determinant, near-plane or output-size admission happens here; the
        /// runtime validates against freshly bound layer geometry.
        func validated() throws -> Projective {
            let coefficients = [h00, h01, h02, h10, h11, h12, h20, h21, h22]
            guard coefficients.allSatisfy(\.isFinite) else {
                throw RecorderFileError.invalid("The projective matrix coefficients must be finite.")
            }
            let maximum = coefficients.map(\.magnitude).max() ?? 0
            guard maximum > 0 else {
                throw RecorderFileError.invalid("The projective matrix is zero.")
            }
            // Normalize by the largest magnitude before the existing inverse,
            // so an arbitrary scalar does not overflow the raw determinant.
            // Negative scalar multiples keep the opposite sign, which does
            // not change the represented mapping or nonsingularity.
            let scaled = coefficients.map { $0 / maximum }
            guard scaled.allSatisfy(\.isFinite) else {
                throw RecorderFileError.invalid("The projective matrix cannot be normalized.")
            }
            guard ProjectiveTransform(h00: scaled[0], h01: scaled[1], h02: scaled[2],
                                      h10: scaled[3], h11: scaled[4], h12: scaled[5],
                                      h20: scaled[6], h21: scaled[7], h22: scaled[8]).inverse != nil else {
                throw RecorderFileError.invalid("The projective matrix is singular.")
            }
            // Test the original values so normalization rounding cannot
            // erase a small nonzero coefficient and invent an identity.
            guard !(h00 == h11 && h11 == h22 && h01 == 0 && h02 == 0 &&
                    h10 == 0 && h12 == 0 && h20 == 0 && h21 == 0) else {
                throw RecorderFileError.invalid("The identity projective transform was never admissible.")
            }
            return self
        }

        /// Pure preflight against a freshly bound layer's native bounds.
        /// Symbol descriptions are hints and are never used for this check.
        /// Source-specific threshold, near-plane and size admission belongs
        /// to `ProjectiveTransform.projectedBounds(forSource:)`.
        func outputBounds(for bounds: Rect) -> Rect? {
            guard (try? validated()) != nil,
                  let projected = projectiveTransform.projectedBounds(forSource:
                    CGRect(x: bounds.x, y: bounds.y, width: bounds.width, height: bounds.height)) else { return nil }
            return Rect(x: Double(projected.x), y: Double(projected.y),
                        width: Double(projected.width), height: Double(projected.height))
        }
    }
    /// Glims' owned interpolation tags, not native enum ordinals.
    enum LayerInterpolation: String { case none, linear, cubic, noHalo, loHalo }

    /// Native scalar edits use paper intensity: zero is full ink, one paper.
    struct InkEdit: Equatable {
        enum Operation: String { case fill, clear, invert }
        let operation: Operation
        let intensity: Double
        let opacity: Double

        var isValid: Bool {
            guard [intensity, opacity].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
            switch operation {
            case .fill: return true
            case .clear: return intensity == 1 && opacity == 1
            case .invert: return intensity == 0 && opacity == 1
            }
        }
    }

    /// One ink plane's paper-intensity Levels mapping, with no RGB/TRC tags.
    struct InkLevels: Equatable {
        let lowInput: Double
        let highInput: Double
        let gamma: Double
        let lowOutput: Double
        let highOutput: Double
        let clampInput: Bool
        let clampOutput: Bool

        var isValid: Bool {
            [lowInput, highInput, lowOutput, highOutput].allSatisfy({ $0.isFinite && (0...1).contains($0) }) &&
                gamma.isFinite && (0.1...10).contains(gamma)
        }
    }

    /// One ink plane's paper-intensity Curves mapping: exactly 256 output
    /// samples at inputs i/255 (0 = full ink, 1 = paper), no RGB/TRC tags.
    /// Samples may rise or fall; a nonmonotone table is valid.
    struct InkCurves: Equatable {
        let samples: [Double]

        var isValid: Bool {
            samples.count == 256 && samples.allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
    }

    /// Complete committed Levels values: an owned TRC tag, both clamps and
    /// all five named channels, each with the five native fields. Equal or
    /// inverted endpoints are valid native mappings.
    struct Levels: Equatable {
        /// Glims' owned transfer-curve tags, not native enum ordinals.
        enum TRC: String { case linear, nonlinear, perceptual }
        struct Channel: Equatable {
            let lowInput: Double
            let highInput: Double
            let gamma: Double
            let lowOutput: Double
            let highOutput: Double
        }
        let trc: TRC
        let clampInput: Bool
        let clampOutput: Bool
        let value: Channel
        let red: Channel
        let green: Channel
        let blue: Channel
        let alpha: Channel
    }

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
    /// A committed Transform-tool projective homography in absolute image
    /// pixels. The explicit layer is the record's `layer` binding; the
    /// command itself carries no native identity.
    case transformProjectiveLayer(Projective, interpolation: LayerInterpolation)
    /// A newly applied Levels adjustment with its whole accepted settings.
    /// The explicit layer is the record's `layer` binding; the command
    /// carries no native filter/effect identity.
    case applyLevels(Levels)
    case editInk(InkEdit)
    case applyInkLevels(InkLevels)
    case applyInkCurves(InkCurves)
    /// A newly applied Curves adjustment with its whole accepted settings:
    /// the owned TRC tag and all five named channels, each preserving both
    /// curve representations and the HDR bypass flag. The explicit layer is
    /// the record's `layer` binding; the command carries no native
    /// filter/effect identity.
    case applyCurves(RecorderCurvesValue)
    /// A newly applied Color Balance adjustment with its whole accepted
    /// settings: all three tonal ranges' signed corrections and Preserve
    /// Lightness. The explicit layer is the record's `layer` binding; the
    /// command carries no native filter/effect identity.
    case applyColorBalance(RecorderColorBalanceValue)
    /// A newly applied Hue/Saturation adjustment with its whole accepted
    /// settings: the global overlap plus all seven named ranges' signed
    /// hue, saturation and lightness corrections. The explicit layer is the
    /// record's `layer` binding; the command carries no native
    /// filter/effect identity.
    case applyHueSaturation(RecorderHueSaturationValue)
    /// A newly applied Brightness/Contrast adjustment with its whole
    /// accepted settings. The explicit layer is the record's `layer`
    /// binding; the command carries no native filter/effect identity.
    case applyBrightnessContrast(RecorderBrightnessContrastValue)
    case completeStroke(RecorderStrokeCommand)

    var isTargetIndependent: Bool {
        switch self {
        case .layerProperties, .transformLayer, .transformProjectiveLayer, .applyLevels, .applyCurves, .applyColorBalance, .applyHueSaturation, .applyBrightnessContrast, .completeStroke, .channelToSelection, .editInk, .applyInkLevels, .applyInkCurves: return false
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
