import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    static func exerciseFloatingControls(_ session: EngineSession, work: URL,
                                                 documents: DocumentList) throws {
        let imageA = try session.newImage(width: 64, height: 64)
        let documentA = try ImageDocument(session: session, image: imageA, name: "Float A")
        documents.items.append(documentA)
        let controllerA = DocumentWindowController(document: documentA)
        controllerA.showWindow(nil)
        let imageB = try session.newImage(width: 64, height: 64)
        let documentB = try ImageDocument(session: session, image: imageB, name: "Float B")
        documents.items.append(documentB)
        let controllerB = DocumentWindowController(document: documentB)
        controllerB.showWindow(nil)
        // B front: a command issued on A must still land in A.
        controllerB.window?.makeKeyAndOrderFront(nil)
        var errorsA: [String] = []
        documentA.onError = { errorsA.append($0) }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            let deadline = Date().addingTimeInterval(10)
            while (document.pendingWork > 0 || EngineActivity.shared.isBusy) && Date() < deadline { spin(0.01) }
            spin()
        }
        defer {
            // Order the windows out (a close on a dirty document would
            // raise the save sheet); the engine-level close below is what
            // drains accepted work before the image is destroyed.
            controllerA.window?.orderOut(nil)
            controllerB.window?.orderOut(nil)
            documents.items.removeAll { $0 === documentA || $0 === documentB }
            for document in [documentA, documentB] where !document.isClosing {
                var closed = false
                document.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(10)
                while !closed && Date() < deadline { spin(0.01) }
            }
            check((try? session.info(imageA)) == nil && (try? session.info(imageB)) == nil,
                  "both floating-controls images drain and close before engine shutdown")
        }

        // A 16x16 opaque red clipboard payload, on a private board and on
        // the general pasteboard the menu validation reads.
        let red = ClipboardImage(width: 16, height: 16,
                                 pixels: Data((0..<(16 * 16)).flatMap { _ in [UInt8(255), 0, 0, 255] }),
                                 origin: .zero)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try red.write(to: board)
        let savedItems = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                item.data(forType: type).map { (type, $0) }
            }
        }
        defer {
            NSPasteboard.general.clearContents()
            let restored = savedItems.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { NSPasteboard.general.writeObjects(restored) }
        }
        try red.write(to: .general)

        guard let layerA = documentA.activeLayer else {
            check(false, "document A has a layer to paste into")
            return
        }
        var options = EngineSession.SelectOptions()
        options.antialias = false
        documentA.select(.rectangle(CGRect(x: 10, y: 10, width: 8, height: 8)), options: options)
        settle(documentA)
        let outlineBefore = try session.selectionOutline(image: imageA)
        check(!outlineBefore.isEmpty, "document A has a selection to paste into")
        let selectionBefore = try session.selectionBounds(image: imageA)
        let targetPixelsBefore = try session.copyPixels(imageA, merged: true).pixels

        // The real menu item, validated against cached state, then sent
        // to A's controller while B is front.
        let menu = MainMenu.make()
        let editMenu = menu.items.first { $0.title == "Edit" }?.submenu
        let pasteIntoItem = editMenu?.items.first { $0.title == "Paste Into" }
        let pasteItem = editMenu?.items.first { $0.title == "Paste" }
        check(pasteIntoItem != nil, "the Edit menu lists Paste Into")
        check(pasteIntoItem.map { controllerA.validateMenuItem($0) } == true,
              "Paste Into validates with a clipboard image, a selection and a layer target")
        check(pasteItem.map { controllerA.validateMenuItem($0) } == true,
              "ordinary Paste still validates while no floating selection is active")
        if let pasteIntoItem, let action = pasteIntoItem.action {
            NSApp.sendAction(action, to: controllerA, from: pasteIntoItem)
        }
        settle(documentA)
        let stateA = try session.floatingSelection(imageA)
        check(stateA.isActive && stateA.target == layerA && stateA.targetKind == .layer,
              "Paste Into on A's controller creates a floating selection attached to A's explicit layer target")
        check(documentA.floatingState == stateA, "the document cache refreshes to the native floating state")
        check((try? session.floatingSelection(imageB))?.isActive == false,
              "document B, frontmost, keeps no floating selection (two-document capture)")
        check(try session.selectionBounds(image: imageA) == selectionBefore,
              "Paste Into leaves the selection mask bounds unchanged")
        check((pixel(session, imageA, x: 12, y: 12)?[1] ?? 255) == 0,
              "the floating preview is clipped to the selection in the composite (inside red)")
        check((pixel(session, imageA, x: 7, y: 7)?[1] ?? 0) == 255,
              "pixels outside the selection are untouched by the clipped preview")

        check(pasteIntoItem.map { controllerA.validateMenuItem($0) } == false
                && pasteItem.map { controllerA.validateMenuItem($0) } == false,
              "while floating is active the menu disables Paste Into and ordinary Paste (resolve-first)")

        // Explicit expected id: zero and stale ids are refused natively
        // and never fall back to the active floating selection.
        check((try? session.floatingCommand(.discard, image: imageA, expected: 0)) == nil
                && (try? session.floatingCommand(.anchor, image: imageA, expected: stateA.floating + 999_999)) == nil,
              "zero and stale expected floating ids are refused")
        check((try? session.floatingSelection(imageA))?.isActive == true,
              "refused resolutions leave the floating selection active")

        // Undo/Redo refresh the cached floating state to the oracle.
        documentA.undo()
        settle(documentA)
        check(documentA.floatingState == (try? session.floatingSelection(imageA)),
              "Undo refreshes the cached floating state to the native oracle")
        check(try session.copyPixels(imageA, merged: true).pixels == targetPixelsBefore,
              "Undo of Paste Into restores the untouched target pixels")
        documentA.redo()
        settle(documentA)
        let stateAfterRedo = try session.floatingSelection(imageA)
        check(documentA.floatingState == stateAfterRedo && stateAfterRedo.isActive,
              "Redo refreshes the cached floating state to the restored native floating selection")

        // While floating is active the floating layer owns the paint
        // target, and accepted input (a stroke) lands on it, off the main
        // thread, as one counted undo step.
        check(documentA.activeDrawable == stateAfterRedo.floating,
              "the floating layer is the paint target while active")
        let undoBeforeStroke = documentA.undoInfo.undoCount
        let black = EngineSession.Brush(size: 6, opacity: 1, red: 0, green: 0, blue: 0, pressureSize: false)
        documentA.beginStroke(at: .init(x: 12, y: 12, pressure: 1), brush: black)
        documentA.continueStroke([.init(x: 13, y: 12, pressure: 1)])
        documentA.endStroke()
        settle(documentA)
        check(documentA.undoInfo.undoCount == undoBeforeStroke + 1
                && (pixel(session, imageA, x: 12, y: 12)?[0] ?? 255) < 30,
              "a stroke accepted while floating paints the floating layer as one undo step")
        documentA.resolveFloatingSelection(.discard) { _ in }
        settle(documentA)
        check(try session.copyPixels(imageA, merged: true).pixels == targetPixelsBefore,
              "discarding the painted floating layer reveals the untouched target")
        documentA.undo()
        settle(documentA)
        check(documentA.floatingState.floating == stateAfterRedo.floating,
              "Undo of Discard restores the painted floating layer with the same identity")

        // New Layer (toLayer) on a layer attachment: allowed, and it
        // reveals the full pasted payload beyond the selection clipping.
        let layersBeforeToLayer = documentA.layers.count
        var toLayerResult: Result<Void, Error>?
        documentA.resolveFloatingSelection(.toLayer) { toLayerResult = $0 }
        settle(documentA)
        let toLayerSucceeded: Bool
        if case .success = toLayerResult { toLayerSucceeded = true } else { toLayerSucceeded = false }
        check(toLayerSucceeded && documentA.layers.count == layersBeforeToLayer
                && documentA.layers.contains(where: { $0.id == stateAfterRedo.floating })
                && (try? session.floatingSelection(imageA))?.isActive == false,
              "New Layer resolves the floating selection into an independent layer")
        check((pixel(session, imageA, x: 7, y: 7)?[1] ?? 255) == 0,
              "New Layer removes the selection clipping and reveals the full pasted payload (not the clipped preview)")

        // BUSY: a held exclusive engine activity refuses resolution and
        // Paste Into without queueing anything.
        documentA.pasteIntoPixels(try ClipboardImage.readPayload(from: board), target: layerA) { _ in }
        settle(documentA)
        check((try? session.floatingSelection(imageA))?.isActive == true, "a second Paste Into re-activates floating")
        let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Floating busy hold", work: {
            ready.signal()
            _ = release.wait(timeout: .now() + 30)
        }, completion: {})
        var started = false
        let holdDeadline = Date().addingTimeInterval(10)
        while !started && Date() < holdDeadline {
            started = ready.wait(timeout: .now()) == .success
            if !started { spin(0.01) }
        }
        check(held && started, "the exclusive hold is running")
        let workBeforeBusy = documentA.pendingWork
        var busyResult: Result<Void, Error>?
        documentA.resolveFloatingSelection(.discard) { busyResult = $0 }
        controllerA.pasteIntoImage(from: board)
        settle(documentA)
        check(busyResult != nil && documentA.pendingWork == workBeforeBusy,
              "resolution and Paste Into are refused while the engine is busy, with nothing queued")
        release.signal()
        settle(documentA)
        var discardResult: Result<Void, Error>?
        documentA.resolveFloatingSelection(.discard) { discardResult = $0 }
        settle(documentA)
        check(discardResult != nil && (try? session.floatingSelection(imageA))?.isActive == false
                && documentA.floatingState.isActive == false,
              "Discard after the hold resolves the floating selection (cached state agrees with the oracle)")

        // Mask attachment: Paste Into targets the editing mask explicitly;
        // the floating layer still owns the paint target, and New Layer
        // is gated off for a mask attachment.
        documentA.addMask(layerA, source: .white, edit: true)
        settle(documentA)
        guard let maskA = documentA.maskStates[layerA]?.mask, maskA != 0, documentA.isMaskTargetActive else {
            check(false, "document A's mask is the edit target before the mask paste")
            return
        }
        controllerA.pasteIntoImage(from: board)
        settle(documentA)
        let maskState = try session.floatingSelection(imageA)
        check(maskState.isActive && maskState.targetKind == .layerMask && maskState.target == maskA,
              "Paste Into with the mask editing attaches the floating selection to the explicit mask target")
        check(documentA.activeDrawable == maskState.floating,
              "a mask-attached floating selection still owns the paint target (no mask/channel-priority redirect)")
        let toLayerMask = documentA.floatingResolutionReadiness(.toLayer)
        check(!toLayerMask.allowed && toLayerMask.reason?.contains("mask or channel") == true,
              "New Layer is refused for a mask-attached floating selection, with the reason")

        // The palette: floating row label, footer buttons and menu,
        // all driven by cached state and accessibility queries.
        let palette = LayersPaletteController()
        palette.retarget(to: documentA)
        _ = palette.view
        palette.reload()
        let bar = descendant(of: palette.view, as: FloatingSelectionBar.self)
        check(bar != nil && bar?.isHidden == false, "the Layers palette shows the floating-selection footer")
        let barButtons = bar.map { buttons(in: $0) } ?? []
        let anchorButton = barButtons.first { $0.accessibilityLabel() == "Anchor floating selection" }
        let newLayerButton = barButtons.first { $0.accessibilityLabel() == "New layer from floating selection" }
        let discardButton = barButtons.first { $0.accessibilityLabel() == "Discard floating selection" }
        check(anchorButton?.isEnabled == true && discardButton?.isEnabled == true && newLayerButton?.isEnabled == false,
              "the footer enables Anchor and Discard and disables New Layer for a mask attachment")
        check(newLayerButton?.toolTip?.contains("mask or channel") == true,
              "the disabled New Layer button explains the mask/channel gate in its tooltip")
        func floatingRowDetails() -> String? {
            guard let outline = descendant(of: palette.view, as: NSOutlineView.self) else { return nil }
            for row in 0..<outline.numberOfRows {
                guard let view = outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? LayerRowView,
                      view.context.layerID == maskState.floating else { continue }
                return view.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
                    .first { $0.contains("floating selection") }
            }
            return nil
        }
        check(floatingRowDetails() != nil, "the native floating row is labelled as a temporary floating selection")
        if let submenu = palette.paletteMenu?.items.first(where: { $0.title == "Floating Selection" })?.submenu,
           let newLayerItem = submenu.items.first(where: { $0.title == "New Layer" }),
           let anchorItem = submenu.items.first(where: { $0.title == "Anchor" }) {
            check(palette.validateMenuItem(newLayerItem) == false && palette.validateMenuItem(anchorItem) == true,
                  "the palette menu validates the floating commands from cached state only")
        } else {
            check(false, "the palette menu lists the Floating Selection submenu")
        }
        discardButton?.performClick(nil)
        settle(documentA)
        check((try? session.floatingSelection(imageA))?.isActive == false,
              "the footer's Discard button resolves the floating selection")

        // Channel attachment: same gates — explicit channel target,
        // floating owns the paint target over the selected channel.
        documentA.saveSelectionToChannel(name: "float-chan")
        settle(documentA)
        guard let channel = documentA.channels.first(where: { !$0.isQuickMask }) else {
            check(false, "document A has a saved channel")
            return
        }
        documentA.selectChannel(channel.id)
        settle(documentA)
        check(documentA.isChannelTargetActive && documentA.activeDrawable == channel.id,
              "the channel is the paint target before the channel paste")
        controllerA.pasteIntoImage(from: board)
        settle(documentA)
        let channelState = try session.floatingSelection(imageA)
        check(channelState.isActive && channelState.targetKind == .channel && channelState.target == channel.id,
              "Paste Into with a channel selected attaches to the explicit channel target")
        check(documentA.activeDrawable == channelState.floating,
              "a channel-attached floating selection still owns the paint target (channel-priority corrected)")
        check(!documentA.floatingResolutionReadiness(.toLayer).allowed,
              "New Layer is refused for a channel-attached floating selection")
        documentA.resolveFloatingSelection(.discard, completion: { _ in })
        settle(documentA)
        documentA.returnToLayers()
        settle(documentA)

        // Locks and structured targets on document B: Paste Into refuses a
        // pixel-locked target from cache, the anchor rechecks the lock,
        // and a genuine editable text target refuses with rasterize-first.
        guard let layerB = documentB.activeLayer else {
            check(false, "document B has a layer")
            return
        }
        documentB.select(.rectangle(CGRect(x: 10, y: 10, width: 8, height: 8)), options: options)
        settle(documentB)
        documentB.setLayerLocks(layerB, .pixels, to: true)
        settle(documentB)
        let lockedReadiness = documentB.pasteIntoReadiness
        check(!lockedReadiness.allowed && lockedReadiness.reason?.contains("locked") == true,
              "Paste Into readiness refuses a pixel-locked target from cached locks")
        var lockedPaste: Result<Void, Error>?
        documentB.pasteIntoPixels(try ClipboardImage.readPayload(from: board), target: layerB) { lockedPaste = $0 }
        check(lockedPaste != nil && (try? session.floatingSelection(imageB))?.isActive == false,
              "a Paste Into into a pixel-locked target is refused with no floating selection created")
        documentB.setLayerLocks(layerB, .pixels, to: false)
        settle(documentB)
        documentB.pasteIntoPixels(try ClipboardImage.readPayload(from: board), target: layerB) { _ in }
        settle(documentB)
        let stateB = try session.floatingSelection(imageB)
        check(stateB.isActive && stateB.target == layerB, "an unlocked target accepts the Paste Into")
        documentB.setLayerLocks(layerB, .pixels, to: true)
        settle(documentB)
        let anchorLocked = documentB.floatingResolutionReadiness(.anchor)
        var anchorResult: Result<Void, Error>?
        documentB.resolveFloatingSelection(.anchor) { anchorResult = $0 }
        check(!anchorLocked.allowed && anchorResult != nil
                && (try? session.floatingSelection(imageB))?.isActive == true,
              "Anchor rechecks the target's cached pixel lock and refuses while locked")
        documentB.setLayerLocks(layerB, .pixels, to: false)
        settle(documentB)
        documentB.resolveFloatingSelection(.anchor) { anchorResult = $0 }
        settle(documentB)
        check(anchorResult != nil && (try? session.floatingSelection(imageB))?.isActive == false
                && (pixel(session, imageB, x: 12, y: 12)?[1] ?? 255) == 0,
              "Anchor after unlocking merges the floating pixels into the target")

        let textB = try session.addTextLayer(image: imageB, text: "T", settings: .init(), at: .zero)
        try session.selectLayer(textB, image: imageB)
        try? documentB.reload()
        let textReadiness = FloatingControlsLogic.pasteIntoTarget(textB, state: documentB.floatingState,
            layers: documentB.layers, maskStates: documentB.maskStates, channels: documentB.channels,
            sources: documentB.layerSources, locks: documentB.layerLocks, acceptsEdits: true, pendingTarget: false)
        check(!textReadiness.allowed && textReadiness.reason?.contains("rasterize") == true,
              "a genuine editable text target refuses Paste Into with the rasterize-first reason")
        var textPaste: Result<Void, Error>?
        documentB.pasteIntoPixels(try ClipboardImage.readPayload(from: board), target: textB) { textPaste = $0 }
        check(textPaste != nil && (try? session.floatingSelection(imageB))?.isActive == false,
              "pasting into a genuine editable text layer is refused with no floating selection")

        // Accepted work is counted and close drains it; a late callback
        // after the close began fails cleanly instead of touching a dead
        // image.
        var lateResult: Result<Void, Error>?
        let workBeforeAccept = documentB.pendingWork
        documentB.pasteIntoPixels(try ClipboardImage.readPayload(from: board), target: layerB) { lateResult = $0 }
        check(documentB.pendingWork == workBeforeAccept + 1, "an accepted Paste Into is counted as pending work")
        var closedB = false
        documentB.closeImageWhenDrained { closedB = true }
        let closeDeadline = Date().addingTimeInterval(10)
        while !closedB && Date() < closeDeadline { spin(0.01) }
        check(closedB && lateResult != nil && (try? session.info(imageB)) == nil,
              "close drains the accepted Paste Into before the image is destroyed, and its callback still lands")
        var lateCallback: Result<Void, Error>?
        documentB.resolveFloatingSelection(.discard) { lateCallback = $0 }
        check(lateCallback != nil, "a resolution requested after close fails through its callback without crashing")
        documents.items.removeAll { $0 === documentB }
    }

}
