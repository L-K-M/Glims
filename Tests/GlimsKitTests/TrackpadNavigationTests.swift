import XCTest
@testable import GlimsKit

/// Pure tests for the trackpad pinch/rotate view-navigation rules: bounds,
/// invalid and non-finite deltas, overflow, delta accumulation, rebase,
/// cancel/end lifecycle and the rotation sign. No window, document,
/// engine or NSEvent is involved.
final class TrackpadNavigationTests: XCTestCase {
    // MARK: Magnify factor

    func testMagnifyFactorRequiresAPositiveFiniteFactor() {
        XCTAssertEqual(TrackpadNavigationLogic.magnifyFactor(0.5), 1.5)
        XCTAssertEqual(TrackpadNavigationLogic.magnifyFactor(-0.5), 0.5)
        XCTAssertNil(TrackpadNavigationLogic.magnifyFactor(-1))        // factor 0
        XCTAssertNil(TrackpadNavigationLogic.magnifyFactor(-2))        // negative factor
        XCTAssertNil(TrackpadNavigationLogic.magnifyFactor(.nan))
        XCTAssertNil(TrackpadNavigationLogic.magnifyFactor(.infinity))
        XCTAssertNil(TrackpadNavigationLogic.magnifyFactor(-.infinity))
    }

    // MARK: Zoom bounds and overflow (clamped in Double, before Int)

    func testZoomedPercentClampsIntoTheLaddersRange() {
        XCTAssertEqual(TrackpadNavigationLogic.zoomedPercent(accumulating: 100, by: 2), 200)
        XCTAssertEqual(TrackpadNavigationLogic.zoomedPercent(accumulating: 3200, by: 2), 3200)
        XCTAssertEqual(TrackpadNavigationLogic.zoomedPercent(accumulating: 5, by: 0.5), 5)
        XCTAssertEqual(TrackpadNavigationLogic.zoomedPercent(accumulating: 100, by: 0), 100)
    }

    func testZoomedPercentHandlesOverflowToTheEndpointSafely() {
        XCTAssertEqual(TrackpadNavigationLogic.zoomedPercent(accumulating: 100, by: 1e308), 3200)
        XCTAssertEqual(TrackpadNavigationLogic.zoomedPercent(accumulating: 100, by: 1e-308), 5)
        XCTAssertEqual(TrackpadNavigationLogic.zoomedPercent(accumulating: .nan, by: 2), 5)
        XCTAssertEqual(TrackpadNavigationLogic.zoomedPercent(accumulating: 100, by: .nan), 100)
    }

    func testClampedZoomPercentBoundsBothTypes() {
        XCTAssertEqual(TrackpadNavigationLogic.clampedZoomPercent(1), 5)
        XCTAssertEqual(TrackpadNavigationLogic.clampedZoomPercent(100_000), 3200)
        XCTAssertEqual(TrackpadNavigationLogic.clampedZoomPercent(250.9), 250.9)
        XCTAssertEqual(TrackpadNavigationLogic.clampedZoomPercent(-10), 5)
        XCTAssertEqual(TrackpadNavigationLogic.clampedZoomPercent(Double(100_000)), 3200)
    }

    // MARK: Zoom accumulator: fractional accumulation and publishing

    func testZoomAccumulatorRetainsTheFractionalRemainderAcrossMessages() {
        var accumulator = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 100)
        XCTAssertNil(accumulator.apply(magnification: 0.004))            // 100.4, still 100
        XCTAssertEqual(accumulator.apply(magnification: 0.004), 101)     // 100.8016 rounds to 101
        XCTAssertNil(accumulator.apply(magnification: 0.004))           // 101.2048064 still rounds to 101
        XCTAssertEqual(accumulator.fractionalPercent, 101.2048064, accuracy: 1e-9)
        XCTAssertEqual(accumulator.publishedPercent, 101)
    }

    func testZoomAccumulatorSkipsAnUnchangedPublishedZoom() {
        var accumulator = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 100)
        XCTAssertEqual(accumulator.apply(magnification: 100), 3200)       // clamps at the top
        XCTAssertNil(accumulator.apply(magnification: 1))                // stays 3200
        var low = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 5)
        XCTAssertNil(low.apply(magnification: -0.9))                     // clamps at the bottom
    }

    func testZoomAccumulatorOverflowPublishesTheEndpointNotATrap() {
        var accumulator = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 100)
        XCTAssertEqual(accumulator.apply(magnification: 1e308), 3200)    // product overflows to +Inf
        XCTAssertTrue(accumulator.fractionalPercent.isFinite)
        XCTAssertEqual(accumulator.publishedPercent, 3200)
    }

    func testZoomAccumulatorRejectsZeroAndNonFiniteDeltasQuietly() {
        var accumulator = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 100)
        XCTAssertNil(accumulator.apply(magnification: 0))
        XCTAssertNil(accumulator.apply(magnification: .nan))
        XCTAssertNil(accumulator.apply(magnification: .infinity))
        XCTAssertNil(accumulator.apply(magnification: -1))
        XCTAssertEqual(accumulator.fractionalPercent, 100)
        XCTAssertEqual(accumulator.publishedPercent, 100)
    }

    func testZoomAccumulatorInitClampsTheStartingPercent() {
        XCTAssertEqual(TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 1).publishedPercent, 5)
        XCTAssertEqual(TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 100_000).publishedPercent, 3200)
    }

    // MARK: Zoom accumulator: rebase and cancel lifecycle

    func testZoomRebaseRestartsFromAnExternalZoomChange() {
        var accumulator = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 100)
        XCTAssertNil(accumulator.apply(magnification: 0.004))           // 100.4 pending
        accumulator.rebase(to: 200)                                       // zoom changed externally
        XCTAssertEqual(accumulator.publishedPercent, 200)
        XCTAssertEqual(accumulator.fractionalPercent, 200)
        XCTAssertEqual(accumulator.apply(magnification: 0.01), 202)     // 202 exactly
    }

    func testZoomClearKeepsThePublishedIntegerWithoutANewDelta() {
        var accumulator = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 100)
        accumulator.apply(magnification: 0.004)                          // 100.4 pending
        accumulator.clear()                                               // cancel: no new delta
        XCTAssertEqual(accumulator.fractionalPercent, 100)
        XCTAssertEqual(accumulator.publishedPercent, 100)
        XCTAssertEqual(accumulator.apply(magnification: 0.5), 150)       // continues from 100
    }

    // MARK: Rotation accumulator: sign, accumulation, lifecycle

    func testRotationAccumulatorMapsCounterclockwiseToMinus() {
        var accumulator = TrackpadNavigationLogic.RotationAccumulator(baseDegrees: 0)
        XCTAssertEqual(accumulator.apply(eventRotationDegrees: 10), -10) // CCW event, CW-negative canvas
        XCTAssertEqual(accumulator.apply(eventRotationDegrees: 10), -20)
        XCTAssertEqual(accumulator.apply(eventRotationDegrees: -5), -15) // CW event adds positively
    }

    func testRotationCancelClearsThePendingDeltaWithNoNewDelta() {
        var accumulator = TrackpadNavigationLogic.RotationAccumulator(baseDegrees: 30)
        XCTAssertEqual(accumulator.apply(eventRotationDegrees: 10), 20)
        accumulator.cancel()
        XCTAssertEqual(accumulator.deltaDegrees, 0)
        XCTAssertEqual(accumulator.apply(eventRotationDegrees: 5), 25)   // from the base, not from 20
    }

    func testRotationFinishMakesTheAppliedRotationTheNewBase() {
        var accumulator = TrackpadNavigationLogic.RotationAccumulator(baseDegrees: 0)
        accumulator.apply(eventRotationDegrees: 10)
        accumulator.apply(eventRotationDegrees: 10)
        accumulator.finish()                                              // end: apply, then clear
        XCTAssertEqual(accumulator.baseDegrees, -20)
        XCTAssertEqual(accumulator.deltaDegrees, 0)
        XCTAssertEqual(accumulator.apply(eventRotationDegrees: 5), -25)
    }

    func testRotationAccumulatorRejectsZeroNonFiniteAndOverflowQuietly() {
        var accumulator = TrackpadNavigationLogic.RotationAccumulator(baseDegrees: 0)
        XCTAssertNil(accumulator.apply(eventRotationDegrees: 0))
        XCTAssertNil(accumulator.apply(eventRotationDegrees: .nan))
        XCTAssertNil(accumulator.apply(eventRotationDegrees: .infinity))
        XCTAssertEqual(accumulator.deltaDegrees, 0)
        XCTAssertEqual(accumulator.apply(eventRotationDegrees: 1e308), -1e308)
        XCTAssertNil(accumulator.apply(eventRotationDegrees: 1e308))     // sum overflows: quiet
        XCTAssertEqual(accumulator.deltaDegrees, -1e308)
    }

    func testRotationRebaseRestartsFromTheCurrentViewRotation() {
        var accumulator = TrackpadNavigationLogic.RotationAccumulator(baseDegrees: 0)
        accumulator.apply(eventRotationDegrees: 45)
        accumulator.rebase(to: 90)                                        // .began / unmatched window
        XCTAssertEqual(accumulator.baseDegrees, 90)
        XCTAssertEqual(accumulator.deltaDegrees, 0)
        XCTAssertEqual(accumulator.apply(eventRotationDegrees: 15), 75)
    }

    func testRotationRebaseIgnoresANonFiniteBase() {
        var accumulator = TrackpadNavigationLogic.RotationAccumulator(baseDegrees: 12)
        accumulator.rebase(to: .nan)
        XCTAssertEqual(accumulator.baseDegrees, 12)
    }
}
