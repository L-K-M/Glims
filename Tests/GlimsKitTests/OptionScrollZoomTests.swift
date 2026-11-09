import XCTest
@testable import GlimsKit

final class OptionScrollZoomTests: XCTestCase {
    func testCoarseDeltaEightDoubles() {
        XCTAssertEqual(OptionScrollZoom.factor(delta: 8, precise: false), 2, accuracy: 1e-12)
    }

    func testPreciseDeltaTwoFortyDoubles() {
        XCTAssertEqual(OptionScrollZoom.factor(delta: 240, precise: true), 2, accuracy: 1e-12)
    }

    func testNegativeDeltaHalves() {
        XCTAssertEqual(OptionScrollZoom.factor(delta: -8, precise: false), 0.5, accuracy: 1e-12)
        XCTAssertEqual(OptionScrollZoom.factor(delta: -240, precise: true), 0.5, accuracy: 1e-12)
    }

    func testZeroDeltaIsOne() {
        XCTAssertEqual(OptionScrollZoom.factor(delta: 0, precise: false), 1, accuracy: 1e-12)
        XCTAssertEqual(OptionScrollZoom.factor(delta: 0, precise: true), 1, accuracy: 1e-12)
    }

    func testExtremeDeltaClampsExponent() {
        XCTAssertEqual(OptionScrollZoom.factor(delta: 1e9, precise: true), pow(2, 16), accuracy: 1e-6)
        XCTAssertEqual(OptionScrollZoom.factor(delta: -1e9, precise: true), pow(2, -16), accuracy: 1e-12)
    }

    func testNonFiniteDeltaDoesNotCrash() {
        XCTAssertTrue(OptionScrollZoom.factor(delta: .nan, precise: false).isNaN
            || OptionScrollZoom.factor(delta: .nan, precise: false).isFinite)
        XCTAssertTrue(OptionScrollZoom.factor(delta: .infinity, precise: false).isFinite)
    }

    func testModifierAdmission() {
        XCTAssertTrue(OptionScrollZoom.isAdmitted(option: true, command: false, control: false))
        XCTAssertTrue(OptionScrollZoom.isAdmitted(option: true, command: false, control: false, shift: true))
        XCTAssertFalse(OptionScrollZoom.isAdmitted(option: false, command: false, control: false))
        XCTAssertFalse(OptionScrollZoom.isAdmitted(option: true, command: true, control: false))
        XCTAssertFalse(OptionScrollZoom.isAdmitted(option: true, command: false, control: true))
    }

    func testModifierAdmissionIgnoresShift() {
        XCTAssertTrue(OptionScrollZoom.isAdmitted(option: true, command: false, control: false, shift: false))
        XCTAssertTrue(OptionScrollZoom.isAdmitted(option: true, command: false, control: false, shift: true))
    }
}