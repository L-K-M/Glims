import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    /// `GLIMS_SMOKE_CASE=float-selected-pixels` (also in the full suite):
    /// Select ▸ Float Selected Pixels (MOVE) and Float a Copy (COPY) driven
    /// through the real menu items, with native pixel/floating-state/
    /// selection oracles. Covers two-document capture, one undo step,
    /// the selection clear, Copy-vs-Move undo/redo, mask and channel
    /// targets, structured-source and lock refusals, busy, queued input
    /// with the stroke-end drain, close draining and the floating-selection
    /// footer bar.
    static func exerciseFloatSelectedPixels(_ session: EngineSession, work: URL,
                                            documents: DocumentList) throws {
        let imageA = try session.newImage(width: 64, height: 64)
        // Use a single alpha-capable raster layer. The native Background
        // has no alpha and a cut correctly replaces its pixels with white.
        let backgroundA = try session.layers(imageA).first!.id
        let white = ClipboardImage(width: 64, height: 64,
                                   pixels: Data(repeating: 255, count: 64 * 64 * 4), origin: .zero)
        _ = try session.pastePixels(imageA, pixels: white, at: .zero)
        _ = try session.layerCommand(.delete, image: imageA, layer: backgroundA)
        let documentA = try ImageDocument(session: session, image: imageA, name: "FloatSel A")
        documents.items.append(documentA)
        let controllerA = DocumentWindowController(document: documentA)
        controllerA.showWindow(nil)
        let imageB = try session.newImage(width: 64, height: 64)
        let documentB = try ImageDocument(session: session, image: imageB, name: "FloatSel B")
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
            controllerA.window?.orderOut(nil)
            controllerB.window?.orderOut(nil)
            documents.items.removeAll { $0 === documentA || $0 === documentB }
            for document in [documentA, documentB] where !document.isClosing {
                var closed = false
                document.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(10)
                while !closed && Date() < deadline { spin(0.01) }
            }
            check((try? session.info(imageB)) == nil,
                  "the float-selected-pixels B image drains and closes before engine shutdown")
        }

        let selection = CGRect(x: 4, y: 4, width: 8, height: 8)
        var options = EngineSession.SelectOptions()
        options.antialias = false
        func reselect(_ document: ImageDocument, _ image: Int32) {
            document.select(.rectangle(selection), options: options)
            settle(document)
            document.refreshSelection()
            settle(document)
            _ = image
        }

        // Nonzero selection coverage below the marching-ants threshold
        // must still be floatable. Select From Alpha on 25%-alpha pixels.
        let softImage = try session.newImage(width: 32, height: 32)
        let softPixels = ClipboardImage(width: 8, height: 8,
            pixels: Data((0..<64).flatMap { _ in [UInt8(255), 0, 0, 64] }), origin: .zero)
        let softLayer = try session.pastePixels(softImage, pixels: softPixels, at: CGPoint(x: 4, y: 4))
        let softDoc = try ImageDocument(session: session, image: softImage, name: "Soft Selection")
        documents.items.append(softDoc)
        softDoc.select(.fromAlpha)
        settle(softDoc)
        softDoc.refreshSelection()
        check((try? session.selectionBounds(image: softImage)) != nil && softDoc.selectionOutline.isEmpty,
              "a 25%-coverage selection has native bounds but no marching ants")
        check(softDoc.floatReadiness(.move).allowed && softDoc.floatReadiness(.copy).allowed,
              "both float actions admit a nonempty soft selection without an outline")
        var softFloat: Result<Void, Error>?
        softDoc.floatSelectedPixels(mode: .copy, target: softLayer) { softFloat = $0 }
        settle(softDoc)
        check(softFloat.map { if case .success = $0 { return true }; return false } == true
                && (try? session.floatingSelection(softImage))?.isActive == true,
              "Float a Copy preserves nonzero coverage below the outline threshold")
        var softClosed = false
        softDoc.closeImageWhenDrained { softClosed = true }
        let softCloseDeadline = Date().addingTimeInterval(10)
        while !softClosed && Date() < softCloseDeadline { spin(0.01) }
        check(softClosed, "the soft-selection fixture closes before continuing")
        documents.items.removeAll { $0 === softDoc }

        // Fixture on A: a red 8x8 block inside the selection on a white layer.
        reselect(documentA, imageA)
        documentA.fill(at: .zero, mode: .selection, color: .red, threshold: 0, sampleMerged: false)
        settle(documentA)
        guard let layerA = documentA.activeLayer else {
            check(false, "document A has a layer to float from")
            return
        }
        check(try session.selectionBounds(image: imageA) == selection,
              "document A has the fixture selection")
        check(pixel(session, imageA, x: 5, y: 5).map { Array($0.prefix(3)) } == [255, 0, 0],
              "the fixture painted the selection red (\(pixel(session, imageA, x: 5, y: 5) ?? []))")

        // The Select menu lists both items with no shortcut, and they
        // validate from cached state while a selection and one layer are
        // current. Ordinary Copy still validates.
        let menu = MainMenu.make()
        let selectMenu = menu.items.first { $0.title == "Select" }?.submenu
        let moveItem = selectMenu?.items.first { $0.title == "Float Selected Pixels" }
        let copyItem = selectMenu?.items.first { $0.title == "Float a Copy" }
        check(moveItem != nil && copyItem != nil, "the Select menu lists Float Selected Pixels and Float a Copy")
        check(moveItem?.keyEquivalent == "" && copyItem?.keyEquivalent == "", "the float items have no shortcut")
        check(moveItem.map { controllerA.validateMenuItem($0) } == true
                && copyItem.map { controllerA.validateMenuItem($0) } == true,
              "both float items validate with a selection and one layer")
        check(moveItem?.toolTip?.contains("selection is cleared") == true
                && copyItem?.toolTip?.contains("selection is cleared") == true,
              "the allowed tooltips state the selection clear (cut vs copy)")
        let copyEdit = menu.items.first { $0.title == "Edit" }?.submenu?.items.first { $0.title == "Copy" }
        check(copyEdit.map { controllerA.validateMenuItem($0) } == true, "ordinary Copy still validates")

        // No selection: the cached readiness refuses both items.
        documentA.select(.none)
        settle(documentA)
        documentA.refreshSelection()
        check(moveItem.map { controllerA.validateMenuItem($0) } == false
                && moveItem?.toolTip?.contains("no selection") == true,
              "without a selection the float items disable with the reason as tooltip")
        reselect(documentA, imageA)
        check(moveItem.map { controllerA.validateMenuItem($0) } == true, "the float item re-enables after re-selecting")

        // MOVE through the real menu item on A's controller while B is
        // front: the capture must land in A.
        let undoBeforeFloat = documentA.undoInfo.undoCount
        if let moveItem, let action = moveItem.action {
            NSApp.sendAction(action, to: controllerA, from: moveItem)
        }
        settle(documentA)
        let stateA = try session.floatingSelection(imageA)
        check(stateA.isActive && stateA.target == layerA && stateA.targetKind == .layer,
              "Float Selected Pixels on A's controller creates a floating selection attached to A's explicit layer target")
        check(documentA.floatingState == stateA,
              "the document cache refreshes to the native floating state (authoritative reload)")
        check(documentA.activeDrawable == stateA.floating,
              "the floating layer becomes the paint target while active")
        check((try? session.floatingSelection(imageB))?.isActive == false,
              "document B, frontmost, keeps no floating selection (two-document capture)")
        check(try session.selectionBounds(image: imageA) == nil,
              "MOVE clears the selection mask")
        check(documentA.layers.first(where: { $0.id == stateA.floating })?.bounds == selection,
              "the floating layer lands on the selection's bounds")
        check(documentA.undoInfo.undoCount == undoBeforeFloat + 1, "the float is exactly one undo step")
        check(pixel(session, imageA, x: 5, y: 5).map { Array($0.prefix(3)) } == [255, 0, 0],
              "the floating preview composites the cut pixels at the selection")

        // While floating is active the float items refuse resolve-first
        // and a move gesture is refused, never an auto-anchor.
        check(moveItem.map { controllerA.validateMenuItem($0) } == false
                && moveItem?.toolTip == FloatingControlsLogic.resolveFirstReason,
              "while floating is active the float items disable with the resolve-first reason")
        documentA.moveActiveLayer(by: CGSize(width: 3, height: 3))
        settle(documentA)
        check(errorsA.contains { $0 == FloatingControlsLogic.resolveFirstReason },
              "a move gesture while floating is refused resolve-first, no auto-anchor")

        // Undo/Redo of the float: selection and pixels restore, the same
        // floating id comes back.
        documentA.undo()
        settle(documentA)
        check(try session.selectionBounds(image: imageA) == selection
                && documentA.floatingState.isActive == false
                && pixel(session, imageA, x: 5, y: 5) == [255, 0, 0, 255],
              "Undo of the float restores the selection and the target pixels, and removes the FS")
        documentA.redo()
        settle(documentA)
        let stateAfterRedo = try session.floatingSelection(imageA)
        let boundsAfterRedo = try? session.selectionBounds(image: imageA)
        check(documentA.floatingState == stateAfterRedo && stateAfterRedo.isActive
                && stateAfterRedo.floating == stateA.floating && boundsAfterRedo == nil,
              "Redo brings back the same floating id and clears the selection again")

        // The existing floating-selection footer bar: shown while active,
        // all three resolution buttons enabled for an unlocked layer
        // target, and its Discard button resolves the FS.
        let palette = LayersPaletteController()
        palette.retarget(to: documentA)
        let paletteHost = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 160),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        paletteHost.isReleasedWhenClosed = false
        paletteHost.contentView = palette.view
        paletteHost.contentView?.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
        paletteHost.orderFront(nil)
        defer { paletteHost.close() }
        palette.reload()
        palette.view.layoutSubtreeIfNeeded()
        let bar = descendant(of: palette.view, as: FloatingSelectionBar.self)
        check(bar != nil && bar?.isHidden == false, "the Layers palette shows the floating-selection footer while active")
        let barButtons = bar.map { buttons(in: $0) } ?? []
        let anchorButton = barButtons.first { $0.accessibilityLabel() == "Anchor floating selection" }
        let newLayerButton = barButtons.first { $0.accessibilityLabel() == "New layer from floating selection" }
        let discardButton = barButtons.first { $0.accessibilityLabel() == "Discard floating selection" }
        check(anchorButton?.isEnabled == true && newLayerButton?.isEnabled == true && discardButton?.isEnabled == true,
              "the footer enables Anchor / New Layer / Discard for an unlocked layer attachment")
        discardButton?.performClick(nil)
        settle(documentA)
        check((try? session.floatingSelection(imageA))?.isActive == false
                && documentA.floatingState.isActive == false,
              "the footer's Discard button resolves the floating selection")
        check(pixel(session, imageA, x: 5, y: 5)?[3] == 0,
              "MOVE's discard leaves a transparent hole in the source (\(pixel(session, imageA, x: 5, y: 5) ?? []))")

        // COPY: the source is preserved and the selection is still
        // cleared; undo/redo behave the same way.
        reselect(documentA, imageA)
        documentA.fill(at: .zero, mode: .selection, color: .red, threshold: 0, sampleMerged: false)
        settle(documentA)
        let undoBeforeCopy = documentA.undoInfo.undoCount
        if let copyItem, let action = copyItem.action {
            NSApp.sendAction(action, to: controllerA, from: copyItem)
        }
        settle(documentA)
        let stateCopy = try session.floatingSelection(imageA)
        check(stateCopy.isActive && stateCopy.target == layerA && stateCopy.targetKind == .layer,
              "Float a Copy creates a floating selection on the same explicit target")
        check(try session.selectionBounds(image: imageA) == nil, "COPY also clears the selection mask")
        check(documentA.undoInfo.undoCount == undoBeforeCopy + 1, "the copy float is one undo step")
        check(pixel(session, imageA, x: 5, y: 5).map { Array($0.prefix(3)) } == [255, 0, 0], "the floated copy composites red")
        documentA.undo()
        settle(documentA)
        check(try session.selectionBounds(image: imageA) == selection && documentA.floatingState.isActive == false,
              "Undo of the copy float restores the selection and removes the FS")
        documentA.redo()
        settle(documentA)
        let boundsAfterCopyRedo = try? session.selectionBounds(image: imageA)
        check((try? session.floatingSelection(imageA))?.floating == stateCopy.floating
                && boundsAfterCopyRedo == nil,
              "Redo of the copy float brings the same floating id back, selection cleared")
        documentA.resolveFloatingSelection(.discard) { _ in }
        settle(documentA)
        check(pixel(session, imageA, x: 5, y: 5) == [255, 0, 0, 255],
              "COPY's discard leaves the source untouched (no hole), unlike MOVE")

        // Queued input and the stroke end drain before the float's target
        // command: a stroke accepted just before the menu action lands on
        // the committed image, then the float runs behind it.
        reselect(documentA, imageA)
        let undoBeforeStroke = documentA.undoInfo.undoCount
        let black = EngineSession.Brush(size: 6, opacity: 1, red: 0, green: 0, blue: 0, pressureSize: false)
        documentA.beginStroke(at: .init(x: 6, y: 6, pressure: 1), brush: black)
        check(documentA.strokeIsActive, "the stroke is active before the float command")
        if let moveItem, let action = moveItem.action {
            NSApp.sendAction(action, to: controllerA, from: moveItem)
        }
        check(!documentA.strokeIsActive, "the float command ends the active stroke before enqueueing")
        settle(documentA)
        check((pixel(session, imageA, x: 6, y: 6)?[0] ?? 255) < 30,
              "the accepted stroke landed on the layer before the float ran")
        check((try? session.floatingSelection(imageA))?.isActive == true,
              "the float queued behind the drained stroke input")
        check(documentA.undoInfo.undoCount == undoBeforeStroke + 2,
              "the stroke and the float are two ordered undo steps")
        documentA.resolveFloatingSelection(.discard) { _ in }
        settle(documentA)

        // Locks: MOVE refuses a pixel- or alpha-locked target from cache
        // (nothing queued), COPY stays allowed on the same locked target.
        reselect(documentA, imageA)
        documentA.setLayerLocks(layerA, .pixels, to: true)
        settle(documentA)
        let lockedMove = documentA.floatReadiness(.move)
        check(!lockedMove.allowed && lockedMove.reason?.contains("pixels are locked") == true,
              "MOVE readiness refuses a pixel-locked target from cached locks")
        check(moveItem.map { controllerA.validateMenuItem($0) } == false
                && moveItem?.toolTip?.contains("locked") == true,
              "the MOVE menu item disables with the lock reason as tooltip")
        check(documentA.floatReadiness(.copy).allowed && copyItem.map { controllerA.validateMenuItem($0) } == true,
              "COPY stays available on the locked target (non-destructive; the native anchor rechecks locks)")
        let workBeforeLocked = documentA.pendingWork
        var lockedResult: Result<Void, Error>?
        documentA.floatSelectedPixels(mode: .move, target: layerA) { lockedResult = $0 }
        check(lockedResult != nil && documentA.pendingWork == workBeforeLocked
                && (try? session.floatingSelection(imageA))?.isActive == false,
              "a MOVE float on a locked target is refused with nothing queued and no FS created")
        documentA.setLayerLocks(layerA, .pixels, to: false)
        documentA.setLayerLocks(layerA, .alpha, to: true)
        settle(documentA)
        check(documentA.floatReadiness(.move).reason?.contains("transparency is locked") == true,
              "MOVE also honors the alpha lock")
        check(documentA.floatReadiness(.copy).allowed, "COPY ignores the alpha lock")
        documentA.setLayerLocks(layerA, .alpha, to: false)
        settle(documentA)

        // Multi-selection: choose one layer first.
        _ = try session.layerCommand(.new, image: imageA)
        try? documentA.reload()
        guard let layerA2 = documentA.layers.first(where: { $0.id != layerA })?.id else {
            check(false, "document A has a second layer for the multi-selection check")
            return
        }
        documentA.selectLayers([layerA, layerA2])
        settle(documentA)
        check(documentA.floatReadiness(.move).reason?.contains("Choose one layer") == true
                && moveItem.map { controllerA.validateMenuItem($0) } == false,
              "a multi-selection refuses the float with the choose-one-layer reason")
        documentA.selectLayer(layerA)
        settle(documentA)
        reselect(documentA, imageA)
        check(documentA.floatReadiness(.move).allowed, "a single selection floats again")

        // Structured source on B: a genuine editable text layer refuses
        // rasterize-first in both modes, from cache and at command time.
        let textB = try session.addTextLayer(image: imageB, text: "T", settings: .init(), at: .zero)
        try session.selectLayer(textB, image: imageB)
        try? documentB.reload()
        reselect(documentB, imageB)
        let textMove = documentB.floatReadiness(.move)
        check(!textMove.allowed && textMove.reason?.contains("rasterize") == true,
              "a genuine editable text target refuses MOVE with rasterize-first")
        check(!documentB.floatReadiness(.copy).allowed,
              "the same text target refuses COPY too (the native source check is mode-independent)")
        let workBeforeText = documentB.pendingWork
        var textResult: Result<Void, Error>?
        documentB.floatSelectedPixels(mode: .move, target: textB) { textResult = $0 }
        check(textResult != nil && documentB.pendingWork == workBeforeText
                && (try? session.floatingSelection(imageB))?.isActive == false,
              "floating from a genuine editable text layer is refused with nothing queued")

        // Mask target: the float attaches to the editing mask explicitly.
        documentA.addMask(layerA, source: .white, edit: true)
        settle(documentA)
        guard let maskA = documentA.maskStates[layerA]?.mask, maskA != 0, documentA.isMaskTargetActive else {
            check(false, "document A's mask is the edit target before the mask float")
            return
        }
        reselect(documentA, imageA)
        check(moveItem.map { controllerA.validateMenuItem($0) } == true,
              "the float validates on a mask target (no structured-source gate on the mask)")
        if let moveItem, let action = moveItem.action {
            NSApp.sendAction(action, to: controllerA, from: moveItem)
        }
        settle(documentA)
        let maskState = try session.floatingSelection(imageA)
        check(maskState.isActive && maskState.targetKind == .layerMask && maskState.target == maskA,
              "the float attaches to the explicit mask target")
        check(documentA.activeDrawable == maskState.floating,
              "a mask-attached floating selection owns the paint target")
        documentA.resolveFloatingSelection(.discard) { _ in }
        settle(documentA)
        documentA.returnToLayers()
        settle(documentA)

        // Channel target: the float attaches to the selected saved channel.
        reselect(documentA, imageA)
        documentA.saveSelectionToChannel(name: "float-chan")
        settle(documentA)
        guard let channelA = documentA.channels.first(where: { !$0.isQuickMask }) else {
            check(false, "document A has a saved channel to float from")
            return
        }
        documentA.selectChannel(channelA.id)
        settle(documentA)
        check(documentA.isChannelTargetActive && documentA.activeDrawable == channelA.id,
              "the channel is the paint target before the channel float")
        if let copyItem, let action = copyItem.action {
            NSApp.sendAction(action, to: controllerA, from: copyItem)
        }
        settle(documentA)
        let channelState = try session.floatingSelection(imageA)
        check(channelState.isActive && channelState.targetKind == .channel && channelState.target == channelA.id,
              "the copy float attaches to the explicit channel target")
        documentA.resolveFloatingSelection(.discard) { _ in }
        settle(documentA)
        documentA.returnToLayers()
        settle(documentA)

        // BUSY: a held exclusive engine activity refuses the float from
        // cache and at command time, with nothing queued.
        reselect(documentA, imageA)
        let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Float busy hold", work: {
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
        check(!documentA.floatReadiness(.move).allowed && !documentA.floatReadiness(.copy).allowed
                && moveItem.map { controllerA.validateMenuItem($0) } == false,
              "while the engine is busy both float items disable from cache")
        let workBeforeBusy = documentA.pendingWork
        var busyResult: Result<Void, Error>?
        documentA.floatSelectedPixels(mode: .move, target: layerA) { busyResult = $0 }
        check(busyResult != nil && documentA.pendingWork == workBeforeBusy
                && (try? session.floatingSelection(imageA))?.isActive == false,
              "the float command is refused while busy, with nothing queued")
        release.signal()
        settle(documentA)

        // Close drains the accepted float before destroying the image; a
        // late command fails through its callback without crashing.
        reselect(documentA, imageA)
        let workBeforeAccept = documentA.pendingWork
        var accepted: Result<Void, Error>?
        documentA.floatSelectedPixels(mode: .copy, target: layerA) { accepted = $0 }
        check(documentA.pendingWork > workBeforeAccept, "an accepted float is counted as pending work")
        var closedA = false
        documentA.closeImageWhenDrained { closedA = true }
        let closeDeadline = Date().addingTimeInterval(10)
        while !closedA && Date() < closeDeadline { spin(0.01) }
        check(closedA && accepted != nil && (try? session.info(imageA)) == nil,
              "close drains the accepted float before the image is destroyed, and its callback still lands")
        var lateResult: Result<Void, Error>?
        documentA.floatSelectedPixels(mode: .copy, target: layerA) { lateResult = $0 }
        check(lateResult != nil, "a float requested after close fails through its callback without crashing")
        documents.items.removeAll { $0 === documentA }
    }
}
