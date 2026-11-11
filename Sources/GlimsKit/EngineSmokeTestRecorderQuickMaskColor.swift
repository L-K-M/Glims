import AppKit

private struct RecorderQuickMaskNativeState: Equatable {
    let info: EngineSession.ImageInfo
    let pixels: Data
    let layers: [Int32]
    let channels: [Int32]
    let quickMask: EngineSession.QuickMaskState
    let selection: CGRect?
    let outline: [EngineSession.Segment]
    let undo: EngineSession.UndoInfo
    let history: EngineSession.History
}

@MainActor
extension EngineSmokeTest {
    /// This fixture uses the native default color through capture and disk.
    /// It can also run against the document APIs before endpoint handling.
    static func exerciseRecorderQuickMaskColor(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        typealias Prepared = RecorderFileSemanticBridge.PreparedRecording
        typealias Choice = ImageDocument.RecorderInstallChoice
        let url = work.appendingPathComponent("native-default-quick-mask.glimsrecording")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        var owned: [ImageDocument] = []
        var loose: [Int32] = []
        var checks = 0
        var complete = false

        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            check(condition, "recorder Quick Mask color: \(message)")
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "RecorderQuickMaskColorFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let limit = Date().addingTimeInterval(20)
            while !condition() && Date() < limit { spin(0.005) }
            return condition()
        }
        func drain(_ doc: ImageDocument) throws {
            try require(wait { doc.pendingWork == 0 && !doc.recorder.isReplaying && !EngineActivity.shared.isBusy },
                        "Quick Mask color fixture did not drain \(doc.name)")
            spin(0.02)
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        defer {
            for doc in owned {
                doc.onError = nil
                doc.closeImageWhenDrained()
            }
            expect(wait { owned.allSatisfy { $0.pendingWork == 0 && gone($0.image) } }, "owned documents and accepted work close")
            documents.items.removeAll { doc in owned.contains { $0 === doc } }
            for image in loose { try? session.closeImage(image) }
            try? FileManager.default.removeItem(at: url)
            expect(loose.allSatisfy(gone) && !FileManager.default.fileExists(atPath: url.path), "reference image and recording file are removed")
            expect(complete, "all default-color scenarios completed")
            print("     recorder-quick-mask-color checks: \(checks)")
        }

        func fixture() throws -> (image: Int32, layer: Int32, ordinary: Int32, quick: Int32) {
            var rgba: [UInt8] = []
            for y in 0..<13 {
                for x in 0..<19 {
                    let red = UInt8((x * 17 + y * 7) % 256)
                    let green = UInt8((x * 3 + y * 23) % 256)
                    let blue = UInt8((x * x + y * 11 + 31) % 256)
                    rgba.append(contentsOf: [red, green, blue, 255])
                }
            }
            let image = try session.newImage(pixels: ClipboardImage(width: 19, height: 13, pixels: Data(rgba), origin: .zero))
            loose.append(image)
            guard let layer = try session.layers(image).first?.id else { throw ImageDocument.DocumentError.noLayer }
            try session.select(.rectangle(CGRect(x: 2, y: 2, width: 9, height: 7)), image: image,
                               options: .init(antialias: false))
            let ordinary = try session.channelFromSelection(image, name: "Ordinary saved alpha")
            try session.selectItems([], kind: .channel, image: image)
            try session.selectLayer(layer, image: image)
            try session.setQuickMask(image, enabled: true)
            let quick = try session.quickMask(image)
            try require(try quick.enabled && quick.channel > 0 && quick.channel != ordinary
                && session.selectedItems(.channel, image: image) == [quick.channel], "Native Quick Mask must own the selected channel")
            return (image, layer, ordinary, quick.channel)
        }
        func document(_ name: String, image: Int32) throws -> ImageDocument {
            let doc = try ImageDocument(session: session, image: image, name: name)
            loose.removeAll { $0 == image }
            owned.append(doc)
            documents.items.append(doc)
            try drain(doc)
            return doc
        }
        func native(_ image: Int32) throws -> RecorderQuickMaskNativeState {
            let info = try session.info(image)
            let render = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: info.width, height: info.height))
            guard let pixels = render.dataProvider?.data as Data? else { throw ImageDocument.DocumentError.targetChanged }
            return RecorderQuickMaskNativeState(info: info, pixels: pixels, layers: try session.selectedLayers(image),
                channels: try session.selectedItems(.channel, image: image), quickMask: try session.quickMask(image),
                selection: try session.selectionBounds(image: image), outline: try session.selectionOutline(image: image),
                undo: try session.undoInfo(image), history: try session.history(image))
        }
        func failedFirst(_ doc: ImageDocument) -> Bool {
            if case .failed(index: 0, reason: let reason) = doc.replayStatus { return !reason.isEmpty }
            return false
        }

        let source = try fixture(), destination = try fixture(), reference = try fixture()
        let a = try document("Default Quick Mask source", image: source.image)
        let b = try document("Explicit Quick Mask destination", image: destination.image)
        let raw = try session.quickMask(a.image).color
        let rgba = [Double(raw.redComponent), Double(raw.greenComponent), Double(raw.blueComponent), Double(raw.alphaComponent)]
        print("     recorder-quick-mask-color native default RGBA \(rgba)")
        let sample = CGPoint(x: 5, y: 5)
        let options = EngineSession.SelectOptions(antialias: false, threshold: 0.18)
        let beforeCapture = try native(a.image)
        try a.startRecording()
        a.selectColor(at: sample, options: options)
        try a.stopRecording()
        try drain(a)
        let afterCapture = try native(a.image)
        let captured: Bool
        if let row = a.recorder.records.first, case .success(.selectColor) = row.resolution { captured = true }
        else { captured = false }
        expect(captured && a.recorder.records.count == 1 && afterCapture.outline != beforeCapture.outline,
               "actual default Quick Mask color selection succeeds and changes the native selection")
        var capturedColor: RecorderColor?
        if case .context(let binding)? = a.recorderBindingDescriptions[0] { capturedColor = binding.quickMask.color }
        // The measured default red exceeds 1 on the pinned engine. Other
        // engines can return an in-range value, which must stay exact.
        let expectedRed = rgba[0] > 1 ? 1 : rgba[0]
        expect(capturedColor?.red == expectedRed && capturedColor?.green == rgba[1]
            && capturedColor?.blue == rgba[2] && capturedColor?.alpha == rgba[3]
            && afterCapture.quickMask == beforeCapture.quickMask,
               "capture stores a valid binding color and preserves the native default")

        var written: Result<ImageDocument.RecorderSaveOutcome, Error>?
        var saveCalls = 0
        a.saveRecording(to: url, checkpoint: try a.recorderInstallCheckpoint()) { result in
            saveCalls += 1
            written = result
        }
        try drain(a)
        let savedCurrent: Bool
        if case .success(.savedCurrentRevision)? = written { savedCurrent = true }
        else { savedCurrent = false }
        expect(saveCalls == 1 && savedCurrent && FileManager.default.fileExists(atPath: url.path),
               "default-color capture saves a complete recording file")
        try require(written != nil, "Default-color save did not complete")
        _ = try written?.get()
        expect(try native(a.image) == afterCapture && !a.hasUnsavedRecordingChanges, "Save changes only the recording's saved revision")

        var loaded: Result<Prepared, Error>?
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try RecorderFileSemanticBridge.prepare(RecorderFileStore.load(from: url)) }
            DispatchQueue.main.async { loaded = result }
        }
        try require(wait { loaded != nil }, "Actual file Load did not finish")
        guard let prepared = try loaded?.get(), let row = prepared.file.records.first,
              case .success(.selectColor(let point, let fileOptions), .context(let binding)) = row.outcome,
              case .quickMask(let symbol) = binding.target,
              let description = prepared.file.symbols.first(where: { $0.id == symbol })?.description else {
            throw NSError(domain: "RecorderQuickMaskColorFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Loaded file did not preserve the explicit Quick Mask role"])
        }
        expect(prepared.file.records.count == 1 && point == .init(x: 5, y: 5) && !fileOptions.sampleMerged
            && binding.quickMask.color == capturedColor && description.kind == .quickMask,
               "actual file Load retains color, command and Quick Mask role")
        try require(binding.layers.count <= 1 && binding.channels == [symbol], "Unexpected saved selection in the single-layer fixture")
        var choices: [UUID: Choice] = [symbol: .quickMask(destination.quick)]
        if let layer = binding.layers.first { choices[layer] = .layer(destination.layer) }
        let beforeInstall = try native(b.image), beforeReference = try native(reference.image)
        var installed: Result<Void, Error>?
        var installCalls = 0
        b.installRecording(prepared, checkpoint: try b.recorderInstallCheckpoint(), choices: choices) { result in
            installCalls += 1
            installed = result
        }
        try drain(b)
        try require(installed != nil, "Explicit binding install did not complete")
        try installed?.get()
        expect(try installCalls == 1 && source.quick != destination.quick && b.recorderLoadedFile == prepared.file
            && native(b.image) == beforeInstall && !b.hasUnsavedRecordingChanges,
               "explicit Load binds a different real Quick Mask without editing the image")

        try session.selectColor(at: sample, image: reference.image, options: options)
        try b.startReplay()
        try drain(b)
        let replayed = try native(b.image), direct = try native(reference.image)
        expect(b.replayStatus == .finished(total: 1) && replayed.pixels == direct.pixels && replayed.selection == direct.selection
            && replayed.outline == direct.outline && replayed.undo.undoCount - beforeInstall.undo.undoCount == direct.undo.undoCount - beforeReference.undo.undoCount,
               "loaded replay matches direct native selection, pixels and Undo")
        expect(try replayed.layers == beforeInstall.layers && replayed.channels == [destination.quick]
            && replayed.quickMask == beforeInstall.quickMask && native(a.image) == afterCapture && b.recorder.records.count == 1,
               "replay keeps the bound target, native color and source image")

        var wrongChoices = choices
        wrongChoices[symbol] = .quickMask(destination.ordinary)
        var wrongRole: Error?
        var wrongCalls = 0
        b.installRecording(prepared, checkpoint: try b.recorderInstallCheckpoint(), choices: wrongChoices) { result in
            wrongCalls += 1
            if case .failure(let error) = result { wrongRole = error }
        }
        try drain(b)
        expect(try wrongCalls == 1 && wrongRole as? ImageDocument.RecorderInstallError == .unavailableTarget(description.name)
            && b.recorderLoadedFile == prepared.file && native(b.image) == replayed,
               "ordinary channel ID cannot bind the Quick Mask role or replace the existing recording")

        // Change only the native overlay color. Before the run loop services
        // its event, the cache still admits replay and the native check must
        // refuse the changed interior color.
        let oldCache = b.quickMaskState
        try session.changeChannel(destination.quick, image: b.image,
                                  .init(color: NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 0.625)))
        let changed = try native(b.image)
        expect(b.quickMaskState == oldCache && changed.quickMask.color != replayed.quickMask.color
            && changed.quickMask.enabled == replayed.quickMask.enabled && changed.quickMask.channel == destination.quick
            && changed.quickMask.inverted == replayed.quickMask.inverted,
               "fresh-native control changes color while keeping the exact role and old cache")
        var errors: [String] = []
        b.onError = { errors.append($0) }
        try b.startReplay()
        expect(b.pendingWork == 1, "old cached color admits the fresh-native comparison")
        try drain(b)
        expect(try failedFirst(b) && errors.last?.contains("native layer, channel, mask or Quick Mask target differs") == true
            && native(b.image) == changed, "fresh-native color mismatch refuses replay before mutation")
        try b.reload()
        errors.removeAll()
        try b.startReplay()
        expect(try b.pendingWork == 0 && failedFirst(b) && errors.last?.contains("recorded layer, channel, mask or Quick Mask target has changed") == true
            && native(b.image) == changed && !b.hasUnsavedRecordingChanges,
               "cached color mismatch also refuses replay without changing image or recording")
        complete = true
    }
}
