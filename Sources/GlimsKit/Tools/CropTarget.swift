import AppKit
import Foundation

/// The Crop tool's persistent Fixed Target Size settings, as the 1996-era
/// editors offered: a target width, height and optional resolution; the
/// crop rectangle keeps the target's proportions and Return crops and
/// resamples to it as one undo step. Only these plain values cross into
/// UserDefaults.
struct CropTargetSettings: Codable, Equatable {
    var enabled = false
    var width = ""
    var height = ""
    var unit: ImageSizeModel.SizeUnit = .pixels
    /// Empty keeps the image's own resolution at crop time.
    var resolution = ""
    var resolutionUnit: ImageSizeModel.ResolutionUnit = .pixelsPerInch
    var interpolation: EngineSession.Interpolation = .cubic

    /// The defaults: off, empty fields, pixels and the same resampling
    /// default Image Size offers.
    static let `default` = CropTargetSettings()

    /// The entered resolution in pixels per inch, nil when the field is
    /// empty or holds only whitespace. A non-empty field that does not
    /// parse or leaves the engine's range fails the target instead.
    var enteredResolution: EngineSession.ImageResolution? {
        get {
            if resolution.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            guard let value = ImageSizeModel.number(resolution) else { return nil }
            let ppi = value * resolutionUnit.pixelsPerInchPerUnit
            guard ImageSizeModel.isValidResolution(ppi) else { return nil }
            return .init(x: ppi, y: ppi)
        }
        set {
            if let newValue {
                // The shortest exact form, so Front Image does not round
                // the resolution into a change on Return.
                resolution = newValue.x == newValue.x.rounded() && abs(newValue.x) < 1e15
                    ? String(Int(newValue.x)) : String(newValue.x)
                resolutionUnit = .pixelsPerInch
            } else {
                resolution = ""
            }
        }
    }

    /// The resolved target, or nil when Fixed Target Size is off or the
    /// fields do not hold a valid size. Physical units convert at the
    /// entered resolution, or at `imageResolution` when the resolution
    /// field is empty, and round to whole pixels of at least 1.
    func resolved(imageResolution: EngineSession.ImageResolution?) -> CropTarget? {
        guard enabled else { return nil }
        let target = enteredResolution
        // Entered text must parse; only an empty field means "keep".
        let hasResolutionText = !resolution.trimmingCharacters(in: .whitespaces).isEmpty
        if hasResolutionText != (target != nil) { return nil }
        let conversionX = target?.x ?? imageResolution?.x ?? ImageSizeModel.defaultResolution
        let conversionY = target?.y ?? imageResolution?.y ?? ImageSizeModel.defaultResolution
        guard let widthValue = ImageSizeModel.number(width),
              let heightValue = ImageSizeModel.number(height),
              let pixelWidth = unit.pixels(widthValue, resolution: conversionX),
              let pixelHeight = unit.pixels(heightValue, resolution: conversionY),
              ImageSizeModel.isValidPixelWidth(pixelWidth),
              ImageSizeModel.isValidPixelWidth(pixelHeight) else { return nil }
        return CropTarget(width: pixelWidth, height: pixelHeight,
                          resolution: target, interpolation: interpolation)
    }

    /// Front Image: fills width, height and resolution from an image of
    /// `width` x `height` pixels at `resolution` pixels per inch, in
    /// pixels and pixels/inch. The field holds one resolution for both
    /// axes, so a non-square resolution empties it: the crop then keeps
    /// the image's own instead of replacing the vertical resolution with
    /// the horizontal one.
    mutating func fillFromImage(width: Int, height: Int,
                                resolution: EngineSession.ImageResolution?) {
        unit = .pixels
        self.width = String(width)
        self.height = String(height)
        if let resolution, resolution.x == resolution.y {
            enteredResolution = resolution
        } else {
            enteredResolution = nil
        }
    }
}

/// A resolved Fixed Target Size: the pixel size to resample to, the
/// resolution to set (nil keeps the image's own) and the resampling
/// method. The pure constraint lives here so the canvas gesture, the
/// tool options and the tests share it.
struct CropTarget: Equatable {
    let width: Int
    let height: Int
    let resolution: EngineSession.ImageResolution?
    let interpolation: EngineSession.Interpolation

    /// The drag end `point` constrained to the target's proportions from
    /// `start`, in every drag direction: the longer of the two sides wins
    /// and the other follows at the target's shape.
    func constrainedEnd(_ point: CGPoint, from start: CGPoint) -> CGPoint {
        let heightPerWidth = Double(height) / Double(width)
        var dx = point.x - start.x
        var dy = point.y - start.y
        if abs(dx) * heightPerWidth >= abs(dy) {
            dy = abs(dx) * heightPerWidth * (dy < 0 ? -1 : 1)
        } else {
            dx = abs(dy) / heightPerWidth * (dx < 0 ? -1 : 1)
        }
        return CGPoint(x: start.x + dx, y: start.y + dy)
    }
}

/// The persistent Crop tool target, stored through UserDefaults as
/// Codable JSON. Pure value storage (no AppKit, no engine): tests inject
/// a suite's UserDefaults, the app uses `shared`.
final class CropTargetStore {
    static let shared = CropTargetStore(defaults: .standard)

    /// The defaults key; internal so tests can inspect the raw encoded form.
    static let preferencesKey = "editor.cropTarget"

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The stored settings; unreadable or absent data reads as the
    /// defaults (the option off and the fields empty).
    var preferences: CropTargetSettings {
        guard let data = defaults.data(forKey: Self.preferencesKey),
              let decoded = try? JSONDecoder().decode(CropTargetSettings.self, from: data) else {
            return .default
        }
        return decoded
    }

    func set(_ preferences: CropTargetSettings) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(preferences) else { return }
        defaults.set(data, forKey: Self.preferencesKey)
    }
}
