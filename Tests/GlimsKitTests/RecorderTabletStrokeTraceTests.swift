import XCTest
@testable import GlimsKit

final class RecorderTabletStrokeTraceTests: XCTestCase {
    private func point(
        x: Double = 1,
        y: Double = 2,
        pressure: Double = 0.5,
        xTilt: Double = 0.25,
        yTilt: Double = -0.5,
        timeMilliseconds: UInt32 = 0,
        rotationTurns: Double? = nil,
        tangentialPressure: Double? = nil
    ) throws -> RecorderTabletStrokeTrace.Point {
        try .init(
            x: x, y: y, pressure: pressure, xTilt: xTilt, yTilt: yTilt,
            timeMilliseconds: timeMilliseconds,
            rotationTurns: rotationTurns,
            tangentialPressure: tangentialPressure
        )
    }

    func testAcceptedLiteralBoundsAndBatchBoundaries() throws {
        let first = try point(x: -524_288, y: 524_288, pressure: 0, xTilt: -1, yTilt: 1,
                              timeMilliseconds: 10, rotationTurns: 0, tangentialPressure: -1)
        let a = try point(x: 524_288, y: -524_288, pressure: 1, xTilt: 1, yTilt: -1,
                          timeMilliseconds: 10, rotationTurns: 0.999999, tangentialPressure: 1)
        let b = try point(timeMilliseconds: 11)
        var accumulator = RecorderTabletStrokeAccumulator(first: first)
        accumulator.appendAccepted([a])
        accumulator.appendAccepted([])
        accumulator.appendAccepted([b])

        XCTAssertEqual(try accumulator.finish()?.get(), .init(first: first, batches: [[a], [b]]))
        XCTAssertNil(accumulator.finish())
    }

    func testInvalidFiniteCoordinatePressureTiltAndOptionalBoundsAreRefused() {
        XCTAssertThrowsError(try point(x: 524_288.000001))
        XCTAssertThrowsError(try point(pressure: -0.000001))
        XCTAssertThrowsError(try point(xTilt: 1.000001))
        XCTAssertThrowsError(try point(x: .nan))
        XCTAssertThrowsError(try point(y: .infinity))
        XCTAssertThrowsError(try point(rotationTurns: -.leastNonzeroMagnitude))
        XCTAssertThrowsError(try point(rotationTurns: 1))
        XCTAssertThrowsError(try point(rotationTurns: .nan))
        XCTAssertThrowsError(try point(tangentialPressure: -1.000001))
        XCTAssertThrowsError(try point(tangentialPressure: .infinity))
    }

    func testOptionalAbsenceAndExplicitZeroRemainDistinct() throws {
        let absent = try point(rotationTurns: nil, tangentialPressure: nil)
        let explicitZero = try point(rotationTurns: 0, tangentialPressure: 0)

        XCTAssertNil(absent.rotationTurns)
        XCTAssertNil(absent.tangentialPressure)
        XCTAssertEqual(explicitZero.rotationTurns, 0)
        XCTAssertEqual(explicitZero.tangentialPressure, 0)
        XCTAssertNotEqual(absent, explicitZero)
    }

    func testNativeConversionPreservesValuesAndOptionalDistinction() throws {
        let nativeAbsent = EngineSession.StrokeSampleV2(
            point: .init(x: 3, y: 4, pressure: 0.75, xTilt: -0.25, yTilt: 0.5, timeMilliseconds: 42),
            rotationTurns: nil,
            tangentialPressure: nil
        )
        let nativeZero = EngineSession.StrokeSampleV2(
            point: .init(x: 3, y: 4, pressure: 0.75, xTilt: -0.25, yTilt: 0.5, timeMilliseconds: 42),
            rotationTurns: 0,
            tangentialPressure: 0
        )

        let absent = try RecorderTabletStrokeTrace.Point(native: nativeAbsent)
        let explicitZero = try RecorderTabletStrokeTrace.Point(native: nativeZero)

        XCTAssertEqual(absent.nativeSample, nativeAbsent)
        XCTAssertEqual(explicitZero.nativeSample, nativeZero)
        XCTAssertNil(absent.rotationTurns)
        XCTAssertEqual(explicitZero.rotationTurns, 0)
        XCTAssertNotEqual(absent, explicitZero)
    }

    func testBatchTimestampContractAcceptsForwardWrapAndRejectsUnsafeOrder() throws {
        let first = try point(timeMilliseconds: UInt32.max - 2)
        let wrapped = try point(x: 2, timeMilliseconds: 5)
        let maxForward = try point(x: 3, timeMilliseconds: 5 &+ 0x7fff_ffff)
        var accepted = RecorderTabletStrokeAccumulator(first: first)
        accepted.appendAccepted([wrapped, maxForward])
        XCTAssertEqual(try accepted.finish()?.get().batches, [[wrapped, maxForward]])

        var backward = RecorderTabletStrokeAccumulator(first: try point(timeMilliseconds: 100))
        backward.appendAccepted([try point(x: 2, timeMilliseconds: 99)])
        XCTAssertEqual(backward.finish(), .failure(.invalidTimestampOrder))

        var tooFar = RecorderTabletStrokeAccumulator(first: try point(timeMilliseconds: 10))
        tooFar.appendAccepted([try point(x: 2, timeMilliseconds: 10 &+ 0x8000_0000)])
        XCTAssertEqual(tooFar.finish(), .failure(.invalidTimestampOrder))
    }

    func testInvalidSampleOrTimestampFailsWholeTraceAndFirstFailureIsSticky() throws {
        let first = try point(timeMilliseconds: 1)
        var invalid = RecorderTabletStrokeAccumulator(first: first)
        invalid.appendAccepted([try point(x: 2, timeMilliseconds: 2)])
        invalid.refuse(.invalidSample)
        invalid.appendAccepted([try point(x: 3, timeMilliseconds: 3)])
        invalid.refuse(.refused("later native failure"))
        XCTAssertEqual(invalid.finish(), .failure(.invalidSample))

        var refused = RecorderTabletStrokeAccumulator(first: first)
        refused.appendAccepted([try point(x: 2, timeMilliseconds: 2)])
        refused.refuse(.refused("The native continuation failed."))
        refused.appendAccepted([try point(x: 3, timeMilliseconds: 3)])
        XCTAssertEqual(refused.finish(), .failure(.refused("The native continuation failed.")))
    }

    func testTotalCountCapCountsFirstAndRefusesWholeTrace() throws {
        let first = try point(timeMilliseconds: 1)
        let maximumContinuation = (0..<65_535).map { index in
            try! point(x: Double(index + 2), timeMilliseconds: UInt32(index + 2))
        }

        var exact = RecorderTabletStrokeAccumulator(first: first)
        exact.appendAccepted(maximumContinuation)
        XCTAssertEqual(try exact.finish()?.get().batches.first?.count, 65_535)

        var overflow = RecorderTabletStrokeAccumulator(first: first)
        overflow.appendAccepted(maximumContinuation)
        overflow.appendAccepted([try point(x: 99, timeMilliseconds: 70_000)])
        XCTAssertEqual(overflow.finish(), .failure(.tooManyPoints))

        var acrossBatches = RecorderTabletStrokeAccumulator(first: first)
        acrossBatches.appendAccepted(Array(maximumContinuation.prefix(65_534)))
        acrossBatches.appendAccepted([maximumContinuation[65_534], try point(x: 100, timeMilliseconds: 70_001)])
        XCTAssertEqual(acrossBatches.finish(), .failure(.tooManyPoints))
    }

    func testFinishIsOnceOnly() throws {
        let first = try point(timeMilliseconds: 7)
        var accumulator = RecorderTabletStrokeAccumulator(first: first)
        accumulator.appendAccepted([try point(x: 2, timeMilliseconds: 8)])
        XCTAssertEqual(try accumulator.finish()?.get(), .init(first: first, batches: [[try point(x: 2, timeMilliseconds: 8)]]))
        XCTAssertNil(accumulator.finish())
    }
}
