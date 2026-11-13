import XCTest
@testable import GlimsKit

final class RecorderLabStrokeValueTests: XCTestCase {
    private func point(_ time: UInt32 = 0) throws -> RecorderTabletStrokeTrace.Point {
        try .init(x: 4, y: 5, pressure: 0.7, xTilt: -0.2, yTilt: 0.3, timeMilliseconds: time)
    }

    private func command(value: Double = -32, size: Double = 4, opacity: Double = 0.7,
                         hardness: Double = 0.5, name: String = "Brush", collection: String? = nil,
                         fingerprint: String = String(repeating: "a", count: 64),
                         trace: RecorderTabletStrokeTrace? = nil) throws -> RecorderLabStrokeCommand {
        .init(settings: .init(value: value, size: size, opacity: opacity, hardness: hardness),
              trace: try trace ?? .init(first: point(), batches: []),
              facts: .init(brush: .init(name: name, collection: collection, isInternal: false), fingerprint: fingerprint))
    }

    func testPhysicalValuesAndOptionalTabletAxesRemainExact() throws {
        let first = try point(UInt32.max - 1)
        let next = try RecorderTabletStrokeTrace.Point(x: 5, y: 6, pressure: 0.8,
            xTilt: 0, yTilt: 0, timeMilliseconds: 1, rotationTurns: 0, tangentialPressure: 0)
        let value = try command(value: -200, trace: .init(first: first, batches: [[next]]))
        XCTAssertEqual(try value.validated(), value)
        XCTAssertNil(value.trace.first.nativeSample.rotationTurns)
        XCTAssertEqual(value.trace.batches[0][0].nativeSample.rotationTurns, 0)
        XCTAssertEqual(value.trace.batches[0][0].nativeSample.tangentialPressure, 0)
    }

    func testRejectsInvalidSettingsBeforeReplay() throws {
        for value in [Double.nan, .infinity, Double(Float.greatestFiniteMagnitude) * 2] {
            XCTAssertThrowsError(try command(value: value).validated())
        }
        for size in [0.9, 10_001, .nan, .infinity] { XCTAssertThrowsError(try command(size: size).validated()) }
        for value in [-0.01, 1.01, .nan, .infinity] {
            XCTAssertThrowsError(try command(opacity: value).validated())
            XCTAssertThrowsError(try command(hardness: value).validated())
        }
    }

    func testResourceIdentityAndDigestAreValidated() throws {
        for name in ["", "bad\0name", String(repeating: "a", count: RecorderFileLimits.stringBytes + 1)] {
            XCTAssertThrowsError(try command(name: name).validated())
        }
        XCTAssertThrowsError(try command(collection: "bad\0collection").validated())
        for digest in ["", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            XCTAssertThrowsError(try command(fingerprint: digest).validated())
        }
        XCTAssertNotEqual(try command(collection: nil).validated(), try command(collection: "").validated())
    }

    func testCallerBuiltTraceRejectsBackwardTimeAndEmptyOrOversizedBatches() throws {
        let first = try point(10)
        for batches in [[[]], [[try point(9)]], [Array(repeating: try point(11), count: 4097)]] {
            XCTAssertThrowsError(try command(trace: .init(first: first, batches: batches)).validated())
        }
    }

    func testStrokeAndFilePointBudgets() throws {
        let first = try point()
        let full = Array(repeating: first, count: 4096)
        let allowed = RecorderTabletStrokeTrace(first: first,
            batches: Array(repeating: full, count: 15) + [Array(repeating: first, count: 4095)])
        XCTAssertNoThrow(try command(trace: allowed).validated())
        let excessive = RecorderTabletStrokeTrace(first: first, batches: Array(repeating: full, count: 16))
        XCTAssertThrowsError(try command(trace: excessive).validated())
        XCTAssertThrowsError(try RecorderFileLimits.tabletStrokePointCount(allowed, remaining: 65_535))
    }
}
