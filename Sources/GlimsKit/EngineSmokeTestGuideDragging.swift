import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    static func exerciseGuideDragging(_ session: EngineSession, work: URL,
                                              documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        // Recursive lookup that keeps the root when it matches the queried
        // type AND still descends into its children.
        func views<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            var found: [T] = []
            if let match = root as? T { found.append(match) }
            for subview in root.subviews { found += views(subview, as: type) }
            return found
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

        let imageA = try session.newImage(width: 400, height: 300)
        let imageB = try session.newImage(width: 120, height: 90)
        let docA = try ImageDocument(session: session, image: imageA, name: "Guide drag A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Guide drag B")
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
            return check(false, "the guide-drag windows exist")
        }
        let canvasA = a.canvas, canvasB = b.canvas
        let scrollA = a.scrollView
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        func layout() {
            a.window?.contentView?.layoutSubtreeIfNeeded()
            spin(0.05)
        }
        // An image point to its window location through the canvas's own
        // conversion (the path the gesture handlers use).
        func windowPoint(ofImagePoint p: CGPoint, _ canvas: EngineCanvasView) -> CGPoint {
            canvas.convert(CGPoint(x: p.x * canvas.scale, y: p.y * canvas.scale), to: nil)
        }
        // Independent oracle: plain frame arithmetic down the view chain
        // (window content -> scroll view -> clip view + scroll offset),
        // not NSView.convert to the canvas.
        func oracleImagePoint(_ location: CGPoint, scroll: NSScrollView, canvas: EngineCanvasView) -> CGPoint {
            var chain: [NSView] = []
            var current: NSView? = canvas
            while let view = current { chain.append(view); current = view.superview }
            var point = location
            for view in chain.reversed() {
                let sx = view.frame.width / view.bounds.width
                let sy = view.frame.height / view.bounds.height
                guard sx.isFinite, sy.isFinite, sx > 0, sy > 0 else {
                    return CGPoint(x: Double.nan, y: Double.nan)
                }
                point.x = view.bounds.minX + (point.x - view.frame.minX) / sx
                if view.isFlipped != (view.superview?.isFlipped ?? false) {
                    point.y = view.bounds.minY + (view.frame.maxY - point.y) / sy
                } else {
                    point.y = view.bounds.minY + (point.y - view.frame.minY) / sy
                }
            }
            return CGPoint(x: point.x / canvas.scale, y: point.y / canvas.scale)
        }
        // A row of the canvas's own view bitmap: does the dashed orange
        // ghost line cross it at this image y?
        func canvasRowShowsGhost(_ canvas: EngineCanvasView, imageY: Double) -> Bool {
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return false }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            let factor = Double(rep.pixelsWide) / Double(canvas.bounds.width)
            let row = Int(imageY * canvas.scale * factor)
            guard row >= 0, row < rep.pixelsHigh else { return false }
            // A one-device-pixel antialiased line can straddle rows.
            for y in max(0, row - 1)...min(rep.pixelsHigh - 1, row + 1) {
                for x in stride(from: 4, to: rep.pixelsWide - 4, by: 3) {
                    guard let c = rep.colorAt(x: x, y: y) else { continue }
                    if c.redComponent - c.blueComponent > 0.3 && c.greenComponent - c.blueComponent > 0.1 {
                        return true
                    }
                }
            }
            return false
        }

        guard let hRuler = scrollA.horizontalRulerView as? PixelRulerView,
              let vRuler = scrollA.verticalRulerView as? PixelRulerView else {
            return check(false, "the scroll view's native ruler slots hold the pixel rulers")
        }
        // Accessibility: meaningful labels and help on both rulers.
        check(hRuler.accessibilityLabel() == "Horizontal ruler" && vRuler.accessibilityLabel() == "Vertical ruler",
              "the rulers keep their accessibility labels")
        check((hRuler.accessibilityHelp() ?? "").contains("horizontal guide")
                && (vRuler.accessibilityHelp() ?? "").contains("vertical guide")
                && (hRuler.accessibilityHelp() ?? "").contains("Escape"),
              "the rulers carry help describing the drag gesture and Escape cancel")
        // Recursive view lookup, including children when the root matches.
        let rulersInWindow = views(windowA.contentView, as: PixelRulerView.self)
        check(rulersInWindow.count == 2 && rulersInWindow.contains(hRuler) && rulersInWindow.contains(vRuler),
              "a recursive lookup finds both pixel rulers in the window")
        check(views(scrollA, as: NSView.self).count > 3 && views(scrollA, as: NSView.self).contains(scrollA),
              "the recursive lookup includes the root itself and still descends into children")

        let pixelsBefore = try session.copyPixels(imageA, merged: true).pixels
        var undoA = docA.undoInfo.undoCount
        let undoB = docB.undoInfo.undoCount

        // MARK: Ruler drags create matching guides at the dropped image pixel

        // Horizontal ruler -> horizontal guide at the drop's image y (100%).
        let downH = mouse(.leftMouseDown, hRuler.convert(CGPoint(x: 100, y: 5), to: nil), windowA)
        let dragH = mouse(.leftMouseDragged, windowPoint(ofImagePoint: CGPoint(x: 30, y: 118), canvasA), windowA)
        let upH = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 30, y: 120), canvasA), windowA)
        guard let downH, let dragH, let upH else { return check(false, "the ruler drag events build") }
        hRuler.mouseDown(with: downH)
        check(canvasA.guideDrag.isActive, "a press on the horizontal ruler begins a guide gesture")
        hRuler.mouseDragged(with: dragH)
        check(abs((canvasA.guideDrag.gesture?.position ?? .nan) - 118) < 1e-9,
              "the ghost tracks the drag in image pixels on the guide's axis")
        check(docA.guides.isEmpty && docA.undoInfo.undoCount == undoA && docA.pendingWork == 0,
              "mouseDragged makes no native guide call per event (cached state only)")
        hRuler.mouseUp(with: upH)
        wait { docA.pendingWork == 0 && docA.guides.count == 1 }
        spin()
        settle(docA)
        check(docA.guides.count == 1 && docA.guides[0].orientation == .horizontal && docA.guides[0].position == 120,
              "a horizontal ruler drag commits one horizontal guide at the dropped image y")
        check(docA.undoInfo.undoCount == undoA + 1, "the creation is exactly one undo step")
        check(!canvasA.guideDrag.isActive, "the gesture is cleared after the commit")
        undoA = docA.undoInfo.undoCount

        // Vertical ruler -> vertical guide at the drop's image x (100%).
        let downV = mouse(.leftMouseDown, vRuler.convert(CGPoint(x: 5, y: 60), to: nil), windowA)
        let upV = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 200, y: 40), canvasA), windowA)
        guard let downV, let upV else { return check(false, "the vertical ruler drag events build") }
        vRuler.mouseDown(with: downV)
        vRuler.mouseUp(with: upV)
        wait { docA.pendingWork == 0 && docA.guides.contains(where: { $0.orientation == .vertical && $0.position == 200 }) }
        spin()
        settle(docA)
        check(docA.guides.count == 2 && docA.guides.contains(where: { $0.orientation == .vertical && $0.position == 200 }),
              "a vertical ruler drag commits one vertical guide at the dropped image x")
        check(docA.undoInfo.undoCount == undoA + 1, "the second creation is one more undo step")
        undoA = docA.undoInfo.undoCount
        check(try session.copyPixels(imageA, merged: true).pixels == pixelsBefore,
              "guide creation leaves the native render pixels unchanged")

        // MARK: Zoom + scroll + backing geometry against the independent oracle

        a.zoom(to: 800)
        layout()
        let clip = scrollA.contentView
        clip.scroll(to: NSPoint(x: 100, y: 80))
        layout()
        check(abs(clip.bounds.origin.x - 100) < 1e-6 && abs(clip.bounds.origin.y - 80) < 1e-6,
              "the zoomed fixture actually scrolls")
        let target = CGPoint(x: 55.5, y: 150.4)
        let targetWindow = windowPoint(ofImagePoint: target, canvasA)
        let oracle = oracleImagePoint(targetWindow, scroll: scrollA, canvas: canvasA)
        check(abs(oracle.x - target.x) < 1e-6 && abs(oracle.y - target.y) < 1e-6,
              "at 800% zoom, scrolled, the independent frame-arithmetic oracle agrees with the canvas conversion (\(oracle) vs \(target))")

        // MARK: View-only ghost in the canvas bitmap; Escape cancels

        try canvasA.renderVisibleTilesNow()
        let ghostDown = mouse(.leftMouseDown, hRuler.convert(CGPoint(x: 220, y: 5), to: nil), windowA)
        let ghostDrag = mouse(.leftMouseDragged, targetWindow, windowA)
        let ghostUp = mouse(.leftMouseUp, targetWindow, windowA)
        guard let ghostDown, let ghostDrag, let ghostUp else { return check(false, "the ghost drag events build") }
        hRuler.mouseDown(with: ghostDown)
        hRuler.mouseDragged(with: ghostDrag)
        check(canvasA.guideDrag.isActive && abs((canvasA.guideDrag.gesture?.position ?? .nan) - 150.4) < 1e-6,
              "at 800% + scroll the ghost sits at the oracle's image y (fractional)")
        check(canvasRowShowsGhost(canvasA, imageY: 150.4) && !canvasRowShowsGhost(canvasA, imageY: 162.4),
              "the canvas view bitmap draws the dashed ghost line at the dragged row only")
        check(docA.guides.count == 2 && docA.undoInfo.undoCount == undoA && docA.pendingWork == 0,
              "the ghost changes no native metadata or history")
        check(try session.copyPixels(imageA, merged: true).pixels == pixelsBefore,
              "the ghost changes no native render pixels")
        // Escape through the canvas's key handler cancels; the release then commits nothing.
        guard let escape = keyEvent(windowA, keyCode: GuideDragLogic.escapeKeyCode, characters: "\u{1b}") else {
            return check(false, "the Escape key event builds")
        }
        canvasA.keyDown(with: escape)
        check(!canvasA.guideDrag.isActive, "Escape cancels the guide gesture and clears the ghost")
        hRuler.mouseUp(with: ghostUp)
        settle(docA)
        check(docA.guides.count == 2 && docA.undoInfo.undoCount == undoA,
              "a cancelled drag commits nothing (no guide, no undo)")
        check(try session.copyPixels(imageA, merged: true).pixels == pixelsBefore,
              "cancel leaves the native render pixels unchanged")

        // A committed drop at a fractional image coordinate rounds to the nearest pixel.
        let dropV = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 55.5, y: 20), canvasA), windowA)
        let downV2 = mouse(.leftMouseDown, vRuler.convert(CGPoint(x: 5, y: 200), to: nil), windowA)
        guard let dropV, let downV2 else { return check(false, "the zoomed ruler drag events build") }
        vRuler.mouseDown(with: downV2)
        vRuler.mouseUp(with: dropV)
        wait { docA.pendingWork == 0 && docA.guides.contains(where: { $0.orientation == .vertical && $0.position == 56 }) }
        spin()
        settle(docA)
        check(docA.guides.contains(where: { $0.orientation == .vertical && $0.position == 56 }),
              "a drop at image x=55.5 at 800% commits the vertical guide at x=56 (nearest pixel)")
        check(docA.undoInfo.undoCount == undoA + 1, "the zoomed creation is one undo step")
        undoA = docA.undoInfo.undoCount

        // MARK: Move tool: hit, move, same-position no-op, delete outside

        ToolState.shared.select(.move)
        guard let hGuide = docA.guides.first(where: { $0.orientation == .horizontal }) else {
            return check(false, "the horizontal guide exists for the Move-tool checks")
        }
        let moveDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: 30, y: 120), canvasA), windowA)
        let moveDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: CGPoint(x: 30, y: 180), canvasA), windowA)
        let moveUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 30, y: 180), canvasA), windowA)
        guard let moveDown, let moveDrag, let moveUp else { return check(false, "the move drag events build") }
        canvasA.mouseDown(with: moveDown)
        check(canvasA.guideDrag.isActive, "a Move-tool press on a visible guide begins a guide gesture")
        canvasA.mouseDragged(with: moveDrag)
        canvasA.mouseUp(with: moveUp)
        wait { docA.pendingWork == 0 && docA.guides.first(where: { $0.id == hGuide.id })?.position == 180 }
        spin()
        settle(docA)
        check(docA.guides.first(where: { $0.id == hGuide.id })?.position == 180
                && docA.guides.first(where: { $0.id == hGuide.id })?.orientation == .horizontal,
              "the Move tool drags the guide to y=180 keeping its identity and orientation")
        check(docA.undoInfo.undoCount == undoA + 1, "the move is exactly one undo step")
        undoA = docA.undoInfo.undoCount

        // A release at the guide's own position keeps the native no-op: no undo.
        let sameDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: 30, y: 180), canvasA), windowA)
        let sameUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 30, y: 180), canvasA), windowA)
        guard let sameDown, let sameUp else { return check(false, "the same-position events build") }
        canvasA.mouseDown(with: sameDown)
        canvasA.mouseUp(with: sameUp)
        settle(docA)
        check(docA.guides.first(where: { $0.id == hGuide.id })?.position == 180
                && docA.undoInfo.undoCount == undoA,
              "a move released at the same position is the native no-op (no undo)")

        // Dragging outside the image never deletes by itself; only the release does.
        let delDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: 30, y: 180), canvasA), windowA)
        let delDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: CGPoint(x: 30, y: -40), canvasA), windowA)
        let delUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 30, y: -40), canvasA), windowA)
        guard let delDown, let delDrag, let delUp else { return check(false, "the delete drag events build") }
        canvasA.mouseDown(with: delDown)
        canvasA.mouseDragged(with: delDrag)
        check(docA.guides.contains(where: { $0.id == hGuide.id }) && docA.undoInfo.undoCount == undoA,
              "merely moving the pointer outside the image does not remove the guide")
        canvasA.mouseUp(with: delUp)
        wait { docA.pendingWork == 0 && !docA.guides.contains(where: { $0.id == hGuide.id }) }
        spin()
        settle(docA)
        check(!docA.guides.contains(where: { $0.id == hGuide.id }) && docA.undoInfo.undoCount == undoA + 1,
              "an intentional release outside the image removes the existing guide (one undo step)")
        undoA = docA.undoInfo.undoCount

        // An ordinary Move-tool drag away from any guide still moves the layer.
        let layerBefore = docA.layers.first(where: { $0.id == docA.activeLayer })?.bounds
        let ordDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: 300, y: 250), canvasA), windowA)
        let ordDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: CGPoint(x: 320, y: 260), canvasA), windowA)
        let ordUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 320, y: 260), canvasA), windowA)
        guard let ordDown, let ordDrag, let ordUp, let layerBefore else {
            return check(false, "the ordinary move drag events build")
        }
        canvasA.mouseDown(with: ordDown)
        check(!canvasA.guideDrag.isActive, "a Move-tool press away from guides starts the ordinary layer move")
        canvasA.mouseDragged(with: ordDrag)
        canvasA.mouseUp(with: ordUp)
        settle(docA)
        let layerAfter = docA.layers.first(where: { $0.id == docA.activeLayer })?.bounds
        check(layerAfter != nil && abs(layerAfter!.minX - (layerBefore.minX + 20)) < 1e-6
                && abs(layerAfter!.minY - (layerBefore.minY + 10)) < 1e-6,
              "the ordinary Move-tool drag still moves the active layer by the dragged delta")
        undoA = docA.undoInfo.undoCount


        // MARK: Hidden guides are not hit; hidden rulers cannot start a drag

        let guidesItem = NSMenuItem(title: "Show Guides",
                                    action: #selector(DocumentWindowController.toggleShowGuides(_:)), keyEquivalent: "")
        a.toggleShowGuides(guidesItem)
        check(!canvasA.showsGuides, "Show Guides toggles the overlay off")
        let hiddenDown = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: 200, y: 50), canvasA), windowA)
        let hiddenUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 200, y: 50), canvasA), windowA)
        guard let hiddenDown, let hiddenUp else { return check(false, "the hidden-guide events build") }
        canvasA.mouseDown(with: hiddenDown)
        check(!canvasA.guideDrag.isActive, "a hidden guide cannot be grabbed by the Move tool")
        canvasA.mouseUp(with: hiddenUp)
        a.toggleShowGuides(guidesItem)
        settle(docA)
        check(docA.undoInfo.undoCount == undoA, "the hidden-guide click changed nothing")

        let rulersItem = NSMenuItem(title: "Show Rulers",
                                    action: #selector(DocumentWindowController.toggleShowRulers(_:)), keyEquivalent: "")
        a.toggleShowRulers(rulersItem)
        check(!scrollA.rulersVisible, "Show Rulers toggles the native slots off")
        let hiddenRulerDown = mouse(.leftMouseDown, hRuler.convert(CGPoint(x: 100, y: 5), to: nil), windowA)
        let hiddenRulerUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 30, y: 90), canvasA), windowA)
        guard let hiddenRulerDown, let hiddenRulerUp else { return check(false, "the hidden-ruler events build") }
        hRuler.mouseDown(with: hiddenRulerDown)
        check(!canvasA.guideDrag.isActive, "hidden rulers cannot begin a new guide drag")
        hRuler.mouseUp(with: hiddenRulerUp)
        settle(docA)
        check(docA.guides.count == 2 && docA.undoInfo.undoCount == undoA,
              "the hidden-ruler drag committed nothing")
        a.toggleShowRulers(rulersItem)
        layout()

        // MARK: Engine-busy guard (cached state; the gate releases on all paths)

        do {
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let held = EngineActivity.shared.perform(label: "Holding the engine for guide drag",
                                                     work: { gate.wait() }, completion: {})
            check(held, "the engine can be held busy")
            if held {
                let busyDown = mouse(.leftMouseDown, hRuler.convert(CGPoint(x: 100, y: 5), to: nil), windowA)
                let busyUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 30, y: 90), canvasA), windowA)
                if let busyDown, let busyUp {
                    hRuler.mouseDown(with: busyDown)
                    check(!canvasA.guideDrag.isActive, "a ruler press while the engine is busy starts no gesture")
                    hRuler.mouseUp(with: busyUp)
                } else {
                    check(false, "the busy-guard events build")
                }
            }
            gate.signal()
            wait { !EngineActivity.shared.isBusy }
            spin(0.05)
            settle(docA)
            check(docA.guides.count == 2 && docA.undoInfo.undoCount == undoA,
                  "the busy ruler drag committed nothing and added no undo")
        }

        // MARK: Tool change cancels mid-drag

        let cancelDown = mouse(.leftMouseDown, hRuler.convert(CGPoint(x: 100, y: 5), to: nil), windowA)
        let cancelUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 30, y: 90), canvasA), windowA)
        guard let cancelDown, let cancelUp else { return check(false, "the tool-change events build") }
        hRuler.mouseDown(with: cancelDown)
        check(canvasA.guideDrag.isActive, "the gesture is active before the tool change")
        ToolState.shared.select(.crop)
        check(!canvasA.guideDrag.isActive, "a tool change cancels the guide gesture and clears the ghost")
        hRuler.mouseUp(with: cancelUp)
        ToolState.shared.select(.move)
        settle(docA)
        check(docA.guides.count == 2 && docA.undoInfo.undoCount == undoA,
              "the tool-change-cancelled drag committed nothing")

        // MARK: Per-document isolation: the gesture cannot be redirected

        let isoDown = mouse(.leftMouseDown, hRuler.convert(CGPoint(x: 100, y: 5), to: nil), windowA)
        guard let isoDown else { return check(false, "the isolation press builds") }
        hRuler.mouseDown(with: isoDown)
        check(canvasA.guideDrag.isActive, "window A's gesture is active")
        // Events delivered to window B's ruler must not touch A's gesture or B's document.
        let scrollB = b.scrollView
        guard let vRulerB = scrollB.verticalRulerView as? PixelRulerView else {
            return check(false, "window B's vertical ruler exists")
        }
        let foreignDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: CGPoint(x: 20, y: 20), canvasB), windowB)
        let foreignUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 20, y: 20), canvasB), windowB)
        if let foreignDrag, let foreignUp {
            vRulerB.mouseDragged(with: foreignDrag)
            vRulerB.mouseUp(with: foreignUp)
        } else {
            check(false, "the foreign events build")
        }
        check(canvasA.guideDrag.isActive && docA.guides.count == 2 && docB.guides.isEmpty
                && docA.undoInfo.undoCount == undoA && docB.undoInfo.undoCount == undoB,
              "another window's ruler events neither redirect nor commit the gesture")
        let isoUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 60, y: 90), canvasA), windowA)
        guard let isoUp else { return check(false, "the isolation release builds") }
        hRuler.mouseUp(with: isoUp)
        wait { docA.pendingWork == 0 && docA.guides.contains(where: { $0.orientation == .horizontal && $0.position == 90 }) }
        spin()
        settle(docA)
        settle(docB)
        check(docA.guides.contains(where: { $0.orientation == .horizontal && $0.position == 90 })
                && docA.undoInfo.undoCount == undoA + 1 && docB.guides.isEmpty && docB.undoInfo.undoCount == undoB,
              "the release commits only to the gesture's own document and window")
        undoA = docA.undoInfo.undoCount

        // MARK: Exactly one-step Undo/Redo of a dragged-in guide

        docA.undo()
        wait { docA.pendingWork == 0 && !docA.guides.contains(where: { $0.orientation == .horizontal && $0.position == 90 }) }
        spin()
        settle(docA)
        check(!docA.guides.contains(where: { $0.orientation == .horizontal && $0.position == 90 })
                && docA.undoInfo.undoCount == undoA - 1,
              "Undo removes the dragged-in guide as one step")
        docA.redo()
        wait { docA.pendingWork == 0 && docA.guides.contains(where: { $0.orientation == .horizontal && $0.position == 90 }) }
        spin()
        settle(docA)
        check(docA.guides.contains(where: { $0.orientation == .horizontal && $0.position == 90 })
                && docA.undoInfo.undoCount == undoA,
              "Redo restores it at the dragged position as one step")

        // A drop outside the perpendicular edge is outside the image,
        // even when the guide's own axis coordinate is valid.
        let outsideCount = docA.guides.count
        let outsideUndo = docA.undoInfo.undoCount
        if let down = mouse(.leftMouseDown, hRuler.convert(CGPoint(x: 100, y: 5), to: nil), windowA),
           let up = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: -40, y: 60), canvasA), windowA) {
            hRuler.mouseDown(with: down)
            hRuler.mouseUp(with: up)
            settle(docA)
            check(docA.guides.count == outsideCount && docA.undoInfo.undoCount == outsideUndo,
                  "a new horizontal guide dropped past the image's left edge cancels")
            if docA.guides.count != outsideCount { docA.undo(); settle(docA) }
        } else { check(false, "the perpendicular outside-drop events build") }

        if let existing = docA.guides.first(where: { $0.orientation == .horizontal && $0.position == 90 }),
           let down = mouse(.leftMouseDown, windowPoint(ofImagePoint: CGPoint(x: 30, y: 90), canvasA), windowA),
           let up = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: -40, y: 90), canvasA), windowA) {
            let before = docA.undoInfo.undoCount
            canvasA.mouseDown(with: down)
            canvasA.mouseUp(with: up)
            settle(docA)
            check(!docA.guides.contains(where: { $0.id == existing.id }) && docA.undoInfo.undoCount == before + 1,
                  "an existing horizontal guide dropped past the image's left edge is removed in one step")
            docA.undo(); settle(docA)
        } else { check(false, "the existing guide perpendicular-drop fixture exists") }

        // MARK: Window close cancels; late events are ignored

        let closeDown = mouse(.leftMouseDown, hRuler.convert(CGPoint(x: 100, y: 5), to: nil), windowA)
        guard let closeDown else { return check(false, "the close-test press builds") }
        hRuler.mouseDown(with: closeDown)
        check(canvasA.guideDrag.isActive, "the gesture is active before the close")
        let guidesAtClose = docA.guides
        let undoAtClose = docA.undoInfo.undoCount
        a.window?.close()
        spin(0.2)
        check(!canvasA.guideDrag.isActive, "window close cancels the gesture and clears the ghost")
        // Late events after the close are ignored: no commit, no mutation.
        let lateDrag = mouse(.leftMouseDragged, windowPoint(ofImagePoint: CGPoint(x: 30, y: 70), canvasA), windowA)
        let lateUp = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 30, y: 70), canvasA), windowA)
        if let lateDrag, let lateUp {
            hRuler.mouseDragged(with: lateDrag)
            hRuler.mouseUp(with: lateUp)
        }
        settle(docA)
        check(docA.guides == guidesAtClose && docA.undoInfo.undoCount == undoAtClose,
              "late closed-window events are ignored: no guide action, no history change")
    }

}
