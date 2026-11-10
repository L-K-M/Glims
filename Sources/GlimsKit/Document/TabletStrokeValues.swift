/// Optional axes captured as owned scalars. An absent or invalid reading
/// stays absent, including when the other axis has a valid reading.
struct TabletStrokeAxes: Equatable, Sendable {
    let rotationTurns: Double?
    let tangentialPressure: Double?

    init(rotationDegrees: Double?, tangentialPressure: Double?) {
        rotationTurns = rotationDegrees.flatMap(Self.turns)
        self.tangentialPressure = tangentialPressure.flatMap { value in
            value.isFinite && (-1...1).contains(value) ? value : nil
        }
    }

    private static func turns(_ degrees: Double) -> Double? {
        guard degrees.isFinite else { return nil }
        // Reduce before division so large angles retain their fractional turn.
        let fraction = degrees.truncatingRemainder(dividingBy: 360) / 360
        let wrapped = fraction < 0 ? 1 + fraction : fraction
        // Near zero, a negative fraction can round back to one. Both that
        // endpoint and a signed zero have the canonical representation zero.
        return wrapped >= 1 || wrapped == 0 ? 0 : wrapped
    }
}

/// The floored millisecond reading on a wrapping 32-bit stroke clock.
struct TabletStrokeTime: Equatable, Sendable {
    let milliseconds: UInt32

    init?(seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let scaled = seconds * 1_000
        guard scaled.isFinite else { return nil }
        let wrapped = scaled.rounded(.down).truncatingRemainder(dividingBy: 4_294_967_296)
        guard let milliseconds = UInt32(exactly: wrapped) else { return nil }
        self.milliseconds = milliseconds
    }

    /// Equal readings and forward differences below half the clock range
    /// are ordered, including a forward wrap. Half the range is ambiguous.
    func canFollow(_ previous: Self) -> Bool {
        (milliseconds &- previous.milliseconds) < 0x8000_0000
    }
}
