import AppKit
import RigiUI

// MARK: - GLIMS_SMOKE_CASE=floating-move

@MainActor
extension EngineSmokeTest {
    /// Moving an EXISTING floating selection's pixels end to end through
    /// the real canvas event path: a Move-tool press captures the
    /// expected floating state/window/document/bounds even when snapping
    /// is off, the drag is a local whole-pixel view-only preview with no
    /// native call per event, and the release commits exactly one
    /// captured move as one undo step through the counted input queue —
    /// with a fresh floating-state revalidation on the worker. Arrow
    /// nudges use the same captured command. Attachment, target kind,
    /// selection mask and the unresolved floating state survive the move;
    /// Anchor / New Layer / Discard still work afterwards (palette
    /// controls found by accessibility label); a Detach that converted
    /// the same id to an ordinary layer makes the captured move refuse;
    /// two documents never retarget; Escape, tool change and window close
    /// cancel the preview and consume the release; accepted strokes land
    /// before the queued move and close drains accepted work.
    static func exerciseFloatingMove(_ session: EngineSession, work: URL,
                                     documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func mouse(_ type: NSEvent.EventType, _ location: CGPoint, _ window: NSWindow,
                   flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)
        }
        func keyEvent(_ window: NSWindow, keyCode: Int, characters: String,
                      flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode))
        }
        // An image point to its window location through the canvas's own
        // conversion (the path the gesture handlers use).
        func windowPoint(ofImagePoint p: CGPoint, _ canvas: EngineCanvasView) -> CGPoint {
            canvas.convert(CGPoint(x: p.x * canvas.scale, y: p.y * canvas.scale), to: nil)
        }

        let imageA = try session.newImage(width: 64, height: 64)
        let docA = try ImageDocument(session: session, image: imageA, name: "FloatMove A")
        let imageB = try session.newImage(width: 64, height: 64)
        let docB = try ImageDocument(session: session, image: imageB, name: "FloatMove B")
        documents.items += [docA, docB]
        let a = DocumentWindowController(document: docA)
        let b = DocumentWindowController(document: docB)
        a.showWindow(nil)
        b.showWindow(nil)
        a.window?.contentView?.layoutSubtreeIfNeeded()
        b.window?.contentView?.layoutSubtreeIfNeeded()
        let previousTool = ToolState.shared.current
        defer {
            ToolState.shared.select(previousTool)
            for (controller, document) in [(a, docA), (b, docB)] {
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
                controller.window?.close()
                documents.items.removeAll { $0 === document }
                document.closeImageWhenDrained()
            }
        }
        guard let windowA = a.window, let windowB = b.window else {
            return check(false, "the floating-move windows exist")
        }
        let canvasA = a.canvas, canvasB = b.canvas
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        var errorsA: [String] = []
        docA.onError = { errorsA.append($0) }

        // A 16x16 opaque red payload on a private pasteboard.
        let red = ClipboardImage(width: 16, height: 16,
                                 pixels: Data((0..<(16 * 16)).flatMap { _ in [UInt8(255), 0, 0, 255] }),
                                 origin: .zero)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try red.write(to: board)

        func selectAll(_ document: ImageDocument) {
            var options = EngineSession.SelectOptions()
            options.antialias = false
            document.select(.rectangle(CGRect(x: 0, y: 0, width: 64, height: 64)), options: options)
            settle(document)
        }
        func pasteFloating(_ controller: DocumentWindowController, _ document: ImageDocument) -> EngineSession.FloatingState {
            controller.pasteIntoImage(from: board)
            settle(document)
            return (try? session.floatingSelection(document.image)) ?? .init(floating: 0, target: 0, targetKind: nil)
        }
        func floatingBounds(_ document: ImageDocument, _ state: EngineSession.FloatingState) -> CGRect? {
            document.layers.first(where: { $0.id == state.floating })?.bounds
        }

        // MARK: Fixture — floating selections on both documents

        guard let layerA = docA.activeLayer else { return check(false, "document A has a layer") }
        selectAll(docA)
        let selectionBefore = try session.selectionBounds(image: imageA)
        check(selectionBefore == CGRect(x: 0, y: 0, width: 64, height: 64),
              "document A has a whole-image selection")
        let stateA = pasteFloating(a, docA)
        guard stateA.isActive && stateA.target == layerA && stateA.targetKind == .layer,
              let fsBounds = floatingBounds(docA, stateA), fsBounds.width > 0 else {
            return check(false, "Paste Into created a layer-attached floating selection on A with cached bounds")
        }
        check(docA.floatingState == stateA, "the document cache matches the native floating state")
        selectAll(docB)
        let stateB = pasteFloating(b, docB)
        guard stateB.isActive, let fsBoundsB = floatingBounds(docB, stateB) else {
            return check(false, "document B has its own floating selection")
        }
        let pixelsBBefore = try session.copyPixels(imageB, merged: true).pixels
        let undoBBefore = docB.undoInfo.undoCount
        // B front: a gesture on A's canvas must still land in A.
        windowB.makeKeyAndOrderFront(nil)
        ToolState.shared.select(.move)

        // MARK: Pointer move with snap OFF — captured at the press, one commit

        let undo0 = docA.undoInfo.undoCount
        let pixelsBeforeMove = try session.copyPixels(imageA, merged: true).pixels
        let press = CGPoint(x: fsBounds.midX, y: fsBounds.midY)
        let dragEnd = CGPoint(x: press.x + 6.4, y: press.y + 4.6) // whole-pixel delta (6, 5)
        guard let down = mouse(.leftMouseDown, windowPoint(ofImagePoint: press, canvasA), windowA),
              let drag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: dragEnd, canvasA), windowA),
              let up = mouse(.leftMouseUp, windowPoint(ofImagePoint: dragEnd, canvasA), windowA) else {
            return check(false, "the floating-move events build")
        }
        check(canvasA.snapTo.isEmpty, "snapping is off for the plain floating move")
        canvasA.mouseDown(with: down)
        check(canvasA.tools.floatingMove != nil && !canvasA.tools.floatingMove!.cancelled,
              "a floating press is captured even when snap is off")
        check(canvasA.tools.floatingMove?.expected == stateA
                && canvasA.tools.floatingMove?.bounds == fsBounds,
              "the capture holds the expected floating state and bounds")
        check(canvasA.tools.moveSnap == nil && canvasB.tools.floatingMove == nil,
              "the floating gesture is not an ordinary snap and stays in A's canvas")
        canvasA.mouseDragged(with: drag)
        check(canvasA.tools.floatingMove?.proposed == fsBounds.offsetBy(dx: 6, dy: 5),
              "the local preview is the whole-pixel delta of the captured bounds")
        check(docA.pendingWork == 0 && docA.undoInfo.undoCount == undo0,
              "no native call happens per dragged event")
        check(try session.copyPixels(imageA, merged: true).pixels == pixelsBeforeMove,
              "the in-progress preview changes no native pixels")
        canvasA.mouseUp(with: up)
        wait { docA.pendingWork == 0 && docA.undoInfo.undoCount == undo0 + 1 }
        spin()
        settle(docA)
        let movedBounds = floatingBounds(docA, stateA)
        check(movedBounds == fsBounds.offsetBy(dx: 6, dy: 5),
              "the release commits exactly one whole-pixel move of the floating selection")
        check(docA.undoInfo.undoCount == undo0 + 1 && canvasA.tools.floatingMove == nil,
              "the floating move is exactly one undo step and the gesture clears")
        let stateAfterMove = try session.floatingSelection(imageA)
        check(stateAfterMove == stateA && docA.floatingState == stateAfterMove,
              "the move preserves the unresolved floating state: same id, attachment and kind")
        let selectionAfterMove = try session.selectionBounds(image: imageA)
        check(selectionAfterMove == selectionBefore,
              "the move leaves the selection mask unchanged")
        check((pixel(session, imageA, x: Int(fsBounds.minX) + 2, y: Int(fsBounds.minY) + 2)?[1] ?? 0) == 255
                && (pixel(session, imageA, x: Int(fsBounds.minX) + 8, y: Int(fsBounds.minY) + 7)?[1] ?? 255) == 0,
              "rendered pixels moved with the floating selection (old spot clear, new spot red)")
        let pixelsAfterMove = try session.copyPixels(imageA, merged: true).pixels
        check(try session.copyPixels(imageB, merged: true).pixels == pixelsBBefore
                && docB.undoInfo.undoCount == undoBBefore
                && (try? session.floatingSelection(imageB)) == stateB,
              "document B, frontmost, is untouched by A's gesture (two-document capture)")

        // MARK: Undo/Redo replay exact pixels

        docA.undo()
        wait { docA.pendingWork == 0 }
        spin()
        settle(docA)
        let pixelsAfterUndo = try session.copyPixels(imageA, merged: true).pixels
        check(floatingBounds(docA, stateA) == fsBounds && pixelsAfterUndo == pixelsBeforeMove,
              "one undo restores the exact pre-move bounds and pixels")
        docA.redo()
        wait { docA.pendingWork == 0 }
        spin()
        settle(docA)
        let pixelsAfterRedo = try session.copyPixels(imageA, merged: true).pixels
        check(floatingBounds(docA, stateA) == movedBounds && pixelsAfterRedo == pixelsAfterMove,
              "redo replays the exact moved bounds and pixels")

        // MARK: Arrow-key nudges through the captured-FS method (1 px, Shift 10 px)

        var nudgeBase = floatingBounds(docA, stateA) ?? fsBounds
        let undoN = docA.undoInfo.undoCount
        if let right = keyEvent(windowA, keyCode: 124, characters: "\u{F703}") {
            canvasA.keyDown(with: right)
        } else { check(false, "the right-arrow event builds") }
        wait { docA.pendingWork == 0 && docA.undoInfo.undoCount == undoN + 1 }
        spin()
        settle(docA)
        check(floatingBounds(docA, stateA) == nudgeBase.offsetBy(dx: 1, dy: 0),
              "a right-arrow nudge moves the floating selection by 1 px")
        nudgeBase = floatingBounds(docA, stateA) ?? nudgeBase
        if let shiftDown = keyEvent(windowA, keyCode: 125, characters: "\u{F704}", flags: [.shift]) {
            canvasA.keyDown(with: shiftDown)
        } else { check(false, "the shift-down event builds") }
        wait { docA.pendingWork == 0 && docA.undoInfo.undoCount == undoN + 2 }
        spin()
        settle(docA)
        check(floatingBounds(docA, stateA) == nudgeBase.offsetBy(dx: 0, dy: 10),
              "Shift-down nudges the floating selection by 10 px")
        check(try session.floatingSelection(imageA) == stateA && docA.floatingState.isActive,
              "nudges preserve the unresolved floating state (no silent anchor)")

        // MARK: Escape cancels the local preview; the release commits nothing

        var cancelBase = floatingBounds(docA, stateA) ?? nudgeBase
        let undoE = docA.undoInfo.undoCount
        let eMid = CGPoint(x: cancelBase.midX, y: cancelBase.midY)
        let eEnd = CGPoint(x: eMid.x + 20, y: eMid.y + 10)
        guard let eDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: eMid, canvasA), windowA),
              let eDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: eEnd, canvasA), windowA),
              let eUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: eEnd, canvasA), windowA) else {
            return check(false, "the escape-test events build")
        }
        canvasA.mouseDown(with: eDown)
        canvasA.mouseDragged(with: eDrag)
        check(canvasA.tools.floatingMove != nil && !canvasA.tools.floatingMove!.cancelled
                && canvasA.tools.floatingMove?.proposed == cancelBase.offsetBy(dx: 20, dy: 10),
              "the drag captures and previews before Escape")
        if let esc = keyEvent(windowA, keyCode: 53, characters: "\u{1b}") { canvasA.keyDown(with: esc) }
        check(canvasA.tools.floatingMove?.cancelled == true, "Escape marks the floating drag cancelled")
        canvasA.mouseUp(with: eUp)
        settle(docA)
        check(floatingBounds(docA, stateA) == cancelBase && docA.undoInfo.undoCount == undoE,
              "the cancelled release commits nothing: no move, no undo, no native action")

        // MARK: Tool change cancels the drag; the release commits nothing

        let undoT = docA.undoInfo.undoCount
        guard let tDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: eMid, canvasA), windowA),
              let tDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: eEnd, canvasA), windowA),
              let tUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: eEnd, canvasA), windowA) else {
            return check(false, "the tool-change-test events build")
        }
        canvasA.mouseDown(with: tDown)
        canvasA.mouseDragged(with: tDrag)
        check(canvasA.tools.floatingMove != nil, "the drag is captured before the tool change")
        ToolState.shared.select(.hand)
        check(canvasA.tools.floatingMove?.cancelled == true, "a tool change cancels the floating drag")
        ToolState.shared.select(.move)
        canvasA.mouseUp(with: tUp)
        settle(docA)
        check(floatingBounds(docA, stateA) == cancelBase && docA.undoInfo.undoCount == undoT,
              "a tool-change-cancelled release commits nothing")

        // MARK: Snap ON reuses the planner on the captured floating bounds

        canvasA.snapTo = SnapToViewState(canvas: true)
        var snapBase = floatingBounds(docA, stateA) ?? cancelBase
        let undoS = docA.undoInfo.undoCount
        let tol = CanvasSnapPlanner.defaultViewPointTolerance / canvasA.scale
        // Drag so the trailing edge lands 0.75 * tol short of the image's
        // max edge (64): inside the tolerance, so Canvas snapping pulls it.
        let rawDX = (64 - 0.75 * tol) - snapBase.maxX
        let sMid = CGPoint(x: snapBase.midX, y: snapBase.midY)
        let sEnd = CGPoint(x: sMid.x + rawDX, y: sMid.y)
        guard let sDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: sMid, canvasA), windowA),
              let sDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: sEnd, canvasA), windowA),
              let sUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: sEnd, canvasA), windowA) else {
            return check(false, "the snapped floating-move events build")
        }
        canvasA.mouseDown(with: sDown)
        canvasA.mouseDragged(with: sDrag)
        let snapGesture = canvasA.tools.floatingMove
        check(snapGesture?.plan.x?.anchor == .trailing && snapGesture?.plan.x?.target == .imageEdge
                && snapGesture?.plan.x?.targetCoordinate == 64,
              "with Snap To on, the floating drag plans against the captured FS bounds (image edge at 64)")
        check(snapGesture?.proposed.maxX == 64 && snapGesture.map({ FloatingControlsLogic.wholePixelDelta(
            bounds: $0.bounds, proposed: $0.proposed).width == 64 - snapBase.maxX }) == true,
              "the whole-pixel preview puts the floating trailing edge at the image edge")
        check(docA.pendingWork == 0 && docA.undoInfo.undoCount == undoS, "the snapped drag still makes no native call per event")
        canvasA.mouseUp(with: sUp)
        wait { docA.pendingWork == 0 && docA.undoInfo.undoCount == undoS + 1 }
        spin()
        settle(docA)
        let snappedBounds = floatingBounds(docA, stateA)
        check(snappedBounds != nil && snappedBounds == snapGesture?.proposed
                && snappedBounds?.maxX == 64 && docA.undoInfo.undoCount == undoS + 1,
              "the snapped floating move commits once onto the image edge")
        check(try session.floatingSelection(imageA) == stateA, "the snapped move keeps the floating selection unresolved")
        docA.undo()
        wait { docA.pendingWork == 0 }
        spin()
        settle(docA)
        canvasA.snapTo = SnapToViewState()
        snapBase = floatingBounds(docA, stateA) ?? snapBase

        // MARK: Accepted input ordering — a stroke lands before the queued move

        // No window callback may be needed to close an accepted stroke.
        let savedFinishInput = docA.onWillChangeLayers
        docA.onWillChangeLayers = nil
        let undoI = docA.undoInfo.undoCount
        let strokePoint = CGPoint(x: snapBase.minX + 4, y: snapBase.minY + 4)
        let black = EngineSession.Brush(size: 4, opacity: 1, red: 0, green: 0, blue: 0, pressureSize: false)
        docA.beginStroke(at: .init(x: strokePoint.x, y: strokePoint.y, pressure: 1), brush: black)
        docA.continueStroke([.init(x: strokePoint.x + 1, y: strokePoint.y, pressure: 1)])
        var orderedMove: Result<Void, Error>?
        docA.moveFloatingSelection(by: CGSize(width: 3, height: 2)) { orderedMove = $0 }
        settle(docA)
        docA.onWillChangeLayers = savedFinishInput
        check(orderedMove != nil && docA.undoInfo.undoCount == undoI + 2,
              "the accepted stroke and the queued floating move each landed as one undo, in order")
        check(floatingBounds(docA, stateA) == snapBase.offsetBy(dx: 3, dy: 2),
              "the queued move landed behind the accepted stroke input")
        check((pixel(session, imageA, x: Int(strokePoint.x) + 3, y: Int(strokePoint.y) + 2)?[0] ?? 255) < 30,
              "the stroke pixels moved with the floating layer")

        // MARK: Stale same-id: a Detach that converted the id refuses the captured move

        let staleState = try session.floatingSelection(imageA)
        guard staleState.isActive else { return check(false, "a floating selection is active before the stale test") }
        let staleLayerBounds = floatingBounds(docA, staleState)
        let undoStale = docA.undoInfo.undoCount
        // Detach natively, off the document's queue: the document cache
        // still shows the same id as the active floating selection.
        _ = try session.floatingCommand(.toLayer, image: imageA, expected: staleState.floating)
        errorsA.removeAll()
        var staleResult: Result<Void, Error>?
        docA.moveFloatingSelection(by: CGSize(width: 5, height: 5)) { staleResult = $0 }
        settle(docA)
        check(staleResult != nil && (try? session.floatingSelection(imageA))?.isActive == false,
              "the captured move is refused after the same id was detached to an ordinary layer")
        if case .failure = staleResult {} else { check(false, "the stale captured move reports a failure") }
        check(docA.undoInfo.undoCount == undoStale + 1 && floatingBounds(docA, staleState) == staleLayerBounds,
              "the refused move mutates nothing: the detached layer keeps its bounds and no extra undo appears")
        check(!errorsA.isEmpty, "the stale refusal is reported visibly")
        try docA.reload()
        check(!docA.floatingState.isActive, "a reload resyncs the cache to the detached reality")

        // MARK: Explicit Anchor / New Layer / Discard still work after moves

        let palette = LayersPaletteController()
        palette.retarget(to: docA)
        let paletteHost = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 160),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        paletteHost.isReleasedWhenClosed = false
        paletteHost.contentView = palette.view
        paletteHost.contentView?.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
        paletteHost.orderFront(nil)
        defer { paletteHost.close() }
        func paletteButton(_ label: String) -> NSButton? {
            palette.reload()
            palette.view.layoutSubtreeIfNeeded()
            guard let bar = descendant(of: palette.view, as: FloatingSelectionBar.self) else { return nil }
            return buttons(in: bar).first { $0.accessibilityLabel() == label }
        }

        // Anchor after a move: merged into the attached layer.
        selectAll(docA)
        let anchorState = pasteFloating(a, docA)
        guard anchorState.isActive, let anchorBounds = floatingBounds(docA, anchorState) else {
            return check(false, "a fresh floating selection exists for the anchor-after-move test")
        }
        var anchorMove: Result<Void, Error>?
        docA.moveFloatingSelection(by: CGSize(width: 4, height: 3)) { anchorMove = $0 }
        settle(docA)
        check(anchorMove != nil && floatingBounds(docA, anchorState) == anchorBounds.offsetBy(dx: 4, dy: 3),
              "a captured floating move is accepted before anchoring")
        let anchorButton = paletteButton("Anchor floating selection")
        check(anchorButton != nil && anchorButton?.isEnabled == true,
              "the palette's Anchor control (by accessibility label) enables after a move")
        anchorButton?.performClick(nil)
        settle(docA)
        check((try? session.floatingSelection(imageA))?.isActive == false && !docA.floatingState.isActive
                && (pixel(session, imageA, x: Int(anchorBounds.minX) + 6, y: Int(anchorBounds.minY) + 5)?[1] ?? 255) == 0,
              "Anchor after a move merges the moved floating pixels into the target")

        // New Layer after a move: the same id becomes an ordinary layer.
        selectAll(docA)
        let toLayerState = pasteFloating(a, docA)
        guard toLayerState.isActive else { return check(false, "a fresh floating selection exists for the new-layer test") }
        if let right = keyEvent(windowA, keyCode: 124, characters: "\u{F703}") { canvasA.keyDown(with: right) }
        settle(docA)
        let newLayerButton = paletteButton("New layer from floating selection")
        check(newLayerButton != nil && newLayerButton?.isEnabled == true,
              "the palette's New Layer control enables for a layer attachment after a nudge")
        newLayerButton?.performClick(nil)
        settle(docA)
        check((try? session.floatingSelection(imageA))?.isActive == false
                && docA.layers.contains(where: { $0.id == toLayerState.floating }),
              "New Layer after a move converts the same id to an ordinary layer")

        // Discard after a move: the target pixels stay untouched.
        selectAll(docA)
        let targetBeforeDiscard = try session.copyPixels(imageA, merged: true).pixels
        let discardState = pasteFloating(a, docA)
        guard discardState.isActive, let discardBounds = floatingBounds(docA, discardState) else {
            return check(false, "a fresh floating selection exists for the discard test")
        }
        var discardMove: Result<Void, Error>?
        docA.moveFloatingSelection(by: CGSize(width: 5, height: 5)) { discardMove = $0 }
        settle(docA)
        check(discardMove != nil && floatingBounds(docA, discardState) == discardBounds.offsetBy(dx: 5, dy: 5),
              "a captured floating move is accepted before discarding")
        let discardButton = paletteButton("Discard floating selection")
        check(discardButton != nil && discardButton?.isEnabled == true,
              "the palette's Discard control enables after a move")
        discardButton?.performClick(nil)
        settle(docA)
        let pixelsAfterDiscard = try session.copyPixels(imageA, merged: true).pixels
        check((try? session.floatingSelection(imageA))?.isActive == false
                && pixelsAfterDiscard == targetBeforeDiscard,
              "Discard after a move removes the floating layer and reveals the untouched target")

        // Mask/channel attachments retain both their identity and target
        // pixels while their floating pixels move. Discard still works.
        guard let maskOwner = docA.activeLayer else { return check(false, "mask-move fixture has a layer") }
        docA.addMask(maskOwner, source: .white, edit: true)
        settle(docA)
        for kind in [EngineSession.FloatingTargetKind.layerMask, .channel] {
            if kind == .channel {
                docA.saveSelectionToChannel(name: "Floating Move Channel")
                settle(docA)
                guard let channel = docA.channels.first(where: { !$0.isQuickMask }) else {
                    return check(false, "channel-move fixture has a channel")
                }
                docA.selectChannel(channel.id)
                settle(docA)
            }
            guard let target = docA.activeDrawable else { return check(false, "attachment has an edit target") }
            // Thumbnails include the floating effect; baseline must precede
            // Paste Into when comparing the target after Discard.
            let targetBefore = try session.drawableThumbnail(target, image: imageA, maxSize: 64)
                .flatMap { $0.dataProvider?.data as Data? }
            let attachedState = pasteFloating(a, docA)
            guard attachedState.isActive, attachedState.targetKind == kind, attachedState.target == target,
                  let attachedBounds = floatingBounds(docA, attachedState) else {
                return check(false, "a floating selection attaches to the \(kind) move target")
            }
            let selectedBefore = try session.selectionBounds(image: imageA)
            let undoBefore = docA.undoInfo.undoCount
            var attachedMove: Result<Void, Error>?
            docA.moveFloatingSelection(by: CGSize(width: 2, height: -3)) { attachedMove = $0 }
            settle(docA)
            let moved = attachedBounds.offsetBy(dx: 2, dy: -3)
            check(attachedMove.map { if case .success = $0 { return true }; return false } == true
                    && floatingBounds(docA, attachedState) == moved
                    && docA.undoInfo.undoCount == undoBefore + 1,
                  "moving the \(kind)-attached floating selection changes its bounds as one undo")
            check(try session.floatingSelection(imageA) == attachedState
                    && session.selectionBounds(image: imageA) == selectedBefore,
                  "the \(kind) move preserves attachment and selection")
            docA.undo()
            settle(docA)
            check(floatingBounds(docA, attachedState) == attachedBounds,
                  "Undo restores the \(kind)-attached floating bounds")
            docA.redo()
            settle(docA)
            check(floatingBounds(docA, attachedState) == moved,
                  "Redo restores the \(kind)-attached floating move")
            paletteButton("Discard floating selection")?.performClick(nil)
            settle(docA)
            let targetAfter = try session.drawableThumbnail(attachedState.target, image: imageA, maxSize: 64)
                .flatMap { $0.dataProvider?.data as Data? }
            check(targetBefore != nil && targetAfter == targetBefore && !docA.floatingState.isActive,
                  "Discard after the \(kind) move leaves the attached target pixels untouched")
        }

        // MARK: Close drains an accepted floating move before destroying the image

        selectAll(docA)
        let drainState = pasteFloating(a, docA)
        guard drainState.isActive else { return check(false, "a floating selection exists for the close-drain test") }
        var drainResult: Result<Void, Error>?
        let workBeforeDrain = docA.pendingWork
        docA.moveFloatingSelection(by: CGSize(width: 2, height: 1)) { drainResult = $0 }
        check(docA.pendingWork > workBeforeDrain, "an accepted floating move is counted as pending work")
        var closedA = false
        docA.closeImageWhenDrained { closedA = true }
        wait { closedA }
        check(closedA && drainResult != nil && (try? session.info(imageA)) == nil,
              "close drains the accepted floating move before the image is destroyed, and its callback still lands")
        documents.items.removeAll { $0 === docA }

        // MARK: Window close cancels B's floating drag; a late release commits nothing

        let undoC = docB.undoInfo.undoCount
        let cBase = floatingBounds(docB, stateB) ?? fsBoundsB
        let cMid = CGPoint(x: cBase.midX, y: cBase.midY)
        let cEnd = CGPoint(x: cMid.x + 15, y: cMid.y + 8)
        guard let cDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: cMid, canvasB), windowB),
              let cDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: cEnd, canvasB), windowB),
              let cUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: cEnd, canvasB), windowB) else {
            return check(false, "the close-test events build")
        }
        canvasB.mouseDown(with: cDown)
        canvasB.mouseDragged(with: cDrag)
        check(canvasB.tools.floatingMove != nil && !canvasB.tools.floatingMove!.cancelled,
              "B's floating drag is active before the close")
        b.window?.close()
        spin(0.2)
        check(canvasB.tools.floatingMove?.cancelled == true, "window close cancels the floating drag and clears the preview")
        canvasB.mouseUp(with: cUp)
        settle(docB)
        check(floatingBounds(docB, stateB) == cBase && docB.undoInfo.undoCount == undoC,
              "a late release after the close commits nothing")
    }
}
