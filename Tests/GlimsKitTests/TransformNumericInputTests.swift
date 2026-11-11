import CoreGraphics
import XCTest
@testable import GlimsKit

final class TransformNumericInputTests: XCTestCase {
    func testParsesStrictDecimalNumbers() {
        XCTAssertEqual(TransformNumericInput.parse("12.5"), 12.5)
        XCTAssertEqual(TransformNumericInput.parse("  12.5  "), 12.5)
        XCTAssertEqual(TransformNumericInput.parse("-3"), -3)
        XCTAssertEqual(TransformNumericInput.parse("1e3"), 1000)
    }

    func testRejectsEmptyGarbageAndNonFiniteDrafts() {
        for text in ["", "   ", "abc", "12,5", "1e999", "-1e999", "nan", "inf", "0x10"] {
            XCTAssertNil(TransformNumericInput.parse(text), "parsed \(text)")
        }
    }

    func testFieldRangeProblemsAreActionable() {
        XCTAssertNil(TransformNumericInput.problem(0, for: .x))
        XCTAssertNil(TransformNumericInput.problem(-524288, for: .y))
        XCTAssertNotNil(TransformNumericInput.problem(524289, for: .x))
        XCTAssertNotNil(TransformNumericInput.problem(-524289, for: .y))

        XCTAssertNil(TransformNumericInput.problem(1, for: .width))
        XCTAssertNil(TransformNumericInput.problem(524288, for: .height))
        XCTAssertNotNil(TransformNumericInput.problem(0, for: .width))
        XCTAssertNotNil(TransformNumericInput.problem(-5, for: .height))
        XCTAssertNotNil(TransformNumericInput.problem(524289, for: .width))

        // Any finite angle is usable: the session normalizes degrees.
        XCTAssertNil(TransformNumericInput.problem(720, for: .angle))
        XCTAssertNil(TransformNumericInput.problem(-1e6, for: .angle))
    }
}
