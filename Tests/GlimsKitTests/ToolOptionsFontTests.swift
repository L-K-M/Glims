import AppKit
import RigiUI
import XCTest
@testable import GlimsKit

@MainActor
final class ToolOptionsFontTests: XCTestCase {
    private var savedTool = ToolID.paintbrush
    private var savedFonts: [String] = []
    private var savedSettings = EngineSession.TextSettings()

    override func setUp() {
        super.setUp()
        let state = ToolState.shared
        savedTool = state.current
        savedFonts = state.fontNames
        savedSettings = state.textSettings
    }

    override func tearDown() {
        let state = ToolState.shared
        state.setEngineFonts(savedFonts)
        state.textSettings = savedSettings
        state.select(savedTool)
        super.tearDown()
    }

    /// The engine lists some font names twice (2622 names, 3 repeated, on
    /// this Mac); the popup must still show and set the font by name.
    func testTheFontPopupShowsAndSetsTheFontByNameWhenTheEngineRepeatsNames() throws {
        let state = ToolState.shared
        state.setEngineFonts(["Mono", "Mono", ".Hidden", "Sans-serif", "Sans-serif Italic", "Serif"])
        state.textSettings.font = "Sans-serif"
        state.select(.text)

        let options = ToolOptionsPaletteController()
        let popUp = try XCTUnwrap(Self.fontPopUp(in: options.view))
        XCTAssertEqual(popUp.titleOfSelectedItem, "Sans-serif")
        XCTAssertEqual(popUp.itemTitles, ["Mono", "Sans-serif", "Sans-serif Italic", "Serif"])

        popUp.selectItem(withTitle: "Sans-serif Italic")
        _ = popUp.sendAction(popUp.action, to: popUp.target)
        XCTAssertEqual(state.textSettings.font, "Sans-serif Italic")
    }

    func testMacOSPrivateFontsAndRepeatsStayOutOfTheMenu() {
        XCTAssertEqual(ToolState.pickableFontNames([".SF Camera Regular", "Arial", ".SF Camera Regular", "Arial", "Zapfino"]),
                       ["Arial", "Zapfino"])
    }

    func testAMissingTextFontFallsBackToTheFirstPickableOne() {
        let state = ToolState.shared
        state.textSettings.font = "Gone"
        state.setEngineFonts([".SF Camera Regular", "Arial"])
        XCTAssertEqual(state.textSettings.font, "Arial")
    }

    private static func fontPopUp(in view: NSView) -> NSPopUpButton? {
        if let row = view as? NSStackView,
           (row.arrangedSubviews.first as? NSTextField)?.stringValue == "Font" {
            return row.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first
        }
        return view.subviews.lazy.compactMap { fontPopUp(in: $0) }.first
    }

    /// Spacing, feather and sizes take fractions, as the engine does.
    func testTheLetterSpacingSliderKeepsAFraction() throws {
        ToolState.shared.select(.text)
        let options = ToolOptionsPaletteController()
        let sliders = Self.sliders(in: options.view)
        let letters = try XCTUnwrap(sliders.first { $0.range == -50...100 }, "the Letters slider")
        letters.value = 1.5
        XCTAssertEqual(letters.value, 1.5)
    }

    private static func sliders(in view: NSView) -> [ClassicValueSlider] {
        ((view as? ClassicValueSlider).map { [$0] } ?? []) + view.subviews.flatMap { sliders(in: $0) }
    }
}
