import Foundation
import XCTest
@testable import GlimsKit

final class InkBrushCoverageTests: XCTestCase {
    func testPaperFullInkAndNeutralCoverage() throws {
        XCTAssertEqual(try XCTUnwrap(InkBrushCoverage.percent(red: 1, green: 1, blue: 1)), 0, accuracy: 1e-12)
        XCTAssertEqual(InkBrushCoverage.percent(red: 0, green: 0, blue: 0), 100)
        XCTAssertEqual(InkBrushCoverage.percent(red: 0.5, green: 0.5, blue: 0.5), 50)
        XCTAssertEqual(InkBrushCoverage.intensity(forPercent: 0), 1)
        XCTAssertEqual(InkBrushCoverage.intensity(forPercent: 100), 0)
        XCTAssertEqual(InkBrushCoverage.intensity(forPercent: 37.5), 0.625)
    }

    func testColoredForegroundUsesDisplayRGBLumaWithoutLinearization() throws {
        XCTAssertEqual(try XCTUnwrap(InkBrushCoverage.percent(red: 1, green: 0, blue: 0)), 78.74, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(InkBrushCoverage.percent(red: 0, green: 1, blue: 0)), 28.48, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(InkBrushCoverage.percent(red: 0, green: 0, blue: 1)), 92.78, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(InkBrushCoverage.percent(red: 0.2, green: 0.4, blue: 0.8)), 61.364, accuracy: 1e-12)
    }

    func testInvalidComponentsAndPercentagesAreRefused() {
        for invalid in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            XCTAssertNil(InkBrushCoverage.percent(red: invalid, green: 0.5, blue: 0.5))
            XCTAssertNil(InkBrushCoverage.percent(red: 0.5, green: invalid, blue: 0.5))
            XCTAssertNil(InkBrushCoverage.percent(red: 0.5, green: 0.5, blue: invalid))
        }
        for invalid in [Double.nan, .infinity, -.infinity, -0.01, 100.01] {
            XCTAssertNil(InkBrushCoverage.intensity(forPercent: invalid))
        }
    }

    func testCommitParserValidatesWholeLocaleAwareDraft() {
        let english = Locale(identifier: "en_US_POSIX")
        let french = Locale(identifier: "fr_FR")
        XCTAssertEqual(InkBrushCoverage.parsePercent(" 37.5% ", locale: english), 37.5)
        XCTAssertEqual(InkBrushCoverage.parsePercent("37,5", locale: french), 37.5)
        for text in ["", " ", "-1", "100.001", "nan", "inf", "12junk", "1e309"] {
            XCTAssertNil(InkBrushCoverage.parsePercent(text, locale: english), text)
        }
    }
}
