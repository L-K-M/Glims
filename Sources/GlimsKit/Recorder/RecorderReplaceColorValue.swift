import Foundation

/// A detached Image > Adjust > Replace Color value. The fuzziness, sampled
/// colors and the three corrections travel as owned numbers, colors and a
/// Boolean; no native property names or enum ordinals cross the file. Every
/// field is revalidated before the value reaches the file.
struct RecorderReplaceColorValue: Equatable {
    struct Sample: Equatable {
        let red: Double
        let green: Double
        let blue: Double
        let subtract: Bool

        /// Components may lie slightly outside 0...1, but must be finite.
        func validated() throws -> Sample {
            guard red.isFinite && green.isFinite && blue.isFinite else {
                throw RecorderFileError.invalid("A recorded Replace Color sample is not a finite color.")
            }
            return self
        }
    }

    /// Mirrors GLIMS_REPLACE_COLOR_MAX_SAMPLES in the facade header.
    static let maximumSamples = 8

    let fuzziness: Double
    let samples: [Sample]
    let hue: Double
    let saturation: Double
    let lightness: Double

    init(fuzziness: Double, samples: [Sample], hue: Double, saturation: Double, lightness: Double) {
        self.fuzziness = fuzziness
        self.samples = samples
        self.hue = hue
        self.saturation = saturation
        self.lightness = lightness
    }

    func validated() throws -> RecorderReplaceColorValue {
        guard fuzziness.isFinite, (0...200).contains(fuzziness) else {
            throw RecorderFileError.invalid("A recorded Replace Color fuzziness is outside 0...200.")
        }
        guard samples.count <= Self.maximumSamples else {
            throw RecorderFileError.invalid("A recorded Replace Color has more than 8 samples.")
        }
        for sample in samples { _ = try sample.validated() }
        guard samples.contains(where: { !$0.subtract }) else {
            throw RecorderFileError.invalid("Replace Color needs at least one sample to add.")
        }
        guard hue.isFinite, (-180...180).contains(hue),
              saturation.isFinite, (-100...100).contains(saturation),
              lightness.isFinite, (-100...100).contains(lightness) else {
            throw RecorderFileError.invalid("A recorded Replace Color correction is outside its range.")
        }
        return self
    }

    /// Bridge in: validates and detaches committed facade settings. An
    /// invalid native value refuses instead of producing a partial value.
    init(_ settings: EngineSession.ReplaceColorSettings) throws {
        guard settings.isValid else {
            throw RecorderFileError.invalid("A recorded Replace Color value is outside the native range.")
        }
        self.init(fuzziness: settings.fuzziness,
                  samples: settings.samples.map {
                      Sample(red: $0.red, green: $0.green, blue: $0.blue, subtract: $0.subtract)
                  },
                  hue: settings.hue, saturation: settings.saturation,
                  lightness: settings.lightness)
    }

    /// Bridge out: revalidates every field a caller could have built by hand
    /// before restoring exact facade settings.
    func settings() throws -> EngineSession.ReplaceColorSettings {
        let value = try validated()
        var settings = EngineSession.ReplaceColorSettings()
        settings.fuzziness = value.fuzziness
        settings.samples = value.samples.map {
            EngineSession.ReplaceColorSettings.Sample(red: $0.red, green: $0.green,
                                                      blue: $0.blue, subtract: $0.subtract)
        }
        settings.hue = value.hue
        settings.saturation = value.saturation
        settings.lightness = value.lightness
        return settings
    }
}
