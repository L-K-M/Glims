import Foundation

/// A detached Color Balance settings value. Owned field names keep native
/// struct layouts out of the model; every tonal range preserves all three
/// corrections and the Preserve Lightness flag exactly as the committed
/// native settings carried them.
struct RecorderColorBalanceValue: Equatable {
    /// One tonal range's three signed corrections, each a finite −1...1
    /// fraction of the native percentage sliders.
    struct Range: Equatable {
        let cyanRed: Double
        let magentaGreen: Double
        let yellowBlue: Double

        /// Enforces the same contract as the typed native settings.
        func validated() throws -> Range {
            guard [cyanRed, magentaGreen, yellowBlue].allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
                throw RecorderFileError.invalid("A recorded Color Balance correction is not a finite −1...1 value.")
            }
            return self
        }
    }

    let shadows: Range
    let midtones: Range
    let highlights: Range
    let preserveLuminosity: Bool

    /// Caller-built values are not trusted: `settings()` and the file codec
    /// revalidate every field before use.
    init(shadows: Range, midtones: Range, highlights: Range, preserveLuminosity: Bool) {
        self.shadows = shadows
        self.midtones = midtones
        self.highlights = highlights
        self.preserveLuminosity = preserveLuminosity
    }

    func validated() throws -> RecorderColorBalanceValue {
        _ = try shadows.validated()
        _ = try midtones.validated()
        _ = try highlights.validated()
        return self
    }

    /// Bridge in: validates and detaches committed facade settings. An
    /// invalid native value refuses instead of producing a partial value.
    init(_ settings: EngineSession.ColorBalanceSettings) throws {
        guard settings.isValid else {
            throw RecorderFileError.invalid("A recorded Color Balance value is outside the native range.")
        }
        func range(_ source: EngineSession.ColorBalanceSettings.Range) -> Range {
            .init(cyanRed: source.cyanRed, magentaGreen: source.magentaGreen, yellowBlue: source.yellowBlue)
        }
        self.init(shadows: range(settings.shadows), midtones: range(settings.midtones),
                  highlights: range(settings.highlights), preserveLuminosity: settings.preserveLuminosity)
    }

    /// Bridge out: revalidates every field a caller could have built by hand
    /// before restoring exact facade settings.
    func settings() throws -> EngineSession.ColorBalanceSettings {
        let value = try validated()
        func range(_ source: Range) -> EngineSession.ColorBalanceSettings.Range {
            .init(cyanRed: source.cyanRed, magentaGreen: source.magentaGreen, yellowBlue: source.yellowBlue)
        }
        return EngineSession.ColorBalanceSettings(shadows: range(value.shadows),
            midtones: range(value.midtones), highlights: range(value.highlights),
            preserveLuminosity: value.preserveLuminosity)
    }
}
