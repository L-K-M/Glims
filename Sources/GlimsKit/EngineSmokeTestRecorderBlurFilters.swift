import AppKit

@MainActor
extension EngineSmokeTest {
    /// Records Gaussian Blur through its real panel and Unsharp Mask through
    /// the document's filter session, then saves, rebinds and replays both and
    /// proves the mask, channel and lock refusals.
    static func exerciseRecorderBlurFilters(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var owned: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        var loose: [Int32] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "RecorderBlurFiltersFixture", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.005) }
            try require(condition(), "blur filter recorder work timed out")
        }
        func drain(_ doc: ImageDocument) throws {
            try wait { doc.pendingWork == 0 && doc.recorder.pendingCount == 0 &&
                !doc.recorder.isReplaying && !EngineActivity.shared.isBusy }
        }
        func pixels(_ image: Int32) throws -> Data { try session.copyPixels(image, merged: true).pixels }
        var bytes: [UInt8] = []
        for i in 0..<120 { bytes += [UInt8(i * 13 % 256), UInt8(i * 31 % 256), UInt8(i * 7 % 256), 255] }
        let input = ClipboardImage(width: 12, height: 10, pixels: Data(bytes), origin: .zero)
        func fixture(_ name: String) throws -> (ImageDocument, Int32, Int32) {
            let image = try session.newImage(width: 16, height: 14)
            let layer = try session.pastePixels(image, pixels: input, at: CGPoint(x: 2, y: 2))
            let extra = try session.layers(image).first { $0.id != layer }!.id
            let doc = try ImageDocument(session: session, image: image, name: name)
            doc.onError = { _ in }
            owned.append(doc); documents.items.append(doc)
            return (doc, layer, extra)
        }
        func begin(_ doc: ImageDocument, _ operation: String) throws -> Int32 {
            var result: Result<ImageDocument.FilterPreviewStart, Error>?
            doc.beginFilterPreview(operation: operation, properties: []) { result = $0 }
            try drain(doc); try require(result != nil, "\(operation) begin callback missing")
            return try result!.get().filter
        }
        func set(_ doc: ImageDocument, _ filter: Int32, _ values: [(String, EngineSession.FilterValue)]) throws {
            for (property, value) in values {
                var result: Result<Void, Error>?
                doc.setFilterProperty(filter, property, value) { result = $0 }
                try drain(doc); try require(result != nil, "\(property) write callback missing")
                try result!.get()
            }
        }
        func finish(_ doc: ImageDocument, _ filter: Int32, commit: Bool) throws -> Bool {
            var result: Bool?
            doc.finishFilter(filter, commit: commit) { result = $0 }
            try drain(doc); try require(result != nil, "filter finish callback missing")
            return result!
        }
        defer {
            for controller in controllers { controller.previewPanel?.cancel() }
            for doc in owned { try? drain(doc) }
            for controller in controllers {
                controller.window?.orderOut(nil)
                var stopped = false; controller.canvas.stopRendering { stopped = true }
                while !stopped { spin(0.01) }
            }
            for doc in owned { doc.closeImageWhenDrained() }
            try? wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            check(owned.allSatisfy { (try? session.info($0.image)) == nil },
                  "blur filter recorder closes every owned image")
            documents.items.removeAll { doc in owned.contains { $0 === doc } }
            for image in loose { try? session.closeImage(image) }
        }

        let blur = EngineSession.GaussianBlurSettings(deviationX: 2.5, deviationY: 2.5, kernel: .auto,
                                                      abyss: .clamp, clipsToInput: true)
        let sharpen = EngineSession.UnsharpMaskSettings(radius: 1.5, amount: 2, threshold: 0.0625)
        let sharpenValues: [(String, EngineSession.FilterValue)] = [
            ("std-dev", .number(sharpen.radius)), ("scale", .number(sharpen.amount)),
            ("threshold", .number(sharpen.threshold))]

        let (a, layerA, extraA) = try fixture("Blur filters capture")
        let (b, layerB, extraB) = try fixture("Blur filters rebound")
        let controllerA = DocumentWindowController(document: a)
        controllers.append(controllerA); controllerA.showWindow(nil)
        let original = try pixels(a.image), baseline = a.undoInfo.undoCount
        try a.startRecording()

        // Real panel Cancel records nothing.
        controllerA.gaussianBlur(nil)
        try wait { controllerA.previewPanel != nil && a.pendingWork == 0 }
        guard var panel = controllerA.previewPanel as? GaussianBlurPanel else {
            return check(false, "Gaussian Blur opens its dedicated panel")
        }
        panel.apply(radius: 6); try drain(a)
        panel.cancel()
        try wait { controllerA.previewPanel == nil && a.pendingWork == 0 }
        check(try a.recorder.records.isEmpty && (try pixels(a.image)) == original && a.undoInfo.undoCount == baseline,
              "Gaussian Blur Cancel records nothing and restores pixels and history")

        // Real panel Apply. A selection change behind the open panel must not
        // retarget the capture.
        controllerA.gaussianBlur(nil)
        try wait { controllerA.previewPanel != nil && a.pendingWork == 0 }
        guard let opened = controllerA.previewPanel as? GaussianBlurPanel else {
            return check(false, "Gaussian Blur reopens its dedicated panel")
        }
        panel = opened
        try session.selectLayers([extraA], image: a.image)
        try a.reload()
        panel.apply(radius: blur.deviationX); try drain(a)
        panel.commit()
        try wait { controllerA.previewPanel == nil && a.pendingWork == 0 }

        try session.selectLayers([layerA], image: a.image)
        try a.reload()
        let sharpenFilter = try begin(a, EngineSession.unsharpMaskOperation)
        try set(a, sharpenFilter, sharpenValues)
        check(try finish(a, sharpenFilter, commit: true), "Unsharp Mask applies while recording")
        try a.stopRecording(); try drain(a)

        guard a.recorder.records.count == 2,
              case .success(.applyGaussianBlur(let capturedBlur))? = a.recorder.records.first?.resolution,
              case .success(.applyUnsharpMask(let capturedSharpen))? = a.recorder.records.last?.resolution,
              case .layer(let blurSymbol)? = a.recorderBindingDescriptions[0],
              case .layer(let sharpenSymbol)? = a.recorderBindingDescriptions[1] else {
            return check(false, "Gaussian Blur and Unsharp Mask record their explicit layers and settings")
        }
        check(capturedBlur == blur && capturedSharpen == sharpen && blurSymbol == sharpenSymbol,
              "recording captures the whole accepted Gaussian Blur and Unsharp Mask settings on one layer")

        let reference = try session.newImage(width: 16, height: 14); loose.append(reference)
        let referenceLayer = try session.pastePixels(reference, pixels: input, at: CGPoint(x: 2, y: 2))
        var oracle = try session.beginFilter(image: reference, drawable: referenceLayer, operation: EngineSession.gaussianBlurOperation)
        try session.setGaussianBlurSettings(oracle, to: blur); try session.commitFilter(oracle)
        oracle = try session.beginFilter(image: reference, drawable: referenceLayer, operation: EngineSession.unsharpMaskOperation)
        try session.setUnsharpMaskSettings(oracle, to: sharpen); try session.commitFilter(oracle)
        let changed = try pixels(a.image)
        check(try changed != original && changed == (try pixels(reference)) &&
              a.undoInfo.undoCount == baseline + 2 && session.effects(on: layerA, image: a.image).count == 2 &&
              session.effects(on: extraA, image: a.image).isEmpty,
              "recorded filters match the independent native result with one effect and Undo step each")

        let url = work.appendingPathComponent("blur-filters.glims-recording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        a.saveRecording(to: url, checkpoint: try a.recorderSaveCheckpoint()) { saved = $0 }
        try drain(a); try require(saved != nil, "blur filter save callback missing"); _ = try saved!.get()
        let encoded = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        check(encoded?["version"] as? Int == 26, "saved blur filter recording declares version 26")
        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        a.prepareRecordingFile(at: url, checkpoint: try a.recorderInstallCheckpoint()) { loaded = $0 }
        try drain(a); try require(loaded != nil, "blur filter load callback missing")
        let prepared = try loaded!.get()
        var installed: Result<Void, Error>?
        b.installRecording(prepared, checkpoint: try b.recorderInstallCheckpoint(), choices: [blurSymbol: .layer(layerB)]) { installed = $0 }
        try drain(b); try require(installed != nil, "blur filter install callback missing"); try installed!.get()
        b.selectLayer(extraB); try drain(b)
        let bUndo = b.undoInfo.undoCount
        try b.startReplay(); try drain(b)
        check(try (try pixels(b.image)) == changed && b.undoInfo.undoCount == bUndo + 2 &&
              session.effects(on: layerB, image: b.image).count == 2 &&
              session.effects(on: extraB, image: b.image).isEmpty && session.selectedLayers(b.image) == [extraB],
              "saved filters replay on the chosen layer while preserving the unrelated selected layer")
        b.undo(); try drain(b); b.undo(); try drain(b)
        check(try pixels(b.image) == original, "replayed filters undo to the exact destination pixels")

        let beforeLock = try pixels(b.image)
        try session.setLayerLocks(layerB, image: b.image, mask: [.pixels], values: [.pixels])
        let lockedUndo = try session.undoInfo(b.image)
        try b.startReplay(); try drain(b)
        var refused = false
        if case .failed(index: 0, reason: let reason) = b.replayStatus { refused = reason.contains("Unlock") }
        check(try refused && (try pixels(b.image)) == beforeLock && session.undoInfo(b.image) == lockedUndo &&
              session.effects(on: layerB, image: b.image).isEmpty,
              "a locked layer refuses Gaussian Blur replay without an effect or Undo step")
        try session.setLayerLocks(layerB, image: b.image, mask: [.pixels], values: [])

        let (maskDoc, maskLayer, _) = try fixture("Blur filters on mask")
        _ = try session.addLayerMask(maskLayer, image: maskDoc.image, source: .white, edit: true)
        try maskDoc.reload()
        try maskDoc.startRecording()
        var filter = try begin(maskDoc, EngineSession.gaussianBlurOperation)
        try set(maskDoc, filter, [("std-dev-x", .number(3)), ("std-dev-y", .number(3))])
        check(try finish(maskDoc, filter, commit: true), "live Gaussian Blur on a mask remains usable")
        try maskDoc.stopRecording(); try drain(maskDoc)
        if case .failure(let reason)? = maskDoc.recorder.records.first?.resolution {
            check(reason.contains("layer mask") && maskDoc.recorder.records.count == 1,
                  "a mask Gaussian Blur records an explicit unsupported row")
        } else { check(false, "a mask Gaussian Blur must not become a layer-bound action") }

        let (channelDoc, _, _) = try fixture("Blur filters on channel")
        try session.select(.all, image: channelDoc.image)
        let channel = try session.channelFromSelection(channelDoc.image, name: "Blur channel target")
        try session.select(.none, image: channelDoc.image)
        try session.selectItems([channel], kind: .channel, image: channelDoc.image)
        try channelDoc.reload()
        try channelDoc.startRecording()
        filter = try begin(channelDoc, EngineSession.unsharpMaskOperation)
        try set(channelDoc, filter, sharpenValues)
        check(try finish(channelDoc, filter, commit: true), "live Unsharp Mask on a saved channel remains usable")
        try channelDoc.stopRecording(); try drain(channelDoc)
        if case .failure(let reason)? = channelDoc.recorder.records.first?.resolution {
            check(reason.contains("channel") && channelDoc.recorder.records.count == 1,
                  "a channel Unsharp Mask records an explicit unsupported row")
        } else { check(false, "a channel Unsharp Mask must not become a layer-bound action") }

        // A filter Recorder cannot replay, and an edit of an existing effect,
        // still apply live but add an explicit unsupported row, so replay
        // refuses the incomplete sequence instead of silently skipping it.
        NativeFilterCatalog.shared.install(try session.filterOperations())
        let (otherDoc, otherLayer, _) = try fixture("Unrecorded filter")
        let otherOriginal = try pixels(otherDoc.image)
        try otherDoc.startRecording()
        filter = try begin(otherDoc, "gegl:pixelize")
        try set(otherDoc, filter, [("size-x", .integer(4)), ("size-y", .integer(4))])
        check(try finish(otherDoc, filter, commit: true), "an unrecorded filter still applies while recording")
        let pixelized = try pixels(otherDoc.image)
        var result: Result<ImageDocument.FilterPreviewStart, Error>?
        let effect = try session.effects(on: otherLayer, image: otherDoc.image)[0]
        otherDoc.beginEffectPreview(effect: effect.id, on: otherLayer, properties: []) { result = $0 }
        try drain(otherDoc); try require(result != nil, "existing effect begin callback missing")
        filter = try result!.get().filter
        try set(otherDoc, filter, [("size-x", .integer(2))])
        check(try finish(otherDoc, filter, commit: true), "an existing filter effect edit still applies while recording")
        let edited = try pixels(otherDoc.image)
        try otherDoc.stopRecording(); try drain(otherDoc)
        let rows = otherDoc.recorder.records.map(\.resolution)
        if rows.count == 2, case .failure(let first) = rows[0], case .failure(let second) = rows[1] {
            check(first.contains("Pixelize") && second.contains("existing effect"),
                  "unrecorded filters and effect edits record explicit unsupported rows")
        } else { check(false, "unrecorded filters and effect edits record explicit unsupported rows") }
        check(otherOriginal != pixelized && pixelized != edited,
              "the unrecorded filter and effect edit both changed the live image")
        let otherUndo = try session.undoInfo(otherDoc.image)
        var incomplete = false
        do { try otherDoc.startReplay() } catch { incomplete = true }
        try drain(otherDoc)
        check(try incomplete && (try pixels(otherDoc.image)) == edited && session.undoInfo(otherDoc.image) == otherUndo,
              "replay refuses a recording with unsupported rows without changing pixels or history")
    }
}
