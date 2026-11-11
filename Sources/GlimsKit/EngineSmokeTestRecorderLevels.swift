import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderLevels(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var owned: [ImageDocument] = []
        var loose: [Int32] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "RecorderLevelsFixture", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.005) }
            try require(condition(), "Levels recorder work timed out")
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
        func begin(_ doc: ImageDocument, existing: Int32? = nil, layer: Int32? = nil) throws -> Int32 {
            var result: Result<ImageDocument.FilterPreviewStart, Error>?
            if let existing, let layer {
                doc.beginEffectPreview(effect: existing, on: layer, properties: [], operation: "gimp:levels") { result = $0 }
            } else {
                doc.beginFilterPreview(operation: "gimp:levels", properties: []) { result = $0 }
            }
            try drain(doc); try require(result != nil, "Levels begin callback missing")
            return try result!.get().filter
        }
        func finish(_ doc: ImageDocument, _ filter: Int32, commit: Bool) throws -> Bool {
            var result: Bool?
            doc.finishFilter(filter, commit: commit) { result = $0 }
            try drain(doc); try require(result != nil, "Levels finish callback missing")
            return result!
        }
        defer {
            for doc in owned { doc.closeImageWhenDrained() }
            try? wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            check(owned.allSatisfy { (try? session.info($0.image)) == nil }, "Levels recorder closes every owned image")
            documents.items.removeAll { doc in owned.contains { $0 === doc } }
            for image in loose { try? session.closeImage(image) }
        }
        let (a, layerA, extraA) = try fixture("Levels capture")
        let (b, layerB, extraB) = try fixture("Levels rebound")
        let reference = try session.newImage(width: 16, height: 14); loose.append(reference)
        let referenceLayer = try session.pastePixels(reference, pixels: input, at: CGPoint(x: 2, y: 2))
        var accepted = EngineSession.LevelsSettings()
        accepted.trc = .nonlinear; accepted.clampInput = true; accepted.clampOutput = true
        accepted.value = .init(lowInput: 0.03, highInput: 0.95, gamma: 1.4, lowOutput: 0.04, highOutput: 0.94)
        accepted.red = .init(lowInput: 0.06, highInput: 0.92, gamma: 1.2, lowOutput: 0.07, highOutput: 0.93)
        accepted.green = .init(lowInput: 0.09, highInput: 0.89, gamma: 1.6, lowOutput: 0.10, highOutput: 0.92)
        accepted.blue = .init(lowInput: 0.12, highInput: 0.86, gamma: 1.8, lowOutput: 0.13, highOutput: 0.91)
        accepted.alpha = .init(lowInput: 0.15, highInput: 0.83, gamma: 2.0, lowOutput: 0.16, highOutput: 0.90)
        let original = try pixels(a.image), baseline = a.undoInfo.undoCount
        try a.startRecording()
        var filter = try begin(a)
        var writes = 0
        a.setLevels(filter, accepted) { if case .success = $0 { writes += 1 } }
        try drain(a)
        check(try a.recorder.records.isEmpty && (try pixels(a.image)) != original,
              "Levels preview changes the image without recording a command")
        check(try finish(a, filter, commit: false), "Levels Cancel succeeds")
        check(try a.recorder.records.isEmpty && (try pixels(a.image)) == original && a.undoInfo.undoCount == baseline,
              "Levels Cancel records nothing and restores exact pixels and history")

        filter = try begin(a)
        // A modeless preview keeps its begin-time layer even if selection
        // moves before the final settings and Apply are admitted.
        a.selectLayer(extraA); try drain(a)
        try require(try session.selectedLayers(a.image) == [extraA], "Levels retarget fixture did not change selection")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        a.inputQueue.async { entered.signal(); release.wait() }
        try require(entered.wait(timeout: .now() + 5) == .success, "Levels queue hold failed")
        var early = accepted; early.value.gamma = 0.75
        a.setLevels(filter, early) { if case .success = $0 { writes += 1 } }
        a.setLevels(filter, accepted) { if case .success = $0 { writes += 1 } }
        var applied: Bool?
        a.finishFilter(filter, commit: true) { applied = $0 }
        try a.stopRecording()
        check(a.recorder.pendingCount == 1, "Apply reserves one row before Stop while native writes are pending")
        release.signal(); try drain(a)
        check(applied == true && writes == 3, "queued Levels writes and Apply all succeed")
        guard case .success(.applyLevels(let captured))? = a.recorder.records.first?.resolution,
              case .layer(let symbol)? = a.recorderBindingDescriptions[0] else {
            return check(false, "Levels Apply records its explicit layer and semantic settings")
        }
        check(captured == accepted && a.recorder.records.count == 1,
              "recording captures the final authoritative settings for all five distinct channels")
        check(a.recorderDescriptions.values[symbol] == .available(.init(name: a.layers.first { $0.id == layerA }!.name,
              kind: .pixel, ancestors: [], siblingIndex: a.layers.firstIndex { $0.id == layerA }!,
              bounds: .init(x: 2, y: 2, width: 12, height: 10))),
              "Levels capture describes the original layer after selection changes")
        let oracle = try session.beginFilter(image: reference, drawable: referenceLayer, operation: "gimp:levels")
        try session.setLevelsSettings(oracle, to: accepted); try session.commitFilter(oracle)
        let changed = try pixels(a.image)
        check(try changed != original && changed == (try pixels(reference)) &&
              a.undoInfo.undoCount == baseline + 1 && session.effects(on: layerA, image: a.image).count == 1 &&
              session.effects(on: extraA, image: a.image).isEmpty && session.selectedLayers(a.image) == [extraA],
              "recorded Apply matches the independent native result and adds one effect and Undo step")
        a.undo(); try drain(a)
        check(try (try pixels(a.image)) == original && session.effects(on: layerA, image: a.image).isEmpty,
              "Levels Undo removes the effect and restores every pixel")
        a.redo(); try drain(a)
        check(try (try pixels(a.image)) == changed, "Levels Redo restores exact output")

        let url = work.appendingPathComponent("levels.glims-recording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        a.saveRecording(to: url, checkpoint: try a.recorderSaveCheckpoint()) { saved = $0 }
        try drain(a); try require(saved != nil, "Levels save callback missing"); _ = try saved!.get()
        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        a.prepareRecordingFile(at: url, checkpoint: try a.recorderInstallCheckpoint()) { loaded = $0 }
        try drain(a); try require(loaded != nil, "Levels load callback missing")
        let prepared = try loaded!.get()
        let encoded = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        check(encoded?["version"] as? Int == 5, "saved Levels recording declares version five")
        var installed: Result<Void, Error>?
        b.installRecording(prepared, checkpoint: try b.recorderInstallCheckpoint(), choices: [symbol: .layer(layerB)]) {
            installed = $0
        }
        try drain(b); try require(installed != nil, "Levels install callback missing"); try installed!.get()
        b.selectLayer(extraB); try drain(b)
        let bUndo = b.undoInfo.undoCount
        try b.startReplay(); try drain(b)
        check(try (try pixels(b.image)) == changed && b.undoInfo.undoCount == bUndo + 1 &&
              session.effects(on: layerB, image: b.image).count == 1 &&
              session.effects(on: extraB, image: b.image).isEmpty && session.selectedLayers(b.image) == [extraB],
              "saved Levels rebinds to its chosen layer while preserving the unrelated selected layer")
        b.undo(); try drain(b)
        check(try (try pixels(b.image)) == original, "rebound Levels Undo restores exact destination pixels")

        let (gray, grayLayer, _) = try fixture("Grayscale Levels replay")
        var grayConverted: Result<Void, Error>?
        gray.convertMode(to: .grayscale) { grayConverted = $0 }
        try drain(gray); try require(grayConverted != nil, "Grayscale conversion callback missing"); try grayConverted!.get()
        let grayBefore = try pixels(gray.image), grayUndo = try session.undoInfo(gray.image)
        let grayReference = try session.newImage(width: 16, height: 14); loose.append(grayReference)
        let grayReferenceLayer = try session.pastePixels(grayReference, pixels: input, at: CGPoint(x: 2, y: 2))
        try session.convertMode(grayReference, to: .grayscale)
        let grayOracle = try session.beginFilter(image: grayReference, drawable: grayReferenceLayer, operation: "gimp:levels")
        try session.setLevelsSettings(grayOracle, to: accepted); try session.commitFilter(grayOracle)
        var grayInstalled: Result<Void, Error>?
        gray.installRecording(prepared, checkpoint: try gray.recorderInstallCheckpoint(), choices: [symbol: .layer(grayLayer)]) {
            grayInstalled = $0
        }
        try drain(gray); try require(grayInstalled != nil, "Grayscale Levels install callback missing"); try grayInstalled!.get()
        try gray.startReplay(); try drain(gray)
        check(try (try pixels(gray.image)) != grayBefore && (try pixels(gray.image)) == (try pixels(grayReference)) &&
              session.undoInfo(gray.image).undoCount == grayUndo.undoCount + 1 &&
              session.effects(on: grayLayer, image: gray.image).count == 1,
              "grayscale Levels replay matches direct native settings and adds exactly one Undo step")
        gray.undo(); try drain(gray)
        check(try (try pixels(gray.image)) == grayBefore && session.effects(on: grayLayer, image: gray.image).isEmpty,
              "grayscale Levels Undo restores exact pixels and removes its effect")
        // Deliberately leave the document's cached grayscale mode unchanged.
        try session.convertToIndexed(gray.image, settings: .init(maxColors: 16))
        let indexedBefore = try pixels(gray.image), indexedUndo = try session.undoInfo(gray.image)
        try gray.startReplay(); try drain(gray)
        var indexedRefused = false
        if case .failed(index: 0, reason: let reason) = gray.replayStatus {
            indexedRefused = reason.contains("Convert the image to RGB or grayscale")
        }
        check(try indexedRefused && (try pixels(gray.image)) == indexedBefore &&
              session.undoInfo(gray.image) == indexedUndo && session.effects(on: grayLayer, image: gray.image).isEmpty,
              "fresh native indexed-mode refusal preserves pixels, effects and history")

        let effects = try session.effects(on: layerA, image: a.image)
        try a.startRecording()
        filter = try begin(a, existing: effects[0].id, layer: layerA)
        a.setLevels(filter, early) { _ in }; try drain(a)
        check(try finish(a, filter, commit: true), "an existing Levels edit remains usable while recording")
        try a.stopRecording(); try drain(a)
        if case .failure(let reason)? = a.recorder.records.first?.resolution {
            check(reason.contains("existing effect"), "unsupported existing-effect recording is an explicit failure row")
        } else { check(false, "an existing effect edit must not masquerade as a new Levels effect") }

        let beforeLock = try pixels(b.image)
        try session.setLayerLocks(layerB, image: b.image, mask: [.pixels], values: [.pixels])
        let lockedUndo = try session.undoInfo(b.image)
        try b.startReplay(); try drain(b)
        var refused = false
        if case .failed(index: 0, reason: let reason) = b.replayStatus { refused = reason.contains("Unlock") }
        check(try refused && (try pixels(b.image)) == beforeLock && session.undoInfo(b.image) == lockedUndo &&
              session.effects(on: layerB, image: b.image).isEmpty,
              "fresh native lock refusal leaves no Levels preview, effect or Undo step")
        try session.setLayerLocks(layerB, image: b.image, mask: [.pixels], values: [])

        func refusesRole(_ label: String) throws {
            let before = try pixels(b.image), undo = try session.undoInfo(b.image)
            try b.startReplay(); try drain(b)
            var refused = false
            if case .failed(index: 0, reason: let reason) = b.replayStatus {
                refused = reason.contains("Finish editing the channel or layer mask")
            }
            check(try refused && (try pixels(b.image)) == before && session.undoInfo(b.image) == undo &&
                  session.effects(on: layerB, image: b.image).isEmpty,
                  "fresh native \(label) refusal preserves pixels, effects and history")
        }
        // Bypass document reload deliberately: replay must inspect native state.
        _ = try session.addLayerMask(extraB, image: b.image, source: .white, edit: true)
        try refusesRole("selected mask")
        try session.setLayerMask(extraB, image: b.image, flags: .editing, values: [])
        try session.select(.all, image: b.image)
        let channel = try session.channelFromSelection(b.image, name: "Levels refusal")
        try session.selectItems([channel], kind: .channel, image: b.image)
        try refusesRole("saved channel")
        try session.selectItems([], kind: .channel, image: b.image)
        try session.select(.none, image: b.image)
        try session.setQuickMask(b.image, enabled: true)
        try refusesRole("Quick Mask")
        try session.setQuickMask(b.image, enabled: false)

        let (retry, retryLayer, _) = try fixture("Levels Apply retry")
        try retry.startRecording()
        filter = try begin(retry)
        retry.setLevels(filter, accepted) { _ in }; try drain(retry)
        try session.setLayerLocks(retryLayer, image: retry.image, mask: [.pixels], values: [.pixels])
        let retryUndo = try session.undoInfo(retry.image)
        check(try !finish(retry, filter, commit: true), "a newly locked layer refuses native Levels Apply")
        if case .failure? = retry.recorder.records.first?.resolution {
            check(try session.undoInfo(retry.image) == retryUndo && session.levelsSettings(filter) == accepted,
                  "failed Apply settles failure and leaves the preview available for retry")
        } else { check(false, "failed native Apply must not record a successful Levels action") }
        try session.setLayerLocks(retryLayer, image: retry.image, mask: [.pixels], values: [])
        check(try finish(retry, filter, commit: true), "unlocking allows the same Levels preview to apply")
        try retry.stopRecording(); try drain(retry)
        if case .success(.applyLevels(let captured))? = retry.recorder.records.last?.resolution {
            check(captured == accepted && retry.recorder.records.count == 2,
                  "retry retains capture metadata and settles one failure followed by one success")
        } else { check(false, "a successful retry must retain the original Levels capture") }

        let (maskDoc, maskLayer, _) = try fixture("Levels on mask")
        _ = try session.addLayerMask(maskLayer, image: maskDoc.image, source: .white, edit: true)
        try maskDoc.reload()
        try maskDoc.startRecording()
        filter = try begin(maskDoc)
        maskDoc.setLevels(filter, early) { _ in }; try drain(maskDoc)
        check(try finish(maskDoc, filter, commit: false) && maskDoc.recorder.records.isEmpty,
              "unsupported mask preview Cancel still records nothing")
        filter = try begin(maskDoc)
        maskDoc.setLevels(filter, early) { _ in }; try drain(maskDoc)
        check(try finish(maskDoc, filter, commit: true), "live Levels on a mask remains usable")
        try maskDoc.stopRecording(); try drain(maskDoc)
        if case .failure(let reason)? = maskDoc.recorder.records.first?.resolution {
            check(reason.contains("layer mask"), "an applied mask adjustment records its unsupported role honestly")
        } else { check(false, "a mask Levels edit must not become a layer-bound action") }

        let (channelDoc, channelLayer, _) = try fixture("Levels on channel")
        try session.select(.all, image: channelDoc.image)
        let channelTarget = try session.channelFromSelection(channelDoc.image, name: "Levels channel target")
        try session.select(.none, image: channelDoc.image)
        try session.selectItems([channelTarget], kind: .channel, image: channelDoc.image)
        try channelDoc.reload()
        try channelDoc.startRecording()
        filter = try begin(channelDoc)
        channelDoc.setLevels(filter, early) { _ in }; try drain(channelDoc)
        let channelUndo = try session.undoInfo(channelDoc.image)
        check(try finish(channelDoc, filter, commit: true), "live Levels on a saved channel remains usable")
        try channelDoc.stopRecording(); try drain(channelDoc)
        if case .failure(let reason)? = channelDoc.recorder.records.first?.resolution {
            check(try reason.contains("channel") && channelDoc.recorder.records.count == 1 &&
                  session.undoInfo(channelDoc.image).undoCount == channelUndo.undoCount + 1 &&
                  session.effects(on: channelLayer, image: channelDoc.image).isEmpty,
                  "an applied channel adjustment records its unsupported role without becoming a layer action")
        } else { check(false, "a channel Levels edit must not become a layer-bound action") }

        let (closing, _, _) = try fixture("Levels close drain")
        filter = try begin(closing)
        closing.closeImageWhenDrained()
        try wait { (try? session.info(closing.image)) == nil }
        check((try? session.levelsSettings(filter)) == nil,
              "closing a document drains and destroys its remaining native preview")
    }
}
