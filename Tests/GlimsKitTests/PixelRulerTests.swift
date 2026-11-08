import CoreGraphics
import XCTest
@testable import GlimsKit

/// Pure tests for the pixel rulers: the bounded tick planner against
/// independent geometry and number oracles (nice-spacing brute force,
/// CanvasGeometry's zoom/backing point scale, explicit range arithmetic),
/// the device-alignment helper, and the cached per-window Show Rulers
/// menu state including its busy-independent validation contract.
final class PixelRulerTests: XCTestCase {
    private static let accuracy = 1e-9

    /// Independent oracle for the major spacing: brute-force the smallest
    /// whole 1/2/5 * 10^n (n >= 0) whose point size reaches the 50-point
    /// target at `pointsPerPixel`. Written as a plain loop, not the
    /// planner's log10/pow path.
    private func oracleMajorSpacing(pointsPerPixel: Double) -> Double? {
        let raw = max(1.0, PixelRulerPlan.targetMajorSpacingPoints / pointsPerPixel)
        guard raw.isFinite else { return nil }
        var best: Double?
        var base = 1.0
        for _ in 0...320 {
            for multiple in [1.0, 2.0, 5.0] {
                let candidate = multiple * base
                if candidate.isFinite && candidate >= raw && (best == nil || candidate < best!) {
                    best = candidate
                }
            }
            if best != nil && base > raw { break }
            base *= 10
            if !base.isFinite { break }
        }
        return best
    }

    /// Independent check that `spacing` is a whole 1/2/5 * 10^n.
    private func isNiceSpacing(_ spacing: Double) -> Bool {
        guard spacing.isFinite, spacing >= 1 else { return false }
        let exponent = floor(log10(spacing))
        let base = pow(10, exponent)
        let multiple = spacing / base
        return [1.0, 2.0, 5.0].contains { abs(multiple - $0) < 1e-9 }
    }

    // MARK: Major spacing targets roughly 50 view points

    func testMajorSpacingMatchesTheBruteForceOracleAcrossZoomAndBacking() {
        for zoom in [5, 10, 25, 33, 50, 67, 100, 150, 200, 300, 800, 1600, 3200] {
            for backing in [1.0, 2.0] {
                let scale = CanvasGeometry.pointScale(zoomPercent: zoom, backingFactor: backing)
                let plan = PixelRulerPlan.plan(visibleStart: 0, visibleEnd: 10_000,
                                               pointsPerPixel: scale, imageExtent: 10_000)
                XCTAssertNotNil(plan)
                XCTAssertEqual(plan?.majorSpacing, oracleMajorSpacing(pointsPerPixel: scale),
                               "zoom \(zoom) at \(backing)x")
                XCTAssertTrue(isNiceSpacing(plan!.majorSpacing))
                // The target holds whenever one image pixel fits in 50 points;
                // below that the deliberate floor is a whole-pixel spacing.
                if PixelRulerPlan.targetMajorSpacingPoints / scale >= 1 {
                    XCTAssertGreaterThanOrEqual(plan!.majorSpacing * scale,
                                                PixelRulerPlan.targetMajorSpacingPoints - 1e-6)
                } else {
                    XCTAssertEqual(plan!.majorSpacing, 1)
                }
            }
        }
    }

    // MARK: Nonzero, scrolled origins

    func testTicksAcrossANonzeroScrolledOrigin() {
        // Scrolled so the visible range starts at image x = 137.5 at 100%
        // on a 1x screen (scale 1 point per pixel); majors every 50 px.
        let plan = PixelRulerPlan.plan(visibleStart: 137.5, visibleEnd: 437.5,
                                       pointsPerPixel: 1, imageExtent: 1000)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.majorSpacing, 50)
        let positions = plan!.ticks.map(\.imagePosition)
        XCTAssertEqual(positions, positions.sorted(), "ticks are sorted")
        XCTAssertTrue(positions.allSatisfy { $0 >= 137.5 - Self.accuracy && $0 <= 437.5 + Self.accuracy },
                      "every tick is inside the visible range")
        // First tick is the first multiple of the tick spacing >= 137.5.
        let tickSpacing = plan!.minorSpacing ?? plan!.majorSpacing
        XCTAssertEqual(positions.first ?? .nan, (137.5 / tickSpacing).rounded(.up) * tickSpacing,
                       accuracy: Self.accuracy)
        // Majors land exactly on multiples of 50: 150, 200, ...
        let majors = plan!.ticks.filter(\.isMajor).map(\.imagePosition)
        XCTAssertEqual(majors, [150, 200, 250, 300, 350, 400])
    }

    func testLargeScrolledCoordinatesKeepMinorTicksUnlabeled() {
        for (scale, expected) in [
            (16.0, [1_000_000.0, 1_000_005, 1_000_010]),
            (32.0, [1_000_000.0, 1_000_002, 1_000_004, 1_000_006, 1_000_008, 1_000_010])
        ] {
            let plan = PixelRulerPlan.plan(visibleStart: 1_000_000, visibleEnd: 1_000_010,
                                          pointsPerPixel: scale, imageExtent: 2_000_000)!
            XCTAssertEqual(plan.ticks.filter(\.isMajor).map(\.imagePosition), expected)
            XCTAssertEqual(plan.ticks.compactMap(\.label), expected.map { String(Int($0)) })
            XCTAssertTrue(plan.ticks.contains { !$0.isMajor && $0.label == nil })
        }
    }

    func testOriginTickSitsAtImageZeroWhenVisible() {
        let plan = PixelRulerPlan.plan(visibleStart: -20, visibleEnd: 80,
                                       pointsPerPixel: 2, imageExtent: 500)
        // The visible range clamps to the image extent: 0...80.
        XCTAssertEqual(plan?.ticks.first?.imagePosition, 0)
        XCTAssertTrue(plan?.ticks.first?.isMajor ?? false, "the origin tick is a labeled major")
        XCTAssertEqual(plan?.ticks.first?.label, "0")
    }

    func testTicksClampToTheImageExtent() {
        // Viewport wider than the image (surround visible on both sides).
        let plan = PixelRulerPlan.plan(visibleStart: -300, visibleEnd: 900,
                                       pointsPerPixel: 1, imageExtent: 200)
        XCTAssertNotNil(plan)
        XCTAssertTrue(plan!.ticks.allSatisfy { $0.imagePosition >= 0 && $0.imagePosition <= 200 },
                      "no tick leaves the image extent")
        XCTAssertEqual(plan?.ticks.last?.imagePosition, 200)
    }

    // MARK: Zoom and backing keep labels in image pixels

    func testSamePointScaleGivesIdenticalPlansWhateverTheBacking() {
        // 100% at 1x and 200% at 2x are both one point per image pixel.
        let at100x1 = PixelRulerPlan.plan(visibleStart: 10, visibleEnd: 400,
                                          pointsPerPixel: CanvasGeometry.pointScale(zoomPercent: 100, backingFactor: 1),
                                          imageExtent: 1000)
        let at200x2 = PixelRulerPlan.plan(visibleStart: 10, visibleEnd: 400,
                                          pointsPerPixel: CanvasGeometry.pointScale(zoomPercent: 200, backingFactor: 2),
                                          imageExtent: 1000)
        XCTAssertEqual(at100x1, at200x2, "backing changes the point scale, never the image coordinates")
    }

    func testZoomOutDoublesTheSpacingInImagePixels() {
        // 100% at 2x: 0.5 points per pixel, so 50 points span 100 pixels.
        let zoomedOut = PixelRulerPlan.plan(visibleStart: 0, visibleEnd: 1000,
                                            pointsPerPixel: CanvasGeometry.pointScale(zoomPercent: 100, backingFactor: 2),
                                            imageExtent: 1000)
        XCTAssertEqual(zoomedOut?.majorSpacing, 100)
        // 200% at 2x: back to one point per pixel.
        let zoomedIn = PixelRulerPlan.plan(visibleStart: 0, visibleEnd: 1000,
                                           pointsPerPixel: CanvasGeometry.pointScale(zoomPercent: 200, backingFactor: 2),
                                           imageExtent: 1000)
        XCTAssertEqual(zoomedIn?.majorSpacing, 50)
    }

    // MARK: Minor ticks only when legible

    func testMinorTicksAppearOnlyWhenLegible() {
        // scale 10 pt/px: major 5 px (50 pt), minor 1 px (10 pt) — legible.
        let plan = PixelRulerPlan.plan(visibleStart: 0, visibleEnd: 50,
                                       pointsPerPixel: 10, imageExtent: 1000)
        XCTAssertEqual(plan?.majorSpacing, 5)
        XCTAssertEqual(plan?.minorSpacing, 1)
        XCTAssertTrue(plan!.ticks.contains { !$0.isMajor }, "legible minors are planned")
        XCTAssertFalse(plan!.ticks.filter(\.isMajor).isEmpty)

        // The legibility gate itself, at spacings the major target cannot
        // produce: minors must land at least 4 view points apart.
        XCTAssertEqual(PixelRulerPlan.legibleMinorSpacing(majorSpacing: 50, pointsPerPixel: 1), 10)
        XCTAssertEqual(PixelRulerPlan.legibleMinorSpacing(majorSpacing: 5, pointsPerPixel: 4), 1,
                       "exactly at the 4 pt floor is legible")
        XCTAssertNil(PixelRulerPlan.legibleMinorSpacing(majorSpacing: 5, pointsPerPixel: 3),
                     "1 px minors at 3 pt/px are 3 pt apart — not legible")
        XCTAssertNil(PixelRulerPlan.legibleMinorSpacing(majorSpacing: 1, pointsPerPixel: 10),
                     "0.2 px minors at 10 pt/px are 2 pt apart — not legible")
    }

    func testMinorTicksAreSubdivisionsOfTheMajor() {
        let plan = PixelRulerPlan.plan(visibleStart: 0, visibleEnd: 100,
                                       pointsPerPixel: 10, imageExtent: 1000)
        XCTAssertEqual(plan?.majorSpacing, 5)
        XCTAssertEqual(plan?.minorSpacing, 1)
        let tickSpacing = plan!.minorSpacing!
        for tick in plan!.ticks {
            let index = tick.imagePosition / tickSpacing
            XCTAssertEqual(index, index.rounded(), accuracy: 1e-6, "every tick is a multiple of the minor spacing")
            if tick.isMajor {
                let majorIndex = tick.imagePosition / plan!.majorSpacing
                XCTAssertEqual(majorIndex, majorIndex.rounded(), accuracy: 1e-6)
            }
        }
    }

    // MARK: Labels stay whole image pixels

    func testLabelsAreWholePixelStringsOnMajorsOnly() {
        let plan = PixelRulerPlan.plan(visibleStart: 3, visibleEnd: 260,
                                       pointsPerPixel: 2, imageExtent: 1000)
        for tick in plan!.ticks {
            if tick.isMajor {
                XCTAssertNotNil(tick.label)
                XCTAssertEqual(tick.label, String(Int(tick.imagePosition)), "major label \(tick.label!) is whole pixels")
                XCTAssertFalse(tick.label!.contains("."))
            } else {
                XCTAssertNil(tick.label, "minor ticks carry no label")
            }
        }
    }

    // MARK: Finite, sorted, bounded results at extremes and damaged inputs

    func testPlanIsCappedAt512TicksForAHugeDenseRange() {
        // One point per pixel, ten billion visible pixels: spacing 50, but
        // minors at 10 px make a dense plan; the cap must bound it.
        let plan = PixelRulerPlan.plan(visibleStart: 0, visibleEnd: 1e10,
                                       pointsPerPixel: 1, imageExtent: 1e10)
        XCTAssertNotNil(plan)
        XCTAssertLessThanOrEqual(plan!.ticks.count, PixelRulerPlan.maximumTicks)
        XCTAssertEqual(plan!.ticks.count, PixelRulerPlan.maximumTicks, "the cap is exactly 512 here")
        let positions = plan!.ticks.map(\.imagePosition)
        XCTAssertEqual(positions, positions.sorted())
        XCTAssertTrue(positions.allSatisfy(\.isFinite))
    }

    func testExtremeZoomOutPlansOnlySparseTicks() {
        // scale 1e-6 points/px: major spacing 5e7 px, minor 1e7 px, so a
        // 1e9 px image plans 101 ticks — bounded and finite, quickly.
        let plan = PixelRulerPlan.plan(visibleStart: 0, visibleEnd: 1e9,
                                       pointsPerPixel: 1e-6, imageExtent: 1e9)
        XCTAssertNotNil(plan)
        XCTAssertEqual(plan?.majorSpacing, 5e7)
        XCTAssertEqual(plan!.ticks.count, 101)
        XCTAssertTrue(plan!.ticks.allSatisfy { $0.imagePosition.isFinite && $0.imagePosition <= 1e9 + 1e-6 })
        XCTAssertEqual(plan!.ticks.filter(\.isMajor).count, 21)
    }

    func testAstronomicalRangeTerminatesInsteadOfSpinning() {
        // Beyond 2^53 the loop index cannot advance by one; the planner must
        // stop rather than hang.
        let plan = PixelRulerPlan.plan(visibleStart: 1e17, visibleEnd: 1e17 + 1000,
                                       pointsPerPixel: 1e6, imageExtent: 1e18)
        XCTAssertNotNil(plan)
        XCTAssertLessThanOrEqual(plan!.ticks.count, PixelRulerPlan.maximumTicks)
        XCTAssertTrue(plan!.ticks.map(\.imagePosition).allSatisfy(\.isFinite))
    }

    func testInvalidGeometryReturnsNil() {
        let good = (visibleStart: 0.0, visibleEnd: 100.0, pointsPerPixel: 1.0, imageExtent: 200.0)
        XCTAssertNil(PixelRulerPlan.plan(visibleStart: .nan, visibleEnd: good.visibleEnd,
                                         pointsPerPixel: good.pointsPerPixel, imageExtent: good.imageExtent))
        XCTAssertNil(PixelRulerPlan.plan(visibleStart: .infinity, visibleEnd: good.visibleEnd,
                                         pointsPerPixel: good.pointsPerPixel, imageExtent: good.imageExtent))
        XCTAssertNil(PixelRulerPlan.plan(visibleStart: good.visibleStart, visibleEnd: -.infinity,
                                         pointsPerPixel: good.pointsPerPixel, imageExtent: good.imageExtent))
        XCTAssertNil(PixelRulerPlan.plan(visibleStart: good.visibleStart, visibleEnd: good.visibleEnd,
                                         pointsPerPixel: 0, imageExtent: good.imageExtent))
        XCTAssertNil(PixelRulerPlan.plan(visibleStart: good.visibleStart, visibleEnd: good.visibleEnd,
                                         pointsPerPixel: -2, imageExtent: good.imageExtent))
        XCTAssertNil(PixelRulerPlan.plan(visibleStart: good.visibleStart, visibleEnd: good.visibleEnd,
                                         pointsPerPixel: .nan, imageExtent: good.imageExtent))
        XCTAssertNil(PixelRulerPlan.plan(visibleStart: good.visibleStart, visibleEnd: good.visibleEnd,
                                         pointsPerPixel: 1e-320, imageExtent: good.imageExtent),
                     "a denormal scale has no finite 50-point spacing")
        XCTAssertNil(PixelRulerPlan.plan(visibleStart: good.visibleStart, visibleEnd: good.visibleEnd,
                                         pointsPerPixel: good.pointsPerPixel, imageExtent: -1))
        XCTAssertNil(PixelRulerPlan.plan(visibleStart: good.visibleStart, visibleEnd: good.visibleEnd,
                                         pointsPerPixel: good.pointsPerPixel, imageExtent: .infinity))
        XCTAssertNil(PixelRulerPlan.plan(visibleStart: 100, visibleEnd: 0,
                                         pointsPerPixel: good.pointsPerPixel, imageExtent: good.imageExtent),
                     "an inverted range is invalid")
    }

    func testValidButOffImageRangeReturnsAnEmptyPlan() {
        // Deliberate fallback: valid inputs whose visible range misses the
        // image entirely plan zero ticks (the caller draws nothing).
        let plan = PixelRulerPlan.plan(visibleStart: 300, visibleEnd: 400,
                                       pointsPerPixel: 1, imageExtent: 200)
        XCTAssertNotNil(plan)
        XCTAssertTrue(plan!.ticks.isEmpty)
        XCTAssertEqual(plan?.majorSpacing, 50, "the spacing is still reported")
    }

    func testZeroExtentImagePlansNothing() {
        let plan = PixelRulerPlan.plan(visibleStart: -10, visibleEnd: 10,
                                       pointsPerPixel: 1, imageExtent: 0)
        XCTAssertNotNil(plan)
        XCTAssertTrue(plan!.ticks.isEmpty)
    }

    // MARK: Device alignment never changes image coordinates

    func testDeviceAlignmentMovesAStrokeByAtMostHalfADevicePixel() {
        for backing in [1.0, 2.0, 3.0] {
            for point in [0.0, 0.13, 10.37, 123.456, 9999.9] {
                let aligned = PixelRulerGeometry.deviceAligned(point, backingFactor: backing)
                XCTAssertLessThanOrEqual(abs(aligned - point), 0.5 / backing + 1e-9,
                                         "alignment moves less than half a device pixel")
                XCTAssertEqual(PixelRulerGeometry.deviceAligned(aligned, backingFactor: backing), aligned,
                               accuracy: Self.accuracy, "alignment is idempotent")
                // The image coordinate is untouched: the plan at this backing
                // still labels whole image pixels.
            }
        }
        // A damaged backing factor leaves the point alone.
        XCTAssertEqual(PixelRulerGeometry.deviceAligned(7.5, backingFactor: 0), 7.5)
        XCTAssertEqual(PixelRulerGeometry.deviceAligned(7.5, backingFactor: .nan), 7.5)
        XCTAssertEqual(PixelRulerGeometry.deviceAligned(.infinity, backingFactor: 2), .infinity)
    }

    // MARK: Cached per-window Show Rulers state and menu contract

    func testRulerViewStateDefaultsToOnAndToggles() {
        var state = RulerViewState()
        XCTAssertTrue(state.showsRulers, "Show Rulers defaults to checked")
        XCTAssertEqual(state.menuState, .on)
        state.toggle()
        XCTAssertFalse(state.showsRulers)
        XCTAssertEqual(state.menuState, .off)
        state.toggle()
        XCTAssertTrue(state.showsRulers)
        XCTAssertEqual(state.menuState, .on)
    }

    func testMenuValidationIgnoresTheEngineBusyState() {
        // The contract: busy never changes the result, in either state.
        for shows in [true, false] {
            let idle = RulerMenuLogic.validate(showsRulers: shows, isClosing: false, engineIsBusy: false)
            let busy = RulerMenuLogic.validate(showsRulers: shows, isClosing: false, engineIsBusy: true)
            XCTAssertEqual(idle.enabled, true)
            XCTAssertEqual(busy.enabled, idle.enabled, "an engine-busy gate never applies to the display-only toggle")
            XCTAssertEqual(busy.state, idle.state, "an engine-busy gate never changes the checkmark")
            XCTAssertEqual(idle.state, shows ? .on : .off, "the checkmark reads the cached per-window state")
        }
        // Only a closing document disables it.
        let closing = RulerMenuLogic.validate(showsRulers: true, isClosing: true, engineIsBusy: true)
        XCTAssertFalse(closing.enabled)
        XCTAssertEqual(closing.state, .on)
    }
}
