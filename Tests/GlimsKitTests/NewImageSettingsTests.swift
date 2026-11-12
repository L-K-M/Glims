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

    func testLegacyInitDefaultsToRGB() {
        let settings = NewImageSettings(width: "100", height: "50")
        XCTAssertEqual(settings?.kind, .rgb)
        XCTAssertEqual(settings?.component, .u8)
        XCTAssertEqual(settings?.channelCount, 4)
    }

    func testMultichannelAllowedPrecisionsAndKind() {
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let settings = NewImageSettings(width: "10", height: "10", kind: .multichannel,
                                            component: component)
            XCTAssertEqual(settings?.kind, .multichannel)
            XCTAssertEqual(settings?.component, component)
            XCTAssertEqual(settings?.channelCount, 4)
        }
    }

    func testMultichannelCountBoundaries() {
        XCTAssertEqual(NewImageSettings(width: "10", height: "10", kind: .multichannel,
                                        channelCount: "1")?.channelCount, 1)
        XCTAssertEqual(NewImageSettings(width: "10", height: "10", kind: .multichannel,
                                        channelCount: " 32 ")?.channelCount, 32)
        for invalid in ["", "0", "33", "-1", "1.5", "4e0", "abc", "9999999999999999999999"] {
            XCTAssertNil(NewImageSettings(width: "10", height: "10", kind: .multichannel,
                                          channelCount: invalid), invalid)
        }
    }

    func testMultichannelRejectsUnsupportedPrecisions() {
        for component in [EngineSession.ColorComponent.u32, .half, .double, .unknown] {
            XCTAssertNil(NewImageSettings(width: "10", height: "10", kind: .multichannel,
                                          component: component), "\(component)")
        }
    }

    func testRGBIgnoresDormantMultichannelFields() {
        let settings = NewImageSettings(width: "10", height: "10", kind: .rgb,
                                        component: .double, channelCount: "bogus")
        XCTAssertEqual(settings?.kind, .rgb)
        XCTAssertEqual(settings?.component, .u8)
        XCTAssertEqual(settings?.channelCount, 4)
    }
}
