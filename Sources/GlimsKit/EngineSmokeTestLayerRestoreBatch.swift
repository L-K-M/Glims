import AppKit

private struct LayerRestoreBatchPixels: Equatable {
    let width: Int
    let height: Int
    let origin: CGPoint
    let bytes: Data

    init(_ value: ClipboardImage) {
        width = value.width; height = value.height; origin = value.origin; bytes = value.pixels
    }
}

/// Read-only native state, including ordered targets and full history. This
/// never repairs the target or reloads a document while testing refusal.
private struct LayerRestoreBatchState: Equatable {
    let layers: [EngineSession.Layer]
    let selected: [Int32]
    let channels: [Int32]
    let sources: [Int32: EngineSession.LayerSource]
    let mask: EngineSession.MaskState
    let pixels: Data
    let history: EngineSession.UndoInfo
    let dirty: Bool

    init(_ session: EngineSession, image: Int32, ids: [Int32], mask layer: Int32) throws {
        layers = try session.layers(image)
        selected = try session.selectedLayers(image)
        channels = try session.selectedItems(.channel, image: image)
        var values: [Int32: EngineSession.LayerSource] = [:]
        for id in ids { values[id] = try session.layerSource(id, image: image) }
        sources = values
        mask = try session.layerMask(layer, image: image)
        pixels = try session.copyPixels(image, merged: true).pixels
        history = try session.undoInfo(image)
        dirty = try session.info(image).isDirty
    }
}

@MainActor
extension EngineSmokeTest {
    /// Source-authored acceptance fixture. Root supplies the launched AppKit
    /// host and immutable API166 producer; authoring is not runtime evidence.
    static func exerciseLayerRestoreBatch(_ session: EngineSession, documents: DocumentList) throws {
        var owned: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        var unmanaged: [Int32] = []
        var gates: [DispatchSemaphore] = []
        var finished = false
        func pump() {
            let end = Date().addingTimeInterval(0.01)
            repeat {
                while Date() < end,
                      let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                    NSApp.sendEvent(event)
                }
                NSApp.updateWindows()
                _ = RunLoop.main.run(mode: .default, before: end)
            } while Date() < end
        }
        func wait(_ label: String, _ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(15)
            while !condition(), Date() < end { pump() }
            if condition() { return true }
            print("batch Restore focus active=\(NSApp.isActive) main=\(NSApp.mainWindow?.windowNumber ?? -1) key=\(NSApp.keyWindow?.windowNumber ?? -1)")
            check(false, "batch Restore timed out: \(label)")
            return false
        }
        func settle() -> Bool {
            wait("counted work drains", { owned.allSatisfy { $0.pendingWork == 0 } && !EngineActivity.shared.isBusy })
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        func gate() -> DispatchSemaphore {
            let value = DispatchSemaphore(value: 0); gates.append(value); return value
        }
        func hold(_ document: ImageDocument) -> DispatchSemaphore? {
            let value = gate(), began = DispatchSemaphore(value: 0)
            document.inputQueue.async { began.signal(); value.wait() }
            var started = false
            return wait("input barrier starts", {
                if !started { started = began.wait(timeout: .now()) == .success }
                return started
            }) ? value : nil
        }
        func success(_ value: Result<Void, Error>?) -> Bool {
            if case .success? = value { return true }; return false
        }
        func failure(_ value: Result<Void, Error>?) -> Bool {
            if case .failure? = value { return true }; return false
        }
        func buttons(_ view: NSView?) -> [NSButton] {
            guard let view else { return [] }
            return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons($0) }
        }
        func button(_ sheet: NSWindow?, _ title: String) -> NSButton? {
            buttons(sheet?.contentView).first { $0.accessibilityLabel() == title }
        }
        func labels(_ view: NSView?) -> [String] {
            guard let view else { return [] }
            return ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap { labels($0) }
        }
        // Idle-only native oracle, preserving the caller's ordered selection
        // before any event-pump turn. Never used for mask/channel refusals.
        func layerPixels(_ image: Int32, ids: [Int32]) throws -> [Int32: LayerRestoreBatchPixels] {
            let prior = try session.selectedLayers(image)
            defer { try? session.selectLayers(prior, image: image) }
            var result: [Int32: LayerRestoreBatchPixels] = [:]
            for id in ids {
                try session.selectLayer(id, image: image)
                result[id] = LayerRestoreBatchPixels(try session.copyPixels(image, merged: false))
            }
            return result
        }
        defer {
            gates.forEach { $0.signal() }
            var stoppedAll = true
            for controller in controllers {
                if let sheet = controller.window?.attachedSheet { NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.abort.rawValue) }
                controller.window?.orderOut(nil)
                var stopped = false
                controller.canvas.stopRendering { stopped = true }
                stoppedAll = wait("owned renderer stops", { stopped }) && stoppedAll
            }
            check(stoppedAll, "batch Restore teardown drains every owned renderer")
            owned.forEach { $0.closeImageWhenDrained() }
            check(wait("owned images close", { owned.allSatisfy { gone($0.image) } && !EngineActivity.shared.isBusy }),
                  "batch Restore teardown closes every owned native image")
            controllers.forEach { $0.window?.close() }
            pump()
            check(controllers.allSatisfy { $0.window?.attachedSheet == nil }, "batch Restore teardown leaves no owned dialog")
            documents.items.removeAll { candidate in owned.contains { $0 === candidate } }
            unmanaged.forEach { try? session.closeImage($0) }
            check(finished, "batch Restore completes every acceptance scenario")
        }

        let imageA = try session.newImage(width: 160, height: 96); unmanaged.append(imageA)
        guard let plain = try session.layers(imageA).first?.id else { return check(false, "Restore fixture has an ordinary layer") }
        var settings = EngineSession.TextSettings(); settings.size = 18
        settings.color = NSColor(srgbRed: 0.7, green: 0.1, blue: 0.2, alpha: 0.7)
        let first = try session.addTextLayer(image: imageA, text: "Restore first", settings: settings, at: CGPoint(x: 4, y: 8))
        settings.color = NSColor(srgbRed: 0.1, green: 0.2, blue: 0.6, alpha: 0.8)
        let second = try session.addTextLayer(image: imageA, text: "Restore next", settings: settings, at: CGPoint(x: 61, y: 47))
        let ids = [first, second]
        let group = try session.createGroup(image: imageA, index: 0, name: "Unselected group")
        _ = try session.addLayerMask(first, image: imageA, source: .white)
        try session.select(.all, image: imageA)
        let channel = try session.channelFromSelection(imageA, name: "Unselected channel")
        try session.select(.none, image: imageA)
        try session.channelCommand(.select, channel: 0, image: imageA)
        try session.selectLayers(ids, image: imageA)
        let sourcePixels = try layerPixels(imageA, ids: ids + [plain])
        let editable = EngineSession.LayerSource(kind: .text, isRasterized: false, hasSource: true)
        let rasterized = EngineSession.LayerSource(kind: .text, isRasterized: true, hasSource: true)
        let editableSources = [first: editable, second: editable]
        let rasterizedSources = [first: rasterized, second: rasterized]
        check(try session.layerSource(first, image: imageA) == editable && session.layerSource(second, image: imageA) == editable
              && sourcePixels[first] != sourcePixels[second], "independent native source pixels precede rasterization and differ asymmetrically")
        try session.rasterizeLayers(imageA, layers: ids)
        for (index, id) in ids.enumerated() {
            try session.selectLayer(id, image: imageA)
            try session.fill(image: imageA, at: .zero, mode: .selection,
                color: index == 0 ? .green : .orange)
        }
        try session.selectLayers(ids, image: imageA)
        let damagedPixels = try layerPixels(imageA, ids: ids + [plain])
        let damaged = try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first)
        check(damaged.sources == rasterizedSources && damagedPixels[first] != sourcePixels[first]
              && damagedPixels[second] != sourcePixels[second], "two real rasterized retained sources have demonstrably damaged drawable bytes")
        check(damaged.selected == ids && ids != damaged.layers.filter { ids.contains($0.id) }.map(\.id),
              "captured order differs from tree order and names two exact retained objects")
        let docA = try ImageDocument(session: session, image: imageA, name: "Restore Batch A")
        owned.append(docA); documents.items.append(docA); unmanaged.removeAll { $0 == imageA }
        let owner = DocumentWindowController(document: docA); controllers.append(owner); owner.showWindow(nil)
        let imageB = try session.newImage(width: 128, height: 72); unmanaged.append(imageB)
        let witness = try session.addTextLayer(image: imageB, text: "Witness B", settings: settings, at: CGPoint(x: 3, y: 9))
        let docB = try ImageDocument(session: session, image: imageB, name: "Restore Batch B")
        owned.append(docB); documents.items.append(docB); unmanaged.removeAll { $0 == imageB }
        let front = DocumentWindowController(document: docB); controllers.append(front); front.showWindow(nil)
        var errors: [String] = []
        let priorError = docA.onError
        docA.onError = { priorError?($0); errors.append($0) }
        guard settle() else { return }
        let other = try LayerRestoreBatchState(session, image: imageB, ids: [witness], mask: witness)
        let palette = LayersPaletteController()
        _ = palette.view
        palette.retarget(to: docA)
        defer { palette.retarget(to: nil) }
        guard let paletteItem = palette.paletteMenu?.items.first(where: { $0.title == "Restore Layer Source…" }) else {
            return check(false, "Layers palette exposes the finite Restore source action")
        }
        check(palette.validateMenuItem(paletteItem) && paletteItem.title == "Restore Layer Sources…",
              "Layers palette mirrors the same cached plural Restore admission")
        palette.retarget(to: docB)
        let stalePaletteRefused = !palette.validateMenuItem(paletteItem)
        _ = NSApp.sendAction(paletteItem.action!, to: palette, from: paletteItem)
        guard settle() else { return }
        check(try stalePaletteRefused && owner.window?.attachedSheet == nil && front.window?.attachedSheet == nil
              && LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first) == damaged
              && LayerRestoreBatchState(session, image: imageB, ids: [witness], mask: witness) == other,
              "a palette menu captured for A refuses after retarget to B without opening consent or mutating either document")
        palette.retarget(to: docA)
        guard settle() else { return }
        guard let item = NSApp.mainMenu?.item(withTitle: "Layer")?.submenu?.items.first(where: {
            $0.action == #selector(DocumentWindowController.restoreLayerSource(_:))
        }) else { return check(false, "installed Layer menu contains Restore Layer Source") }
        check(owner.validateMenuItem(item) && item.title == "Restore Layer Sources…",
              "installed menu admits the plural captured Restore from cached source state")
        func openSheet(viaPalette: Bool = false) -> NSWindow? {
            NSApp.activate(ignoringOtherApps: true)
            owner.window?.makeMain(); owner.window?.makeKeyAndOrderFront(nil)
            guard wait("application activates", { NSApp.isActive }) else { return nil }
            if viaPalette { _ = NSApp.sendAction(paletteItem.action!, to: palette, from: paletteItem) }
            else { _ = NSApp.sendAction(item.action!, to: owner, from: item) }
            guard wait("owned Restore sheet opens", {
                guard let sheet = owner.window?.attachedSheet else { return false }
                return sheet.isVisible && sheet.sheetParent === owner.window && NSApp.keyWindow === sheet
            }) else { return nil }
            return owner.window?.attachedSheet
        }
        guard let cancelled = openSheet(viaPalette: true), let cancel = button(cancelled, "Cancel") else { return check(false, "real Restore Cancel is present") }
        check(button(cancelled, "Restore") != nil && front.window?.attachedSheet == nil,
              "Restore owns real labeled buttons in A alone")
        check(!owner.validateMenuItem(item), "attached Restore consent disables duplicate menu admission")
        cancel.performClick(nil)
        guard wait("Cancel dismisses", { owner.window?.attachedSheet == nil }), settle() else { return }
        check(try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first) == damaged && docA.pendingWork == 0,
              "real Cancel preserves exact sources, pixels, targets and complete native history without work")

        guard let sheet = openSheet(), let apply = button(sheet, "Restore") else { return check(false, "real Restore Apply is present") }
        let text = labels(sheet.contentView).joined(separator: "\n")
        let names = ids.compactMap { id in damaged.layers.first { $0.id == id }?.name }
        check(names.count == 2 && names.allSatisfy { text.contains($0) } && text.contains("Restore 2 Layer Sources?")
              && text.contains("pixel edits") && text.contains("current readable file") && text.contains("masks"),
              "plural consent describes captured names, pixel loss, current linked files and possible mask geometry changes")
        docA.selectLayer(plain); guard settle() else { return }
        front.window?.makeMain(); front.window?.makeKeyAndOrderFront(nil)
        guard wait("B becomes frontmost while A owns Restore", {
            NSApp.isActive && NSApp.mainWindow === front.window && NSApp.keyWindow === front.window
        }) else { return }
        check(try session.selectedLayers(imageA) == [plain] && docA.selectedLayerIDs == [plain],
              "A's ordinary third layer is selected after capture while genuine B is frontmost")
        apply.performClick(nil)
        guard wait("Apply dismisses", { owner.window?.attachedSheet == nil }), settle() else { return }
        let restored = try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first)
        check(restored.sources == editableSources && docA.layerSources[first] == editable && docA.layerSources[second] == editable,
              "actual Apply restores only the two originally captured retained sources and refreshes their states")
        check(try layerPixels(imageA, ids: ids + [plain]) == sourcePixels && restored.selected == [plain]
              && docA.selectedLayerIDs == [plain] && restored.mask == damaged.mask,
              "Restore regenerates independent original source pixels while preserving the newer ordinary target and attached mask")
        check(restored.history.undoCount == damaged.history.undoCount + 1 && docA.pendingWork == 0,
              "plural Restore is one native Undo and drains its counted exclusive work")
        check(try LayerRestoreBatchState(session, image: imageB, ids: [witness], mask: witness) == other,
              "frontmost B keeps its source, complete history, pixels and target unchanged")
        docA.selectLayers(ids); guard settle() else { return }
        check(!owner.validateMenuItem(item) && item.toolTip?.contains("already editable") == true,
              "confirmation is unavailable when every source is already editable")
        var noOp: Result<Void, Error>?, noOpCount = 0
        let beforeNoOp = try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first)
        docA.restoreLayerSources(ids) { noOp = $0; noOpCount += 1 }
        guard settle() else { return }
        check(try success(noOp) && noOpCount == 1 && LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first) == beforeNoOp,
              "an explicit all-editable no-op completes once without adding history or changing state")
        docA.undo(); guard settle() else { return }
        check(try session.layerSource(first, image: imageA) == rasterized && session.layerSource(second, image: imageA) == rasterized
              && layerPixels(imageA, ids: ids + [plain]) == damagedPixels && session.undoInfo(imageA).undoCount == damaged.history.undoCount,
              "one document Undo restores exact damaged buffers and both retained raster states")
        docA.redo(); guard settle() else { return }
        check(try session.layerSource(first, image: imageA) == editable && session.layerSource(second, image: imageA) == editable
              && layerPixels(imageA, ids: ids + [plain]) == sourcePixels && session.undoInfo(imageA).undoCount == damaged.history.undoCount + 1,
              "one document Redo regenerates original text bytes and both editable source states")
        docA.undo(); guard settle() else { return }
        docA.selectLayers(ids); guard settle() else { return }

        for (vector, label) in [([first, Int32.max], "unknown last ID"), ([first, group], "group last ID"), ([first, plain], "ordinary last ID")] {
            let before = try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first)
            var result: Result<Void, Error>?, count = 0
            let beforeErrors = errors.count
            docA.restoreLayerSources(vector) { result = $0; count += 1 }
            check(failure(result) && count == 1 && errors.count == beforeErrors + 1 && docA.pendingWork == 0,
                  "cached \(label) refuses the complete vector exactly once before work")
            check(try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first) == before,
                  "cached \(label) preserves all native source, pixel, target and history state")
        }
        docA.setLayerLocks(second, .pixels, to: true); guard settle() else { return }
        let locked = try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first)
        var lockResult: Result<Void, Error>?
        docA.restoreLayerSources(ids) { lockResult = $0 }
        check(!owner.validateMenuItem(item) && failure(lockResult) && docA.pendingWork == 0,
              "a real last-member pixel lock disables menu and explicit vector admission")
        check(try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first) == locked,
              "whole-vector lock refusal preserves every retained source and native history")
        docA.setLayerLocks(second, .pixels, to: false); guard settle() else { return }
        docA.editMask(first); guard settle() else { return }
        let masked = try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first)
        var maskResult: Result<Void, Error>?
        docA.restoreLayerSources(ids) { maskResult = $0 }
        check(docA.isMaskTargetActive && !owner.validateMenuItem(item) && failure(maskResult)
              && docA.pendingWork == 0, "real mask editing refuses batch Restore in menu and service")
        check(try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first) == masked,
              "mask-target refusal preserves mask flags and the entire native image state")
        docA.selectLayers(ids); guard settle() else { return }
        docA.selectChannel(channel); guard settle() else { return }
        let channelState = try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first)
        var channelResult: Result<Void, Error>?
        docA.restoreLayerSources(ids) { channelResult = $0 }
        check(docA.isChannelTargetActive && !owner.validateMenuItem(item) && failure(channelResult)
              && docA.pendingWork == 0, "real selected channel refuses batch Restore in menu and service")
        check(try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first) == channelState,
              "channel-target refusal preserves ordered channels and full native state")
        docA.selectLayers(ids); guard settle() else { return }

        guard let busySheet = openSheet(), let busyApply = button(busySheet, "Restore") else { return }
        let busyBefore = try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first)
        let busyGate = gate(); var busyDone = false
        let busyAccepted = EngineActivity.shared.perform(label: "Restore busy fixture", work: { busyGate.wait() }, completion: { busyDone = true })
        var busyResult: Result<Void, Error>?, busyCount = 0
        docA.restoreLayerSources(ids) { busyResult = $0; busyCount += 1 }
        check(busyAccepted && EngineActivity.shared.isBusy && !owner.validateMenuItem(item)
              && failure(busyResult) && busyCount == 1 && docA.pendingWork == 0,
              "an engine-wide busy owner refuses the captured service and real menu before work")
        busyApply.performClick(nil)
        guard wait("late busy consent dismisses", { owner.window?.attachedSheet == nil }) else { return }
        check(try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first) == busyBefore && docA.pendingWork == 0,
              "late busy Apply never changes a captured source or native history")
        busyGate.signal(); guard wait("busy activity finishes", { busyDone }), settle() else { return }

        // Cached admission is deliberately valid while a Swift-only transport
        // barrier holds input. A real native delete then forces fresh vector
        // admission failure after the engine-wide exclusive drain.
        guard let staleGate = hold(docA) else { return }
        var staleResult: Result<Void, Error>?, staleCount = 0, stalePending = 0
        let beforeStaleErrors = errors.count
        docA.restoreLayerSources(ids) { staleResult = $0; staleCount += 1; stalePending = docA.pendingWork }
        check(docA.pendingWork > 0 && EngineActivity.shared.isBusy && staleResult == nil,
              "an accepted Restore is counted while exclusive admission waits for earlier input")
        _ = try session.layerCommand(.delete, image: imageA, layer: second)
        let afterDelete = try LayerRestoreBatchState(session, image: imageA, ids: [first], mask: first)
        staleGate.signal(); guard settle() else { return }
        let notFound: Bool
        if case .failure(let error)? = staleResult { notFound = (error as? EngineSession.EngineError)?.isNotFound == true }
        else { notFound = false }
        check(notFound && staleCount == 1 && stalePending > 0 && errors.count == beforeStaleErrors + 1,
              "fresh native last-member failure reports NOT_FOUND once before counted completion drains")
        check(try LayerRestoreBatchState(session, image: imageA, ids: [first], mask: first) == afterDelete
              && !docA.layers.contains { $0.id == second } && docA.layerSources[first] == rasterized,
              "native vector refusal changes no first source and reloads authoritative state even on failure")
        docA.undo(); guard settle() else { return }
        docA.selectLayers(ids); guard settle() else { return }
        check(try session.layerSource(first, image: imageA) == rasterized && session.layerSource(second, image: imageA) == rasterized,
              "Undo of the separate deletion restores both original captured retained IDs")

        guard let closeSheet = openSheet(), let lateApply = button(closeSheet, "Restore"), let closeGate = hold(docA) else { return }
        let beforeClose = try LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first)
        var accepted: Result<Void, Error>?, acceptedCount = 0, pendingAtCompletion = 0
        var completionState: LayerRestoreBatchState?
        docA.restoreLayerSources(ids) {
            accepted = $0; acceptedCount += 1; pendingAtCompletion = docA.pendingWork
            completionState = try? LayerRestoreBatchState(session, image: imageA, ids: ids, mask: first)
        }
        let pending = docA.pendingWork
        check(pending > 0 && accepted == nil && !gone(imageA), "accepted exclusive Restore holds the native image while waiting for input")
        docA.beginClosing()
        var rejectedClose: Result<Void, Error>?, rejectedCount = 0
        docA.restoreLayerSources(ids) { rejectedClose = $0; rejectedCount += 1 }
        let closed: Bool
        if case .failure(ImageDocument.DocumentError.closed)? = rejectedClose { closed = true } else { closed = false }
        check(closed && rejectedCount == 1 && docA.pendingWork == pending,
              "late close refuses a new vector once without dropping accepted work")
        let errorCount = errors.count
        lateApply.performClick(nil)
        guard wait("late closing consent dismisses", { owner.window?.attachedSheet == nil }) else { return }
        check(docA.pendingWork == pending && errors.count == errorCount,
              "late sheet Apply after close admission queues no second vector or spurious error")
        owner.window?.close()
        closeGate.signal()
        guard wait("accepted completion then native close", { acceptedCount == 1 && docA.pendingWork == 0 && gone(imageA) }), settle() else { return }
        check(success(accepted) && acceptedCount == 1 && pendingAtCompletion > 0,
              "already accepted Restore succeeds once before its final counted stage drains across close")
        check(completionState?.sources == editableSources && completionState?.history.undoCount == beforeClose.history.undoCount + 1
              && completionState?.pixels == restored.pixels,
              "completion observes regenerated sources, independent original composite and one Undo before native destruction")
        check(gone(imageA) && docA.pendingWork == 0, "close destroys A only after its accepted batch and completion drain")
        check(try LayerRestoreBatchState(session, image: imageB, ids: [witness], mask: witness) == other,
              "B remains unchanged through every refusal and A's accepted-close teardown")
        finished = true
    }
}
