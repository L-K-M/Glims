import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseBatchDelete(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 24, height: 20)
        for color in [NSColor.red, .green, .blue] {
            _ = try session.layerCommand(.new, image: image)
            try session.fill(image: image, at: .zero, mode: .selection, color: color)
        }
        let original = try session.layers(image).map(\.id)
        let captured = [original[2], original[0]]
        try session.selectLayers(captured, image: image)
        let beforePixels = try session.copyPixels(image, merged: true).pixels
        let baseline = try session.undoInfo(image).undoCount
        let doc = try ImageDocument(session: session, image: image, name: "Delete A")
        let otherImage = try session.newImage(width: 12, height: 12)
        let other = try ImageDocument(session: session, image: otherImage, name: "Delete B")
        documents.items += [doc, other]
        let controller = DocumentWindowController(document: doc), front = DocumentWindowController(document: other)
        controller.showWindow(nil); front.showWindow(nil)
        func wait(_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(15)
            while !condition() && Date() < end { spin(0.01) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}; wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }; spin()
        }
        func buttons(_ view: NSView) -> [NSButton] {
            ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons($0) }
        }
        let inputGate = DispatchSemaphore(value: 0), exclusiveGate = DispatchSemaphore(value: 0)
        defer {
            inputGate.signal(); exclusiveGate.signal()
            for window in [controller, front] {
                window.window?.orderOut(nil)
                var stopped = false; window.canvas.stopRendering { stopped = true }; wait { stopped }
            }
            for document in [doc, other] where !document.isClosing {
                var closed = false; document.closeImageWhenDrained { closed = true }; wait { closed }
            }
            documents.items.removeAll { $0 === doc || $0 === other }
        }
        let menu = NSApp.mainMenu?.item(withTitle: "Layer")?.submenu
        let item = menu?.items.first { $0.action == #selector(DocumentWindowController.deleteLayer(_:)) }
        check(item.map { controller.validateMenuItem($0) && $0.title == "Delete Layers" } == true,
              "the actual Layer menu admits Delete Layers for a captured pixel selection")
        front.window?.makeKeyAndOrderFront(nil)
        controller.deleteLayer(nil); settle(doc)
        let survivors = original.filter { !captured.contains($0) }
        let otherAfter = try session.layers(otherImage)
        check(doc.layers.map(\.id) == survivors && otherAfter.count == 1,
              "Delete Layers removes A's exact captured ids while B is frontmost")
        check(try session.undoInfo(image).undoCount == baseline + 1,
              "batch deletion creates exactly one native Undo step")
        check(doc.selectedLayerIDs == [survivors[0]], "the document mirrors the declared surviving-row selection")
        doc.undo(); settle(doc)
        check(doc.layers.map(\.id) == original && doc.selectedLayerIDs == captured,
              "one document Undo restores the original tree and complete ordered selection")
        check(try session.copyPixels(image, merged: true).pixels == beforePixels
              && session.undoInfo(image).undoCount == baseline, "Undo restores independent image pixels and history baseline")
        doc.redo(); settle(doc)
        check(doc.layers.map(\.id) == survivors && doc.selectedLayerIDs == [survivors[0]],
              "document Redo removes the same ids and restores survivor selection")
        doc.undo(); settle(doc)
        let palette = LayersPaletteController(); palette.retarget(to: doc)
        let paletteHost = NSWindow(contentRect: NSRect(x: 10, y: 10, width: 240, height: 220),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        paletteHost.isReleasedWhenClosed = false; paletteHost.contentView = palette.view; paletteHost.orderFront(nil)
        defer { palette.retarget(to: nil); paletteHost.close() }
        let paletteItem = palette.paletteMenu?.items.first { $0.tag == Int(EngineSession.LayerCommand.delete.rawValue) && $0.action != nil }
        let deleteButton = buttons(palette.view).first { $0.accessibilityLabel() == "Delete Layers" }
        check(paletteItem.map { palette.validateMenuItem($0) && $0.title == "Delete Layers" } == true && deleteButton?.isEnabled == true,
              "palette menu and actual Delete button admit the same captured batch")
        if let paletteItem, let action = paletteItem.action { _ = NSApp.sendAction(action, to: palette, from: paletteItem) }
        settle(doc)
        check(doc.layers.map(\.id) == survivors, "the actual palette menu deletes the full captured vector")
        doc.undo(); settle(doc); palette.retarget(to: doc)
        deleteButton?.performClick(nil); settle(doc)
        check(doc.layers.map(\.id) == survivors, "the actual palette Delete button removes the full vector")
        doc.undo(); settle(doc)
        let pendingGate = DispatchSemaphore(value: 0)
        doc.inputQueue.async { _ = pendingGate.wait(timeout: .now() + 15) }
        doc.layerCommand(.new)
        var refused: Result<Void, Error>?
        doc.deleteSelectedLayers { refused = $0 }
        check(doc.targetCommandIsPending && item.map { !controller.validateMenuItem($0) } == true
              && refused.map { if case .failure = $0 { return true }; return false } == true,
              "pending New Layer prevents Delete from using the stale cached selection")
        pendingGate.signal(); settle(doc)
        check(doc.layers.count == original.count + 1, "the refused stale Delete leaves only New Layer's added row")
        doc.undo(); settle(doc)
        doc.selectLayers(captured); settle(doc)
        let selectionGate = DispatchSemaphore(value: 0)
        doc.inputQueue.async { _ = selectionGate.wait(timeout: .now() + 15) }
        var selectionResult: Result<Void, Error>?
        doc.deleteSelectedLayers { selectionResult = $0 }
        let newerSelection = Array(survivors.reversed())
        try session.selectLayers(newerSelection, image: image)
        selectionGate.signal(); settle(doc)
        check(selectionResult.map { if case .success = $0 { return true }; return false } == true
              && doc.layers.map(\.id) == survivors && doc.selectedLayerIDs == newerSelection,
              "later native selection changes cannot retarget accepted Delete and its surviving order is preserved")
        doc.undo(); settle(doc)
        check(doc.layers.map(\.id) == original && doc.selectedLayerIDs == newerSelection,
              "Undo restores the actual pre-execution selection after a later pick")
        doc.selectLayers(captured); settle(doc)
        let failureGate = DispatchSemaphore(value: 0)
        doc.inputQueue.async { _ = failureGate.wait(timeout: .now() + 15) }
        var failed: Result<Void, Error>?, failedCount = 0
        doc.deleteSelectedLayers { failed = $0; failedCount += 1 }
        _ = try session.layerCommand(.delete, image: image, layer: captured[1])
        let afterEarlierDelete = try session.layers(image).map(\.id)
        let undoAfterEarlierDelete = try session.undoInfo(image).undoCount
        failureGate.signal(); settle(doc)
        check(failedCount == 1 && failed.map { if case .failure = $0 { return true }; return false } == true
              && doc.pendingWork == 0 && doc.layers.map(\.id) == afterEarlierDelete,
              "a queued stale-target failure completes once, drains, and refreshes without deleting another source")
        check(try session.undoInfo(image).undoCount == undoAfterEarlierDelete,
              "the refused queued batch adds no Undo step after an earlier target deletion")
        doc.undo(); settle(doc)
        doc.selectLayers(captured); settle(doc)
        doc.inputQueue.async { _ = inputGate.wait(timeout: .now() + 15) }
        var result: Result<Void, Error>?, completionCount = 0
        doc.deleteSelectedLayers { result = $0; completionCount += 1 }
        let started = DispatchSemaphore(value: 0)
        var idle = false
        let accepted = EngineActivity.shared.perform(label: "Delete completion ordering", work: {
            started.signal(); _ = exclusiveGate.wait(timeout: .now() + 15)
        }, completion: { idle = true })
        inputGate.signal()
        var began = false
        wait { if !began { began = started.wait(timeout: .now()) == .success }; return began }
        check(accepted && began && result == nil && doc.pendingWork > 0,
              "batch Delete stays counted through another document's exclusive drain")
        var stopped = false; controller.canvas.stopRendering { stopped = true }; wait { stopped }
        var closeCount = 0; doc.closeImageWhenDrained { closeCount += 1 }
        check(closeCount == 0, "image close waits for accepted deletion delivery")
        exclusiveGate.signal(); wait { idle && closeCount == 1 }
        check(completionCount == 1 && result.map { if case .success = $0 { return true }; return false } == true
              && doc.pendingWork == 0 && (try? session.info(image)) == nil,
              "batch Delete completes once before its captured image is destroyed")
    }
}
