import AppKit
import XCTest
@testable import GlimsKit

final class SwatchesTests: XCTestCase {
    func testClicksFollowPhotoshopsSwatchesModifiers() {
        XCTAssertEqual(SwatchClick.action(index: 3, flags: []), .chooseForeground(3))
        XCTAssertEqual(SwatchClick.action(index: 3, flags: .option), .chooseBackground(3))
        XCTAssertEqual(SwatchClick.action(index: 3, flags: .shift), .replace(3))
        XCTAssertEqual(SwatchClick.action(index: 3, flags: .command), .delete(3))
        XCTAssertEqual(SwatchClick.action(index: 3, flags: [.shift, .command]), SwatchClick.none)
        XCTAssertEqual(SwatchClick.action(index: nil, flags: []), .addForeground)
        XCTAssertEqual(SwatchClick.action(index: nil, flags: .option), SwatchClick.none)
        XCTAssertEqual(SwatchClick.action(index: 2, flags: [.capsLock, .numericPad]), .chooseForeground(2))
    }

    func testListEditsAndBounds() {
        var list = SwatchList([Swatch(red: 1, green: 0, blue: 0)])
        let blue = Swatch(red: 0, green: 0, blue: 1)
        XCTAssertTrue(list.add(blue))
        XCTAssertEqual(list.swatches.count, 2)
        XCTAssertTrue(list.replace(at: 0, with: blue))
        XCTAssertEqual(list.swatches, [blue, blue])
        XCTAssertFalse(list.replace(at: 2, with: blue))
        XCTAssertFalse(list.remove(at: -1))
        XCTAssertTrue(list.remove(at: 1))
        XCTAssertEqual(list.swatches, [blue])
        list.reset()
        XCTAssertEqual(list.swatches, SwatchList.defaults)

        var full = SwatchList(Array(repeating: blue, count: SwatchList.maximumCount + 5))
        XCTAssertEqual(full.swatches.count, SwatchList.maximumCount)
        XCTAssertFalse(full.add(blue))
    }

    func testSwatchesClampAndDescribeThemselves() {
        let swatch = Swatch(red: 2, green: -1, blue: .nan)
        XCTAssertEqual(swatch, Swatch(red: 1, green: 0, blue: 0))
        XCTAssertEqual(swatch.hex, "#FF0000")
        XCTAssertEqual(Swatch(NSColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 0.3))?.hex, "#0080FF")
        XCTAssertEqual(SwatchList.defaults.count, 47)
        XCTAssertEqual(SwatchList.defaults.first?.hex, "#FF0000")
        XCTAssertEqual(SwatchList.defaults.last?.hex, "#000000")
    }

    @MainActor
    func testStorePersistsEditsAndIgnoresCorruptPreferences() throws {
        let suite = "SwatchesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SwatchStore(defaults: defaults)
        XCTAssertEqual(store.list.swatches, SwatchList.defaults)
        var notified = 0
        store.observe { notified += 1 }
        XCTAssertTrue(store.update { $0.remove(at: 0) })
        XCTAssertFalse(store.update { $0.remove(at: 999) })
        XCTAssertEqual(notified, 1)
        XCTAssertEqual(SwatchStore(defaults: defaults).list.swatches, Array(SwatchList.defaults.dropFirst()))

        defaults.set(Data("not json".utf8), forKey: "Glims.swatches")
        XCTAssertEqual(SwatchStore(defaults: defaults).list.swatches, SwatchList.defaults)

        defaults.set(Data(#"[{"red":2,"green":-1,"blue":0.5}]"#.utf8), forKey: "Glims.swatches")
        let decoded = SwatchStore(defaults: defaults).list.swatches
        XCTAssertEqual(decoded, [Swatch(red: 1, green: 0, blue: 0.5)], "saved components are clamped to 0 ... 1")
        XCTAssertEqual(decoded.first?.hex, "#FF0080")
    }

    @MainActor
    func testHintKeepsItsInsetBesideTheGrid() throws {
        let suite = "SwatchesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let palette = SwatchesPaletteController(store: SwatchStore(defaults: defaults), tools: ToolState())
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 200), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = palette
        window.setContentSize(NSSize(width: 220, height: 200))
        palette.view.layoutSubtreeIfNeeded()
        let stack = try XCTUnwrap(palette.view as? NSStackView)
        XCTAssertFalse(stack.hasAmbiguousLayout)
        let hint = try XCTUnwrap(stack.arrangedSubviews.last)
        let text = hint.alignmentRect(forFrame: hint.frame)
        XCTAssertEqual(text.minX, 8, "the hint text is inset 8 points from the leading edge")
        XCTAssertEqual(text.maxX, 212, "and from the trailing edge")
        XCTAssertEqual(stack.arrangedSubviews.first?.frame.width, 220, "the grid spans the palette")
    }

    @MainActor
    func testPaletteClicksChangeToolColorsAndSwatches() throws {
        let suite = "SwatchesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SwatchStore(defaults: defaults)
        let tools = ToolState()
        let palette = SwatchesPaletteController(store: store, tools: tools)
        palette.loadView()

        palette.perform(.chooseForeground(0))
        XCTAssertEqual(Swatch(tools.foreground), SwatchList.defaults[0])
        palette.perform(.chooseBackground(46))
        XCTAssertEqual(Swatch(tools.background), SwatchList.defaults[46])

        tools.foreground = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        palette.perform(.addForeground)
        XCTAssertEqual(store.list.swatches.last?.hex, "#336699")
        XCTAssertEqual(palette.grid.swatches, store.list.swatches)
        palette.perform(.replace(0))
        XCTAssertEqual(store.list.swatches.first?.hex, "#336699")
        palette.perform(.delete(0))
        XCTAssertEqual(store.list.swatches.count, SwatchList.defaults.count)
        palette.resetSwatches(nil)
        XCTAssertEqual(store.list.swatches, SwatchList.defaults)
    }

    func testGridHitTestingFollowsTheWrappedCells() {
        let grid = SwatchGridView(frame: NSRect(x: 0, y: 0, width: 64, height: 200))
        grid.swatches = Array(repeating: Swatch(red: 0, green: 0, blue: 0), count: 10)
        // 64 points hold four 14-point cells with 2-point gaps.
        XCTAssertEqual(grid.index(at: NSPoint(x: 1, y: 1)), 0)
        XCTAssertEqual(grid.index(at: NSPoint(x: 49, y: 1)), 3)
        XCTAssertEqual(grid.index(at: NSPoint(x: 1, y: 17)), 4)
        XCTAssertNil(grid.index(at: NSPoint(x: 15, y: 1)), "the gap between cells is not a swatch")
        XCTAssertNil(grid.index(at: NSPoint(x: 33, y: 33)), "past the last swatch is empty space")
        XCTAssertEqual(grid.intrinsicContentSize.height, 48)
        XCTAssertEqual(grid.accessibilityChildren()?.count, 10)
        XCTAssertEqual(grid.view(grid, stringForToolTip: 0, point: NSPoint(x: 1, y: 1), userData: nil), "#000000")
        XCTAssertEqual(grid.view(grid, stringForToolTip: 0, point: NSPoint(x: 15, y: 1), userData: nil), "")
    }
}
