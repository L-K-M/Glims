import CoreGraphics

/// Pure, bounded tick planning for the pixel rulers around the canvas.
///
/// Everything here is display math over image pixels: no AppKit view state,
/// no engine call, nothing that can mutate image pixels, the file, the
/// dirty flag, history, selection, export or print. The ruler views feed
/// it the visible image-pixel range and the current point scale; it answers
/// with ticks whose `imagePosition` is in image pixels, aligned with the
/// image origin (tick 0 sits at image coordinate 0).
///
/// Deliberate fallback behavior for damaged geometry: `plan` returns nil
/// when an input is non-finite, the point scale is not positive, the image
/// extent is negative, the visible range is inverted, or no finite nice
/// spacing exists; it returns an empty tick list when the inputs are valid
/// but the visible range misses the image entirely (after clamping to the
/// image extent). Either way the caller just draws nothing.
enum PixelRulerPlan {
    /// View points the planner aims to leave between major ticks.
    static let targetMajorSpacingPoints: Double = 50
    /// Minor ticks are planned only when they land at least this many view
    /// points apart — sparser minors would not be legible.
    static let minimumMinorSpacingPoints: Double = 4
    /// Hard cap on planned ticks per axis, whatever the inputs. Extreme
    /// zoom or damaged sizes can ask for billions of ticks; the ruler shows
    /// the first `maximumTicks` of them.
    static let maximumTicks = 512
    /// Minor ticks per major interval (major spacing / 5).
    static let minorSubdivisions = 5

    struct Tick: Equatable {
        /// The tick's position in image pixels (fractional for minors).
        let imagePosition: Double
        let isMajor: Bool
        /// The numeric label, in image pixels: whole pixels on majors only.
        var label: String? {
            guard isMajor else { return nil }
            let rounded = imagePosition.rounded()
            guard rounded.isFinite, let value = Int64(exactly: rounded) else { return nil }
            return String(value)
        }
    }

    struct Plan: Equatable {
        let ticks: [Tick]
        /// Image pixels between major ticks (always a whole 1/2/5 * 10^n).
        let majorSpacing: Double
        /// Image pixels between minor ticks, or nil when minors would not
        /// be legible at the current scale.
        let minorSpacing: Double?
    }

    /// Plans the ticks for one ruler axis.
    ///
    /// - Parameters:
    ///   - visibleStart, visibleEnd: the visible range in image pixels.
    ///     May be fractional, nonzero or scrolled; it is clamped to
    ///     `0...imageExtent` because the ruler only labels the image.
    ///   - pointsPerPixel: view points per image pixel at the current zoom
    ///     and backing factor (CanvasGeometry.pointScale).
    ///   - imageExtent: the image's size along this axis, in pixels.
    /// - Returns: nil for invalid geometry (see the enum comment), otherwise
    ///   a plan whose ticks are sorted, finite, inside the image extent and
    ///   capped at `maximumTicks`.
    static func plan(visibleStart: Double, visibleEnd: Double,
                     pointsPerPixel: Double, imageExtent: Double) -> Plan? {
        guard visibleStart.isFinite, visibleEnd.isFinite,
              pointsPerPixel.isFinite, imageExtent.isFinite,
              pointsPerPixel > 0, imageExtent >= 0,
              visibleStart <= visibleEnd else { return nil }
        guard let major = majorSpacing(pointsPerPixel: pointsPerPixel) else { return nil }
        let minor = legibleMinorSpacing(majorSpacing: major, pointsPerPixel: pointsPerPixel)
        let empty = Plan(ticks: [], majorSpacing: major, minorSpacing: minor)

        // Intersect the visible range with the image: [0, extent]. A range
        // entirely off the image (or a zero-extent image) plans no ticks.
        guard imageExtent > 0 else { return empty }
        let clampedStart = max(visibleStart, 0)
        let clampedEnd = min(visibleEnd, imageExtent)
        guard clampedStart <= clampedEnd else { return empty }

        let tickSpacing = minor ?? major
        let first = (clampedStart / tickSpacing).rounded(.up)
        let last = (clampedEnd / tickSpacing).rounded(.down)
        guard first.isFinite, last.isFinite else { return empty }

        var ticks: [Tick] = []
        ticks.reserveCapacity(maximumTicks)
        var index = first
        while index <= last && ticks.count < maximumTicks {
            let position = index * tickSpacing
            guard position.isFinite else { break }
            // Tick indices are integral, with one major per subdivision
            // group. A position-relative epsilon would grow large enough
            // to classify ordinary minors as majors on large images.
            let isMajor = minor == nil
                || index.truncatingRemainder(dividingBy: Double(minorSubdivisions)) == 0
            ticks.append(Tick(imagePosition: position, isMajor: isMajor))
            let next = index + 1
            // Beyond 2^53 a Double no longer advances by one; stop instead
            // of spinning forever on damaged, astronomically large ranges.
            guard next > index else { break }
            index = next
        }
        return Plan(ticks: ticks, majorSpacing: major, minorSpacing: minor)
    }

    /// The smallest whole 1/2/5 * 10^n (n >= 0, so at least one image
    /// pixel — labels are whole pixels) whose on-screen size reaches the
    /// target of about `targetMajorSpacingPoints` view points. Nil when no
    /// finite candidate exists (a non-finite or absurd point scale).
    static func majorSpacing(pointsPerPixel: Double) -> Double? {
        guard pointsPerPixel.isFinite, pointsPerPixel > 0 else { return nil }
        let raw = max(1, targetMajorSpacingPoints / pointsPerPixel)
        guard raw.isFinite else { return nil }
        let exponent = Int(floor(log10(raw)))
        guard exponent >= 0, exponent <= 308 else { return nil }
        let base = pow(10, Double(exponent))
        for multiple in [1.0, 2.0, 5.0, 10.0] {
            let candidate = multiple * base
            if candidate.isFinite && candidate >= raw { return candidate }
        }
        return nil
    }

    /// The minor spacing (major / subdivisions) when it is legible at the
    /// current scale — at least `minimumMinorSpacingPoints` view points
    /// apart — nil otherwise. Internal so tests can exercise the gate
    /// directly at spacings the major-spacing target cannot produce.
    static func legibleMinorSpacing(majorSpacing: Double, pointsPerPixel: Double) -> Double? {
        let minor = majorSpacing / Double(minorSubdivisions)
        guard minor.isFinite, minor > 0, minor * pointsPerPixel >= minimumMinorSpacingPoints else { return nil }
        return minor
    }
}

/// Pure drawing geometry shared by the ruler views: device-pixel alignment
/// for hairline strokes.
enum PixelRulerGeometry {
    /// Snaps a view-point coordinate onto the half-device-pixel grid, so a
    /// one-device-pixel stroke lands on whole device pixels at any backing
    /// factor. The move is at most half a device pixel; the image coordinate
    /// the point came from is unchanged — alignment never relabels a tick.
    static func deviceAligned(_ point: Double, backingFactor: Double) -> Double {
        guard backingFactor.isFinite, backingFactor > 0 else { return point }
        let device = point * backingFactor
        guard device.isFinite else { return point }
        return (device * 2).rounded() / 2 / backingFactor
    }
}
