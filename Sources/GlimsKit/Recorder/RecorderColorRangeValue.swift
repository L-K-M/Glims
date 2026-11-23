import Foundation

/// A detached Select > Color Range value. The mode tag, fuzziness, Invert
/// and sampled colors travel as owned strings and finite numbers. Sampled
/// Colors keeps one to 64 samples with at least one add; a fixed range keeps
/// none. Every field is revalidated before the value reaches the file.
struct RecorderColorRangeValue: Equatable {
    /// Glims' version-one string catalog, never native enum ordinals.
    enum Mode: String {
        case sampledColors, reds, yellows, greens, cyans, blues, magentas,
             highlights, midtones, shadows

        var engine: EngineSession.ColorRangeSettings.Mode {
            switch self {
            case .sampledColors: return .sampled
            case .reds: return .reds
            case .yellows: return .yellows
            case .greens: return .greens
            case .cyans: return .cyans
            case .blues: return .blues
            case .magentas: return .magentas
            case .highlights: return .highlights
            case .midtones: return .midtones
            case .shadows: return .shadows
            }
        }

        private init(_ engine: EngineSession.ColorRangeSettings.Mode) {
            switch engine {
            case .sampled: self = .sampledColors
            case .reds: self = .reds
            case .yellows: self = .yellows
            case .greens: self = .greens
            case .cyans: self = .cyans
            case .blues: self = .blues
            case .magentas: self = .magentas
            case .highlights: self = .highlights
            case .midtones: self = .midtones
            case .shadows: self = .shadows
            }
        }

        static func from(_ engine: EngineSession.ColorRangeSettings.Mode) -> Mode {
            Mode(engine)
        }
    }

    struct Sample: Equatable {
        let red: Double
        let green: Double
        let blue: Double
        let subtract: Bool

        /// Components may lie slightly outside 0...1, but must be finite.
        func validated() throws -> Sample {
            guard red.isFinite && green.isFinite && blue.isFinite else {
                throw RecorderFileError.invalid("A recorded color range sample is not a finite color.")
            }
            return self
        }
    }

    /// Mirrors GLIMS_COLOR_RANGE_MAX_SAMPLES in the facade header.
    static let maximumSamples = 64

    let mode: Mode
    let fuzziness: Double
    let invert: Bool
    let samples: [Sample]

    init(mode: Mode, fuzziness: Double, invert: Bool, samples: [Sample]) {
        self.mode = mode
        self.fuzziness = fuzziness
        self.invert = invert
        self.samples = samples
    }

    func validated() throws -> RecorderColorRangeValue {
        guard fuzziness.isFinite, (0...200).contains(fuzziness) else {
            throw RecorderFileError.invalid("A recorded color range fuzziness is outside 0...200.")
        }
        guard samples.count <= Self.maximumSamples else {
            throw RecorderFileError.invalid("A recorded color range has more than 64 samples.")
        }
        for sample in samples { _ = try sample.validated() }

        if mode == .sampledColors {
            guard !samples.isEmpty, samples.contains(where: { !$0.subtract }) else {
                throw RecorderFileError.invalid("Sampled Colors needs at least one sample to add.")
            }
        } else if !samples.isEmpty {
            throw RecorderFileError.invalid("A fixed color range takes no samples.")
        }
        return self
    }

    /// Bridge in: validates and detaches committed facade settings. A fixed
    /// mode's stored samples are dropped, as the live command drops them.
    init(_ settings: EngineSession.ColorRangeSettings) throws {
        let engine = settings.engineSettings
        guard engine.isValid else {
            throw RecorderFileError.invalid("A recorded color range has invalid settings.")
        }
        self.init(mode: .from(engine.mode), fuzziness: engine.fuzziness,
                  invert: engine.invert,
                  samples: engine.samples.map {
                      Sample(red: $0.red, green: $0.green, blue: $0.blue, subtract: $0.subtract)
                  })
    }

    /// Bridge out: revalidates every field before restoring exact facade
    /// settings.
    func settings() throws -> EngineSession.ColorRangeSettings {
        let value = try validated()
        var settings = EngineSession.ColorRangeSettings()
        settings.mode = value.mode.engine
        settings.fuzziness = value.fuzziness
        settings.invert = value.invert
        settings.samples = value.samples.map {
            EngineSession.ColorRangeSettings.Sample(red: $0.red, green: $0.green,
                                                    blue: $0.blue, subtract: $0.subtract)
        }
        return settings
    }
}
