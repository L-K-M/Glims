import Foundation
import CGlimsEngine

/// Whole settings of the recordable blur and sharpen filters. They are read
/// and written through the generic property facade with a closed schema per
/// operation, so a recording never depends on properties it does not name.
/// The property names, ranges and enum nicks match GEGL's
/// `gaussian-blur.c` and `unsharp-mask.c` in all four pinned engine sets.
extension EngineSession {
    static let gaussianBlurOperation = "gegl:gaussian-blur"
    static let unsharpMaskOperation = "gegl:unsharp-mask"

    /// GEGL's `std-dev` limit for both operations.
    static let blurDeviationRange: ClosedRange<Double> = 0...1500

    struct GaussianBlurSettings: Equatable {
        /// How the kernel is discretized (`filter`).
        enum Kernel: String, CaseIterable { case auto, fir, iir }
        /// How image edges are handled (`abyss-policy`).
        enum Abyss: String, CaseIterable { case none, clamp, black, white }

        var deviationX: Double = 1.5
        var deviationY: Double = 1.5
        var kernel: Kernel = .auto
        var abyss: Abyss = .clamp
        var clipsToInput = true

        var isValid: Bool {
            [deviationX, deviationY].allSatisfy { $0.isFinite && EngineSession.blurDeviationRange.contains($0) }
        }
    }

    struct UnsharpMaskSettings: Equatable {
        static let amountRange: ClosedRange<Double> = 0...300
        static let thresholdRange: ClosedRange<Double> = 0...1

        /// GEGL's `std-dev`, shown as Radius.
        var radius: Double = 3
        /// GEGL's `scale`, shown as Amount.
        var amount: Double = 0.5
        var threshold: Double = 0

        var isValid: Bool {
            radius.isFinite && EngineSession.blurDeviationRange.contains(radius)
                && amount.isFinite && Self.amountRange.contains(amount)
                && threshold.isFinite && Self.thresholdRange.contains(threshold)
        }
    }

    func gaussianBlurSettings(_ filter: Int32) throws -> GaussianBlurSettings {
        let value = GaussianBlurSettings(
            deviationX: try number(filter, "std-dev-x"), deviationY: try number(filter, "std-dev-y"),
            kernel: try choice(filter, "filter"), abyss: try choice(filter, "abyss-policy"),
            clipsToInput: try flag(filter, "clip-extent"))
        guard value.isValid else { throw unreadableSettings() }
        return value
    }

    func setGaussianBlurSettings(_ filter: Int32, to value: GaussianBlurSettings) throws {
        guard value.isValid else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "Gaussian Blur sizes must be between 0 and 1500 pixels.")
        }
        try setFilterProperty(filter, "std-dev-x", to: .number(value.deviationX))
        try setFilterProperty(filter, "std-dev-y", to: .number(value.deviationY))
        try setFilterProperty(filter, "filter", to: .enumeration(value.kernel.rawValue))
        try setFilterProperty(filter, "abyss-policy", to: .enumeration(value.abyss.rawValue))
        try setFilterProperty(filter, "clip-extent", to: .boolean(value.clipsToInput))
    }

    func unsharpMaskSettings(_ filter: Int32) throws -> UnsharpMaskSettings {
        let value = UnsharpMaskSettings(radius: try number(filter, "std-dev"), amount: try number(filter, "scale"),
                                        threshold: try number(filter, "threshold"))
        guard value.isValid else { throw unreadableSettings() }
        return value
    }

    func setUnsharpMaskSettings(_ filter: Int32, to value: UnsharpMaskSettings) throws {
        guard value.isValid else {
            throw EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                              message: "Unsharp Mask needs a radius of 0–1500, an amount of 0–300 and a threshold of 0–1.")
        }
        try setFilterProperty(filter, "std-dev", to: .number(value.radius))
        try setFilterProperty(filter, "scale", to: .number(value.amount))
        try setFilterProperty(filter, "threshold", to: .number(value.threshold))
    }

    private func number(_ filter: Int32, _ property: String) throws -> Double {
        guard case .number(let value) = try filterProperty(filter, property) else { throw unreadableSettings() }
        return value
    }

    private func flag(_ filter: Int32, _ property: String) throws -> Bool {
        guard case .boolean(let value) = try filterProperty(filter, property) else { throw unreadableSettings() }
        return value
    }

    private func choice<Choice: RawRepresentable>(_ filter: Int32, _ property: String) throws -> Choice where Choice.RawValue == String {
        guard case .enumeration(let nick) = try filterProperty(filter, property), let value = Choice(rawValue: nick) else {
            throw unreadableSettings()
        }
        return value
    }

    private func unreadableSettings() -> EngineError {
        EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "The filter settings could not be read.")
    }
}
