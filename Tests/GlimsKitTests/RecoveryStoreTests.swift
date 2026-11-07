import XCTest
@testable import GlimsKit

/// The on-disk recovery store: private folders and manifests, atomic
/// temp-then-rename writes, strict manifest validation, dead-run
/// discovery and stale-file sweeping. Everything runs in a unique
/// temporary folder per test.
@MainActor
final class RecoveryStoreTests: XCTestCase {
    private var base: URL!
    private let files = FileManager.default

    override func setUp() {
        base = files.temporaryDirectory
            .appendingPathComponent("glims-recovery-tests-\(UUID().uuidString)", isDirectory: true)
        try? files.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? files.removeItem(at: base)
        base = nil
    }

    private func permissions(_ url: URL) -> Int {
        (try? files.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int) ?? -1
    }

    /// A record payload for hand-writing manifests.
    private func metadata(name: String = "Drawing", native: String? = nil,
                          imported: String? = nil, revision: UInt64? = 3) -> RecoveryStore.Metadata {
        RecoveryStore.Metadata(name: name,
                               nativeURL: native.map { URL(fileURLWithPath: $0) },
                               importedSourceURL: imported.map { URL(fileURLWithPath: $0) },
                               revision: revision)
    }

    /// Writes a committed copy+manifest through the store's own path.
    @discardableResult
    private func commit(_ store: RecoveryStore, id: UUID, content: String,
                        metadata: RecoveryStore.Metadata) throws -> RecoveryStore.Record {
        let temp = store.temporaryCopyURL(for: id)
        try Data(content.utf8).write(to: temp)
        return try store.commitCopy(at: temp, for: id, metadata: metadata)
    }

    /// Writes `run.json` into a run folder belonging to another run.
    private func writeRun(_ runID: UUID, pid: Int32) throws -> URL {
        let dir = base.appendingPathComponent(runID.uuidString, isDirectory: true)
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        let run = RecoveryStore.Run(runID: runID, pid: pid, started: Date())
        try JSONEncoder().encode(run).write(to: dir.appendingPathComponent(RecoveryStore.runFilename))
        return dir
    }

    /// Writes a manifest (already encoded JSON) and an optional copy
    /// file directly into a run folder, bypassing the store's writes.
    private func writeRawManifest(_ json: String, copy: Data?, named name: String, in dir: URL) throws {
        try json.write(to: dir.appendingPathComponent(name), atomically: false, encoding: .utf8)
        if let copy {
            let id = name.replacingOccurrences(of: ".json", with: "")
            try copy.write(to: dir.appendingPathComponent("\(id).xcf"))
        }
    }

    private func manifestJSON(id: UUID, name: String = "Drawing", copyFilename: String? = nil,
                              schemaVersion: Int = 1, native: String? = nil, revision: Int = 3) -> String {
        let filename = copyFilename ?? "\(id.uuidString).xcf"
        let nativeField = native.map { "\"\($0)\"" } ?? "null"
        return """
        {"schemaVersion":\(schemaVersion),"documentID":"\(id.uuidString)","name":"\(name)",\
        "nativeURL":\(nativeField),"importedSourceURL":null,"copyFilename":"\(filename)",\
        "date":700000000.0,"revision":\(revision)}
        """
    }

    func testFoldersAndFilesArePrivate() throws {
        let store = RecoveryStore(base: base, runID: UUID())
        try store.prepare()
        XCTAssertEqual(permissions(base), 0o700)
        XCTAssertEqual(permissions(store.runDirectory), 0o700)
        XCTAssertEqual(permissions(store.runDirectory.appendingPathComponent(RecoveryStore.runFilename)), 0o600)

        let id = UUID()
        try commit(store, id: id, content: "xcf-v1", metadata: metadata())
        XCTAssertEqual(permissions(store.copyURL(for: id)), 0o600)
        XCTAssertEqual(permissions(store.runDirectory.appendingPathComponent("\(id.uuidString).json")), 0o600)
    }

    func testCommitRecordsIdentityAndReplacesTheSameDocumentsCopy() throws {
        let store = RecoveryStore(base: base, runID: UUID())
        try store.prepare()
        let id = UUID()
        let first = try commit(store, id: id, content: "v1", metadata: metadata(revision: 4))
        XCTAssertEqual(first.documentID, id)
        XCTAssertTrue(first.copyFilename.hasPrefix("\(id.uuidString)."))
        XCTAssertTrue(first.copyFilename.hasSuffix(".xcf"))
        XCTAssertEqual(first.revision, 4)
        XCTAssertEqual(String(data: try Data(contentsOf: store.copyURL(for: id)), encoding: .utf8), "v1")

        let second = try commit(store, id: id, content: "v2-longer", metadata: metadata(revision: 9))
        XCTAssertEqual(second.revision, 9)
        XCTAssertNotEqual(first.copyFilename, second.copyFilename)
        XCTAssertFalse(files.fileExists(atPath: store.runDirectory.appendingPathComponent(first.copyFilename).path))
        XCTAssertEqual(String(data: try Data(contentsOf: store.copyURL(for: id)), encoding: .utf8), "v2-longer")
        // One copy and one manifest per document, replaced not appended.
        let names = try files.contentsOfDirectory(at: store.runDirectory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        XCTAssertEqual(names.filter { $0.contains(id.uuidString) }.sorted(),
                       ["\(id.uuidString).json", second.copyFilename].sorted())
    }

    /// A failed copy keeps the last committed copy and its manifest —
    /// the recoverable state never gets worse.
    func testAFailedCommitKeepsTheEarlierCopyAndRecord() throws {
        let store = RecoveryStore(base: base, runID: UUID())
        try store.prepare()
        let id = UUID()
        try commit(store, id: id, content: "v1", metadata: metadata(revision: 4))

        // The engine wrote nothing this round: no temp exists to commit.
        let missingTemp = store.temporaryCopyURL(for: id)
        XCTAssertThrowsError(try store.commitCopy(at: missingTemp, for: id, metadata: metadata(revision: 9)))
        XCTAssertEqual(String(data: try Data(contentsOf: store.copyURL(for: id)), encoding: .utf8), "v1")
        XCTAssertEqual(store.record(for: id)?.revision, 4)

        // A temp abandoned mid-write is discarded without touching the
        // committed pair.
        let abandoned = store.temporaryCopyURL(for: id)
        try Data("partial".utf8).write(to: abandoned)
        store.discardTemporary(abandoned)
        XCTAssertFalse(files.fileExists(atPath: abandoned.path))
        XCTAssertEqual(String(data: try Data(contentsOf: store.copyURL(for: id)), encoding: .utf8), "v1")
        XCTAssertEqual(store.record(for: id)?.revision, 4)
    }

    func testManifestFailureKeepsThePreviousCopyAndMetadataTogether() throws {
        let failingFiles = FailingManifestFiles()
        let store = RecoveryStore(base: base, runID: UUID(), fileManager: failingFiles)
        try store.prepare()
        let id = UUID()
        let first = try commit(store, id: id, content: "earlier pixels", metadata: metadata(revision: 4))
        failingFiles.failManifest = true
        XCTAssertThrowsError(try commit(store, id: id, content: "newer pixels", metadata: metadata(revision: 9)))
        XCTAssertEqual(store.record(for: id), first)
        XCTAssertEqual(try Data(contentsOf: store.copyURL(for: id)), Data("earlier pixels".utf8))
    }

    /// Decoding must never turn manifest text into paths: traversal and
    /// wrong names are refused record by record.
    func testManifestValidationRefusesTraversalAndSchemaViolations() throws {
        let deadRun = UUID()
        let dir = try writeRun(deadRun, pid: 4242)

        let traversal = UUID()
        try writeRawManifest(manifestJSON(id: traversal, copyFilename: "../escape.xcf"),
                             copy: Data("x".utf8), named: "\(traversal.uuidString).json", in: dir)
        let absolute = UUID()
        try writeRawManifest(manifestJSON(id: absolute, copyFilename: "/tmp/escape.xcf"),
                             copy: Data("x".utf8), named: "\(absolute.uuidString).json", in: dir)
        let mismatch = UUID()
        try writeRawManifest(manifestJSON(id: UUID()),
                             copy: Data("x".utf8), named: "\(mismatch.uuidString).json", in: dir)
        let wrongSchema = UUID()
        try writeRawManifest(manifestJSON(id: wrongSchema, schemaVersion: 99),
                             copy: Data("x".utf8), named: "\(wrongSchema.uuidString).json", in: dir)
        let nonFileURL = UUID()
        try writeRawManifest(manifestJSON(id: nonFileURL, native: "https://example.com/x.xcf"),
                             copy: Data("x".utf8), named: "\(nonFileURL.uuidString).json", in: dir)
        let noCopy = UUID()
        try writeRawManifest(manifestJSON(id: noCopy),
                             copy: nil, named: "\(noCopy.uuidString).json", in: dir)
        let good = UUID()
        try writeRawManifest(manifestJSON(id: good, name: "Kept", native: "file:///tmp/kept.xcf", revision: 7),
                             copy: Data("x".utf8), named: "\(good.uuidString).json", in: dir)

        let store = RecoveryStore(base: base, runID: UUID(),
                                  processIsAlive: { $0 == ProcessInfo.processInfo.processIdentifier })
        try store.prepare()
        let found = store.discoverRecoverableDocuments()
        XCTAssertEqual(found.map(\.documentID), [good])
        let record = try XCTUnwrap(found.first)
        XCTAssertEqual(record.runID, deadRun)
        XCTAssertEqual(record.name, "Kept")
        XCTAssertEqual(record.nativeURL, URL(fileURLWithPath: "/tmp/kept.xcf"))
        XCTAssertEqual(record.copyURL.resolvingSymlinksInPath().path,
                       dir.resolvingSymlinksInPath().appendingPathComponent("\(good.uuidString).xcf").path)
        XCTAssertTrue(record.copyURL.resolvingSymlinksInPath().path
            .hasPrefix(dir.resolvingSymlinksInPath().path))
    }

    func testDiscoverySkipsLiveOwnersAndTheCurrentRun() throws {
        let liveRun = UUID()
        let liveDir = try writeRun(liveRun, pid: 4242)
        let liveDoc = UUID()
        try writeRawManifest(manifestJSON(id: liveDoc, name: "Live"),
                             copy: Data("x".utf8), named: "\(liveDoc.uuidString).json", in: liveDir)

        let deadRun = UUID()
        let deadDir = try writeRun(deadRun, pid: 7777)
        let deadDoc = UUID()
        try writeRawManifest(manifestJSON(id: deadDoc, name: "Dead"),
                             copy: Data("x".utf8), named: "\(deadDoc.uuidString).json", in: deadDir)

        let ownRun = UUID()
        let store = RecoveryStore(base: base, runID: ownRun,
                                  processIsAlive: { $0 == 4242 })
        try store.prepare()
        let ownDoc = UUID()
        try commit(store, id: ownDoc, content: "x", metadata: metadata())

        let found = store.discoverRecoverableDocuments()
        XCTAssertEqual(found.map(\.name), ["Dead"])
        XCTAssertEqual(found.first?.documentID, deadDoc)
    }

    /// Orphan temporaries and content-free folders of provably dead
    /// runs are swept; live or unknown-owner folders are untouched.
    func testSweepCleansStaleFilesOnlyForDeadOrOwnRuns() throws {
        let deadRun = UUID()
        let deadDir = try writeRun(deadRun, pid: 7777)
        let deadDoc = UUID()
        try writeRawManifest(manifestJSON(id: deadDoc), copy: Data("x".utf8),
                             named: "\(deadDoc.uuidString).json", in: deadDir)
        try Data("t".utf8).write(to: deadDir.appendingPathComponent(".\(deadDoc.uuidString).tmp-abc.xcf"))

        let liveRun = UUID()
        let liveDir = try writeRun(liveRun, pid: 4242)
        let liveTemp = liveDir.appendingPathComponent(".\(UUID().uuidString).tmp-def.xcf")
        try Data("t".utf8).write(to: liveTemp)

        let emptyRun = UUID()
        _ = try writeRun(emptyRun, pid: 8888)
        let emptyDir = base.appendingPathComponent(emptyRun.uuidString)

        let unownedRun = UUID()
        let unownedDir = base.appendingPathComponent(unownedRun.uuidString)
        try files.createDirectory(at: unownedDir, withIntermediateDirectories: true)
        let unownedTemp = unownedDir.appendingPathComponent(".\(UUID().uuidString).tmp-ghi.xcf")
        try Data("t".utf8).write(to: unownedTemp)

        let store = RecoveryStore(base: base, runID: UUID(),
                                  processIsAlive: { $0 == 4242 })
        try store.prepare()

        XCTAssertFalse(files.fileExists(atPath: deadDir.appendingPathComponent(".\(deadDoc.uuidString).tmp-abc.xcf").path),
                       "a dead run's temp is swept")
        XCTAssertTrue(files.fileExists(atPath: deadDir.appendingPathComponent("\(deadDoc.uuidString).json").path),
                      "a dead run's record remains")
        XCTAssertTrue(files.fileExists(atPath: liveTemp.path),
                      "a live run's temp is never touched")
        XCTAssertFalse(files.fileExists(atPath: emptyDir.path),
                       "a dead run folder without records is removed")
        XCTAssertTrue(files.fileExists(atPath: unownedTemp.path),
                      "a folder whose owner cannot be read is left alone")
    }

    /// Closing a tracked document deletes its record, copy and temps —
    /// other documents' files are untouched.
    func testDiscardRemovesOnlyThatDocumentsFiles() throws {
        let store = RecoveryStore(base: base, runID: UUID())
        try store.prepare()
        let closed = UUID()
        let open = UUID()
        try commit(store, id: closed, content: "v1", metadata: metadata())
        try commit(store, id: open, content: "v1", metadata: metadata())
        try Data("t".utf8).write(to: store.temporaryCopyURL(for: closed))

        store.discard(closed)
        XCTAssertNil(store.record(for: closed))
        XCTAssertFalse(files.fileExists(atPath: store.copyURL(for: closed).path))
        let remaining = try files.contentsOfDirectory(at: store.runDirectory, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)
        XCTAssertFalse(remaining.contains { $0.contains(closed.uuidString) })
        XCTAssertNotNil(store.record(for: open))
        XCTAssertTrue(files.fileExists(atPath: store.copyURL(for: open).path))
    }

    func testSourceFilesAreNeverRemovedByTheStore() throws {
        let source = base.appendingPathComponent("original.png")
        try Data("png".utf8).write(to: source)
        let store = RecoveryStore(base: base, runID: UUID())
        try store.prepare()
        let id = UUID()
        try commit(store, id: id, content: "v1", metadata: metadata(imported: source.path))
        store.discard(id)
        XCTAssertTrue(files.fileExists(atPath: source.path),
                      "discarding a record never touches the document's source")
    }

    func testReadRecordRejectsAMissingManifest() throws {
        let store = RecoveryStore(base: base, runID: UUID())
        try store.prepare()
        XCTAssertNil(store.record(for: UUID()))
        XCTAssertFalse(store.copyExists(for: UUID()))
    }

    /// A prior run's generations are discoverable by the copy name the
    /// manifest records, and a replaced generation is not resurrected.
    func testDiscoveryReturnsTheCommittedGenerationFromAPriorRun() throws {
        let prior = RecoveryStore(base: base, runID: UUID(), ownerPID: 4242,
                                  processIsAlive: { _ in false })
        try prior.prepare()
        let id = UUID()
        let first = try commit(prior, id: id, content: "v1", metadata: metadata(name: "Gen"))
        let newer = try commit(prior, id: id, content: "v2", metadata: metadata(name: "Gen", revision: 5))
        XCTAssertNotEqual(first.copyFilename, newer.copyFilename)

        let store = RecoveryStore(base: base, runID: UUID(),
                                  processIsAlive: { $0 == ProcessInfo.processInfo.processIdentifier })
        try store.prepare()
        let found = try XCTUnwrap(store.discoverRecoverableDocuments().first)
        XCTAssertEqual(found.documentID, id)
        XCTAssertEqual(found.copyURL.lastPathComponent, newer.copyFilename)
        XCTAssertEqual(found.revision, 5)
        XCTAssertTrue(files.fileExists(atPath: found.copyURL.path))
        XCTAssertFalse(files.fileExists(atPath: prior.runDirectory.appendingPathComponent(first.copyFilename).path),
                       "the superseded generation is not offered")
    }

    /// A recoverable candidate is re-read from disk every time: a stale
    /// row — changed name, date or copy — is refused instead of opened.
    func testRecoverableDocumentRevalidatesTheCandidate() throws {
        let prior = RecoveryStore(base: base, runID: UUID(), ownerPID: 4242,
                                  processIsAlive: { _ in false })
        try prior.prepare()
        let id = UUID()
        try commit(prior, id: id, content: "v1", metadata: metadata(name: "Kept", native: "/tmp/kept.xcf"))

        let store = RecoveryStore(base: base, runID: UUID(), processIsAlive: { _ in false })
        try store.prepare()
        let candidate = try XCTUnwrap(store.discoverRecoverableDocuments().first)
        XCTAssertEqual(store.recoverableDocument(matching: candidate)?.documentID, id)

        var stale = candidate
        stale.name = "Renamed"
        XCTAssertNil(store.recoverableDocument(matching: stale))
        stale = candidate
        stale.date = candidate.date.addingTimeInterval(60)
        XCTAssertNil(store.recoverableDocument(matching: stale))
        stale = candidate
        stale.copyURL = candidate.copyURL.deletingLastPathComponent().appendingPathComponent("other.xcf")
        XCTAssertNil(store.recoverableDocument(matching: stale))
        stale = candidate
        stale.runID = store.runID
        XCTAssertNil(store.recoverableDocument(matching: stale), "this run's records are never recoverable")
        try files.removeItem(at: candidate.copyURL)
        XCTAssertNil(store.recoverableDocument(matching: candidate),
                     "a deleted copy cannot be recovered")
    }

    /// Discarding a prior record removes its manifest, its copy and its
    /// leftover temporaries — never the document's own source file.
    func testDiscardRecoverableRemovesTheRecordAndCopyOnly() throws {
        let outside = files.temporaryDirectory
            .appendingPathComponent("glims-recovery-source-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: outside) }
        let source = outside.appendingPathComponent("photo.png")
        try Data("png".utf8).write(to: source)

        let prior = RecoveryStore(base: base, runID: UUID(), ownerPID: 4242,
                                  processIsAlive: { _ in false })
        try prior.prepare()
        let id = UUID()
        try commit(prior, id: id, content: "v1", metadata: metadata(imported: source.path))
        let runDir = prior.runDirectory
        try Data("t".utf8).write(to: runDir.appendingPathComponent(".\(id.uuidString).tmp-zzz.xcf"))

        let store = RecoveryStore(base: base, runID: UUID(), processIsAlive: { _ in false })
        try store.prepare()
        let candidate = try XCTUnwrap(store.discoverRecoverableDocuments().first { $0.documentID == id })

        try store.discardRecoverable(candidate)
        XCTAssertTrue(store.discoverRecoverableDocuments().isEmpty)
        XCTAssertFalse(files.fileExists(atPath: runDir.path),
                       "a run folder emptied of records is pruned")
        XCTAssertEqual(try? String(contentsOf: source, encoding: .utf8), "png",
                       "the source file is never a deletion target")
    }

    /// Live, unverifiable and current runs are refused wholesale: a
    /// candidate can never delete a foreign or live run's files, and
    /// nothing is removed outside the store.
    func testDiscardRecoverableRefusesLiveUnverifiableAndCurrentRuns() throws {
        let liveRun = UUID()
        let liveDir = try writeRun(liveRun, pid: 4242)
        let liveDoc = UUID()
        try writeRawManifest(manifestJSON(id: liveDoc, name: "Live"), copy: Data("x".utf8),
                             named: "\(liveDoc.uuidString).json", in: liveDir)

        let unmarkedRun = UUID()
        let unmarkedDir = base.appendingPathComponent(unmarkedRun.uuidString, isDirectory: true)
        try files.createDirectory(at: unmarkedDir, withIntermediateDirectories: true)
        let unmarkedDoc = UUID()
        try writeRawManifest(manifestJSON(id: unmarkedDoc, name: "Unmarked"), copy: Data("x".utf8),
                             named: "\(unmarkedDoc.uuidString).json", in: unmarkedDir)

        let store = RecoveryStore(base: base, runID: UUID(),
                                  processIsAlive: { $0 == 4242 })
        try store.prepare()
        let ownDoc = UUID()
        try commit(store, id: ownDoc, content: "x", metadata: metadata())

        func candidate(_ runID: UUID, _ docID: UUID, _ name: String) -> RecoveryStore.RecoveredDocument {
            RecoveryStore.RecoveredDocument(runID: runID, documentID: docID, name: name,
                                            nativeURL: nil, importedSourceURL: nil,
                                            copyURL: base.appendingPathComponent(runID.uuidString)
                                                .appendingPathComponent("\(docID.uuidString).xcf"),
                                            date: Date(timeIntervalSinceReferenceDate: 700000000),
                                            revision: 3)
        }
        for (runID, docID, name) in [(liveRun, liveDoc, "Live"),
                                     (unmarkedRun, unmarkedDoc, "Unmarked"),
                                     (store.runID, ownDoc, "Fake")] {
            XCTAssertThrowsError(try store.discardRecoverable(candidate(runID, docID, name))) {
                guard case RecoveryStore.StoreError.runUnavailable = $0 else {
                    return XCTFail("expected runUnavailable, got \($0)")
                }
            }
        }
        XCTAssertTrue(files.fileExists(atPath: liveDir.appendingPathComponent("\(liveDoc.uuidString).json").path))
        XCTAssertTrue(files.fileExists(atPath: liveDir.appendingPathComponent("\(liveDoc.uuidString).xcf").path))
        XCTAssertTrue(files.fileExists(atPath: unmarkedDir.appendingPathComponent("\(unmarkedDoc.uuidString).xcf").path))
        XCTAssertNotNil(store.record(for: ownDoc))
    }

    /// A stale row can never delete a changed record: the manifest is
    /// re-validated field by field before anything is removed.
    func testDiscardRecoverableRefusesChangedOrVanishedRecords() throws {
        let prior = RecoveryStore(base: base, runID: UUID(), ownerPID: 4242,
                                  processIsAlive: { _ in false })
        try prior.prepare()
        let id = UUID()
        try commit(prior, id: id, content: "v1", metadata: metadata(name: "First", revision: 3))

        let store = RecoveryStore(base: base, runID: UUID(), processIsAlive: { _ in false })
        try store.prepare()
        let candidate = try XCTUnwrap(store.discoverRecoverableDocuments().first)

        // The record changes under the row the UI was shown.
        try commit(prior, id: id, content: "v2", metadata: metadata(name: "Second", revision: 9))
        XCTAssertThrowsError(try store.discardRecoverable(candidate)) {
            guard case RecoveryStore.StoreError.recordMismatch = $0 else {
                return XCTFail("expected recordMismatch, got \($0)")
            }
        }
        XCTAssertEqual(store.discoverRecoverableDocuments().count, 1,
                       "the changed record was not deleted")

        // A vanished record refuses the same way.
        let gone = try XCTUnwrap(store.discoverRecoverableDocuments().first)
        try files.removeItem(at: prior.runDirectory.appendingPathComponent("\(id.uuidString).json"))
        XCTAssertThrowsError(try store.discardRecoverable(gone)) {
            guard case RecoveryStore.StoreError.recordMismatch = $0 else {
                return XCTFail("expected recordMismatch, got \($0)")
            }
        }
    }
}

final class FailingManifestFiles: FileManager, @unchecked Sendable {
    var failManifest = false
    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if failManifest && path.hasSuffix(".json") && URL(fileURLWithPath: path).lastPathComponent.hasPrefix(".") {
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}
