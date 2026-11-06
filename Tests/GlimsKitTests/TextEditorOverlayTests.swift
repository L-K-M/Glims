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

    /// The editor previews the alignment the layer will get: a shorter
    /// second line lines up with the longest one at the left, in the middle
    /// or at the right.
    func testTheEditorShowsTheTextsAlignment() throws {
        /// Each line's start and width, in the editor's coordinates.
        func lines(_ justify: EngineSession.TextSettings.Justify) throws -> [(start: CGFloat, width: CGFloat)] {
            var settings = EngineSession.TextSettings()
            settings.justify = justify
            let text = "Hello there\nHi"
            let editor = TextEditorOverlay(layer: nil, text: text, origin: .zero, settings: settings, scale: 1)
            let layout = try XCTUnwrap(editor.layoutManager)
            return try [0, ("Hello there\n" as NSString).length].map { character in
                let glyph = layout.glyphIndexForCharacter(at: character)
                let start = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minX
                    + layout.location(forGlyphAt: glyph).x
                let width = layout.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil).width
                XCTAssertLessThanOrEqual(start + width, editor.frame.width + 0.5, "\(justify) runs past the editor")
                return try XCTUnwrap((start, width))
            }
        }

        let left = try lines(.left), center = try lines(.center), right = try lines(.right)
        XCTAssertEqual(left[1].start, left[0].start, accuracy: 0.5)
        XCTAssertEqual(center[1].start + center[1].width / 2, center[0].start + center[0].width / 2, accuracy: 1)
        XCTAssertEqual(right[1].start + right[1].width, right[0].start + right[0].width, accuracy: 1)
        XCTAssertGreaterThan(center[1].start, left[1].start + 10, "centering moves the short line")
    }
}
