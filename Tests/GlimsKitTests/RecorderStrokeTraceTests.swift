import XCTest
@testable import GlimsKit

final class RecorderStrokeTraceTests: XCTestCase {
    private func sample(_ x: Double, time: UInt32 = 0) throws -> RecorderStrokeTrace.Point {
        try .init(x: x, y: 2, pressure: 0.75, xTilt: 0.25, yTilt: -0.5, timeMilliseconds: time)
    }

    func testCompletedTraceKeepsCallBoundariesAndWrappedTimes() throws {
        let first = try sample(1, time: .max - 1)
        let a = try sample(2, time: .max)
        let b = try sample(3, time: 0)
        let c = try sample(4, time: 0)
        var capture = RecorderStrokeAccumulator(first: first)
        capture.appendAccepted([a, b])
        capture.appendAccepted([])
        capture.appendAccepted([c])
        XCTAssertEqual(try capture.finish()?.get(), .init(first: first, batches: [[a, b], [c]]))
        XCTAssertNil(capture.finish())
    }

    func testAContinuationFailureNeverYieldsASuccessfulPrefix() throws {
        let first = try sample(1)
        var capture = RecorderStrokeAccumulator(first: first)
        capture.appendAccepted([try sample(2)])
        capture.refuse(.refused("The native continuation failed."))
        capture.appendAccepted([try sample(3)])
        capture.refuse(.refused("The native cleanup also failed."))
        XCTAssertEqual(capture.finish(), .failure(.refused("The native continuation failed.")))
        XCTAssertNil(capture.finish())
    }

    func testAggregateLimitRefusesTheWholeStroke() throws {
        let first = try sample(1)
        let maximum = Array(repeating: first, count: 65_535)
        var exact = RecorderStrokeAccumulator(first: first)
        exact.appendAccepted(maximum)
        XCTAssertEqual(try exact.finish()?.get().batches.first?.count, 65_535)

        var overflow = RecorderStrokeAccumulator(first: first)
        overflow.appendAccepted(maximum)
        overflow.appendAccepted([first])
        XCTAssertEqual(overflow.finish(), .failure(.tooManyPoints))
    }

    func testUnsafeCoordinatesAndNonfiniteAxesAreRefused() throws {
        XCTAssertNoThrow(try sample(-524_288))
        XCTAssertThrowsError(try sample(524_289))
        XCTAssertThrowsError(try sample(.nan))
        XCTAssertThrowsError(try RecorderStrokeTrace.Point(x: 1, y: 2, pressure: 1, xTilt: .infinity,
                                                            yTilt: 0, timeMilliseconds: 1))
    }
}
