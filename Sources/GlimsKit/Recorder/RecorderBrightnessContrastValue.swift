import Foundation

/// A detached Brightness/Contrast settings value. Owned field names keep the
/// native struct layout out of the model; both corrections are preserved
/// exactly as the committed native settings carried them.
struct RecorderBrightnessContrastValue: Equatable {
    let brightness: Double
    let contrast: Double

    /// Caller-built values are not trusted: `settings()` and the file codec
    /// revalidate both fields before use.
    init(brightness: Double, contrast: Double) {
        self.brightness = brightness
        self.contrast = contrast
    }

    func validated() throws -> RecorderBrightnessContrastValue {
        guard [brightness, contrast].allSatisfy({ $0.isFinite && (-1...1).contains($0) }) else {
            throw RecorderFileError.invalid("A recorded Brightness/Contrast value is not a finite −1...1 value.")
        }
        return self
    }

    /// Bridge in: validates and detaches committed facade settings. An invalid
    /// native value refuses instead of producing a partial value.
    init(_ settings: EngineSession.BrightnessContrastSettings) throws {
        guard settings.isValid else {
            throw RecorderFileError.invalid("A recorded Brightness/Contrast value is outside the native range.")
        }
        self.init(brightness: settings.brightness, contrast: settings.contrast)
    }

    /// Bridge out: revalidates every field a caller could have built by hand
    /// before restoring exact facade settings.
    func settings() throws -> EngineSession.BrightnessContrastSettings {
        let value = try validated()
        return EngineSession.BrightnessContrastSettings(brightness: value.brightness, contrast: value.contrast)
    }
}
