import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class TextEditorOverlayTests: XCTestCase {

    /// Stands in for the document window's EngineUndoManager, which opens
    /// no groups by itself and so raises on any AppKit registration.
    private final class EngineLikeUndo: NSObject, NSWindowDelegate {
        let manager: UndoManager = {
            let manager = UndoManager()
            manager.groupsByEvent = false
            return manager
        }()

        func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { manager }
    }

    func testTypingHasItsOwnUndoHistoryNotTheDocumentWindows() throws {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let engineUndo = EngineLikeUndo()
        window.delegate = engineUndo
        let editor = TextEditorOverlay(layer: nil, text: "", origin: .zero,
                                       settings: EngineSession.TextSettings(), scale: 1)
        window.contentView?.addSubview(editor)
        window.makeFirstResponder(editor)

        let typing = try XCTUnwrap(editor.undoManager)
        // Typing into the window's manager raises an uncaught exception.
        guard typing !== engineUndo.manager else {
            return XCTFail("the editor registers typing with the document window's undo manager")
        }
        editor.insertText("Hi", replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertEqual(editor.string, "Hi")

        // Edit ▸ Undo while typing takes back the typing, not an image edit.
        XCTAssertTrue(editor.tryToPerform(Selector(("undo:")), with: nil))
        XCTAssertEqual(editor.string, "")
        XCTAssertTrue(editor.tryToPerform(Selector(("redo:")), with: nil))
        XCTAssertEqual(editor.string, "Hi")
        XCTAssertFalse(engineUndo.manager.canUndo)
    }
}
