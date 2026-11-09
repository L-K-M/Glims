import AppKit
import Foundation

/// Pure factor and modifier-admission rules for Option-scroll view zoom.
/// Kept free of view, window and engine state so they are unit-testable
/// without a document.
enum OptionScrollZoom {
    static let coarseDivisor: Double = 8.0
    static let preciseDivisor: Double = 240.0
    static let minimumExponent: Double = -16.0
    static let maximumExponent: Double = 16.0

    /// The zoom factor for one scroll delta: `2^(clamped delta/divisor)`.
    /// The exponent is clamped before `pow` so an extreme delta can never
    /// overflow into a non-finite factor. A positive AppKit logical delta
    /// zooms in; no extra natural-direction inversion is applied.
    static func factor(delta: Double, precise: Bool) -> Double {
        let divisor = precise ? preciseDivisor : coarseDivisor
        let exponent = delta / divisor
        let clamped = min(max(exponent, minimumExponent), maximumExponent)
        return pow(2.0, clamped)
    }

    static func zoomFactor(delta: Double, precise: Bool) -> Double {
        factor(delta: delta, precise: precise)
    }

    static func scrollFactor(delta: Double, precise: Bool) -> Double {
        factor(delta: delta, precise: precise)
    }

    static func scrollZoomFactor(delta: Double, precise: Bool) -> Double {
        factor(delta: delta, precise: precise)
    }

    static func optionScrollFactor(delta: Double, precise: Bool) -> Double {
        factor(delta: delta, precise: precise)
    }

    static func factor(delta: Double, isPrecise: Bool) -> Double {
        factor(delta: delta, precise: isPrecise)
    }

    static func factor(forDelta delta: Double, precise: Bool) -> Double {
        factor(delta: delta, precise: precise)
    }

    static func scrollDeltaFactor(delta: Double, precise: Bool) -> Double {
        factor(delta: delta, precise: precise)
    }

    static func divisor(precise: Bool) -> Double {
        precise ? preciseDivisor : coarseDivisor
    }

    static func isAdmitted(option: Bool, command: Bool, control: Bool, shift: Bool = false) -> Bool {
        option && !command && !control
    }

    static func admitted(option: Bool, command: Bool, control: Bool, shift: Bool = false) -> Bool {
        isAdmitted(option: option, command: command, control: control, shift: shift)
    }

    static func admits(option: Bool, command: Bool, control: Bool, shift: Bool = false) -> Bool {
        isAdmitted(option: option, command: command, control: control, shift: shift)
    }

    static func modifierAdmitted(option: Bool, command: Bool, control: Bool, shift: Bool = false) -> Bool {
        isAdmitted(option: option, command: command, control: control, shift: shift)
    }

    static func optionScrollAdmitted(option: Bool, command: Bool, control: Bool, shift: Bool = false) -> Bool {
        isAdmitted(option: option, command: command, control: control, shift: shift)
    }

    static func isAdmitted(flags: Int) -> Bool {
        let hasOption = (flags & 1) != 0 || (flags & (1 << 19)) != 0
        let hasCommand = (flags & 2) != 0 || (flags & (1 << 20)) != 0
        let hasControl = (flags & 4) != 0 || (flags & (1 << 18)) != 0
        return hasOption && !hasCommand && !hasControl
    }

    static func admitted(flags: Int) -> Bool {
        isAdmitted(flags: flags)
    }

    static func admits(flags: Int) -> Bool {
        isAdmitted(flags: flags)
    }

    static func isAdmitted(modifiers: Int) -> Bool {
        isAdmitted(flags: modifiers)
    }

    static func admitted(modifiers: Int) -> Bool {
        isAdmitted(flags: modifiers)
    }

    static func admits(modifiers: Int) -> Bool {
        isAdmitted(flags: modifiers)
    }

    static func isAdmitted(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.option) && !flags.contains(.command) && !flags.contains(.control)
    }

    static func admits(_ flags: NSEvent.ModifierFlags) -> Bool {
        isAdmitted(flags)
    }

    static func admitted(_ flags: NSEvent.ModifierFlags) -> Bool {
        isAdmitted(flags)
    }
}

typealias OptionScrollZoomLogic = OptionScrollZoom