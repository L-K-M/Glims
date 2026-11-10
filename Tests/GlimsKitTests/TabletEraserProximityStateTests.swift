import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class TabletEraserProximityStateTests: XCTestCase {
    func testMissingDevicePreservesSelectedTool() {
        let state = TabletEraserProximityState()

        XCTAssertEqual(state.effectiveTool(selected: .paintbrush, tabletDeviceID: nil), .paintbrush)
        XCTAssertEqual(state.effectiveTool(selected: .pencil, tabletDeviceID: 7), .pencil)
    }

    func testMatchingDeviceUsesEraserWhileNonmatchingPreservesSelection() {
        var state = TabletEraserProximityState()
        state.update(deviceID: 7, entering: true, isEraser: true)

        XCTAssertEqual(state.effectiveTool(selected: .paintbrush, tabletDeviceID: 7), .eraser)
        XCTAssertEqual(state.effectiveTool(selected: .paintbrush, tabletDeviceID: 9), .paintbrush)
        XCTAssertEqual(state.effectiveTool(selected: .airbrush, tabletDeviceID: nil), .airbrush)
    }

    func testLeavingOneOfTwoDevicesKeepsOtherActive() {
        var state = TabletEraserProximityState()
        state.update(deviceID: 1, entering: true, isEraser: true)
        state.update(deviceID: 2, entering: true, isEraser: true)

        state.update(deviceID: 1, entering: false, isEraser: true)

        XCTAssertEqual(state.effectiveTool(selected: .paintbrush, tabletDeviceID: 1), .paintbrush)
        XCTAssertEqual(state.effectiveTool(selected: .paintbrush, tabletDeviceID: 2), .eraser)
    }

    func testPenFlipClearsStaleEraserAndLeavingRemovesRegardlessOfType() {
        var state = TabletEraserProximityState()
        state.update(deviceID: 4, entering: true, isEraser: true)
        XCTAssertEqual(state.effectiveTool(selected: .paintbrush, tabletDeviceID: 4), .eraser)

        state.update(deviceID: 4, entering: true, isEraser: false)
        XCTAssertEqual(state.effectiveTool(selected: .paintbrush, tabletDeviceID: 4), .paintbrush)

        state.update(deviceID: 4, entering: true, isEraser: true)
        state.update(deviceID: 4, entering: false, isEraser: false)
        XCTAssertEqual(state.effectiveTool(selected: .paintbrush, tabletDeviceID: 4), .paintbrush)
    }

    func testClearRemovesTrackedEraserDevices() {
        var state = TabletEraserProximityState()
        state.update(deviceID: 3, entering: true, isEraser: true)
        state.update(deviceID: 8, entering: true, isEraser: true)

        state.clear()

        XCTAssertEqual(state.effectiveTool(selected: .paintbrush, tabletDeviceID: 3), .paintbrush)
        XCTAssertEqual(state.effectiveTool(selected: .paintbrush, tabletDeviceID: 8), .paintbrush)
    }

    func testExplicitLaterSelectedChoicesArePreserved() {
        var state = TabletEraserProximityState()
        var selected: ToolID = .paintbrush
        state.update(deviceID: 11, entering: true, isEraser: true)

        selected = .pencil
        XCTAssertEqual(state.effectiveTool(selected: selected, tabletDeviceID: 11), .eraser)

        state.update(deviceID: 11, entering: false, isEraser: true)
        XCTAssertEqual(state.effectiveTool(selected: selected, tabletDeviceID: 11), .pencil)

        selected = .clone
        XCTAssertEqual(state.effectiveTool(selected: selected, tabletDeviceID: 11), .clone)
    }

    func testComposesWithCanvasKeyboardStatePointerToolPrecedence() {
        var keyboard = CanvasKeyboardState()
        var tablet = TabletEraserProximityState()
        let selected: ToolID = .paintbrush
        tablet.update(deviceID: 20, entering: true, isEraser: true)

        let hardwareEraser = tablet.effectiveTool(selected: selected, tabletDeviceID: 20)
        XCTAssertEqual(hardwareEraser, .eraser)
        XCTAssertEqual(keyboard.pointerTool(current: hardwareEraser, flags: []), .eraser)
        XCTAssertEqual(keyboard.pointerTool(current: hardwareEraser, flags: .command), .move)

        keyboard.keyDown(55)
        XCTAssertEqual(keyboard.pointerTool(current: hardwareEraser, flags: []), .move)
        XCTAssertEqual(keyboard.pointerTool(current: hardwareEraser, flags: .command), .move)

        keyboard.keyDown(CanvasKeyboardPolicy.spaceKeyCode)
        XCTAssertEqual(keyboard.pointerTool(current: hardwareEraser, flags: []), .hand)
        XCTAssertEqual(keyboard.pointerTool(current: hardwareEraser, flags: .command), .hand)

        keyboard.keyUp(CanvasKeyboardPolicy.spaceKeyCode)
        keyboard.keyUp(55)
        XCTAssertEqual(keyboard.pointerTool(current: hardwareEraser, flags: []), .eraser)
    }

    func testExistingOptionPaintBehaviorUnchanged() {
        var keyboard = CanvasKeyboardState()
        var tablet = TabletEraserProximityState()
        let selected: ToolID = .paintbrush
        tablet.update(deviceID: 30, entering: true, isEraser: true)

        keyboard.keyDown(58)
        XCTAssertTrue(keyboard.optionIsDown(flags: []))
        XCTAssertTrue(keyboard.optionIsDown(flags: .option))

        let hardwareEraser = tablet.effectiveTool(selected: selected, tabletDeviceID: 30)
        XCTAssertEqual(hardwareEraser, .eraser)
        XCTAssertEqual(keyboard.pointerTool(current: hardwareEraser, flags: []), .eraser)
        XCTAssertTrue(CanvasKeyboardPolicy.optionSamplesForeground(selected))
        XCTAssertTrue(CanvasKeyboardPolicy.optionSamplesForeground(hardwareEraser))

        tablet.update(deviceID: 30, entering: false, isEraser: true)
        XCTAssertTrue(keyboard.optionIsDown(flags: []))
        keyboard.keyUp(58)
        XCTAssertFalse(keyboard.optionIsDown(flags: []))
        XCTAssertTrue(keyboard.optionIsDown(flags: .option))
        XCTAssertEqual(tablet.effectiveTool(selected: selected, tabletDeviceID: 30), .paintbrush)
    }
    @MainActor
    func testTrackingEventsDoNotReadMouseOnlySubtype() throws {
        for type: NSEvent.EventType in [.mouseEntered, .mouseExited] {
            let event = try XCTUnwrap(NSEvent.enterExitEvent(with: type, location: .zero,
                modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil,
                eventNumber: 1, trackingNumber: 0, userData: nil))
            XCTAssertFalse(TabletEraserProximity.isProximityEvent(event))
            XCTAssertEqual(TabletEraserProximity.shared.effectiveTool(selected: .pencil, event: event), .pencil)
        }
    }

}
