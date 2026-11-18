import Foundation

/// The Color palette's slider sets, chosen from its palette menu as in
/// Photoshop 4. CMYK and Lab sliders are not offered: the tool colors are
/// sRGB and Glims has no color-managed CMYK or Lab conversion for them.
enum ColorSliderMode: String, CaseIterable {
    case rgb, hsb, grayscale

    var menuTitle: String {
        switch self {
        case .rgb: return "RGB Sliders"
        case .hsb: return "HSB Sliders"
        case .grayscale: return "Grayscale Slider"
        }
    }

    var channels: [ColorSliderChannel] {
        switch self {
        case .rgb:
            return [ColorSliderChannel(label: "R", name: "Red", maximum: 255, unit: ""),
                    ColorSliderChannel(label: "G", name: "Green", maximum: 255, unit: ""),
                    ColorSliderChannel(label: "B", name: "Blue", maximum: 255, unit: "")]
        case .hsb:
            return [ColorSliderChannel(label: "H", name: "Hue", maximum: 360, unit: "°"),
                    ColorSliderChannel(label: "S", name: "Saturation", maximum: 100, unit: "%"),
                    ColorSliderChannel(label: "B", name: "Brightness", maximum: 100, unit: "%")]
        case .grayscale:
            return [ColorSliderChannel(label: "K", name: "Black", maximum: 100, unit: "%")]
        }
    }
}

/// One slider: its short label, its spoken name, and its range 0 ... maximum
/// in the units the palette shows.
struct ColorSliderChannel: Equatable {
    let label: String
    let name: String
    let maximum: Double
    let unit: String
}

/// Hue in degrees (0 ..< 360), saturation and brightness in 0 ... 1, of an
/// sRGB color.
struct HSBComponents: Equatable {
    var hue: Double
    var saturation: Double
    var brightness: Double

    init(hue: Double, saturation: Double, brightness: Double) {
        self.hue = hue
        self.saturation = saturation
        self.brightness = brightness
    }

    init(_ color: Swatch) {
        let high = max(color.red, color.green, color.blue)
        let delta = high - min(color.red, color.green, color.blue)
        brightness = high
        saturation = high > 0 ? delta / high : 0
        guard delta > 0 else {
            hue = 0
            return
        }
        let sector: Double
        if high == color.red {
            sector = (color.green - color.blue) / delta
        } else if high == color.green {
            sector = (color.blue - color.red) / delta + 2
        } else {
            sector = (color.red - color.green) / delta + 4
        }
        let degrees = sector * 60
        hue = degrees < 0 ? degrees + 360 : degrees
    }

    var color: Swatch {
        let chroma = brightness * saturation
        let sector = hue.truncatingRemainder(dividingBy: 360) / 60
        let second = chroma * (1 - abs(sector.truncatingRemainder(dividingBy: 2) - 1))
        let (red, green, blue): (Double, Double, Double)
        switch sector {
        case ..<1: (red, green, blue) = (chroma, second, 0)
        case ..<2: (red, green, blue) = (second, chroma, 0)
        case ..<3: (red, green, blue) = (0, chroma, second)
        case ..<4: (red, green, blue) = (0, second, chroma)
        case ..<5: (red, green, blue) = (second, 0, chroma)
        default: (red, green, blue) = (chroma, 0, second)
        }
        let offset = brightness - chroma
        return Swatch(red: red + offset, green: green + offset, blue: blue + offset)
    }
}

/// The slider state for one tool color: the exact color plus the hue and
/// saturation it last had. A gray has no hue and black no saturation, so
/// dragging Saturation or Brightness to zero and back keeps them, as in
/// Photoshop. Pure, so the rules are unit-tested without a palette.
struct ColorSliderState: Equatable {
    private(set) var color: Swatch
    private(set) var hsb: HSBComponents

    init(color: Swatch) {
        self.color = color
        hsb = HSBComponents(color)
    }

    /// Takes a color set elsewhere (the Tools palette, a swatch, the
    /// eyedropper), keeping the hue and saturation it cannot express.
    mutating func sync(_ next: Swatch) {
        guard next != color else { return }
        color = next
        hsb = Self.retaining(HSBComponents(next), from: hsb)
    }

    /// The slider values in `mode`'s units.
    func values(_ mode: ColorSliderMode) -> [Double] {
        switch mode {
        case .rgb: return [color.red * 255, color.green * 255, color.blue * 255]
        case .hsb: return [hsb.hue, hsb.saturation * 100, hsb.brightness * 100]
        case .grayscale: return [(1 - Self.luminance(color)) * 100]
        }
    }

    /// Sets slider `index` of `mode` to `value`, in the slider's units. A
    /// value that is not a finite number in the slider's range is refused
    /// (false) and nothing changes; values are never clamped.
    mutating func set(_ value: Double, channel index: Int, mode: ColorSliderMode) -> Bool {
        let channels = mode.channels
        guard channels.indices.contains(index), value.isFinite,
              value >= 0, value <= channels[index].maximum else { return false }

        switch mode {
        case .rgb:
            var next = color
            let component = value / 255
            switch index {
            case 0: next.red = component
            case 1: next.green = component
            default: next.blue = component
            }
            sync(next)
        case .hsb:
            var next = hsb
            switch index {
            case 0: next.hue = value == 360 ? 0 : value
            case 1: next.saturation = value / 100
            default: next.brightness = value / 100
            }
            hsb = next
            color = next.color
        case .grayscale:
            let level = 1 - value / 100
            sync(Swatch(red: level, green: level, blue: level))
        }
        return true
    }

    /// Photoshop's color bar: hues left to right, white at the top, full
    /// strength in the middle and black at the bottom. `x` and `y` are
    /// fractions of the bar, top-left origin, clamped to 0 ... 1.
    static func colorBar(x: Double, y: Double) -> Swatch {
        let x = x.isFinite ? min(1, max(0, x)) : 0
        let y = y.isFinite ? min(1, max(0, y)) : 0
        let hue = x * 360
        if y < 0.5 {
            return HSBComponents(hue: hue, saturation: y * 2, brightness: 1).color
        }
        return HSBComponents(hue: hue, saturation: 1, brightness: 1 - (y - 0.5) * 2).color
    }

    /// The gray level the Grayscale slider shows: Rec. 601 luma of the
    /// sRGB values, the weighting Photoshop's grayscale readouts use.
    static func luminance(_ color: Swatch) -> Double {
        0.299 * color.red + 0.587 * color.green + 0.114 * color.blue
    }

    private static func retaining(_ next: HSBComponents, from previous: HSBComponents) -> HSBComponents {
        var result = next
        if next.brightness == 0 {
            result.hue = previous.hue
            result.saturation = previous.saturation
        } else if next.saturation == 0 {
            result.hue = previous.hue
        }
        return result
    }
}
