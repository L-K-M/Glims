import XCTest
@testable import GlimsKit

@MainActor
final class HueSaturationSettingsTests: XCTestCase {
    private typealias Settings = EngineSession.HueSaturationSettings
    private typealias Range = EngineSession.HueSaturationSettings.Range

    private let rangeTriples: [(String, WritableKeyPath<Settings, Range>)] = [
        ("master", \.master), ("red", \.red), ("yellow", \.yellow),
        ("green", \.green), ("cyan", \.cyan), ("blue", \.blue), ("magenta", \.magenta),
    ]

    private let rangeFields: [(String, WritableKeyPath<Range, Double>)] = [
        ("hue", \.hue), ("saturation", \.saturation), ("lightness", \.lightness),
    ]

    private func operation(_ name: String, title: String = "Test",
                           support: EngineSession.FilterOpSupport) -> EngineSession.FilterOperation {
        EngineSession.FilterOperation(name: name, title: title, categories: [], blurb: "", support: support)
    }

    func testDefaultsAllRangesZeroOverlapZeroAndValid() {
        let value = Settings()
        let zero = Range(hue: 0, saturation: 0, lightness: 0)
        XCTAssertEqual(value.overlap, 0)
        XCTAssertEqual(value.master, zero)
        XCTAssertEqual(value.red, zero)
        XCTAssertEqual(value.yellow, zero)
        XCTAssertEqual(value.green, zero)
        XCTAssertEqual(value.cyan, zero)
        XCTAssertEqual(value.blue, zero)
        XCTAssertEqual(value.magenta, zero)
        XCTAssertTrue(value.isValid)
    }

    func testAllTwentyOneRangeFieldsIndependentlyAcceptBoundsAndFiniteFraction() {
        for (rangeName, rangeKey) in rangeTriples {
            for (fieldName, fieldKey) in rangeFields {
                for accepted in [-1.0, 1.0, 0.375] {
                    var value = Settings()
                    value[keyPath: rangeKey][keyPath: fieldKey] = accepted
                    XCTAssertTrue(value.isValid, "\(rangeName).\(fieldName) should accept \(accepted)")
                    XCTAssertEqual(value[keyPath: rangeKey][keyPath: fieldKey], accepted)
                }
            }
        }
    }

    func testAllTwentyOneRangeFieldsIndependentlyRejectInvalidValues() {
        let rejected = [Double.nan, .infinity, -.infinity, -1.000001, 1.000001]
        for (rangeName, rangeKey) in rangeTriples {
            for (fieldName, fieldKey) in rangeFields {
                for invalid in rejected {
                    var value = Settings()
                    value[keyPath: rangeKey][keyPath: fieldKey] = invalid
                    XCTAssertFalse(value.isValid, "\(rangeName).\(fieldName) should reject \(invalid)")
                }
            }
        }
    }

    func testOverlapAcceptsBoundsAndFiniteFractionRejectsInvalidValues() {
        for accepted in [0.0, 0.5, 1.0] {
            var value = Settings()
            value.overlap = accepted
            XCTAssertTrue(value.isValid, "overlap should accept \(accepted)")
            XCTAssertEqual(value.overlap, accepted)
        }
        for invalid in [-0.000001, 1.000001, .nan, .infinity, -.infinity] {
            var value = Settings()
            value.overlap = invalid
            XCTAssertFalse(value.isValid, "overlap should reject \(invalid)")
        }
    }

    func testMasterAndLocalIndividuallyOneRemainValidWithoutSumClamp() {
        var master = Settings()
        master.master = .init(hue: 1, saturation: 1, lightness: 1)
        XCTAssertTrue(master.isValid)
        XCTAssertEqual(master.master, .init(hue: 1, saturation: 1, lightness: 1))
        XCTAssertEqual(master.red, .init(hue: 0, saturation: 0, lightness: 0))

        var local = Settings()
        local.red = .init(hue: 1, saturation: 1, lightness: 1)
        XCTAssertTrue(local.isValid)
        XCTAssertEqual(local.red, .init(hue: 1, saturation: 1, lightness: 1))
        XCTAssertEqual(local.master, .init(hue: 0, saturation: 0, lightness: 0))

        let both = Settings(overlap: 1, master: .init(hue: 1, saturation: 1, lightness: 1),
                            red: .init(hue: 1, saturation: 1, lightness: 1))
        XCTAssertTrue(both.isValid, "master and local at +1 must remain valid without sum clamp")
    }

    func testDistinctRangeTriplesAndOverlapRetainedIndependently() {
        let master = Range(hue: -1, saturation: -0.25, lightness: 0.5)
        let red = Range(hue: 0.125, saturation: 1, lightness: -0.75)
        let yellow = Range(hue: 0.9, saturation: -0.4, lightness: 0.01)
        let green = Range(hue: -0.5, saturation: 0.6, lightness: 1)
        let cyan = Range(hue: 1, saturation: -1, lightness: -0.125)
        let blue = Range(hue: 0.33, saturation: 0.44, lightness: -0.55)
        let magenta = Range(hue: -0.66, saturation: 0.77, lightness: 0.88)
        let value = Settings(overlap: 0.625, master: master, red: red, yellow: yellow,
                             green: green, cyan: cyan, blue: blue, magenta: magenta)
        XCTAssertEqual(value.overlap, 0.625)
        XCTAssertEqual(value.master, master)
        XCTAssertEqual(value.red, red)
        XCTAssertEqual(value.yellow, yellow)
        XCTAssertEqual(value.green, green)
        XCTAssertEqual(value.cyan, cyan)
        XCTAssertEqual(value.blue, blue)
        XCTAssertEqual(value.magenta, magenta)
        XCTAssertTrue(value.isValid)
    }

    func testUsesHueSaturationEditorOnlyForExactNameAndNeedsConfig() {
        let exact = operation("gimp:hue-saturation", support: .needsConfig)
        XCTAssertTrue(NativeFilterMenuLayout.usesHueSaturationEditor(exact))
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(exact))
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(exact), "Test…")

        let supported = operation("gimp:hue-saturation", support: .supported)
        XCTAssertFalse(NativeFilterMenuLayout.usesHueSaturationEditor(supported))
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(supported),
                      ".supported may have generic support but must not match the special editor")
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(supported), "Test…")

        let aux = operation("gimp:hue-saturation", support: .needsAuxInput)
        XCTAssertFalse(NativeFilterMenuLayout.usesHueSaturationEditor(aux))
        XCTAssertFalse(NativeFilterMenuLayout.supportsParameterEditor(aux))
    }

    func testNearNamesWrongNamespaceCaseAndUnrelatedOperationsAreNotSpecial() {
        let nearOrUnrelated: [(String, String, EngineSession.FilterOpSupport)] = [
            ("gimp:hue-saturation-legacy", "near name", .needsConfig),
            ("gegl:hue-saturation", "GEGL namespace", .needsConfig),
            ("GIMP:HUE-SATURATION", "case mismatch", .needsConfig),
            ("gimp:curves", "curves unsupported", .needsConfig),
            ("gimp:levels", "levels unsupported", .needsConfig),
            ("gimp:color-balance", "other special editor", .needsConfig),
            ("gimp:brightness-contrast", "other special editor", .needsConfig),
        ]
        for (name, label, support) in nearOrUnrelated {
            let value = operation(name, support: support)
            XCTAssertFalse(NativeFilterMenuLayout.usesHueSaturationEditor(value), label)
            if name == "gimp:color-balance" {
                XCTAssertTrue(NativeFilterMenuLayout.usesColorBalanceEditor(value), label)
                XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(value), label)
            } else if name == "gimp:brightness-contrast" {
                XCTAssertTrue(NativeFilterMenuLayout.usesBrightnessContrastEditor(value), label)
                XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(value), label)
            } else {
                XCTAssertFalse(NativeFilterMenuLayout.supportsParameterEditor(value), label)
            }
            if support == .needsConfig && name != "gimp:color-balance" && name != "gimp:brightness-contrast" {
                XCTAssertEqual(NativeFilterMenuLayout.itemTitle(value), "Test (needs a dedicated editor)", label)
            }
        }
    }
}
