import AppKit
import RigiUI

private struct RecorderLayerPropertiesState: Equatable {
    let layers: [EngineSession.Layer]
    let pixels: Data
    let undo: EngineSession.UndoInfo
}

@MainActor
extension EngineSmokeTest {
    /// Uses only d925 APIs so this exact fixture can witness the old0-record RED.
    static func exerciseRecorderLayerProperties(_ session: EngineSession, documents: DocumentList) throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1; check(condition, "recorder layer properties: \(message)")
        }
        func wait(_ message: String, _ condition: () -> Bool) throws {
            let until = Date().addingTimeInterval(20)
            while Date() < until {
                if condition() { return }
                EngineSmokeTestHost.pumpEvents()
            }
            throw NSError(domain: "RecorderLayerPropertiesFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: message])
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "RecorderLayerPropertiesFixture", code: 2,
                                         userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func drain(_ document: ImageDocument) throws {
            try wait("accepted property/replay/reconciliation work drains", {
                document.pendingWork == 0 && document.recorder.pendingCount == 0 &&
                    !document.recorder.isReplaying && !EngineActivity.shared.isBusy
            })
        }
        func state(_ image: Int32) throws -> RecorderLayerPropertiesState {
            RecorderLayerPropertiesState(layers: try session.layers(image),
                pixels: try session.copyPixels(image, merged: true).pixels, undo: try session.undoInfo(image))
        }
        func layer(_ image: Int32, _ id: Int32) throws -> EngineSession.Layer {
            guard let row = try session.layers(image).first(where: { $0.id == id }) else {
                throw ImageDocument.DocumentError.targetChanged
            }
            return row
        }
        func equalProperties(_ first: EngineSession.Layer, _ second: EngineSession.Layer) -> Bool {
            first.name == second.name && first.isVisible == second.isVisible &&
                first.opacity == second.opacity && first.mode == second.mode
        }
        func titles(_ document: ImageDocument) -> [String] {
            document.recorder.records.compactMap { record in
                if case .success(let command) = record.resolution { return command.title }
                return nil
            }
        }
        func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
            ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
        }
        var bytes: [UInt8] = []
        for y in 0..<29 {
            for x in 0..<41 {
                let red = UInt8((x * 17 + y * 7) % 256)
                let green = UInt8((x * 3 + y * 23) % 256)
                let blue = UInt8((x * x + y * 11 + 31) % 256)
                bytes.append(contentsOf: [red, green, blue, 255])
            }
        }
        let pixels = ClipboardImage(width: 41, height: 29, pixels: Data(bytes), origin: .zero)
        var owned: [ImageDocument] = [], windows: [DocumentWindowController] = [], loose: [Int32] = []
        var observers: [(ImageDocument, UUID)] = [], releases: [DispatchSemaphore] = []
        var complete = false
        let palette = LayersPaletteController()
        let paletteWindow = NSWindow(contentRect: NSRect(origin: CGPoint(x: 100, y: 100), size: LayersPaletteController.definition.contentSize),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        paletteWindow.isReleasedWhenClosed = false
        paletteWindow.contentView = palette.view
        func image() throws -> (image: Int32, layer: Int32, extra: Int32) {
            let id = try session.newImage(pixels: pixels); loose.append(id)
            let primary = try session.layers(id)[0].id
            guard let extra = try session.layerCommand(.new, image: id) else { throw ImageDocument.DocumentError.targetChanged }
            try session.selectLayer(primary, image: id)
            return (id, primary, extra)
        }
        func document(_ name: String) throws -> (ImageDocument, Int32, Int32) {
            let fixture = try image()
            let value = try ImageDocument(session: session, image: fixture.image, name: name)
            loose.removeAll { $0 == fixture.image }; owned.append(value); documents.items.append(value)
            return (value, fixture.layer, fixture.extra)
        }
        func hold(_ document: ImageDocument) throws -> DispatchSemaphore {
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            releases.append(release)
            document.inputQueue.async { entered.signal(); _ = release.wait(timeout: .now() + 30) }
            let accepted = entered.wait(timeout: .now() + 3) == .success
            if !accepted { release.signal() }
            try require(accepted, "bounded input hold must begin")
            return release
        }
        defer {
            releases.forEach { $0.signal() }
            observers.forEach { $0.0.removeRecorderObserver($0.1) }
            owned.forEach { $0.onRecorderChange = nil }
            palette.retarget(to: nil); paletteWindow.close()
            var stopped = 0
            for owner in windows {
                owner.window?.orderOut(nil)
                owner.canvas.stopRendering { stopped += 1 }
            }
            try? wait("fixture renderers stop", { stopped == windows.count })
            expect(stopped == windows.count, "all owned renderers stop before image destruction")
            for owner in windows { owner.window?.close() }
            for item in owned { item.closeImageWhenDrained() }
            try? wait("all owned native images close", { owned.allSatisfy { (try? session.info($0.image)) == nil } })
            expect(owned.allSatisfy { $0.pendingWork == 0 && (try? session.info($0.image)) == nil },
                   "all owned native images and accepted completion work drain")
            documents.items.removeAll { candidate in owned.contains { $0 === candidate } }
            loose.forEach { try? session.closeImage($0) }
            expect(!paletteWindow.isVisible && windows.allSatisfy { $0.window?.attachedSheet == nil }, "no owned palette or dialog remains")
            expect(complete, "all admitted property scenarios complete (or stop at the explicit baseline RED)")
            print("     recorder-layer-properties checks: \(checks)")
        }

        let (a, layerA, extraA) = try document("Recorder properties A")
        let (b, layerB, _) = try document("Recorder properties B")
        let reference = try image()
        let ownerA = DocumentWindowController(document: a), ownerB = DocumentWindowController(document: b)
        windows += [ownerA, ownerB]
        ownerA.showWindow(nil); ownerB.showWindow(nil); paletteWindow.orderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        ownerA.window?.makeMain(); ownerA.window?.makeKeyAndOrderFront(nil)
        try wait("A actually owns key/main focus", { NSApp.isActive && NSApp.keyWindow === ownerA.window && NSApp.mainWindow === ownerA.window })
        palette.retarget(to: a); palette.view.layoutSubtreeIfNeeded()
        guard let row = descendants(palette.view, ClassicValueSlider.self).first(where: { $0.accessibilityTitle == "Layer opacity" }),
              let field = descendants(row, NSTextField.self).first(where: { $0.isEditable }) else {
            return expect(false, "installed Layers opacity row and field exist")
        }
        try wait("retargeted actual opacity row becomes available", { row.isEnabled && field.isEnabled })
        expect(!row.isHidden && field.accessibilityLabel() == "Layer opacity value", "actual labelled Layers opacity row is visible and enabled")
        let source = try session.copyPixels(a.image, merged: false).pixels
        let untouchedB = try state(b.image)
        let originalA = try layer(a.image, layerA)
        try a.startRecording()
        field.stringValue = "37"; _ = field.sendAction(field.action, to: field.target)
        try drain(a); try a.stopRecording()
        try session.changeLayer(reference.layer, image: reference.image, .init(opacity: 0.37))
        expect(try equalProperties(layer(a.image, layerA), layer(reference.image, reference.layer)) &&
            session.copyPixels(a.image, merged: true).pixels == session.copyPixels(reference.image, merged: true).pixels &&
            session.undoInfo(a.image) == session.undoInfo(reference.image),
            "real opacity edit matches an independent native property/pixel/history reference")
        expect(try session.copyPixels(a.image, merged: false).pixels == source, "opacity preserves source pixels")
        let baselineCaptured = titles(a) == ["Layer Properties"] && a.recorder.records.count == 1
        expect(baselineCaptured, "the real opacity commit settles exactly one Layer Properties command (old0-record RED)")
        guard baselineCaptured else {
            print("     later property replay/lifetime cases NOT RUN: old capture is missing")
            complete = true; return
        }

        a.changeLayer(layerA, .init(opacity: 1)); try drain(a)
        palette.retarget(to: b)
        ownerB.window?.makeMain(); ownerB.window?.makeKeyAndOrderFront(nil)
        try wait("B genuinely becomes frontmost", { NSApp.isActive && NSApp.keyWindow === ownerB.window && NSApp.mainWindow === ownerB.window })
        expect(NSApp.mainWindow === ownerB.window, "actual B is front while A owns its recording")
        try a.startReplay(); try drain(a)
        expect(try layer(a.image, layerA).opacity == 0.37 && state(b.image) == untouchedB, "A-owned replay changes A only while B is front")
        expect(titles(a) == ["Layer Properties"] && a.recorder.records.count == 1, "replay never recursively records its layer change")
        a.undo(); try drain(a)
        expect(try layer(a.image, layerA).opacity == 1, "ordinary native Undo reverses the replayed opacity")
        a.redo(); try drain(a)
        expect(try layer(a.image, layerA).opacity == 0.37, "ordinary Redo restores the replayed opacity")

        try require(DocumentWindowController.blendModes.contains("multiply"), "installed layer mode list must contain multiply")
        let reset = EngineSession.LayerChange(name: originalA.name, isVisible: true, opacity: 1, mode: originalA.mode)
        a.changeLayer(layerA, reset); try drain(a)
        let first = EngineSession.LayerChange(name: "Captured property name", isVisible: false, opacity: 0.63, mode: "multiply")
        let second = EngineSession.LayerChange(isVisible: true, opacity: 0.42)
        try a.startRecording()
        var callbacks = 0, succeeded = false
        let release = try hold(a)
        var packet = first
        a.changeLayer(layerA, packet) { result in callbacks += 1; if case .success = result { succeeded = true } }
        a.changeLayer(layerA, second)
        packet = .init(name: "Changed caller packet", isVisible: true, opacity: 0.02, mode: "normal")
        try a.stopRecording()
        expect(a.recorder.pendingCount == 2 && !a.recorder.isRecording && callbacks == 0, "Stop fences capture without losing two accepted write routes")
        release.signal(); try drain(a)
        try session.changeLayer(reference.layer, image: reference.image, reset)
        try session.changeLayer(reference.layer, image: reference.image, first)
        try session.changeLayer(reference.layer, image: reference.image, second)
        expect(callbacks == 1 && succeeded && a.pendingWork == 0, "completion-bearing route reconciles and invokes its callback exactly once")
        expect(titles(a) == ["Layer Properties", "Layer Properties"], "both write routes settle in acceptance order once")
        expect(try equalProperties(layer(a.image, layerA), layer(reference.image, reference.layer)) &&
            session.copyPixels(a.image, merged: true).pixels == session.copyPixels(reference.image, merged: true).pixels,
            "immutable combined name/visibility/opacity/mode values match independent native setters")
        a.changeLayer(layerA, reset); try drain(a)
        try session.changeLayer(reference.layer, image: reference.image, reset)
        a.selectLayer(extraA); try drain(a)
        let extraBefore = try layer(a.image, extraA)
        let beforeReplay = try session.undoInfo(a.image)
        let referenceBefore = try session.undoInfo(reference.image)
        try session.changeLayer(reference.layer, image: reference.image, first)
        try session.changeLayer(reference.layer, image: reference.image, second)
        try a.startReplay(); try drain(a)
        expect(try equalProperties(layer(a.image, layerA), layer(reference.image, reference.layer)) && layer(a.image, extraA) == extraBefore &&
            session.selectedLayers(a.image) == [extraA], "replay keeps the explicit original layer while another layer is selected")
        expect(try session.copyPixels(a.image, merged: true).pixels == session.copyPixels(reference.image, merged: true).pixels &&
            session.undoInfo(a.image).undoCount - beforeReplay.undoCount == session.undoInfo(reference.image).undoCount - referenceBefore.undoCount,
            "mixed packet replay matches native pixels and normal setter Undo count")
        expect(try state(b.image) == untouchedB && titles(a).count == 2, "mixed replay leaves B and the recording unchanged")

        a.changeLayer(layerA, reset); try drain(a)
        let beforeCancel = try state(a.image)
        var cancelledAtStart = false
        let cancelStart = a.addRecorderObserver {
            if a.recorder.isReplaying && !cancelledAtStart { cancelledAtStart = true; try? a.cancelReplay() }
        }
        observers.append((a, cancelStart))
        try a.startReplay(); try drain(a); a.removeRecorderObserver(cancelStart)
        expect(try cancelledAtStart && state(a.image) == beforeCancel, "cancel from the start observer schedules no property mutation")
        try session.changeLayer(reference.layer, image: reference.image, reset)
        try session.changeLayer(reference.layer, image: reference.image, first)
        var cancelledAfterFirst = false
        let cancelFirst = a.addRecorderObserver {
            if case .running(index: 1, total: 2) = a.replayStatus, !cancelledAfterFirst {
                cancelledAfterFirst = true; try? a.cancelReplay()
            }
        }
        observers.append((a, cancelFirst))
        try a.startReplay(); try drain(a); a.removeRecorderObserver(cancelFirst)
        expect(cancelledAfterFirst && !a.recorder.isReplaying, "cancel after first acknowledgment stops later scheduling")
        expect(try equalProperties(layer(a.image, layerA), layer(reference.image, reference.layer)) &&
            session.copyPixels(a.image, merged: true).pixels == session.copyPixels(reference.image, merged: true).pixels,
            "post-drain cancellation contains exactly the first native property packet")

        try a.startRecording()
        let epochRelease = try hold(a)
        var oldCallbacks = 0, newCallbacks = 0
        a.changeLayer(layerA, .init(opacity: 0.28)) { _ in oldCallbacks += 1 }
        try a.stopRecording(); try require(a.clearRecording(), "clear must be permitted outside replay")
        try a.startRecording()
        a.changeLayer(extraA, .init(opacity: 0.64)) { _ in newCallbacks += 1 }
        try a.stopRecording(); epochRelease.signal(); try drain(a)
        expect(oldCallbacks == 1 && newCallbacks == 1 && titles(a) == ["Layer Properties"], "new epoch ignores old settlement without losing either callback")
        expect(try layer(a.image, layerA).opacity == 0.28 && layer(a.image, extraA).opacity == 0.64,
            "epoch invalidation leaves both already accepted native writes intact")
        a.changeLayer(layerA, .init(opacity: 0.11)); a.changeLayer(extraA, .init(opacity: 0.12)); try drain(a)
        try a.startReplay(); try drain(a)
        expect(try layer(a.image, layerA).opacity == 0.11 && layer(a.image, extraA).opacity == 0.64,
            "late old ordinal cannot replace the new epoch's explicit layer binding")

        var errors: [String] = []
        let oldError = a.onError; a.onError = { errors.append($0); oldError?($0) }
        let beforeFailure = try state(a.image)
        var failureCallbacks = 0, failed = false
        try a.startRecording()
        a.changeLayer(layerA, .init(mode: "__glims_no_such_layer_mode__")) { result in
            failureCallbacks += 1; if case .failure = result { failed = true }
        }
        try a.stopRecording(); try drain(a)
        expect(failureCallbacks == 1 && failed && !errors.isEmpty, "accepted native failure retains the original error and one completion")
        let failedRecord = a.recorder.records.count == 1 && a.recorder.records.contains {
            if case .failure = $0.resolution { return true }; return false
        }
        expect(failedRecord && a.recorder.replayRefusal == .unsuccessfulRecording, "native failure is visible and cannot become a successful macro")
        expect(try state(a.image) == beforeFailure, "invalid mode preflight preserves complete image state")
        var replayRefused = false
        do { try a.startReplay() } catch { replayRefused = true }
        expect(replayRefused, "failed recording refuses replay")
        try a.startRecording()
        a.changeLayer(layerB, .init(opacity: 0.05)) { _ in failureCallbacks += 1 }
        try a.stopRecording(); try drain(a)
        expect(try state(a.image) == beforeFailure && state(b.image) == untouchedB && a.recorder.replayRefusal == .unsuccessfulRecording,
            "foreign explicit layer produces a failed record without editing either image")
        a.onError = oldError

        let (stale, staleLayer, _) = try document("Stale property binding")
        var staleErrors: [String] = []
        stale.onError = { staleErrors.append($0) }
        try stale.startRecording()
        stale.changeLayer(staleLayer, .init(opacity: 0.4)); stale.changeLayer(staleLayer, .init(name: "must not run"))
        try stale.stopRecording(); try drain(stale)
        _ = try session.layerCommand(.delete, image: stale.image, layer: staleLayer)
        // No cache reload: only the worker's fresh ownership read can reject it.
        try require(stale.layers.contains(where: { $0.id == staleLayer }), "fresh-native refusal fixture must retain its deliberately stale cache")
        let afterDelete = try state(stale.image)
        try stale.startReplay(); try drain(stale)
        var staleFailed = false
        if case .failed(index: 0, reason: let reason) = stale.replayStatus { staleFailed = !reason.isEmpty }
        expect(staleFailed && !staleErrors.isEmpty, "fresh native ownership refuses a deleted target at the first step")
        expect(try state(stale.image) == afterDelete && titles(stale).count == 2, "stale replay mutates nothing and stops remaining property steps")

        let (closing, closingLayer, _) = try document("Closing accepted property")
        var closeRequested = false, closed = false, closeCallbacks = 0, closeSucceeded = false
        try closing.startRecording()
        let closeToken = closing.addRecorderObserver {
            if closing.recorder.pendingCount > 0 && !closeRequested {
                closeRequested = true; closing.closeImageWhenDrained { closed = true }
            }
        }
        observers.append((closing, closeToken))
        closing.changeLayer(closingLayer, .init(opacity: 0.31)) { result in
            closeCallbacks += 1; if case .success = result { closeSucceeded = true }
        }
        try wait("close from Recorder admission observer drains the accepted property", { closed && closing.pendingWork == 0 })
        expect(closeRequested && closeCallbacks == 1 && closeSucceeded, "close after admission keeps the one native result and one completion")
        expect(titles(closing) == ["Layer Properties"] && (try? session.info(closing.image)) == nil,
            "accepted capture settles before native image destruction without a reload after close")
        expect(try state(b.image) == untouchedB, "all property, error and lifecycle scenarios leave B unchanged")
        complete = true
    }
}
