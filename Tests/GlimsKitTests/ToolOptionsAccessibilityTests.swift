import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class ToolOptionsAccessibilityTests: XCTestCase {
    func testExistingPopupsExposeTheirVisibleSettingNames() throws {
        let state = ToolState.shared
        let savedTool = state.current
        let savedFonts = state.fontNames
        let savedText = state.textSettings
        defer {
            state.setEngineFonts(savedFonts)
            state.textSettings = savedText
            state.select(savedTool)
        }
        state.setEngineFonts(["Sans-serif", "Serif"])
        for (tool, names): (ToolID, [String]) in [
            (.transform, ["Resample"]), (.text, ["Font", "Align"]),
            (.bucketFill, ["Fill"])
        ] {
            state.select(tool)
            let options = ToolOptionsPaletteController()
            for name in names {
                let row = try XCTUnwrap(options.view.subviews.compactMap { $0 as? NSStackView }
                    .first { ($0.arrangedSubviews.first as? NSTextField)?.stringValue == name })
                let label = try XCTUnwrap(row.arrangedSubviews.first as? NSTextField)
                let control = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? NSPopUpButton }.first)
                XCTAssertEqual(control.accessibilityLabel(), name)
                XCTAssertTrue((control.accessibilityTitleUIElement() as AnyObject?) === label)
                XCTAssertNotNil(control.action)
                XCTAssertNotNil(control.target)
                XCTAssertGreaterThan(control.numberOfItems, 1)
            }
        }
    }

    func testSelectionModeNamesItsControlWithoutReplacingSegmentValues() throws {
        let state = ToolState.shared
        let savedTool = state.current
        defer { state.select(savedTool) }
        state.select(.rectangleSelect)
        let options = ToolOptionsPaletteController()
        let row = try XCTUnwrap(options.view.subviews.compactMap { $0 as? NSStackView }
            .first { ($0.arrangedSubviews.first as? NSTextField)?.stringValue == "Mode" })
        let label = try XCTUnwrap(row.arrangedSubviews.first as? NSTextField)
        let control = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? NSSegmentedControl }.first)
        XCTAssertEqual(control.accessibilityLabel(), "Selection mode")
        XCTAssertTrue((control.accessibilityTitleUIElement() as AnyObject?) === label)
        XCTAssertEqual((0..<control.segmentCount).compactMap { control.label(forSegment: $0) },
                       ["New", "Add", "Subtract", "Intersect"])
        XCTAssertNotNil(control.action)
    }
}
