import XCTest
@testable import GlimsKit

final class InputHistogramTests: XCTestCase {
    typealias Histogram = EngineSession.InputHistogram
    func testEmptyNativeResultRetainsValueAvailability() {
        XCTAssertTrue(Histogram(trc: .linear, binCount: 0, channels: [.value: []]).isValid)
    }
    func testNativeBinCountsAndSignedWeightsStayExact() {
        for count in [256, 1024, 4096] {
            var bins = Array(repeating: 0.0, count: count)
            bins[0] = -0.5; bins[count - 1] = 1.5
            let value = Histogram(trc: .perceptual, binCount: count, channels: [.value: bins, .alpha: bins])
            XCTAssertTrue(value.isValid)
            XCTAssertEqual(value[.value]?[0], -0.5)
            XCTAssertEqual(value[.alpha]?[count - 1], 1.5)
            XCTAssertNil(value[.red])
        }
    }
    func testMissingValueOrUnknownTransferCurveIsInvalid() {
        XCTAssertFalse(Histogram(trc: .unknown, binCount: 0, channels: [.value: []]).isValid)
        XCTAssertFalse(Histogram(trc: .linear, binCount: 0, channels: [:]).isValid)
    }
    func testEveryAvailableChannelMustMatchTheNativeBinCount() {
        let value = Array(repeating: 0.0, count: 256)
        XCTAssertFalse(Histogram(trc: .linear, binCount: 256, channels: [.value: value, .red: []]).isValid)
        XCTAssertFalse(Histogram(trc: .linear, binCount: -1, channels: [.value: []]).isValid)
        XCTAssertFalse(Histogram(trc: .linear, binCount: 4097, channels: [.value: []]).isValid)
    }
    func testNonfiniteWeightsAreRefusedWithoutClampingFiniteSignedData() {
        for invalid in [Double.nan, .infinity, -.infinity] {
            var bins = Array(repeating: -0.25, count: 256); bins[128] = invalid
            XCTAssertFalse(Histogram(trc: .nonlinear, binCount: 256, channels: [.value: bins]).isValid)
        }
    }
}
