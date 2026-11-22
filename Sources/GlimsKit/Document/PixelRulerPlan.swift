import Foundation

/// Pure, bounded tick planning for the pixel rulers around the canvas.
///
/// Everything here is display math over image pixels: no AppKit view state,
/// no engine call, nothing that can mutate image pixels, the file, the
/// dirty flag, history, selection, export or print. The ruler views feed
/// it the visible image-pixel range and the current point scale; it answers
/// with ticks whose `imagePosition` is in image pixels, aligned with the
/// image origin (tick 0 sits at image coordinate 0). A `RulerUnit` changes
/// only where the nice steps fall and what the labels read.
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
    /// Minor ticks per major interval (major spacing / 5), except for short
    /// inch steps, which divide into quarters.
    static let minorSubdivisions = 5
    /// The finest step in a unit other than pixels, so labels stay short.
    static let finestStepExponent = -6

    struct Tick: Equatable {
        /// The tick's position in image pixels (fractional for minors).
        let imagePosition: Double
        let isMajor: Bool
        /// The numeric label in the ruler's unit, on majors only.
        let label: String?
    }

    struct Plan: Equatable {
        let ticks: [Tick]
        /// The unit the labels read in. A print length on an image without
        /// a usable resolution falls back to pixels.
        let unit: RulerUnit
        /// Image pixels between major ticks: in pixels a whole 1/2/5 * 10^n,
        /// in another unit that unit's nice step converted to image pixels.
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
    ///   - unit: what the labels read in; percent is of `imageExtent`.
    ///   - resolution: pixels per inch along this axis, for print lengths.
    /// - Returns: nil for invalid geometry (see the enum comment), otherwise
    ///   a plan whose ticks are sorted, finite, inside the image extent and
    ///   capped at `maximumTicks`.
    static func plan(visibleStart: Double, visibleEnd: Double,
                     pointsPerPixel: Double, imageExtent: Double,
                     unit requested: RulerUnit = .pixels, resolution: Double? = nil) -> Plan? {
        guard visibleStart.isFinite, visibleEnd.isFinite,
              pointsPerPixel.isFinite, imageExtent.isFinite,
              pointsPerPixel > 0, imageExtent >= 0,
              visibleStart <= visibleEnd else { return nil }
        let measured = pixelsPerUnit(requested, resolution: resolution, imageExtent: imageExtent)
        let unit = measured == nil ? .pixels : requested
        let perUnit = measured ?? 1
        guard let step = majorStep(unit, pointsPerUnit: pointsPerPixel * perUnit) else { return nil }
        let major = step * perUnit
        guard major.isFinite, major > 0 else { return nil }
        let subdivisions = subdivisions(unit, step: step)
        let minor = legibleMinorSpacing(majorSpacing: major, pointsPerPixel: pointsPerPixel,
                                        subdivisions: subdivisions)
        let decimals = labelDecimals(step: step)
        let empty = Plan(ticks: [], unit: unit, majorSpacing: major, minorSpacing: minor)

        // Intersect the visible range with the image: [0, extent]. A range
        // entirely off the image (or a zero-extent image) plans no ticks.
        guard imageExtent > 0 else { return empty }
        let clampedStart = max(visibleStart, 0)
        let clampedEnd = min(visibleEnd, imageExtent)
        guard clampedStart <= clampedEnd else { return empty }

        let tickSpacing = minor ?? major
        // A converted spacing is rarely exact: without the slack the tick
        // at 100% or at a whole inch on the edge would drop out.
        // Adding zero turns the slack's -0 into 0, which would label "-0".
        let first = (clampedStart / tickSpacing - 1e-9).rounded(.up) + 0
        let last = (clampedEnd / tickSpacing + 1e-9).rounded(.down)
        guard first.isFinite, last.isFinite else { return empty }

        var ticks: [Tick] = []
        ticks.reserveCapacity(maximumTicks)
        var index = first
        while index <= last && ticks.count < maximumTicks {
            let raw = index * tickSpacing
            guard raw.isFinite else { break }
            let position = min(max(raw, 0), imageExtent)
            // Tick indices are integral, with one major per subdivision
            // group. A position-relative epsilon would grow large enough
            // to classify ordinary minors as majors on large images.
            let isMajor = minor == nil
                || index.truncatingRemainder(dividingBy: Double(subdivisions)) == 0
            let majors = minor == nil ? index : index / Double(subdivisions)
            let text = isMajor ? label(majors * step, decimals: decimals) : nil
            ticks.append(Tick(imagePosition: position, isMajor: isMajor, label: text))
            let next = index + 1
            // Beyond 2^53 a Double no longer advances by one; stop instead
            // of spinning forever on damaged, astronomically large ranges.
            guard next > index else { break }
            index = next
        }
        return Plan(ticks: ticks, unit: unit, majorSpacing: major, minorSpacing: minor)
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

    /// Image pixels in one `unit`, or nil when the image cannot be measured
    /// in it.
    static func pixelsPerUnit(_ unit: RulerUnit, resolution: Double?, imageExtent: Double) -> Double? {
        if unit == .pixels { return 1 }
        if unit == .percent { return imageExtent.isFinite && imageExtent > 0 ? imageExtent / 100 : nil }
        guard let length = unit.length, let resolution,
              ImageSizeModel.isValidResolution(resolution) else { return nil }
        return resolution / length.perInch
    }

    /// The smallest nice step in `unit` that spans the target on screen.
    /// Pixels keep their whole steps. Inches step in eighths, quarters and
    /// halves below one inch and in decimals finer than that. The other
    /// units step in 1/2/5 * 10^n.
    static func majorStep(_ unit: RulerUnit, pointsPerUnit: Double) -> Double? {
        if unit == .pixels { return majorSpacing(pointsPerPixel: pointsPerUnit) }
        guard pointsPerUnit.isFinite, pointsPerUnit > 0 else { return nil }
        let finest = pow(10, Double(finestStepExponent))
        // The slack keeps a converted 0.5000000001 from jumping to 1.
        let raw = max(finest, targetMajorSpacingPoints / pointsPerUnit * (1 - 1e-9))
        guard raw.isFinite else { return nil }
        if unit == .inches, raw > 0.05, raw <= 0.5 {
            return [0.125, 0.25, 0.5].first { $0 >= raw }
        }
        let exponent = Int(floor(log10(raw)))
        guard exponent <= 308 else { return nil }
        let base = pow(10, Double(exponent))
        return [1.0, 2.0, 5.0, 10.0].map { $0 * base }.first { $0.isFinite && $0 >= raw }
    }

    /// How many minor intervals one major step of `unit` divides into.
    static func subdivisions(_ unit: RulerUnit, step: Double) -> Int {
        unit == .inches && step >= 0.125 && step <= 2 ? 4 : minorSubdivisions
    }

    /// The decimals a label needs to show every multiple of `step` exactly.
    static func labelDecimals(step: Double) -> Int {
        var decimals = 0
        var scaled = step
        while decimals < -finestStepExponent, abs(scaled - scaled.rounded()) > 1e-6 * scaled {
            decimals += 1
            scaled = step * pow(10, Double(decimals))
        }
        return decimals
    }

    /// `value` without float noise or trailing zeros.
    static func label(_ value: Double, decimals: Int) -> String? {
        guard value.isFinite else { return nil }
        if decimals == 0 { return Int64(exactly: value.rounded()).map { String($0) } }
        var text = String(format: "%.*f", decimals, value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }

    /// The minor spacing (major / subdivisions) when it is legible at the
    /// current scale — at least `minimumMinorSpacingPoints` view points
    /// apart — nil otherwise. Internal so tests can exercise the gate
    /// directly at spacings the major-spacing target cannot produce.
    static func legibleMinorSpacing(majorSpacing: Double, pointsPerPixel: Double,
                                    subdivisions: Int = minorSubdivisions) -> Double? {
        let minor = majorSpacing / Double(subdivisions)
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
