import AppKit

@MainActor
extension EngineSmokeTest {
    /// Records, saves, rebinds and replays one new Hue/Saturation adjustment
    /// driven through the real panel, then proves the unsupported and retry
    /// rows the earlier adjustments established for the same capture path.
    static func exerciseRecorderHueSaturation(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var owned: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        var loose: [Int32] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "RecorderHueSaturationFixture", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.005) }
            try require(condition(), "Hue/Saturation recorder work timed out")
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
                doc.beginEffectPreview(effect: existing, on: layer, properties: [], operation: "gimp:hue-saturation") { result = $0 }
            } else {
                doc.beginFilterPreview(operation: "gimp:hue-saturation", properties: []) { result = $0 }
            }
            try drain(doc); try require(result != nil, "Hue/Saturation begin callback missing")
            return try result!.get().filter
        }
        func finish(_ doc: ImageDocument, _ filter: Int32, commit: Bool) throws -> Bool {
            var result: Bool?
            doc.finishFilter(filter, commit: commit) { result = $0 }
            try drain(doc); try require(result != nil, "Hue/Saturation finish callback missing")
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
                  "Hue/Saturation recorder closes every owned image")
            documents.items.removeAll { doc in owned.contains { $0 === doc } }
            for image in loose { try? session.closeImage(image) }
        }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        guard let operation = operations.first(where: { $0.name == "gimp:hue-saturation" }) else {
            return check(false, "Hue/Saturation is available")
        }
        let (a, layerA, extraA) = try fixture("Hue/Saturation capture")
        let (b, layerB, extraB) = try fixture("Hue/Saturation rebound")
        let controllerA = DocumentWindowController(document: a)
        controllers.append(controllerA); controllerA.showWindow(nil)
        func open() throws -> HueSaturationPanel {
            controllerA.openNativeFilter(operation)
            try wait { controllerA.previewPanel != nil && a.pendingWork == 0 }
            guard let panel = controllerA.previewPanel as? HueSaturationPanel else {
                throw NSError(domain: "RecorderHueSaturationFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Hue/Saturation did not open its dedicated panel"])
            }
            return panel
        }
        let reference = try session.newImage(width: 16, height: 14); loose.append(reference)
        let referenceLayer = try session.pastePixels(reference, pixels: input, at: CGPoint(x: 2, y: 2))
        // All 21 range corrections nonzero plus overlap; display units match
        // the panel's own degrees/percent normalization exactly.
        var accepted = EngineSession.HueSaturationSettings()
        accepted.overlap = 45.0 / 100.0
        accepted.master = .init(hue: 45.0 / 180.0, saturation: -50.0 / 100.0, lightness: 10.0 / 100.0)
        accepted.red = .init(hue: -90.0 / 180.0, saturation: 30.0 / 100.0, lightness: -20.0 / 100.0)
        accepted.yellow = .init(hue: 30.0 / 180.0, saturation: 60.0 / 100.0, lightness: 40.0 / 100.0)
        accepted.green = .init(hue: -60.0 / 180.0, saturation: -70.0 / 100.0, lightness: 50.0 / 100.0)
        accepted.cyan = .init(hue: 120.0 / 180.0, saturation: 80.0 / 100.0, lightness: -60.0 / 100.0)
        accepted.blue = .init(hue: -135.0 / 180.0, saturation: -90.0 / 100.0, lightness: 70.0 / 100.0)
        accepted.magenta = .init(hue: 162.0 / 180.0, saturation: 100.0 / 100.0, lightness: -80.0 / 100.0)
        let original = try pixels(a.image), baseline = a.undoInfo.undoCount
        try a.startRecording()
        // Real panel Cancel: preview writes move pixels without recording.
        var panel = try open()
        panel.saturationSlider.doubleValue = 25; panel.sliderChanged(panel.saturationSlider)
        try drain(a)
        check(try a.recorder.records.isEmpty && (try pixels(a.image)) != original,
              "Hue/Saturation preview changes the image without recording a command")
        panel.cancel()
        try wait { controllerA.previewPanel == nil && a.pendingWork == 0 }
        check(try a.recorder.records.isEmpty && (try pixels(a.image)) == original && a.undoInfo.undoCount == baseline,
              "Hue/Saturation Cancel records nothing and restores exact pixels and history")

        // Real panel Apply: every named range and overlap through the
        // visible controls. The record must capture the acknowledged
        // native settings, not the panel's fields.
        panel = try open()
        guard let panelFilter = panel.filter else { return check(false, "Hue/Saturation panel keeps its session") }
        // The panel refuses ordinary target switches. Also exercise a native
        // selection change behind it: capture must keep the begin-time layer.
        a.selectLayer(extraA); try drain(a)
        check(try session.selectedLayers(a.image) == [layerA],
              "an open Hue/Saturation panel refuses an ordinary layer switch")
        try session.selectLayers([extraA], image: a.image)
        try a.reload()
        try require(try session.selectedLayers(a.image) == [extraA], "Hue/Saturation retarget fixture did not change selection")
        func setRange(_ index: Int, _ values: (Double, Double, Double)) {
            panel.rangePopup.selectItem(at: index); panel.rangeChanged(panel.rangePopup)
            panel.hueSlider.doubleValue = values.0; panel.sliderChanged(panel.hueSlider)
            panel.saturationSlider.doubleValue = values.1; panel.sliderChanged(panel.saturationSlider)
            panel.lightnessSlider.doubleValue = values.2; panel.sliderChanged(panel.lightnessSlider)
        }
        setRange(0, (45, -50, 10))
        setRange(1, (-90, 30, -20))
        setRange(2, (30, 60, 40))
        setRange(3, (-60, -70, 50))
        setRange(4, (120, 80, -60))
        setRange(5, (-135, -90, 70))
        setRange(6, (162, 100, -80))
        panel.overlapSlider.doubleValue = 45; panel.sliderChanged(panel.overlapSlider)
        try drain(a)
        check(try session.hueSaturationSettings(panelFilter) == accepted,
              "panel writes land as the complete acknowledged native settings")
        panel.commit()
        try wait { controllerA.previewPanel == nil && a.pendingWork == 0 }
        try a.stopRecording(); try drain(a)
        guard case .success(.applyHueSaturation(let captured))? = a.recorder.records.first?.resolution,
              case .layer(let symbol)? = a.recorderBindingDescriptions[0] else {
            return check(false, "Hue/Saturation Apply records its explicit layer and semantic settings")
        }
        check(captured == accepted && a.recorder.records.count == 1,
              "recording captures all 21 acknowledged corrections and overlap")
        check(a.recorderDescriptions.values[symbol] == .available(.init(name: a.layers.first { $0.id == layerA }!.name,
              kind: .pixel, ancestors: [], siblingIndex: a.layers.firstIndex { $0.id == layerA }!,
              bounds: .init(x: 2, y: 2, width: 12, height: 10))),
              "Hue/Saturation capture describes the original layer after selection changes")
        let oracle = try session.beginFilter(image: reference, drawable: referenceLayer, operation: "gimp:hue-saturation")
        try session.setHueSaturationSettings(oracle, to: accepted); try session.commitFilter(oracle)
        let changed = try pixels(a.image)
        check(try changed != original && changed == (try pixels(reference)) &&
              a.undoInfo.undoCount == baseline + 1 && session.effects(on: layerA, image: a.image).count == 1 &&
              session.effects(on: extraA, image: a.image).isEmpty && session.selectedLayers(a.image) == [extraA],
              "recorded Apply matches the independent native result and adds one effect and Undo step")
        // The committed effect preserves the exact recorded settings.
        let effectA = try session.effects(on: layerA, image: a.image)[0]
        let inspect = try session.beginEditingEffect(effectA.id, on: layerA, image: a.image)
        check(try session.hueSaturationSettings(inspect) == accepted,
              "the committed effect stores all 21 corrections and overlap exactly")
        try session.abortFilter(inspect)
        a.undo(); try drain(a)
        check(try (try pixels(a.image)) == original && session.effects(on: layerA, image: a.image).isEmpty,
              "Hue/Saturation Undo removes the effect and restores every pixel")
        a.redo(); try drain(a)
        check(try pixels(a.image) == changed, "Hue/Saturation Redo restores exact output")

        let url = work.appendingPathComponent("hue-saturation.glims-recording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        a.saveRecording(to: url, checkpoint: try a.recorderSaveCheckpoint()) { saved = $0 }
        try drain(a); try require(saved != nil, "Hue/Saturation save callback missing"); _ = try saved!.get()
        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        a.prepareRecordingFile(at: url, checkpoint: try a.recorderInstallCheckpoint()) { loaded = $0 }
        try drain(a); try require(loaded != nil, "Hue/Saturation load callback missing")
        let prepared = try loaded!.get()
        let encoded = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        check(encoded?["version"] as? Int == 9, "saved Hue/Saturation recording declares version nine")
        var installed: Result<Void, Error>?
        b.installRecording(prepared, checkpoint: try b.recorderInstallCheckpoint(), choices: [symbol: .layer(layerB)]) {
            installed = $0
        }
        try drain(b); try require(installed != nil, "Hue/Saturation install callback missing"); try installed!.get()
        b.selectLayer(extraB); try drain(b)
        let bUndo = b.undoInfo.undoCount
        try b.startReplay(); try drain(b)
        check(try (try pixels(b.image)) == changed && b.undoInfo.undoCount == bUndo + 1 &&
              session.effects(on: layerB, image: b.image).count == 1 &&
              session.effects(on: extraB, image: b.image).isEmpty && session.selectedLayers(b.image) == [extraB],
              "saved Hue/Saturation rebinds to its chosen layer while preserving the unrelated selected layer")
        let effectB = try session.effects(on: layerB, image: b.image)[0]
        let inspectB = try session.beginEditingEffect(effectB.id, on: layerB, image: b.image)
        check(try session.hueSaturationSettings(inspectB) == accepted,
              "the replayed effect preserves every recorded correction exactly")
        try session.abortFilter(inspectB)
        b.undo(); try drain(b)
        check(try pixels(b.image) == original, "rebound Hue/Saturation Undo restores exact destination pixels")
        // The replay never touched the source document.
        check(try pixels(a.image) == changed && a.recorder.records.count == 1,
              "replaying the saved file leaves the recorded source image untouched")

        try a.startRecording()
        let redoneEffect = try session.effects(on: layerA, image: a.image)[0]
        var filter = try begin(a, existing: redoneEffect.id, layer: layerA)
        var early = accepted; early.master.saturation = -0.25
        a.setHueSaturation(filter, early) { _ in }; try drain(a)
        check(try finish(a, filter, commit: true), "an existing Hue/Saturation edit remains usable while recording")
        try a.stopRecording(); try drain(a)
        if case .failure(let reason)? = a.recorder.records.first?.resolution {
            check(reason.contains("existing effect"), "unsupported existing-effect recording is an explicit failure row")
        } else { check(false, "an existing effect edit must not masquerade as a new Hue/Saturation effect") }

        let beforeLock = try pixels(b.image)
        try session.setLayerLocks(layerB, image: b.image, mask: [.pixels], values: [.pixels])
        let lockedUndo = try session.undoInfo(b.image)
        try b.startReplay(); try drain(b)
        var refused = false
        if case .failed(index: 0, reason: let reason) = b.replayStatus { refused = reason.contains("Unlock") }
        check(try refused && (try pixels(b.image)) == beforeLock && session.undoInfo(b.image) == lockedUndo &&
              session.effects(on: layerB, image: b.image).isEmpty,
              "fresh native lock refusal leaves no Hue/Saturation preview, effect or Undo step")
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
        let channel = try session.channelFromSelection(b.image, name: "Hue/Saturation refusal")
        try session.selectItems([channel], kind: .channel, image: b.image)
        try refusesRole("saved channel")
        try session.selectItems([], kind: .channel, image: b.image)
        try session.select(.none, image: b.image)
        try session.setQuickMask(b.image, enabled: true)
        try refusesRole("Quick Mask")
        try session.setQuickMask(b.image, enabled: false)

        let (retry, retryLayer, _) = try fixture("Hue/Saturation Apply retry")
        try retry.startRecording()
        filter = try begin(retry)
        retry.setHueSaturation(filter, accepted) { _ in }; try drain(retry)
        try session.setLayerLocks(retryLayer, image: retry.image, mask: [.pixels], values: [.pixels])
        let retryUndo = try session.undoInfo(retry.image)
        check(try !finish(retry, filter, commit: true), "a newly locked layer refuses native Hue/Saturation Apply")
        if case .failure? = retry.recorder.records.first?.resolution {
            check(try session.undoInfo(retry.image) == retryUndo && session.hueSaturationSettings(filter) == accepted,
                  "failed Apply settles failure and leaves the preview available for retry")
        } else { check(false, "failed native Apply must not record a successful Hue/Saturation action") }
        try session.setLayerLocks(retryLayer, image: retry.image, mask: [.pixels], values: [])
        check(try finish(retry, filter, commit: true), "unlocking allows the same Hue/Saturation preview to apply")
        try retry.stopRecording(); try drain(retry)
        if case .success(.applyHueSaturation(let captured))? = retry.recorder.records.last?.resolution {
            check(captured == accepted && retry.recorder.records.count == 2,
                  "retry retains capture metadata and settles one failure followed by one success")
        } else { check(false, "a successful retry must retain the original Hue/Saturation capture") }

        let (maskDoc, maskLayer, _) = try fixture("Hue/Saturation on mask")
        _ = try session.addLayerMask(maskLayer, image: maskDoc.image, source: .white, edit: true)
        try maskDoc.reload()
        try maskDoc.startRecording()
        filter = try begin(maskDoc)
        maskDoc.setHueSaturation(filter, early) { _ in }; try drain(maskDoc)
        check(try finish(maskDoc, filter, commit: false) && maskDoc.recorder.records.isEmpty,
              "unsupported mask preview Cancel still records nothing")
        filter = try begin(maskDoc)
        maskDoc.setHueSaturation(filter, early) { _ in }; try drain(maskDoc)
        check(try finish(maskDoc, filter, commit: true), "live Hue/Saturation on a mask remains usable")
        try maskDoc.stopRecording(); try drain(maskDoc)
        if case .failure(let reason)? = maskDoc.recorder.records.first?.resolution {
            check(reason.contains("layer mask"), "an applied mask adjustment records its unsupported role honestly")
        } else { check(false, "a mask Hue/Saturation edit must not become a layer-bound action") }

        let (channelDoc, channelLayer, _) = try fixture("Hue/Saturation on channel")
        try session.select(.all, image: channelDoc.image)
        let channelTarget = try session.channelFromSelection(channelDoc.image, name: "Hue/Saturation channel target")
        try session.select(.none, image: channelDoc.image)
        try session.selectItems([channelTarget], kind: .channel, image: channelDoc.image)
        try channelDoc.reload()
        try channelDoc.startRecording()
        filter = try begin(channelDoc)
        channelDoc.setHueSaturation(filter, early) { _ in }; try drain(channelDoc)
        let channelUndo = try session.undoInfo(channelDoc.image)
        check(try finish(channelDoc, filter, commit: true), "live Hue/Saturation on a saved channel remains usable")
        try channelDoc.stopRecording(); try drain(channelDoc)
        if case .failure(let reason)? = channelDoc.recorder.records.first?.resolution {
            check(try reason.contains("channel") && channelDoc.recorder.records.count == 1 &&
                  session.undoInfo(channelDoc.image).undoCount == channelUndo.undoCount + 1 &&
                  session.effects(on: channelLayer, image: channelDoc.image).isEmpty,
                  "an applied channel adjustment records its unsupported role without becoming a layer action")
        } else { check(false, "a channel Hue/Saturation edit must not become a layer-bound action") }
    }
}
