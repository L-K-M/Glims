import AppKit
import XCTest
@testable import GlimsKit

/// The Image menu's color controls — the Mode submenu, the Precision
/// form's choices and seeding, the Image Information rows — as they
/// read without a running engine. The document paths that drive them
/// (conversions, checkmarks against live state, undo) are covered by
/// the engine smoke test.
@MainActor
final class ColorControlsTests: XCTestCase {

    // MARK: Window titles

    /// The title reports the image's real mode — the bug this covers
    /// named every image RGB in the title.
    func testTitleReportsTheActualMode() {
        for (mode, name) in [
            (EngineSession.ColorMode.rgb, "RGB"),
            (.grayscale, "Grayscale"),
            (.indexed, "Indexed"),
            (.unknown, "Unknown"),
        ] as [(EngineSession.ColorMode, String)] {
            XCTAssertEqual(
                DocumentWindowController.title(name: "drawing", zoomPercent: 100, isDirty: false,
                                               mode: mode, precision: "u8-non-linear"),
                "drawing @ 100% (\(name), u8-non-linear)")
        }
    }

    /// The precision nick is the second field wherever it goes.
    func testTitleKeepsThePrecisionNick() {
        XCTAssertEqual(
            DocumentWindowController.title(name: "drawing", zoomPercent: 100, isDirty: false,
                                           mode: .grayscale, precision: "u16-linear"),
            "drawing @ 100% (Grayscale, u16-linear)")
    }

    // MARK: Menu structure

    private func imageMenu() -> NSMenu? {
        MainMenu.make().item(withTitle: "Image")?.submenu
    }

    func testTheImageMenuOpensWithModeAndPrecision() throws {
        let titles = try XCTUnwrap(imageMenu()).items.map(\.title)
        let mode = try XCTUnwrap(titles.firstIndex(of: "Mode"))
        let precision = try XCTUnwrap(titles.firstIndex(of: "Precision…"))
        let size = try XCTUnwrap(titles.firstIndex(of: "Image Size…"))
        XCTAssertEqual(mode, 0, "Mode heads the menu")
        XCTAssertEqual(precision, 1, "Precision follows it")
        XCTAssertLessThan(precision, size, "the color commands precede the geometry ones")
    }

    func testTheModeSubmenuOffersRGBGrayscaleAndIndexed() throws {
        let mode = try XCTUnwrap(imageMenu()?.item(withTitle: "Mode")?.submenu)
        XCTAssertEqual(mode.items.map(\.title), ["RGB", "Grayscale", "Indexed…"])
        for (entry, target) in zip(mode.items, [EngineSession.ColorMode.rgb, .grayscale]) {
            XCTAssertEqual(entry.action, #selector(DocumentWindowController.convertImageMode(_:)))
            // The tag is the mode's facade value: menu validation
            // compares it with the cached mode for the checkmark.
            XCTAssertEqual(entry.tag, Int(target.rawValue))
        }
    }

    /// Indexed uses its policy sheet rather than the direct mode command.
    func testIndexedUsesItsOwnPalettePolicyCommand() throws {
        let mode = try XCTUnwrap(imageMenu()?.item(withTitle: "Mode")?.submenu)
        XCTAssertFalse(mode.items.contains { $0.tag == Int(EngineSession.ColorMode.indexed.rawValue) })
        XCTAssertEqual(mode.item(withTitle: "Indexed…")?.action,
                       #selector(DocumentWindowController.convertImageToIndexed(_:)))
    }

    func testTheImageMenuEndsWithImageInformation() throws {
        let items = try XCTUnwrap(imageMenu()).items
        let info = try XCTUnwrap(items.last { $0.action == #selector(DocumentWindowController.imageInformation(_:)) })
        XCTAssertEqual(info.title, "Image Information…")
        XCTAssertEqual(items.last, info)
    }

    // MARK: Precision form choices

    /// The component popup offers 8/16/32-bit integer then 16/32/64-bit
    /// float — every value image_convert_precision takes.
    func testTheComponentChoicesCoverEveryPrecision() {
        let components = EngineSession.ColorComponent.conversionChoices
        XCTAssertEqual(components, [.u8, .u16, .u32, .half, .float, .double])
        XCTAssertEqual(components.map(\.title),
                       ["8-bit integer", "16-bit integer", "32-bit integer",
                        "16-bit float", "32-bit float", "64-bit float"])
    }

    func testTheTransferCurveChoicesCoverEveryCurve() {
        let trcs = EngineSession.ColorTRC.conversionChoices
        XCTAssertEqual(trcs, [.linear, .nonlinear, .perceptual])
        XCTAssertEqual(trcs.map(\.title), ["Linear", "Non-linear", "Perceptual"])
    }

    /// The popups open on the image's current component and curve, not
    /// on a default.
    func testThePopupSeedsTheCurrentValue() {
        let components = EngineSession.ColorComponent.conversionChoices.map { (value: $0, title: $0.title) }
        let content = ColorForms.popupContent(choices: components, current: .u16)
        XCTAssertEqual(content.titles, components.map(\.title))
        XCTAssertEqual(content.selected, 1)
        XCTAssertNil(content.disabled)

        let trcs = EngineSession.ColorTRC.conversionChoices.map { (value: $0, title: $0.title) }
        let seeded = ColorForms.popupContent(choices: trcs, current: .perceptual)
        XCTAssertEqual(seeded.selected, 2)
        XCTAssertNil(seeded.disabled)
    }

    /// A state the facade reports but this build cannot name appears as
    /// a disabled "Unknown" row rather than seeding a wrong value.
    func testThePopupShowsUnknownHonesty() {
        let components = EngineSession.ColorComponent.conversionChoices.map { (value: $0, title: $0.title) }
        let content = ColorForms.popupContent(choices: components, current: .unknown)
        XCTAssertEqual(content.titles.first, "Unknown")
        XCTAssertEqual(content.titles.count, components.count + 1)
        XCTAssertEqual(content.selected, 0)
        XCTAssertEqual(content.disabled, 0)
    }

    // MARK: Indexed restriction

    /// Indexed precision is fixed at u8 non-linear: the Precision item
    /// stays listed but disabled on indexed images only.
    func testIndexedPrecisionIsFixed() {
        XCTAssertTrue(ColorForms.precisionIsFixed(mode: .indexed))
        for mode in [EngineSession.ColorMode.rgb, .grayscale, .unknown] {
            XCTAssertFalse(ColorForms.precisionIsFixed(mode: mode))
        }
    }

    // MARK: Image Information

    private func info(mode: EngineSession.ColorMode = .rgb,
                      component: EngineSession.ColorComponent = .u8,
                      trc: EngineSession.ColorTRC = .nonlinear,
                      profile: String = "GIMP built-in sRGB",
                      embedded: Bool = false) -> EngineSession.ColorInfo {
        EngineSession.ColorInfo(mode: mode, component: component, trc: trc,
                                profileLabel: profile, hasEmbeddedProfile: embedded)
    }

    private func rows(_ colorInfo: EngineSession.ColorInfo) -> [String: String] {
        Dictionary(uniqueKeysWithValues: ColorForms.informationRows(colorInfo: colorInfo)
            .map { ($0.label, $0.value) })
    }

    func testTheInformationRowsReportTheMode() {
        XCTAssertEqual(rows(info(mode: .grayscale))["Mode"], "Grayscale")
        XCTAssertEqual(rows(info(mode: .indexed))["Mode"], "Indexed")
        XCTAssertEqual(rows(info(mode: .unknown))["Mode"], "Unknown")
    }

    func testTheInformationRowsDistinguishEmbeddedFromBuiltin() {
        XCTAssertEqual(rows(info(profile: "My scanner's profile", embedded: true))["Color profile"],
                       "My scanner's profile")
        XCTAssertEqual(rows(info(profile: "My scanner's profile", embedded: true))["Profile source"],
                       "Embedded in the image")
        XCTAssertEqual(rows(info(profile: "GIMP built-in sRGB", embedded: false))["Profile source"],
                       "Built-in default")
    }

    /// No profile at all reports "None" — and invents no source for it.
    func testTheInformationRowsReportNoProfile() {
        let values = ColorForms.informationRows(colorInfo: info(profile: ""))
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: values.map { ($0.label, $0.value) })["Color profile"], "None")
        XCTAssertFalse(values.contains { $0.label == "Profile source" })
    }

    /// An unreadable precision reports "Unknown", never an empty cell.
    func testTheInformationRowsReportUnknownPrecision() {
        XCTAssertEqual(rows(info(component: .unknown))["Precision"], "Unknown")
    }
}
