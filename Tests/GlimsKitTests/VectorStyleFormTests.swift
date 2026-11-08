import AppKit
import XCTest
@testable import GlimsKit

/// Pure checks for the Vector Style sheet's rules: the finite/range
/// guards that mirror the facade's own flags, the change a control set
/// makes against the captured style (disabled sections are never
/// validated or flagged), and the facade-owned enum values the typed
/// wrappers carry. No engine, no windows.
final class VectorStyleFormTests: XCTestCase {

    private static func captured() -> EngineSession.VectorStyle {
        EngineSession.VectorStyle(fillEnabled: true, fillColor: .red, fillAntialias: true,
                                  strokeEnabled: true, strokeColor: .black, strokeAntialias: true,
                                  strokeWidth: 2, strokeCap: .butt, strokeJoin: .miter,
                                  strokeMiterLimit: 4)
    }

    private static func values(fillEnabled: Bool = true, fillColor: NSColor = .red,
                               fillAntialias: Bool = true, strokeEnabled: Bool = true,
                               strokeColor: NSColor = .black, strokeAntialias: Bool = true,
                               strokeWidthText: String = "2.0",
                               strokeCap: EngineSession.VectorCapStyle = .butt,
                               strokeJoin: EngineSession.VectorJoinStyle = .miter,
                               strokeMiterText: String = "4.0") -> VectorStyleFormValidation.Values {
        VectorStyleFormValidation.Values(fillEnabled: fillEnabled, fillColor: fillColor,
                                         fillAntialias: fillAntialias, strokeEnabled: strokeEnabled,
                                         strokeColor: strokeColor, strokeAntialias: strokeAntialias,
                                         strokeWidthText: strokeWidthText, strokeCap: strokeCap,
                                         strokeJoin: strokeJoin, strokeMiterText: strokeMiterText)
    }

    // MARK: Number and range guards (the facade's exact flags)

    func testFiniteNumberParsing() {
        XCTAssertEqual(VectorStyleFormValidation.finiteNumber("2.5"), 2.5)
        XCTAssertEqual(VectorStyleFormValidation.finiteNumber("0"), 0)
        XCTAssertEqual(VectorStyleFormValidation.finiteNumber("  3 "), 3)
        XCTAssertEqual(VectorStyleFormValidation.finiteNumber("2000"), 2000)
        XCTAssertEqual(VectorStyleFormValidation.finiteNumber("-1"), -1)
        XCTAssertNil(VectorStyleFormValidation.finiteNumber(""))
        XCTAssertNil(VectorStyleFormValidation.finiteNumber("   "))
        XCTAssertNil(VectorStyleFormValidation.finiteNumber("abc"))
        XCTAssertNil(VectorStyleFormValidation.finiteNumber("2 3"))
        XCTAssertNil(VectorStyleFormValidation.finiteNumber("1,5"))
        XCTAssertNil(VectorStyleFormValidation.finiteNumber("nan"))
        XCTAssertNil(VectorStyleFormValidation.finiteNumber("inf"))
        XCTAssertNil(VectorStyleFormValidation.finiteNumber("-infinity"))
        XCTAssertNil(VectorStyleFormValidation.finiteNumber("2.5x"))
    }

    func testStrokeWidthGuardMatchesTheFacade() {
        XCTAssertFalse(VectorStyleFormValidation.validStrokeWidth(0))
        XCTAssertFalse(VectorStyleFormValidation.validStrokeWidth(-3))
        XCTAssertFalse(VectorStyleFormValidation.validStrokeWidth(.nan))
        XCTAssertFalse(VectorStyleFormValidation.validStrokeWidth(.infinity))
        XCTAssertTrue(VectorStyleFormValidation.validStrokeWidth(0.1))
        XCTAssertTrue(VectorStyleFormValidation.validStrokeWidth(2))
        XCTAssertTrue(VectorStyleFormValidation.validStrokeWidth(2000))
        XCTAssertFalse(VectorStyleFormValidation.validStrokeWidth(2000.0001))
    }

    func testMiterLimitGuardMatchesTheFacade() {
        XCTAssertTrue(VectorStyleFormValidation.validMiterLimit(0))
        XCTAssertTrue(VectorStyleFormValidation.validMiterLimit(4))
        XCTAssertTrue(VectorStyleFormValidation.validMiterLimit(100))
        XCTAssertFalse(VectorStyleFormValidation.validMiterLimit(-0.5))
        XCTAssertFalse(VectorStyleFormValidation.validMiterLimit(100.1))
        XCTAssertFalse(VectorStyleFormValidation.validMiterLimit(.nan))
        XCTAssertFalse(VectorStyleFormValidation.validMiterLimit(.infinity))
    }

    func testColorComponentGuardMatchesTheFacade() {
        XCTAssertTrue(VectorStyleFormValidation.validColorComponent(0))
        XCTAssertTrue(VectorStyleFormValidation.validColorComponent(0.5))
        XCTAssertTrue(VectorStyleFormValidation.validColorComponent(1))
        XCTAssertFalse(VectorStyleFormValidation.validColorComponent(-0.1))
        XCTAssertFalse(VectorStyleFormValidation.validColorComponent(1.1))
        XCTAssertFalse(VectorStyleFormValidation.validColorComponent(.nan))
        XCTAssertFalse(VectorStyleFormValidation.validColorComponent(.infinity))
    }

    func testColorComponentsReadSRGB() {
        let red = VectorStyleFormValidation.colorComponents(.red)
        XCTAssertEqual(red?.red ?? -1, 1, accuracy: 1e-6)
        XCTAssertEqual(red?.green ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(red?.blue ?? -1, 0, accuracy: 1e-6)
        XCTAssertEqual(red?.alpha ?? -1, 1, accuracy: 1e-6)
        let half = VectorStyleFormValidation.colorComponents(NSColor.black.withAlphaComponent(0.5))
        XCTAssertEqual(half?.alpha ?? -1, 0.5, accuracy: 1e-6)
        XCTAssertEqual(half?.red ?? -1, 0, accuracy: 1e-6)
        // An out-of-range extended color is garbage, not clamped silently.
        let extended = NSColor(srgbRed: 2, green: 0, blue: 0, alpha: 1)
        if let rgb = extended.usingColorSpace(.sRGB), Double(rgb.redComponent) > 1 {
            XCTAssertNil(VectorStyleFormValidation.colorComponents(extended))
        }
    }

    // MARK: Change building

    func testUnchangedValuesAreTheNoOp() {
        let result = VectorStyleFormValidation.change(from: Self.captured(), Self.values())
        guard case .success(let change) = result else {
            return XCTFail("unchanged values must succeed")
        }
        XCTAssertTrue(change.properties.isEmpty, "no field differs, so nothing is flagged: \(change.properties)")
    }

    func testDisablingASectionFlagsOnlyItsEnableBit() {
        let result = VectorStyleFormValidation.change(from: Self.captured(),
                                                      Self.values(fillEnabled: false, strokeEnabled: false))
        guard case .success(let change) = result else { return XCTFail("disabling must succeed") }
        XCTAssertEqual(change.properties, [.enableFill, .enableStroke])
        XCTAssertFalse(change.fillEnabled)
        XCTAssertFalse(change.strokeEnabled)
    }

    func testDisabledSectionsAreNotValidatedOrFlagged() {
        // Garbage in a disabled section's fields is ignored entirely.
        let result = VectorStyleFormValidation.change(
            from: Self.captured(),
            Self.values(fillEnabled: false, strokeEnabled: false,
                        strokeWidthText: "not a number", strokeMiterText: "nan"))
        guard case .success(let change) = result else {
            return XCTFail("disabled sections must not validate garbage")
        }
        XCTAssertEqual(change.properties, [.enableFill, .enableStroke])
        XCTAssertFalse(change.properties.contains(.strokeWidth))
        XCTAssertFalse(change.properties.contains(.strokeMiter))
        XCTAssertFalse(change.properties.contains(.fillColor))
    }

    func testEnabledSectionFlagsOnlyWhatChanged() {
        let result = VectorStyleFormValidation.change(from: Self.captured(),
                                                      Self.values(fillColor: .blue, strokeWidthText: "6"))
        guard case .success(let change) = result else { return XCTFail("valid edits must succeed") }
        XCTAssertEqual(change.properties, [.fillColor, .strokeWidth])
        XCTAssertEqual(change.strokeWidth, 6)
        // Unflagged fields keep the engine's state, including every option
        // the facade does not expose.
        XCTAssertFalse(change.properties.contains(.enableFill))
        XCTAssertFalse(change.properties.contains(.strokeCap))
    }

    func testStrokeFieldGuardsRejectOutOfRangeInput() {
        for bad in ["0", "-1", "2000.5", "abc", "nan", "inf", ""] {
            let result = VectorStyleFormValidation.change(from: Self.captured(),
                                                          Self.values(strokeWidthText: bad))
            if case .success = result {
                XCTFail("width \"\(bad)\" must be refused")
            }
        }
        for bad in ["-1", "100.5", "abc", "nan", ""] {
            let result = VectorStyleFormValidation.change(from: Self.captured(),
                                                          Self.values(strokeMiterText: bad))
            if case .success = result {
                XCTFail("miter \"\(bad)\" must be refused")
            }
        }
        for good in ["0.5", "2000"] {
            guard case .success = VectorStyleFormValidation.change(from: Self.captured(),
                                                                   Self.values(strokeWidthText: good)) else {
                XCTFail("width \"\(good)\" must be accepted")
                return
            }
        }
        guard case .success = VectorStyleFormValidation.change(from: Self.captured(),
                                                               Self.values(strokeMiterText: "100")) else {
            XCTFail("miter 100 must be accepted")
            return
        }
    }

    func testCapJoinAndMiterChangesCarryTheirFacadeValues() {
        let result = VectorStyleFormValidation.change(
            from: Self.captured(),
            Self.values(strokeCap: .round, strokeJoin: .bevel, strokeMiterText: "10"))
        guard case .success(let change) = result else { return XCTFail("valid edits must succeed") }
        XCTAssertEqual(change.properties, [.strokeCap, .strokeJoin, .strokeMiter])
        XCTAssertEqual(change.strokeCap, .round)
        XCTAssertEqual(change.strokeJoin, .bevel)
        XCTAssertEqual(change.strokeMiterLimit, 10)
    }

    func testAntialiasTogglesAreFlaggedPerSection() {
        let result = VectorStyleFormValidation.change(from: Self.captured(),
                                                      Self.values(fillAntialias: false))
        guard case .success(let change) = result else { return XCTFail("valid edits must succeed") }
        XCTAssertEqual(change.properties, [.fillAntialias])
        XCTAssertFalse(change.fillAntialias)
    }

    // MARK: Facade-owned enum values

    func testPropertyBitsAreTheStableFacadeValues() {
        XCTAssertEqual(EngineSession.VectorStyleProperty.enableFill.rawValue, 1 << 0)
        XCTAssertEqual(EngineSession.VectorStyleProperty.fillColor.rawValue, 1 << 1)
        XCTAssertEqual(EngineSession.VectorStyleProperty.fillAntialias.rawValue, 1 << 2)
        XCTAssertEqual(EngineSession.VectorStyleProperty.enableStroke.rawValue, 1 << 3)
        XCTAssertEqual(EngineSession.VectorStyleProperty.strokeColor.rawValue, 1 << 4)
        XCTAssertEqual(EngineSession.VectorStyleProperty.strokeAntialias.rawValue, 1 << 5)
        XCTAssertEqual(EngineSession.VectorStyleProperty.strokeWidth.rawValue, 1 << 6)
        XCTAssertEqual(EngineSession.VectorStyleProperty.strokeCap.rawValue, 1 << 7)
        XCTAssertEqual(EngineSession.VectorStyleProperty.strokeJoin.rawValue, 1 << 8)
        XCTAssertEqual(EngineSession.VectorStyleProperty.strokeMiter.rawValue, 1 << 9)
    }

    func testCapAndJoinValuesAreTheStableFacadeValues() {
        XCTAssertEqual(EngineSession.VectorCapStyle.butt.rawValue, 1)
        XCTAssertEqual(EngineSession.VectorCapStyle.round.rawValue, 2)
        XCTAssertEqual(EngineSession.VectorCapStyle.square.rawValue, 3)
        XCTAssertNil(EngineSession.VectorCapStyle(rawValue: 0))
        XCTAssertNil(EngineSession.VectorCapStyle(rawValue: 4))
        XCTAssertEqual(EngineSession.VectorJoinStyle.miter.rawValue, 1)
        XCTAssertEqual(EngineSession.VectorJoinStyle.round.rawValue, 2)
        XCTAssertEqual(EngineSession.VectorJoinStyle.bevel.rawValue, 3)
        XCTAssertNil(EngineSession.VectorJoinStyle(rawValue: 0))
        XCTAssertNil(EngineSession.VectorJoinStyle(rawValue: 99))
        XCTAssertEqual(EngineSession.VectorCapStyle.allCases.map(\.name),
                       ["Butt", "Round", "Square"])
        XCTAssertEqual(EngineSession.VectorJoinStyle.allCases.map(\.name),
                       ["Miter", "Round", "Bevel"])
    }
}
