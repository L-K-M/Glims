import AppKit

/// Read-only session oracles for refusal checks. These never change a target
/// or finish pending input, so mask/channel admission cannot be hidden by the
/// test's own snapshot. The selected IDs and history are native, not caches.
/// Text getters require editable behavior; retained rasterized sources are
/// checked by source_info here and their original text again after Undo.
private struct LayerRasterizeBatchSnapshot: Equatable {
    let layers: [EngineSession.Layer]
    let selectedLayers: [Int32]
    let selectedChannels: [Int32]
    let sources: [Int32: EngineSession.LayerSource]
    let texts: [Int32: String]
    let mask: EngineSession.MaskState
    let pixels: Data
    let history: EngineSession.UndoInfo
    let isDirty: Bool

    init(_ session: EngineSession, image: Int32, sources ids: [Int32], masked: Int32) throws {
        layers = try session.layers(image)
        selectedLayers = try session.selectedLayers(image)
        selectedChannels = try session.selectedItems(.channel, image: image)
        var sourceStates: [Int32: EngineSession.LayerSource] = [:]
        var textStates: [Int32: String] = [:]
        for id in ids {
            let source = try session.layerSource(id, image: image)
            sourceStates[id] = source
            if !source.isRasterized { textStates[id] = try session.textLayer(image: image, layer: id).text }
        }
        sources = sourceStates
        texts = textStates
        mask = try session.layerMask(masked, image: image)
        pixels = try session.copyPixels(image, merged: true).pixels
        history = try session.undoInfo(image)
        isDirty = try session.info(image).isDirty
    }
}

private struct LayerRasterizeBatchPixels: Equatable {
    let width: Int
    let height: Int
    let origin: CGPoint
    let pixels: Data

    init(_ image: ClipboardImage) {
        width = image.width; height = image.height
        origin = image.origin; pixels = image.pixels
    }
}

@MainActor
extension EngineSmokeTest {
    /// Focused source-only fixture at authoring time. Production preceded this
    /// fixture; an independent old-menu RED has not yet been witnessed here.
    static func exerciseLayerRasterizeBatch(_ session: EngineSession, documents: DocumentList) throws {
        var ownedDocuments: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        var unmanagedImages: [Int32] = []
        var gates: [DispatchSemaphore] = []
        func waitFor(_ message: String, _ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(15)
            while Date() < end {
                if condition() { return true }
                spin(0.01)
            }
            print("focus active=\(NSApp.isActive) main=\(NSApp.mainWindow?.windowNumber ?? -1) key=\(NSApp.keyWindow?.windowNumber ?? -1)")
            for controller in controllers {
                guard let window = controller.window else { continue }
                let sheet = window.attachedSheet
                print("focus owned=\(window.windowNumber) visible=\(window.isVisible) canMain=\(window.canBecomeMain) canKey=\(window.canBecomeKey) sheet=\(sheet?.windowNumber ?? -1) sheetVisible=\(sheet?.isVisible == true) sheetKey=\(sheet?.isKeyWindow == true)")
            }
            check(false, "Timed out: \(message)")
            return false
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch { return (error as? EngineSession.EngineError)?.isNotFound == true }
        }
        func settle() -> Bool {
            guard waitFor("batch Rasterize input/completion drains", {
                ownedDocuments.allSatisfy { $0.pendingWork == 0 } && !EngineActivity.shared.isBusy
            }) else { return false }
            spin(0.03); return true
        }
        func newGate() -> DispatchSemaphore {
            let gate = DispatchSemaphore(value: 0); gates.append(gate); return gate
        }
        func holdInput(_ document: ImageDocument) -> DispatchSemaphore? {
            let gate = newGate(), started = DispatchSemaphore(value: 0)
            document.inputQueue.async { started.signal(); gate.wait() }
            guard waitFor("batch Rasterize input barrier starts", {
                started.wait(timeout: .now()) == .success
            }) else { return nil }
            return gate
        }
        func succeeded(_ result: Result<Void, Error>?) -> Bool {
            if case .success? = result { return true }; return false
        }
        func failed(_ result: Result<Void, Error>?) -> Bool {
            if case .failure? = result { return true }; return false
        }
        func buttons(_ root: NSView?) -> [NSButton] {
            guard let root else { return [] }
            return ((root as? NSButton).map { [$0] } ?? []) + root.subviews.flatMap { buttons($0) }
        }
        func button(_ sheet: NSWindow?, _ label: String) -> NSButton? {
            buttons(sheet?.contentView).first { $0.accessibilityLabel() == label }
        }
        func labels(_ root: NSView?) -> [String] {
            guard let root else { return [] }
            return ((root as? NSTextField).map { [$0.stringValue] } ?? []) + root.subviews.flatMap { labels($0) }
        }
        func sameLayout(_ before: [EngineSession.Layer], _ after: [EngineSession.Layer]) -> Bool {
            guard before.count == after.count else { return false }
            return zip(before, after).allSatisfy { lhs, rhs in
                lhs.id == rhs.id && lhs.parent == rhs.parent && lhs.depth == rhs.depth
                    && lhs.name == rhs.name && lhs.mode == rhs.mode && lhs.isVisible == rhs.isVisible
                    && lhs.hasMask == rhs.hasMask && lhs.opacity == rhs.opacity
                    && lhs.bounds == rhs.bounds && lhs.filterCount == rhs.filterCount
            }
        }
        // Used only while idle and on layer targets. Each read restores the
        // native ordered selection before any main-loop spin. Refusal oracles
        // above never use it, particularly while mask/channel editing or held.
        func sourcePixels(_ image: Int32, ids: [Int32]) throws -> [Int32: LayerRasterizeBatchPixels] {
            let selected = try session.selectedLayers(image)
            do {
                var result: [Int32: LayerRasterizeBatchPixels] = [:]
                for id in ids {
                    try session.selectLayer(id, image: image)
                    result[id] = LayerRasterizeBatchPixels(try session.copyPixels(image, merged: false))
                }
                try session.selectLayers(selected, image: image)
                return result
            } catch { try? session.selectLayers(selected, image: image); throw error }
        }
        func hasPartialAlpha(_ source: LayerRasterizeBatchPixels?) -> Bool {
            guard let source else { return false }
            let bytes = Array(source.pixels)
            return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] > 0 && bytes[$0] < 255 }
        }
        defer {
            gates.forEach { $0.signal() }
            var stoppedAll = true
            for controller in controllers {
                if let sheet = controller.window?.attachedSheet {
                    NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.abort.rawValue)
                }
                controller.window?.orderOut(nil)
                var stopped = false
                controller.canvas.stopRendering { stopped = true }
                stoppedAll = waitFor("owned batch Rasterize canvas drains", { stopped }) && stoppedAll
            }
            check(stoppedAll, "batch Rasterize teardown drains every owned renderer")
            for document in ownedDocuments { document.closeImageWhenDrained() }
            let closedAll = waitFor("owned batch Rasterize native images close", {
                ownedDocuments.allSatisfy { gone($0.image) } && !EngineActivity.shared.isBusy
            })
            check(closedAll, "batch Rasterize teardown closes every owned native image")
            for controller in controllers { controller.window?.close() }
            spin(0.03)
            check(controllers.allSatisfy { $0.window?.attachedSheet == nil },
                  "batch Rasterize teardown leaves no owned confirmation sheet")
            documents.items.removeAll { candidate in ownedDocuments.contains { $0 === candidate } }
            for image in unmanagedImages { try? session.closeImage(image) }
        }

        let imageA = try session.newImage(width: 160, height: 96); unmanagedImages.append(imageA)
        guard let plain = try session.layers(imageA).first?.id else {
            return check(false, "batch Rasterize fixture has an ordinary third layer")
        }
        try session.fill(image: imageA, at: .zero, mode: .selection,
                         color: NSColor(srgbRed: 0.8, green: 0.9, blue: 0.7, alpha: 1))
        var settings = EngineSession.TextSettings(); settings.size = 18
        settings.color = NSColor(srgbRed: 0.7, green: 0.1, blue: 0.2, alpha: 0.7)
        let first = try session.addTextLayer(image: imageA, text: "First A", settings: settings, at: CGPoint(x: 5, y: 8))
        settings.color = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.6, alpha: 0.8)
        let second = try session.addTextLayer(image: imageA, text: "Next A", settings: settings, at: CGPoint(x: 65, y: 49))
        let captured = [first, second]
        let group = try session.createGroup(image: imageA, index: 0, name: "Unselected group")
        _ = try session.addLayerMask(first, image: imageA, source: .white)
        try session.select(.all, image: imageA)
        let channel = try session.channelFromSelection(imageA, name: "Unselected channel")
        try session.select(.none, image: imageA)
        try session.channelCommand(.select, channel: 0, image: imageA)
        try session.selectLayers(captured, image: imageA)
        let originalPixels = try sourcePixels(imageA, ids: captured + [plain])
        let original = try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first)
        let sourceNames = captured.compactMap { id in original.layers.first { $0.id == id }?.name }
        let editable = EngineSession.LayerSource(kind: .text, isRasterized: false, hasSource: true)
        let rasterized = EngineSession.LayerSource(kind: .text, isRasterized: true, hasSource: true)
        let editableSources = [first: editable, second: editable]
        let rasterizedSources = [first: rasterized, second: rasterized]
        check(original.selectedLayers == captured && captured != original.layers.filter { captured.contains($0.id) }.map(\.id)
              && original.sources == editableSources && sourceNames.count == 2,
              "fixture has two ordered editable native sources unlike tree order, plus an ordinary third layer")
        check(original.texts == [first: "First A", second: "Next A"]
              && original.layers.first { $0.id == first }?.bounds.origin != original.layers.first { $0.id == second }?.bounds.origin,
              "native source text and asymmetric offsets are independent rasterization oracles")
        check(hasPartialAlpha(originalPixels[first]) && hasPartialAlpha(originalPixels[second])
              && originalPixels[first]?.pixels != originalPixels[second]?.pixels,
              "the retained sources have distinct nonempty partially transparent native payloads")

        let docA = try ImageDocument(session: session, image: imageA, name: "Rasterize Batch A")
        ownedDocuments.append(docA); documents.items.append(docA); unmanagedImages.removeAll { $0 == imageA }
        let controller = DocumentWindowController(document: docA); controllers.append(controller); controller.showWindow(nil)
        let imageB = try session.newImage(width: 128, height: 72); unmanagedImages.append(imageB)
        let witness = try session.addTextLayer(image: imageB, text: "Witness B", settings: settings, at: CGPoint(x: 3, y: 9))
        let docB = try ImageDocument(session: session, image: imageB, name: "Rasterize Batch B")
        ownedDocuments.append(docB); documents.items.append(docB); unmanagedImages.removeAll { $0 == imageB }
        let front = DocumentWindowController(document: docB); controllers.append(front); front.showWindow(nil)
        var errors: [String] = []
        let priorError = docA.onError
        docA.onError = { priorError?($0); errors.append($0) }
        guard settle() else { return }
        let other = try LayerRasterizeBatchSnapshot(session, image: imageB, sources: [witness], masked: witness)
        guard let item = NSApp.mainMenu?.item(withTitle: "Layer")?.submenu?.items.first(where: {
            $0.action == #selector(DocumentWindowController.rasterizeLayer(_:))
        }) else { return check(false, "the actual installed Layer menu exposes Rasterize") }
        check(controller.validateMenuItem(item) && item.title == "Rasterize Layers…",
              "the actual Layer menu admits plural Rasterize from cached retained-source state")
        func openSheet() -> NSWindow? {
            // Engine smoke uses an accessory application without interactive
            // startup's activation. Establish actual AppKit focus explicitly.
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeMainWindow()
            controller.window?.makeKeyAndOrderFront(nil)
            guard waitFor("batch Rasterize application activates", { NSApp.isActive }) else { return nil }
            _ = NSApp.sendAction(#selector(DocumentWindowController.rasterizeLayer(_:)), to: controller, from: item)
            guard waitFor("owned batch Rasterize confirmation opens", {
                guard let sheet = controller.window?.attachedSheet else { return false }
                return sheet.isVisible && sheet.sheetParent === controller.window && NSApp.keyWindow === sheet
            }) else { return nil }
            return controller.window?.attachedSheet
        }
        guard let cancelledSheet = openSheet(), let cancel = button(cancelledSheet, "Cancel") else {
            return check(false, "owned plural Rasterize offers a real Cancel button")
        }
        check(button(cancelledSheet, "Rasterize") != nil && controller.window?.attachedSheet === cancelledSheet
              && front.window?.attachedSheet == nil, "plural Rasterize owns its labeled Apply/Cancel sheet in A alone")
        check(!controller.validateMenuItem(item), "the actual Rasterize menu refuses a second sheet while its confirmation is attached")
        cancel.performClick(nil)
        guard waitFor("batch Rasterize Cancel dismisses", { controller.window?.attachedSheet == nil }), settle() else { return }
        check(try docA.pendingWork == 0 && LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first) == original,
              "the real Cancel queues no batch and preserves sources, pixels, selection and complete native history")

        guard let applySheet = openSheet(), let apply = button(applySheet, "Rasterize") else {
            return check(false, "owned plural Rasterize offers a real Apply button")
        }
        let displayed = labels(applySheet.contentView).joined(separator: "\n")
        check(sourceNames.allSatisfy { displayed.contains($0) } && displayed.contains("Rasterize 2 Layers?"),
              "the owned plural sheet describes both captured source names and count")
        docA.selectLayer(plain); guard settle() else { return }
        front.window?.makeMainWindow()
        front.window?.makeKeyAndOrderFront(nil)
        guard waitFor("B becomes frontmost while A owns its sheet", {
            NSApp.isActive && NSApp.mainWindow === front.window && NSApp.keyWindow === front.window
        }) else { return }
        check(try session.selectedLayers(imageA) == [plain] && docA.selectedLayerIDs == [plain]
              && NSApp.mainWindow === front.window, "A's ordinary third layer is selected behind the sheet while B becomes frontmost")
        apply.performClick(nil)
        guard waitFor("batch Rasterize Apply dismisses", { controller.window?.attachedSheet == nil }), settle() else { return }
        let applied = try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first)
        check(applied.sources == rasterizedSources && docA.layerSources[first] == rasterized
              && docA.layerSources[second] == rasterized,
              "Apply rasterizes the two original captured IDs and refreshes their actual source states")
        check(try applied.selectedLayers == [plain] && docA.selectedLayerIDs == [plain]
              && session.layerSource(plain, image: imageA).kind == .pixel
              && sameLayout(original.layers, applied.layers),
              "Apply preserves A's newer ordinary-layer selection, every layer ID, tree, name, bounds and mask")
        check(try applied.sources.values.allSatisfy(\.hasSource) && applied.pixels == original.pixels
              && sourcePixels(imageA, ids: captured + [plain]) == originalPixels,
              "Apply retains both structured sources and every independent native source/composite pixel")
        check(applied.history.undoCount == original.history.undoCount + 1 && docA.pendingWork == 0,
              "the real plural Apply is one native Undo with counted work fully drained")
        check(try LayerRasterizeBatchSnapshot(session, image: imageB, sources: [witness], masked: witness) == other,
              "frontmost B keeps its editable source, selected IDs, pixels, tree and full history")
        docA.selectLayers(captured); guard settle() else { return }
        check(!controller.validateMenuItem(item) && item.toolTip?.contains("already rasterized") == true,
              "the plural menu stops offering confirmation when all captured sources are rasterized")
        var noOp: Result<Void, Error>?, noOpCount = 0
        let noOpBefore = try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first)
        docA.rasterizeLayerSources(captured) { noOp = $0; noOpCount += 1 }
        guard settle() else { return }
        check(try succeeded(noOp) && noOpCount == 1
              && LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first) == noOpBefore,
              "an explicit all-no-op vector completes once without pixels, source, selection or history changes")
        docA.undo(); guard settle() else { return }
        let undone = try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first)
        check(undone.sources == editableSources && undone.history.undoCount == original.history.undoCount,
              "one document Undo restores both editable sources and the prior native history depth")
        check(try undone.pixels == original.pixels && undone.texts == original.texts
              && sourcePixels(imageA, ids: captured + [plain]) == originalPixels,
              "Undo restores original source/composite bytes and retained text")
        docA.redo(); guard settle() else { return }
        let redone = try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first)
        check(try redone.sources == rasterizedSources && redone.history.undoCount == original.history.undoCount + 1
              && redone.pixels == original.pixels && sourcePixels(imageA, ids: captured + [plain]) == originalPixels,
              "one document Redo restores both rasterized sources, exact pixels and one history step")
        docA.undo(); guard settle() else { return }
        docA.selectLayers(captured); guard settle() else { return }

        // Cached whole-vector refusals: the last member cannot silently
        // leave the first source rasterized or invoke a native partial edit.
        for (ids, reason) in [([first, Int32.max], "unknown last ID"), ([first, group], "group last ID")] {
            let before = try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first)
            let errorCount = errors.count
            var result: Result<Void, Error>?, count = 0
            docA.rasterizeLayerSources(ids) { result = $0; count += 1 }
            check(failed(result) && count == 1 && docA.pendingWork == 0 && errors.count == errorCount + 1,
                  "cached \(reason) refuses the complete vector with one completion/report and no queued work")
            check(try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first) == before,
                  "cached \(reason) preserves both source states, pixels, selection and complete history")
        }
        docA.selectLayers([first, group]); guard settle() else { return }
        check(!controller.validateMenuItem(item) && item.toolTip?.contains("source") == true,
              "the actual plural menu refuses a group even when the first selected source is editable")
        docA.selectLayers(captured); guard settle() else { return }
        docA.editMask(first); guard settle() else { return }
        let masked = try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first)
        var maskResult: Result<Void, Error>?, maskCount = 0
        docA.rasterizeLayerSources(captured) { maskResult = $0; maskCount += 1 }
        check(docA.isMaskTargetActive && masked.mask.editing && !controller.validateMenuItem(item)
              && failed(maskResult) && maskCount == 1 && docA.pendingWork == 0,
              "a real mask target disables the menu and refuses explicit source-vector admission")
        check(try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first) == masked,
              "mask refusal preserves mask flags, sources, selection, pixels and history")
        docA.selectLayers(captured); guard settle() else { return }
        docA.selectChannel(channel); guard settle() else { return }
        let channelState = try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first)
        var channelResult: Result<Void, Error>?, channelCount = 0
        docA.rasterizeLayerSources(captured) { channelResult = $0; channelCount += 1 }
        check(docA.isChannelTargetActive && channelState.selectedChannels == [channel]
              && !controller.validateMenuItem(item) && failed(channelResult) && channelCount == 1 && docA.pendingWork == 0,
              "a real selected channel disables the menu and refuses the captured layer vector")
        check(try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first) == channelState,
              "channel refusal preserves selected channels, both sources, pixels and history")
        docA.selectLayers(captured); guard settle() else { return }

        // A late global activity owns no native lock, so direct native reads
        // remain safe while the sheet's Apply and service refuse admission.
        guard let busySheet = openSheet(), let busyApply = button(busySheet, "Rasterize") else {
            return check(false, "busy-before-Apply fixture opens its owned confirmation")
        }
        let busyBefore = try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first)
        let activityGate = newGate()
        var activityDone = false
        let activityAccepted = EngineActivity.shared.perform(label: "Batch Rasterize busy fixture", work: {
            activityGate.wait()
        }, completion: { activityDone = true })
        check(activityAccepted && EngineActivity.shared.isBusy && !controller.validateMenuItem(item),
              "an accepted engine activity disables the real Rasterize menu")
        var busyResult: Result<Void, Error>?, busyCount = 0
        docA.rasterizeLayerSources(captured) { busyResult = $0; busyCount += 1 }
        let busyRefusal: Bool
        if case .failure(ImageDocument.DocumentError.busy)? = busyResult { busyRefusal = true } else { busyRefusal = false }
        check(busyRefusal && busyCount == 1 && docA.pendingWork == 0,
              "busy direct vector admission refuses once before queueing")
        busyApply.performClick(nil)
        guard waitFor("late busy Apply dismisses its owned sheet", { controller.window?.attachedSheet == nil }) else { return }
        check(try docA.pendingWork == 0
              && LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first) == busyBefore,
              "a late busy Apply queues nothing and preserves the complete native image state")
        activityGate.signal()
        guard waitFor("busy fixture activity releases", { activityDone && !EngineActivity.shared.isBusy }), settle() else { return }

        let priorEndEdits = docA.onWillChangeLayers
        let fieldGate = newGate()
        var fieldActivity = false, fieldActivityDone = false
        let fieldBefore = try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first)
        docA.onWillChangeLayers = {
            priorEndEdits?()
            fieldActivity = EngineActivity.shared.perform(label: "Batch Rasterize field commit", work: {
                fieldGate.wait()
            }, completion: { fieldActivityDone = true })
        }
        var fieldResult: Result<Void, Error>?, fieldCount = 0
        docA.rasterizeLayerSources(captured) { fieldResult = $0; fieldCount += 1 }
        docA.onWillChangeLayers = priorEndEdits
        let fieldBusyRefusal: Bool
        if case .failure(ImageDocument.DocumentError.busy)? = fieldResult { fieldBusyRefusal = true } else { fieldBusyRefusal = false }
        check(fieldActivity && fieldBusyRefusal && fieldCount == 1 && docA.pendingWork == 0,
              "an activity begun by field commit is rechecked before any source-vector work is accepted")
        check(try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first) == fieldBefore,
              "the field-commit admission refusal preserves both sources, pixels and history")
        fieldGate.signal()
        guard waitFor("field-commit activity releases", { fieldActivityDone && !EngineActivity.shared.isBusy }), settle() else { return }

        guard let targetGate = holdInput(docA) else { return }
        docA.layerCommand(.new)
        var pendingResult: Result<Void, Error>?, pendingCount = 0
        docA.rasterizeLayerSources(captured) { pendingResult = $0; pendingCount += 1 }
        check(docA.targetCommandIsPending && failed(pendingResult) && pendingCount == 1 && !controller.validateMenuItem(item),
              "a queued replacement target disables the actual menu and refuses captured Rasterize")
        targetGate.signal(); guard settle() else { return }
        check(try session.layerSource(first, image: imageA) == editable && session.layerSource(second, image: imageA) == editable
              && session.layers(imageA).count == original.layers.count + 1,
              "pending-target refusal leaves only the admitted New Layer without rasterizing either source")
        docA.undo(); guard settle() else { return }
        docA.selectLayers(captured); guard settle() else { return }

        // Admit while caches are valid, delete the last native source behind
        // the Swift-only input barrier, then release. No reload or queue.sync
        // is performed while held; the command must reach native preflight.
        guard let staleGate = holdInput(docA) else { return }
        let errorsBeforeStale = errors.count
        var staleResult: Result<Void, Error>?, staleCount = 0, stalePendingAtCompletion = 0
        docA.rasterizeLayerSources(captured) {
            staleResult = $0; staleCount += 1; stalePendingAtCompletion = docA.pendingWork
        }
        check(docA.pendingWork > 0 && docA.targetCommandIsPending && staleResult == nil,
              "an admitted source vector is counted before the held input worker runs")
        _ = try session.layerCommand(.delete, image: imageA, layer: second)
        let staleBefore = try LayerRasterizeBatchSnapshot(session, image: imageA, sources: [first], masked: first)
        staleGate.signal(); guard settle() else { return }
        let staleIsNotFound: Bool
        if case .failure(let error)? = staleResult { staleIsNotFound = (error as? EngineSession.EngineError)?.isNotFound == true }
        else { staleIsNotFound = false }
        check(staleIsNotFound && staleCount == 1 && stalePendingAtCompletion > 0
              && !docA.targetCommandIsPending && errors.count == errorsBeforeStale + 1,
              "a deleted last native source reports NOT_FOUND exactly once before its counted completion drains")
        check(try LayerRasterizeBatchSnapshot(session, image: imageA, sources: [first], masked: first) == staleBefore,
              "native last-member refusal leaves the first source editable and preserves post-delete pixels/history")
        docA.undo(); guard settle() else { return }
        docA.selectLayers(captured); guard settle() else { return }
        check(try session.layerSource(first, image: imageA) == editable && session.layerSource(second, image: imageA) == editable,
              "Undo of the independent deletion restores both original editable source IDs")

        // Keep one already accepted vector alive across close. Late Apply on
        // the earlier owned sheet must not enqueue a second vector. A global
        // Swift-only activity then defers the existing completion delivery.
        guard let closingSheet = openSheet(), let lateApply = button(closingSheet, "Rasterize"),
              let closeInputGate = holdInput(docA) else {
            return check(false, "closing fixture owns its original confirmation and input barrier")
        }
        let closingBefore = try LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first)
        var acceptedResult: Result<Void, Error>?, acceptedCount = 0, pendingAtCompletion = 0
        var completionSnapshot: LayerRasterizeBatchSnapshot?
        docA.rasterizeLayerSources(captured) {
            acceptedResult = $0; acceptedCount += 1; pendingAtCompletion = docA.pendingWork
            completionSnapshot = try? LayerRasterizeBatchSnapshot(session, image: imageA, sources: captured, masked: first)
        }
        let pendingBeforeClose = docA.pendingWork
        check(pendingBeforeClose > 0 && acceptedResult == nil, "the final vector is accepted and counted before close starts")
        docA.beginClosing()
        var closedResult: Result<Void, Error>?, closedCount = 0
        docA.rasterizeLayerSources(captured) { closedResult = $0; closedCount += 1 }
        let closedRefusal: Bool
        if case .failure(ImageDocument.DocumentError.closed)? = closedResult { closedRefusal = true } else { closedRefusal = false }
        check(closedRefusal && closedCount == 1 && docA.pendingWork == pendingBeforeClose,
              "a closing document refuses a new explicit vector once without adding work")
        let errorsBeforeLateApply = errors.count
        lateApply.performClick(nil)
        guard waitFor("late closing Apply dismisses its sheet", { controller.window?.attachedSheet == nil }) else { return }
        check(docA.pendingWork == pendingBeforeClose && errors.count == errorsBeforeLateApply,
              "late sheet Apply after close admission queues no second vector and reports no spurious error")
        let closeActivityGate = newGate(), closeActivityStarted = DispatchSemaphore(value: 0)
        var closeActivityDone = false
        let closeActivityAccepted = EngineActivity.shared.perform(label: "Batch Rasterize deferred completion", work: {
            closeActivityStarted.signal(); closeActivityGate.wait()
        }, completion: { closeActivityDone = true })
        controller.window?.close()
        closeInputGate.signal()
        guard closeActivityAccepted, waitFor("closing activity begins after accepted rasterization", {
            closeActivityStarted.wait(timeout: .now()) == .success
        }) else { return check(false, "the close-drain activity is accepted") }
        check(acceptedResult == nil && docA.pendingWork > 0 && !gone(imageA),
              "close retains the native image while an accepted Rasterize completion is deferred")
        check(try session.layerSource(first, image: imageA) == rasterized
              && session.layerSource(second, image: imageA) == rasterized
              && session.undoInfo(imageA).undoCount == closingBefore.history.undoCount + 1,
              "the accepted original vector finishes natively once while close waits for its completion")
        closeActivityGate.signal()
        guard waitFor("accepted source completion and native close finish", {
            closeActivityDone && acceptedCount == 1 && docA.pendingWork == 0 && gone(imageA)
        }) else { return }
        check(succeeded(acceptedResult) && acceptedCount == 1 && pendingAtCompletion > 0,
              "accepted Rasterize completes exactly once before the final counted stage drains")
        check(completionSnapshot?.sources == rasterizedSources
              && completionSnapshot?.pixels == closingBefore.pixels
              && completionSnapshot?.history.undoCount == closingBefore.history.undoCount + 1,
              "the completion observes retained sources, unchanged pixels and one Undo before native destruction")
        check(gone(imageA) && docA.pendingWork == 0,
              "A is natively NOT_FOUND only after its accepted source work and completion drain")
        check(try LayerRasterizeBatchSnapshot(session, image: imageB, sources: [witness], masked: witness) == other,
              "B remains unchanged through A's refusals, accepted work and late-close teardown")
    }
}
