import Foundation

/// A detached Image > Adjust > Variations value. The three tonal ranges
/// keep their signed corrections, and the master lightness and saturation
/// travel alongside them. An identity is refused: a Variations row always
/// represents a change.
struct RecorderVariationsValue: Equatable {
    /// One tonal range's three signed corrections, each a finite −1...1
    /// fraction of the native slider.
    struct Range: Equatable {
        let cyanRed: Double
        let magentaGreen: Double
        let yellowBlue: Double

        func validated() throws -> Range {
            guard [cyanRed, magentaGreen, yellowBlue]
                .allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
                throw RecorderFileError.invalid("A recorded Variations correction is not a finite −1...1 value.")
            }
            return self
        }
    }

    let shadows: Range
    let midtones: Range
    let highlights: Range
    let lightness: Double
    let saturation: Double

    init(shadows: Range, midtones: Range, highlights: Range, lightness: Double, saturation: Double) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.lightness = lightness
        self.saturation = saturation
    }

    func validated() throws -> RecorderVariationsValue {
        _ = try shadows.validated()
        _ = try midtones.validated()
        _ = try highlights.validated()
        guard lightness.isFinite, (-1...1).contains(lightness),
              saturation.isFinite, (-1...1).contains(saturation) else {
            throw RecorderFileError.invalid("A recorded Variations lightness or saturation is outside −1...1.")
        }
        guard !(shadows.cyanRed == 0 && shadows.magentaGreen == 0 && shadows.yellowBlue == 0 &&
                midtones.cyanRed == 0 && midtones.magentaGreen == 0 && midtones.yellowBlue == 0 &&
                highlights.cyanRed == 0 && highlights.magentaGreen == 0 && highlights.yellowBlue == 0 &&
                lightness == 0 && saturation == 0) else {
            throw RecorderFileError.invalid("A recorded Variations row changes nothing.")
        }
        return self
    }

    /// Bridge in: validates and detaches committed facade settings.
    init(_ settings: EngineSession.VariationsSettings) throws {
        guard settings.isValid, !settings.isIdentity else {
            throw RecorderFileError.invalid("A recorded Variations value changes nothing.")
        }
        func range(_ source: EngineSession.ColorBalanceSettings.Range) -> Range {
            .init(cyanRed: source.cyanRed, magentaGreen: source.magentaGreen, yellowBlue: source.yellowBlue)
        }
        self.init(shadows: range(settings.shadows), midtones: range(settings.midtones),
                  highlights: range(settings.highlights),
                  lightness: settings.lightness, saturation: settings.saturation)
    }

    /// Bridge out: revalidates every field before restoring exact facade
    /// settings.
    func settings() throws -> EngineSession.VariationsSettings {
        let value = try validated()
        func range(_ source: Range) -> EngineSession.ColorBalanceSettings.Range {
            .init(cyanRed: source.cyanRed, magentaGreen: source.magentaGreen, yellowBlue: source.yellowBlue)
        }
        return EngineSession.VariationsSettings(shadows: range(value.shadows),
                                                midtones: range(value.midtones),
                                                highlights: range(value.highlights),
                                                lightness: value.lightness,
                                                saturation: value.saturation)
    }
}
