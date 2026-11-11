import AppKit
import Darwin

private struct RecorderSaveNativeState: Equatable {
    let info: EngineSession.ImageInfo
    let pixels: Data
    let layers: [EngineSession.Layer]
    let history: EngineSession.History
    let selection: CGRect?
}

@MainActor
private final class RecorderSaveCompletion {
    var calls = 0
    var heldWork = 0
    var result: Result<ImageDocument.RecorderSaveOutcome, Error>?

    var outcome: ImageDocument.RecorderSaveOutcome? {
        if case .success(let outcome)? = result { return outcome }
        return nil
    }
    var error: Error? {
        if case .failure(let error)? = result { return error }
        return nil
    }
}

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderSave(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        typealias Checkpoint = ImageDocument.RecorderInstallCheckpoint
        typealias CheckpointError = ImageDocument.RecorderInstallError
        let directory = work.appendingPathComponent("recorder-save-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var owned: [ImageDocument] = []
        var loose: [Int32] = []
        var releases: [DispatchSemaphore] = []
        var checks = 0
        var complete = false

        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            check(condition, "recorder save: \(message)")
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "RecorderSaveFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let limit = Date().addingTimeInterval(20)
            while !condition() && Date() < limit { spin(0.005) }
            return condition()
        }
        func drain(_ doc: ImageDocument) throws {
            try require(wait { doc.pendingWork == 0 && !doc.recorder.isReplaying && !EngineActivity.shared.isBusy },
                        "Recorder save fixture did not drain \(doc.name)")
            spin(0.02)
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        defer {
            releases.forEach { $0.signal() }
            for doc in owned {
                doc.onRecorderChange = nil
                doc.closeImageWhenDrained()
            }
            expect(wait { owned.allSatisfy { $0.pendingWork == 0 && gone($0.image) } }, "owned images and writes drain")
            documents.items.removeAll { doc in owned.contains { $0 === doc } }
            for image in loose { try? session.closeImage(image) }
            try? FileManager.default.removeItem(at: directory)
            expect(loose.allSatisfy(gone) && !FileManager.default.fileExists(atPath: directory.path), "fixture images and files are removed")
            expect(complete, "all save scenarios completed")
            print("     recorder-save checks: \(checks)")
        }

        func document(_ name: String, salt: Int) throws -> ImageDocument {
            var pixels: [UInt8] = []
            for y in 0..<13 {
                for x in 0..<17 {
                    let red = UInt8((x * 17 + y * 7 + salt) % 256)
                    let green = UInt8((x * 3 + y * 23) % 256)
                    let blue = UInt8((x * x + y * 11 + 31) % 256)
                    pixels.append(contentsOf: [red, green, blue, 255])
                }
            }
            let image = try session.newImage(pixels: ClipboardImage(width: 17, height: 13, pixels: Data(pixels), origin: .zero))
            loose.append(image)
            let doc = try ImageDocument(session: session, image: image, name: name)
            loose.removeAll { $0 == image }
            owned.append(doc)
            documents.items.append(doc)
            try drain(doc)
            return doc
        }
        func native(_ image: Int32) throws -> RecorderSaveNativeState {
            let info = try session.info(image)
            let raster = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: info.width, height: info.height))
            guard let pixels = raster.dataProvider?.data as Data? else { throw ImageDocument.DocumentError.targetChanged }
            return RecorderSaveNativeState(info: info, pixels: pixels, layers: try session.layers(image),
                                           history: try session.history(image), selection: try session.selectionBounds(image: image))
        }
        func url(_ name: String) -> URL { directory.appendingPathComponent(name + ".glimsrecording") }
        func read(_ url: URL) throws -> RecorderFileValue { try RecorderFileCodec.decode(Data(contentsOf: url)) }
        func save(_ doc: ImageDocument, to url: URL, checkpoint: Checkpoint? = nil) throws -> RecorderSaveCompletion {
            let stamp = try checkpoint ?? doc.recorderInstallCheckpoint()
            let result = RecorderSaveCompletion()
            doc.saveRecording(to: url, checkpoint: stamp) { outcome in
                result.calls += 1
                result.heldWork = doc.pendingWork
                result.result = outcome
            }
            return result
        }
        func finish(_ result: RecorderSaveCompletion, on doc: ImageDocument) throws {
            try drain(doc)
            try require(result.calls == 1, "Save completion must run exactly once")
        }
        func hold(_ doc: ImageDocument) throws -> DispatchSemaphore {
            let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
            releases.append(release)
            doc.inputQueue.async { entered.signal(); _ = release.wait(timeout: .now() + 20) }
            try require(entered.wait(timeout: .now() + 3) == .success, "Save fixture input hold did not start")
            return release
        }

        let a = try document("Save A", salt: 0)
        let b = try document("Save B", salt: 31)
        let beforeB = try native(b.image), metadataB = b.recorderFileMetadata
        let originalDraft = a.recorderFileMetadata
        expect(!a.hasUnsavedRecordingChanges && originalDraft.name == "Save A Recording", "never-used default draft is clean")
        try a.startRecording()
        let recording = a.recorderFileMetadata
        expect(recording.recordingID != originalDraft.recordingID && !a.hasUnsavedRecordingChanges,
               "starting an empty recording creates a new identity without dirtying it")
        let pending = try hold(a)
        a.transformImage(.rotate90)
        try a.stopRecording()
        let unsettled: Bool
        do { _ = try a.recorderInstallCheckpoint(); unsettled = false }
        catch let error as CheckpointError { unsettled = error == .unsettled }
        expect(a.recorder.pendingCount == 1 && a.hasUnsavedRecordingChanges && unsettled,
               "a pending row is unsaved and fences Save after Stop")
        pending.signal()
        try drain(a)
        let beforeSave = try native(a.image), imageWasDirty = a.hasUnsavedChanges
        expect(beforeSave.info.width == 13 && beforeSave.info.height == 17 && a.hasUnsavedRecordingChanges
            && recording.origin == .init(imageLabel: "Save A", initialWidth: 17, initialHeight: 13),
               "settled row stays unsaved and origin keeps the pre-command dimensions")

        let firstURL = url("Filename unrelated to the recording")
        let saved = try save(a, to: firstURL)
        expect(saved.calls == 0 && a.pendingWork == 1, "admitted disk write holds the document")
        try finish(saved, on: a)
        expect(saved.outcome == .savedCurrentRevision && saved.heldWork == 1 && !a.hasUnsavedRecordingChanges,
               "exact successful Save clears only the recording revision and completes before drain")
        let first = try read(firstURL)
        expect(first.recordingID == recording.recordingID && first.origin == recording.origin && first.name == "Save A Recording"
            && first.records == [.init(ordinal: 0, outcome: .success(.transformImage(.rotate90), .none))],
               "written file keeps the intrinsic name, stable identity, original origin and command")
        expect(try native(a.image) == beforeSave && a.hasUnsavedChanges == imageWasDirty && native(b.image) == beforeB,
               "Save preserves image dirty state, pixels, history and the other image")
        let savedCheckpoint = try a.recorderInstallCheckpoint()
        try a.startReplay()
        try drain(a)
        expect(try a.replayStatus == .finished(total: 1) && !a.hasUnsavedRecordingChanges
            && a.recorderInstallCheckpoint() == savedCheckpoint, "replay presentation leaves the saved revision clean")

        try a.renameRecording("Earlier intrinsic name")
        let earlierCheckpoint = try a.recorderInstallCheckpoint()
        let earlierURL = url("Earlier revision")
        let earlier = try save(a, to: earlierURL, checkpoint: earlierCheckpoint)
        try a.renameRecording("Newer draft")
        try finish(earlier, on: a)
        let earlierFile = try read(earlierURL)
        expect(earlier.outcome == .savedEarlierRevision && earlier.heldWork == 1 && earlierFile.name == "Earlier intrinsic name"
            && earlierFile.recordingID == recording.recordingID && a.recorderFileMetadata.name == "Newer draft" && a.hasUnsavedRecordingChanges,
               "stale success writes the admitted revision and leaves the newer draft unsaved")
        let staleURL = url("Stale request")
        let stale = try save(a, to: staleURL, checkpoint: earlierCheckpoint)
        expect(stale.calls == 1 && stale.heldWork == 0 && stale.error as? CheckpointError == .staleRecording
            && !FileManager.default.fileExists(atPath: staleURL.path), "obsolete checkpoint refuses before file I/O")
        let foreignURL = url("Wrong owner")
        let foreign = try save(a, to: foreignURL, checkpoint: b.recorderInstallCheckpoint())
        expect(foreign.calls == 1 && foreign.heldWork == 0 && foreign.error as? CheckpointError == .wrongDocument
            && !FileManager.default.fileExists(atPath: foreignURL.path) && b.recorderFileMetadata == metadataB,
               "foreign checkpoint cannot save either image's recording")

        let missingParent = directory.appendingPathComponent("missing/cannot-save.glimsrecording")
        let failed = try save(a, to: missingParent)
        try finish(failed, on: a)
        expect(try failed.error as? RecorderFileStore.StoreError == .io(operation: "open parent of", path: missingParent.path, code: ENOENT)
            && failed.heldWork == 1 && a.hasUnsavedRecordingChanges && a.recorderFileMetadata.name == "Newer draft"
            && read(earlierURL) == earlierFile, "store failure preserves dirty metadata and earlier saved bytes")

        let observedURL = url("Observer revision")
        var observerError: Error?
        a.onRecorderChange = {
            a.onRecorderChange = nil
            do { try a.renameRecording("Renamed by observer") }
            catch { observerError = error }
        }
        let observed = try save(a, to: observedURL)
        try finish(observed, on: a)
        expect(try observed.outcome == .savedEarlierRevision && observerError == nil && read(observedURL).name == "Newer draft"
            && a.recorderFileMetadata.name == "Renamed by observer" && a.hasUnsavedRecordingChanges,
               "reentrant name edit after publication still reports the saved revision accurately")

        try a.startRecording()
        a.scale(toWidth: 0, height: 13)
        try a.stopRecording()
        try drain(a)
        guard let row = a.recorder.records.first, case .failure(let reason) = row.resolution else {
            throw NSError(domain: "RecorderSaveFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected native scale refusal"])
        }
        expect(a.hasUnsavedRecordingChanges && a.recorder.records.count == 1, "failed-only live recording is meaningful unsaved content")
        let failureURL = url("Failed inspection")
        let savedFailure = try save(a, to: failureURL)
        try finish(savedFailure, on: a)
        expect(try savedFailure.outcome == .savedCurrentRevision && !a.hasUnsavedRecordingChanges
            && read(failureURL).records == [.init(ordinal: 0, outcome: .failure(reason))],
               "failed inspection row saves with its exact reason")

        let literal = #"""
        {"format":"ch.lkmc.Glims.recording","version":1,"recordingID":"11111111-1111-1111-1111-111111111111","name":"Loaded intrinsic name","origin":{"imageLabel":"Earlier image","initialWidth":7,"initialHeight":9},"symbols":[{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Unused original layer","kind":"pixel","ancestors":[],"siblingIndex":2,"bounds":{"x":-1,"y":2,"width":7,"height":9}}}],"records":[{"ordinal":0,"outcome":"failure","reason":"Earlier refusal"},{"ordinal":1,"outcome":"cancelled","reason":""}]}
        """#
        let loaded = try RecorderFileCodec.decode(Data(literal.utf8))
        let prepared = try RecorderFileSemanticBridge.prepare(loaded)
        let beforeLoad = try native(a.image)
        var installation: Result<Void, Error>?
        a.installRecording(prepared, checkpoint: try a.recorderInstallCheckpoint(), choices: [:]) { installation = $0 }
        try drain(a)
        try require(installation != nil, "Loaded recording install did not complete")
        try installation?.get()
        expect(!a.hasUnsavedRecordingChanges && a.recorderFileMetadata.recordingID == loaded.recordingID
            && a.recorderFileMetadata.origin == loaded.origin && a.recorderFileMetadata.name == loaded.name,
               "loaded recording starts clean with original identity, origin and name")
        let copyURL = url("Different Save As filename")
        let copied = try save(a, to: copyURL)
        try finish(copied, on: a)
        expect(try copied.outcome == .savedCurrentRevision && read(copyURL) == loaded && a.recorderFileMetadata.name == loaded.name,
               "unchanged Save As preserves unused descriptions, all outcomes and the intrinsic name")
        expect(try native(a.image) == beforeLoad && native(b.image) == beforeB, "loaded Save As leaves both native images unchanged")

        try b.renameRecording("Save before close")
        let closeURL = url("Accepted close write")
        let closeWrite = try save(b, to: closeURL)
        var closed = 0
        b.closeImageWhenDrained { closed += 1 }
        expect(try b.isClosing && b.pendingWork == 1 && closed == 0 && closeWrite.calls == 0 && session.info(b.image).width == 17,
               "real close waits while the accepted file write still owns its document")
        try require(wait { closed == 1 && closeWrite.calls == 1 && b.pendingWork == 0 }, "Accepted save and close did not drain")
        let closedFile = try read(closeURL)
        expect(try closeWrite.outcome == .savedCurrentRevision && closeWrite.heldWork == 1 && gone(b.image)
            && closedFile.name == "Save before close" && closedFile.recordingID == metadataB.recordingID
            && closedFile.records.isEmpty && native(a.image) == beforeLoad, "accepted Save reaches disk before native close and A survives")
        complete = true
    }
}
