import AppKit
import RigiUI

// MARK: - GLIMS_SMOKE_CASE=snapping

@MainActor
extension EngineSmokeTest {
    /// View ▸ Snap To and Move-layer snapping, end to end through the real
    /// canvas event path: menu wiring and per-window defaults, a snapped
    /// move at zoom + scroll committing once as one undo step, disabled
    /// independence across two windows, Escape/close cancellation with no
    /// mutation, guide-hit first priority under the Move tool, refusal when
    /// the target or the captured bounds changed before the commit, and the
    /// overlay never changing exported pixels.
    static func exerciseSnapping(_ session: EngineSession, work: URL,
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
        func keyEvent(_ window: NSWindow, keyCode: Int, characters: String) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(keyCode))
        }
        // An image point to its window location through the canvas's own
        // conversion (the path the gesture handlers use).
        func windowPoint(ofImagePoint p: CGPoint, _ canvas: EngineCanvasView) -> CGPoint {
            canvas.convert(CGPoint(x: p.x * canvas.scale, y: p.y * canvas.scale), to: nil)
        }
        func bitmap(_ canvas: EngineCanvasView) -> Data? {
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            guard let bytes = rep.bitmapData else { return nil }
            return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
        }

        let imageA = try session.newImage(width: 400, height: 300)
        let imageB = try session.newImage(width: 120, height: 90)
        let docA = try ImageDocument(session: session, image: imageA, name: "Snap A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Snap B")
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
                controller.window?.close()
                documents.items.removeAll { $0 === document }
                document.closeImageWhenDrained()
            }
        }
        guard let windowA = a.window, let windowB = b.window else {
            return check(false, "the snapping windows exist")
        }
        let canvasA = a.canvas, canvasB = b.canvas
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        func layout() {
            a.window?.contentView?.layoutSubtreeIfNeeded()
            b.window?.contentView?.layoutSubtreeIfNeeded()
            spin(0.05)
        }
        // A small movable layer and a separate "other" layer, plus a
        // vertical guide, all through cached document state.
        let movingID = try session.addTextLayer(image: imageA, text: "Snap", settings: .init(),
                                                at: CGPoint(x: 40, y: 30))
        let otherID = try session.addTextLayer(image: imageA, text: "Other", settings: .init(),
                                               at: CGPoint(x: 300, y: 200))
        try docA.reload()
        docA.selectLayer(movingID)
        settle(docA)
        docA.addGuide(.vertical, at: 200)
        settle(docA)
        func movingBounds() -> CGRect? {
            docA.layers.first(where: { $0.id == movingID })?.bounds
        }
        func otherBounds() -> CGRect? {
            docA.layers.first(where: { $0.id == otherID })?.bounds
        }
        guard let startBounds = movingBounds(), let other = otherBounds(),
              startBounds.width > 0, startBounds.height > 0,
              docA.activeLayer == movingID,
              docA.guides.contains(where: { $0.orientation == .vertical && $0.position == 200 }) else {
            return check(false, "the snapping fixture has a movable layer, an other layer and a guide")
        }
        ToolState.shared.select(.move)
        let pixelsBefore = try session.copyPixels(imageA, merged: true).pixels
        let exportBeforeURL = work.appendingPathComponent("snap-before.png")
        let exportMidURL = work.appendingPathComponent("snap-mid.png")
        try session.export(imageA, to: exportBeforeURL.path)

        // MARK: Menu wiring and per-window defaults

        let view = MainMenu.make().items.first { $0.title == "View" }?.submenu
        let snapTo = view?.items.first { $0.title == "Snap To" }?.submenu
        check(snapTo?.items.map { $0.title } == ["Guides", "Grid", "Canvas", "Layer Bounds"],
              "View offers Snap To with Guides, Grid, Canvas and Layer Bounds")
        check(snapTo?.items.allSatisfy { $0.keyEquivalent.isEmpty } == true,
              "the Snap To items carry no new keyboard shortcut")
        check(snapTo?.items.map { $0.action } == [
            #selector(DocumentWindowController.toggleSnapToGuides(_:)),
            #selector(DocumentWindowController.toggleSnapToGrid(_:)),
            #selector(DocumentWindowController.toggleSnapToCanvas(_:)),
            #selector(DocumentWindowController.toggleSnapToLayerBounds(_:))],
              "the Snap To items sit on the document's own selectors")
        let guideItem = NSMenuItem(title: "Guides", action: #selector(DocumentWindowController.toggleSnapToGuides(_:)), keyEquivalent: "")
        let gridItem = NSMenuItem(title: "Grid", action: #selector(DocumentWindowController.toggleSnapToGrid(_:)), keyEquivalent: "")
        let canvasItem = NSMenuItem(title: "Canvas", action: #selector(DocumentWindowController.toggleSnapToCanvas(_:)), keyEquivalent: "")
        let layerItem = NSMenuItem(title: "Layer Bounds", action: #selector(DocumentWindowController.toggleSnapToLayerBounds(_:)), keyEquivalent: "")
        check([guideItem, gridItem, canvasItem, layerItem].allSatisfy {
            a.validateMenuItem($0) && $0.state == .off },
              "every Snap To entry validates enabled and OFF by default")
        check(canvasA.snapTo.isEmpty && canvasA.snapTo.targets.isEmpty
                && canvasB.snapTo.isEmpty,
              "both windows start with snapping fully off")

        // MARK: Canvas entry on window A only; window B stays independent

        a.toggleSnapToCanvas(canvasItem)
        check(canvasA.snapTo.canvas && canvasA.snapTo.targets == [.imageEdge, .imageCenter]
                && canvasItem.state == .on,
              "the Canvas entry maps to the image edge and centre")
        check(canvasB.snapTo.isEmpty, "toggling window A leaves window B off")
        let canvasItemB = NSMenuItem(title: "Canvas", action: #selector(DocumentWindowController.toggleSnapToCanvas(_:)), keyEquivalent: "")
        check(b.validateMenuItem(canvasItemB) && canvasItemB.state == .off && !canvasB.snapTo.canvas,
              "window B's Canvas entry still validates off")

        // MARK: The Command temporary-move modifier still snaps (no new shortcut)

        var undoA = docA.undoInfo.undoCount
        let cmdDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: startBounds.midX, y: startBounds.midY), canvasA),
                           windowA, flags: [.command])
        guard let cmdDown else { return check(false, "the Command-press event builds") }
        canvasA.mouseDown(with: cmdDown)
        check(canvasA.tools.moveSnap != nil && !canvasA.tools.moveSnap!.cancelled,
              "a Command temporary-Move press captures the snapping drag")
        let cmdEscape = keyEvent(windowA, keyCode: 53, characters: "\u{1b}")
        let cmdUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: startBounds.midX + 9, y: startBounds.midY), canvasA), windowA)
        if let cmdEscape { canvasA.keyDown(with: cmdEscape) }
        if let cmdUp { canvasA.mouseUp(with: cmdUp) }
        settle(docA)
        check(canvasA.tools.moveSnap == nil && docA.undoInfo.undoCount == undoA && movingBounds() == startBounds,
              "Escape after a Command press cancels with no mutation")

        // MARK: A guide hit keeps first priority under the Move tool

        let guideDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: 200, y: 100), canvasA), windowA)
        let guideDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: CGPoint(x: 250, y: 100), canvasA), windowA)
        let guideUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 250, y: 100), canvasA), windowA)
        guard let guideDown, let guideDrag, let guideUp else { return check(false, "the guide-hit events build") }
        canvasA.mouseDown(with: guideDown)
        check(canvasA.guideDrag.isActive && canvasA.tools.moveSnap == nil,
              "a Move press on a guide starts the guide drag, never a layer move")
        canvasA.mouseDragged(with: guideDrag)
        canvasA.mouseUp(with: guideUp)
        wait { docA.pendingWork == 0 && docA.guides.contains(where: { $0.orientation == .vertical && $0.position == 250 }) }
        spin()
        settle(docA)
        check(docA.guides.contains(where: { $0.orientation == .vertical && $0.position == 250 })
                && docA.undoInfo.undoCount == undoA + 1 && movingBounds() == startBounds,
              "the guide drag commits the guide move (one undo) and leaves the layer unmoved")
        undoA = docA.undoInfo.undoCount

        // MARK: Window B with snapping off keeps the raw move (independence)

        let undoB = docB.undoInfo.undoCount
        let bDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: 10, y: 10), canvasB), windowB)
        let bDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: CGPoint(x: 15, y: 13), canvasB), windowB)
        let bUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 15, y: 13), canvasB), windowB)
        guard let bDown, let bDrag, let bUp else { return check(false, "window B's move events build") }
        canvasB.mouseDown(with: bDown)
        check(canvasB.tools.moveSnap == nil, "with every Snap To entry off no snap gesture is captured")
        canvasB.mouseDragged(with: bDrag)
        canvasB.mouseUp(with: bUp)
        settle(docB)
        let bBounds = docB.layers.first(where: { $0.id == docB.activeLayer })?.bounds
        check(bBounds == CGRect(x: 5, y: 3, width: 120, height: 90) && docB.undoInfo.undoCount == undoB + 1,
              "window B's move commits the raw dragged delta (5, 3), one undo")
        check(movingBounds() == startBounds && docA.undoInfo.undoCount == undoA,
              "window B's drag changed nothing in window A's document")

        // MARK: Escape cancels a snapping drag; the overlay changes no export pixels

        let settledBitmap = { () -> Data? in
            _ = try? canvasA.renderVisibleTilesNow()
            return bitmap(canvasA)
        }
        let beforeDrag = settledBitmap()
        let dragTo = CGPoint(x: startBounds.midX + 30, y: startBounds.midY + 12)
        let cancelDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: startBounds.midX, y: startBounds.midY), canvasA), windowA)
        let cancelDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: dragTo, canvasA), windowA)
        guard let cancelDown, let cancelDrag else { return check(false, "the cancel-drag events build") }
        canvasA.mouseDown(with: cancelDown)
        canvasA.mouseDragged(with: cancelDrag)
        check(canvasA.tools.moveSnap != nil && !canvasA.tools.moveSnap!.cancelled,
              "the drag captures a snapping gesture")
        check(docA.pendingWork == 0 && docA.undoInfo.undoCount == undoA,
              "mouseDragged makes no native call per event (no pending work, no undo)")
        check(try session.copyPixels(imageA, merged: true).pixels == pixelsBefore,
              "the in-progress preview changes no native pixels")
        try session.export(imageA, to: exportMidURL.path)
        let exportedBefore = try session.openImage(path: exportBeforeURL.path)
        let exportedMid = try session.openImage(path: exportMidURL.path)
        let exportedBeforePixels = try session.copyPixels(exportedBefore, merged: true)
        let exportedMidPixels = try session.copyPixels(exportedMid, merged: true)
        check(exportedBeforePixels.width == exportedMidPixels.width
                && exportedBeforePixels.height == exportedMidPixels.height
                && exportedBeforePixels.pixels == exportedMidPixels.pixels,
              "the snapped preview and indicators do not change decoded export pixels")
        try session.closeImage(exportedBefore)
        try session.closeImage(exportedMid)
        let midBitmap = settledBitmap()
        check(beforeDrag != nil && midBitmap != nil && midBitmap != beforeDrag,
              "the view bitmap does draw the move preview over the tiles")
        let cancelEscape = keyEvent(windowA, keyCode: 53, characters: "\u{1b}")
        let cancelUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: dragTo, canvasA), windowA)
        if let cancelEscape { canvasA.keyDown(with: cancelEscape) }
        check(canvasA.tools.moveSnap?.cancelled == true, "Escape marks the snap drag cancelled")
        check(settledBitmap() == beforeDrag, "Escape clears both the move outline and snap indicators before release")
        if let cancelUp { canvasA.mouseUp(with: cancelUp) }
        settle(docA)
        let pixelsAfterCancel = try session.copyPixels(imageA, merged: true).pixels
        check(docA.undoInfo.undoCount == undoA && movingBounds() == startBounds
                && pixelsAfterCancel == pixelsBefore,
              "a cancelled move commits nothing: no bounds, undo or pixel change")

        // MARK: Refusal when the target or the captured bounds changed before the commit

        // (a) The active layer changed mid-drag.
        let staleDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: startBounds.midX, y: startBounds.midY), canvasA), windowA)
        guard let staleDown else { return check(false, "the stale-target press builds") }
        canvasA.mouseDown(with: staleDown)
        check(canvasA.tools.moveSnap != nil, "the press captured the moving layer")
        docA.selectLayer(otherID)
        settle(docA)
        let staleDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: dragTo, canvasA), windowA)
        let staleUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: dragTo, canvasA), windowA)
        if let staleDrag { canvasA.mouseDragged(with: staleDrag) }
        if let staleUp { canvasA.mouseUp(with: staleUp) }
        settle(docA)
        check(movingBounds() == startBounds && docA.undoInfo.undoCount == undoA,
              "a target change before the release refuses the commit (no stale retarget)")
        docA.selectLayer(movingID)
        settle(docA)

        // (b) The captured bounds changed mid-drag (another move landed).
        let stale2Down = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: startBounds.midX, y: startBounds.midY), canvasA), windowA)
        guard let stale2Down, let captured2 = movingBounds() else { return check(false, "the stale-bounds press builds") }
        canvasA.mouseDown(with: stale2Down)
        docA.moveActiveLayer(by: CGSize(width: 7, height: 0))
        settle(docA)
        let afterDirect = movingBounds()
        check(afterDirect == captured2.offsetBy(dx: 7, dy: 0), "the direct move landed first")
        let stale2Drag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: dragTo, canvasA), windowA)
        let stale2Up = mouse(.leftMouseUp, windowPoint(ofImagePoint: dragTo, canvasA), windowA)
        if let stale2Drag { canvasA.mouseDragged(with: stale2Drag) }
        if let stale2Up { canvasA.mouseUp(with: stale2Up) }
        settle(docA)
        check(movingBounds() == afterDirect && docA.undoInfo.undoCount == undoA + 1,
              "changed captured bounds refuse the drag's commit (only the direct move counts)")
        undoA = docA.undoInfo.undoCount

        // MARK: Snapped move at 400% zoom, scrolled — one commit, one undo

        a.zoom(to: 400)
        layout()
        let clipA = a.scrollView.contentView
        clipA.scroll(to: NSPoint(x: 100, y: 80))
        layout()
        check(abs(clipA.bounds.origin.x - 100) < 1e-6 && abs(clipA.bounds.origin.y - 80) < 1e-6,
              "the zoomed fixture actually scrolls")
        guard let base = movingBounds() else { return check(false, "the layer bounds exist for the snapped move") }
        let tol = CanvasSnapPlanner.defaultViewPointTolerance / canvasA.scale
        // Drag so the trailing edge lands 0.75 * tol short of the image's
        // max edge: inside the tolerance, so Canvas snapping pulls it to 400.
        let rawDX = (400 - 0.75 * tol) - base.maxX
        let rawDY = 40.0
        let press = CGPoint(x: base.midX, y: base.midY)
        let release = CGPoint(x: base.midX + rawDX, y: base.midY + rawDY)
        let snapDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: press, canvasA), windowA)
        let snapDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: release, canvasA), windowA)
        let snapUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: release, canvasA), windowA)
        guard let snapDown, let snapDrag, let snapUp else { return check(false, "the snapped-move events build") }
        canvasA.mouseDown(with: snapDown)
        canvasA.mouseDragged(with: snapDrag)
        let gesture = canvasA.tools.moveSnap
        check(gesture != nil && !gesture!.cancelled, "the zoomed drag captured a snap gesture")
        check(gesture?.plan.x?.anchor == .trailing && gesture?.plan.x?.target == .imageEdge
                && gesture?.plan.x?.targetCoordinate == 400,
              "at 400% + scroll the trailing edge snaps to the image max edge at x=400")
        check(gesture?.plan.y == nil, "the y axis finds no candidate within tolerance")
        check(gesture.map { abs($0.proposed.maxX - 400) < 1e-9 } == true,
              "the local preview rect lands exactly on the matched line")
        check(docA.pendingWork == 0 && docA.undoInfo.undoCount == undoA,
              "the zoomed drag still makes no native call per event")
        canvasA.mouseUp(with: snapUp)
        wait { docA.pendingWork == 0 && docA.undoInfo.undoCount == undoA + 1 }
        spin()
        settle(docA)
        let snapped = movingBounds()
        check(snapped != nil && abs(snapped!.maxX - 400) <= 0.5 + 1e-9
                && abs(snapped!.minY - (base.minY + rawDY)) <= 0.5 + 1e-9,
              "the release commits once with the snapped bounds (maxX at the image edge)")
        check(docA.undoInfo.undoCount == undoA + 1 && canvasA.tools.moveSnap == nil,
              "the snapped move is exactly one undo step and the gesture clears")
        docA.undo()
        wait { docA.pendingWork == 0 && movingBounds() == base }
        spin()
        settle(docA)
        check(movingBounds() == base && docA.undoInfo.undoCount == undoA,
              "one undo restores the pre-move bounds")
        undoA = docA.undoInfo.undoCount
        a.zoom(to: 100)
        layout()

        // MARK: Layer Bounds entry snaps to another layer's edge

        a.toggleSnapToLayerBounds(layerItem)
        check(canvasA.snapTo.layerBounds && canvasA.snapTo.targets.contains(.layerEdge)
                && canvasA.snapTo.targets.contains(.layerCenter),
              "the Layer Bounds entry maps to other layers' edges and centres")
        guard let base2 = movingBounds() else { return check(false, "the layer bounds exist for the layer-bounds move") }
        let tol2 = CanvasSnapPlanner.defaultViewPointTolerance / canvasA.scale
        // Drag so the leading edge lands 0.4 * tol short of the other
        // layer's leading edge.
        let rawDX2 = (other.minX - 0.4 * tol2) - base2.minX
        let press2 = CGPoint(x: base2.midX, y: base2.midY)
        let release2 = CGPoint(x: base2.midX + rawDX2, y: base2.midY)
        let lbDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: press2, canvasA), windowA)
        let lbDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: release2, canvasA), windowA)
        let lbUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: release2, canvasA), windowA)
        guard let lbDown, let lbDrag, let lbUp else { return check(false, "the layer-bounds events build") }
        canvasA.mouseDown(with: lbDown)
        canvasA.mouseDragged(with: lbDrag)
        let lbGesture = canvasA.tools.moveSnap
        check(lbGesture?.plan.x?.target == .layerEdge && lbGesture?.plan.x?.targetCoordinate == other.minX,
              "the leading edge snaps to the other layer's edge (the moving layer is excluded)")
        canvasA.mouseUp(with: lbUp)
        wait { docA.pendingWork == 0 && docA.undoInfo.undoCount == undoA + 1 }
        spin()
        settle(docA)
        let lbResult = movingBounds()
        check(lbResult != nil && abs(lbResult!.minX - other.minX) <= 0.5 + 1e-9
                && docA.undoInfo.undoCount == undoA + 1,
              "the Layer Bounds move commits once onto the other layer's edge")
        undoA = docA.undoInfo.undoCount
        a.toggleSnapToLayerBounds(layerItem)

        // A detached canvas cannot capture a valid window-bound snap.
        // Its late synthetic events must never fall back to moving the
        // document's newly selected layer.
        let detached = EngineCanvasView(document: docA)
        detached.snapTo = canvasA.snapTo
        if detached.snapTo.isEmpty { detached.snapTo.toggle(.canvas) }
        let unavailableDown = mouse(.leftMouseDown, CGPoint(x: 22, y: 22), windowA)
        let unavailableUp = mouse(.leftMouseUp, CGPoint(x: 32, y: 29), windowA)
        if let unavailableDown, let unavailableUp {
            detached.tools.mouseDown(with: unavailableDown)
            docA.selectLayer(otherID)
            settle(docA)
            let untouched = otherBounds()
            let undoUnavailable = docA.undoInfo.undoCount
            detached.tools.mouseUp(with: unavailableUp)
            settle(docA)
            check(otherBounds() == untouched && docA.undoInfo.undoCount == undoUnavailable,
                  "an unavailable snap capture refuses instead of moving a later target")
            if docA.undoInfo.undoCount != undoUnavailable { docA.undo(); settle(docA) }
            docA.selectLayer(movingID)
            settle(docA)
        } else { check(false, "the unavailable-capture events build") }
        var detachedStopped = false
        detached.stopRendering { detachedStopped = true }
        wait { detachedStopped }

        // MARK: Window close cancels; late events commit nothing

        guard let finalBounds = movingBounds() else { return check(false, "the final bounds exist") }
        let closeDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: finalBounds.midX, y: finalBounds.midY), canvasA), windowA)
        let closeDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: CGPoint(x: finalBounds.midX + 25, y: finalBounds.midY + 5), canvasA), windowA)
        guard let closeDown, let closeDrag else { return check(false, "the close-test events build") }
        canvasA.mouseDown(with: closeDown)
        canvasA.mouseDragged(with: closeDrag)
        check(canvasA.tools.moveSnap != nil && !canvasA.tools.moveSnap!.cancelled,
              "the gesture is active before the close")
        a.window?.close()
        spin(0.2)
        check(canvasA.tools.moveSnap?.cancelled == true,
              "window close cancels the snap drag and clears the preview")
        let lateUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: finalBounds.midX + 25, y: finalBounds.midY + 5), canvasA), windowA)
        if let lateUp { canvasA.mouseUp(with: lateUp) }
        settle(docA)
        check(movingBounds() == finalBounds && docA.undoInfo.undoCount == undoA,
              "late events after the close commit nothing")
    }
}
