import AppKit
import XCTest
@testable import GlimsKit

final class OptionScrollZoomTests: XCTestCase {
    func testCoarseAndPreciseFactorsHaveIndependentExpectedValues() throws {
        XCTAssertEqual(try XCTUnwrap(OptionScrollZoom.factor(delta: 8, precise: false)), 2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(OptionScrollZoom.factor(delta: 240, precise: true)), 2, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(OptionScrollZoom.factor(delta: -8, precise: false)), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(OptionScrollZoom.factor(delta: -240, precise: true)), 0.5, accuracy: 1e-12)
        XCTAssertEqual(OptionScrollZoom.factor(delta: 0, precise: false), 1)
        XCTAssertEqual(OptionScrollZoom.factor(delta: 0, precise: true), 1)
    }

    func testExponentIsClampedAndNonfiniteDeltasAreRefused() {
        XCTAssertEqual(OptionScrollZoom.factor(delta: .greatestFiniteMagnitude, precise: false), 65536)
        XCTAssertEqual(OptionScrollZoom.factor(delta: -.greatestFiniteMagnitude, precise: true), 1.0 / 65536)
        for delta in [Double.nan, .infinity, -.infinity] {
            XCTAssertNil(OptionScrollZoom.factor(delta: delta, precise: false))
        }
    }

    func testNativeModifierValuesAllowShiftAndIgnoreUnrelatedFlags() {
        XCTAssertTrue(OptionScrollZoom.isAdmitted(.option))
        XCTAssertTrue(OptionScrollZoom.isAdmitted([.option, .shift, .capsLock, .function]))
        for flags: NSEvent.ModifierFlags in [[], .shift, .command, [.option, .command], [.option, .control]] {
            XCTAssertFalse(OptionScrollZoom.isAdmitted(flags))
        }
    }

    private func apply(_ delta: Double?, to accumulator: inout TrackpadNavigationLogic.ZoomAccumulator,
                       current: Int = 100, began: Bool = false, ended: Bool = false,
                       cancelled: Bool = false) -> Int? {
        OptionScrollZoom.apply(delta: delta, precise: false, currentPercent: current,
                               began: began, ended: ended, cancelled: cancelled, to: &accumulator)
    }

    func testSubpercentMessagesAccumulateWithoutRoundingEachDelta() {
        var accumulator = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 100)
        XCTAssertNil(apply(0.04, to: &accumulator))
        XCTAssertEqual(apply(0.04, to: &accumulator), 101)
    }

    func testZeroAndInvalidTerminalDeltasClearPendingFraction() {
        for delta in [Double?.some(0), .some(.nan), .none] {
            var accumulator = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 100)
            XCTAssertNil(apply(0.04, to: &accumulator))
            XCTAssertNil(apply(delta, to: &accumulator, ended: true))
            XCTAssertEqual(accumulator.fractionalPercent, 100)
            XCTAssertNil(apply(0.04, to: &accumulator))
        }
    }

    func testCancelIgnoresItsDeltaAndDropsPendingFraction() {
        var accumulator = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 100)
        XCTAssertNil(apply(0.04, to: &accumulator))
        XCTAssertNil(apply(8, to: &accumulator, cancelled: true))
        XCTAssertEqual(accumulator.fractionalPercent, 100)
        XCTAssertNil(apply(0.04, to: &accumulator))
    }

    func testBeginAndExternalZoomRebaseBeforeApplyingDelta() {
        var accumulator = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 100)
        XCTAssertNil(apply(0.04, to: &accumulator))
        XCTAssertNil(apply(0, to: &accumulator, began: true))
        XCTAssertEqual(accumulator.fractionalPercent, 100)
        XCTAssertEqual(apply(8, to: &accumulator, current: 200), 400)
    }

    func testEndsApplyTheirDeltaThenDropTailAndClampAtZoomBounds() {
        var accumulator = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: 100)
        XCTAssertEqual(apply(8, to: &accumulator, ended: true), 200)
        XCTAssertEqual(accumulator.fractionalPercent, 200)
        XCTAssertEqual(apply(.greatestFiniteMagnitude, to: &accumulator, current: 200), 3200)
        XCTAssertEqual(apply(-.greatestFiniteMagnitude, to: &accumulator, current: 3200), 5)
    }
}
