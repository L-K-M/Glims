import AppKit

@MainActor
extension EngineSmokeTest {
    /// Records, saves, rebinds and replays one new Brightness/Contrast
    /// adjustment driven through the real panel, then proves unsupported and
    /// retry rows like the other layer-bound adjustment families.
    static func exerciseRecorderBrightnessContrast(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var owned: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        var loose: [Int32] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "RecorderBrightnessContrastFixture", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.005) }
            try require(condition(), "Brightness/Contrast recorder work timed out")
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
                doc.beginEffectPreview(effect: existing, on: layer, properties: [], operation: "gimp:brightness-contrast") { result = $0 }
            } else {
                doc.beginFilterPreview(operation: "gimp:brightness-contrast", properties: []) { result = $0 }
            }
            try drain(doc); try require(result != nil, "Brightness/Contrast begin callback missing")
            return try result!.get().filter
        }
        func finish(_ doc: ImageDocument, _ filter: Int32, commit: Bool) throws -> Bool {
            var result: Bool?
            doc.finishFilter(filter, commit: commit) { result = $0 }
            try drain(doc); try require(result != nil, "Brightness/Contrast finish callback missing")
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
                  "Brightness/Contrast recorder closes every owned image")
            documents.items.removeAll { doc in owned.contains { $0 === doc } }
            for image in loose { try? session.closeImage(image) }
        }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        guard let operation = operations.first(where: { $0.name == "gimp:brightness-contrast" }) else {
            return check(false, "Brightness/Contrast is available")
        }
        let (a, layerA, extraA) = try fixture("Brightness/Contrast capture")
        let (b, layerB, extraB) = try fixture("Brightness/Contrast rebound")
        let controllerA = DocumentWindowController(document: a)
        controllers.append(controllerA); controllerA.showWindow(nil)
        func open() throws -> BrightnessContrastPanel {
            controllerA.openNativeFilter(operation)
            try wait { controllerA.previewPanel != nil && a.pendingWork == 0 }
            guard let panel = controllerA.previewPanel as? BrightnessContrastPanel else {
                throw NSError(domain: "RecorderBrightnessContrastFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Brightness/Contrast did not open its dedicated panel"])
            }
            return panel
        }
        let reference = try session.newImage(width: 16, height: 14); loose.append(reference)
        let referenceLayer = try session.pastePixels(reference, pixels: input, at: CGPoint(x: 2, y: 2))
        let accepted = EngineSession.BrightnessContrastSettings(brightness: 0.3, contrast: -0.25)
        let original = try pixels(a.image), baseline = a.undoInfo.undoCount
        try a.startRecording()
        // Real panel Cancel: preview writes move pixels without recording.
        var panel = try open()
        panel.brightnessSlider.doubleValue = 20; panel.sliderChanged(panel.brightnessSlider)
        try drain(a)
        check(try a.recorder.records.isEmpty && (try pixels(a.image)) != original,
              "Brightness/Contrast preview changes the image without recording a command")
        panel.cancel()
        try wait { controllerA.previewPanel == nil && a.pendingWork == 0 }
        check(try a.recorder.records.isEmpty && (try pixels(a.image)) == original && a.undoInfo.undoCount == baseline,
              "Brightness/Contrast Cancel records nothing and restores exact pixels and history")

        // Real panel Apply through controls. Selection changes behind the open
        // panel must not retarget capture.
        panel = try open()
        guard let panelFilter = panel.filter else { return check(false, "Brightness/Contrast panel keeps its session") }
        a.selectLayer(extraA); try drain(a)
        check(try session.selectedLayers(a.image) == [layerA],
              "an open Brightness/Contrast panel refuses an ordinary layer switch")
        try session.selectLayers([extraA], image: a.image)
        try a.reload()
        try require(try session.selectedLayers(a.image) == [extraA], "Brightness/Contrast retarget fixture did not change selection")
        panel.brightnessSlider.doubleValue = 30; panel.sliderChanged(panel.brightnessSlider)
        panel.contrastSlider.doubleValue = -25; panel.sliderChanged(panel.contrastSlider)
        try drain(a)
        check(try session.brightnessContrastSettings(panelFilter) == accepted,
              "panel writes land as the complete acknowledged native settings")
        panel.commit()
        try wait { controllerA.previewPanel == nil && a.pendingWork == 0 }
        try a.stopRecording(); try drain(a)
        guard case .success(.applyBrightnessContrast(let captured))? = a.recorder.records.first?.resolution,
              case .layer(let symbol)? = a.recorderBindingDescriptions[0] else {
            return check(false, "Brightness/Contrast Apply records its explicit layer and semantic settings")
        }
        check(captured == accepted && a.recorder.records.count == 1,
              "recording captures acknowledged brightness and contrast exactly")
        check(a.recorderDescriptions.values[symbol] == .available(.init(name: a.layers.first { $0.id == layerA }!.name,
              kind: .pixel, ancestors: [], siblingIndex: a.layers.firstIndex { $0.id == layerA }!,
              bounds: .init(x: 2, y: 2, width: 12, height: 10))),
              "Brightness/Contrast capture describes the original layer after selection changes")
        let oracle = try session.beginFilter(image: reference, drawable: referenceLayer, operation: "gimp:brightness-contrast")
        try session.setBrightnessContrastSettings(oracle, to: accepted); try session.commitFilter(oracle)
        let changed = try pixels(a.image)
        check(try changed != original && changed == (try pixels(reference)) &&
              a.undoInfo.undoCount == baseline + 1 && session.effects(on: layerA, image: a.image).count == 1 &&
              session.effects(on: extraA, image: a.image).isEmpty && session.selectedLayers(a.image) == [extraA],
              "recorded Apply matches the independent native result and adds one effect and Undo step")
        let effectA = try session.effects(on: layerA, image: a.image)[0]
        let inspect = try session.beginEditingEffect(effectA.id, on: layerA, image: a.image)
        check(try session.brightnessContrastSettings(inspect) == accepted,
              "the committed effect stores brightness and contrast exactly")
        try session.abortFilter(inspect)
        a.undo(); try drain(a)
        check(try (try pixels(a.image)) == original && session.effects(on: layerA, image: a.image).isEmpty,
              "Brightness/Contrast Undo removes the effect and restores every pixel")
        a.redo(); try drain(a)
        check(try pixels(a.image) == changed, "Brightness/Contrast Redo restores exact output")

        let url = work.appendingPathComponent("brightness-contrast.glims-recording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        a.saveRecording(to: url, checkpoint: try a.recorderSaveCheckpoint()) { saved = $0 }
        try drain(a); try require(saved != nil, "Brightness/Contrast save callback missing"); _ = try saved!.get()
        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        a.prepareRecordingFile(at: url, checkpoint: try a.recorderInstallCheckpoint()) { loaded = $0 }
        try drain(a); try require(loaded != nil, "Brightness/Contrast load callback missing")
        let prepared = try loaded!.get()
        let encoded = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        check(encoded?["version"] as? Int == 10, "saved Brightness/Contrast recording declares version ten")
        var installed: Result<Void, Error>?
        b.installRecording(prepared, checkpoint: try b.recorderInstallCheckpoint(), choices: [symbol: .layer(layerB)]) { installed = $0 }
        try drain(b); try require(installed != nil, "Brightness/Contrast install callback missing"); try installed!.get()
        b.selectLayer(extraB); try drain(b)
        let bUndo = b.undoInfo.undoCount
        try b.startReplay(); try drain(b)
        check(try (try pixels(b.image)) == changed && b.undoInfo.undoCount == bUndo + 1 &&
              session.effects(on: layerB, image: b.image).count == 1 &&
              session.effects(on: extraB, image: b.image).isEmpty && session.selectedLayers(b.image) == [extraB],
              "saved Brightness/Contrast rebinds to its chosen layer while preserving the unrelated selected layer")
        let effectB = try session.effects(on: layerB, image: b.image)[0]
        let inspectB = try session.beginEditingEffect(effectB.id, on: layerB, image: b.image)
        check(try session.brightnessContrastSettings(inspectB) == accepted,
              "the replayed effect preserves recorded brightness and contrast exactly")
        try session.abortFilter(inspectB)
        b.undo(); try drain(b)
        check(try pixels(b.image) == original, "rebound Brightness/Contrast Undo restores exact destination pixels")
        check(try pixels(a.image) == changed && a.recorder.records.count == 1,
              "replaying the saved file leaves the recorded source image untouched")

        try a.startRecording()
        let redoneEffect = try session.effects(on: layerA, image: a.image)[0]
        var filter = try begin(a, existing: redoneEffect.id, layer: layerA)
        var early = accepted; early.brightness = 0.1
        a.setBrightnessContrast(filter, early) { _ in }; try drain(a)
        check(try finish(a, filter, commit: true), "an existing Brightness/Contrast edit remains usable while recording")
        try a.stopRecording(); try drain(a)
        if case .failure(let reason)? = a.recorder.records.first?.resolution {
            check(reason.contains("existing effect"), "unsupported existing-effect recording is an explicit failure row")
        } else { check(false, "an existing effect edit must not masquerade as a new Brightness/Contrast effect") }

        let beforeLock = try pixels(b.image)
        try session.setLayerLocks(layerB, image: b.image, mask: [.pixels], values: [.pixels])
        let lockedUndo = try session.undoInfo(b.image)
        try b.startReplay(); try drain(b)
        var refused = false
        if case .failed(index: 0, reason: let reason) = b.replayStatus { refused = reason.contains("Unlock") }
        check(try refused && (try pixels(b.image)) == beforeLock && session.undoInfo(b.image) == lockedUndo &&
              session.effects(on: layerB, image: b.image).isEmpty,
              "fresh native lock refusal leaves no Brightness/Contrast preview, effect or Undo step")
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
        _ = try session.addLayerMask(extraB, image: b.image, source: .white, edit: true)
        try refusesRole("selected mask")
        try session.setLayerMask(extraB, image: b.image, flags: .editing, values: [])
        try session.select(.all, image: b.image)
        let channel = try session.channelFromSelection(b.image, name: "Brightness/Contrast refusal")
        try session.selectItems([channel], kind: .channel, image: b.image)
        try refusesRole("saved channel")
        try session.selectItems([], kind: .channel, image: b.image)
        try session.select(.none, image: b.image)
        try session.setQuickMask(b.image, enabled: true)
        try refusesRole("Quick Mask")
        try session.setQuickMask(b.image, enabled: false)

        let (retry, retryLayer, _) = try fixture("Brightness/Contrast Apply retry")
        try retry.startRecording()
        filter = try begin(retry)
        retry.setBrightnessContrast(filter, accepted) { _ in }; try drain(retry)
        try session.setLayerLocks(retryLayer, image: retry.image, mask: [.pixels], values: [.pixels])
        let retryUndo = try session.undoInfo(retry.image)
        check(try !finish(retry, filter, commit: true), "a newly locked layer refuses native Brightness/Contrast Apply")
        if case .failure? = retry.recorder.records.first?.resolution {
            check(try session.undoInfo(retry.image) == retryUndo && session.brightnessContrastSettings(filter) == accepted,
                  "failed Apply settles failure and leaves the preview available for retry")
        } else { check(false, "failed native Apply must not record a successful Brightness/Contrast action") }
        try session.setLayerLocks(retryLayer, image: retry.image, mask: [.pixels], values: [])
        check(try finish(retry, filter, commit: true), "unlocking allows the same Brightness/Contrast preview to apply")
        try retry.stopRecording(); try drain(retry)
        if case .success(.applyBrightnessContrast(let captured))? = retry.recorder.records.last?.resolution {
            check(captured == accepted && retry.recorder.records.count == 2,
                  "retry retains capture metadata and settles one failure followed by one success")
        } else { check(false, "a successful retry must retain the original Brightness/Contrast capture") }

        let (maskDoc, maskLayer, _) = try fixture("Brightness/Contrast on mask")
        _ = try session.addLayerMask(maskLayer, image: maskDoc.image, source: .white, edit: true)
        try maskDoc.reload()
        try maskDoc.startRecording()
        filter = try begin(maskDoc)
        maskDoc.setBrightnessContrast(filter, early) { _ in }; try drain(maskDoc)
        check(try finish(maskDoc, filter, commit: false) && maskDoc.recorder.records.isEmpty,
              "unsupported mask preview Cancel still records nothing")
        filter = try begin(maskDoc)
        maskDoc.setBrightnessContrast(filter, early) { _ in }; try drain(maskDoc)
        check(try finish(maskDoc, filter, commit: true), "live Brightness/Contrast on a mask remains usable")
        try maskDoc.stopRecording(); try drain(maskDoc)
        if case .failure(let reason)? = maskDoc.recorder.records.first?.resolution {
            check(reason.contains("layer mask"), "an applied mask adjustment records its unsupported role honestly")
        } else { check(false, "a mask Brightness/Contrast edit must not become a layer-bound action") }

        let (channelDoc, channelLayer, _) = try fixture("Brightness/Contrast on channel")
        try session.select(.all, image: channelDoc.image)
        let channelTarget = try session.channelFromSelection(channelDoc.image, name: "Brightness/Contrast channel target")
        try session.select(.none, image: channelDoc.image)
        try session.selectItems([channelTarget], kind: .channel, image: channelDoc.image)
        try channelDoc.reload()
        try channelDoc.startRecording()
        filter = try begin(channelDoc)
        channelDoc.setBrightnessContrast(filter, early) { _ in }; try drain(channelDoc)
        let channelUndo = try session.undoInfo(channelDoc.image)
        check(try finish(channelDoc, filter, commit: true), "live Brightness/Contrast on a saved channel remains usable")
        try channelDoc.stopRecording(); try drain(channelDoc)
        if case .failure(let reason)? = channelDoc.recorder.records.first?.resolution {
            check(try reason.contains("channel") && channelDoc.recorder.records.count == 1 &&
                  session.undoInfo(channelDoc.image).undoCount == channelUndo.undoCount + 1 &&
                  session.effects(on: channelLayer, image: channelDoc.image).isEmpty,
                  "an applied channel adjustment records its unsupported role without becoming a layer action")
        } else { check(false, "a channel Brightness/Contrast edit must not become a layer-bound action") }
    }
}
