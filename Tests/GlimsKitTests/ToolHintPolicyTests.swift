import AppKit
import XCTest
@testable import GlimsKit

final class ToolHintPolicyTests: XCTestCase {
    func testEveryExistingToolHasAnExplicitIdleAffordance() {
        let expected: [ToolID: String] = [
            .move: "Drag a layer or guide. Arrows nudge 1 px; Shift-arrows nudge 10 px.",
            .transform: "Drag transform handles. Shift constrains.",
            .crop: "Drag the area to keep.",
            .rectangleSelect: "Select rectangle. Shift adds; Option subtracts; Shift-Option intersects.",
            .ellipseSelect: "Select ellipse. Shift adds; Option subtracts; Shift-Option intersects.",
            .lasso: "Select freehand area. Shift adds; Option subtracts; Shift-Option intersects.",
            .magicWand: "Select connected colors. Shift adds; Option subtracts; Shift-Option intersects.",
            .selectByColor: "Select matching colors. Shift adds; Option subtracts; Shift-Option intersects.",
            .eyedropper: "Click or drag to sample the foreground color.",
            .text: "Click to add or edit text.",
            .path: "Click to add an anchor; drag for handles. Shift-click selects or starts a subpath.",
            .paintbrush: "Drag to apply brush. Option samples color; [ ] changes size.",
            .pencil: "Drag to apply pencil. Option samples color; [ ] changes size.",
            .airbrush: "Drag to apply airbrush. Option samples color; [ ] changes size.",
            .eraser: "Drag to apply eraser. Option samples color; [ ] changes size.",
            .clone: "Option-click sets the clone source; drag to paint.",
            .heal: "Option-click sets the heal source; drag to paint.",
            .smudge: "Drag to apply smudge. Option samples color; [ ] changes size.",
            .blur: "Drag to apply blur. Option samples color; [ ] changes size.",
            .sharpen: "Drag to apply sharpen. Option samples color; [ ] changes size.",
            .dodge: "Drag to apply dodge. Option samples color; [ ] changes size.",
            .burn: "Drag to apply burn. Option samples color; [ ] changes size.",
            .spongeDesaturate: "Drag to change saturation on RGB pixels; Opacity sets strength; [ ] changes size.",
            .spongeSaturate: "Drag to change saturation on RGB pixels; Opacity sets strength; [ ] changes size.",
            .gradient: "Drag the gradient endpoints; release to apply.",
            .bucketFill: "Click to fill using the Paint Bucket options.",
            .hand: "Drag to pan the view.",
            .zoom: "Click to zoom in. Option-click zooms out."
        ]
        XCTAssertEqual(Set(expected.keys), Set(ToolID.allCases))
        for (tool, literal) in expected {
            XCTAssertEqual(ToolHintPolicy.hint(tool: tool, phase: .idle, flags: []), literal)
            XCTAssertFalse(ToolHintPolicy.hint(tool: tool, phase: .dragging, flags: []).isEmpty)
        }
    }

    func testSelectionOperationChangesBeforePressButGeometryChangesDuringDrag() {
        XCTAssertEqual(ToolHintPolicy.hint(tool: .rectangleSelect, phase: .idle, flags: .shift),
            "Add to the selection with rectangle. Shift adds; Option subtracts; Shift-Option intersects.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .ellipseSelect, phase: .idle, flags: .option),
            "Subtract from the selection with ellipse. Shift adds; Option subtracts; Shift-Option intersects.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .lasso, phase: .idle, flags: [.shift, .option]),
            "Intersect the selection with freehand area. Shift adds; Option subtracts; Shift-Option intersects.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .rectangleSelect, phase: .dragging, flags: [.shift, .option]),
            "Constrained rectangle from its center. Shift constrains; Option draws from the center.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .lasso, phase: .dragging, flags: [.shift, .option]),
            "Trace the selection; release to finish. Escape cancels.")
    }

    func testOptionPaintAndCloneSourcesAreDistinctAndNotNewModesMidStroke() {
        XCTAssertEqual(ToolHintPolicy.hint(tool: .paintbrush, phase: .idle, flags: .option),
            "Option-click or drag to sample the foreground color.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .clone, phase: .idle, flags: .option), "Option-click to set the clone source.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .heal, phase: .idle, flags: .option), "Option-click to set the heal source.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .paintbrush, phase: .dragging, flags: .option),
            "Drag to apply brush; release to finish.")
    }

    func testLayeredLabBrushHintsMatchSamplingCapability() {
        XCTAssertEqual(ToolHintPolicy.hint(tool: .paintbrush, phase: .idle, flags: .option,
            mode: .lab, layout: .layeredLab, canSampleLayeredLab: true),
            "Option-click or drag to sample the foreground color.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .paintbrush, phase: .idle, flags: .option,
            mode: .lab, layout: .layeredLab, canSampleLayeredLab: false),
            "Release Option to paint the selected Lab layer.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .paintbrush, phase: .idle, flags: [],
            mode: .lab, layout: .layeredLab, canSampleLayeredLab: true),
            "Paint the selected Lab layer. Option samples color; [ ] changes size.")
        XCTAssertTrue(ToolHintPolicy.hint(tool: .paintbrush, phase: .idle, flags: [],
            mode: .lab).contains("physical Lab value"))
    }

    func testActualTemporaryToolPrecedenceAndModifierRelease() {
        XCTAssertFalse(CanvasKeyboardPolicy.allowsPlainKey([.command, .option]),
                       "Command-Space remains reserved; hold plain Space before adding Command")
        var keys = CanvasKeyboardState()
        keys.keyDown(CanvasKeyboardPolicy.spaceKeyCode)
        keys.modifiersChanged([.command, .option])
        XCTAssertEqual(keys.pointerTool(current: .clone, flags: [.command, .option]), .hand)
        keys.keyUp(CanvasKeyboardPolicy.spaceKeyCode)
        XCTAssertEqual(keys.pointerTool(current: .clone, flags: .option), .move)
        keys.modifiersChanged(.option)
        XCTAssertEqual(keys.pointerTool(current: .clone, flags: .option), .clone)
        XCTAssertTrue(keys.optionIsDown(flags: []))
        keys.modifiersChanged([])
        XCTAssertFalse(keys.optionIsDown(flags: []))
    }

    func testOnlySupportedToolsAdvertiseConstraintsAndPendingCommits() {
        XCTAssertEqual(ToolHintPolicy.hint(tool: .path, phase: .idle, flags: .option),
            "Option-drag an anchor to pull out its handles.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .path, phase: .idle, flags: [.shift, .option]),
            "Shift-click toggles an anchor or starts a new subpath.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .transform, phase: .dragging, flags: .shift),
            "Constrained transform. Release Shift for a free transform.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .gradient, phase: .dragging, flags: [.shift, .option]),
            "Drag the gradient endpoints; release to apply.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .crop, phase: .cropReady(width: 20, height: 13), flags: []),
            "Return crops to 20 × 13 px; Escape cancels.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .transform, phase: .transformReady, flags: []),
            "Return applies the transform; Escape cancels it.")
        XCTAssertEqual(ToolHintPolicy.hint(tool: .text, phase: .textEditing, flags: []),
            "Type text. Escape or clicking outside applies it.")
    }

    func testErrorsProgressAndBusyTextKeepExactPriority() {
        for reason: ToolHintPolicy.Refresh in [.context, .afterAction, .stateChange] {
            XCTAssertEqual(ToolHintPolicy.status(current: "Keep this refusal", isError: true, progressActive: false,
                activity: "Loading", actionIsVisible: false, refresh: reason, hint: "hint", summary: "summary"), "Keep this refusal")
            XCTAssertEqual(ToolHintPolicy.status(current: "Rendering tile 7 of 20", isError: false, progressActive: true,
                activity: "Loading", actionIsVisible: false, refresh: reason, hint: "hint", summary: "summary"), "Rendering tile 7 of 20")
        }
        XCTAssertEqual(ToolHintPolicy.status(current: "Exact busy text", isError: false, progressActive: false,
            activity: "Loading", actionIsVisible: false, refresh: .context, hint: "hint", summary: "summary"), "Exact busy text")
        XCTAssertEqual(ToolHintPolicy.status(current: "Old idle", isError: false, progressActive: false,
            activity: "Loading", actionIsVisible: false, refresh: .stateChange, hint: "hint", summary: "summary"), "Loading…")
    }

    func testImmediateActionFeedbackSurvivesButNewContextShowsHintBeforeSummary() {
        XCTAssertEqual(ToolHintPolicy.status(current: "Selection cancelled.", isError: false, progressActive: false,
            activity: nil, actionIsVisible: true, refresh: .afterAction, hint: "Select rectangle", summary: "32 × 24 px"), "Selection cancelled.")
        XCTAssertEqual(ToolHintPolicy.status(current: "Selection cancelled.", isError: false, progressActive: false,
            activity: nil, actionIsVisible: true, refresh: .context, hint: "Select rectangle", summary: "32 × 24 px"), "Select rectangle · 32 × 24 px")
    }
}
