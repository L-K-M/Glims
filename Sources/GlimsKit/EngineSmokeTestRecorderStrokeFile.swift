import AppKit

private struct RecorderStrokeFilePixels: Equatable {
    let raw: Data
    let merged: Data
}

private struct RecorderStrokeFileNativeState: Equatable {
    let pixels: RecorderStrokeFilePixels
    let layers: [EngineSession.Layer]
    let selected: [Int32]
    let undo: EngineSession.UndoInfo
    let history: EngineSession.History
    let components: EngineSession.ComponentState
}

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderStrokeFile(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        struct Scene {
            let image: Int32
            let layer: Int32
        }
        let directory = work.appendingPathComponent("recorder-stroke-file", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("Pencil and Eraser.glimsrecording")
        var owned: [ImageDocument] = []
        var loose: [Int32] = []
        var checks = 0
        var complete = false
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            check(value, "Recorder stroke file: \(message)")
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "RecorderStrokeFile", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.005) }
            return condition()
        }
        func drain(_ document: ImageDocument) throws {
            try require(wait {
                document.pendingWork == 0 && document.recorder.pendingCount == 0 &&
                !document.recorder.isReplaying && !EngineActivity.shared.isBusy
            }, "The saved stroke document did not drain")
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        defer {
            for document in owned {
                document.onError = nil
                document.closeImageWhenDrained()
            }
            expect(wait { owned.allSatisfy { $0.pendingWork == 0 && gone($0.image) } },
                   "A, B and all accepted file or replay work close")
            documents.items.removeAll { document in owned.contains { $0 === document } }
            for image in loose { try? session.closeImage(image) }
            expect(loose.allSatisfy(gone), "the independent native reference closes")
            try? FileManager.default.removeItem(at: directory)
            expect(!FileManager.default.fileExists(atPath: directory.path), "the owned recording directory is removed")
            expect(complete, "all saved stroke integration checks ran")
            print("     recorder-stroke-file checks: \(checks)")
        }

        var background: [UInt8] = [], foreground: [UInt8] = []
        for y in 0..<29 {
            for x in 0..<37 {
                background.append(contentsOf: [UInt8((x * 17 + y * 7) % 256), UInt8(y * 7), UInt8(x * 5), 255])
                foreground.append(contentsOf: [UInt8(x * 6), UInt8((y * 19 + x * 9) % 256), UInt8(y * 8),
                                                UInt8(77 + (x + y) % 96)])
            }
        }
        func scene() throws -> Scene {
            let image = try session.newImage(pixels: ClipboardImage(width: 37, height: 29,
                pixels: Data(background), origin: .zero))
            loose.append(image)
            let layer = try session.pastePixels(image, pixels: ClipboardImage(width: 37, height: 29,
                pixels: Data(foreground), origin: .zero), at: .zero)
            return Scene(image: image, layer: layer)
        }
        func document(_ scene: Scene, name: String) throws -> ImageDocument {
            let document = try ImageDocument(session: session, image: scene.image, name: name)
            owned.append(document)
            loose.removeAll { $0 == scene.image }
            documents.items.append(document)
            try drain(document)
            return document
        }
        func pixels(_ image: Int32) throws -> RecorderStrokeFilePixels {
            try .init(raw: session.copyPixels(image, merged: false).pixels,
                      merged: session.copyPixels(image, merged: true).pixels)
        }
        func native(_ image: Int32) throws -> RecorderStrokeFileNativeState {
            try .init(pixels: pixels(image), layers: session.layers(image), selected: session.selectedLayers(image),
                      undo: session.undoInfo(image), history: session.history(image), components: session.components(image))
        }
        func agrees(_ image: Int32, with reference: RecorderStrokeFileNativeState) throws -> Bool {
            let value = try native(image)
            return value.pixels == reference.pixels && value.undo == reference.undo &&
                value.history.rows == reference.history.rows && value.history.currentPosition == reference.history.currentPosition
        }
        func install(_ prepared: RecorderFileSemanticBridge.PreparedRecording, on document: ImageDocument,
                     symbol: UUID, layer: Int32) throws {
            let checkpoint = try document.recorderInstallCheckpoint()
            var result: Result<Void, Error>?
            var calls = 0
            var heldWork = 0
            document.installRecording(prepared, checkpoint: checkpoint, choices: [symbol: .layer(layer)]) {
                calls += 1
                heldWork = document.pendingWork
                result = $0
            }
            try drain(document)
            try require(calls == 1 && heldWork > 0, "The explicit binding install did not finish exactly once while counted")
            try result?.get()
            try require(result != nil, "The explicit binding install produced no result")
        }

        guard let brushRow = try session.resources(.brush).first(where: { $0.displayName == "2. Hardness 025" }) else {
            throw NSError(domain: "RecorderStrokeFile", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "The installed monochrome brush is absent"])
        }
        let resource = try session.resourceIdentifiers(brushRow.id)
        let pencil = EngineSession.Brush(tool: .pencil, size: 7, opacity: 0.67, red: 0.83, green: 0.15, blue: 0.41,
                                         pressureSize: false, resource: resource)
        var eraser = pencil
        eraser.tool = .eraser
        eraser.size = 9
        eraser.opacity = 0.53
        let first = EngineSession.StrokePoint(x: 6.5, y: 7.5, pressure: 0.91)
        let pencilBatches: [[EngineSession.StrokePoint]] = [
            [.init(x: 10.5, y: 8.5, pressure: 0.73, timeMilliseconds: 17),
             .init(x: 15.5, y: 11.5, pressure: 0.58, timeMilliseconds: 34)],
            [.init(x: 20.5, y: 16.5, pressure: 0.85, timeMilliseconds: 50),
             .init(x: 26.5, y: 17.5, pressure: 0.94, timeMilliseconds: 69)],
        ]
        let eraseFirst = EngineSession.StrokePoint(x: 14.5, y: 13.5, pressure: 0.82, timeMilliseconds: 100)
        let eraserBatches: [[EngineSession.StrokePoint]] = [
            [.init(x: 19.5, y: 14.5, pressure: 0.61, timeMilliseconds: 119)],
            [.init(x: 25.5, y: 18.5, pressure: 0.76, timeMilliseconds: 137)],
        ]
        let source = try scene(), destination = try scene(), reference = try scene()
        let a = try document(source, name: "Stroke source A")
        let b = try document(destination, name: "Stroke destination B")
        var errorsA: [String] = [], errorsB: [String] = []
        a.onError = { errorsA.append($0) }
        b.onError = { errorsB.append($0) }
        let initial = try native(reference.image)
        expect(try source.layer != destination.layer && source.layer != reference.layer &&
               destination.layer != reference.layer && pixels(a.image) == initial.pixels &&
               pixels(b.image) == initial.pixels && initial.pixels.raw != initial.pixels.merged,
               "three independent RGBA layers start with matching raw and merged buffers and distinct native IDs")

        func direct(_ brush: EngineSession.Brush, first: EngineSession.StrokePoint,
                    batches: [[EngineSession.StrokePoint]]) throws {
            let stroke = try session.beginStroke(image: reference.image, drawable: reference.layer, brush: brush, first: first)
            do { for batch in batches { try session.continueStroke(stroke, points: batch) } }
            catch { try? session.endStroke(stroke); throw error }
            try session.endStroke(stroke)
        }
        try a.startRecording()
        a.beginStroke(at: first, brush: pencil)
        for batch in pencilBatches { a.continueStroke(batch) }
        a.endStroke()
        try drain(a)
        try direct(pencil, first: first, batches: pencilBatches)
        let afterPencil = try native(reference.image)
        expect(try agrees(a.image, with: afterPencil) && afterPencil.pixels.raw != initial.pixels.raw &&
               afterPencil.pixels.merged != initial.pixels.merged && afterPencil.undo.undoCount == initial.undo.undoCount + 1,
               "recorded Pencil matches a direct V1 stroke in both buffers and one Undo")
        a.beginStroke(at: eraseFirst, brush: eraser)
        for batch in eraserBatches { a.continueStroke(batch) }
        a.endStroke()
        try a.stopRecording()
        try drain(a)
        try direct(eraser, first: eraseFirst, batches: eraserBatches)
        let finished = try native(reference.image)
        expect(try errorsA.isEmpty && agrees(a.image, with: finished) &&
               finished.pixels.raw != afterPencil.pixels.raw && finished.pixels.merged != afterPencil.pixels.merged &&
               finished.undo.undoCount == afterPencil.undo.undoCount + 1,
               "recorded RGBA Eraser matches the independent V1 result and its own Undo")
        guard a.recorder.records.count == 2,
              case .success(.completeStroke(let capturedPencil)) = a.recorder.records[0].resolution,
              case .success(.completeStroke(let capturedEraser)) = a.recorder.records[1].resolution else {
            throw NSError(domain: "RecorderStrokeFile", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The two recorded native strokes did not settle"])
        }
        expect(try capturedPencil.trace.first == .init(first) &&
               capturedPencil.trace.batches == pencilBatches.map { try $0.map(RecorderStrokeTrace.Point.init) } &&
               capturedEraser.trace.first == .init(eraseFirst) &&
               capturedEraser.trace.batches == eraserBatches.map { try $0.map(RecorderStrokeTrace.Point.init) },
               "both settled strokes own their literal first points and exact continuation batches")

        let beforeSave = try native(a.image), beforeB = try native(b.image)
        let saveCheckpoint = try a.recorderSaveCheckpoint()
        var saveResult: Result<ImageDocument.RecorderSaveOutcome, Error>?
        var saveCalls = 0
        var saveHeldWork = 0
        a.saveRecording(to: fileURL, checkpoint: saveCheckpoint) {
            saveCalls += 1
            saveHeldWork = a.pendingWork
            saveResult = $0
        }
        expect(saveCalls == 0 && a.pendingWork > 0, "the real RecorderFileStore save is counted before returning")
        try drain(a)
        try require(saveCalls == 1 && saveResult != nil, "The saved stroke completion did not run exactly once")
        let outcome = try saveResult!.get()
        expect(outcome == .savedCurrentRevision && saveHeldWork > 0 && !a.hasUnsavedRecordingChanges,
               "successful file replacement acknowledges the current recording before releasing its work count")
        expect(try native(a.image) == beforeSave && native(b.image) == beforeB,
               "saving strokes preserves both native documents exactly")
        let savedBytes = try Data(contentsOf: fileURL)
        let decoded = try RecorderFileCodec.decode(savedBytes)
        guard let root = try JSONSerialization.jsonObject(with: savedBytes) as? [String: Any],
              let rows = root["records"] as? [[String: Any]], rows.count == 2 else {
            throw NSError(domain: "RecorderStrokeFile", code: 4)
        }
        let idFree = rows.allSatisfy { row in
            guard let command = row["command"] as? [String: Any],
                  Set(command.keys) == Set(["tag", "settings", "facts", "first", "batches"]),
                  let facts = command["facts"] as? [String: Any], Set(facts.keys) == Set(["brush", "fingerprint"]),
                  let brush = facts["brush"] as? [String: Any] else { return false }
            return Set(brush.keys).isSubset(of: ["name", "collection", "isInternal"])
        }
        expect((root["version"] as? Int) == 2 && idFree,
               "the saved version 2 command schema contains resource facts and symbolic bindings without native IDs")
        guard decoded.records.count == 2,
              case .success(.completeStroke(let loadedPencil), .layer(let symbol)) = decoded.records[0].outcome,
              case .success(.completeStroke(let loadedEraser), .layer(let eraserSymbol)) = decoded.records[1].outcome else {
            throw NSError(domain: "RecorderStrokeFile", code: 5)
        }
        expect(loadedPencil == capturedPencil && loadedEraser == capturedEraser && symbol == eraserSymbol &&
               decoded.symbols.count == 1 && decoded.symbols[0].id == symbol && decoded.symbols[0].description.kind == .pixel &&
               loadedPencil.facts.brush == resource && loadedEraser.facts.brush == resource,
               "decoding owns both exact stroke payloads and their one original pixel-layer symbol")

        var preparedResult: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        var prepareCalls = 0
        var prepareHeldWork = 0
        b.prepareRecordingFile(at: fileURL, checkpoint: try b.recorderInstallCheckpoint()) {
            prepareCalls += 1
            prepareHeldWork = b.pendingWork
            preparedResult = $0
        }
        expect(prepareCalls == 0 && b.pendingWork > 0, "loading and preparing the saved file hold B through real disk work")
        try drain(b)
        try require(prepareCalls == 1 && preparedResult != nil, "The file preparation callback did not run exactly once")
        let prepared = try preparedResult!.get()
        expect(prepared.file == decoded && prepareHeldWork > 0 && !b.recorder.isRecording && b.recorder.records.isEmpty,
               "preparation retains the entire file while leaving B's Recorder detached")
        try install(prepared, on: b, symbol: symbol, layer: destination.layer)
        expect(try native(b.image) == beforeB && b.recorderLoadedFile == decoded && b.recorder.records.count == 2 &&
               !b.hasUnsavedRecordingChanges, "explicit installation binds B's distinct layer without editing its native image")
        try b.startReplay()
        try drain(b)
        expect(try errorsB.isEmpty && b.replayStatus == .finished(total: 2) && agrees(b.image, with: finished) &&
               session.selectedLayers(b.image) == [destination.layer],
               "saved Pencil and Eraser replay on B matches direct V1 raw, merged and native Undo history")
        expect(try native(a.image) == beforeSave && native(reference.image) == finished,
               "replay leaves the captured A and independent reference unchanged")
        b.undo(); try drain(b)
        expect(try pixels(b.image) == afterPencil.pixels &&
               session.undoInfo(b.image).undoCount == afterPencil.undo.undoCount,
               "one loaded replay Undo removes only the Eraser")
        b.undo(); try drain(b)
        expect(try pixels(b.image) == initial.pixels && session.undoInfo(b.image).undoCount == initial.undo.undoCount,
               "the second loaded replay Undo restores the original raw and merged buffers")
        b.redo(); try drain(b)
        expect(try pixels(b.image) == afterPencil.pixels, "first replay Redo restores the Pencil")
        b.redo(); try drain(b)
        expect(try agrees(b.image, with: finished), "second replay Redo restores both strokes and native history")

        b.undo(); try drain(b)
        b.undo(); try drain(b)
        var wrongDigest = Array(loadedPencil.facts.fingerprint.utf8)
        wrongDigest[0] = wrongDigest[0] == 48 ? 49 : 48
        let corruptedStroke = RecorderStrokeCommand(settings: loadedPencil.settings, trace: loadedPencil.trace,
            facts: .init(brush: loadedPencil.facts.brush, fingerprint: String(decoding: wrongDigest, as: UTF8.self)))
        let corrupted = RecorderFileValue(recordingID: decoded.recordingID, name: decoded.name, origin: decoded.origin,
            symbols: decoded.symbols, records: [
                .init(ordinal: 0, outcome: .success(.completeStroke(corruptedStroke), .layer(symbol))), decoded.records[1],
            ])
        let beforeRefusal = try native(b.image)
        try install(RecorderFileSemanticBridge.prepare(corrupted), on: b, symbol: symbol, layer: destination.layer)
        try b.startReplay()
        try drain(b)
        let wrongFingerprintRefused: Bool
        if case .failed(index: 0, reason: let reason) = b.replayStatus { wrongFingerprintRefused = !reason.isEmpty }
        else { wrongFingerprintRefused = false }
        expect(try wrongFingerprintRefused && native(b.image) == beforeRefusal,
               "an otherwise valid prepared file with a wrong fingerprint refuses before first paint or Undo")

        try install(prepared, on: b, symbol: symbol, layer: destination.layer)
        try session.setComponents(b.image, activeMask: .red, activeValues: [])
        try b.reload()
        let disabled = try native(b.image)
        expect(!disabled.components.active.contains(.red) && disabled.pixels == beforeRefusal.pixels &&
               disabled.undo == beforeRefusal.undo, "the unsupported active component state is real and changes no image bytes or Undo")
        try b.startReplay()
        try drain(b)
        let disabledRefused: Bool
        if case .failed(index: 0, reason: let reason) = b.replayStatus { disabledRefused = !reason.isEmpty }
        else { disabledRefused = false }
        expect(try disabledRefused && native(b.image) == disabled,
               "the saved supported stroke refuses an unsupported current native configuration before mutation")
        expect(try Data(contentsOf: fileURL) == savedBytes && native(a.image) == beforeSave,
               "successful and refused replay leave the saved file and source A unchanged")
        complete = true
    }
}
