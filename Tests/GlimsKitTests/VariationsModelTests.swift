import XCTest
@testable import GlimsKit

/// The pure Variations accumulator: one click adds one step to the chosen
/// range (or to the whole tonal range for Lighter/Darker), values clamp at
/// ±1, Original resets to identity, and the step table drives everything.
final class VariationsModelTests: XCTestCase {
    private typealias Model = VariationsModel
    private typealias Settings = EngineSession.VariationsSettings
    private typealias Range = EngineSession.ColorBalanceSettings.Range

    func testStepTableAndDefault() {
        XCTAssertEqual(Model.steps, [0.02, 0.03, 0.05, 0.08, 0.12, 0.18, 0.25])
        XCTAssertEqual(Model.defaultStepIndex, 3)
        let model = Model()
        XCTAssertEqual(model.stepIndex, 3)
        XCTAssertEqual(model.step, 0.08)
        XCTAssertTrue(model.isIdentity)
        XCTAssertTrue(Settings().isIdentity)
    }

    func testColorMappingPerDirection() {
        let expected: [(Model.Direction, WritableKeyPath<Range, Double>, Double)] = [
            (.moreRed, \.cyanRed, 0.08),
            (.moreCyan, \.cyanRed, -0.08),
            (.moreGreen, \.magentaGreen, 0.08),
            (.moreMagenta, \.magentaGreen, -0.08),
            (.moreBlue, \.yellowBlue, 0.08),
            (.moreYellow, \.yellowBlue, -0.08),
        ]
        for (direction, keyPath, amount) in expected {
            var model = Model()
            model.range = .shadows
            model.apply(direction)
            XCTAssertEqual(model.settings.shadows[keyPath: keyPath], amount, direction.rawValue)
            XCTAssertEqual(model.settings.midtones[keyPath: keyPath], 0, direction.rawValue)
            XCTAssertEqual(model.settings.highlights[keyPath: keyPath], 0, direction.rawValue)

            model = Model()
            model.range = .highlights
            let candidate = model.settings(afterClick: direction)
            XCTAssertEqual(candidate.highlights[keyPath: keyPath], amount, direction.rawValue)
            XCTAssertTrue(model.isIdentity, "settings(afterClick:) must not mutate")
        }
    }

    func testLighterDarkerAffectLightnessOnly() {
        var model = Model()
        model.range = .shadows
        model.apply(.lighter)
        model.apply(.darker)
        model.apply(.darker)
        XCTAssertEqual(model.settings.lightness, -0.08)
        XCTAssertEqual(model.settings.saturation, 0)
        XCTAssertTrue(model.settings.shadows == Range())
        XCTAssertTrue(model.settings.highlights == Range())
    }

    func testSaturationDirections() {
        var model = Model()
        model.mode = .saturation
        model.apply(.lessSaturation)
        model.apply(.moreSaturation)
        model.apply(.moreSaturation)
        XCTAssertEqual(model.settings.saturation, 0.08)
        XCTAssertEqual(model.settings.lightness, 0)
        XCTAssertTrue(model.settings.shadows == Range())
    }

    func testAccumulationAndClamping() {
        var model = Model()
        model.stepIndex = 6 // 0.25
        for _ in 0..<5 { model.apply(.moreRed) }
        XCTAssertEqual(model.settings.midtones.cyanRed, 1)
        for _ in 0..<10 { model.apply(.moreCyan) }
        XCTAssertEqual(model.settings.midtones.cyanRed, -1)
        for _ in 0..<5 { model.apply(.lighter) }
        XCTAssertEqual(model.settings.lightness, 1)
        for _ in 0..<10 { model.apply(.darker) }
        XCTAssertEqual(model.settings.lightness, -1)
        XCTAssertEqual(model.settings.saturation, 0)
    }

    func testOriginalResetKeepsControls() {
        var model = Model()
        model.range = .highlights
        model.mode = .saturation
        model.stepIndex = 5
        model.apply(.moreRed)
        model.apply(.moreSaturation)
        model.reset()
        XCTAssertTrue(model.isIdentity)
        XCTAssertEqual(model.range, .highlights)
        XCTAssertEqual(model.mode, .saturation)
        XCTAssertEqual(model.stepIndex, 5)
        XCTAssertTrue(model.settings.isValid)
    }

    func testInvalidValuesAreRejectedByTheFacadeSettingsType() {
        var settings = Settings()
        settings.lightness = 1.5
        XCTAssertFalse(settings.isValid)
        XCTAssertFalse(settings.isIdentity)
        settings = Settings(saturation: .nan)
        XCTAssertFalse(settings.isValid)
        XCTAssertFalse(settings.isIdentity)
    }

    func testSettingsRoundTripThroughCodable() throws {
        var settings = Settings()
        settings.shadows = Range(cyanRed: 0.25, magentaGreen: -0.5, yellowBlue: 1)
        settings.highlights = Range(cyanRed: -1, magentaGreen: 0.125, yellowBlue: 0)
        settings.lightness = 0.4
        settings.saturation = -0.6
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data), settings)
    }
}
