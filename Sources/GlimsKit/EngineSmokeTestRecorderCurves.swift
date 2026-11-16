import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderCurves(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var owned: [ImageDocument] = []
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "RecorderCurvesFixture", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.005) }
            try require(condition(), "Curves recorder work timed out")
        }
        func drain(_ doc: ImageDocument) throws {
            try wait { doc.pendingWork == 0 && doc.recorder.pendingCount == 0 &&
                !doc.recorder.isReplaying && !EngineActivity.shared.isBusy }
        }
        func settleNativeEvents(_ doc: ImageDocument) throws {
            var crossed = false
            DispatchQueue.main.async { crossed = true }
            try wait { crossed }
            try drain(doc)
        }
        func pixels(_ doc: ImageDocument) throws -> Data { try session.copyPixels(doc.image, merged: true).pixels }
        var bytes: [UInt8] = []
        for i in 0..<120 { bytes += [UInt8(i * 13 % 256), UInt8(i * 31 % 256), UInt8(i * 7 % 256), 255] }
        let input = ClipboardImage(width: 12, height: 10, pixels: Data(bytes), origin: .zero)
        func fixture(_ name: String) throws -> (ImageDocument, Int32, Int32) {
            let image = try session.newImage(width: 16, height: 14)
            let layer = try session.pastePixels(image, pixels: input, at: CGPoint(x: 2, y: 2))
            let extra = try session.layers(image).first { $0.id != layer }!.id
            let doc = try ImageDocument(session: session, image: image, name: name)
            doc.onError = { _ in }; owned.append(doc); documents.items.append(doc)
            return (doc, layer, extra)
        }
        func begin(_ doc: ImageDocument, existing: Int32? = nil, layer: Int32? = nil) throws -> Int32 {
            var result: Result<ImageDocument.FilterPreviewStart, Error>?
            if let existing, let layer {
                doc.beginEffectPreview(effect: existing, on: layer, properties: [], operation: "gimp:curves") { result = $0 }
            } else {
                doc.beginFilterPreview(operation: "gimp:curves", properties: []) { result = $0 }
            }
            try drain(doc); try require(result != nil, "Curves begin callback missing")
            return try result!.get().filter
        }
        func finish(_ doc: ImageDocument, _ filter: Int32, commit: Bool) throws -> Bool {
            var result: Bool?
            doc.finishFilter(filter, commit: commit) { result = $0 }
            try drain(doc); try require(result != nil, "Curves finish callback missing")
            return result!
        }
        defer {
            for doc in owned { doc.closeImageWhenDrained() }
            try? wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            check(owned.allSatisfy { (try? session.info($0.image)) == nil }, "Curves recorder closes every owned image")
            documents.items.removeAll { doc in owned.contains { $0 === doc } }
        }
        let patches: [CurvesDraft.Patch] = [
            .trc(.linear),
            .curve(.smooth(channel: .value, points: [.init(x: 0, y: 0.1, kind: .corner), .init(x: 1, y: 0.8)])),
            .curve(.free(channel: .red, samples: (0..<256).map { Double($0) / 510 })),
            .curve(.smooth(channel: .green, points: [.init(x: 0, y: 0), .init(x: 0.5, y: 0.3, kind: .corner), .init(x: 1, y: 1)])),
            .curve(.free(channel: .blue, samples: (0..<256).map { 1 - Double($0) / 510 })),
            .curve(.smooth(channel: .alpha, points: [.init(x: 0, y: 0.2), .init(x: 1, y: 0.9)]))
        ]
        let (a, layerA, extraA) = try fixture("Curves capture")
        let (b, layerB, extraB) = try fixture("Curves rebound")
        let (reference, referenceLayer, _) = try fixture("Curves native patch oracle")
        let oracle = try session.beginFilter(image: reference.image, drawable: referenceLayer, operation: "gimp:curves")
        for patch in patches {
            switch patch {
            case .trc(let trc): _ = try session.setCurvesTRC(oracle, to: trc)
            case .curve(let edit): _ = try session.editCurve(oracle, edit: edit)
            }
        }
        let expected = try session.curvesSettings(oracle)
        try session.commitFilter(oracle)
        let original = try pixels(a), baseline = a.undoInfo.undoCount
        try a.startRecording()
        var filter = try begin(a)
        a.setCurves(filter, patch: patches[1]) { _ in }; try drain(a)
        check(try a.recorder.records.isEmpty && (try pixels(a)) != original,
              "Curves preview changes pixels without recording")
        check(try finish(a, filter, commit: false) && a.recorder.records.isEmpty &&
              (try pixels(a)) == original && a.undoInfo.undoCount == baseline,
              "Curves Cancel restores exact pixels and records nothing")
        filter = try begin(a)
        a.selectLayer(extraA); try drain(a)
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        a.inputQueue.async { entered.signal(); release.wait() }
        try require(entered.wait(timeout: .now() + 5) == .success, "Curves queue hold failed")
        var writes = 0
        for patch in patches { a.setCurves(filter, patch: patch) { if case .success = $0 { writes += 1 } } }
        var applied: Bool?
        a.finishFilter(filter, commit: true) { applied = $0 }
        try a.stopRecording()
        check(a.recorder.pendingCount == 1, "Curves Apply reserves one row before Stop and queued writes finish")
        release.signal(); try drain(a)
        guard case .success(.applyCurves(let captured))? = a.recorder.records.first?.resolution,
              case .layer(let symbol)? = a.recorderBindingDescriptions[0] else {
            return check(false, "Curves Apply records an explicit layer and complete settings")
        }
        check(applied == true && writes == patches.count && captured == expected && a.recorder.records.count == 1,
              "Curves capture reads final authoritative TRC, kind, identity, points and samples after all queued edits")
        let changed = try pixels(a)
        check(try changed != original && changed == (try pixels(reference)) && a.undoInfo.undoCount == baseline + 1 &&
              session.effects(on: layerA, image: a.image).count == 1 && session.effects(on: extraA, image: a.image).isEmpty &&
              session.selectedLayers(a.image) == [extraA], "Curves Apply keeps its begin-time layer and equals independent native patches with one Undo")
        a.undo(); try drain(a); check(try (try pixels(a)) == original, "Curves Undo restores original pixels")
        a.redo(); try drain(a); check(try (try pixels(a)) == changed, "Curves Redo restores exact output")
        let url = work.appendingPathComponent("curves.glims-recording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        a.saveRecording(to: url, checkpoint: try a.recorderSaveCheckpoint()) { saved = $0 }
        try drain(a); try require(saved != nil, "Curves save callback missing"); _ = try saved!.get()
        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        a.prepareRecordingFile(at: url, checkpoint: try a.recorderInstallCheckpoint()) { loaded = $0 }
        try drain(a); try require(loaded != nil, "Curves load callback missing")
        let prepared = try loaded!.get()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        check(json?["version"] as? Int == 7, "saved Curves recording declares version seven")
        var installed: Result<Void, Error>?
        b.installRecording(prepared, checkpoint: try b.recorderInstallCheckpoint(), choices: [symbol: .layer(layerB)]) { installed = $0 }
        try drain(b); try require(installed != nil, "Curves install callback missing"); try installed!.get()
        b.selectLayer(extraB); try drain(b)
        let bUndo = b.undoInfo.undoCount
        try b.startReplay(); try drain(b)
        check(try (try pixels(b)) == changed && b.undoInfo.undoCount == bUndo + 1 &&
              session.effects(on: layerB, image: b.image).count == 1 && session.effects(on: extraB, image: b.image).isEmpty &&
              session.selectedLayers(b.image) == [extraB], "saved Curves rebinds explicitly and matches patch oracle through the whole-value writer")
        let effects = try session.effects(on: layerB, image: b.image)
        let inspect = try session.beginEditingEffect(effects[0].id, on: layerB, image: b.image)
        check(try session.curvesSettings(inspect) == expected, "Curves replay restores every stored field exactly")
        try session.abortFilter(inspect)
        b.undo(); try drain(b); check(try (try pixels(b)) == original, "rebound Curves Undo restores original destination")
        try session.setLayerLocks(layerB, image: b.image, mask: [.pixels], values: [.pixels])
        let lockedUndo = try session.undoInfo(b.image)
        try b.startReplay(); try drain(b)
        var refused = false
        if case .failed(index: 0, reason: let reason) = b.replayStatus { refused = reason.contains("Unlock") }
        check(try refused && (try pixels(b)) == original && session.undoInfo(b.image) == lockedUndo &&
              session.effects(on: layerB, image: b.image).isEmpty, "fresh Curves lock refusal leaves no pixels, effect or Undo changes")
        try session.setLayerLocks(layerB, image: b.image, mask: [.pixels], values: [])
        _ = try session.addLayerMask(extraB, image: b.image, source: .white, edit: true)
        let maskUndo = try session.undoInfo(b.image)
        try b.startReplay(); try drain(b)
        refused = false
        if case .failed(index: 0, reason: let reason) = b.replayStatus { refused = reason.contains("Finish editing the channel or layer mask") }
        check(try refused && session.undoInfo(b.image) == maskUndo && session.effects(on: layerB, image: b.image).isEmpty,
              "Curves replay checks fresh mask-editing state without trusting document cache")
        let existing = try session.effects(on: layerA, image: a.image)[0].id
        try a.startRecording(); filter = try begin(a, existing: existing, layer: layerA)
        a.setCurves(filter, patch: .curve(.reset(channel: .red))) { _ in }; try drain(a)
        check(try finish(a, filter, commit: true), "existing Curves edit remains usable while recording")
        try a.stopRecording(); try drain(a)
        if case .failure(let reason)? = a.recorder.records.first?.resolution {
            check(reason.contains("existing effect"), "existing Curves edit records an explicit unsupported row")
        } else { check(false, "existing Curves effect must not become a new-effect action") }
        let (retry, retryLayer, _) = try fixture("Curves Apply retry")
        try retry.startRecording(); filter = try begin(retry)
        retry.setCurves(filter, patch: patches[1]) { _ in }; try drain(retry)
        let retrySettings = try session.curvesSettings(filter)
        try session.setLayerLocks(retryLayer, image: retry.image, mask: [.pixels], values: [.pixels])
        check(try !finish(retry, filter, commit: true), "locked Curves Apply refuses")
        if case .failure? = retry.recorder.records.first?.resolution {
            check(try session.curvesSettings(filter) == retrySettings, "failed Curves Apply settles failure and keeps its preview for retry")
        } else { check(false, "failed Curves Apply must not record success") }
        try session.setLayerLocks(retryLayer, image: retry.image, mask: [.pixels], values: [])
        check(try finish(retry, filter, commit: true), "unlocked Curves retry applies")
        try retry.stopRecording(); try drain(retry)
        if case .success(.applyCurves(let accepted))? = retry.recorder.records.last?.resolution {
            check(accepted == retrySettings && retry.recorder.records.count == 2, "Curves retry retains original capture metadata")
        } else { check(false, "successful Curves retry must preserve capture") }

        let (maskDoc, maskLayer, _) = try fixture("Curves on mask")
        _ = try session.addLayerMask(maskLayer, image: maskDoc.image, source: .white, edit: true)
        try maskDoc.reload()
        try maskDoc.startRecording(); filter = try begin(maskDoc)
        maskDoc.setCurves(filter, patch: patches[1]) { _ in }; try drain(maskDoc)
        let maskSettings = try session.curvesSettings(filter)
        check(try finish(maskDoc, filter, commit: true), "live Curves on a mask remains usable")
        try maskDoc.stopRecording(); try drain(maskDoc)
        guard case .success(.applyCurves(let captured))? = maskDoc.recorder.records.first?.resolution,
              case .context(let target)? = maskDoc.recorderBindingDescriptions[0],
              case .mask(let maskSymbol) = target.target else {
            return check(false, "an applied mask Curves adjustment records its mask role and settings")
        }
        check(captured == maskSettings, "an applied mask Curves adjustment records its mask role and settings")
        let maskURL = work.appendingPathComponent("mask-curves.glims-recording")
        var maskSaved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        maskDoc.saveRecording(to: maskURL, checkpoint: try maskDoc.recorderSaveCheckpoint()) { maskSaved = $0 }
        try drain(maskDoc); try require(maskSaved != nil, "Mask Curves save callback missing"); _ = try maskSaved!.get()
        var maskLoaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        maskDoc.prepareRecordingFile(at: maskURL, checkpoint: try maskDoc.recorderInstallCheckpoint()) { maskLoaded = $0 }
        try drain(maskDoc); try require(maskLoaded != nil, "Mask Curves load callback missing")
        let maskPrepared = try maskLoaded!.get()
        let maskJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: maskURL)) as? [String: Any]
        check(maskJSON?["version"] as? Int == 24, "saved mask Curves declares version 24")
        let (maskDest, maskDestLayer, _) = try fixture("Mask Curves rebound")
        try settleNativeEvents(maskDest)
        var missingInstall: Result<Void, Error>?
        maskDest.installRecording(maskPrepared, checkpoint: try maskDest.recorderInstallCheckpoint(),
                                  choices: [maskSymbol: .layer(maskDestLayer)]) { missingInstall = $0 }
        try drain(maskDest); try require(missingInstall != nil, "Maskless Curves install callback missing")
        if case .failure(let error)? = missingInstall,
           case .missingMask = error as? ImageDocument.RecorderInstallError {
            check(true, "mask Curves refuses binding to a layer without a mask")
        } else { check(false, "mask Curves refuses binding to a layer without a mask") }
        _ = try session.addLayerMask(maskDestLayer, image: maskDest.image, source: .white, edit: true)
        try maskDest.reload(); try settleNativeEvents(maskDest)
        var maskInstalled: Result<Void, Error>?
        maskDest.installRecording(maskPrepared, checkpoint: try maskDest.recorderInstallCheckpoint(),
                                  choices: [maskSymbol: .layer(maskDestLayer)]) { maskInstalled = $0 }
        try drain(maskDest); try require(maskInstalled != nil, "Mask Curves install callback missing"); try maskInstalled!.get()
        let beforeMaskReplay = try pixels(maskDest), beforeMaskUndo = try session.undoInfo(maskDest.image)
        try maskDest.startReplay(); try drain(maskDest)
        check(try pixels(maskDest) == pixels(maskDoc) && pixels(maskDest) != beforeMaskReplay &&
              session.undoInfo(maskDest.image).undoCount == beforeMaskUndo.undoCount + 1 &&
              session.effects(on: maskDestLayer, image: maskDest.image).isEmpty,
              "saved mask Curves replays on the rebound mask as one destructive Undo step")
        maskDest.undo(); try drain(maskDest)
        check(try pixels(maskDest) == beforeMaskReplay, "mask Curves Undo restores destination pixels")
        try session.setLayerMask(maskDestLayer, image: maskDest.image, flags: .editing, values: [])
        let stalePixels = try pixels(maskDest), staleHistory = try session.undoInfo(maskDest.image)
        try maskDest.startReplay(); try drain(maskDest)
        var maskRefused = false
        if case .failed(index: 0, reason: _) = maskDest.replayStatus { maskRefused = true }
        check(try maskRefused && pixels(maskDest) == stalePixels && session.undoInfo(maskDest.image) == staleHistory,
              "fresh native mask-role changes refuse Curves replay without modifying pixels or history")
    }
}
