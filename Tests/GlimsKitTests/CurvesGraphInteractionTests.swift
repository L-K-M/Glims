import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class CurvesGraphInteractionTests: XCTestCase {
    private func key(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: code))
    }

    func testAcceptedKeyboardEditsAlwaysEndTheirInteraction() throws {
        _ = NSApplication.shared
        for code: UInt16 in [126, 51, 125] { // Move, Delete, and a clamped no-op.
            let graph = CurvesGraphView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
            graph.selectedPoint = 0
            var sequence: [String] = []
            graph.onBeginEdit = { sequence.append("begin"); return true }
            graph.onStateEdit = { _, _, _ in sequence.append("edit") }
            graph.onEndInteraction = { _ in sequence.append("end") }
            graph.keyDown(with: try key(code))
            XCTAssertEqual(sequence, code == 125 ? ["begin", "end"] : ["begin", "edit", "end"])
            XCTAssertFalse(graph.isInteracting)
        }
    }

    func testRefusedKeyboardEditNeverChangesOrEndsUnownedState() throws {
        _ = NSApplication.shared
        let graph = CurvesGraphView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        graph.selectedPoint = 0
        let initial = graph.state
        var ended = 0
        graph.onBeginEdit = { false }
        graph.onEndInteraction = { _ in ended += 1 }
        graph.keyDown(with: try key(126))
        XCTAssertEqual(graph.state, initial)
        XCTAssertEqual(ended, 0)
    }
}
