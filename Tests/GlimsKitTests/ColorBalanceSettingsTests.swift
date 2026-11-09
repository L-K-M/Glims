import XCTest
@testable import GlimsKit

@MainActor
final class ColorBalanceSettingsTests: XCTestCase {
    private typealias Settings = EngineSession.ColorBalanceSettings
    private typealias Range = EngineSession.ColorBalanceSettings.Range

    private let corrections: [(String, WritableKeyPath<Settings, Double>)] = [
        ("shadows.cyanRed", \.shadows.cyanRed),
        ("shadows.magentaGreen", \.shadows.magentaGreen),
        ("shadows.yellowBlue", \.shadows.yellowBlue),
        ("midtones.cyanRed", \.midtones.cyanRed),
        ("midtones.magentaGreen", \.midtones.magentaGreen),
        ("midtones.yellowBlue", \.midtones.yellowBlue),
        ("highlights.cyanRed", \.highlights.cyanRed),
        ("highlights.magentaGreen", \.highlights.magentaGreen),
        ("highlights.yellowBlue", \.highlights.yellowBlue),
    ]

    private func operation(_ name: String, title: String = "Test",
                           support: EngineSession.FilterOpSupport) -> EngineSession.FilterOperation {
        EngineSession.FilterOperation(name: name, title: title, categories: [], blurb: "", support: support)
    }

    func testDefaultWholeValueContract() {
        let value = Settings()
        let zero = Range(cyanRed: 0, magentaGreen: 0, yellowBlue: 0)
        XCTAssertEqual(value.shadows, zero)
        XCTAssertEqual(value.midtones, zero)
        XCTAssertEqual(value.highlights, zero)
        XCTAssertTrue(value.preserveLuminosity)
        XCTAssertTrue(value.isValid)
    }

    func testEachCorrectionIndependentlyAcceptsBoundsAndFiniteFraction() {
        for (name, keyPath) in corrections {
            for accepted in [-1.0, 1.0, 0.375] {
                var value = Settings()
                value[keyPath: keyPath] = accepted
                XCTAssertTrue(value.isValid, "\(name) should accept \(accepted)")
                XCTAssertEqual(value[keyPath: keyPath], accepted, name)
            }
        }
    }

    func testEachCorrectionIndependentlyRejectsInvalidValues() {
        let rejected = [Double.nan, .infinity, -.infinity, -1.000001, 1.000001]
        for (name, keyPath) in corrections {
            for invalid in rejected {
                var value = Settings()
                value[keyPath: keyPath] = invalid
                XCTAssertFalse(value.isValid, "\(name) should reject \(invalid)")
            }
        }
    }

    func testRangesRetainIndependentTriplesAndPreserveFlagDoesNotInvalidate() {
        let shadows = Range(cyanRed: -1, magentaGreen: -0.25, yellowBlue: 0.5)
        let midtones = Range(cyanRed: 0.125, magentaGreen: 1, yellowBlue: -0.75)
        let highlights = Range(cyanRed: 0.9, magentaGreen: -0.4, yellowBlue: 0.01)
        let value = Settings(shadows: shadows, midtones: midtones, highlights: highlights,
                             preserveLuminosity: false)
        XCTAssertEqual(value.shadows, shadows)
        XCTAssertEqual(value.midtones, midtones)
        XCTAssertEqual(value.highlights, highlights)
        XCTAssertFalse(value.preserveLuminosity)
        XCTAssertTrue(value.isValid)
    }

    func testUsesColorBalanceEditorOnlyForExactNameAndNeedsConfig() {
        let exact = operation("gimp:color-balance", support: .needsConfig)
        XCTAssertTrue(NativeFilterMenuLayout.usesColorBalanceEditor(exact))
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(exact))
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(exact), "Test…")

        let supported = operation("gimp:color-balance", support: .supported)
        XCTAssertFalse(NativeFilterMenuLayout.usesColorBalanceEditor(supported),
                       ".supported may use generic support but must not match the special editor")
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(supported))

        let auxiliary = operation("gimp:color-balance", support: .needsAuxInput)
        XCTAssertFalse(NativeFilterMenuLayout.usesColorBalanceEditor(auxiliary))
        XCTAssertFalse(NativeFilterMenuLayout.supportsParameterEditor(auxiliary))
    }

    func testNearNamesAndUnrelatedConfigOperationsAreNotSpecialEditors() {
        let nearOrUnrelated: [(String, String)] = [
            ("gimp:color-balance-legacy", "near name"),
            ("gegl:color-balance", "GEGL alias/namespace mismatch"),
            ("GIMP:COLOR-BALANCE", "case mismatch"),
            ("gimp:future-config", "unrelated config"),
        ]
        for (name, label) in nearOrUnrelated {
            let value = operation(name, support: .needsConfig)
            XCTAssertFalse(NativeFilterMenuLayout.usesColorBalanceEditor(value), label)
            XCTAssertFalse(NativeFilterMenuLayout.supportsParameterEditor(value), label)
            XCTAssertEqual(value.support, .needsConfig, "\(label): .needsConfig must remain recognized")
            XCTAssertEqual(NativeFilterMenuLayout.itemTitle(value), "Test (needs a dedicated editor)", label)
        }

        let brightnessContrast = operation("gimp:brightness-contrast", support: .needsConfig)
        XCTAssertFalse(NativeFilterMenuLayout.usesColorBalanceEditor(brightnessContrast))
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(brightnessContrast),
                      "existing brightness/contrast remains supported via its own policy")

        let hueSaturation = operation("gimp:hue-saturation", support: .needsConfig)
        XCTAssertFalse(NativeFilterMenuLayout.usesColorBalanceEditor(hueSaturation))
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(hueSaturation))

        let levels = operation("gimp:levels", support: .needsConfig)
        XCTAssertFalse(NativeFilterMenuLayout.usesColorBalanceEditor(levels))
        XCTAssertTrue(NativeFilterMenuLayout.usesLevelsEditor(levels))
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(levels))
        XCTAssertFalse(NativeFilterMenuLayout.supportsParameterEditor(nil))
    }
}
