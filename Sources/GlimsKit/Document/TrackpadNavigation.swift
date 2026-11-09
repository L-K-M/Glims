import CoreGraphics

/// Pure rules for the canvas's trackpad pinch (magnify) and rotate view
/// navigation, kept free of `NSEvent` and view state so they are
/// unit-testable without a window, a document or an engine.
///
/// Apple's Event Overview (Handling Touch Events) defines the per-message
/// deltas: `magnification` is relative — the new zoom is the current zoom
/// times `1 + magnification` — and a positive `rotation` is
/// counterclockwise. The flipped canvas's positive `frameRotation` is
/// clockwise, so a rotate delta maps to MINUS the event's rotation.
enum TrackpadNavigationLogic {
    /// The zoom clamp bounds, in percent: the ladder's ends.
    static let minimumZoomPercent = ZoomLadder.steps.first ?? 5
    static let maximumZoomPercent = ZoomLadder.steps.last ?? 3200

    /// The per-message magnify factor `1 + magnification`: nil unless the
    /// delta is finite and the factor is positive and finite — a pinch can
    /// never scale by zero or less.
    static func magnifyFactor(_ magnification: Double) -> Double? {
        guard magnification.isFinite else { return nil }
        let factor = 1 + magnification
        guard factor.isFinite, factor > 0 else { return nil }
        return factor
    }

    /// Clamps a fractional zoom percent into the ladder's range.
    static func clampedZoomPercent(_ percent: Double) -> Double {
        guard percent.isFinite else { return Double(minimumZoomPercent) }
        return min(max(percent, Double(minimumZoomPercent)), Double(maximumZoomPercent))
    }

    /// Clamps an integer zoom percent into the ladder's range.
    static func clampedZoomPercent(_ percent: Int) -> Int {
        min(max(percent, minimumZoomPercent), maximumZoomPercent)
    }

    /// One magnify step: `current * factor`, clamped into the ladder's
    /// range IN DOUBLE, before any Int conversion — a non-finite or
    /// overflowing product lands on the nearest endpoint instead of
    /// trapping when later read as Int.
    static func zoomedPercent(accumulating current: Double, by factor: Double) -> Double {
        guard current.isFinite, factor.isFinite, factor > 0 else { return clampedZoomPercent(current) }
        let product = current * factor
        if product.isNaN { return clampedZoomPercent(current) }
        if product == .infinity { return Double(maximumZoomPercent) }
        if product == -.infinity { return Double(minimumZoomPercent) }
        return clampedZoomPercent(product)
    }

    /// One pinch gesture's fractional zoom percent plus the last integer
    /// percent published to the view. The fractional remainder survives
    /// across messages; comparing `publishedPercent` with the view's
    /// current percent detects an external zoom change (rebase) without
    /// dropping the remainder on the gesture's own publications.
    struct ZoomAccumulator {
        private(set) var fractionalPercent: Double
        private(set) var publishedPercent: Int

        init(publishedPercent: Int) {
            self.publishedPercent = TrackpadNavigationLogic.clampedZoomPercent(publishedPercent)
            fractionalPercent = Double(self.publishedPercent)
        }

        /// Restarts from `currentPercent`: a new gesture (.began) or a zoom
        /// changed outside it (menu, status bar, another window).
        mutating func rebase(to currentPercent: Int) {
            publishedPercent = TrackpadNavigationLogic.clampedZoomPercent(currentPercent)
            fractionalPercent = Double(publishedPercent)
        }

        /// Applies one relative magnify delta and returns the integer
        /// percent to publish — nil when the delta is zero or invalid, or
        /// when the integer did not change (the fraction stays pending).
        mutating func apply(magnification: Double) -> Int? {
            guard magnification.isFinite, magnification != 0,
                  let factor = TrackpadNavigationLogic.magnifyFactor(magnification) else { return nil }
            fractionalPercent = TrackpadNavigationLogic.zoomedPercent(accumulating: fractionalPercent, by: factor)
            let percent = Int(fractionalPercent.rounded())
            guard percent != publishedPercent else { return nil }
            publishedPercent = percent
            return percent
        }

        /// Clears the pending fraction without publishing: the view keeps
        /// the last published integer (cancel), or loses only the
        /// sub-percent tail after an applied end.
        mutating func clear() {
            fractionalPercent = Double(publishedPercent)
        }
    }

    /// One rotate gesture's pending angle in canvas degrees: the absolute
    /// rotation captured as the base plus the accumulated MINUS event
    /// deltas (Apple's positive rotation is counterclockwise; the flipped
    /// canvas's positive frameRotation is clockwise).
    struct RotationAccumulator {
        private(set) var baseDegrees: Double
        private(set) var deltaDegrees: Double

        init(baseDegrees: Double) {
            self.baseDegrees = baseDegrees.isFinite ? baseDegrees : 0
            deltaDegrees = 0
        }

        /// Restarts from `baseDegrees` (a new gesture's .began, or a reset
        /// after an unmatched window).
        mutating func rebase(to baseDegrees: Double) {
            if baseDegrees.isFinite { self.baseDegrees = baseDegrees }
            deltaDegrees = 0
        }

        /// Applies one event rotation (degrees, positive counterclockwise)
        /// and returns the absolute canvas rotation to apply — nil for a
        /// zero or non-finite delta, or on overflow (quiet, unchanged).
        mutating func apply(eventRotationDegrees delta: Double) -> Double? {
            guard delta.isFinite, delta != 0 else { return nil }
            let next = deltaDegrees - delta
            let result = baseDegrees + next
            guard next.isFinite, result.isFinite else { return nil }
            deltaDegrees = next
            return result
        }

        /// Cancel: drops the pending delta with NO new delta applied.
        mutating func cancel() { deltaDegrees = 0 }

        /// End: the applied rotation becomes the new base.
        mutating func finish() {
            if (baseDegrees + deltaDegrees).isFinite { baseDegrees += deltaDegrees }
            deltaDegrees = 0
        }
    }
}
