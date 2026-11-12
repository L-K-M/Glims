import Foundation

/// A detached Hue/Saturation settings value. Owned field names keep native
/// struct layouts and range ordinals out of the model; every named range
/// preserves all three corrections and the global Overlap exactly as the
/// committed native settings carried them.
struct RecorderHueSaturationValue: Equatable {
    /// One named range's three signed corrections, each a finite −1...1
    /// fraction of the native sliders (hue over its ±180° scale,
    /// saturation and lightness over ±100%).
    struct Range: Equatable {
        let hue: Double
        let saturation: Double
        let lightness: Double

        /// Enforces the same contract as the typed native settings.
        func validated() throws -> Range {
            guard [hue, saturation, lightness].allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
                throw RecorderFileError.invalid("A recorded Hue/Saturation correction is not a finite −1...1 value.")
            }
            return self
        }
    }

    let overlap: Double
    let master: Range
    let red: Range
    let yellow: Range
    let green: Range
    let cyan: Range
    let blue: Range
    let magenta: Range

    /// Caller-built values are not trusted: `settings()` and the file codec
    /// revalidate every field before use.
    init(overlap: Double, master: Range, red: Range, yellow: Range,
         green: Range, cyan: Range, blue: Range, magenta: Range) {
        self.overlap = overlap
        self.master = master
        self.red = red
        self.yellow = yellow
        self.green = green
        self.cyan = cyan
        self.blue = blue
        self.magenta = magenta
    }

    func validated() throws -> RecorderHueSaturationValue {
        guard overlap.isFinite, (0...1).contains(overlap) else {
            throw RecorderFileError.invalid("A recorded Hue/Saturation overlap is not a finite 0...1 value.")
        }
        _ = try master.validated()
        _ = try red.validated()
        _ = try yellow.validated()
        _ = try green.validated()
        _ = try cyan.validated()
        _ = try blue.validated()
        _ = try magenta.validated()
        return self
    }

    /// Bridge in: validates and detaches committed facade settings. An
    /// invalid native value refuses instead of producing a partial value.
    init(_ settings: EngineSession.HueSaturationSettings) throws {
        guard settings.isValid else {
            throw RecorderFileError.invalid("A recorded Hue/Saturation value is outside the native range.")
        }
        func range(_ source: EngineSession.HueSaturationSettings.Range) -> Range {
            .init(hue: source.hue, saturation: source.saturation, lightness: source.lightness)
        }
        self.init(overlap: settings.overlap, master: range(settings.master), red: range(settings.red),
                  yellow: range(settings.yellow), green: range(settings.green), cyan: range(settings.cyan),
                  blue: range(settings.blue), magenta: range(settings.magenta))
    }

    /// Bridge out: revalidates every field a caller could have built by hand
    /// before restoring exact facade settings.
    func settings() throws -> EngineSession.HueSaturationSettings {
        let value = try validated()
        func range(_ source: Range) -> EngineSession.HueSaturationSettings.Range {
            .init(hue: source.hue, saturation: source.saturation, lightness: source.lightness)
        }
        return EngineSession.HueSaturationSettings(overlap: value.overlap, master: range(value.master),
            red: range(value.red), yellow: range(value.yellow), green: range(value.green),
            cyan: range(value.cyan), blue: range(value.blue), magenta: range(value.magenta))
    }
}
