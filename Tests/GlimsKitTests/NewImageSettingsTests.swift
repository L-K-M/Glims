import XCTest
import AppKit
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

    @MainActor
    func testCmykRequiresSourceProfileAndFixesPlaneCount() throws {
        let icc = try XCTUnwrap(NSColorSpace.genericCMYK.iccProfileData)
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let settings = try XCTUnwrap(NewImageSettings(width: "31", height: "23", kind: .cmyk,
                component: component, channelCount: "not applicable", profileICC: icc))
            XCTAssertEqual(settings.kind, .cmyk)
            XCTAssertEqual(settings.component, component)
            XCTAssertEqual(settings.channelCount, 4)
            XCTAssertEqual(settings.profileICC, icc)
        }
        XCTAssertNil(NewImageSettings(width: "31", height: "23", kind: .cmyk))
        XCTAssertNil(NewImageSettings(width: "31", height: "23", kind: .cmyk, profileICC: Data([0])))
        let rgb = try XCTUnwrap(NSColorSpace.sRGB.iccProfileData)
        XCTAssertNil(NewImageSettings(width: "31", height: "23", kind: .cmyk, profileICC: rgb))
        XCTAssertNil(NewImageSettings(width: "31", height: "23", kind: .cmyk, component: .double, profileICC: icc))
        XCTAssertNil(NewImageSettings(width: "0", height: "23", kind: .cmyk, profileICC: icc))
    }

    func testOtherModesIgnoreDormantCmykProfile() {
        for kind in [NewImageSettings.Kind.rgb, .multichannel, .lab] {
            let settings = NewImageSettings(width: "12", height: "13", kind: kind, profileICC: Data([0]))
            XCTAssertNotNil(settings)
            XCTAssertNil(settings?.profileICC)
        }
    }

    func testInkEditingAdmissionIncludesCmyk() {
        XCTAssertTrue(EngineSession.ColorMode.cmyk.usesInkChannels)
        XCTAssertTrue(EngineSession.ColorMode.multichannel.usesInkChannels)
        XCTAssertFalse(EngineSession.ColorMode.rgb.usesInkChannels)
        for tool in ToolID.allCases {
            XCTAssertEqual(tool.isAvailable(in: .cmyk), tool.isAvailable(in: .multichannel))
        }
    }

    func testLabAllPrecisionsFixedCountNoICC() {
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let settings = NewImageSettings(width: "64", height: "48", kind: .lab,
                                            component: component, channelCount: "1", profileICC: Data([0]))
            XCTAssertEqual(settings?.kind, .lab)
            XCTAssertEqual(settings?.component, component)
            XCTAssertEqual(settings?.channelCount, 3)
            XCTAssertNil(settings?.profileICC)
        }
    }

    func testLabRejectsInvalidPrecisionsAndDimensions() {
        for component in [EngineSession.ColorComponent.u32, .half, .double, .unknown] {
            XCTAssertNil(NewImageSettings(width: "10", height: "10", kind: .lab, component: component), "\(component)")
        }
        for invalid in ["", "0", "-1", "1.5", "524289"] {
            XCTAssertNil(NewImageSettings(width: invalid, height: "10", kind: .lab), invalid)
            XCTAssertNil(NewImageSettings(width: "10", height: invalid, kind: .lab), invalid)
        }
    }

    func testLabIgnoresDormantMalformedCountAndProfile() {
        let settings = NewImageSettings(width: "10", height: "10", kind: .lab,
                                        channelCount: "bogus", profileICC: Data([1, 2, 3]))
        XCTAssertEqual(settings?.kind, .lab)
        XCTAssertEqual(settings?.component, .u8)
        XCTAssertEqual(settings?.channelCount, 3)
        XCTAssertNil(settings?.profileICC)
    }

    func testKindChoicesExcludeLabByDefaultAndIncludeLabExplicitly() {
        XCTAssertEqual(NewImageSettings.Kind.choices(), [.rgb, .multichannel, .cmyk])
        XCTAssertEqual(NewImageSettings.Kind.choices(supportsLab: false), [.rgb, .multichannel, .cmyk])
        XCTAssertEqual(NewImageSettings.Kind.choices(supportsLab: true), [.rgb, .multichannel, .cmyk, .lab])
        XCTAssertEqual(NewImageSettings.Kind.choices(supportsLab: true).map(\.title),
                       ["RGB", "Multichannel", "CMYK", "Lab (D50)"])
    }

    func testKindMappingRefusesInvalidIndexWithoutFallback() {
        XCTAssertEqual(NewImageSettings.Kind.kind(at: 0, supportsLab: false), .rgb)
        XCTAssertEqual(NewImageSettings.Kind.kind(at: 1, supportsLab: false), .multichannel)
        XCTAssertEqual(NewImageSettings.Kind.kind(at: 2, supportsLab: true), .cmyk)
        XCTAssertEqual(NewImageSettings.Kind.kind(at: 3, supportsLab: true), .lab)
        XCTAssertNil(NewImageSettings.Kind.kind(at: 3, supportsLab: false))
        XCTAssertNil(NewImageSettings.Kind.kind(at: -1, supportsLab: true))
        XCTAssertNil(NewImageSettings.Kind.kind(at: 99, supportsLab: false))
    }
}
