import XCTest
@testable import GlimsKit

@MainActor
final class LevelsSettingsTests: XCTestCase {
    private typealias Settings = EngineSession.LevelsSettings
    private typealias Channel = EngineSession.LevelsSettings.Channel
    private let channels: [(String, WritableKeyPath<Settings, Channel>)] = [
        ("value", \.value), ("red", \.red), ("green", \.green),
        ("blue", \.blue), ("alpha", \.alpha),
    ]
    private let endpoints: [(String, WritableKeyPath<Channel, Double>)] = [
        ("lowInput", \.lowInput), ("highInput", \.highInput),
        ("lowOutput", \.lowOutput), ("highOutput", \.highOutput),
    ]

    func testDefaultsUseIdentityChannelsAndExplicitLinearTransferCurve() {
        let settings = Settings()
        let identity = Channel(lowInput: 0, highInput: 1, gamma: 1, lowOutput: 0, highOutput: 1)
        XCTAssertEqual(settings.trc, .linear)
        XCTAssertFalse(settings.clampInput)
        XCTAssertFalse(settings.clampOutput)
        XCTAssertEqual(settings.value, identity)
        XCTAssertEqual(settings.red, identity)
        XCTAssertEqual(settings.green, identity)
        XCTAssertEqual(settings.blue, identity)
        XCTAssertEqual(settings.alpha, identity)
        XCTAssertTrue(settings.isValid)
    }

    func testEveryEndpointIndependentlyAcceptsBoundsAndFiniteFractions() {
        for (channelName, channelKey) in channels {
            for (fieldName, fieldKey) in endpoints {
                for accepted in [0.0, 1.0, 0.375] {
                    var settings = Settings()
                    settings[keyPath: channelKey][keyPath: fieldKey] = accepted
                    XCTAssertTrue(settings.isValid, "\(channelName).\(fieldName) accepts \(accepted)")
                    XCTAssertEqual(settings[keyPath: channelKey][keyPath: fieldKey], accepted)
                }
            }
        }
    }

    func testEveryEndpointIndependentlyRejectsNonfiniteOrOutOfDomainValues() {
        let rejected = [Double.nan, .infinity, -.infinity, -0.000001, 1.000001]
        for (channelName, channelKey) in channels {
            for (fieldName, fieldKey) in endpoints {
                for invalid in rejected {
                    var settings = Settings()
                    settings[keyPath: channelKey][keyPath: fieldKey] = invalid
                    XCTAssertFalse(settings.isValid, "\(channelName).\(fieldName) rejects \(invalid)")
                }
            }
        }
    }

    func testGammaHasItsOwnPositiveDomainInEveryChannel() {
        for (name, key) in channels {
            for accepted in [0.1, 10.0, 1.25] {
                var settings = Settings()
                settings[keyPath: key].gamma = accepted
                XCTAssertTrue(settings.isValid, "\(name).gamma accepts \(accepted)")
                XCTAssertEqual(settings[keyPath: key].gamma, accepted)
            }
            for invalid in [Double.nan, .infinity, -.infinity, 0, 0.099999, 10.000001] {
                var settings = Settings()
                settings[keyPath: key].gamma = invalid
                XCTAssertFalse(settings.isValid, "\(name).gamma rejects \(invalid)")
            }
        }
    }

    func testOnlyKnownTransferCurvesAreValidAndClampFlagsAreIndependent() {
        for trc in [EngineSession.ColorTRC.linear, .nonlinear, .perceptual] {
            for input in [false, true] {
                for output in [false, true] {
                    let settings = Settings(trc: trc, clampInput: input, clampOutput: output)
                    XCTAssertTrue(settings.isValid)
                    XCTAssertEqual(settings.trc, trc)
                    XCTAssertEqual(settings.clampInput, input)
                    XCTAssertEqual(settings.clampOutput, output)
                }
            }
        }
        XCTAssertFalse(Settings(trc: .unknown).isValid)
    }

    func testEqualAndInvertedEndpointPairsRemainValidWithoutSorting() {
        let equal = Channel(lowInput: 0.5, highInput: 0.5, gamma: 0.1, lowOutput: 0.25, highOutput: 0.25)
        let inverted = Channel(lowInput: 1, highInput: 0, gamma: 10, lowOutput: 1, highOutput: 0)
        for (name, key) in channels {
            for mapping in [equal, inverted] {
                var settings = Settings()
                settings[keyPath: key] = mapping
                XCTAssertTrue(settings.isValid, "\(name) supports equal and inverted mappings")
                XCTAssertEqual(settings[keyPath: key], mapping)
            }
        }
    }

    func testDistinctChannelsRetainAllTwentyFiveValues() {
        let value = Channel(lowInput: 0.1, highInput: 0.9, gamma: 1.25, lowOutput: 0.2, highOutput: 0.8)
        let red = Channel(lowInput: 0.2, highInput: 0.8, gamma: 2, lowOutput: 0.3, highOutput: 0.7)
        let green = Channel(lowInput: 0.3, highInput: 0.7, gamma: 3, lowOutput: 0.4, highOutput: 0.6)
        let blue = Channel(lowInput: 0.4, highInput: 0.6, gamma: 4, lowOutput: 0.5, highOutput: 0.55)
        let alpha = Channel(lowInput: 0.5, highInput: 0.55, gamma: 5, lowOutput: 0.6, highOutput: 0.4)
        let settings = Settings(trc: .perceptual, clampInput: true, clampOutput: false,
                                value: value, red: red, green: green, blue: blue, alpha: alpha)
        XCTAssertEqual(settings.value, value)
        XCTAssertEqual(settings.red, red)
        XCTAssertEqual(settings.green, green)
        XCTAssertEqual(settings.blue, blue)
        XCTAssertEqual(settings.alpha, alpha)
        XCTAssertEqual(settings.trc, .perceptual)
        XCTAssertTrue(settings.clampInput)
        XCTAssertFalse(settings.clampOutput)
        XCTAssertTrue(settings.isValid)
    }

    private func operation(_ name: String, support: EngineSession.FilterOpSupport) -> EngineSession.FilterOperation {
        .init(name: name, title: "Test", categories: [], blurb: "", support: support)
    }

    func testDedicatedLevelsEditorRequiresExactNameAndConfigSupport() {
        let exact = operation("gimp:levels", support: .needsConfig)
        XCTAssertTrue(NativeFilterMenuLayout.usesLevelsEditor(exact))
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(exact))
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(exact), "Test…")
        let generic = operation("gimp:levels", support: .supported)
        XCTAssertFalse(NativeFilterMenuLayout.usesLevelsEditor(generic))
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(generic))
        let auxiliary = operation("gimp:levels", support: .needsAuxInput)
        XCTAssertFalse(NativeFilterMenuLayout.usesLevelsEditor(auxiliary))
        XCTAssertFalse(NativeFilterMenuLayout.supportsParameterEditor(auxiliary))
        for name in ["gegl:levels", "GIMP:LEVELS", "gimp:levels-legacy", "gimp:curves"] {
            let unrelated = operation(name, support: .needsConfig)
            XCTAssertFalse(NativeFilterMenuLayout.usesLevelsEditor(unrelated), name)
            XCTAssertFalse(NativeFilterMenuLayout.supportsParameterEditor(unrelated), name)
        }
        for name in ["gimp:brightness-contrast", "gimp:color-balance", "gimp:hue-saturation"] {
            let existing = operation(name, support: .needsConfig)
            XCTAssertFalse(NativeFilterMenuLayout.usesLevelsEditor(existing), name)
            XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(existing), name)
        }
    }
}
