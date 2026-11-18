import AppKit
import XCTest
@testable import GlimsKit

final class ColorPaletteTests: XCTestCase {
    private func assertColor(_ color: Swatch, _ red: Double, _ green: Double, _ blue: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(color.red, red, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(color.green, green, accuracy: 1e-9, file: file, line: line)
        XCTAssertEqual(color.blue, blue, accuracy: 1e-9, file: file, line: line)
    }

    func testHSBConversionMatchesTheStandardFormulas() {
        let orange = HSBComponents(Swatch(red: 1, green: 0.5, blue: 0))
        XCTAssertEqual(orange.hue, 30, accuracy: 1e-9)
        XCTAssertEqual(orange.saturation, 1, accuracy: 1e-9)
        XCTAssertEqual(orange.brightness, 1, accuracy: 1e-9)
        let violet = HSBComponents(Swatch(red: 0.5, green: 0, blue: 1))
        XCTAssertEqual(violet.hue, 270, accuracy: 1e-9)
        let rose = HSBComponents(Swatch(red: 1, green: 0, blue: 0.5))
        XCTAssertEqual(rose.hue, 330, accuracy: 1e-9)
        XCTAssertEqual(HSBComponents(Swatch(red: 0.4, green: 0.4, blue: 0.4)),
                       HSBComponents(hue: 0, saturation: 0, brightness: 0.4))

        assertColor(HSBComponents(hue: 120, saturation: 1, brightness: 1).color, 0, 1, 0)
        assertColor(HSBComponents(hue: 200, saturation: 0.5, brightness: 0.8).color, 0.4, 2.0 / 3.0, 0.8)
        assertColor(HSBComponents(hue: 360, saturation: 1, brightness: 1).color, 1, 0, 0)
        for color in [Swatch(red: 0.1, green: 0.7, blue: 0.3), Swatch(red: 0.9, green: 0.2, blue: 0.6),
                      Swatch(red: 0.25, green: 0.25, blue: 0.8)] {
            let back = HSBComponents(color).color
            assertColor(back, color.red, color.green, color.blue)
        }
    }

    func testSlidersEditOneChannelAndRefuseOutOfRangeValues() {
        var state = ColorSliderState(color: Swatch(red: 0, green: 0, blue: 0))
        XCTAssertTrue(state.set(255, channel: 0, mode: .rgb))
        XCTAssertTrue(state.set(51, channel: 2, mode: .rgb))
        assertColor(state.color, 1, 0, 0.2)
        XCTAssertEqual(state.values(.rgb).map { $0.rounded() }, [255, 0, 51])

        XCTAssertFalse(state.set(256, channel: 0, mode: .rgb))
        XCTAssertFalse(state.set(-1, channel: 1, mode: .rgb))
        XCTAssertFalse(state.set(.nan, channel: 1, mode: .rgb))
        XCTAssertFalse(state.set(10, channel: 3, mode: .rgb))
        XCTAssertFalse(state.set(361, channel: 0, mode: .hsb))
        XCTAssertFalse(state.set(50, channel: 1, mode: .grayscale))
        assertColor(state.color, 1, 0, 0.2)

        XCTAssertTrue(state.set(120, channel: 0, mode: .hsb))
        XCTAssertEqual(state.values(.hsb)[0], 120, accuracy: 1e-9)
        assertColor(state.color, 0, 1, 0)
        XCTAssertTrue(state.set(360, channel: 0, mode: .hsb), "360 degrees is red again")
        XCTAssertEqual(state.values(.hsb)[0], 0)

        XCTAssertTrue(state.set(25, channel: 0, mode: .grayscale))
        assertColor(state.color, 0.75, 0.75, 0.75)
        XCTAssertEqual(state.values(.grayscale)[0], 25, accuracy: 1e-9)
        XCTAssertEqual(ColorSliderState(color: Swatch(red: 1, green: 0, blue: 0)).values(.grayscale)[0],
                       70.1, accuracy: 1e-9, "Rec. 601 luma of red is 0.299")
    }

    func testHueAndSaturationSurviveGrayAndBlack() {
        var state = ColorSliderState(color: Swatch(red: 0, green: 0, blue: 1))
        XCTAssertTrue(state.set(0, channel: 2, mode: .hsb))
        assertColor(state.color, 0, 0, 0)
        XCTAssertEqual(state.values(.hsb), [240, 100, 0])
        XCTAssertTrue(state.set(100, channel: 2, mode: .hsb))
        assertColor(state.color, 0, 0, 1)

        XCTAssertTrue(state.set(0, channel: 1, mode: .hsb))
        XCTAssertEqual(state.values(.hsb), [240, 0, 100])
        XCTAssertTrue(state.set(100, channel: 1, mode: .hsb))
        assertColor(state.color, 0, 0, 1)

        // A gray chosen elsewhere keeps the hue too; a real color replaces it.
        state.sync(Swatch(red: 0.5, green: 0.5, blue: 0.5))
        XCTAssertEqual(state.values(.hsb)[0], 240)
        state.sync(Swatch(red: 0, green: 1, blue: 0))
        XCTAssertEqual(state.values(.hsb)[0], 120, accuracy: 1e-9)
    }

    func testColorBarRunsFromWhiteThroughTheHuesToBlack() {
        assertColor(ColorSliderState.colorBar(x: 0, y: 0), 1, 1, 1)
        assertColor(ColorSliderState.colorBar(x: 0, y: 0.5), 1, 0, 0)
        assertColor(ColorSliderState.colorBar(x: 1.0 / 3.0, y: 0.5), 0, 1, 0)
        assertColor(ColorSliderState.colorBar(x: 2.0 / 3.0, y: 0.5), 0, 0, 1)
        assertColor(ColorSliderState.colorBar(x: 0.5, y: 1), 0, 0, 0)
        assertColor(ColorSliderState.colorBar(x: 0, y: 0.25), 1, 0.5, 0.5)
        assertColor(ColorSliderState.colorBar(x: 0, y: 0.75), 0.5, 0, 0)
        assertColor(ColorSliderState.colorBar(x: -3, y: .nan), 1, 1, 1)
    }

    @MainActor
    func testPaletteEditsTheActiveToolColorAndFollowsOutsideChanges() throws {
        let suite = "ColorPaletteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tools = ToolState()
        tools.foreground = .black
        tools.background = .white
        let palette = ColorPaletteController(tools: tools, defaults: defaults)
        palette.loadView()
        XCTAssertEqual(palette.mode, .rgb)
        XCTAssertEqual(palette.fields.map(\.stringValue), ["0", "0", "0"])

        palette.sliders[0].doubleValue = 254.6
        palette.sliders[0].sendAction(palette.sliders[0].action, to: palette.sliders[0].target)
        XCTAssertEqual(Swatch(tools.foreground)?.hex, "#FF0000", "slider values snap to whole units")
        palette.fields[1].stringValue = "128"
        palette.fields[1].sendAction(palette.fields[1].action, to: palette.fields[1].target)
        XCTAssertEqual(Swatch(tools.foreground)?.hex, "#FF8000")
        palette.fields[1].stringValue = "300"
        palette.fields[1].sendAction(palette.fields[1].action, to: palette.fields[1].target)
        XCTAssertEqual(Swatch(tools.foreground)?.hex, "#FF8000", "an out-of-range entry changes nothing")
        XCTAssertEqual(palette.fields[1].stringValue, "128", "and the field shows the value again")

        palette.targetControl.selectedSegment = 1
        palette.targetControl.sendAction(palette.targetControl.action, to: palette.targetControl.target)
        XCTAssertEqual(palette.target, .background)
        XCTAssertEqual(palette.fields.map(\.stringValue), ["255", "255", "255"])
        palette.setMode(.grayscale)
        XCTAssertEqual(defaults.string(forKey: ColorPaletteController.modeKey), "grayscale")
        XCTAssertEqual(palette.paletteMenu?.items.filter { $0.state == .on }.map(\.title), ["Grayscale Slider"])
        XCTAssertTrue(palette.setChannel(0, to: 60))
        XCTAssertEqual(Swatch(tools.background)?.hex, "#666666")
        XCTAssertEqual(Swatch(tools.foreground)?.hex, "#FF8000", "only the active color changes")

        tools.swapColors()
        XCTAssertEqual(palette.fields[0].stringValue, String(Int(((1 - ColorSliderState.luminance(
            Swatch(red: 1, green: 128.0 / 255, blue: 0))) * 100).rounded())),
                       "the sliders follow a swap made elsewhere")
        XCTAssertEqual(ColorPaletteController(tools: tools, defaults: defaults).mode, .grayscale,
                       "the slider choice persists")
    }

    @MainActor
    func testAColorChangedBeforeTheViewLoadsReachesTheSliders() throws {
        let suite = "ColorPaletteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tools = ToolState()
        tools.foreground = .black
        let palette = ColorPaletteController(tools: tools, defaults: defaults)
        tools.foreground = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        tools.notifyChange()
        palette.loadView()
        XCTAssertEqual(palette.fields.map(\.stringValue), ["255", "0", "0"])

        palette.fields[2].stringValue = "255"
        palette.fields[2].sendAction(palette.fields[2].action, to: palette.fields[2].target)
        XCTAssertEqual(Swatch(tools.foreground)?.hex, "#FF00FF", "an edit starts from the current color")
    }

    @MainActor
    func testAFocusedFieldStillFollowsTheSliders() throws {
        let suite = "ColorPaletteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tools = ToolState()
        tools.foreground = .black
        let palette = ColorPaletteController(tools: tools, defaults: defaults)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ColorPaletteController.definition.contentSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = palette
        XCTAssertTrue(window.makeFirstResponder(palette.fields[0]))
        XCTAssertNotNil(palette.fields[0].currentEditor())

        palette.sliders[0].doubleValue = 255
        palette.sliders[0].sendAction(palette.sliders[0].action, to: palette.sliders[0].target)
        XCTAssertEqual(palette.fields[0].stringValue, "255", "the focused field shows the slider's value")
        XCTAssertEqual(palette.fields[0].currentEditor()?.string, "255", "in its editor too")
        palette.setMode(.hsb)
        XCTAssertEqual(palette.fields.map(\.stringValue), ["0", "100", "100"])
    }

    @MainActor
    func testColorBarClicksPickTheActiveOrTheOtherColor() throws {
        let suite = "ColorPaletteTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let tools = ToolState()
        let palette = ColorPaletteController(tools: tools, defaults: defaults)
        palette.loadView()
        palette.colorBar.frame = NSRect(x: 0, y: 0, width: 120, height: 20)
        XCTAssertEqual(palette.colorBar.color(at: NSPoint(x: 40, y: 10)).hex, "#00FF00")

        palette.colorBar.onPick?(.active(Swatch(red: 0, green: 1, blue: 0)))
        XCTAssertEqual(Swatch(tools.foreground)?.hex, "#00FF00")
        palette.colorBar.onPick?(.inactive(Swatch(red: 0, green: 0, blue: 1)))
        XCTAssertEqual(Swatch(tools.background)?.hex, "#0000FF")
        XCTAssertEqual(palette.target, .foreground)
    }
}
