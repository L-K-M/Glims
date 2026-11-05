import Foundation

/// The document window's undo manager: the engine's undo stack, seen
/// through AppKit's.
///
/// Edit ▸ Undo and Redo send `undo:` and `redo:` up the responder chain.
/// `NSWindow` answers both itself, from its undo manager, before a window
/// controller could, so the document's history must be that undo manager.
/// Nothing registers undo actions here; the engine keeps the history.
@MainActor
final class EngineUndoManager: UndoManager {
    private weak var document: ImageDocument?

    init(document: ImageDocument) {
        self.document = document
        super.init()
        groupsByEvent = false
    }

    override var canUndo: Bool { (document?.undoInfo.undoCount ?? 0) > 0 }
    override var canRedo: Bool { (document?.undoInfo.redoCount ?? 0) > 0 }

    override var undoActionName: String { document?.undoInfo.nextUndo ?? "" }
    override var redoActionName: String { document?.undoInfo.nextRedo ?? "" }

    override var undoMenuItemTitle: String { undoMenuTitle(forUndoActionName: undoActionName) }
    override var redoMenuItemTitle: String { redoMenuTitle(forUndoActionName: redoActionName) }

    override func undo() { document?.undo() }
    override func redo() { document?.redo() }
}
