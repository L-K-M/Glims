import AppKit
import CoreGraphics

/// Display names for the five native grid styles, in the facade enum's
/// own order (raw values 1...5). The popup in the Configure Grid sheet
/// lists them in this order.
extension EngineSession.GridStyle {
    var title: String {
        switch self {
        case .dots: return "Dots"
        case .intersections: return "Intersections"
        case .onOffDash: return "On-off Dash"
        case .doubleDash: return "Double Dash"
        case .solid: return "Solid"
        }
    }
}

/// View ▸ Show Grid's cached per-window state. Pure view state, default
/// OFF: toggling changes only what the canvas draws — never image pixels,
/// the file's dirty state, history, selection, export or print.
struct GridViewState {
    var showsGrid = false
    var menuState: NSControl.StateValue { showsGrid ? .on : .off }
    mutating func toggle() { showsGrid.toggle() }
}

/// Pure logic behind Image ▸ Configure Grid…: strict whole-field Double
/// parsing and the draft's local validation. No AppKit state and no
/// engine call, so the rules are unit-testable without an engine.
///
/// Only finiteness and positivity are checked here; the native range
/// bounds (spacings up to the engine's maximum, offsets inside its
/// signed range) are deliberately NOT checked — the adapter refuses
/// them and that refusal is shown in the sheet, never clamped away.
enum GridSheetLogic {
    /// A draft the sheet refuses to send: the message shown in the sheet.
    struct Rejection: Error, Equatable {
        let message: String
    }

    /// Strictly parses a decimal Double: the whole field must be one
    /// finite literal — no whitespace, no trailing characters, no NaN or
    /// infinity, no overflow to infinity. Anything else is not a number.
    static func parseDouble(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    /// Validates the sheet's draft fields into a grid the document may
    /// queue as one atomic setGrid. Spacings must be finite and strictly
    /// positive; offsets must be finite (any sign). Colors pass through
    /// as picked. A failure returns the message the sheet shows; the
    /// draft is kept so the user can correct it.
    static func validateDraft(style: EngineSession.GridStyle,
                              spacingXText: String, spacingYText: String,
                              offsetXText: String, offsetYText: String,
                              foreground: NSColor, background: NSColor) -> Result<EngineSession.Grid, Rejection> {
        guard let spacingX = parseDouble(spacingXText) else {
            return .failure(Rejection(message: "Spacing X must be a finite number — the whole field, no other characters."))
        }
        guard let spacingY = parseDouble(spacingYText) else {
            return .failure(Rejection(message: "Spacing Y must be a finite number — the whole field, no other characters."))
        }
        guard let offsetX = parseDouble(offsetXText) else {
            return .failure(Rejection(message: "Offset X must be a finite number — the whole field, no other characters."))
        }
        guard let offsetY = parseDouble(offsetYText) else {
            return .failure(Rejection(message: "Offset Y must be a finite number — the whole field, no other characters."))
        }
        guard spacingX > 0 else {
            return .failure(Rejection(message: "Spacing X must be greater than zero."))
        }
        guard spacingY > 0 else {
            return .failure(Rejection(message: "Spacing Y must be greater than zero."))
        }
        return .success(EngineSession.Grid(style: style, spacingX: spacingX, spacingY: spacingY,
                                           offsetX: offsetX, offsetY: offsetY,
                                           foreground: foreground, background: background))
    }
}

/// The bounded, pure planner for the canvas's grid overlay. It turns the
/// cached grid, the image size and the visible image rect (already
/// clipped to the image bounds — clipping happens FIRST, so no loop ever
/// walks the whole image) into a fixed-cap set of primitives in image
/// coordinates. The canvas only scales them to view points and strokes
/// them; no native call and no bitmap is involved.
///
/// Semantics mirror the engine's own grid drawing
/// (app/display/gimpcanvasgrid.c + gimpcanvas-style.c in the pinned
/// trees): lines sit at image coordinates `offset + k * spacing` on each
/// axis; an axis's lines disappear when the scaled spacing drops below
/// 2 device pixels; Dots and Intersections need BOTH axes legible and
/// draw only at intersections (Dots a 1-device-px mark, Intersections a
/// crosshair); the three line styles draw full-length lines per legible
/// axis. Foreground colors everything; the background color is used only
/// by Double Dash, as the interleaved second dash. Invalid or dense
/// configs are SUPPRESSED, never clamped: a non-finite or non-positive
/// spacing, an overflowing line count, a Cartesian product over the cap
/// or an axis past the per-axis cap each drop the affected primitives and
/// are reported through the plan's flags.
enum GridOverlayPlanner {
    /// An axis's lines disappear below this scaled spacing, in device
    /// pixels — the engine's own legibility threshold (bug #599267).
    static let minimumLegibleSpacingDevicePixels = 2.0
    /// Fixed primitive caps: a denser visible grid is suppressed as
    /// illegible instead of allocating an enormous array.
    static let maximumLinesPerAxis = 4096
    static let maximumGridPoints = 65536
    /// Dash length of the two dashed styles, in device pixels; the
    /// period is twice that. The phase is anchored to image coordinates
    /// so the pattern does not drift when scrolling.
    static let dashLengthDevicePixels = 4.0
    /// The engine's crosshair arm reach, in device pixels (CROSSHAIR).
    static let crosshairDevicePixels = 2.0

    /// One visible line segment in image coordinates. `coordinate` is the
    /// fixed axis position; `from`...`to` the visible extent on the other
    /// axis (already clipped to the image). `dashPhase` anchors the dash
    /// pattern of the dashed styles to image coordinates.
    struct Line {
        let isVertical: Bool
        let coordinate: Double
        let from: Double
        let to: Double
        let dashPhase: Double
    }

    /// One grid intersection in image coordinates (Dots, Intersections).
    struct Point {
        let x: Double
        let y: Double
    }

    struct Plan {
        let style: EngineSession.GridStyle
        var verticalLines: [Line] = []
        var horizontalLines: [Line] = []
        var points: [Point] = []
        /// True when the config itself is invalid (non-finite or
        /// non-positive spacing/offset, degenerate image or scale):
        /// nothing may be drawn and the metadata is not clamped.
        var isInvalid = false
        /// True when both axes are illegible (scaled spacing below the
        /// threshold) or the config is invalid: nothing at all is drawn.
        var isSuppressed = false
        /// True when an axis (or the dot product) was dropped only
        /// because its visible line count exceeds the fixed cap.
        var xAxisOverCap = false
        var yAxisOverCap = false
        var pointsOverCap = false
        /// Per-axis legibility at the current device scale.
        var xAxisLegible = false
        var yAxisLegible = false
    }

    /// Plans the overlay. `visibleImageRect` is the visible canvas area
    /// in image coordinates, already intersected with the image bounds;
    /// `deviceScale` is device pixels per image pixel (the render scale,
    /// used for the legibility threshold) and `viewScale` is view points
    /// per image pixel (used for the dash phase).
    static func plan(grid: EngineSession.Grid, imageSize: CGSize,
                     visibleImageRect: CGRect, deviceScale: Double, viewScale: Double) -> Plan {
        var plan = Plan(style: grid.style)
        guard imageSize.width > 0, imageSize.height > 0, imageSize.width.isFinite, imageSize.height.isFinite,
              deviceScale > 0, deviceScale.isFinite, viewScale > 0, viewScale.isFinite,
              grid.spacingX > 0, grid.spacingX.isFinite, grid.spacingY > 0, grid.spacingY.isFinite,
              grid.offsetX.isFinite, grid.offsetY.isFinite,
              visibleImageRect.minX <= visibleImageRect.maxX, visibleImageRect.minY <= visibleImageRect.maxY,
              visibleImageRect.minX.isFinite, visibleImageRect.maxX.isFinite,
              visibleImageRect.minY.isFinite, visibleImageRect.maxY.isFinite else {
            plan.isInvalid = true
            plan.isSuppressed = true
            return plan
        }
        // The visible rect is clipped to the image by the caller; clip
        // again defensively so a bad rect can never widen the loops.
        let image = CGRect(origin: .zero, size: imageSize)
        let visible = visibleImageRect.intersection(image)
        guard !visible.isEmpty else {
            plan.isSuppressed = true
            return plan
        }

        plan.xAxisLegible = grid.spacingX * deviceScale >= minimumLegibleSpacingDevicePixels
        plan.yAxisLegible = grid.spacingY * deviceScale >= minimumLegibleSpacingDevicePixels

        // Dash period in view points, with finite/overflow guards.
        let dashPeriod = 2 * dashLengthDevicePixels * viewScale / deviceScale
        func phase(_ lineStart: Double) -> Double {
            let p = lineStart * viewScale
            guard p.isFinite, dashPeriod.isFinite, dashPeriod > 0 else { return 0 }
            return p.truncatingRemainder(dividingBy: dashPeriod)
        }

        switch grid.style {
        case .dots, .intersections:
            // The engine draws these only when both axes are legible.
            guard plan.xAxisLegible, plan.yAxisLegible else {
                plan.isSuppressed = true
                return plan
            }
            guard let xs = lineCoordinates(spacing: grid.spacingX, offset: grid.offsetX,
                                          lower: visible.minX, upper: visible.maxX,
                                          cap: maximumLinesPerAxis, overCap: &plan.xAxisOverCap),
                  let ys = lineCoordinates(spacing: grid.spacingY, offset: grid.offsetY,
                                          lower: visible.minY, upper: visible.maxY,
                                          cap: maximumLinesPerAxis, overCap: &plan.yAxisOverCap) else {
                plan.isSuppressed = true
                return plan
            }
            // Checked Cartesian product cap before allocating it.
            let product = Double(xs.count) * Double(ys.count)
            guard product.isFinite, product <= Double(maximumGridPoints) else {
                plan.pointsOverCap = true
                plan.isSuppressed = true
                return plan
            }
            plan.points = xs.flatMap { x in ys.map { Point(x: x, y: $0) } }
        case .onOffDash, .doubleDash, .solid:
            if plan.xAxisLegible,
               let xs = lineCoordinates(spacing: grid.spacingX, offset: grid.offsetX,
                                        lower: visible.minX, upper: visible.maxX,
                                        cap: maximumLinesPerAxis, overCap: &plan.xAxisOverCap) {
                plan.verticalLines = xs.map { Line(isVertical: true, coordinate: $0,
                                                   from: visible.minY, to: visible.maxY,
                                                   dashPhase: phase(visible.minY)) }
            }
            if plan.yAxisLegible,
               let ys = lineCoordinates(spacing: grid.spacingY, offset: grid.offsetY,
                                        lower: visible.minY, upper: visible.maxY,
                                        cap: maximumLinesPerAxis, overCap: &plan.yAxisOverCap) {
                plan.horizontalLines = ys.map { Line(isVertical: false, coordinate: $0,
                                                     from: visible.minX, to: visible.maxX,
                                                     dashPhase: phase(visible.minX)) }
            }
            if plan.verticalLines.isEmpty && plan.horizontalLines.isEmpty {
                plan.isSuppressed = true
            }
        }
        return plan
    }

    /// The grid line coordinates `offset + k * spacing` inside
    /// `lower...upper`, without ever looping over more than the cap:
    /// the first and last index come from closed-form ceil/floor, so a
    /// huge or tiny spacing is detected by the count guard (overflow to
    /// infinity included) instead of being walked. Nil means the axis is
    /// dropped — out of range, non-finite, or over `cap` (`overCap` set).
    /// Coordinates that fall outside the range through rounding are
    /// filtered out (clipping), never clamped onto it.
    private static func lineCoordinates(spacing: Double, offset: Double,
                                        lower: Double, upper: Double,
                                        cap: Int, overCap: inout Bool) -> [Double]? {
        guard spacing > 0, spacing.isFinite, offset.isFinite, lower.isFinite, upper.isFinite,
              lower <= upper else { return nil }
        let first = (lower - offset) / spacing
        let last = (upper - offset) / spacing
        guard first.isFinite, last.isFinite else { return nil }
        let k0 = first.rounded(.up)
        let k1 = last.rounded(.down)
        guard k0.isFinite, k1.isFinite else { return nil }
        let count = k1 - k0 + 1
        guard count >= 0 else { return [] }
        guard count.isFinite, count <= Double(cap) else {
            overCap = true
            return nil
        }
        var coordinates: [Double] = []
        coordinates.reserveCapacity(Int(count))
        var k = k0
        while k <= k1 {
            let x = offset + k * spacing
            if x.isFinite, x >= lower, x <= upper { coordinates.append(x) }
            k += 1
        }
        return coordinates
    }
}
