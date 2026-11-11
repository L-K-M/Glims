import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderAffine(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var owned: [ImageDocument] = []
        var loose: [Int32] = []
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "RecorderAffineFixture", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let until = Date().addingTimeInterval(15)
            while !condition() && Date() < until { spin(0.005) }
            try require(condition(), "Recorder affine work did not finish")
        }
        func drain(_ doc: ImageDocument) throws {
            try wait { doc.pendingWork == 0 && doc.recorder.pendingCount == 0
                && !doc.recorder.isReplaying && !EngineActivity.shared.isBusy }
        }
        func pixels(_ image: Int32) throws -> Data { try session.copyPixels(image, merged: true).pixels }
        func bounds(_ layer: Int32, _ image: Int32) throws -> CGRect {
            guard let value = try session.layers(image).first(where: { $0.id == layer }) else {
                throw ImageDocument.DocumentError.noLayer
            }
            return value.bounds
        }
        var bytes: [UInt8] = []
        for i in 0..<120 { bytes += [UInt8(i * 13 % 256), UInt8(i * 31 % 256), UInt8(i * 7 % 256), 255] }
        let input = ClipboardImage(width: 12, height: 10, pixels: Data(bytes), origin: .zero)
        func fixture(_ name: String) throws -> (ImageDocument, Int32, Int32) {
            let image = try session.newImage(width: 64, height: 48)
            let layer = try session.pastePixels(image, pixels: input, at: CGPoint(x: 4, y: 6))
            let extra = try session.layers(image).first { $0.id != layer }!.id
            let doc = try ImageDocument(session: session, image: image, name: name)
            doc.onError = { _ in }
            owned.append(doc); documents.items.append(doc)
            return (doc, layer, extra)
        }
        defer {
            for doc in owned { doc.closeImageWhenDrained() }
            try? wait { owned.allSatisfy { $0.pendingWork == 0 && (try? session.info($0.image)) == nil } }
            check(owned.allSatisfy { (try? session.info($0.image)) == nil }, "affine recorder closes every owned image")
            documents.items.removeAll { doc in owned.contains { $0 === doc } }
            for image in loose { try? session.closeImage(image) }
        }
        let (a, layerA, extraA) = try fixture("Affine capture")
        let (b, layerB, extraB) = try fixture("Affine rebound destination")
        let reference = try session.newImage(width: 64, height: 48); loose.append(reference)
        let referenceLayer = try session.pastePixels(reference, pixels: input, at: CGPoint(x: 4, y: 6))
        let matrix = CGAffineTransform(a: 1.25, b: 0.2, c: -0.15, d: 1.1, tx: 7, ty: 2)
        let original = try pixels(a.image), originalBounds = try bounds(layerA, a.image)
        let originalUndo = a.undoInfo.undoCount
        try a.startRecording()
        a.transformLayer(layerA, matrix: .identity, interpolation: .none)
        a.transformLayer(layerA, matrix: CGAffineTransform(translationX: 1e12, y: 0), interpolation: .none)
        try drain(a)
        check(try a.recorder.records.isEmpty && (try pixels(a.image)) == original,
              "identity and unsafe transform refusals record nothing and preserve pixels")
        a.transformLayer(layerA, matrix: matrix, interpolation: .none)
        try a.stopRecording(); try drain(a)
        try session.transformLayer(referenceLayer, image: reference, matrix: matrix, interpolation: .none)
        let transformed = try pixels(a.image), transformedBounds = try bounds(layerA, a.image)
        check(transformed != original && transformedBounds != originalBounds,
              "the asymmetric fixture produces a real pixel and geometry change")
        check(try transformed == (try pixels(reference)) && transformedBounds == (try bounds(referenceLayer, reference)),
              "captured transform matches independent native pixels and bounds")
        check(a.undoInfo.undoCount == originalUndo + 1 && a.recorder.records.count == 1,
              "one committed transform settles one command and one Undo step")
        guard case .success(.transformLayer(let captured, let interpolation))? = a.recorder.records.first?.resolution else {
            return check(false, "accepted transform records the affine semantic command")
        }
        check(captured == matrix && interpolation == .none, "capture keeps exact coefficients and interpolation")
        guard case .layer(let symbol)? = a.recorderBindingDescriptions[0] else {
            return check(false, "transform records an explicit layer symbol")
        }
        a.undo(); try drain(a)
        check(try (try pixels(a.image)) == original && (try bounds(layerA, a.image)) == originalBounds,
              "transform Undo restores exact pixels and bounds")
        a.redo(); try drain(a)
        check(try (try pixels(a.image)) == transformed && (try bounds(layerA, a.image)) == transformedBounds,
              "transform Redo restores exact transformed pixels and bounds")
        a.undo(); try drain(a)
        a.selectLayer(extraA); try drain(a)
        try a.startReplay(); try drain(a)
        check(try (try pixels(a.image)) == transformed && (try session.selectedLayers(a.image)) == [extraA],
              "same-document replay retains its explicit target while another layer is selected")
        check(a.recorder.records.count == 1, "replay does not recursively record itself")

        let url = work.appendingPathComponent("affine.glims-recording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        a.saveRecording(to: url, checkpoint: try a.recorderSaveCheckpoint()) { saved = $0 }
        try drain(a); try require(saved != nil, "save callback missing")
        _ = try saved!.get()
        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        a.prepareRecordingFile(at: url, checkpoint: try a.recorderInstallCheckpoint()) { loaded = $0 }
        try drain(a); try require(loaded != nil, "load callback missing")
        let prepared = try loaded!.get()
        let encoded = try String(contentsOf: url, encoding: .utf8)
        check(encoded.contains("\"version\":4") || encoded.contains("\"version\" : 4"),
              "saved transform recording declares format version four")
        var installed: Result<Void, Error>?
        b.installRecording(prepared, checkpoint: try b.recorderInstallCheckpoint(), choices: [symbol: .layer(layerB)]) {
            installed = $0
        }
        try drain(b); try require(installed != nil, "install callback missing"); try installed!.get()
        b.selectLayer(extraB); try drain(b)
        let bUndo = b.undoInfo.undoCount
        let otherBefore = try bounds(extraB, b.image)
        try b.startReplay(); try drain(b)
        check(try (try pixels(b.image)) == transformed && (try bounds(layerB, b.image)) == transformedBounds,
              "saved v4 recording rebinds to the chosen destination with exact native output")
        check(try b.undoInfo.undoCount == bUndo + 1 && (try bounds(extraB, b.image)) == otherBefore
              && (try session.selectedLayers(b.image)) == [extraB],
              "rebound transform has one Undo step and preserves the selected other layer")
        b.undo(); try drain(b)
        check(try (try pixels(b.image)) == original, "rebound transform Undo restores destination pixels")

        func refusesWithoutMutation(_ label: String, reason expected: String) throws {
            let before = try pixels(b.image), layerBounds = try bounds(layerB, b.image)
            let undo = try session.undoInfo(b.image)
            // A busy start or a fixture timeout must fail the test, not
            // masquerade as the particular worker-side admission check.
            try b.startReplay(); try drain(b)
            var refused = false
            if case .failed(index: 0, reason: let reason) = b.replayStatus {
                refused = reason.contains(expected)
            }
            check(try refused && (try pixels(b.image)) == before && (try bounds(layerB, b.image)) == layerBounds
                  && (try session.undoInfo(b.image)) == undo, "fresh replay refuses \(label) without mutation")
        }
        // Deliberately bypass document reload to exercise fresh native checks.
        try session.setLayerLocks(layerB, image: b.image, mask: .position, values: .position)
        try refusesWithoutMutation("a newly locked bound layer", reason: "Unlock the recorded layer")
        try session.setLayerLocks(layerB, image: b.image, mask: .position, values: [])
        _ = try session.addLayerMask(extraB, image: b.image, source: .white, edit: true)
        try refusesWithoutMutation("mask editing on a different selected layer", reason: "Finish editing the channel or layer mask")
        try session.setLayerMask(extraB, image: b.image, flags: .editing, values: [])
        try session.select(.all, image: b.image)
        let channel = try session.channelFromSelection(b.image, name: "Replay refusal")
        try session.selectItems([channel], kind: .channel, image: b.image)
        try refusesWithoutMutation("an active saved channel", reason: "Finish editing the channel or layer mask")
        try session.selectItems([], kind: .channel, image: b.image)
        try session.select(.none, image: b.image)
        try session.setQuickMask(b.image, enabled: true)
        try refusesWithoutMutation("Quick Mask", reason: "Finish editing the channel or layer mask")
        try session.setQuickMask(b.image, enabled: false)
        try b.reload()
        _ = try session.layerCommand(.delete, image: b.image, layer: layerB)
        let afterDelete = try pixels(b.image), afterDeleteUndo = try session.undoInfo(b.image)
        try b.startReplay(); try drain(b)
        if case .failed(index: 0, reason: _) = b.replayStatus {
            check(try (try pixels(b.image)) == afterDelete && (try session.undoInfo(b.image)) == afterDeleteUndo,
                  "fresh membership rejects a deleted recorded layer despite a stale document cache")
        } else { check(false, "deleted layer replay must fail") }

        let (failure, doomed, _) = try fixture("Accepted affine failure")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        failure.inputQueue.async { entered.signal(); _ = release.wait(timeout: .now() + 15) }
        try require(entered.wait(timeout: .now() + 2) == .success, "input hold did not start")
        try failure.startRecording()
        failure.transformLayer(doomed, matrix: matrix, interpolation: .none)
        try failure.stopRecording()
        _ = try session.layerCommand(.delete, image: failure.image, layer: doomed)
        let failurePixels = try pixels(failure.image), failureUndo = try session.undoInfo(failure.image)
        release.signal(); try drain(failure)
        if case .failure? = failure.recorder.records.first?.resolution {
            check(try failure.recorder.records.count == 1 && (try pixels(failure.image)) == failurePixels
                  && (try session.undoInfo(failure.image)) == failureUndo,
                  "an accepted transform that loses its target settles failure, never successful capture")
        } else { check(false, "accepted native transform failure must be recorded as failure") }
    }
}
