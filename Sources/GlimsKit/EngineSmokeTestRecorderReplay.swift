import AppKit

private struct RecorderReplayNativeState: Equatable {
    let info: EngineSession.ImageInfo
    let pixels: Data
    let selection: CGRect?
    let outline: [EngineSession.Segment]
    let undo: EngineSession.UndoInfo
    let position: Int32
    let history: [EngineSession.HistoryRow]
}

private struct RecorderReplayTargetState: Equatable {
    let layers: [Int32]
    let channels: [Int32]
    let masks: [Int32: EngineSession.MaskState]
    let quick: EngineSession.QuickMaskState
}

private struct RecorderReplayFixture {
    let image: Int32
    let layer: Int32
    let extra: Int32
    let channel: Int32
}

@MainActor
extension EngineSmokeTest {
    /// Capture/replay pipelines over bare documents. Floating-policy checks
    /// intentionally reproduce the reviewed b2 driver's missing live guards.
    static func exerciseRecorderReplay(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            check(condition, "recorder replay: \(message)")
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.005) }
            return condition()
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "RecorderReplayFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func drain(_ document: ImageDocument) throws {
            try require(wait { document.pendingWork == 0 && !document.recorder.isReplaying && !EngineActivity.shared.isBusy },
                        "Recorder fixture timed out draining \(document.name)")
            spin(0.02)
        }
        func snapshot(_ image: Int32) throws -> RecorderReplayNativeState {
            let info = try session.info(image)
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: info.width, height: info.height))
            guard let pixels = rendered.dataProvider?.data as Data? else {
                throw NSError(domain: "RecorderReplayFixture", code: 2)
            }
            let history = try session.history(image)
            return RecorderReplayNativeState(info: info, pixels: pixels, selection: try session.selectionBounds(image: image),
                outline: try session.selectionOutline(image: image), undo: try session.undoInfo(image),
                position: history.currentPosition, history: history.rows)
        }
        func targets(_ image: Int32) throws -> RecorderReplayTargetState {
            let layers = try session.selectedLayers(image)
            var masks: [Int32: EngineSession.MaskState] = [:]
            for id in layers { masks[id] = try session.layerMask(id, image: image) }
            return RecorderReplayTargetState(layers: layers, channels: try session.selectedItems(.channel, image: image),
                                             masks: masks, quick: try session.quickMask(image))
        }
        var bytes: [UInt8] = []
        for y in 0..<29 {
            for x in 0..<41 {
                bytes += [UInt8((x * 17 + y * 7) % 256), UInt8((x * 3 + y * 23) % 256),
                          UInt8((x * x + y * 11 + 31) % 256), 255]
            }
        }
        let pixels = ClipboardImage(width: 41, height: 29, pixels: Data(bytes), origin: .zero)
        var loose: [Int32] = []
        var owned: [ImageDocument] = []
        func image() throws -> Int32 {
            let result = try session.newImage(pixels: pixels)
            loose.append(result)
            return result
        }
        func document(_ name: String, image: Int32? = nil) throws -> ImageDocument {
            let handle = try image ?? session.newImage(pixels: pixels)
            let result = try ImageDocument(session: session, image: handle, name: name)
            loose.removeAll { $0 == handle }
            owned.append(result)
            documents.items.append(result)
            return result
        }
        defer {
            for item in owned { item.onRecorderChange = nil }
            var closing = 0
            for item in owned where !item.isClosing {
                closing += 1
                item.closeImageWhenDrained { closing -= 1 }
            }
            expect(wait { closing == 0 && owned.allSatisfy { $0.pendingWork == 0 } }, "all bare documents and accepted work close cleanly")
            documents.items.removeAll { item in owned.contains { $0 === item } }
            for handle in loose { try? session.closeImage(handle) }
            print("     recorder-replay checks: \(checks)")
        }
        func hold(_ document: ImageDocument) throws -> DispatchSemaphore {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            document.inputQueue.async { entered.signal(); _ = release.wait(timeout: .now() + 20) }
            let ready = entered.wait(timeout: .now() + 3) == .success
            if !ready { release.signal() }
            try require(ready, "Recorder fixture input hold did not start")
            return release
        }
        func record(_ document: ImageDocument, _ actions: () -> Void) throws {
            try document.startRecording()
            actions()
            try document.stopRecording()
            try drain(document)
        }
        func commands(_ document: ImageDocument) -> [SemanticImageCommand] {
            document.recorder.records.compactMap { if case .success(let command) = $0.resolution { return command }; return nil }
        }
        func failedFirst(_ document: ImageDocument) -> Bool {
            if case .failed(index: 0, reason: let reason) = document.replayStatus { return !reason.isEmpty }
            return false
        }
        func attempt(_ document: ImageDocument) throws -> Bool {
            do { try document.startReplay() }
            catch { return true }
            try drain(document)
            return failedFirst(document)
        }
        func contextFixture() throws -> RecorderReplayFixture {
            let handle = try image()
            let layer = try session.layers(handle)[0].id
            guard let extra = try session.layerCommand(.new, image: handle) else { throw NSError(domain: "RecorderReplayFixture", code: 3) }
            try session.selectLayer(layer, image: handle)
            _ = try session.addLayerMask(layer, image: handle, source: .white, edit: false)
            try session.select(.all, image: handle)
            let channel = try session.channelFromSelection(handle, name: "Recorder context")
            try session.selectItems([], kind: .channel, image: handle)
            try session.selectLayer(layer, image: handle)
            try session.select(.none, image: handle)
            return RecorderReplayFixture(image: handle, layer: layer, extra: extra, channel: channel)
        }

        // Independent direct native order oracle, including a second pass on
        // the already-edited image rather than replaying into another document.
        let a = try document("Replay A")
        let b = try document("Replay B")
        let reference = try image()
        let beforeB = try snapshot(b.image)
        let shape = EngineSession.SelectShape.polygon([CGPoint(x: 3, y: 4), CGPoint(x: 26, y: 6),
                                                       CGPoint(x: 20, y: 21), CGPoint(x: 5, y: 17)])
        var shapeOptions = EngineSession.SelectOptions()
        shapeOptions.feather = 1.25
        var colorOptions = EngineSession.SelectOptions()
        colorOptions.operation = .add
        colorOptions.threshold = 0.18
        let fill = NSColor(srgbRed: 0.2, green: 0.35, blue: 0.6, alpha: 0.8)
        let crop = CGRect(x: 2, y: 1, width: 40, height: 45)
        func directPass(_ handle: Int32) throws {
            try session.select(shape, image: handle, options: shapeOptions)
            try session.selectColor(at: CGPoint(x: 13, y: 9), image: handle, options: colorOptions)
            try session.select(.invert, image: handle, radius: 2.75)
            try session.transformImage(handle, .rotate90)
            try session.scaleImage(handle, width: 35, height: 43)
            try session.resizeCanvas(handle, width: 45, height: 49, offset: CGPoint(x: 4, y: 3), fill: fill)
            try session.crop(image: handle, to: crop)
        }
        var aErrors: [String] = []
        a.onError = { aErrors.append($0) }
        try record(a) {
            a.select(shape, options: shapeOptions)
            a.selectColor(at: CGPoint(x: 13, y: 9), options: colorOptions)
            a.select(.invert, radius: 2.75)
            a.transformImage(.rotate90)
            a.scale(toWidth: 35, height: 43)
            a.resizeCanvas(width: 45, height: 49, offset: CGPoint(x: 4, y: 3), fill: fill)
            a.crop(to: crop)
        }
        try directPass(reference)
        let titles = commands(a).map(\.title)
        expect(titles.count == 7 && a.recorder.replayRefusal == nil, "seven real captured commands are eligible for replay")
        try a.startReplay()
        try drain(a)
        try directPass(reference)
        expect(a.replayStatus == .finished(total: 7) && aErrors.isEmpty, "matching layer binding completes all seven queued steps")
        expect(try snapshot(a.image) == snapshot(reference), "two-pass native pixels/selection/history match independent direct calls")
        expect(try snapshot(b.image) == beforeB, "owning A replay leaves separate B unchanged")
        expect(commands(a).map(\.title) == titles && a.recorder.records.count == 7,
               "replay retains the exact original log without recursive capture")
        a.undo()
        try drain(a)
        try session.undo(reference)
        expect(try snapshot(a.image) == snapshot(reference), "Undo removes one normal replay step, without atomic macro grouping")

        // Native failure, not a fabricated failed reservation: merged color
        // selection requires a drawable even though it has no local binding.
        let failure = try document("Replay native failure")
        var failureErrors: [String] = []
        failure.onError = { failureErrors.append($0) }
        var merged = EngineSession.SelectOptions()
        merged.sampleMerged = true
        try record(failure) {
            failure.selectColor(at: CGPoint(x: 9, y: 9), options: merged)
            failure.scale(toWidth: 31, height: 23)
        }
        try session.selectLayers([], image: failure.image)
        try failure.reload()
        let beforeFailure = try snapshot(failure.image)
        try failure.startReplay()
        try drain(failure)
        expect(failedFirst(failure) && failureErrors == ["Select a layer first."], "first actual native failure reports its reason and stops replay")
        expect(try snapshot(failure.image) == beforeFailure, "native failure prevents the following scale and preserves history")
        expect(commands(failure).count == 2 && failure.pendingWork == 0, "failed replay drains without altering successful capture entries")

        for closeInstead in [false, true] {
            let item = try document(closeInstead ? "Replay close observer" : "Replay cancel after first")
            try record(item) { item.transformImage(.flipHorizontal); item.transformImage(.rotate90) }
            let before = try snapshot(item.image)
            let expectedImage = try session.duplicateImage(item.image)
            loose.append(expectedImage)
            try session.transformImage(expectedImage, .flipHorizontal)
            let expectedFirst = try snapshot(expectedImage)
            var errors: [String] = []
            var observed: RecorderReplayNativeState?
            var acted = false
            var closed = 0
            item.onError = { errors.append($0) }
            item.onRecorderChange = {
                if !acted, case .running(index: 1, total: 2) = item.replayStatus {
                    acted = true
                    observed = try? snapshot(item.image)
                    if closeInstead { item.closeImageWhenDrained { closed += 1 } }
                    else { try? item.cancelReplay() }
                }
            }
            try item.startReplay()
            if closeInstead { try require(wait { closed == 1 }, "close observer did not complete") }
            else { try drain(item) }
            spin(0.03)
            let afterSettlement: RecorderReplayNativeState?
            if closeInstead { afterSettlement = observed }
            else { afterSettlement = try snapshot(item.image) }
            expect(acted && item.replayStatus == .cancelled(index: 1) && errors.isEmpty && item.pendingWork == 0,
                   "\(closeInstead ? "Close" : "Cancel") from first-settlement observer fences every later step")
            expect(observed?.pixels == expectedFirst.pixels && observed?.info.width == before.info.width
                    && observed?.info.height == before.info.height && observed?.undo.undoCount == before.undo.undoCount + 1
                    && afterSettlement?.pixels == expectedFirst.pixels
                    && afterSettlement?.info.width == before.info.width && afterSettlement?.info.height == before.info.height
                    && afterSettlement?.undo.undoCount == before.undo.undoCount + 1
                    && (!closeInstead || closed == 1), "observer and drained state contain exactly one native edit before cancellation/close")
            item.onRecorderChange = nil
        }
        let cancelled = try document("Replay cancel at start")
        try record(cancelled) { cancelled.transformImage(.flipHorizontal); cancelled.scale(toWidth: 31, height: 23) }
        let beforeCancel = try snapshot(cancelled.image)
        var cancelledAtStart = false
        cancelled.onRecorderChange = {
            if !cancelledAtStart, case .running(index: 0, total: 2) = cancelled.replayStatus {
                cancelledAtStart = true
                try? cancelled.cancelReplay()
            }
        }
        try cancelled.startReplay()
        try drain(cancelled)
        expect(cancelledAtStart && cancelled.replayStatus == .cancelled(index: 0), "start observer cancels before the first queue admission")
        expect(try snapshot(cancelled.image) == beforeCancel, "start cancellation produces no pixels, selection or Undo change")
        cancelled.onRecorderChange = nil

        // Cancellation cannot undo an already accepted job, but its late
        // acknowledgment must neither advance nor schedule the second command.
        do {
            let item = try document("Replay Cancel with native work held")
            try record(item) { item.transformImage(.flipHorizontal); item.transformImage(.rotate90) }
            let before = try snapshot(item.image)
            let expectedImage = try session.duplicateImage(item.image)
            loose.append(expectedImage)
            try session.transformImage(expectedImage, .flipHorizontal)
            let expectedFirst = try snapshot(expectedImage)
            let release = try hold(item)
            defer { release.signal() }
            var errors: [String] = []
            item.onError = { errors.append($0) }
            try item.startReplay()
            try item.cancelReplay()
            expect(item.replayStatus == .cancelled(index: 0) && item.pendingWork == 1 && commands(item).count == 2,
                   "in-flight Cancel fences scheduling while the accepted native job remains counted")
            release.signal()
            try drain(item)
            let final = try snapshot(item.image)
            expect(final.pixels == expectedFirst.pixels && final.info.width == before.info.width
                    && final.info.height == before.info.height && final.undo.undoCount == before.undo.undoCount + 1
                    && item.replayStatus == .cancelled(index: 0) && item.pendingWork == 0 && errors.isEmpty
                    && commands(item).count == 2,
                   "accepted native job finishes after Cancel, with no second edit or late replay restart")
        }

        // Hold an already-admitted replay step, then exercise real read and
        // manual-write entrypoints before releasing its native queue.
        do {
            let item = try document("Replay reads and live gates")
            try record(item) { item.transformImage(.flipHorizontal); item.transformImage(.rotate90) }
            let before = try snapshot(item.image)
            let expectedImage = try session.duplicateImage(item.image)
            loose.append(expectedImage)
            try session.transformImage(expectedImage, .flipHorizontal)
            let expectedFirst = try snapshot(expectedImage)
            try session.transformImage(expectedImage, .rotate90)
            let expectedFinal = try snapshot(expectedImage)
            let release = try hold(item)
            defer { release.signal() }
            var busy = 0
            var cutConsumed = 0
            var readDone = false
            var copied: Int32?
            var copyError: Error?
            var gateErrors: [String] = []
            item.onError = { gateErrors.append($0) }
            try item.startReplay()
            item.scale(toWidth: 9, height: 9)
            item.convertMode(to: .grayscale) { if case .failure = $0 { busy += 1 } }
            item.placeLink(from: work.appendingPathComponent("must-not-open-recorder.file")) { if case .failure = $0 { busy += 1 } }
            item.copyPixels(.cutLayer, background: .white, consume: { _ in cutConsumed += 1 }) { if $0 != nil { busy += 1 } }
            item.createGradient(name: "Must not create during replay", left: .init(red: 0, green: 0, blue: 0, alpha: 1),
                                right: .init(red: 1, green: 1, blue: 1, alpha: 1)) { if case .failure = $0 { busy += 1 } }
            item.beginFilterPreview(operation: "gegl:gaussian-blur", properties: []) { if case .failure = $0 { busy += 1 } }
            expect(busy == 5 && cutConsumed == 0 && item.pendingWork == 1 && !item.acceptsEdits && gateErrors.count == 1,
                   "common scale plus mode/import/Cut/resource/preview writes refuse without native admission")
            let readAccepted = item.run(effect: .readsPixels) { engine, handle in
                _ = try engine.info(handle)
                DispatchQueue.main.async { readDone = true }
            }
            item.snapshot { result in
                switch result {
                case .success(let handle): copied = handle; loose.append(handle)
                case .failure(let error): copyError = error
                }
            }
            release.signal()
            try drain(item)
            expect(readAccepted && readDone && copied != nil && copyError == nil && item.replayStatus == .finished(total: 2),
                   "allowed counted read and snapshot drain before replay resumes")
            let copy = try copied.map { try snapshot($0) }
            let final = try snapshot(item.image)
            expect(copy?.pixels == expectedFirst.pixels && copy?.info.width == before.info.width
                    && copy?.info.height == before.info.height && final.pixels == expectedFinal.pixels
                    && final.info.width == expectedFinal.info.width && final.info.height == expectedFinal.info.height
                    && final.undo.undoCount == before.undo.undoCount + 2 && commands(item).count == 2,
                   "snapshot captures only the first replay step; later step resumes once with normal Undo")
        }

        // Matching mask/channel/Quick Mask roles, then independent cache versus
        // fresh-native changes. No contexts are patched or invented by tests.
        for role in ["layer", "mask", "channel", "quick"] {
            let fixture = try contextFixture()
            if role == "mask" { try session.setLayerMask(fixture.layer, image: fixture.image, flags: [.editing], values: [.editing]) }
            if role == "channel" { try session.selectItems([fixture.channel], kind: .channel, image: fixture.image) }
            if role == "quick" { try session.setQuickMask(fixture.image, enabled: true) }
            let item = try document("Matching \(role)", image: fixture.image)
            var errors: [String] = []
            item.onError = { errors.append($0) }
            try record(item) { item.selectColor(at: CGPoint(x: 9, y: 9), options: EngineSession.SelectOptions()) }
            let captured = commands(item).count == 1 && item.recorder.replayRefusal == nil
            expect(captured, "matching \(role) fixture captures a real local-color success")
            if captured {
                let beforeTargets = try targets(item.image)
                try item.startReplay()
                try drain(item)
                expect(try item.replayStatus == .finished(total: 1) && errors.isEmpty && targets(item.image) == beforeTargets,
                       "matching \(role) runtime context succeeds without retargeting")
            }
        }
        var freshProofs = 0
        for role in ["layer", "channel", "mask", "quick"] {
            for cached in [true, false] {
                let fixture = try contextFixture()
                let item = try document("Changed \(role) \(cached ? "cache" : "native")", image: fixture.image)
                var errors: [String] = []
                item.onError = { errors.append($0) }
                try record(item) { item.select(.fromAlpha) }
                try require(commands(item).count == 1 && item.recorder.replayRefusal == nil, "context fixture failed to capture Alpha")
                switch role {
                case "layer":
                    if cached { item.selectLayer(fixture.extra) }
                    else { try session.selectLayer(fixture.extra, image: item.image) }
                case "channel":
                    if cached { item.selectChannel(fixture.channel) }
                    else { try session.selectItems([fixture.channel], kind: .channel, image: item.image) }
                case "mask":
                    if cached { item.editMask(fixture.layer) }
                    else { try session.setLayerMask(fixture.layer, image: item.image, flags: [.editing], values: [.editing]) }
                default:
                    if cached { item.setQuickMask(true) }
                    else { try session.setQuickMask(item.image, enabled: true) }
                }
                if cached { try drain(item) }
                else if item.selectedLayerIDs == [fixture.layer] && item.selectedChannelIDs.isEmpty
                    && item.maskStates[fixture.layer]?.editing == false && item.quickMaskState?.enabled == false {
                    freshProofs += 1
                }
                let before = try snapshot(item.image)
                let beforeTargets = try targets(item.image)
                let refused = try attempt(item)
                expect(refused && !errors.isEmpty, "changed \(role) \(cached ? "cached" : "fresh-native") context refuses replay")
                expect(try snapshot(item.image) == before && targets(item.image) == beforeTargets,
                       "changed \(role) context refusal preserves all native state and the user's target")
            }
        }
        expect(freshProofs == 4, "all four fresh-native variants retain old cached facts until replay admission")
        let unavailableFixture = try contextFixture()
        let unavailable = try document("Unavailable original binding", image: unavailableFixture.image)
        var unavailableErrors: [String] = []
        unavailable.onError = { unavailableErrors.append($0) }
        try record(unavailable) { unavailable.selectLayer(unavailableFixture.extra); unavailable.select(.fromAlpha) }
        let beforeUnavailable = try snapshot(unavailable.image)
        expect(commands(unavailable).count == 1 && unavailable.recorder.replayRefusal == nil,
               "queued target change still permits the original Alpha edit to capture successfully")
        let unavailableRefused = try attempt(unavailable)
        expect(try unavailableRefused && !unavailableErrors.isEmpty && snapshot(unavailable.image) == beforeUnavailable,
               "unavailable original runtime binding fails actionably without replay mutation")

        // Reviewed policy RED: live image-wide guards refuse a floating
        // selection, so the corresponding recorded command must do so too.
        for operation in ["transform", "scale", "crop", "resize"] {
            let item = try document("Floating policy \(operation)")
            func edit() {
                switch operation {
                case "transform": item.transformImage(.flipHorizontal)
                case "scale": item.scale(toWidth: 31, height: 23)
                case "crop": item.crop(to: CGRect(x: 1, y: 1, width: 25, height: 19))
                default: item.resizeCanvas(width: 45, height: 35, offset: CGPoint(x: 2, y: 3), fill: .white)
                }
            }
            var errors: [String] = []
            item.onError = { errors.append($0) }
            try record(item) { edit() }
            expect(commands(item).count == 1 && item.recorder.replayRefusal == nil, "floating \(operation) fixture captures one valid image-wide command")
            let layer = try session.selectedLayers(item.image)[0]
            try session.select(.rectangle(CGRect(x: 3, y: 3, width: 8, height: 7)), image: item.image)
            _ = try session.floatSelection(item.image, target: layer, mode: .copy)
            try item.reload()
            let before = try snapshot(item.image)
            let beforeFloating = try session.floatingSelection(item.image)
            errors.removeAll()
            edit()
            try drain(item)
            expect(try errors.count == 1 && snapshot(item.image) == before,
                   "existing live \(operation) refuses floating selection without mutation")
            errors.removeAll()
            let refused = try attempt(item)
            expect(try refused && snapshot(item.image) == before && session.floatingSelection(item.image) == beforeFloating,
                   "recorded \(operation) also refuses floating selection before any mutation (policy RED)")
        }
        do {
            let item = try document("Fresh-native floating policy")
            var errors: [String] = []
            item.onError = { errors.append($0) }
            try record(item) { item.scale(toWidth: 31, height: 23) }
            let layer = try session.selectedLayers(item.image)[0]
            try session.select(.rectangle(CGRect(x: 3, y: 3, width: 8, height: 7)), image: item.image)
            _ = try session.floatSelection(item.image, target: layer, mode: .copy)
            let before = try snapshot(item.image)
            let beforeFloating = try session.floatingSelection(item.image)
            // No reload or main-runloop spin: cached false must pass the main
            // gate so the queued fresh native query supplies this refusal.
            let cacheWasInactive = !item.floatingState.isActive
            let refused = try attempt(item)
            expect(try cacheWasInactive && beforeFloating.isActive && refused && failedFirst(item)
                    && errors == [FloatingControlsLogic.resolveFirstReason]
                    && snapshot(item.image) == before && session.floatingSelection(item.image) == beforeFloating,
                   "fresh-native floating selection refuses before mutation despite an inactive cached state")
        }
    }
}
