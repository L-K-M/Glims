import AppKit

// MARK: - GLIMS_SMOKE_CASE=view-overlays

@MainActor
extension EngineSmokeTest {
    /// `GLIMS_SMOKE_CASE=view-overlays` (wired into the full run by the
    /// shared dispatcher): View ▸ Show Selection Edges and View ▸ Show
    /// Layer Boundary as per-window cached display controls, driven
    /// through the real menu items and validation. Covers menu wiring and
    /// defaults, checkmarks from each window's cached state, two
    /// independent windows, availability and toggling while the engine is
    /// busy, hiding the edges over a nonempty selection (native bounds and
    /// the cached outline stay), the cached paint-target geometry for
    /// layer / mask / channel / floating targets, persistence through a
    /// document reload, and that toggling changes no undo step, pixel or
    /// file-dirty state. Boundary expectations use the pure cached helper's
    /// rectangles, never pixel-perfect screenshots; the renderer source
    /// (EngineCanvasView.draw) is the evidence for visual review.
    static func exerciseViewOverlays(_ session: EngineSession, work: URL,
                                     documents: DocumentList) throws {
        _ = work
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }

        let imageA = try session.newImage(width: 64, height: 48)
        let imageB = try session.newImage(width: 40, height: 30)
        // Distinguish the remembered layer from a channel's full-image
        // boundary. Equal full-size fixtures cannot detect that mistake.
        let smallLayer = ClipboardImage(width: 32, height: 28,
            pixels: Data(repeating: 255, count: 32 * 28 * 4), origin: .zero)
        _ = try session.pastePixels(imageA, pixels: smallLayer, at: CGPoint(x: 2, y: 3))
        let docA = try ImageDocument(session: session, image: imageA, name: "Overlays A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Overlays B")
        documents.items += [docA, docB]
        let a = DocumentWindowController(document: docA)
        let b = DocumentWindowController(document: docB)
        a.showWindow(nil)
        b.showWindow(nil)
        a.window?.contentView?.layoutSubtreeIfNeeded()
        b.window?.contentView?.layoutSubtreeIfNeeded()
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        defer {
            for (controller, document) in [(a, docA), (b, docB)] {
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
                controller.window?.close()
                document.inputQueue.sync {}
                documents.items.removeAll { $0 === document }
                guard !document.isClosing else { continue }
                var closed = false
                document.closeImageWhenDrained { closed = true }
                wait { closed }
            }
        }
        guard a.window != nil, b.window != nil else {
            return check(false, "the two overlay windows exist")
        }
        let canvasA = a.canvas
        let canvasB = b.canvas

        // Menu wiring: both items sit on the document's own selectors, are
        // found by their accessibility labels, and carry no shortcut.
        let menu = MainMenu.make()
        let viewMenu = menu.items.first { $0.title == "View" }?.submenu
        func viewItem(_ label: String) -> NSMenuItem? {
            viewMenu?.items.first { $0.accessibilityLabel() == label || $0.title == label }
        }
        let edgesItem = viewItem("Show Selection Edges")
        let boundaryItem = viewItem("Show Layer Boundary")
        check(edgesItem?.action == #selector(DocumentWindowController.toggleSelectionEdges(_:)),
              "View offers Show Selection Edges on the document's selector")
        check(boundaryItem?.action == #selector(DocumentWindowController.toggleLayerBoundary(_:)),
              "View offers Show Layer Boundary on the document's selector")
        check(edgesItem?.keyEquivalent == "" && boundaryItem?.keyEquivalent == "",
              "neither overlay item has a shortcut by default")

        // Defaults: edges on, boundary off, in both windows' caches, and
        // the validation checkmarks read that cached state.
        let edgesProbe = NSMenuItem(title: "Show Selection Edges",
                                    action: #selector(DocumentWindowController.toggleSelectionEdges(_:)),
                                    keyEquivalent: "")
        let boundaryProbe = NSMenuItem(title: "Show Layer Boundary",
                                       action: #selector(DocumentWindowController.toggleLayerBoundary(_:)),
                                       keyEquivalent: "")
        check(a.validateMenuItem(edgesProbe) && edgesProbe.state == .on
                && b.validateMenuItem(edgesProbe) && edgesProbe.state == .on,
              "Show Selection Edges validates checked by default in both windows")
        check(a.validateMenuItem(boundaryProbe) && boundaryProbe.state == .off
                && b.validateMenuItem(boundaryProbe) && boundaryProbe.state == .off,
              "Show Layer Boundary validates unchecked by default in both windows")
        check(canvasA.showsSelectionEdges && !canvasA.showsLayerBoundary
                && canvasB.showsSelectionEdges && !canvasB.showsLayerBoundary,
              "both canvases cache the defaults (edges on, boundary off)")

        // Toggling stays available and works while the engine is busy:
        // the action and the validation read cached state only.
        let gate = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Holding the engine", work: { gate.wait() },
                                                 completion: {})
        check(held && a.validateMenuItem(boundaryProbe) && boundaryProbe.state == .off,
              "Show Layer Boundary stays enabled while the engine is busy")
        if let action = boundaryItem?.action {
            NSApp.sendAction(action, to: a, from: boundaryItem)
        }
        check(canvasA.showsLayerBoundary && boundaryItem?.state == .on,
              "the real menu action turns the boundary on in window A while the engine is busy")
        check(canvasB.showsLayerBoundary == false && b.layerBoundaryViewState.showsLayerBoundary == false,
              "window B keeps its own cached boundary state (two independent windows)")
        gate.signal()
        wait { !EngineActivity.shared.isBusy }
        spin(0.05)
        check(a.validateMenuItem(boundaryProbe) && boundaryProbe.state == .on,
              "the checkmark reads on after the toggle, engine idle again")

        // Hiding the edges over a nonempty selection: only the ants stop;
        // the native selection bounds and the cached outline remain.
        var options = EngineSession.SelectOptions()
        options.antialias = false
        let selection = CGRect(x: 4, y: 4, width: 12, height: 10)
        docA.select(.rectangle(selection), options: options)
        settle(docA)
        docA.refreshSelection()
        settle(docA)
        check(docA.selectionBounds == selection && !docA.selectionOutline.isEmpty
                && (try? session.selectionBounds(image: imageA)) == selection,
              "A has a nonempty cached and native selection with an outline")
        if let action = edgesItem?.action {
            NSApp.sendAction(action, to: a, from: edgesItem)
        }
        check(canvasA.showsSelectionEdges == false && edgesItem?.state == .off,
              "the real menu action hides the selection edges in window A")
        check(docA.selectionBounds == selection && !docA.selectionOutline.isEmpty
                && (try? session.selectionBounds(image: imageA)) == selection,
              "hiding the edges keeps the native selection bounds and the cached outline")
        check(canvasB.showsSelectionEdges, "window B still shows its own edges")

        // Cached paint-target geometry, checked through the pure helper's
        // rectangles. Layer target first.
        guard let layerA = docA.activeLayer else {
            return check(false, "A has an active layer for the boundary fixture")
        }
        let layerBounds = docA.layers.first { $0.id == layerA }?.bounds
        let imageRectA = CGRect(x: 0, y: 0, width: 64, height: 48)
        check(layerBounds == CGRect(x: 2, y: 3, width: 32, height: 28),
              "the layer boundary fixture differs from the image in origin and size")
        check(docA.cachedPaintTargetBounds == layerBounds
                && LayerBoundaryGeometry.boundaryRect(target: .layer(layerA), layers: docA.layers,
                                                       imageSize: imageRectA.size) == layerBounds,
              "layer target: the boundary is the active layer's cached absolute bounds")

        // Mask editing: the owner layer's bounds, not the mask drawable.
        docA.addMask(layerA, source: .white, edit: true)
        settle(docA)
        check(docA.isMaskTargetActive && docA.cachedPaintTargetBounds == layerBounds,
              "mask target: the boundary is the owner layer's cached bounds")
        docA.selectLayer(layerA)
        settle(docA)
        check(!docA.isMaskTargetActive && docA.cachedPaintTargetBounds == layerBounds,
              "returning to the layer restores the layer's own boundary")
        docA.deleteMask()
        settle(docA)

        // Channel target: the image bounds.
        try session.select(.rectangle(CGRect(x: 20, y: 20, width: 24, height: 24)),
                           image: imageA, options: .init())
        let channel = try session.channelFromSelection(imageA, name: "Overlay area")
        try session.select(.none, image: imageA)
        try docA.reload()
        settle(docA)
        check(docA.activeChannel == channel && docA.cachedPaintTargetBounds == imageRectA,
              "channel target: the boundary is the image bounds")
        docA.selectLayer(layerA)
        settle(docA)
        check(docA.cachedPaintTargetBounds == layerBounds,
              "leaving the channel restores the layer boundary")

        // Floating selection: the floating layer's actual bounds, ahead of
        // any layer/mask/channel target.
        docA.select(.rectangle(selection), options: options)
        settle(docA)
        docA.refreshSelection()
        settle(docA)
        var floatResult: Result<Void, Error>?
        docA.floatSelectedPixels(mode: .copy, target: layerA) { floatResult = $0 }
        settle(docA)
        check(docA.floatingState.isActive
                && (floatResult.map { if case .success = $0 { return true }; return false } == true),
              "Float a Copy creates the floating selection on A")
        let floatBounds = docA.layers.first { $0.id == docA.floatingState.floating }?.bounds
        check(floatBounds == selection && docA.cachedPaintTargetBounds == floatBounds,
              "floating target: the boundary is the floating layer's actual cached bounds")
        var anchorResult: Result<Void, Error>?
        docA.resolveFloatingSelection(.anchor) { anchorResult = $0 }
        settle(docA)
        check(!docA.floatingState.isActive
                && (anchorResult.map { if case .success = $0 { return true }; return false } == true)
                && docA.cachedPaintTargetBounds == layerBounds,
              "anchoring the float returns the boundary to the layer's bounds")

        // Toggling the overlays changes no undo step, pixel or dirty state.
        let undoBefore = docA.undoInfo.undoCount
        let dirtyBefore = docA.hasUnsavedChanges
        let pixelsBefore = try session.copyPixels(imageA, merged: true).pixels
        if let action = edgesItem?.action { NSApp.sendAction(action, to: a, from: edgesItem) }
        if let action = boundaryItem?.action { NSApp.sendAction(action, to: a, from: boundaryItem) }
        if let action = edgesItem?.action { NSApp.sendAction(action, to: a, from: edgesItem) }
        if let action = boundaryItem?.action { NSApp.sendAction(action, to: a, from: boundaryItem) }
        check(docA.undoInfo.undoCount == undoBefore && docA.hasUnsavedChanges == dirtyBefore
                && (try? session.copyPixels(imageA, merged: true).pixels) == pixelsBefore,
              "four overlay toggles change no undo step, dirty flag or engine pixel")
        check(canvasA.showsSelectionEdges == false && canvasA.showsLayerBoundary == true,
              "window A's cached toggles are edges-off, boundary-on after the round trip")

        // The per-window toggles survive a document reload and never reach
        // the other document's window.
        try docA.reload()
        settle(docA)
        check(canvasA.showsSelectionEdges == false && canvasA.showsLayerBoundary == true,
              "window A's toggles survive a document reload")
        check(a.validateMenuItem(edgesProbe) && edgesProbe.state == .off
                && a.validateMenuItem(boundaryProbe) && boundaryProbe.state == .on,
              "the checkmarks read A's cached state after the reload")
        check(canvasB.showsSelectionEdges && !canvasB.showsLayerBoundary
                && b.validateMenuItem(edgesProbe) && edgesProbe.state == .on
                && b.validateMenuItem(boundaryProbe) && boundaryProbe.state == .off,
              "window B is unaffected by A's toggles and reload")
    }
}
