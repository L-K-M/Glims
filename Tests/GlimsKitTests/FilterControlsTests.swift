import AppKit
import XCTest
@testable import GlimsKit

/// The number-row mapping and the property presentation helpers: the
/// engine's odd-power slider curve, absolute vs suggested bounds, digit
/// fallbacks and unit keys.
final class FilterControlsTests: XCTestCase {
    private func property(kind: EngineSession.FilterValueKind = .number,
                          minimum: Double = 0, maximum: Double = 400,
                          uiMinimum: Double = 0.25, uiMaximum: Double = 100,
                          uiStepSmall: Double = 0, uiGamma: Double = 1,
                          uiDigits: Int = -1, unit: String = "") -> EngineSession.FilterProperty {
        EngineSession.FilterProperty(name: "test", label: "Test", blurb: "", unit: unit, kind: kind,
                                     minimum: minimum, maximum: maximum,
                                     uiMinimum: uiMinimum, uiMaximum: uiMaximum,
                                     uiStepSmall: uiStepSmall, uiStepBig: 0, uiGamma: uiGamma,
                                     uiDigits: uiDigits, defaultNumber: 0, defaultBool: false,
                                     defaultString: "", defaultColor: .black, choiceCount: 0)
    }

    func testGammaScaleEndpointsAndLinearMidpoint() {
        let scale = GammaScale(minimum: 0.25, maximum: 100, gamma: 3)
        XCTAssertEqual(scale.value(forPosition: 0), 0.25, accuracy: 0.001)
        XCTAssertEqual(scale.value(forPosition: 1), 100, accuracy: 0.001)
        XCTAssertEqual(scale.position(for: 0.25), 0, accuracy: 0.001)
        XCTAssertEqual(scale.position(for: 100), 1, accuracy: 0.001)
        // GIMP's odd-power mapping: position p → (lo^(1/γ) + p·(hi^(1/γ)−lo^(1/γ)))^γ.
        let expected = pow(pow(0.25, 1.0 / 3.0) + 0.5 * (pow(100, 1.0 / 3.0) - pow(0.25, 1.0 / 3.0)), 3)
        XCTAssertEqual(scale.value(forPosition: 0.5), expected, accuracy: 0.001)
        XCTAssertEqual(scale.position(for: expected), 0.5, accuracy: 0.001)
    }

    func testGammaScaleOneIsLinear() {
        let scale = GammaScale(minimum: 0, maximum: 40, gamma: 1)
        XCTAssertEqual(scale.value(forPosition: 0.5), 20, accuracy: 0.0001)
        XCTAssertEqual(scale.position(for: 30), 0.75, accuracy: 0.0001)
    }

    func testGammaScaleNegativeBoundsUseOddPower() {
        let scale = GammaScale(minimum: -40, maximum: 40, gamma: 3)
        XCTAssertEqual(scale.value(forPosition: 0.5), 0, accuracy: 0.001)
        XCTAssertEqual(scale.value(forPosition: 1), 40, accuracy: 0.001)
        XCTAssertEqual(scale.value(forPosition: 0), -40, accuracy: 0.001)
    }

    func testGammaScaleClampsPositionsAndDegenerateRange() {
        let scale = GammaScale(minimum: 0, maximum: 1, gamma: 2)
        XCTAssertEqual(scale.value(forPosition: 2), 1, accuracy: 0.001)
        XCTAssertEqual(scale.value(forPosition: -1), 0, accuracy: 0.001)
        let flat = GammaScale(minimum: 5, maximum: 5, gamma: 1)
        XCTAssertEqual(flat.position(for: 5), 0)
        XCTAssertEqual(flat.value(forPosition: 0.5), 5, accuracy: 0.001)
    }

    func testPropertyPresentationHelpers() {
        let number = property(uiDigits: -1, unit: "pixel-distance")
        XCTAssertEqual(number.displayUnit, "px")
        XCTAssertEqual(number.displayDigits, 2, "range ≤ 100 defaults to two decimals")
        XCTAssertEqual(number.absoluteRange, 0...400)
        XCTAssertEqual(number.suggestedRange, 0.25...100)

        let explicit = property(uiDigits: 3)
        XCTAssertEqual(explicit.displayDigits, 3)

        let integer = property(kind: .integer, minimum: 0, maximum: 100, uiMinimum: 0, uiMaximum: 40)
        XCTAssertEqual(integer.displayDigits, 0)

        let narrow = property(uiMinimum: 0, uiMaximum: 0.5)
        XCTAssertEqual(narrow.displayDigits, 4)

        XCTAssertEqual(property(unit: "percent").displayUnit, "%")
        XCTAssertEqual(property(unit: "degree").displayUnit, "°")
        XCTAssertEqual(property(unit: "relative-coordinate").displayUnit, "",
                       "unfamiliar unit keys stay hidden rather than shown raw")
    }

    func testNumberRowShowsValuesAcrossTheAbsoluteRange() {
        let row = FilterNumberRow(property: property())
        // Within the suggested range the slider tracks; beyond it the
        // knob stops at the end while the field keeps the value.
        row.show(50)
        XCTAssertEqual(row.value, 50, accuracy: 0.001)
        row.show(300)
        XCTAssertEqual(row.value, 300, accuracy: 0.001)
    }

    func testNumberRowIntegerClampsToAbsoluteBounds() {
        let row = FilterNumberRow(property: property(kind: .integer, minimum: 0, maximum: 150,
                                                     uiMinimum: 0, uiMaximum: 40))
        // The suggested slider range is smaller than the absolute one;
        // the field still takes values up to the absolute limit.
        XCTAssertEqual(row.value, 0)
        XCTAssertEqual(property(kind: .integer, minimum: 0, maximum: 150,
                                uiMinimum: 0, uiMaximum: 40).absoluteRange, 0...150)
    }
}
