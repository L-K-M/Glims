import Foundation

/// Pure print and pixel geometry for Image > Image Size and File > New.
/// The canonical resolution is pixels per inch; every unit conversion and
/// rounding decision lives here so the sheets and the tests share it.
struct ImageSizeModel: Equatable {
    /// A print dimension's unit. These are the units Image > Image Size
    /// offers for the print width and height.
    enum LengthUnit: String, CaseIterable, Equatable {
        case inches, centimeters, millimeters, points, picas

        var title: String {
            switch self {
            case .inches: return "Inches"
            case .centimeters: return "Centimeters"
            case .millimeters: return "Millimeters"
            case .points: return "Points"
            case .picas: return "Picas"
            }
        }

        /// Units per inch.
        var perInch: Double {
            switch self {
            case .inches: return 1
            case .centimeters: return 2.54
            case .millimeters: return 25.4
            case .points: return 72
            case .picas: return 6
            }
        }
    }

    /// A resolution's unit, as Image > Image Size displays it.
    enum ResolutionUnit: String, CaseIterable, Equatable {
        case pixelsPerInch, pixelsPerCentimeter

        var title: String {
            switch self {
            case .pixelsPerInch: return "pixels/inch"
            case .pixelsPerCentimeter: return "pixels/cm"
            }
        }

        /// Canonical pixels per inch in one displayed unit.
        var pixelsPerInchPerUnit: Double {
            switch self {
            case .pixelsPerInch: return 1
            case .pixelsPerCentimeter: return 2.54
            }
        }
    }

    /// A width or height unit in File > New, where pixels are a choice too.
    enum SizeUnit: String, CaseIterable, Equatable {
        case pixels, inches, centimeters, millimeters

        var title: String {
            switch self {
            case .pixels: return "px"
            case .inches: return "in"
            case .centimeters: return "cm"
            case .millimeters: return "mm"
            }
        }

        /// Units per inch, or nil for pixels.
        var perInch: Double? {
            switch self {
            case .pixels: return nil
            case .inches: return 1
            case .centimeters: return 2.54
            case .millimeters: return 25.4
            }
        }

        /// The whole pixel dimension for `value` in this unit at
        /// `resolution` pixels per inch, or nil when the text is not a
        /// valid positive dimension. Pixels must be a whole number; the
        /// length units round to the nearest pixel.
        func pixels(_ value: Double, resolution: Double) -> Int? {
            guard value.isFinite, value > 0, ImageSizeModel.isValidResolution(resolution) else { return nil }
            guard let perInch else {
                guard value >= Double(ImageSizeModel.minimumPixels),
                      value <= Double(ImageSizeModel.maximumPixels),
                      value == value.rounded() else { return nil }
                return Int(value)
            }
            let product = value / perInch * resolution
            guard product.isFinite, product <= Double(ImageSizeModel.maximumPixels) else { return nil }
            return ImageSizeModel.pixel(product)
        }
    }

    /// GIMP's own resolution bounds, owned by the facade and mirrored here.
    static let minimumResolution: Double = 0.005
    static let maximumResolution: Double = 1_048_576
    static let minimumPixels = 1
    static let maximumPixels = 524_288
    /// File > New's default resolution.
    static let defaultResolution: Double = 72

    var width: Int
    var height: Int
    var resolutionX: Double
    var resolutionY: Double
    var constrainProportions: Bool
    var resample: Bool

    init?(width: Int, height: Int, resolutionX: Double, resolutionY: Double,
          constrainProportions: Bool = true, resample: Bool = true) {
        guard Self.isValidPixelWidth(width), Self.isValidPixelWidth(height),
              Self.isValidResolution(resolutionX), Self.isValidResolution(resolutionY) else { return nil }
        self.width = width
        self.height = height
        self.resolutionX = resolutionX
        self.resolutionY = resolutionY
        self.constrainProportions = constrainProportions
        self.resample = resample
    }

    static func isValidPixelWidth(_ value: Int) -> Bool {
        (minimumPixels...maximumPixels).contains(value)
    }

    static func isValidResolution(_ value: Double) -> Bool {
        value.isFinite && (minimumResolution...maximumResolution).contains(value)
    }

    var printWidthInInches: Double { Double(width) / resolutionX }
    var printHeightInInches: Double { Double(height) / resolutionY }

    func printWidth(in unit: LengthUnit) -> Double { printWidthInInches * unit.perInch }
    func printHeight(in unit: LengthUnit) -> Double { printHeightInInches * unit.perInch }
    func resolutionX(in unit: ResolutionUnit) -> Double { resolutionX / unit.pixelsPerInchPerUnit }
    func resolutionY(in unit: ResolutionUnit) -> Double { resolutionY / unit.pixelsPerInchPerUnit }

    /// The pixel dimension a scaled value rounds to, clamped to the bounds.
    static func pixel(_ value: Double) -> Int {
        guard value.isFinite else { return minimumPixels }
        return min(maximumPixels, max(minimumPixels, Int(value.rounded())))
    }

    /// A scaled pixel dimension, or nil when the rounded value would exceed
    /// the maximum; a shrink still rounds and clamps up to one pixel.
    private static func scaledPixel(_ value: Double) -> Int? {
        guard value.isFinite, value.rounded() <= Double(maximumPixels) else { return nil }
        return pixel(value)
    }

    /// Sets both resolutions to `value` in `unit`. With resampling the print
    /// size is fixed and the pixels follow; without it the pixels are fixed
    /// and the print size follows. The two resolutions stay equal after an
    /// edit; a differing pair is only ever changed here, never by a width or
    /// height edit.
    @discardableResult
    mutating func setResolution(_ value: Double, unit: ResolutionUnit) -> Bool {
        let canonical = value * unit.pixelsPerInchPerUnit
        guard Self.isValidResolution(canonical) else { return false }
        if resample {
            let scaleX = canonical / resolutionX
            if constrainProportions {
                guard let scaledWidth = Self.scaledPixel(Double(width) * scaleX),
                      let scaledHeight = Self.scaledPixel(Double(height) * scaleX) else { return false }
                width = scaledWidth
                height = scaledHeight
            } else {
                let scaleY = canonical / resolutionY
                guard let scaledWidth = Self.scaledPixel(Double(width) * scaleX),
                      let scaledHeight = Self.scaledPixel(Double(height) * scaleY) else { return false }
                width = scaledWidth
                height = scaledHeight
            }
        }
        resolutionX = canonical
        resolutionY = canonical
        return true
    }

    /// Sets the print width. With resampling the resolution is fixed and the
    /// pixels follow; without it the pixels are fixed and the resolution
    /// moves inversely.
    @discardableResult
    mutating func setPrintWidth(_ value: Double, unit: LengthUnit) -> Bool {
        guard value.isFinite, value > 0 else { return false }
        let inches = value / unit.perInch
        guard inches > 0 else { return false }
        if resample {
            let oldWidth = width
            guard let newWidth = Self.scaledPixel(inches * resolutionX) else { return false }
            if constrainProportions, oldWidth > 0 {
                guard let scaledHeight = Self.scaledPixel(Double(height) * Double(newWidth) / Double(oldWidth)) else { return false }
                height = scaledHeight
            }
            width = newWidth
        } else {
            let newResolution = Double(width) / inches
            guard Self.isValidResolution(newResolution) else { return false }
            resolutionX = newResolution
        }
        return true
    }

    /// Sets the print height, the vertical counterpart of `setPrintWidth`.
    @discardableResult
    mutating func setPrintHeight(_ value: Double, unit: LengthUnit) -> Bool {
        guard value.isFinite, value > 0 else { return false }
        let inches = value / unit.perInch
        guard inches > 0 else { return false }
        if resample {
            let oldHeight = height
            guard let newHeight = Self.scaledPixel(inches * resolutionY) else { return false }
            if constrainProportions, oldHeight > 0 {
                guard let scaledWidth = Self.scaledPixel(Double(width) * Double(newHeight) / Double(oldHeight)) else { return false }
                width = scaledWidth
            }
            height = newHeight
        } else {
            let newResolution = Double(height) / inches
            guard Self.isValidResolution(newResolution) else { return false }
            resolutionY = newResolution
        }
        return true
    }

    /// Sets the pixel width; with the proportions constrained the height
    /// follows by the same scale.
    @discardableResult
    mutating func setPixelWidth(_ newWidth: Int) -> Bool {
        guard Self.isValidPixelWidth(newWidth) else { return false }
        if constrainProportions, width > 0 {
            guard let scaledHeight = Self.scaledPixel(Double(height) * Double(newWidth) / Double(width)) else { return false }
            height = scaledHeight
        }
        width = newWidth
        return true
    }

    /// Sets the pixel height, the vertical counterpart of `setPixelWidth`.
    @discardableResult
    mutating func setPixelHeight(_ newHeight: Int) -> Bool {
        guard Self.isValidPixelWidth(newHeight) else { return false }
        if constrainProportions, height > 0 {
            guard let scaledWidth = Self.scaledPixel(Double(width) * Double(newHeight) / Double(height)) else { return false }
            width = scaledWidth
        }
        height = newHeight
        return true
    }

    mutating func setResample(_ value: Bool) { resample = value }
    mutating func setConstrainProportions(_ value: Bool) { constrainProportions = value }
}
