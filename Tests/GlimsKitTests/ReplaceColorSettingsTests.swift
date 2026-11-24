import XCTest
@testable import GlimsKit

/// Image > Adjust > Replace Color's sample-list rules and scalar property
/// encoding, factored into `EngineSession.ReplaceColorSettings` so the panel
/// and the Recorder codec share one validation path.
final class ReplaceColorSettingsTests: XCTestCase {
    private typealias Settings = EngineSession.ReplaceColorSettings
    private typealias Sample = EngineSession.ReplaceColorSettings.Sample

    private func sample(_ red: Double, _ green: Double, _ blue: Double,
                        subtract: Bool = false) -> Sample {
        Sample(red: red, green: green, blue: blue, subtract: subtract)
    }

    func testDefaultNeedsAnAddSample() {
        var value = Settings()
        XCTAssertEqual(value.fuzziness, 40)
        XCTAssertEqual(value.hue, 0)
        XCTAssertEqual(value.saturation, 0)
        XCTAssertEqual(value.lightness, 0)
        XCTAssertFalse(value.isValid, "Replace Color without a sample cannot run")

        value.samples = [sample(0.5, 0.2, 0.1)]
        XCTAssertTrue(value.isValid)

        value.samples = [sample(0.5, 0.2, 0.1), sample(0.1, 0.2, 0.3, subtract: true)]
        XCTAssertTrue(value.isValid, "a subtract sample beside an add is fine")

        value.samples = [sample(0.5, 0.2, 0.1, subtract: true)]
        XCTAssertFalse(value.isValid, "subtract alone changes nothing")
    }

    func testBoundsAndFiniteness() {
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
        value.fuzziness = 40

        for accepted in [-180.0, 0.0, 180.0] {
            value.hue = accepted
            XCTAssertTrue(value.isValid, "hue \(accepted) should be valid")
        }
        for rejected in [-180.0001, 180.0001, .nan] {
            value.hue = rejected
            XCTAssertFalse(value.isValid, "hue \(rejected) should be refused")
        }
        value.hue = 0

        for accepted in [-100.0, 100.0] {
            value.saturation = accepted
            value.lightness = accepted
            XCTAssertTrue(value.isValid, "saturation/lightness \(accepted) should be valid")
        }
        for rejected in [-100.0001, 100.0001, .nan] {
            value.saturation = rejected
            XCTAssertFalse(value.isValid, "saturation \(rejected) should be refused")
            value.saturation = 0
            value.lightness = rejected
            XCTAssertFalse(value.isValid, "lightness \(rejected) should be refused")
            value.lightness = 0
        }
    }

    func testSampleCountAndFiniteComponents() {
        var value = Settings()
        value.samples = (0..<8).map { _ in sample(0.5, 0.5, 0.5) }
        XCTAssertTrue(value.isValid, "eight samples are the maximum")
        XCTAssertEqual(Settings.maximumSamples, 8)

        value.samples.append(sample(0.5, 0.5, 0.5))
        XCTAssertFalse(value.isValid, "nine samples are refused")

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

    func testPropertyEncodingRoundTrip() throws {
        var value = Settings()
        value.fuzziness = 75
        value.samples = [sample(1, 0.4, 0.4), sample(0, 1, 0, subtract: true)]
        value.hue = 90
        value.saturation = -30
        value.lightness = 20

        let values = value.propertyValues
        XCTAssertEqual(values.count, 21)
        XCTAssertEqual(values["fuzziness"], .number(75))
        XCTAssertEqual(values["sample-count"], .integer(2))
        XCTAssertEqual(values["subtract-0"], .boolean(false))
        XCTAssertEqual(values["subtract-1"], .boolean(true))
        XCTAssertEqual(values["hue"], .number(90))
        XCTAssertEqual(values["saturation"], .number(-30))
        XCTAssertEqual(values["lightness"], .number(20))
        guard case .color(let first) = values["sample-0"] else {
            return XCTFail("sample-0 should encode as a color")
        }
        let srgb = try XCTUnwrap(first.usingColorSpace(.sRGB))
        XCTAssertEqual(Double(srgb.redComponent), 1, accuracy: 1e-9)
        XCTAssertEqual(Double(srgb.greenComponent), 0.4, accuracy: 1e-9)
        XCTAssertEqual(Double(srgb.blueComponent), 0.4, accuracy: 1e-9)

        let decoded = Settings(values: values)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(decoded.propertyValues, values)
    }

    func testDecodingClampsAnImpossibleSampleCount() {
        var values: [String: EngineSession.FilterValue] = [:]
        values["sample-count"] = .integer(9)
        let decoded = Settings(values: values)
        XCTAssertEqual(decoded.samples.count, 8, "the decoder keeps at most the operation's eight slots")
    }
}
