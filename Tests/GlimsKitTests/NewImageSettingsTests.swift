import XCTest
@testable import GlimsKit

final class NewImageSettingsTests: XCTestCase {
    func testPixelDimensionsAreStrictPositiveIntegers() {
        XCTAssertEqual(NewImageSettings(width: " 1920 ", height: "1080")?.width, 1920)
        for invalid in ["", "0", "-1", "1.5", "1e3", "nan", "9999999999999999999999", "524289"] {
            XCTAssertNil(NewImageSettings(width: invalid, height: "100"), invalid)
            XCTAssertNil(NewImageSettings(width: "100", height: invalid), invalid)
        }
    }

    func testEngineDimensionBoundary() {
        XCTAssertEqual(NewImageSettings(width: "524288", height: "1")?.height, 1)
    }
}
