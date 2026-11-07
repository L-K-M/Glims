import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class CanvasKeyboardTests: XCTestCase {
    private var savedTool = ToolID.paintbrush
    private var savedBrush = EngineSession.Brush()

    override func setUp() {
        super.setUp()
        savedTool = ToolState.shared.current
        savedBrush = ToolState.shared.brush(for: .paintbrush)
    }

    override func tearDown() {
        ToolState.shared.update(.paintbrush) { $0 = savedBrush }
        ToolState.shared.select(savedTool)
        super.tearDown()
    }

    /// Digits 1-9 set 10-90% opacity and 0 sets 100%, nothing else does.
    func testDigitsSetTenToNinetyPercentOpacityAndZeroIsFull() {
        for digit in 1...9 {
            XCTAssertEqual(CanvasKeyboardPolicy.paintOpacity(for: String(digit)), Double(digit) / 10)
        }
        XCTAssertEqual(CanvasKeyboardPolicy.paintOpacity(for: "0"), 1)
        XCTAssertNil(CanvasKeyboardPolicy.paintOpacity(for: "a"))
        XCTAssertNil(CanvasKeyboardPolicy.paintOpacity(for: "!"))
        XCTAssertNil(CanvasKeyboardPolicy.paintOpacity(for: "10"))
        XCTAssertNil(CanvasKeyboardPolicy.paintOpacity(for: ""))
    }

    /// Shift-[ and Shift-] adjust hardness by one tenth, within 0...1, and
    /// nil hardness starts at the engine's 0.5 default.
    func testShiftBracketsAdjustHardnessAndClamp() {
        XCTAssertEqual(CanvasKeyboardPolicy.hardness(nil, increased: true), 0.6, accuracy: 0.0001)
        XCTAssertEqual(CanvasKeyboardPolicy.hardness(nil, increased: false), 0.4, accuracy: 0.0001)
        XCTAssertEqual(CanvasKeyboardPolicy.hardness(0.95, increased: true), 1, accuracy: 0.0001)
        XCTAssertEqual(CanvasKeyboardPolicy.hardness(0.05, increased: false), 0, accuracy: 0.0001)
        XCTAssertEqual(CanvasKeyboardPolicy.hardness(0.4, increased: false), 0.3, accuracy: 0.0001)
        XCTAssertEqual(CanvasKeyboardPolicy.hardnessStep, 0.1, accuracy: 0.0001)
    }

    /// Arrows nudge the active layer 1 px and Shift-arrows 10 px, with the
    /// canvas's flipped y axis: Up is negative image y.
    func testArrowsNudgeOnePixelAndShiftArrowsTen() {
        XCTAssertEqual(CanvasKeyboardPolicy.nudge(.left, shift: false), CGSize(width: -1, height: 0))
        XCTAssertEqual(CanvasKeyboardPolicy.nudge(.right, shift: false), CGSize(width: 1, height: 0))
        XCTAssertEqual(CanvasKeyboardPolicy.nudge(.up, shift: false), CGSize(width: 0, height: -1))
        XCTAssertEqual(CanvasKeyboardPolicy.nudge(.down, shift: false), CGSize(width: 0, height: 1))
        XCTAssertEqual(CanvasKeyboardPolicy.nudge(.left, shift: true), CGSize(width: -10, height: 0))
        XCTAssertEqual(CanvasKeyboardPolicy.nudge(.right, shift: true), CGSize(width: 10, height: 0))
        XCTAssertEqual(CanvasKeyboardPolicy.nudge(.up, shift: true), CGSize(width: 0, height: -10))
        XCTAssertEqual(CanvasKeyboardPolicy.nudge(.down, shift: true), CGSize(width: 0, height: 10))
        XCTAssertEqual(CanvasKeyboardPolicy.Arrow(keyCode: 123), .some(.left))
        XCTAssertEqual(CanvasKeyboardPolicy.Arrow(keyCode: 124), .some(.right))
        XCTAssertEqual(CanvasKeyboardPolicy.Arrow(keyCode: 125), .some(.down))
        XCTAssertEqual(CanvasKeyboardPolicy.Arrow(keyCode: 126), .some(.up))
        XCTAssertNil(CanvasKeyboardPolicy.Arrow(keyCode: 36))
    }

    /// Bracket keys recognize both the unshifted and shifted characters.
    func testBracketKeysIncludeShiftedBraces() {
        XCTAssertTrue(CanvasKeyboardPolicy.isLeftBracket("["))
        XCTAssertTrue(CanvasKeyboardPolicy.isLeftBracket("{"))
        XCTAssertTrue(CanvasKeyboardPolicy.isRightBracket("]"))
        XCTAssertTrue(CanvasKeyboardPolicy.isRightBracket("}"))
        XCTAssertFalse(CanvasKeyboardPolicy.isLeftBracket("]"))
        XCTAssertFalse(CanvasKeyboardPolicy.isRightBracket("["))
    }

    /// Only painting tools have opacity and brush settings to adjust.
    func testDigitsAndBracketsApplyOnlyToPaintTools() {
        for tool in [ToolID.paintbrush, .pencil, .airbrush, .eraser, .clone, .heal,
                     .smudge, .blur, .sharpen, .dodge, .burn] {
            XCTAssertTrue(CanvasKeyboardPolicy.adjustsBrush(tool), tool.name)
        }
        for tool in [ToolID.move, .transform, .crop, .rectangleSelect, .ellipseSelect,
                     .lasso, .magicWand, .selectByColor, .eyedropper, .text, .path,
                     .gradient, .bucketFill, .hand, .zoom] {
            XCTAssertFalse(CanvasKeyboardPolicy.adjustsBrush(tool), tool.name)
        }
    }

    /// Option samples the foreground color with an ordinary paint tool, but
    /// clone and heal keep their Option source behavior.
    func testOptionSamplesForOrdinaryPaintToolsButNotCloneOrHeal() {
        XCTAssertTrue(CanvasKeyboardPolicy.optionSamplesForeground(.paintbrush))
        XCTAssertTrue(CanvasKeyboardPolicy.optionSamplesForeground(.pencil))
        XCTAssertTrue(CanvasKeyboardPolicy.optionSamplesForeground(.airbrush))
        XCTAssertTrue(CanvasKeyboardPolicy.optionSamplesForeground(.eraser))
        XCTAssertFalse(CanvasKeyboardPolicy.optionSamplesForeground(.clone))
        XCTAssertFalse(CanvasKeyboardPolicy.optionSamplesForeground(.heal))
        XCTAssertFalse(CanvasKeyboardPolicy.optionSamplesForeground(.move))
        XCTAssertFalse(CanvasKeyboardPolicy.optionSamplesForeground(.eyedropper))
    }

    /// Command temporarily moves the layer and leaves the prior tool; the
    /// pointer's flags alone report it too.
    func testCommandTemporarilyMovesAndReturnsToThePriorTool() {
        var state = CanvasKeyboardState()
        XCTAssertEqual(state.pointerTool(current: .paintbrush, flags: []), .paintbrush)

        state.keyDown(55)
        XCTAssertTrue(state.commandHeld)
        XCTAssertEqual(state.pointerTool(current: .paintbrush, flags: []), .move)
        XCTAssertEqual(state.pointerTool(current: .paintbrush, flags: .command), .move)

        state.keyUp(55)
        XCTAssertFalse(state.commandHeld)
        XCTAssertEqual(state.pointerTool(current: .paintbrush, flags: []), .paintbrush)

        // The right Command key tracks the same state.
        state.keyDown(54)
        XCTAssertEqual(state.pointerTool(current: .pencil, flags: []), .move)
        state.keyUp(54)
        XCTAssertEqual(state.pointerTool(current: .pencil, flags: []), .pencil)
    }

    /// Space is the temporary hand and takes precedence over Command.
    func testSpaceTakesPrecedenceOverCommand() {
        var state = CanvasKeyboardState()
        state.keyDown(49)
        state.keyDown(55)
        XCTAssertEqual(state.pointerTool(current: .paintbrush, flags: []), .hand)
        state.keyUp(49)
        XCTAssertEqual(state.pointerTool(current: .paintbrush, flags: []), .move)
        state.keyUp(55)
        XCTAssertEqual(state.pointerTool(current: .paintbrush, flags: []), .paintbrush)
    }

    /// Option held state and the pointer's own Option flag agree.
    func testOptionHeldStateAndFlagsAgree() {
        var state = CanvasKeyboardState()
        XCTAssertFalse(state.optionIsDown(flags: []))
        state.keyDown(58)
        XCTAssertTrue(state.optionIsDown(flags: []))
        XCTAssertTrue(state.optionIsDown(flags: .option))
        state.keyUp(61)
        XCTAssertFalse(state.optionIsDown(flags: []))
        // Flags alone still report Option.
        XCTAssertTrue(state.optionIsDown(flags: .option))
    }

    /// Other keys leave the held state alone, and releasing Space clears it.
    func testUnknownKeysDoNotChangeHeldState() {
        var state = CanvasKeyboardState()
        state.keyDown(36)
        state.keyDown(123)
        XCTAssertFalse(state.spaceHeld)
        XCTAssertFalse(state.commandHeld)
        XCTAssertFalse(state.optionHeld)

        state.keyDown(49)
        XCTAssertTrue(state.spaceHeld)
        state.keyUp(49)
        XCTAssertFalse(state.spaceHeld)
    }

    /// Command and Option key events are temporary-tool modifiers; plain
    /// keys ignore Command, Control and Option but keep Shift.
    func testTemporaryModifierKeysAndPlainKeyGuard() {
        for keyCode in [54, 55, 58, 61] {
            XCTAssertTrue(CanvasKeyboardPolicy.isTemporaryModifierKey(keyCode: keyCode))
        }
        for keyCode in [49, 36, 53, 123, 18] {
            XCTAssertFalse(CanvasKeyboardPolicy.isTemporaryModifierKey(keyCode: keyCode))
        }
        XCTAssertTrue(CanvasKeyboardPolicy.allowsPlainKey([]))
        XCTAssertTrue(CanvasKeyboardPolicy.allowsPlainKey(.shift))
        XCTAssertFalse(CanvasKeyboardPolicy.allowsPlainKey(.command))
        XCTAssertFalse(CanvasKeyboardPolicy.allowsPlainKey(.option))
        XCTAssertFalse(CanvasKeyboardPolicy.allowsPlainKey(.control))
        XCTAssertFalse(CanvasKeyboardPolicy.allowsPlainKey([.shift, .command]))
    }

    /// The decisions land in ToolState, which the canvas actually paints with.
    func testToolStateAppliesDigitOpacityAndShiftHardness() throws {
        ToolState.shared.select(.paintbrush)
        let opacity = try XCTUnwrap(CanvasKeyboardPolicy.paintOpacity(for: "7"))
        ToolState.shared.update(.paintbrush) { $0.opacity = opacity }
        XCTAssertEqual(ToolState.shared.brush(for: .paintbrush).opacity, 0.7, accuracy: 0.0001)

        let hardness = CanvasKeyboardPolicy.hardness(ToolState.shared.brush(for: .paintbrush).hardness,
                                                     increased: true)
        ToolState.shared.update(.paintbrush) { $0.hardness = hardness }
        let applied = try XCTUnwrap(ToolState.shared.brush(for: .paintbrush).hardness)
        XCTAssertEqual(applied, hardness, accuracy: 0.0001)
    }
}
