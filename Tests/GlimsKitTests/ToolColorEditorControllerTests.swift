import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class ToolColorEditorControllerTests: XCTestCase {
    func testPatternWellColorPreservesTheToolColorAndShowsARevertibleMessage() throws {
        _ = NSApplication.shared
        let state = ToolState()
        state.foreground = NSColor(srgbRed: 0.123456789, green: 0.4, blue: 0.6, alpha: 1)
        let initial = state.foreground
        let editor = ToolColorEditorController(state: state)
        defer { tearDownEditor(editor) }
        XCTAssertTrue(editor.open(target: .foreground))
        let well = try control(NSColorWell.self, "Foreground color well", in: editor)
        well.color = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
        _ = NSApp.sendAction(try XCTUnwrap(well.action), to: editor, from: well)
        XCTAssertEqual(state.foreground, initial)
        XCTAssertEqual(well.color, initial)
        let message = try control(NSTextField.self, "Color editor message", in: editor)
        XCTAssertFalse(message.isHidden)
        XCTAssertTrue(message.stringValue.contains("cannot be converted to sRGB"))
        let revert = try control(NSButton.self, "Revert uncommitted color entries", in: editor)
        XCTAssertTrue(revert.isEnabled)
        revert.performClick(nil)
        XCTAssertTrue(message.isHidden)
        XCTAssertEqual(state.foreground, initial)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView, label: String) -> T? {
        if let match = view as? T, match.accessibilityLabel() == label { return match }
        return view.subviews.lazy.compactMap { self.find(type, in: $0, label: label) }.first
    }

    private func control<T: NSView>(_ type: T.Type, _ label: String,
                                    in editor: ToolColorEditorController) throws -> T {
        let content = try XCTUnwrap(editor.window?.contentView)
        return try XCTUnwrap(find(type, in: content, label: label), "Missing control: \(label)")
    }

    private func draft(_ text: String, in field: NSTextField, editor: ToolColorEditorController) {
        field.stringValue = text
        field.currentEditor()?.string = text
        editor.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
    }

    private func finish(_ field: NSTextField, editor: ToolColorEditorController) {
        editor.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
    }

    private func tearDownEditor(_ editor: ToolColorEditorController) {
        if let content = editor.window?.contentView,
           let button = find(NSButton.self, in: content, label: "Revert uncommitted color entries") {
            button.performClick(nil)
        }
        editor.close()
    }

    func testTargetSwitchSettlesOldDraftAndRejectsDetachedFieldCallbacks() throws {
        _ = NSApplication.shared
        let state = ToolState()
        state.foreground = .black
        state.background = .white
        let editor = ToolColorEditorController(state: state)
        defer { tearDownEditor(editor) }
        XCTAssertTrue(editor.open(target: .foreground))
        let oldField = try control(NSTextField.self, "Red float (0 to 1)", in: editor)
        editor.window?.makeFirstResponder(oldField)
        let fraction = 0.12345678901234568
        draft(String(fraction), in: oldField, editor: editor)
        XCTAssertTrue(editor.open(target: .background))
        XCTAssertEqual(Double(state.foreground.redComponent), fraction, accuracy: 1e-15)
        XCTAssertEqual(state.background, .white)
        XCTAssertEqual(editor.window?.title, "Background Color")

        // Retain and deliver notifications from the detached foreground field.
        // These must not become an edit to either the new target or old one.
        draft("0.9", in: oldField, editor: editor)
        finish(oldField, editor: editor)
        XCTAssertEqual(Double(state.foreground.redComponent), fraction, accuracy: 1e-15)
        XCTAssertEqual(state.background, .white)
        let newField = try control(NSTextField.self, "Red float (0 to 1)", in: editor)
        XCTAssertFalse(oldField === newField)
    }

    func testInvalidDraftSurvivesExternalSamplingAndBlocksTargetSwitchUntilExplicitRevert() throws {
        _ = NSApplication.shared
        let state = ToolState()
        state.foreground = NSColor(srgbRed: 0.12345678901234568, green: 0.4, blue: 0.6, alpha: 1)
        state.background = .white
        let editor = ToolColorEditorController(state: state)
        defer { tearDownEditor(editor) }
        XCTAssertTrue(editor.open(target: .foreground))
        let field = try control(NSTextField.self, "Red float (0 to 1)", in: editor)
        editor.window?.makeFirstResponder(field)
        let unchanged = state.foreground
        draft("nan", in: field, editor: editor)
        finish(field, editor: editor)
        XCTAssertEqual(state.foreground, unchanged)
        let message = try control(NSTextField.self, "Color editor message", in: editor)
        XCTAssertFalse(message.isHidden)
        XCTAssertTrue(message.stringValue.contains("not finite"))

        let sampled = NSColor(srgbRed: 0.23456789012345678, green: 0.5, blue: 0.75, alpha: 1)
        state.foreground = sampled
        state.notifyChange()
        XCTAssertEqual(field.currentEditor()?.string ?? field.stringValue, "nan")
        XCTAssertFalse(message.isHidden)
        let well = try control(NSColorWell.self, "Foreground color well", in: editor)
        XCTAssertEqual(well.color, sampled)
        XCTAssertFalse(editor.open(target: .background))
        XCTAssertEqual(editor.window?.title, "Foreground Color")
        XCTAssertEqual(field.currentEditor()?.string ?? field.stringValue, "nan")
        XCTAssertEqual(state.foreground, sampled)
        XCTAssertEqual(state.background, .white)

        editor.close()
        XCTAssertNotNil(editor.window?.contentView, "Close must retain an invalid draft for correction")
        let revert = try control(NSButton.self, "Revert uncommitted color entries", in: editor)
        revert.performClick(nil)
        XCTAssertTrue(editor.open(target: .background))
        XCTAssertEqual(state.foreground, sampled, "Reverting a draft must not write a color")
    }

    func testCloseAndReopenRejectsTheOldWellsAction() throws {
        _ = NSApplication.shared
        let state = ToolState()
        state.foreground = .black
        state.background = .white
        let editor = ToolColorEditorController(state: state)
        defer { tearDownEditor(editor) }
        XCTAssertTrue(editor.open(target: .foreground))
        let previous = try control(NSColorWell.self, "Foreground color well", in: editor)
        let previousAction = try XCTUnwrap(previous.action)
        editor.close()
        XCTAssertTrue(editor.open(target: .background))
        let current = try control(NSColorWell.self, "Background color well", in: editor)
        XCTAssertFalse(previous === current)
        previous.color = .red
        _ = NSApp.sendAction(previousAction, to: editor, from: previous)
        XCTAssertEqual(state.foreground, .black)
        XCTAssertEqual(state.background, .white)

        let chosen = NSColor(srgbRed: 0.13579135791357913, green: 0.4, blue: 0.8, alpha: 1)
        current.color = chosen
        _ = NSApp.sendAction(try XCTUnwrap(current.action), to: editor, from: current)
        XCTAssertEqual(state.background, chosen)
        XCTAssertEqual(state.foreground, .black)
    }

    func testNumericAndExternalUpdatesSynchronizeAnActiveWell() throws {
        _ = NSApplication.shared
        let state = ToolState()
        state.foreground = .black
        let editor = ToolColorEditorController(state: state)
        defer { tearDownEditor(editor) }
        XCTAssertTrue(editor.open(target: .foreground))
        let well = try control(NSColorWell.self, "Foreground color well", in: editor)
        well.activate(true)
        XCTAssertTrue(well.isActive)
        let field = try control(NSTextField.self, "Blue float (0 to 1)", in: editor)
        let fraction = 0.12345678901234568
        draft(String(fraction), in: field, editor: editor)
        finish(field, editor: editor)
        XCTAssertEqual(Double(well.color.blueComponent), fraction, accuracy: 1e-15)
        XCTAssertEqual(Double(state.foreground.blueComponent), fraction, accuracy: 1e-15)
        let sampled = NSColor(srgbRed: 0.9, green: 0.2, blue: 0.3141592653589793, alpha: 1)
        state.foreground = sampled
        state.notifyChange()
        XCTAssertEqual(well.color, sampled)
        XCTAssertTrue(well.isActive)
    }

    func testLeavingAnUnchangedFocusedReadoutDoesNotOverwriteANewerExternalColor() throws {
        _ = NSApplication.shared
        let state = ToolState()
        state.foreground = .black
        let editor = ToolColorEditorController(state: state)
        defer { tearDownEditor(editor) }
        XCTAssertTrue(editor.open(target: .foreground))
        let field = try control(NSTextField.self, "Red float (0 to 1)", in: editor)
        editor.window?.makeFirstResponder(field)
        var notifications = 0
        let observer = state.observe { notifications += 1 }
        defer { state.removeObserver(observer) }
        let sampled = NSColor(srgbRed: 0.2718281828459045, green: 0.3, blue: 0.4, alpha: 1)
        state.foreground = sampled
        state.notifyChange()
        finish(field, editor: editor)
        XCTAssertEqual(state.foreground, sampled)
        XCTAssertEqual(notifications, 1, "Untouched readouts must not write back or loop")
    }
}
