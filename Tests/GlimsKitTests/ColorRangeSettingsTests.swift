import XCTest
@testable import GlimsKit

/// Select > Color Range's sample-list rules, factored into
/// `EngineSession.ColorRangeSettings` so the panel and the codec share one
/// validation path.
final class ColorRangeSettingsTests: XCTestCase {
    private typealias Settings = EngineSession.ColorRangeSettings
    private typealias Sample = EngineSession.ColorRangeSettings.Sample

    private func sample(_ red: Double, _ green: Double, _ blue: Double,
                        subtract: Bool = false) -> Sample {
        Sample(red: red, green: green, blue: blue, subtract: subtract)
    }

    func testDefaultSampledColorsNeedsAnAddSample() {
        var value = Settings()
        XCTAssertEqual(value.mode, .sampled)
        XCTAssertEqual(value.fuzziness, 40)
        XCTAssertFalse(value.invert)
        XCTAssertFalse(value.isValid, "Sampled Colors without a sample cannot run")

        value.samples = [sample(0.5, 0.2, 0.1)]
        XCTAssertTrue(value.isValid)

        value.samples = [sample(0.5, 0.2, 0.1), sample(0.1, 0.2, 0.3, subtract: true)]
        XCTAssertTrue(value.isValid, "a subtract sample beside an add is fine")

        value.samples = [sample(0.5, 0.2, 0.1, subtract: true)]
        XCTAssertFalse(value.isValid, "subtract alone selects nothing")
    }

    func testFixedModesTakeNoSamples() {
        for mode in Settings.Mode.allCases where mode != .sampled {
            var value = Settings()
            value.mode = mode
            XCTAssertTrue(value.isValid, "\(mode.title) needs no samples")

            value.samples = [sample(0.5, 0.2, 0.1)]
            XCTAssertFalse(value.isValid, "\(mode.title) cannot carry samples")

            value.samples = []
            XCTAssertEqual(value.engineSettings.samples, [])
        }
    }

    func testFuzzinessBoundsAndFiniteness() {
        var value = Settings()
        value.samples = [sample(0.5, 0.5, 0.5)]

        for accepted in [0.0, 40.0, 200.0] {
            value.fuzziness = accepted
            XCTAssertTrue(value.isValid, "fuzziness \(accepted) should be valid")
        }
        for rejected in [-0.0001, 200.0001, .nan, .infinity, -.infinity] {
            value.fuzziness = rejected
            XCTAssertFalse(value.isValid, "fuzziness \(rejected) should be refused")
        }
    }

    func testSampleCountAndFiniteComponents() {
        var value = Settings()
        value.samples = (0..<64).map { _ in sample(0.5, 0.5, 0.5) }
        XCTAssertTrue(value.isValid, "64 samples are the maximum")

        value.samples.append(sample(0.5, 0.5, 0.5))
        XCTAssertFalse(value.isValid, "65 samples are refused")

        value.samples = [sample(.nan, 0.5, 0.5)]
        XCTAssertFalse(value.isValid, "a NaN component is refused")
        value.samples = [sample(0.5, .infinity, 0.5)]
        XCTAssertFalse(value.isValid, "an infinite component is refused")
    }

    func testComponentsOutsideTheUnitRangeRemainValid() {
        var value = Settings()
        value.samples = [sample(1.02, -0.01, 2.0)]
        XCTAssertTrue(value.isValid, "the kernel clamps components before comparing")
    }

    func testEngineSettingsDropsSamplesForAFixedModeOnly() {
        var value = Settings()
        value.samples = [sample(0.5, 0.2, 0.1), sample(0.1, 0.2, 0.3, subtract: true)]

        var fixedValue = value
        fixedValue.mode = .reds
        XCTAssertEqual(fixedValue.engineSettings.samples, [], "a fixed mode sends none")
        XCTAssertEqual(fixedValue.engineSettings.mode, .reds)
        XCTAssertEqual(fixedValue.samples.count, 2, "the dialog still keeps its samples")

        let sampled = value.engineSettings
        XCTAssertEqual(sampled.samples, value.samples, "Sampled Colors keeps every sample")
    }

    func testModeTitles() {
        XCTAssertEqual(Settings.Mode.allCases.map(\.title), [
            "Sampled Colors", "Reds", "Yellows", "Greens", "Cyans", "Blues",
            "Magentas", "Highlights", "Midtones", "Shadows",
        ])
        XCTAssertEqual(Settings.Mode.sampled.rawValue, 1)
        XCTAssertEqual(Settings.Mode.shadows.rawValue, 10)
    }
}
