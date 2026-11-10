import XCTest
@testable import GlimsKit

/// Pure contract tests for `MetadataRatingValue`: the Xmp.xmp.Rating value
/// type recognizes only exact whole wire arrays, never parses or normalizes
/// numbers, and leaves unrecognized source text with the caller. Every
/// expectation below comes from the literal `canonical` table; none is
/// computed by running the implementation.
final class MetadataRatingValueTests: XCTestCase {
    /// Independent literal table: case, exact wire array, exact title.
    private static let canonical: [(MetadataRatingValue, [String], String)] = [
        (.unspecified, [], "Not specified"),
        (.unrated, ["0"], "Unrated (0)"),
        (.rejected, ["-1"], "Rejected (-1)"),
        (.one, ["1"], "1 star"),
        (.two, ["2"], "2 stars"),
        (.three, ["3"], "3 stars"),
        (.four, ["4"], "4 stars"),
        (.five, ["5"], "5 stars"),
    ]

    /// Arrays that must stay unrecognized: no parsing, trimming, joining,
    /// element dropping, rounding, or implicit absence/zero.
    private static let unknownArrays: [[String]] = [
        // Fractional and otherwise numeric spellings are never rounded.
        ["2.5"], ["2.50"], ["0.5"], ["-1.0"], ["1.0"], ["3.0"], ["3e0"], ["1e0"],
        // Noncanonical digit spellings.
        ["03"], ["-0"], ["+3"], ["0x3"],
        // Out-of-range values.
        ["6"], ["-2"], ["-1", "-1"], ["0", "0"], ["5", "5"],
        // Whitespace and line endings are not trimmed.
        [""], [" "], [" 3 "], ["3\n"], ["3\r\n"], ["\t3"], ["3\t"],
        // Multiple values are not collapsed or dropped.
        ["3", "4"], ["0", ""], ["", "0"], ["1", "2", "3", "4", "5"],
        // Non-finite and huge numerals are strings, not numbers.
        ["NaN"], ["nan"], ["inf"], ["-inf"], ["Infinity"],
        ["999999999999999999999999999999999999999"],
        // Unicode digit lookalikes are not ASCII digits.
        ["３"], ["③"], ["³"],
    ]

    func testCanonicalTableHasEightUniqueChoicesTitlesAndArrays() {
        XCTAssertEqual(Self.canonical.count, 8)
        XCTAssertEqual(Set(Self.canonical.map(\.0)).count, 8)
        XCTAssertEqual(Set(Self.canonical.map(\.2)).count, 8)
        XCTAssertEqual(Set(Self.canonical.map(\.1)).count, 8)
    }

    func testAllCasesMatchTheLiteralTableInOrder() {
        XCTAssertEqual(MetadataRatingValue.allCases, Self.canonical.map(\.0))
    }

    func testEachCanonicalArrayInitializesItsChoiceWithExactOutputAndTitle() {
        for (choice, values, title) in Self.canonical {
            XCTAssertEqual(MetadataRatingValue(values: values), choice,
                           "expected \(values) to initialize \(choice)")
            XCTAssertEqual(choice.values, values,
                           "expected \(choice) to emit \(values)")
            XCTAssertEqual(choice.title, title,
                           "expected \(choice) title \(title)")
        }
    }

    func testAbsenceEmptySingletonAndExplicitZeroStayDistinct() {
        XCTAssertEqual(MetadataRatingValue(values: []), .unspecified)
        XCTAssertNil(MetadataRatingValue(values: [""]))
        XCTAssertEqual(MetadataRatingValue(values: ["0"]), .unrated)
        XCTAssertNotEqual(MetadataRatingValue(values: []), MetadataRatingValue(values: ["0"]))
        XCTAssertTrue(MetadataRatingValue.unspecified.values.isEmpty)
        XCTAssertFalse(MetadataRatingValue.unrated.values.isEmpty)
        XCTAssertNotEqual(MetadataRatingValue.unspecified.values, MetadataRatingValue.unrated.values)
    }

    func testRejectedUsesMinusOneNotADash() {
        XCTAssertEqual(MetadataRatingValue(values: ["-1"]), .rejected)
        XCTAssertEqual(MetadataRatingValue.rejected.values, ["-1"])
        XCTAssertEqual(MetadataRatingValue.rejected.title, "Rejected (-1)")
        XCTAssertNil(MetadataRatingValue(values: ["-"]))
        XCTAssertNil(MetadataRatingValue(values: ["--1"]))
        XCTAssertNil(MetadataRatingValue(values: ["−1"]))
    }

    func testFractionalRatingStaysWithTheCaller() {
        XCTAssertNil(MetadataRatingValue(values: ["2.5"]))
        XCTAssertNil(MetadataRatingValue(values: ["2.50"]))
        XCTAssertNil(MetadataRatingValue(values: ["0.5"]))
        XCTAssertEqual(MetadataRatingValue(values: ["2"]), .two)
        XCTAssertNotEqual(MetadataRatingValue(values: ["2.5"]),
                          MetadataRatingValue(values: ["2"]))
    }

    func testOnlyExactWholeArraysAreRecognized() {
        for values in Self.unknownArrays {
            XCTAssertNil(MetadataRatingValue(values: values),
                         "unexpected coercion of \(values)")
        }
    }

    func testEveryChoiceRoundTripsWithoutChangingItsSpelling() {
        for choice in MetadataRatingValue.allCases {
            XCTAssertEqual(MetadataRatingValue(values: choice.values), choice)
        }
    }
}
