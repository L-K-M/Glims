import AppKit

/// Value-only Option-scroll rules; no window, view or engine access.
enum OptionScrollZoom {
    /// Positive AppKit logical deltas zoom in, without a second natural-scroll inversion.
    static func factor(delta: Double, precise: Bool) -> Double? {
        guard delta.isFinite else { return nil }
        let exponent = min(max(delta / (precise ? 240 : 8), -16), 16)
        return pow(2, exponent)
    }

    static func isAdmitted(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.option) && !flags.contains(.command) && !flags.contains(.control)
    }

    /// Phase boundaries still apply when a terminal event has no usable delta.
    /// A nil delta also lets callers discard an invalid pointer location.
    static func apply(delta: Double?, precise: Bool, currentPercent: Int,
                      began: Bool, ended: Bool, cancelled: Bool,
                      to accumulator: inout TrackpadNavigationLogic.ZoomAccumulator) -> Int? {
        if began || accumulator.publishedPercent != currentPercent {
            accumulator.rebase(to: currentPercent)
        }
        if cancelled {
            accumulator.clear()
            return nil
        }
        defer { if ended { accumulator.clear() } }
        guard let delta, delta != 0, let factor = factor(delta: delta, precise: precise) else { return nil }
        return accumulator.apply(magnification: factor - 1)
    }
}
