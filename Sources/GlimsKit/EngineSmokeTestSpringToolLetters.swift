import AppKit

// MARK: - GLIMS_SMOKE_CASE=spring-tool-letters

@MainActor
extension EngineSmokeTest {
    /// Uses the pre-existing canvas event entry points, ToolState and native
    /// session API so this same fixture can be overlaid on the old app.
    /// Expected pixels come from literal payloads and a separately configured
    /// native pencil stroke, never from the spring state or gesture planner.
    static func exerciseSpringToolLetters(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
            check(document.pendingWork == 0 && !EngineActivity.shared.isBusy,
                  "spring-letter native work drains")
        }
        let state = ToolState.shared
        let oldTool = state.current, oldForeground = state.foreground
        let oldPencil = state.brush(for: .pencil), oldText = state.textSettings
        var hosts: [(DocumentWindowController, ImageDocument)] = []
        defer {
            for (controller, document) in hosts {
                controller.window?.close()
                documents.items.removeAll { $0 === document }
                // The window owns renderer teardown and schedules the native
                // close. A second close request would not receive a callback.
                wait { (try? session.info(document.image)) == nil }
                check((try? session.info(document.image)) == nil,
                      "the spring-letter image closes before engine shutdown")
            }
            state.foreground = oldForeground
            state.update(.pencil) { $0 = oldPencil }
            state.textSettings = oldText
            state.select(oldTool)
        }
        func host(_ image: Int32, _ name: String) throws -> (DocumentWindowController, ImageDocument) {
            let document = try ImageDocument(session: session, image: image, name: name)
            documents.items.append(document)
            let controller = DocumentWindowController(document: document)
            hosts.append((controller, document))
            controller.showWindow(nil)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.window?.makeFirstResponder(controller.canvas)
            return (controller, document)
        }
        func key(_ type: NSEvent.EventType, _ text: String, _ code: UInt16,
                 _ time: Double, _ controller: DocumentWindowController,
                 flags: NSEvent.ModifierFlags = [], repeated: Bool = false) throws -> NSEvent {
            guard let window = controller.window,
                  let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                              timestamp: time, windowNumber: window.windowNumber,
                                              context: nil, characters: text, charactersIgnoringModifiers: text,
                                              isARepeat: repeated, keyCode: code) else { throw NoSpringEvent() }
            return event
        }
        func letter(_ type: NSEvent.EventType, _ text: String, _ code: UInt16,
                    _ time: Double, _ controller: DocumentWindowController,
                    flags: NSEvent.ModifierFlags = [], repeated: Bool = false) throws {
            let event = try key(type, text, code, time, controller, flags: flags, repeated: repeated)
            if type == .keyDown { controller.canvas.keyDown(with: event) }
            else { controller.canvas.keyUp(with: event) }
        }
        func pointer(_ type: NSEvent.EventType, _ point: CGPoint, _ time: Double,
                     _ controller: DocumentWindowController, flags: NSEvent.ModifierFlags = []) throws {
            let canvas = controller.canvas
            guard let window = controller.window,
                  let event = NSEvent.mouseEvent(with: type,
                      location: canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil),
                      modifierFlags: flags, timestamp: time, windowNumber: window.windowNumber,
                      context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { throw NoSpringEvent() }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        let image = try session.newImage(width: 96, height: 64)
        try session.fill(image: image, at: .zero, mode: .selection, color: .white)
        let (paint, document) = try host(image, "Spring letters: paint and text")
        let canvas = paint.canvas
        let initialPixels = try session.copyPixels(image, merged: true).pixels
        let initialUndo = document.undoInfo.undoCount

        state.select(.paintbrush) // Establish B's remembered choice explicitly.
        state.select(.hand)
        try letter(.keyDown, "b", 11, 1, paint)
        check(state.current == .paintbrush, "a tool letter selects at key-down")
        try letter(.keyUp, "b", 11, 1.1, paint)
        check(state.current == .paintbrush, "a quick unused tap keeps the selected tool")
        state.select(.hand)
        try letter(.keyDown, "b", 11, 2, paint)
        try letter(.keyUp, "b", 11, 2.31, paint)
        check(state.current == .hand, "a held unused letter restores the prior tool on release")

        state.select(.paintbrush)
        try letter(.keyDown, "b", 11, 3, paint, flags: [.shift])
        check(state.current == .pencil, "Shift-B cycles once to Pencil")
        try letter(.keyDown, "b", 11, 3.02, paint, flags: [.shift], repeated: true)
        check(state.current == .pencil, "autorepeat never cycles again")
        try letter(.keyUp, "b", 11, 3.1, paint, flags: [.shift])
        check(state.current == .pencil, "a quick Shift-letter tap retains its cycled choice")

        state.select(.paintbrush); state.select(.hand)
        try letter(.keyDown, "b", 11, 4, paint)
        state.select(.paintbrush) // An explicit same-tool selection is a new owner.
        try letter(.keyUp, "b", 11, 4.4, paint)
        check(state.current == .paintbrush, "release never overwrites a later explicit same-tool selection")
        state.select(.hand)
        try letter(.keyDown, "b", 11, 5, paint)
        state.update(.pencil) { $0.size = 7 }
        try letter(.keyUp, "b", 11, 5.4, paint)
        check(state.current == .hand, "a brush-setting notification does not steal shortcut ownership")

        state.select(.paintbrush); state.select(.hand)
        try letter(.keyDown, "b", 11, 6, paint)
        try letter(.keyDown, "e", 14, 6.1, paint)
        try letter(.keyUp, "b", 11, 6.4, paint)
        check(state.current == .eraser, "an older overlapping release leaves the newer letter selected")
        try letter(.keyUp, "e", 14, 6.5, paint)
        check(state.current == .hand, "the newest held letter restores the original baseline once")
        let commandB = try key(.keyDown, "b", 11, 7, paint, flags: [.command])
        let optionB = try key(.keyDown, "b", 11, 7, paint, flags: [.option])
        check(!canvas.tools.keyDown(with: commandB) && !canvas.tools.keyDown(with: optionB)
                && state.current == .hand,
              "Command and Option combinations remain outside plain tool letters")
        check(try session.copyPixels(image, merged: true).pixels == initialPixels
                && document.undoInfo.undoCount == initialUndo,
              "tap, hold, repeat and overlap change no native pixels or history")

        // Independently configure the native pencil oracle. Its literal brush
        // and samples do not read ToolState or any captured canvas settings.
        let expected = try session.newImage(width: 96, height: 64)
        defer { try? session.closeImage(expected) }
        try session.fill(image: expected, at: .zero, mode: .selection, color: .white)
        guard let expectedLayer = try session.layers(expected).first?.id else {
            return check(false, "the independent pencil oracle has a native layer")
        }
        var nativeBrush = EngineSession.Brush()
        nativeBrush.tool = .pencil; nativeBrush.size = 7; nativeBrush.opacity = 1
        nativeBrush.pressureSize = false; nativeBrush.hardness = 1
        let nativeStroke = try session.beginStroke(image: expected, drawable: expectedLayer, brush: nativeBrush,
                                                   first: .init(x: 12, y: 16, pressure: 1, timeMilliseconds: 10_000))
        try session.continueStroke(nativeStroke, points: [
            .init(x: 36, y: 16, pressure: 1, timeMilliseconds: 10_060),
            .init(x: 52, y: 16, pressure: 1, timeMilliseconds: 10_100)
        ])
        try session.endStroke(nativeStroke)
        let expectedPixels = try session.copyPixels(expected, merged: true).pixels
        check(expectedPixels != initialPixels && pixel(session, expected, x: 36, y: 16) == [0, 0, 0, 255]
                && pixel(session, expected, x: 36, y: 40) == [255, 255, 255, 255],
              "the independent native pencil oracle has black ink and untouched white")

        state.foreground = .black
        state.update(.pencil) { $0 = nativeBrush }
        state.select(.paintbrush)
        try letter(.keyDown, "b", 11, 9.95, paint, flags: [.shift])
        try pointer(.leftMouseDown, CGPoint(x: 12, y: 16), 10, paint)
        check(document.strokeIsActive && state.current == .pencil, "the spring Pencil press accepts a native stroke")
        try letter(.keyUp, "b", 11, 10.03, paint, flags: [.shift])
        check(state.current == .pencil && document.strokeIsActive,
              "release during paint defers restoration until the accepted gesture ends")
        state.foreground = .red
        state.update(.pencil) { $0.size = 29; $0.opacity = 0.2 }
        try pointer(.leftMouseDragged, CGPoint(x: 36, y: 16), 10.06, paint)
        try pointer(.leftMouseUp, CGPoint(x: 52, y: 16), 10.1, paint)
        settle(document)
        check(state.current == .paintbrush && !document.strokeIsActive,
              "paint release finishes before restoring the prior tool")
        check(try session.copyPixels(image, merged: true).pixels == expectedPixels,
              "all painted pixels match independent captured tool, color, size, opacity and samples")
        check(document.undoInfo.undoCount == initialUndo + 1, "the spring stroke adds exactly one native Undo")
        document.undo(); settle(document)
        check(try session.copyPixels(image, merged: true).pixels == initialPixels
                && document.undoInfo.undoCount == initialUndo,
              "Undo exactly restores the pre-stroke pixels and history")
        document.redo(); settle(document)
        check(try session.copyPixels(image, merged: true).pixels == expectedPixels
                && document.undoInfo.undoCount == initialUndo + 1,
              "Redo exactly restores the spring stroke")

        // Text deliberately promotes T before the overlay takes focus. Typed
        // letters stay in the editor; releasing T must not create a layer.
        state.textSettings.font = ((try? session.fonts()) ?? []).first ?? "Sans-serif"
        state.textSettings.size = 12
        state.foreground = .black
        state.select(.hand)
        let beforeTextLayers = document.layers.count, beforeTextUndo = document.undoInfo.undoCount
        try letter(.keyDown, "t", 17, 12, paint)
        try pointer(.leftMouseDown, CGPoint(x: 8, y: 40), 12.01, paint)
        try pointer(.leftMouseUp, CGPoint(x: 8, y: 40), 12.02, paint)
        let editor = canvas.tools.textEditor
        check(editor != nil && paint.window?.firstResponder === editor,
              "a held T opens the actual text overlay without a focus-triggered commit")
        editor?.insertText("bqd 7", replacementRange: NSRange(location: NSNotFound, length: 0))
        let textB = try key(.keyDown, "b", 11, 12.1, paint)
        check(!canvas.tools.keyDown(with: textB) && editor?.string == "bqd 7" && state.current == .text,
              "plain tool letters remain available to the text overlay")
        try letter(.keyUp, "t", 17, 12.5, paint)
        check(canvas.tools.textEditor === editor && editor?.string == "bqd 7"
                && paint.window?.firstResponder === editor && state.current == .text
                && document.layers.count == beforeTextLayers && document.undoInfo.undoCount == beforeTextUndo,
              "T release neither restores a tool nor commits or cancels the typing draft")
        canvas.tools.finishTextEditing(); settle(document)
        check(document.layers.count == beforeTextLayers + 1 && document.undoInfo.undoCount == beforeTextUndo + 1,
              "explicitly finishing the text draft creates just one native text layer")
        if let textID = document.layers.first(where: { $0.kind == .text })?.id {
            check(try session.textLayer(image: image, layer: textID).text == "bqd 7", "the native text layer retains the literal typed letters")
        } else { check(false, "the committed text layer exists") }

        let field = NSTextField(string: "")
        field.frame = NSRect(x: 0, y: 0, width: 100, height: 22)
        paint.window?.contentView?.addSubview(field)
        state.select(.paintbrush); state.select(.hand)
        try letter(.keyDown, "b", 11, 14, paint)
        paint.window?.makeFirstResponder(field)
        check(state.current == .hand && field.currentEditor() != nil,
              "canvas focus loss restores the held tool and leaves the field editor usable")
        check(!canvas.tools.keyDown(with: textB), "a real field editor owns plain letters")
        (field.currentEditor() as? NSTextView)?.insertText("bqd 7", replacementRange: NSRange(location: NSNotFound, length: 0))
        check(field.currentEditor()?.string == "bqd 7", "the field keeps its text draft")
        state.select(.eraser)
        try letter(.keyUp, "b", 11, 14.5, paint)
        check(state.current == .eraser && field.currentEditor()?.string == "bqd 7",
              "a late release after focus loss cannot overwrite a newer tool or field draft")
        paint.window?.makeFirstResponder(canvas)
        field.removeFromSuperview()
        state.select(.paintbrush); state.select(.hand)
        try letter(.keyDown, "b", 11, 15, paint)
        try letter(.keyDown, "\u{1b}", 53, 15.1, paint)
        check(state.current == .hand, "Escape clears a held shortcut without an image edit")
        try letter(.keyUp, "b", 11, 15.5, paint)
        check(state.current == .hand, "the cancelled shortcut's later release stays harmless")

        // A literal 20x14 red layer provides fixed Move geometry and pixels.
        // The spring release must not let the ToolState observer cancel the
        // captured snap before mouse-up commits the expected native move.
        let moveImage = try session.newImage(width: 96, height: 64)
        try session.fill(image: moveImage, at: .zero, mode: .selection, color: .white)
        let red = ClipboardImage(width: 20, height: 14,
                                 pixels: Data((0..<(20 * 14)).flatMap { _ in [UInt8(255), 0, 0, 255] }), origin: .zero)
        let movingID = try session.pastePixels(moveImage, pixels: red, at: CGPoint(x: 10, y: 8))
        let (moving, moveDocument) = try host(moveImage, "Spring letters: captured Move")
        moveDocument.selectLayer(movingID); settle(moveDocument)
        let moveCanvas = moving.canvas
        let snapItem = NSMenuItem(title: "Canvas", action: #selector(DocumentWindowController.toggleSnapToCanvas(_:)), keyEquivalent: "")
        moving.toggleSnapToCanvas(snapItem)
        let beforeMovePixels = try session.copyPixels(moveImage, merged: true).pixels
        let beforeMoveUndo = moveDocument.undoInfo.undoCount
        func bounds() -> CGRect? { moveDocument.layers.first(where: { $0.id == movingID })?.bounds }
        check(bounds() == CGRect(x: 10, y: 8, width: 20, height: 14) && moveCanvas.snapTo.canvas,
              "the Move fixture has literal geometry with Canvas snapping enabled")
        state.select(.move); state.select(.pencil)
        try letter(.keyDown, "v", 9, 20, moving)
        try pointer(.leftMouseDown, CGPoint(x: 20, y: 15), 20.01, moving)
        try pointer(.leftMouseDragged, CGPoint(x: 85, y: 32), 20.04, moving)
        check(moveCanvas.tools.moveSnap?.plan.x?.targetCoordinate == 96
                && moveCanvas.tools.moveSnap?.cancelled == false,
              "the accepted spring Move captures the image's right-edge snap")
        try letter(.keyUp, "v", 9, 20.08, moving)
        state.update(.pencil) { $0.opacity = 0.7 }
        check(state.current == .move && moveCanvas.tools.moveSnap?.cancelled == false,
              "key release and a settings notification preserve the captured Move preview")
        check(try session.copyPixels(moveImage, merged: true).pixels == beforeMovePixels
                && moveDocument.undoInfo.undoCount == beforeMoveUndo,
              "the Move preview changes neither native pixels nor history")
        try pointer(.leftMouseUp, CGPoint(x: 85, y: 32), 20.1, moving)
        settle(moveDocument)
        let afterMovePixels = try session.copyPixels(moveImage, merged: true).pixels
        var literalMovePixels = Data()
        for y in 0..<64 {
            for x in 0..<96 {
                literalMovePixels.append(contentsOf: (76..<96).contains(x) && (25..<39).contains(y)
                    ? [UInt8(255), 0, 0, 255] : [UInt8(255), 255, 255, 255])
            }
        }
        check(bounds() == CGRect(x: 76, y: 25, width: 20, height: 14)
                && afterMovePixels == literalMovePixels && state.current == .pencil,
              "mouse-up commits the literal snapped bounds and every expected pixel before restoring Pencil")
        check(moveDocument.undoInfo.undoCount == beforeMoveUndo + 1, "the captured Move creates one native Undo")
        moveDocument.undo(); settle(moveDocument)
        let undoMovePixels = try session.copyPixels(moveImage, merged: true).pixels
        check(bounds() == CGRect(x: 10, y: 8, width: 20, height: 14)
                && undoMovePixels == beforeMovePixels,
              "Move Undo exactly restores bounds and pixels")
        moveDocument.redo(); settle(moveDocument)
        let redoMovePixels = try session.copyPixels(moveImage, merged: true).pixels
        check(bounds() == CGRect(x: 76, y: 25, width: 20, height: 14)
                && redoMovePixels == literalMovePixels,
              "Move Redo exactly restores the snapped bounds and pixels")

        let beforeCancel = moveDocument.undoInfo.undoCount
        state.select(.move); state.select(.pencil)
        try letter(.keyDown, "v", 9, 22, moving)
        try pointer(.leftMouseDown, CGPoint(x: 86, y: 32), 22.01, moving)
        try pointer(.leftMouseDragged, CGPoint(x: 70, y: 40), 22.04, moving)
        check(state.current == .move && moveCanvas.tools.moveSnap?.cancelled == false,
              "Escape is exercised with an accepted spring Move preview")
        try letter(.keyDown, "\u{1b}", 53, 22.05, moving)
        try letter(.keyUp, "v", 9, 22.06, moving)
        try pointer(.leftMouseUp, CGPoint(x: 70, y: 40), 22.1, moving)
        settle(moveDocument)
        let cancelMovePixels = try session.copyPixels(moveImage, merged: true).pixels
        check(state.current == .pencil && moveDocument.undoInfo.undoCount == beforeCancel
                && cancelMovePixels == literalMovePixels,
              "Escape cancels the spring Move without a native move or Undo")

        // The same ownership rule protects a floating move and must never
        // resolve its attachment implicitly when the held letter is released.
        moving.toggleSnapToCanvas(snapItem) // Raw, literal (-20, 10) move.
        var selection = EngineSession.SelectOptions()
        selection.antialias = false
        moveDocument.select(.rectangle(CGRect(x: 76, y: 25, width: 12, height: 10)), options: selection)
        settle(moveDocument)
        var floated = false
        moveDocument.floatSelectedPixels(mode: .copy, target: movingID) {
            if case .success = $0 { floated = true }
        }
        settle(moveDocument)
        let attachment = try session.floatingSelection(moveImage)
        guard floated, attachment.isActive, attachment.target == movingID else {
            return check(false, "the floating fixture retains its explicit source attachment")
        }
        func floatingBounds() -> CGRect? {
            moveDocument.layers.first(where: { $0.id == attachment.floating })?.bounds
        }
        check(floatingBounds() == CGRect(x: 76, y: 25, width: 12, height: 10),
              "the floating fixture has literal cropped bounds")
        // Obtain floating compositing from the unchanged native engine: a
        // floating selection may be clipped to its attachment. This oracle
        // explicitly avoids assuming that red outside the target is visible.
        let floatExpected = try session.newImage(width: 96, height: 64)
        defer { try? session.closeImage(floatExpected) }
        try session.fill(image: floatExpected, at: .zero, mode: .selection, color: .white)
        let floatExpectedTarget = try session.pastePixels(floatExpected, pixels: red, at: CGPoint(x: 76, y: 25))
        try session.select(.rectangle(CGRect(x: 76, y: 25, width: 12, height: 10)), image: floatExpected, options: selection)
        let floatExpectedID = try session.floatSelection(floatExpected, target: floatExpectedTarget, mode: .copy)
        try session.moveLayer(floatExpectedID, image: floatExpected, by: CGSize(width: -20, height: 10))
        let nativeFloatPixels = try session.copyPixels(floatExpected, merged: true).pixels
        let beforeFloatMoveUndo = moveDocument.undoInfo.undoCount
        state.select(.move); state.select(.pencil)
        try letter(.keyDown, "v", 9, 23, moving)
        try pointer(.leftMouseDown, CGPoint(x: 82, y: 30), 23.01, moving)
        try pointer(.leftMouseDragged, CGPoint(x: 62, y: 40), 23.04, moving)
        try letter(.keyUp, "v", 9, 23.05, moving)
        state.update(.pencil) { $0.size = 9 }
        check(state.current == .move && moveCanvas.tools.floatingMove?.cancelled == false,
              "letter release and brush settings preserve the captured floating preview")
        try pointer(.leftMouseUp, CGPoint(x: 62, y: 40), 23.1, moving)
        settle(moveDocument)
        let floatMovedPixels = try session.copyPixels(moveImage, merged: true).pixels
        check(state.current == .pencil && floatingBounds() == CGRect(x: 56, y: 35, width: 12, height: 10)
                && floatMovedPixels == nativeFloatPixels && moveDocument.undoInfo.undoCount == beforeFloatMoveUndo + 1,
              "the floating release matches independent native compositing, commits once and restores Pencil")
        check(try session.floatingSelection(moveImage) == attachment,
              "spring restoration leaves the floating selection attached and unresolved")
        moveDocument.undo(); settle(moveDocument)
        let undoFloatPixels = try session.copyPixels(moveImage, merged: true).pixels
        check(floatingBounds() == CGRect(x: 76, y: 25, width: 12, height: 10)
                && undoFloatPixels == literalMovePixels && moveDocument.undoInfo.undoCount == beforeFloatMoveUndo,
              "floating Move Undo restores the literal pixels and original floating bounds")
        moveDocument.redo(); settle(moveDocument)
        let redoFloatPixels = try session.copyPixels(moveImage, merged: true).pixels
        check(floatingBounds() == CGRect(x: 56, y: 35, width: 12, height: 10)
                && redoFloatPixels == nativeFloatPixels && moveDocument.undoInfo.undoCount == beforeFloatMoveUndo + 1,
              "floating Move Redo restores the independent native pixels and literal bounds as one step")
        var discarded = false
        moveDocument.resolveFloatingSelection(.discard) { if case .success = $0 { discarded = true } }
        settle(moveDocument)
        check(discarded && !moveDocument.floatingState.isActive,
              "only an explicit Discard resolves the floating fixture")
        moveDocument.selectLayer(movingID); settle(moveDocument)
        moving.toggleSnapToCanvas(snapItem)

        state.select(.move); state.select(.pencil)
        try letter(.keyDown, "v", 9, 24, moving)
        try pointer(.leftMouseDown, CGPoint(x: 86, y: 32), 24.01, moving)
        try pointer(.leftMouseDragged, CGPoint(x: 70, y: 40), 24.04, moving)
        check(state.current == .move && moveCanvas.tools.moveSnap?.cancelled == false,
              "window close is exercised with an accepted spring Move preview")
        moving.window?.close()
        check(state.current == .pencil && moveCanvas.tools.moveSnap?.cancelled != false,
              "window close clears the held tool and captured preview")
        wait { (try? session.info(moveImage)) == nil }
        check((try? session.info(moveImage)) == nil, "closing the spring Move document drains and closes its native image")
        try letter(.keyUp, "v", 9, 24.5, moving)
        check(state.current == .pencil, "a late release after close cannot resurrect the temporary tool")
    }

    private struct NoSpringEvent: Error {}
}
