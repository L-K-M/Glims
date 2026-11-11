import AppKit
import Darwin

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderActiveSave(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        typealias Checkpoint = ImageDocument.RecorderInstallCheckpoint
        typealias Refusal = ImageDocument.RecorderInstallError
        typealias Outcome = ImageDocument.RecorderSaveOutcome

        struct NativeState: Equatable {
            let info: EngineSession.ImageInfo
            let pixels: Data
            let history: EngineSession.History
        }

        final class SaveResult {
            var results: [Result<Outcome, Error>] = []
            var workCounts: [Int] = []

            var outcome: Outcome? { results.first.flatMap { try? $0.get() } }
            var error: Error? {
                if case .failure(let error)? = results.first { return error }
                return nil
            }
        }

        let directory = work.appendingPathComponent("recorder-active-save-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var document: ImageDocument?
        var ownedImage: Int32?
        let release = DispatchSemaphore(value: 0)
        var checks = 0
        var complete = false

        func expect(_ value: Bool, _ message: String) {
            checks += 1
            check(value, "active recorder save: \(message)")
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "RecorderActiveSaveFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let limit = Date().addingTimeInterval(20)
            while !condition() && Date() < limit { spin(0.005) }
            return condition()
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        defer {
            release.signal()
            if let document {
                document.closeImageWhenDrained()
                expect(wait { document.pendingWork == 0 && gone(document.image) }, "the owning image closes after accepted work drains")
                documents.items.removeAll { $0 === document }
            }
            if let ownedImage { try? session.closeImage(ownedImage) }
            try? FileManager.default.removeItem(at: directory)
            expect((ownedImage.map(gone) ?? true) && !FileManager.default.fileExists(atPath: directory.path), "temporary image and files are removed")
            expect(complete, "all active snapshot scenarios completed")
            print("     recorder-active-save checks: \(checks)")
        }

        var pixels: [UInt8] = []
        for y in 0..<5 {
            for x in 0..<8 {
                pixels.append(contentsOf: [UInt8(x * 19), UInt8(y * 37), UInt8(x + y * 11), 255])
            }
        }
        let image = try session.newImage(pixels: ClipboardImage(width: 8, height: 5, pixels: Data(pixels), origin: .zero))
        ownedImage = image
        let a = try ImageDocument(session: session, image: image, name: "Active A")
        document = a
        ownedImage = nil
        documents.items.append(a)

        func native() throws -> NativeState {
            let info = try session.info(image)
            let raster = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: info.width, height: info.height))
            guard let pixels = raster.dataProvider?.data as Data? else { throw ImageDocument.DocumentError.targetChanged }
            return NativeState(info: info, pixels: pixels, history: try session.history(image))
        }
        func drain(_ result: SaveResult? = nil) throws {
            try require(wait { a.pendingWork == 0 && a.recorder.pendingCount == 0 && !EngineActivity.shared.isBusy },
                        "Accepted active recording work did not drain")
            if let result { try require(result.results.count == 1, "Expected exactly one save completion") }
        }
        func url(_ name: String) -> URL { directory.appendingPathComponent(name + ".glimsrecording") }
        func read(_ url: URL) throws -> RecorderFileValue { try RecorderFileCodec.decode(Data(contentsOf: url)) }
        func save(_ url: URL, _ checkpoint: Checkpoint) -> SaveResult {
            let result = SaveResult()
            a.saveRecording(to: url, checkpoint: checkpoint, allowActiveRecording: true) { outcome in
                result.workCounts.append(a.pendingWork)
                result.results.append(outcome)
            }
            return result
        }
        func refusal(_ checkpoint: () throws -> Checkpoint) -> Refusal? {
            do { _ = try checkpoint(); return nil }
            catch { return error as? Refusal }
        }

        try drain()
        try a.startRecording()
        let origin = a.recorderFileMetadata
        let initial = a.recorderContentCheckpoint()
        let entered = DispatchSemaphore(value: 0)
        a.inputQueue.async { entered.signal(); _ = release.wait(timeout: .now() + 20) }
        try require(entered.wait(timeout: .now() + 3) == .success, "Input hold did not start")
        a.transformImage(.rotate90)
        let pending = a.recorderContentCheckpoint()
        let pendingURL = url("Pending")
        let pendingSave = save(pendingURL, pending)
        expect(a.recorder.isRecording && a.recorder.pendingCount == 1 && pending != initial && a.hasUnsavedRecordingChanges,
               "content checkpoint is readable during a pending accepted capture")
        expect(refusal { try a.recorderSaveCheckpoint(allowActiveRecording: true) } == .unsettled
            && pendingSave.error as? Refusal == .unsettled && pendingSave.workCounts == [1]
            && !FileManager.default.fileExists(atPath: pendingURL.path), "active Save refuses pending captures without adding work or writing")
        release.signal()
        try drain()
        expect(a.recorderContentCheckpoint() != pending && a.recorder.isRecording && a.recorder.records.count == 1,
               "settlement changes content revision and preserves the active recording")

        let ordinaryURL = url("Ordinary Save")
        let ordinary = SaveResult()
        a.saveRecording(to: ordinaryURL, checkpoint: a.recorderContentCheckpoint()) { ordinary.results.append($0) }
        expect(refusal { try a.recorderSaveCheckpoint() } == .unsettled
            && refusal { try a.recorderInstallCheckpoint() } == .unsettled
            && ordinary.error as? Refusal == .unsettled && ordinary.results.count == 1
            && a.pendingWork == 0 && !FileManager.default.fileExists(atPath: ordinaryURL.path), "ordinary Save and install remain stopped-only")

        a.scale(toWidth: 0, height: 5)
        try drain()
        guard a.recorder.records.count == 2, case .failure(let reason) = a.recorder.records[1].resolution else {
            throw NSError(domain: "RecorderActiveSaveFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected one failed native scale capture"])
        }
        let expected: [RecorderFileValue.Record] = [
            .init(ordinal: 0, outcome: .success(.transformImage(.rotate90), .none)),
            .init(ordinal: 1, outcome: .failure(reason)),
        ]
        let beforeSave = try native()
        let settled = try a.recorderSaveCheckpoint(allowActiveRecording: true)
        let missingParent = directory.appendingPathComponent("missing/active.glimsrecording")
        let failed = save(missingParent, settled)
        try drain(failed)
        expect(failed.error as? RecorderFileStore.StoreError == .io(operation: "open parent of", path: missingParent.path, code: ENOENT)
            && failed.workCounts == [1], "store failure completes once while holding the owner")
        expect(try a.recorderContentCheckpoint() == settled && a.recorder.isRecording && a.recorder.records.count == 2
            && a.recorderFileMetadata == origin && a.hasUnsavedRecordingChanges && native() == beforeSave,
               "failed save preserves active phase, revision, log, image and dirty recording")

        let currentURL = url("Different filename")
        let saved = save(currentURL, settled)
        expect(saved.results.isEmpty && a.pendingWork == 1 && a.recorder.isRecording,
               "admitted active snapshot adds counted work and does not pause recording")
        try drain(saved)
        let file = try read(currentURL)
        expect(file.records == expected && file.name == "Active A Recording" && file.recordingID == origin.recordingID
            && file.origin == .init(imageLabel: "Active A", initialWidth: 8, initialHeight: 5),
               "detached file preserves exact ordered outcomes, intrinsic name and origin")
        expect(try saved.outcome == .savedCurrentRevision && saved.workCounts == [1] && !a.hasUnsavedRecordingChanges
            && a.recorder.isRecording && a.recorderContentCheckpoint() == settled && native() == beforeSave,
               "exact save marks the current revision clean and leaves active state and native image intact")

        let earlierURL = url("Earlier active revision")
        let earlier = save(earlierURL, settled)
        a.transformImage(.flipHorizontal)
        expect(a.recorder.isRecording && a.recorder.pendingCount == 1 && a.recorderContentCheckpoint() != settled,
               "the same active recording immediately accepts another command during a save")
        try drain(earlier)
        expect(try earlier.outcome == .savedEarlierRevision && earlier.workCounts.first.map { $0 >= 1 } == true
            && read(earlierURL) == file && a.hasUnsavedRecordingChanges && a.recorder.records.map(\.ordinal) == [0, 1, 2]
            && a.recorderFileMetadata == origin && native().pixels != beforeSave.pixels,
               "earlier save contains only its admitted snapshot and the live epoch continues at the next ordinal")

        let staleURL = url("Stale")
        let stale = save(staleURL, settled)
        expect(stale.error as? Refusal == .staleRecording && stale.workCounts == [0]
            && !FileManager.default.fileExists(atPath: staleURL.path), "a stale active checkpoint refuses before writing")

        let latest = save(currentURL, try a.recorderSaveCheckpoint(allowActiveRecording: true))
        try drain(latest)
        expect(try latest.outcome == .savedCurrentRevision && read(currentURL).records == expected + [
            .init(ordinal: 2, outcome: .success(.transformImage(.flipHorizontal), .none)),
        ] && a.recorder.isRecording && !a.hasUnsavedRecordingChanges,
               "saving again atomically replaces the file with the new command and keeps recording active")

        let latestFile = try read(currentURL)
        let closingURL = url("Accepted before close")
        let closing = save(closingURL, try a.recorderSaveCheckpoint(allowActiveRecording: true))
        a.closeImageWhenDrained()
        expect(a.isClosing && a.pendingWork == 1 && closing.results.isEmpty && !gone(image),
               "an accepted snapshot holds its image through a close request")
        try drain(closing)
        expect(try closing.outcome == .savedCurrentRevision && closing.workCounts == [1]
            && read(closingURL) == latestFile && wait { gone(image) },
               "the saved file and counted completion survive the owning image's close drain")
        complete = true
    }
}
