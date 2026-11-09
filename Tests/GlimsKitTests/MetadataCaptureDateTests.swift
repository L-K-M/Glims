import XCTest
@testable import GlimsKit

/// Independent literal expectations: every result asserted here is
/// written out by hand from the documented Gregorian rules, never
/// produced by MetadataCaptureDate itself except in round trips against
/// literal strings.
final class MetadataCaptureDateTests: XCTestCase {

    private func value(_ year: Int, _ month: Int, _ day: Int,
                       _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0)
    -> MetadataCaptureDate? {
        MetadataCaptureDate(year: year, month: month, day: day,
                            hour: hour, minute: minute, second: second)
    }

    // MARK: Validated value

    func testValidValueRoundTripsCanonicalLiteral() throws {
        let date = try XCTUnwrap(value(2024, 2, 29, 12, 34, 56))
        XCTAssertEqual(date.year, 2024)
        XCTAssertEqual(date.month, 2)
        XCTAssertEqual(date.day, 29)
        XCTAssertEqual(date.hour, 12)
        XCTAssertEqual(date.minute, 34)
        XCTAssertEqual(date.second, 56)
        XCTAssertEqual(date.metadataText, "2024:02:29 12:34:56")
    }

    func testLeapYearRule() {
        XCTAssertNil(value(1900, 2, 29), "1900 is not a leap year")
        XCTAssertNil(value(2100, 2, 29), "2100 is not a leap year")
        XCTAssertNotNil(value(2000, 2, 29), "2000 is a leap year")
        XCTAssertNotNil(value(2024, 2, 29), "2024 is a leap year")
    }

    func testEveryMonthLastDayAcceptedAndOverflowRejected() {
        // 2023 is not a leap year.
        let lastDays = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        for (index, lastDay) in lastDays.enumerated() {
            let month = index + 1
            XCTAssertNotNil(value(2023, month, lastDay), "month \(month) last day")
            XCTAssertNil(value(2023, month, lastDay + 1), "month \(month) overflow")
            XCTAssertNil(value(2023, month, 0), "month \(month) day zero")
        }
        XCTAssertNil(value(2023, 0, 1))
        XCTAssertNil(value(2023, 13, 1))
    }

    func testTimeBoundaries() {
        XCTAssertNotNil(value(2024, 6, 15, 23, 59, 59))
        XCTAssertNil(value(2024, 6, 15, 24, 0, 0))
        XCTAssertNil(value(2024, 6, 15, 0, 60, 0))
        XCTAssertNil(value(2024, 6, 15, 0, 0, 60))
        XCTAssertNil(value(2024, 6, 15, -1, 0, 0))
        XCTAssertNil(value(2024, 6, 15, 0, -1, 0))
        XCTAssertNil(value(2024, 6, 15, 0, 0, -1))
    }

    func testYearBoundaries() {
        XCTAssertNil(value(0, 1, 1))
        XCTAssertNil(value(10000, 1, 1))
    }

    func testExtremeIntegerComponentsRejectedWithoutTrapping() {
        XCTAssertNil(value(Int.min, 1, 1))
        XCTAssertNil(value(Int.max, 1, 1))
        XCTAssertNil(value(2024, Int.min, 1))
        XCTAssertNil(value(2024, Int.max, 1))
        XCTAssertNil(value(2024, 1, Int.min))
        XCTAssertNil(value(2024, 1, 1, Int.min, 0, 0))
        XCTAssertNil(value(2024, 1, 1, 0, Int.max, 0))
        XCTAssertNil(value(2024, 1, 1, 0, 0, Int.min))
    }

    func testEqualityMatchesFields() {
        XCTAssertEqual(value(2024, 2, 29, 1, 2, 3), value(2024, 2, 29, 1, 2, 3))
        XCTAssertNotEqual(value(2024, 2, 29, 1, 2, 3), value(2024, 2, 28, 1, 2, 3))
    }

    // MARK: Text form

    func testEarliestAndLatestRoundTrip() throws {
        let earliest = try XCTUnwrap(MetadataCaptureDate(metadataText: "0001:01:01 00:00:00"))
        XCTAssertEqual(earliest.year, 1)
        XCTAssertEqual(earliest.month, 1)
        XCTAssertEqual(earliest.day, 1)
        XCTAssertEqual(earliest.hour, 0)
        XCTAssertEqual(earliest.minute, 0)
        XCTAssertEqual(earliest.second, 0)
        XCTAssertEqual(earliest.metadataText, "0001:01:01 00:00:00")

        let latest = try XCTUnwrap(MetadataCaptureDate(metadataText: "9999:12:31 23:59:59"))
        XCTAssertEqual(latest.year, 9999)
        XCTAssertEqual(latest.month, 12)
        XCTAssertEqual(latest.day, 31)
        XCTAssertEqual(latest.hour, 23)
        XCTAssertEqual(latest.minute, 59)
        XCTAssertEqual(latest.second, 59)
        XCTAssertEqual(latest.metadataText, "9999:12:31 23:59:59")
    }

    func testMetadataTextZeroPadsEveryComponent() throws {
        let date = try XCTUnwrap(value(5, 3, 7, 0, 9, 41))
        XCTAssertEqual(date.metadataText, "0005:03:07 00:09:41")
    }

    func testRejectsMalformedText() {
        let malformed = [
            "",                                  // empty
            "2024:02:29 12:34:5",                // partial
            "2024:2:29 12:34:56",                // unpadded month
            "2024:02:29 12:34:567",              // trailing garbage
            "2024:02:29 12:34:56.5",             // fractional second
            "2024:02:29T12:34:56",               // ISO T separator
            "2024:02:29 12:34:56Z",              // time zone suffix
            "2024:02:29 12:34:56+01:00",         // time zone offset
            "2024-02-29 12:34:56",               // wrong separators
            "2024:02:29-12:34:56",               // wrong date/time separator
            "1234567890123456789",               // digits everywhere, no separators
            "0000:00:00 00:00:00",               // unknown-zero date
            "2024:00:01 00:00:00",               // unknown-zero month
            "2024:02:00 00:00:00",               // unknown-zero day
            "0000:01:01 00:00:00",               // year zero
            "10000:01:01 00:00:00",              // five-digit year
            "2024:02:29 24:00:00",               // hour 24
            "2024:02:29 12:60:00",               // minute 60
            "2024:02:29 12:34:60",               // second 60
            " 2024:02:29 12:34:56",              // leading whitespace
            "2024:02:29 12:34:56 ",              // trailing whitespace
            "\n2024:02:29 12:34:56",             // leading newline
            "2024:02:29 12:34:56\n",             // trailing newline
            "2024:02:2\u{0} 12:34:56",           // NUL replacing a digit
            "2024:02:29 12:34:56\u{0}",          // appended NUL
            "+024:02:29 12:34:56",               // signed year
            "-024:02:29 12:34:56",               // negated year
        ]
        for text in malformed {
            XCTAssertNil(MetadataCaptureDate(metadataText: text), "accepted \(text.debugDescription)")
        }
    }

    func testRejectsNonASCIIAndNonDecimalBytes() {
        let nonASCII = [
            "\u{FF12}024:02:29 12:34:56",             // fullwidth digit
            "\u{660}\u{660}\u{660}\u{660}:02:29 12:34:56",  // Arabic-Indic digits
            "2024\u{FE55}02:29 12:34:56",             // small form colon separator
            "2024:02:29\u{A0}12:34:56",               // no-break space separator
            "2024:02:\u{E9} 12:34:56",                // 19 bytes, non-ASCII masquerade
        ]
        for text in nonASCII {
            XCTAssertNil(MetadataCaptureDate(metadataText: text), "accepted \(text.debugDescription)")
        }
    }

    func testMasqueradeExampleIsNineteenBytesAndRejected() {
        let masquerade = "2024:02:\u{E9} 12:34:56"
        XCTAssertEqual(masquerade.utf8.count, 19)
        XCTAssertNil(MetadataCaptureDate(metadataText: masquerade))
    }
}
