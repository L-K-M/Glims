import XCTest
@testable import GlimsKit

final class TabletStrokeValuesTests: XCTestCase {
    func testRotationNormalizesPositiveAndNegativeDegrees() {
        let cases: [(Double, Double)] = [
            (0, 0), (90, 0.25), (180, 0.5), (270, 0.75), (360, 0),
            (-90, 0.75), (-180, 0.5), (-270, 0.25), (-360, 0),
            (810, 0.25), (-810, 0.75)
        ]
        for (degrees, turns) in cases {
            XCTAssertEqual(TabletStrokeAxes(rotationDegrees: degrees, tangentialPressure: nil).rotationTurns,
                           turns, "\(degrees) degrees")
        }
    }

    func testLargeAngleReducesBeforeDividing() throws {
        // 2^63 degrees has eight degrees left after full turns. Its quotient
        // in turns is too large to represent the fraction before reduction.
        let axes = TabletStrokeAxes(rotationDegrees: 9_223_372_036_854_775_808.0,
                                    tangentialPressure: nil)
        XCTAssertEqual(try XCTUnwrap(axes.rotationTurns), 1.0 / 45.0, accuracy: 1e-16)
    }

    func testRotationCanonicalizesRoundedOneAndSignedZero() throws {
        for degrees in [-0.0, -360.0, -1e-15, -Double.leastNonzeroMagnitude] {
            let axes = TabletStrokeAxes(rotationDegrees: degrees, tangentialPressure: nil)
            XCTAssertEqual(try XCTUnwrap(axes.rotationTurns).bitPattern, 0, "\(degrees) degrees")
        }
        let beforeWrap = TabletStrokeAxes(rotationDegrees: Double(360).nextDown, tangentialPressure: nil)
        let turns = try XCTUnwrap(beforeWrap.rotationTurns)
        XCTAssertGreaterThan(turns, 0.99)
        XCTAssertLessThan(turns, 1)
    }

    func testMissingAndInvalidAxesAreIndependentOfPresentZero() {
        let absent = TabletStrokeAxes(rotationDegrees: nil, tangentialPressure: nil)
        XCTAssertNil(absent.rotationTurns)
        XCTAssertNil(absent.tangentialPressure)
        XCTAssertNotEqual(absent, TabletStrokeAxes(rotationDegrees: 0, tangentialPressure: 0))

        for degrees in [Double.nan, .infinity, -.infinity] {
            let axes = TabletStrokeAxes(rotationDegrees: degrees, tangentialPressure: -0.5)
            XCTAssertNil(axes.rotationTurns)
            XCTAssertEqual(axes.tangentialPressure, -0.5)
        }
        for pressure in [Double.nan, .infinity, -.infinity, -1.01, 1.01] {
            let axes = TabletStrokeAxes(rotationDegrees: 90, tangentialPressure: pressure)
            XCTAssertEqual(axes.rotationTurns, 0.25)
            XCTAssertNil(axes.tangentialPressure)
        }
        for pressure in [-1.0, -0.25, 0, 0.25, 1] {
            XCTAssertEqual(TabletStrokeAxes(rotationDegrees: nil, tangentialPressure: pressure).tangentialPressure,
                           pressure)
        }
    }

    func testClockFloorsMillisecondsAndWrapsAtTwoToThe32() {
        let cases: [(Double, UInt32)] = [
            (-0.0, 0), (0.0009, 0), (0.0019, 1), (1.2349, 1_234),
            (4_294_967.295, 4_294_967_295), (4_294_967.296, 0), (4_294_967.297, 1),
            (36_028_797_018_963_968.0, 0), (36_028_797_018_964_480.0, 512_000)
        ]
        for (seconds, milliseconds) in cases {
            XCTAssertEqual(TabletStrokeTime(seconds: seconds)?.milliseconds, milliseconds, "\(seconds) seconds")
        }
    }

    func testClockRefusesNonfiniteNegativeAndScaledOverflow() {
        for seconds in [Double.nan, .infinity, -.infinity, -0.0001, .greatestFiniteMagnitude] {
            XCTAssertNil(TabletStrokeTime(seconds: seconds), "\(seconds) seconds")
        }
    }

    func testClockOrderAcceptsEqualAndWrappedForwardReadings() throws {
        let justBeforeWrap = try XCTUnwrap(TabletStrokeTime(seconds: 4_294_967.295))
        let sameTick = try XCTUnwrap(TabletStrokeTime(seconds: 4_294_967.2955))
        let justAfterWrap = try XCTUnwrap(TabletStrokeTime(seconds: 4_294_967.296))
        let oneMore = try XCTUnwrap(TabletStrokeTime(seconds: 4_294_967.297))
        XCTAssertEqual(sameTick, justBeforeWrap)
        XCTAssertTrue(sameTick.canFollow(justBeforeWrap))
        XCTAssertTrue(justAfterWrap.canFollow(justBeforeWrap))
        XCTAssertTrue(oneMore.canFollow(justBeforeWrap))
        XCTAssertFalse(justBeforeWrap.canFollow(justAfterWrap))
        XCTAssertFalse(justAfterWrap.canFollow(oneMore))
    }

    func testClockOrderRejectsAmbiguousHalfRangeAndLargerDelta() throws {
        let zero = try XCTUnwrap(TabletStrokeTime(seconds: 0))
        let shortOfHalf = try XCTUnwrap(TabletStrokeTime(seconds: 2_147_483.647))
        let half = try XCTUnwrap(TabletStrokeTime(seconds: 2_147_483.648))
        let pastHalf = try XCTUnwrap(TabletStrokeTime(seconds: 2_147_483.649))
        XCTAssertEqual(shortOfHalf.milliseconds, 0x7fff_ffff)
        XCTAssertEqual(half.milliseconds, 0x8000_0000)
        XCTAssertEqual(pastHalf.milliseconds, 0x8000_0001)
        XCTAssertTrue(shortOfHalf.canFollow(zero))
        XCTAssertFalse(half.canFollow(zero))
        XCTAssertFalse(zero.canFollow(half))
        XCTAssertFalse(pastHalf.canFollow(zero))
    }
}
