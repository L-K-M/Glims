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
    enum ResolutionUnit: String, CaseIterable, Equatable, Codable {
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
    enum SizeUnit: String, CaseIterable, Equatable, Codable {
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

    private let originalWidth: Int
    private let originalHeight: Int
    /// The pixel size before rounding. Every typed digit is an edit, so
    /// scaling from the rounded size would add up the rounding. An edit
    /// with the proportions free takes the other side as shown, so locking
    /// them again keeps the shown shape.
    private var exactWidth: Double
    private var exactHeight: Double
    var width: Int { Self.pixel(exactWidth) }
    var height: Int { Self.pixel(exactHeight) }
    var resolutionX: Double
    var resolutionY: Double
    var constrainProportions: Bool
    var resample: Bool

    init?(width: Int, height: Int, resolutionX: Double, resolutionY: Double,
          constrainProportions: Bool = true, resample: Bool = true) {
        guard Self.isValidPixelWidth(width), Self.isValidPixelWidth(height),
              Self.isValidResolution(resolutionX), Self.isValidResolution(resolutionY) else { return nil }
        originalWidth = width
        originalHeight = height
        exactWidth = Double(width)
        exactHeight = Double(height)
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

    /// A typed number, with either decimal separator.
    static func number(_ text: String) -> Double? {
        let plain = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(plain), value.isFinite else { return nil }
        return value
    }

    /// The pixel dimension a scaled value rounds to, clamped to the bounds.
    static func pixel(_ value: Double) -> Int {
        guard value.isFinite else { return minimumPixels }
        return Int(min(Double(maximumPixels), max(Double(minimumPixels), value.rounded())))
    }

    /// Takes an unrounded pixel size unless it exceeds the maximum; a
    /// shrink still shows and applies at least one pixel.
    private mutating func setExactPixels(width newWidth: Double, height newHeight: Double) -> Bool {
        let maximum = Double(Self.maximumPixels)
        guard newWidth.isFinite, newHeight.isFinite, newWidth > 0, newHeight > 0,
              newWidth.rounded() <= maximum, newHeight.rounded() <= maximum else { return false }
        exactWidth = newWidth
        exactHeight = newHeight
        return true
    }

    /// Sets both resolutions to `value` in `unit`. With resampling the print
    /// size is fixed and the pixels follow on each axis; without it the
    /// pixels are fixed and the print size follows.
    @discardableResult
    mutating func setResolution(_ value: Double, unit: ResolutionUnit) -> Bool {
        let canonical = value * unit.pixelsPerInchPerUnit
        guard Self.isValidResolution(canonical) else { return false }
        if resample {
            guard setExactPixels(width: exactWidth * (canonical / resolutionX),
                                 height: exactHeight * (canonical / resolutionY)) else { return false }
        }
        resolutionX = canonical
        resolutionY = canonical
        return true
    }

    /// Sets the print width. With resampling the resolution is fixed and the
    /// pixels follow. Without it the pixels are fixed, so both resolutions
    /// move by one factor: only that keeps the picture's shape.
    @discardableResult
    mutating func setPrintWidth(_ value: Double, unit: LengthUnit) -> Bool {
        guard value.isFinite, value > 0 else { return false }
        let inches = value / unit.perInch
        guard inches > 0 else { return false }
        if resample {
            let newWidth = inches * resolutionX
            let newHeight = constrainProportions ? exactHeight * (newWidth / exactWidth) : Double(height)
            return setExactPixels(width: newWidth, height: newHeight)
        }
        let newX = Double(width) / inches
        let newY = resolutionY * (newX / resolutionX)
        guard Self.isValidResolution(newX), Self.isValidResolution(newY) else { return false }
        resolutionX = newX
        resolutionY = newY
        return true
    }

    /// Sets the print height, the vertical counterpart of `setPrintWidth`.
    @discardableResult
    mutating func setPrintHeight(_ value: Double, unit: LengthUnit) -> Bool {
        guard value.isFinite, value > 0 else { return false }
        let inches = value / unit.perInch
        guard inches > 0 else { return false }
        if resample {
            let newHeight = inches * resolutionY
            let newWidth = constrainProportions ? exactWidth * (newHeight / exactHeight) : Double(width)
            return setExactPixels(width: newWidth, height: newHeight)
        }
        let newY = Double(height) / inches
        let newX = resolutionX * (newY / resolutionY)
        guard Self.isValidResolution(newX), Self.isValidResolution(newY) else { return false }
        resolutionX = newX
        resolutionY = newY
        return true
    }

    /// Sets the pixel width; with the proportions constrained the height
    /// follows by the same scale.
    @discardableResult
    mutating func setPixelWidth(_ newWidth: Int) -> Bool {
        guard Self.isValidPixelWidth(newWidth) else { return false }
        let newHeight = constrainProportions ? exactHeight * (Double(newWidth) / exactWidth) : Double(height)
        return setExactPixels(width: Double(newWidth), height: newHeight)
    }

    /// Sets the pixel height, the vertical counterpart of `setPixelWidth`.
    @discardableResult
    mutating func setPixelHeight(_ newHeight: Int) -> Bool {
        guard Self.isValidPixelWidth(newHeight) else { return false }
        let newWidth = constrainProportions ? exactWidth * (Double(newHeight) / exactHeight) : Double(width)
        return setExactPixels(width: newWidth, height: Double(newHeight))
    }

    /// Without resampling the image keeps its own pixels, so turning it off
    /// drops any pixel edit.
    mutating func setResample(_ value: Bool) {
        resample = value
        guard !value else { return }
        exactWidth = Double(originalWidth)
        exactHeight = Double(originalHeight)
    }

    mutating func setConstrainProportions(_ value: Bool) { constrainProportions = value }
}
