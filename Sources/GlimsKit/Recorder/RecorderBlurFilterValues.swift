import Foundation

/// A detached Gaussian Blur settings value with owned field and choice
/// names, so the file never stores native enum ordinals.
struct RecorderGaussianBlurValue: Equatable {
    enum Kernel: String, CaseIterable { case auto, fir, iir }
    enum Abyss: String, CaseIterable { case none, clamp, black, white }

    let deviationX: Double
    let deviationY: Double
    let kernel: Kernel
    let abyss: Abyss
    let clipsToInput: Bool

    /// Caller-built values are not trusted: `settings()` and the file codec
    /// revalidate both sizes before use.
    init(deviationX: Double, deviationY: Double, kernel: Kernel, abyss: Abyss, clipsToInput: Bool) {
        self.deviationX = deviationX
        self.deviationY = deviationY
        self.kernel = kernel
        self.abyss = abyss
        self.clipsToInput = clipsToInput
    }

    func validated() throws -> RecorderGaussianBlurValue {
        guard [deviationX, deviationY].allSatisfy({ $0.isFinite && EngineSession.blurDeviationRange.contains($0) }) else {
            throw RecorderFileError.invalid("A recorded Gaussian Blur size is not a finite 0...1500 value.")
        }
        return self
    }

    init(_ settings: EngineSession.GaussianBlurSettings) throws {
        guard settings.isValid,
              let kernel = Kernel(rawValue: settings.kernel.rawValue),
              let abyss = Abyss(rawValue: settings.abyss.rawValue) else {
            throw RecorderFileError.invalid("A recorded Gaussian Blur value is outside the native range.")
        }
        self.init(deviationX: settings.deviationX, deviationY: settings.deviationY, kernel: kernel,
                  abyss: abyss, clipsToInput: settings.clipsToInput)
    }

    func settings() throws -> EngineSession.GaussianBlurSettings {
        let value = try validated()
        guard let kernel = EngineSession.GaussianBlurSettings.Kernel(rawValue: value.kernel.rawValue),
              let abyss = EngineSession.GaussianBlurSettings.Abyss(rawValue: value.abyss.rawValue) else {
            throw RecorderFileError.invalid("A recorded Gaussian Blur choice is unknown.")
        }
        return .init(deviationX: value.deviationX, deviationY: value.deviationY, kernel: kernel,
                     abyss: abyss, clipsToInput: value.clipsToInput)
    }
}

/// A detached Unsharp Mask settings value.
struct RecorderUnsharpMaskValue: Equatable {
    let radius: Double
    let amount: Double
    let threshold: Double

    init(radius: Double, amount: Double, threshold: Double) {
        self.radius = radius
        self.amount = amount
        self.threshold = threshold
    }

    func validated() throws -> RecorderUnsharpMaskValue {
        guard EngineSession.UnsharpMaskSettings(radius: radius, amount: amount, threshold: threshold).isValid else {
            throw RecorderFileError.invalid("A recorded Unsharp Mask needs a radius of 0...1500, an amount of 0...300 and a threshold of 0...1.")
        }
        return self
    }

    init(_ settings: EngineSession.UnsharpMaskSettings) throws {
        guard settings.isValid else {
            throw RecorderFileError.invalid("A recorded Unsharp Mask value is outside the native range.")
        }
        self.init(radius: settings.radius, amount: settings.amount, threshold: settings.threshold)
    }

    func settings() throws -> EngineSession.UnsharpMaskSettings {
        let value = try validated()
        return .init(radius: value.radius, amount: value.amount, threshold: value.threshold)
    }
}
