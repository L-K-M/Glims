import AppKit

/// Quick Mask binding metadata reads components that travelled through GEGL's
/// Float representation. The pinned default red was three Float steps above 1.
/// Allow four steps of endpoint roundoff while retaining exact interior values.
enum RecorderQuickMaskColor {
    private static let endpointTolerance = 4 * Double(Float.ulpOfOne)

    static func canonical(red: Double, green: Double, blue: Double, alpha: Double) throws -> RecorderColor {
        func component(_ value: Double) throws -> Double {
            guard value.isFinite, value >= -endpointTolerance, value <= 1 + endpointTolerance else {
                throw RecorderFileError.invalid("The Quick Mask color is outside the recording's supported sRGB range.")
            }
            if value < 0 { return 0 }
            if value > 1 { return 1 }
            return value
        }
        return try RecorderColor(red: component(red), green: component(green),
                                 blue: component(blue), alpha: component(alpha))
    }

    static func canonical(_ state: EngineSession.QuickMaskState) throws -> RecorderColor {
        // EngineSession and loaded Recorder contexts both construct an RGB
        // component color. Read that representation without a second conversion.
        let color = state.color
        return try canonical(red: Double(color.redComponent), green: Double(color.greenComponent),
                             blue: Double(color.blueComponent), alpha: Double(color.alphaComponent))
    }

    static func matches(_ actual: EngineSession.QuickMaskState, _ expected: EngineSession.QuickMaskState) -> Bool {
        guard actual.enabled == expected.enabled, actual.channel == expected.channel,
              actual.inverted == expected.inverted,
              let actualColor = try? canonical(actual), let expectedColor = try? canonical(expected) else { return false }
        return actualColor == expectedColor
    }
}
