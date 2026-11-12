import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class ToolOptionsAccessibilityTests: XCTestCase {
    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

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
                let row = try XCTUnwrap(descendants(options.view).compactMap { $0 as? NSStackView }
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

    func testTransformNumericRowsAreLabelledAndDisabledWithoutADocument() throws {
        let state = ToolState.shared
        let savedTool = state.current
        defer { state.select(savedTool) }
        state.select(.transform)
        let options = ToolOptionsPaletteController()
        for name in ["X", "Y", "Width", "Height", "Angle"] {
            let row = try XCTUnwrap(descendants(options.view).compactMap { $0 as? NSStackView }
                .first { ($0.arrangedSubviews.first as? NSTextField)?.stringValue == name },
                "missing \(name) row")
            let label = try XCTUnwrap(row.arrangedSubviews.first as? NSTextField)
            let field = try XCTUnwrap(row.arrangedSubviews.compactMap { $0 as? NSTextField }
                .first { $0.isEditable })
            XCTAssertTrue((field.accessibilityTitleUIElement() as AnyObject?) === label)
            XCTAssertEqual(field.accessibilityLabel(), "Transform \(name)")
            XCTAssertFalse(field.isEnabled)
        }
        func buttons(in root: NSView) -> [NSButton] {
            (root as? NSButton).map { [$0] } ?? root.subviews.flatMap(buttons(in:))
        }
        let buttons = buttons(in: options.view)
        let apply = try XCTUnwrap(buttons.first { $0.title == "Apply" })
        let cancel = try XCTUnwrap(buttons.first { $0.title == "Cancel" })
        XCTAssertEqual(apply.accessibilityLabel(), "Apply transform")
        XCTAssertEqual(cancel.accessibilityLabel(), "Cancel transform")
        XCTAssertFalse(apply.isEnabled)
        XCTAssertFalse(cancel.isEnabled)
    }

    func testSelectionModeNamesItsControlWithoutReplacingSegmentValues() throws {
        let state = ToolState.shared
        let savedTool = state.current
        let savedOptions = state.selectOptions
        defer { state.selectOptions = savedOptions; state.select(savedTool) }
        state.select(.rectangleSelect)
        let options = ToolOptionsPaletteController()
        let controls = descendants(options.view).compactMap { $0 as? NSSegmentedControl }
            .filter { $0.accessibilityLabel() == "Selection mode" }
        XCTAssertEqual(controls.count, 1)
        let control = try XCTUnwrap(controls.first)
        XCTAssertEqual(control.accessibilityLabel(), "Selection mode")
        XCTAssertEqual((0..<control.segmentCount).compactMap { control.label(forSegment: $0) },
                       ["New", "Add", "Subtract", "Intersect"])
        XCTAssertNotNil(control.target)
        let action = try XCTUnwrap(control.action)
        for (index, operation) in [EngineSession.SelectOperation.replace, .add, .subtract, .intersect].enumerated() {
            control.selectedSegment = index
            XCTAssertTrue(control.sendAction(action, to: control.target))
            XCTAssertEqual(state.selectOptions.operation, operation)
        }
    }
    func testRejectedTransformDraftSurvivesAnUnfocusedRefreshAndCancelClearsIt() throws {
        let state = ToolState.shared
        let savedTool = state.current
        let savedInterpolation = state.transformInterpolation
        defer { state.transformInterpolation = savedInterpolation; state.select(savedTool) }
        state.select(.transform)
        let options = ToolOptionsPaletteController()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let controls = descendants(options.view)
        let field = try XCTUnwrap(controls.compactMap { $0 as? NSTextField }
            .first { $0.accessibilityLabel() == "Transform Width" })
        field.stringValue = "-"
        _ = field.sendAction(try XCTUnwrap(field.action), to: field.target)
        state.transformInterpolation = .linear
        XCTAssertEqual(field.stringValue, "-", "a failed end-edit draft remains visible after refresh")
        let cancel = try XCTUnwrap(controls.compactMap { $0 as? NSButton }.first { $0.title == "Cancel" })
        XCTAssertTrue(cancel.isEnabled, "even a targetless invalid draft can be explicitly discarded")
        cancel.performClick(nil)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertFalse(cancel.isEnabled)
    }

    func testNumericControlsCanBeRevealedInASmallPalette() throws {
        let savedTool = ToolState.shared.current
        defer { ToolState.shared.select(savedTool) }
        ToolState.shared.select(.transform)
        let options = ToolOptionsPaletteController()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 120))
        let body = options.view
        body.frame = host.bounds
        host.addSubview(body)
        body.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        let labels = ["Transform X", "Transform Width", "Transform Angle", "Apply transform", "Resample"]
        let controls = descendants(body)
        for label in labels {
            let control = try XCTUnwrap(controls.first { $0.accessibilityLabel() == label })
            control.scrollToVisible(control.bounds)
            body.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(control.bounds.height, 10, label)
            XCTAssertTrue(control.visibleRect.insetBy(dx: -1, dy: -1).contains(control.bounds),
                          "\(label) must remain reachable at the minimum palette height")
        }
    }

}
