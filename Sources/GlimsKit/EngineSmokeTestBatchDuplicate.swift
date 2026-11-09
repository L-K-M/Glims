import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseBatchDuplicate(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 32, height: 24)
        _ = try session.layerCommand(.new, image: image)
        let original = try session.layers(image).map(\.id)
        try session.selectLayers(original, image: image)
        let doc = try ImageDocument(session: session, image: image, name: "Batch A")
        documents.items.append(doc)
        let controller = DocumentWindowController(document: doc)
        controller.showWindow(nil)
        let otherImage = try session.newImage(width: 16, height: 16)
        let other = try ImageDocument(session: session, image: otherImage, name: "Batch B")
        documents.items.append(other)
        let otherController = DocumentWindowController(document: other)
        otherController.showWindow(nil)
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        }
        let inputGate = DispatchSemaphore(value: 0), exclusiveGate = DispatchSemaphore(value: 0)
        var closed = false
        defer {
            inputGate.signal(); exclusiveGate.signal()
            for c in [controller, otherController] {
                c.window?.orderOut(nil)
                var stopped = false; c.canvas.stopRendering { stopped = true }; wait { stopped }
            }
            for d in [doc, other] where !d.isClosing {
                var stopped = false; d.closeImageWhenDrained { stopped = true }; wait { stopped }
            }
            documents.items.removeAll { $0 === doc || $0 === other }
        }
        let menu = MainMenu.make().items.first { $0.title == "Layer" }?.submenu
        guard let item = menu?.items.first(where: { $0.action == #selector(DocumentWindowController.duplicateLayer(_:)) }) else {
            return check(false, "Layer offers the captured duplicate action")
        }
        check(controller.validateMenuItem(item) && item.title == "Duplicate Layers" && item.keyEquivalent == "j",
              "Command-J admits the selected ordinary pixel layers using cached menu state")
        let before = try session.undoInfo(image), otherBefore = try session.layers(otherImage).map(\.id)
        otherController.window?.makeKeyAndOrderFront(nil)
        controller.duplicateLayer(nil)
        settle(doc)
        let copies = doc.selectedLayerIDs
        check(copies.count == 2 && Set(copies).isDisjoint(with: original) && doc.layers.count == 4,
              "the real menu action duplicates both captured layers and refreshes the complete selection")
        check(try session.undoInfo(image).undoCount == before.undoCount + 1 && session.layers(otherImage).map(\.id) == otherBefore,
              "captured A changes as one Undo while frontmost B remains unchanged")
        doc.selectLayers(original.reversed()); settle(doc)
        doc.undo(); settle(doc)
        check(doc.layers.map(\.id) == original && doc.selectedLayerIDs == original,
              "document Undo restores the original tree and ordered selection after a view reorder")
        doc.redo(); settle(doc)
        check(doc.selectedLayerIDs == copies && doc.layers.count == 4,
              "document Redo refreshes all selected copies in native order")
        let palette = LayersPaletteController()
        palette.retarget(to: doc)
        let paletteHost = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 220),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        paletteHost.isReleasedWhenClosed = false
        paletteHost.contentView = palette.view
        paletteHost.orderFront(nil)
        defer { palette.retarget(to: nil); paletteHost.close() }
        func buttons(_ root: NSView) -> [NSButton] {
            (root as? NSButton).map { [$0] } ?? []
                + root.subviews.flatMap { buttons($0) }
        }
        doc.selectLayers(original); settle(doc); palette.retarget(to: doc)
        let paletteItem = palette.paletteMenu?.items.first { $0.tag == Int(EngineSession.LayerCommand.duplicate.rawValue) && $0.action != nil }
        let duplicateButton = buttons(palette.view).first { $0.accessibilityLabel() == "Duplicate Layers" }
        check(paletteItem.map { palette.validateMenuItem($0) && $0.title == "Duplicate Layers" } == true
                && duplicateButton?.isEnabled == true,
              "the Layers palette menu and button admit the same captured pixel batch")
        otherController.window?.makeKeyAndOrderFront(nil)
        if let paletteItem, let action = paletteItem.action {
            _ = NSApp.sendAction(action, to: palette, from: paletteItem)
        }
        settle(doc)
        let otherAfterPalette = try session.layers(otherImage).map(\.id)
        check(doc.layers.count == 6 && doc.selectedLayerIDs.count == 2
                && Set(doc.selectedLayerIDs).isDisjoint(with: original)
                && otherAfterPalette == otherBefore,
              "the actual palette menu duplicates A's full selection while B is frontmost")
        doc.undo(); settle(doc); doc.selectLayers(original); settle(doc); palette.retarget(to: doc)
        duplicateButton?.performClick(nil); settle(doc)
        check(doc.layers.count == 6 && doc.selectedLayerIDs.count == 2,
              "the actual palette Duplicate button duplicates the full captured selection")
        doc.undo(); settle(doc)
        // The cached multi-selection must not admit another captured edit
        // while New Layer's replacement target has not been reconciled.
        doc.selectLayers(original); settle(doc)
        let pendingInputGate = DispatchSemaphore(value: 0)
        doc.inputQueue.async { pendingInputGate.wait() }
        let countBeforePending = doc.layers.count
        doc.layerCommand(.new)
        var refusedPending: Result<Void, Error>?
        check(doc.targetCommandIsPending && !controller.validateMenuItem(item),
              "Duplicate is disabled while a queued New Layer has an unknown replacement target")
        palette.retarget(to: doc)
        check(paletteItem.map { !palette.validateMenuItem($0) } == true && duplicateButton?.isEnabled == false,
              "the palette menu and button also refuse a pending replacement target")
        doc.duplicateSelectedLayers { refusedPending = $0 }
        check(refusedPending.map { if case .failure = $0 { return true }; return false } == true,
              "direct batch admission refuses the stale cached selection while a target command is pending")
        pendingInputGate.signal(); settle(doc)
        check(doc.layers.count == countBeforePending + 1 && doc.selectedLayerIDs.count == 1,
              "the refused stale batch leaves only New Layer's single new row and selection")
        doc.undo(); settle(doc)
        // Put a native command behind an input barrier, then admit an
        // exclusive operation whose drain is behind that command. The
        // operation holds no native lock, so an early completion fails a
        // deterministic state assertion instead of hanging the main loop.
        doc.selectLayers(original); settle(doc)
        doc.inputQueue.async { inputGate.wait() }
        var outcome: Result<Void, Error>?
        doc.duplicateSelectedLayers { outcome = $0 }
        let started = DispatchSemaphore(value: 0)
        var idle = false
        let admitted = EngineActivity.shared.perform(label: "Batch completion ordering", work: {
            started.signal(); exclusiveGate.wait()
        }, completion: { idle = true })
        inputGate.signal()
        var began = false
        wait {
            if !began { began = started.wait(timeout: .now()) == .success }
            return began
        }
        spin(0.05)
        check(admitted && began && EngineActivity.shared.isBusy && outcome == nil && doc.pendingWork > 0,
              "the target-command cache/completion remains counted until another document's exclusive operation is idle")
        var renderingStopped = false
        controller.canvas.stopRendering { renderingStopped = true }; wait { renderingStopped }
        doc.closeImageWhenDrained { closed = true }
        check(!closed, "close waits for the accepted batch command's deferred completion")
        exclusiveGate.signal()
        wait { idle && closed }
        check(closed && outcome.map { if case .success = $0 { return true }; return false } == true
                && (try? session.info(image)) == nil,
              "exclusive completion drains the batch result before the image is destroyed")
    }
}
