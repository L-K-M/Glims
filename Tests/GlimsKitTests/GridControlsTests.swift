import CoreGraphics
import XCTest
@testable import GlimsKit

/// Pure tests for the grid controls: strict whole-field Double parsing,
/// the draft validation (finite, positive spacings; native bounds left to
/// the engine), the cached Show Grid toggle policy, the five style names,
/// and the bounded overlay planner against independent geometry oracles —
/// line positions from closed-form modular arithmetic, visible-rect
/// clipping, legibility thresholds, caps, overflow guards and dash-phase
/// anchoring to image coordinates.
final class GridControlsTests: XCTestCase {
    private static let accuracy = 1e-9

    private func grid(style: EngineSession.GridStyle = .solid, spacingX: Double = 10, spacingY: Double = 10,
                      offsetX: Double = 0, offsetY: Double = 0) -> EngineSession.Grid {
        EngineSession.Grid(style: style, spacingX: spacingX, spacingY: spacingY,
                           offsetX: offsetX, offsetY: offsetY,
                           foreground: .black, background: .white)
    }

    // MARK: Strict whole-field Double parsing

    func testParseDoubleAcceptsWholeFieldFiniteLiterals() {
        XCTAssertEqual(GridSheetLogic.parseDouble("0") ?? -1, 0)
        XCTAssertEqual(GridSheetLogic.parseDouble("10") ?? -1, 10)
        XCTAssertEqual(GridSheetLogic.parseDouble("10.5") ?? -1, 10.5, accuracy: Self.accuracy)
        XCTAssertEqual(GridSheetLogic.parseDouble("-3.25") ?? -1, -3.25, accuracy: Self.accuracy)
        XCTAssertEqual(GridSheetLogic.parseDouble(".5") ?? -1, 0.5, accuracy: Self.accuracy)
        XCTAssertEqual(GridSheetLogic.parseDouble("1e3") ?? -1, 1000, accuracy: Self.accuracy)
        XCTAssertEqual(GridSheetLogic.parseDouble("1E-2") ?? -1, 0.01, accuracy: Self.accuracy)
        XCTAssertEqual(GridSheetLogic.parseDouble("+7") ?? -1, 7)
    }

    func testParseDoubleRejectsPartialWhitespaceAndNonFiniteInput() {
        for text in ["", " ", " 12", "12 ", "abc", "12abc", "1,5", "10px", "1 2", "\t3",
                     "nan", "NaN", "inf", "-inf", "infinity", "1e400", "-1e400",
                     "99999999999999999999999999e400"] {
            XCTAssertNil(GridSheetLogic.parseDouble(text), "\"\(text)\" must not parse")
        }
    }

    // MARK: Draft validation

    private func validate(style: EngineSession.GridStyle = .solid, sx: String = "10", sy: String = "10",
                          ox: String = "0", oy: String = "0") -> Result<EngineSession.Grid, GridSheetLogic.Rejection> {
        GridSheetLogic.validateDraft(style: style, spacingXText: sx, spacingYText: sy,
                                     offsetXText: ox, offsetYText: oy,
                                     foreground: .red, background: .blue)
    }

    func testValidateDraftAcceptsAFinitePositiveDraftAndPassesColorsThrough() {
        guard case .success(let draft) = validate(style: .doubleDash, sx: "12.5", sy: "8",
                                                  ox: "-4", oy: "1e2") else {
            return XCTFail("a valid draft must validate")
        }
        XCTAssertEqual(draft, grid(style: .doubleDash, spacingX: 12.5, spacingY: 8, offsetX: -4, offsetY: 100)
            .withColors(foreground: .red, background: .blue))
    }

    func testValidateDraftRefusesUnparsableZeroAndNegativeSpacings() {
        for sx in ["abc", "", "nan", "1e400", "10px"] {
            guard case .failure(let rejection) = validate(sx: sx) else {
                return XCTFail("spacing X \"\(sx)\" must be refused")
            }
            XCTAssertTrue(rejection.message.contains("Spacing X"), rejection.message)
        }
        for sx in ["0", "-5", "0.0", "-0"] {
            guard case .failure(let rejection) = validate(sx: sx) else {
                return XCTFail("spacing X \"\(sx)\" must be refused as not positive")
            }
            XCTAssertTrue(rejection.message.contains("greater than zero"), rejection.message)
        }
        guard case .failure(let rejection) = validate(sy: "0") else {
            return XCTFail("spacing Y 0 must be refused")
        }
        XCTAssertTrue(rejection.message.contains("Spacing Y"), rejection.message)
    }

    func testValidateDraftChecksFinitenessOfOffsetsButNotNativeBounds() {
        // Offsets only need to be finite; their sign is allowed.
        guard case .success = validate(ox: "-999999", oy: "123456789") else {
            return XCTFail("finite offsets must validate")
        }
        for ox in ["abc", "inf", "nan", ""] {
            guard case .failure = validate(ox: ox) else {
                return XCTFail("offset X \"\(ox)\" must be refused as not a finite number")
            }
        }
        // The native range bounds are NOT checked here on purpose: a
        // spacing beyond the engine's maximum must reach the engine and
        // be refused there visibly, never clamped client-side.
        guard case .success(let huge) = validate(sx: "1000000000") else {
            return XCTFail("an over-maximum spacing is the engine's refusal, not the sheet's")
        }
        XCTAssertEqual(huge.spacingX, 1_000_000_000)
    }

    // MARK: Cached Show Grid toggle policy and style names

    func testShowGridDefaultsToOffAndTogglesAsPureViewState() {
        var state = GridViewState()
        XCTAssertFalse(state.showsGrid, "Show Grid defaults to unchecked")
        XCTAssertEqual(state.menuState, .off)
        state.toggle()
        XCTAssertTrue(state.showsGrid)
        XCTAssertEqual(state.menuState, .on)
        state.toggle()
        XCTAssertFalse(state.showsGrid)
        XCTAssertEqual(state.menuState, .off)
    }

    func testAllFiveNativeStylesHaveDistinctDisplayNames() {
        let titles = EngineSession.GridStyle.allCases.map(\.title)
        XCTAssertEqual(titles, ["Dots", "Intersections", "On-off Dash", "Double Dash", "Solid"])
        XCTAssertEqual(Set(titles).count, 5)
    }

    // MARK: Planner — line positions from modular arithmetic

    func testSolidGridLinesSitAtOffsetPlusKSpacingAcrossTheVisibleImage() {
        let size = CGSize(width: 40, height: 24)
        let plan = GridOverlayPlanner.plan(grid: grid(), imageSize: size,
                                           visibleImageRect: CGRect(x: 0, y: 0, width: 40, height: 24),
                                           deviceScale: 1, viewScale: 1)
        XCTAssertFalse(plan.isSuppressed)
        XCTAssertFalse(plan.isInvalid)
        XCTAssertEqual(plan.style, .solid)
        XCTAssertTrue(plan.xAxisLegible && plan.yAxisLegible)
        XCTAssertEqual(plan.verticalLines.map(\.coordinate), [0, 10, 20, 30, 40])
        XCTAssertEqual(plan.horizontalLines.map(\.coordinate), [0, 10, 20])
        // Each line spans the visible extent on the other axis.
        for line in plan.verticalLines {
            XCTAssertTrue(line.isVertical)
            XCTAssertEqual(line.from, 0)
            XCTAssertEqual(line.to, 24)
        }
        for line in plan.horizontalLines {
            XCTAssertFalse(line.isVertical)
            XCTAssertEqual(line.from, 0)
            XCTAssertEqual(line.to, 40)
        }
    }

    func testOffsetsShiftTheLinesModularlyAndAreNeverClamped() {
        let size = CGSize(width: 40, height: 24)
        let rect = CGRect(x: 0, y: 0, width: 40, height: 24)
        // Offset 3/5: lines at 3+10k and 5+10k inside the image.
        let shifted = GridOverlayPlanner.plan(grid: grid(offsetX: 3, offsetY: 5), imageSize: size,
                                               visibleImageRect: rect, deviceScale: 1, viewScale: 1)
        XCTAssertEqual(shifted.verticalLines.map(\.coordinate), [3, 13, 23, 33])
        XCTAssertEqual(shifted.horizontalLines.map(\.coordinate), [5, 15])
        // Offset 45 is beyond the width: it must NOT be clamped to 40
        // (which would give 0,10,...,40) — modular arithmetic gives
        // 5,15,25,35.
        let beyond = GridOverlayPlanner.plan(grid: grid(offsetX: 45), imageSize: size,
                                              visibleImageRect: rect, deviceScale: 1, viewScale: 1)
        XCTAssertEqual(beyond.verticalLines.map(\.coordinate), [5, 15, 25, 35])
        XCTAssertFalse(beyond.xAxisOverCap)
        // Negative offset -3: lines at 7,17,27,37.
        let negative = GridOverlayPlanner.plan(grid: grid(offsetX: -3), imageSize: size,
                                                visibleImageRect: rect, deviceScale: 1, viewScale: 1)
        XCTAssertEqual(negative.verticalLines.map(\.coordinate), [7, 17, 27, 37])
    }

    func testTheVisibleRectClipsThePlanBeforeAnyLoop() {
        let size = CGSize(width: 40, height: 24)
        // Visible window (12,2)-(32,12) in image coordinates.
        let plan = GridOverlayPlanner.plan(grid: grid(), imageSize: size,
                                           visibleImageRect: CGRect(x: 12, y: 2, width: 20, height: 10),
                                           deviceScale: 1, viewScale: 1)
        XCTAssertEqual(plan.verticalLines.map(\.coordinate), [20, 30])
        XCTAssertEqual(plan.horizontalLines.map(\.coordinate), [10])
        // The line extents are the visible range, not the whole image:
        // no long offscreen path is planned.
        XCTAssertEqual(plan.verticalLines.first?.from, 2)
        XCTAssertEqual(plan.verticalLines.first?.to, 12)
        XCTAssertEqual(plan.horizontalLines.first?.from, 12)
        XCTAssertEqual(plan.horizontalLines.first?.to, 32)
    }

    // MARK: Planner — legibility threshold, per-axis and style semantics

    func testAnAxisBelowTwoDevicePixelsIsSuppressedLikeTheEngine() {
        let size = CGSize(width: 40, height: 24)
        let rect = CGRect(x: 0, y: 0, width: 40, height: 24)
        // 10 * 0.1 = 1 device px < 2: both axes illegible, nothing drawn.
        let tiny = GridOverlayPlanner.plan(grid: grid(), imageSize: size, visibleImageRect: rect,
                                           deviceScale: 0.1, viewScale: 0.1)
        XCTAssertTrue(tiny.isSuppressed)
        XCTAssertFalse(tiny.xAxisLegible)
        XCTAssertTrue(tiny.verticalLines.isEmpty && tiny.horizontalLines.isEmpty)
        // Exactly 2 device px is still legible (the engine uses >= 2.0).
        let edge = GridOverlayPlanner.plan(grid: grid(), imageSize: size, visibleImageRect: rect,
                                           deviceScale: 0.2, viewScale: 0.2)
        XCTAssertTrue(edge.xAxisLegible && edge.yAxisLegible)
        XCTAssertFalse(edge.isSuppressed)
        XCTAssertEqual(edge.verticalLines.count, 5)
    }

    func testOneIllegibleAxisDropsOnlyItsOwnLinesForLineStyles() {
        let size = CGSize(width: 40, height: 24)
        let rect = CGRect(x: 0, y: 0, width: 40, height: 24)
        // Spacing Y 1 at device scale 1: 1 < 2 device px, horizontal gone.
        let plan = GridOverlayPlanner.plan(grid: grid(spacingY: 1), imageSize: size,
                                           visibleImageRect: rect, deviceScale: 1, viewScale: 1)
        XCTAssertTrue(plan.xAxisLegible)
        XCTAssertFalse(plan.yAxisLegible)
        XCTAssertFalse(plan.isSuppressed, "the legible axis still draws")
        XCTAssertEqual(plan.verticalLines.map(\.coordinate), [0, 10, 20, 30, 40])
        XCTAssertTrue(plan.horizontalLines.isEmpty)
    }

    func testDotsAndIntersectionsNeedBothAxesAndDrawOnlyIntersections() throws {
        let size = CGSize(width: 40, height: 24)
        let rect = CGRect(x: 0, y: 0, width: 40, height: 24)
        for style: EngineSession.GridStyle in [.dots, .intersections] {
            let plan = GridOverlayPlanner.plan(grid: grid(style: style), imageSize: size,
                                               visibleImageRect: rect, deviceScale: 1, viewScale: 1)
            XCTAssertEqual(plan.style, style)
            XCTAssertTrue(plan.verticalLines.isEmpty && plan.horizontalLines.isEmpty)
            // Independent oracle: the Cartesian product of the line sets.
            let xs = [0.0, 10, 20, 30, 40]
            let ys = [0.0, 10, 20]
            XCTAssertEqual(plan.points.count, xs.count * ys.count)
            XCTAssertEqual(Set(plan.points.map { "\($0.x),\($0.y)" }),
                           Set(xs.flatMap { x in ys.map { "\(x),\($0)" } }))
            // One axis illegible: no dots at all (the engine's vert && horz).
            let partial = GridOverlayPlanner.plan(grid: grid(style: style, spacingY: 1), imageSize: size,
                                                  visibleImageRect: rect, deviceScale: 1, viewScale: 1)
            XCTAssertTrue(partial.isSuppressed)
            XCTAssertTrue(partial.points.isEmpty)
        }
    }

    // MARK: Planner — fixed caps, overflow and invalid-input guards

    func testAVeryDenseVisibleGridIsSuppressedByTheFixedCapNotWalked() {
        // 524288-wide image, spacing 2 at device scale 1: 262145 visible
        // lines, far over the 4096 per-axis cap — dropped, not looped.
        let size = CGSize(width: 524288, height: 8)
        let rect = CGRect(x: 0, y: 0, width: 524288, height: 8)
        let plan = GridOverlayPlanner.plan(grid: grid(spacingX: 2, spacingY: 10), imageSize: size,
                                           visibleImageRect: rect, deviceScale: 1, viewScale: 1)
        XCTAssertTrue(plan.xAxisLegible)
        XCTAssertTrue(plan.xAxisOverCap)
        XCTAssertTrue(plan.verticalLines.isEmpty)
        XCTAssertFalse(plan.yAxisOverCap)
        XCTAssertEqual(plan.horizontalLines.map(\.coordinate), [0])
        XCTAssertFalse(plan.isSuppressed, "the legible axis still draws")
    }

    func testTheDotCartesianProductHasACheckedCap() {
        // 600x600 image, spacing 2 at device scale 2 (legible): 301 lines
        // per axis are under the per-axis cap, but 301*301 = 90601
        // intersections exceed the 65536 point cap.
        let size = CGSize(width: 600, height: 600)
        let rect = CGRect(x: 0, y: 0, width: 600, height: 600)
        let plan = GridOverlayPlanner.plan(grid: grid(style: .dots, spacingX: 2, spacingY: 2),
                                           imageSize: size, visibleImageRect: rect,
                                           deviceScale: 2, viewScale: 1)
        XCTAssertTrue(plan.pointsOverCap)
        XCTAssertTrue(plan.isSuppressed)
        XCTAssertTrue(plan.points.isEmpty)
        // Just under the cap still plans every point.
        let small = GridOverlayPlanner.plan(grid: grid(style: .dots, spacingX: 2, spacingY: 2),
                                            imageSize: CGSize(width: 300, height: 300),
                                            visibleImageRect: CGRect(x: 0, y: 0, width: 300, height: 300),
                                            deviceScale: 2, viewScale: 1)
        XCTAssertEqual(small.points.count, 151 * 151)
    }

    func testInvalidCachedMetadataIsSuppressedNeverClamped() {
        let size = CGSize(width: 40, height: 24)
        let rect = CGRect(x: 0, y: 0, width: 40, height: 24)
        for bad in [grid(spacingX: 0), grid(spacingX: -1), grid(spacingX: .nan), grid(spacingX: .infinity),
                    grid(spacingY: 0), grid(offsetX: .nan), grid(offsetY: .infinity)] {
            let plan = GridOverlayPlanner.plan(grid: bad, imageSize: size, visibleImageRect: rect,
                                               deviceScale: 1, viewScale: 1)
            XCTAssertTrue(plan.isInvalid, "spacing/offset \(bad.spacingX)/\(bad.spacingY) off \(bad.offsetX)/\(bad.offsetY)")
            XCTAssertTrue(plan.isSuppressed)
            XCTAssertTrue(plan.verticalLines.isEmpty && plan.horizontalLines.isEmpty && plan.points.isEmpty)
        }
        // Degenerate image or scale: suppressed, no crash.
        for (s, ds, vs) in [(CGSize(width: 0, height: 24), 1.0, 1.0), (size, 0, 1), (size, 1, .infinity)] {
            let plan = GridOverlayPlanner.plan(grid: grid(), imageSize: s, visibleImageRect: rect,
                                               deviceScale: ds, viewScale: vs)
            XCTAssertTrue(plan.isInvalid || plan.isSuppressed)
        }
    }

    // MARK: Planner — dash phase anchored to image coordinates across scroll

    func testDashPhaseKeepsThePatternAlignedToImageCoordinatesAcrossScroll() throws {
        let size = CGSize(width: 40, height: 24)
        // Device scale 2, view scale 1 (a 2x screen): dash period in view
        // points is 2 * 4 * 1 / 2 = 4.
        let period = 2 * GridOverlayPlanner.dashLengthDevicePixels * 1 / 2
        // Plan A: the whole image visible. Vertical lines run from y = 0.
        let whole = GridOverlayPlanner.plan(grid: grid(style: .onOffDash), imageSize: size,
                                            visibleImageRect: CGRect(x: 0, y: 0, width: 40, height: 24),
                                            deviceScale: 2, viewScale: 1)
        let wholeLine = try XCTUnwrap(whole.verticalLines.first { $0.coordinate == 10 })
        XCTAssertEqual(wholeLine.from, 0)
        XCTAssertEqual(wholeLine.dashPhase, 0, accuracy: Self.accuracy)
        // Plan B: scrolled down — the visible rect starts at y = 6, so the
        // same physical vertical line is planned from y = 6.
        let scrolled = GridOverlayPlanner.plan(grid: grid(style: .onOffDash), imageSize: size,
                                               visibleImageRect: CGRect(x: 0, y: 6, width: 40, height: 18),
                                               deviceScale: 2, viewScale: 1)
        XCTAssertEqual(scrolled.verticalLines.map(\.coordinate), [0, 10, 20, 30, 40])
        let line = try XCTUnwrap(scrolled.verticalLines.first { $0.coordinate == 10 })
        XCTAssertEqual(line.from, 6)
        XCTAssertEqual(line.to, 24)
        XCTAssertEqual(line.dashPhase, (6 * 1).truncatingRemainder(dividingBy: period), accuracy: Self.accuracy)
        // Anchoring invariant, checked against the closed-form oracle:
        // a dash pattern position at image coordinate t along the line is
        // fmod((t - from) * viewScale + phase, period), and must equal
        // fmod(t * viewScale, period) — the pattern is glued to the image,
        // not to the scroll position.
        for t in [6.0, 7.5, 10, 12, 20, 23.5] {
            let along = (t - line.from) * 1 + line.dashPhase
            XCTAssertEqual(along.truncatingRemainder(dividingBy: period),
                           (t * 1).truncatingRemainder(dividingBy: period), accuracy: Self.accuracy,
                           "image y \(t) must land on the same dash phase after scrolling")
        }
        // The same physical line has the same absolute pattern in both
        // plans at the image points they share.
        for t in [10.0, 15, 20, 24] {
            let a = ((t - wholeLine.from) * 1 + wholeLine.dashPhase).truncatingRemainder(dividingBy: period)
            let b = ((t - line.from) * 1 + line.dashPhase).truncatingRemainder(dividingBy: period)
            XCTAssertEqual(a, b, accuracy: Self.accuracy)
        }
        // Horizontal scroll anchors horizontal lines the same way.
        let sideways = GridOverlayPlanner.plan(grid: grid(style: .doubleDash), imageSize: size,
                                               visibleImageRect: CGRect(x: 6, y: 0, width: 34, height: 24),
                                               deviceScale: 2, viewScale: 1)
        let hLine = try XCTUnwrap(sideways.horizontalLines.first { $0.coordinate == 10 })
        XCTAssertEqual(hLine.from, 6)
        XCTAssertEqual(hLine.dashPhase, (6 * 1).truncatingRemainder(dividingBy: period), accuracy: Self.accuracy)
        for t in [6.0, 11, 30, 40] {
            let along = (t - hLine.from) * 1 + hLine.dashPhase
            XCTAssertEqual(along.truncatingRemainder(dividingBy: period),
                           (t * 1).truncatingRemainder(dividingBy: period), accuracy: Self.accuracy)
        }
    }
}

private extension EngineSession.Grid {
    func withColors(foreground: NSColor, background: NSColor) -> EngineSession.Grid {
        EngineSession.Grid(style: style, spacingX: spacingX, spacingY: spacingY,
                           offsetX: offsetX, offsetY: offsetY,
                           foreground: foreground, background: background)
    }
}
