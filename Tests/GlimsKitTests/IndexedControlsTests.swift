import AppKit
import XCTest
@testable import GlimsKit

/// Pure tests for the Image ▸ Mode ▸ Indexed… controls as they read
/// without a running engine: the Mode menu entry, the choice lists, the
/// strict custom-palette parser, the generated color-count gate, the
/// cached native-eligibility gate and the validated settings builder.
/// The document paths that drive the engine (admission, consent, undo)
/// are covered by the engine smoke test.
@MainActor
final class IndexedControlsTests: XCTestCase {
    func testMaximumColorTextRejectsNumericPrefixes() {
        for value in ["", "12px", "12.5", " 12", "+12", "012", "1", "257", "１２"] {
            XCTAssertNil(IndexedFormLogic.parseMaxColors(value), value)
        }
        XCTAssertEqual(IndexedFormLogic.parseMaxColors("2"), 2)
        XCTAssertEqual(IndexedFormLogic.parseMaxColors("256"), 256)
    }


    // MARK: Menu structure

    func testTheModeSubmenuOffersRGBGrayscaleAndIndexed() {
        let mode = MainMenu.make().item(withTitle: "Image")?.submenu?.item(withTitle: "Mode")?.submenu
        let titles = mode?.items.map(\.title)
        XCTAssertEqual(titles, ["RGB", "Grayscale", "Indexed…"])
        let indexed = mode?.items.last
        XCTAssertEqual(indexed?.action, #selector(DocumentWindowController.convertImageToIndexed(_:)))
        XCTAssertEqual(mode?.items[0].action, #selector(DocumentWindowController.convertImageMode(_:)))
        XCTAssertEqual(mode?.items[0].tag, Int(EngineSession.ColorMode.rgb.rawValue))
        XCTAssertEqual(mode?.items[1].tag, Int(EngineSession.ColorMode.grayscale.rawValue))
    }

    // MARK: Choice lists

    func testThePaletteChoicesAreGeneratedWebMonochromeCustom() {
        XCTAssertEqual(IndexedFormLogic.paletteChoices.map(\.title),
                       ["Generated", "Web", "Monochrome", "Custom"])
        XCTAssertEqual(IndexedFormLogic.paletteChoices.map(\.value),
                       [.generated, .web, .mono, .custom])
    }

    func testTheDitherChoicesAreNoneFSReducedBleedingOrdered() {
        XCTAssertEqual(IndexedFormLogic.ditherChoices.map(\.title),
                       ["None", "FS", "Reduced Bleeding", "Ordered"])
        XCTAssertEqual(IndexedFormLogic.ditherChoices.map(\.value),
                       [.none, .floydSteinberg, .floydSteinbergLowBleed, .fixed])
    }

    // MARK: Generated maximum colors

    func testMaxColorsAcceptsOnly2Through256() {
        XCTAssertFalse(IndexedFormLogic.isValidMaxColors(0))
        XCTAssertFalse(IndexedFormLogic.isValidMaxColors(1))
        XCTAssertTrue(IndexedFormLogic.isValidMaxColors(2))
        XCTAssertTrue(IndexedFormLogic.isValidMaxColors(256))
        XCTAssertFalse(IndexedFormLogic.isValidMaxColors(257))
        XCTAssertFalse(IndexedFormLogic.isValidMaxColors(-4))
    }

    // MARK: Strict custom-palette parsing — valid input

    private func srgb(_ color: NSColor) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard let rgb = color.usingColorSpace(.sRGB) else { return nil }
        return (Double(rgb.redComponent), Double(rgb.greenComponent),
                Double(rgb.blueComponent), Double(rgb.alphaComponent))
    }

    func testASingleColorParsesToOpaqueSRGB() {
        guard case .success(let colors) = IndexedFormLogic.parseCustomPalette("#FF0000") else {
            return XCTFail("#FF0000 must parse")
        }
        XCTAssertEqual(colors.count, 1)
        guard let rgb = srgb(colors[0]) else { return XCTFail("the parsed color must be sRGB") }
        XCTAssertEqual(rgb.r, 1, accuracy: 1.0 / 255 / 16)
        XCTAssertEqual(rgb.g, 0, accuracy: 1e-9)
        XCTAssertEqual(rgb.b, 0, accuracy: 1e-9)
        XCTAssertEqual(rgb.a, 1, accuracy: 1e-9)
    }

    func testHexDigitsAreCaseInsensitiveAndExact() {
        for text in ["#a1B2c3", "#A1b2C3", "#000000", "#ffffff"] {
            guard case .success(let colors) = IndexedFormLogic.parseCustomPalette(text),
                  let rgb = srgb(colors[0]) else {
                return XCTFail("\(text) must parse")
            }
            let expected = Int(text.dropFirst(), radix: 16)!
            XCTAssertEqual(rgb.r, Double((expected >> 16) & 0xff) / 255, accuracy: 1e-9)
            XCTAssertEqual(rgb.g, Double((expected >> 8) & 0xff) / 255, accuracy: 1e-9)
            XCTAssertEqual(rgb.b, Double(expected & 0xff) / 255, accuracy: 1e-9)
            XCTAssertEqual(rgb.a, 1, accuracy: 1e-9)
        }
    }

    func testBlankLinesAreAllowedBetweenColors() {
        guard case .success(let colors) = IndexedFormLogic.parseCustomPalette("#FF0000\n\n#00FF00\n\n\n#0000FF\n") else {
            return XCTFail("blank lines must be allowed")
        }
        XCTAssertEqual(colors.count, 3)
        XCTAssertEqual(srgb(colors[1])?.g ?? -1, 1, accuracy: 1e-9)
    }

    func testExactly256ColorsParse() {
        let text = (1...256).map { String(format: "#%06X", $0 * 997) }.joined(separator: "\n")
        guard case .success(let colors) = IndexedFormLogic.parseCustomPalette(text) else {
            return XCTFail("256 colors must parse")
        }
        XCTAssertEqual(colors.count, 256)
    }

    // MARK: Strict custom-palette parsing — refusals

    private func XCTAssertRefused(_ text: String, _ note: String = "",
                                   file: StaticString = #filePath, line: UInt = #line) {
        if case .success = IndexedFormLogic.parseCustomPalette(text) {
            XCTFail("\"\(text)\" must not parse \(note)", file: file, line: line)
        }
    }

    func testBadLengthsAreRefused() {
        for text in ["#", "#F", "#FF", "#FFF", "#FFFF", "#FFFFF", "#FFFFFFF", "FF0000", "0xFF0000"] {
            XCTAssertRefused(text, "bad length")
        }
    }

    func testBadHexDigitsAreRefused() {
        for text in ["#GGGGGG", "#12345G", "#FF00 0", "#-F0000", "#ＦＦ0000", "#１２３45"] {
            XCTAssertRefused(text, "non-hex")
        }
    }

    func testWhitespaceBoundariesAreRefused() {
        // No trimming: any decoration around the color is refused, and a
        // whitespace-only line is not blank.
        for text in [" #FF0000", "#FF0000 ", "\t#FF0000", "#FF0000\t", "#FF0000\n   \n#00FF00",
                     "#FF0000\r\n#00FF00", "#FF 000"] {
            XCTAssertRefused(text, "whitespace boundary")
        }
    }

    func testNULIsRefusedBeforeAnyColorIsBuilt() {
        XCTAssertRefused("#FF0000\u{0}")
        XCTAssertRefused("#FF000\u{0}0")
        XCTAssertRefused("\u{0}")
        XCTAssertRefused("#FF0000\n#00FF00\u{0}")
    }

    func testTheColorCountIsEnforced() {
        XCTAssertRefused("", "no colors at all")
        XCTAssertRefused("\n\n\n", "only blank lines")
        XCTAssertRefused((1...257).map { String(format: "#%06X", $0) }.joined(separator: "\n"), "257 colors")
    }

    func testARefusalNamesTheOffendingLine() {
        guard case .failure(let error) = IndexedFormLogic.parseCustomPalette("#FF0000\nnope\n#00FF00") else {
            return XCTFail("the bad second line must refuse")
        }
        XCTAssertTrue(error.message.contains("2"), "the message names the line: \(error.message)")
    }

    // MARK: Cached native eligibility

    func testEligibilityAllowsU8NonlinearWithoutGroups() {
        let ok = IndexedFormLogic.nativeEligibility(mode: .rgb, component: .u8, trc: .nonlinear, hasGroup: false)
        XCTAssertTrue(ok.allowed)
        XCTAssertNil(ok.reason)
        let gray = IndexedFormLogic.nativeEligibility(mode: .grayscale, component: .u8, trc: .nonlinear, hasGroup: false)
        XCTAssertTrue(gray.allowed)
    }

    func testAnAlreadyIndexedImageIsIneligibleAndSaysSo() {
        let result = IndexedFormLogic.nativeEligibility(mode: .indexed, component: .u8, trc: .nonlinear, hasGroup: false)
        XCTAssertFalse(result.allowed)
        XCTAssertEqual(result.reason, "The image is already indexed.")
    }

    func testWrongPrecisionIsIneligibleAndNeverAutoConverted() {
        for component: EngineSession.ColorComponent in [.u16, .u32, .half, .float, .double, .unknown] {
            let result = IndexedFormLogic.nativeEligibility(mode: .rgb, component: component, trc: .nonlinear, hasGroup: false)
            XCTAssertFalse(result.allowed, "\(component) must be ineligible")
            XCTAssertTrue(result.reason?.contains("8-bit non-linear") == true)
            XCTAssertTrue(result.reason?.contains("never changed automatically") == true)
        }
        let linear = IndexedFormLogic.nativeEligibility(mode: .rgb, component: .u8, trc: .linear, hasGroup: false)
        XCTAssertFalse(linear.allowed)
        XCTAssertTrue(linear.reason?.contains("8-bit non-linear") == true)
    }

    func testLayerGroupsAreIneligibleAndNeverAutoFlattened() {
        let result = IndexedFormLogic.nativeEligibility(mode: .rgb, component: .u8, trc: .nonlinear, hasGroup: true)
        XCTAssertFalse(result.allowed)
        XCTAssertTrue(result.reason?.contains("group") == true)
        XCTAssertTrue(result.reason?.contains("never flattened automatically") == true)
    }

    // MARK: Validated settings builder

    func testGeneratedSettingsCarryTheCheckedMaxColorsAndNoCustomList() {
        var values = IndexedFormLogic.FormValues()
        values.palette = .generated
        values.maxColors = 16
        values.removeUnused = true // not honored for Generated
        guard case .success(let settings) = IndexedFormLogic.makeSettings(values, preservation: .preserveEditable) else {
            return XCTFail("generated settings must build")
        }
        XCTAssertEqual(settings.palette, .generated)
        XCTAssertEqual(settings.maxColors, 16)
        XCTAssertFalse(settings.removeUnused)
        XCTAssertTrue(settings.customColors.isEmpty)
        XCTAssertEqual(settings.preservation, .preserveEditable)
    }

    func testGeneratedSettingsRefuseABadMaxColors() {
        for count in [0, 1, 257, -1] {
            var values = IndexedFormLogic.FormValues()
            values.palette = .generated
            values.maxColors = count
            if case .success = IndexedFormLogic.makeSettings(values, preservation: .preserveEditable) {
                XCTFail("max colors \(count) must refuse")
            }
        }
    }

    func testWebSettingsPassRemoveUnusedThrough() {
        var values = IndexedFormLogic.FormValues()
        values.palette = .web
        values.removeUnused = true
        guard case .success(let settings) = IndexedFormLogic.makeSettings(values, preservation: .preserveEditable) else {
            return XCTFail("web settings must build")
        }
        XCTAssertTrue(settings.removeUnused)
        XCTAssertEqual(settings.palette, .web)
    }

    func testMonochromeForcesRemoveUnusedOff() {
        var values = IndexedFormLogic.FormValues()
        values.palette = .mono
        values.removeUnused = true // the engine ignores it for Mono
        guard case .success(let settings) = IndexedFormLogic.makeSettings(values, preservation: .preserveEditable) else {
            return XCTFail("mono settings must build")
        }
        XCTAssertFalse(settings.removeUnused)
    }

    func testCustomSettingsCarryTheParsedOpaqueColors() {
        var values = IndexedFormLogic.FormValues()
        values.palette = .custom
        values.removeUnused = true
        values.customText = "#FF0000\n\n#00FF00"
        guard case .success(let settings) = IndexedFormLogic.makeSettings(values, preservation: .allowRasterize) else {
            return XCTFail("a valid custom palette must build")
        }
        XCTAssertEqual(settings.customColors.count, 2)
        XCTAssertEqual(srgb(settings.customColors[0])?.r ?? -1, 1, accuracy: 1e-9)
        XCTAssertEqual(srgb(settings.customColors[1])?.g ?? -1, 1, accuracy: 1e-9)
        XCTAssertTrue(settings.customColors.allSatisfy { srgb($0)?.a == 1 })
        XCTAssertTrue(settings.removeUnused)
        XCTAssertEqual(settings.preservation, .allowRasterize)
    }

    func testCustomSettingsRefuseInvalidTextWithoutBuilding() {
        for text in ["", "#FFF", "#GGGGGG", "#FF0000\u{0}", "nope"] {
            var values = IndexedFormLogic.FormValues()
            values.palette = .custom
            values.customText = text
            if case .success = IndexedFormLogic.makeSettings(values, preservation: .preserveEditable) {
                XCTFail("custom text \"\(text)\" must refuse")
            }
        }
    }

    func testDitherAndToggleFieldsPassThrough() {
        var values = IndexedFormLogic.FormValues()
        values.dither = .floydSteinbergLowBleed
        values.ditherAlpha = true
        values.ditherText = true
        guard case .success(let settings) = IndexedFormLogic.makeSettings(values, preservation: .preserveEditable) else {
            return XCTFail("settings must build")
        }
        XCTAssertEqual(settings.dither, .floydSteinbergLowBleed)
        XCTAssertTrue(settings.ditherAlpha)
        XCTAssertTrue(settings.ditherText)
    }
}
