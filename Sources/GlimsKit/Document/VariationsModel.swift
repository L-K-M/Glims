import Foundation

/// Pure accumulated state for Image > Adjust > Variations. No AppKit and no
/// engine calls, so the mapping from a thumbnail click to facade settings is
/// unit-testable on its own.
///
/// Every click adds one step to the chosen tonal range (or to the whole
/// lightness/saturation range) and clamps each value to -1...1. The dialog
/// also asks what a click *would* produce without committing it, so each
/// thumbnail can show its own result.
struct VariationsModel: Equatable {
    /// The tonal range the color ring edits. Lighter and Darker ignore it.
    enum Range: String, CaseIterable, Codable {
        case shadows, midtones, highlights
    }

    /// The correction mode: the six-color ring or the saturation row.
    enum Mode: String, CaseIterable, Codable {
        case color, saturation
    }

    /// One thumbnail's click. `currentPick` only names the center display;
    /// it has no direction and never changes the settings.
    enum Direction: String, CaseIterable {
        case moreGreen, moreYellow, moreRed, moreMagenta, moreBlue, moreCyan
        case lighter, darker
        case lessSaturation, moreSaturation
        case currentPick
    }

    /// The Fine-to-Coarse slider's step sizes, finest first.
    static let steps: [Double] = [0.02, 0.03, 0.05, 0.08, 0.12, 0.18, 0.25]
    static let defaultStepIndex = 3

    var settings = EngineSession.VariationsSettings()
    var range: Range = .midtones
    var mode: Mode = .color
    var stepIndex: Int = VariationsModel.defaultStepIndex

    init() {}

    var step: Double {
        get { Self.steps[min(max(stepIndex, 0), Self.steps.count - 1)] }
        set {
            if let index = Self.steps.firstIndex(where: { abs($0 - newValue) < 1e-9 }) {
                stepIndex = index
            }
        }
    }

    var isIdentity: Bool { settings.isIdentity }

    /// The settings that would result from clicking `direction` once,
    /// without changing this model.
    func settings(afterClick direction: Direction) -> EngineSession.VariationsSettings {
        var candidate = self
        candidate.apply(direction)
        return candidate.settings
    }

    mutating func apply(_ direction: Direction) {
        switch direction {
        case .moreGreen:
            addToRange(\.magentaGreen, +step)
        case .moreYellow:
            addToRange(\.yellowBlue, -step)
        case .moreRed:
            addToRange(\.cyanRed, +step)
        case .moreMagenta:
            addToRange(\.magentaGreen, -step)
        case .moreBlue:
            addToRange(\.yellowBlue, +step)
        case .moreCyan:
            addToRange(\.cyanRed, -step)
        case .lighter:
            settings.lightness = clamp(settings.lightness + step)
        case .darker:
            settings.lightness = clamp(settings.lightness - step)
        case .lessSaturation:
            settings.saturation = clamp(settings.saturation - step)
        case .moreSaturation:
            settings.saturation = clamp(settings.saturation + step)
        case .currentPick:
            break
        }
    }

    /// Original restores the identity settings; the range, mode and step
    /// controls stay as the user left them.
    mutating func reset() {
        settings = EngineSession.VariationsSettings()
    }

    private mutating func addToRange(_ keyPath: WritableKeyPath<EngineSession.ColorBalanceSettings.Range, Double>,
                                     _ amount: Double) {
        switch range {
        case .shadows:
            settings.shadows[keyPath: keyPath] = clamp(settings.shadows[keyPath: keyPath] + amount)
        case .midtones:
            settings.midtones[keyPath: keyPath] = clamp(settings.midtones[keyPath: keyPath] + amount)
        case .highlights:
            settings.highlights[keyPath: keyPath] = clamp(settings.highlights[keyPath: keyPath] + amount)
        }
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(-1, value))
    }
}
