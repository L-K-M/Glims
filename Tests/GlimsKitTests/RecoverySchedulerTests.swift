import XCTest
@testable import GlimsKit

/// The periodic pass: which documents get copied, how often, and what
/// happens when they close mid-write. Documents are fakes so the
/// scheduling rules are checked without the engine.
@MainActor
final class RecoverySchedulerTests: XCTestCase {
    private var base: URL!
    private let files = FileManager.default
    private var armed: [(interval: TimeInterval, fire: @MainActor () -> Void)] = []

    override func setUp() {
        base = files.temporaryDirectory
            .appendingPathComponent("glims-recovery-scheduler-\(UUID().uuidString)", isDirectory: true)
        armed = []
    }

    override func tearDown() {
        try? files.removeItem(at: base)
        base = nil
        armed = []
    }

    private struct FakeError: Error {}

    /// A stand-in document: a mutable snapshot plus a copy call that
    /// writes bytes or fails, like `saveCopy` does.
    @MainActor
    private final class FakeDocument: RecoveryCandidate {
        let recoveryID = UUID()
        var recoverySnapshot: RecoverySnapshot
        var copies: [URL] = []
        var nextError: Error?
        var hold = false
        var pending: (@MainActor (Error?) -> Void)?
        var byte: UInt8 = 0

        init(name: String = "Fake", dirty: Bool = true, revision: UInt64? = 1) {
            recoverySnapshot = RecoverySnapshot(name: name, revision: revision,
                                        isDirty: dirty, canAcceptCopy: true)
        }

        func saveRecoveryCopy(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
            copies.append(url)
            if let nextError { self.nextError = nil; return completion(nextError) }
            if hold { pending = completion; return }
            do {
                byte += 1
                try Data([byte]).write(to: url)
                completion(nil)
            } catch {
                completion(error)
            }
        }
    }

    private func makeScheduler(interval: TimeInterval = 120,
                               fileManager: FileManager = .default) throws -> RecoveryScheduler {
        let store = RecoveryStore(base: base, runID: UUID(), fileManager: fileManager)
        try store.prepare()
        let scheduler = RecoveryScheduler(store: store, interval: interval) { [self] interval, fire in
            armed.append((interval, fire))
            return {}
        }
        return scheduler
    }

    private func ready() -> @MainActor () -> Bool { { true } }

    /// Fires the armed tick and lets a pass that copies synchronously
    /// run to its re-arm.
    private func tick() {
        let fire = armed.last?.fire
        armed.removeAll()
        fire?()
    }

    func testDefaultIntervalIsTwoMinutesAndConfigurable() throws {
        let scheduler = try makeScheduler()
        scheduler.start()
        XCTAssertEqual(armed.last?.interval, 120)
        let custom = try makeScheduler(interval: 37)
        custom.start()
        XCTAssertEqual(armed.last?.interval, 37)
    }

    func testADirtyChangedDocumentIsCopiedAndRecorded() throws {
        let scheduler = try makeScheduler()
        let document = FakeDocument(revision: 5)
        scheduler.track(document, isReady: ready())
        scheduler.start()
        tick()
        XCTAssertEqual(document.copies.count, 1)
        let record = try XCTUnwrap(scheduler.store.record(for: document.recoveryID))
        XCTAssertEqual(record.name, "Fake")
        XCTAssertEqual(record.revision, 5)
        XCTAssertTrue(scheduler.store.copyExists(for: document.recoveryID))
        XCTAssertEqual(armed.count, 1, "the pass re-arms after finishing")
    }

    /// While nothing changed, a pass writes nothing; a new revision is
    /// copied over the same names.
    func testUnchangedRevisionSuppressesTheCopy() throws {
        let scheduler = try makeScheduler()
        let document = FakeDocument(revision: 5)
        scheduler.track(document, isReady: ready())
        scheduler.start()
        tick()
        let firstDate = scheduler.store.record(for: document.recoveryID)?.date
        let firstBytes = try Data(contentsOf: scheduler.store.copyURL(for: document.recoveryID))

        tick()
        XCTAssertEqual(document.copies.count, 1, "an unchanged revision is not copied again")
        XCTAssertEqual(scheduler.store.record(for: document.recoveryID)?.date, firstDate)

        document.recoverySnapshot.revision = 6
        tick()
        XCTAssertEqual(document.copies.count, 2)
        XCTAssertEqual(scheduler.store.record(for: document.recoveryID)?.revision, 6)
        XCTAssertNotEqual(try Data(contentsOf: scheduler.store.copyURL(for: document.recoveryID)), firstBytes)
    }

    /// A clean document needs no recovery copy; an imported one counts
    /// as dirty until a native save exists.
    func testOnlyDirtyDocumentsAreCopied() throws {
        let scheduler = try makeScheduler()
        let clean = FakeDocument(dirty: false)
        let imported = FakeDocument()
        imported.recoverySnapshot.importedSourceURL = URL(fileURLWithPath: "/tmp/photo.png")
        scheduler.track(clean, isReady: ready())
        scheduler.track(imported, isReady: ready())
        scheduler.start()
        tick()
        XCTAssertTrue(clean.copies.isEmpty)
        XCTAssertEqual(imported.copies.count, 1)
        XCTAssertEqual(scheduler.store.record(for: imported.recoveryID)?.importedSourceURL,
                       URL(fileURLWithPath: "/tmp/photo.png"))
    }

    /// Pending engine work on a document skips it this pass; it is
    /// picked up once it can accept a copy again.
    func testADocumentThatCannotAcceptACopyIsSkipped() throws {
        let scheduler = try makeScheduler()
        let document = FakeDocument()
        document.recoverySnapshot.canAcceptCopy = false
        scheduler.track(document, isReady: ready())
        scheduler.start()
        tick()
        XCTAssertTrue(document.copies.isEmpty)
        document.recoverySnapshot.canAcceptCopy = true
        tick()
        XCTAssertEqual(document.copies.count, 1)
    }

    /// An open text or field edit anywhere defers every copy: admission
    /// would commit the in-flight input for all documents, never only
    /// the one being copied.
    func testAnyUnreadinessOrStrokeDefersTheWholePass() throws {
        let scheduler = try makeScheduler()
        let editing = FakeDocument()
        let other = FakeDocument()
        var editingReady = false
        scheduler.track(editing, isReady: { editingReady })
        scheduler.track(other, isReady: ready())
        scheduler.start()
        tick()
        XCTAssertTrue(editing.copies.isEmpty && other.copies.isEmpty,
                      "a field edit in one window defers every document's copy")

        editingReady = true
        editing.recoverySnapshot.strokeIsActive = true
        tick()
        XCTAssertTrue(editing.copies.isEmpty && other.copies.isEmpty,
                      "an active stroke in one document defers every copy")

        editing.recoverySnapshot.strokeIsActive = false
        tick()
        XCTAssertEqual(other.copies.count, 1)
        XCTAssertEqual(editing.copies.count, 1)
    }

    /// Every eligible document is copied in one pass, one at a time,
    /// and a failing document neither blocks the others nor loops.
    func testAllEligibleDocumentsAreCopiedAndFailuresRetry() throws {
        let scheduler = try makeScheduler()
        let failing = FakeDocument()
        failing.nextError = FakeError()
        let good = FakeDocument()
        scheduler.track(failing, isReady: ready())
        scheduler.track(good, isReady: ready())
        scheduler.start()
        tick()
        XCTAssertEqual(good.copies.count, 1)
        XCTAssertEqual(failing.copies.count, 1, "the failure was attempted once this pass")
        XCTAssertNil(scheduler.store.record(for: failing.recoveryID))
        XCTAssertNotNil(scheduler.store.record(for: good.recoveryID))

        tick()
        XCTAssertEqual(failing.copies.count, 2)
        XCTAssertNotNil(scheduler.store.record(for: failing.recoveryID),
                       "a failed copy is retried on a later pass")
    }

    /// Closing while its copy is in flight leaves no committed record
    /// behind; the temporary goes too.
    func testACloseDuringTheWriteKeepsNoRecovery() throws {
        let scheduler = try makeScheduler()
        let document = FakeDocument()
        document.hold = true
        scheduler.track(document, isReady: ready())
        scheduler.start()
        tick()
        XCTAssertEqual(scheduler.copying, document.recoveryID)
        let temp = try XCTUnwrap(document.copies.first)
        try Data("partial".utf8).write(to: temp)

        document.recoverySnapshot.isClosing = true
        document.pending?(nil)
        XCTAssertNil(scheduler.copying)
        XCTAssertNil(scheduler.store.record(for: document.recoveryID))
        XCTAssertFalse(files.fileExists(atPath: temp.path),
                       "the abandoned temporary is discarded")
    }

    /// A document that explicitly closes loses its record; another
    /// tracked document's record stays.
    func testUntrackingAClosedDocumentDeletesItsRecord() throws {
        let scheduler = try makeScheduler()
        let closing = FakeDocument()
        let staying = FakeDocument()
        scheduler.track(closing, isReady: ready())
        scheduler.track(staying, isReady: ready())
        scheduler.start()
        tick()
        XCTAssertNotNil(scheduler.store.record(for: closing.recoveryID))

        scheduler.untrack(closing)
        XCTAssertNil(scheduler.store.record(for: closing.recoveryID))
        XCTAssertFalse(scheduler.store.copyExists(for: closing.recoveryID))
        XCTAssertNotNil(scheduler.store.record(for: staying.recoveryID))

        staying.recoverySnapshot.revision = 2
        tick()
        XCTAssertEqual(staying.copies.count, 2)
        XCTAssertEqual(closing.copies.count, 1, "the closed document is never copied again")
    }

    /// Untracking while a write is in flight also discards its
    /// temporary when the write completes.
    func testUntrackingDuringTheWriteCleansUp() throws {
        let scheduler = try makeScheduler()
        let document = FakeDocument()
        document.hold = true
        scheduler.track(document, isReady: ready())
        scheduler.start()
        tick()
        let temp = try XCTUnwrap(document.copies.first)
        try Data("partial".utf8).write(to: temp)

        scheduler.untrack(document)
        document.pending?(nil)
        XCTAssertFalse(files.fileExists(atPath: temp.path))
        XCTAssertNil(scheduler.store.record(for: document.recoveryID))
    }

    /// Stopping while a copy is in flight lets the write and its
    /// finalize finish, then arms nothing further.
    func testStopLetsAnInFlightCopyFinish() throws {
        let scheduler = try makeScheduler()
        let document = FakeDocument()
        document.hold = true
        scheduler.track(document, isReady: ready())
        scheduler.start()
        tick()
        XCTAssertNotNil(scheduler.copying)

        scheduler.stop()
        armed.removeAll()
        try Data("final".utf8).write(to: try XCTUnwrap(document.copies.first))
        document.pending?(nil)
        XCTAssertNil(scheduler.copying)
        XCTAssertNotNil(scheduler.store.record(for: document.recoveryID),
                        "the counted finalize still commits the finished copy")
        XCTAssertTrue(armed.isEmpty, "nothing is scheduled after stop")
    }

    /// Retuning the interval re-arms a pending tick at the new gap; a
    /// stopped scheduler takes the value for its next start without
    /// arming anything.
    func testSetIntervalRearmsTheIdleGap() throws {
        let scheduler = try makeScheduler()
        scheduler.start()
        XCTAssertEqual(armed.last?.interval, 120)
        scheduler.setInterval(60)
        XCTAssertEqual(armed.last?.interval, 60,
                       "an armed tick is re-armed at the new interval")
        scheduler.setInterval(60)
        scheduler.stop()
        armed.removeAll()
        scheduler.setInterval(30)
        XCTAssertTrue(armed.isEmpty, "a stopped scheduler arms nothing")
        scheduler.start()
        XCTAssertEqual(armed.last?.interval, 30)
    }

    /// A retune while a copy is in flight neither cancels the copy nor
    /// arms a second pass; the finished copy still commits and the next
    /// pass uses the new interval.
    func testSetIntervalDuringACopyDoesNotOverlapPasses() throws {
        let scheduler = try makeScheduler()
        let document = FakeDocument()
        document.hold = true
        scheduler.track(document, isReady: ready())
        scheduler.start()
        tick()
        XCTAssertNotNil(scheduler.copying)
        armed.removeAll()
        scheduler.setInterval(45)
        XCTAssertTrue(armed.isEmpty, "a copy in flight is never overlapped by a retune")
        try Data("final".utf8).write(to: try XCTUnwrap(document.copies.first))
        document.pending?(nil)
        XCTAssertNil(scheduler.copying)
        XCTAssertNotNil(scheduler.store.record(for: document.recoveryID),
                        "the in-flight copy still commits after a retune")
        XCTAssertEqual(armed.last?.interval, 45)
    }

    /// A failed write is reported with the document it concerned, so a
    /// missed backup is visible; a document that closed mid-write is
    /// not an error to surface.
    func testFailuresAreReportedPerDocument() throws {
        let scheduler = try makeScheduler()
        var failures: [(UUID, String)] = []
        scheduler.onFailure = { candidate, message in failures.append((candidate.recoveryID, message)) }
        let failing = FakeDocument(name: "Bad")
        failing.nextError = FakeError()
        let good = FakeDocument()
        scheduler.track(failing, isReady: ready())
        scheduler.track(good, isReady: ready())
        scheduler.start()
        tick()
        XCTAssertEqual(failures.map(\.0), [failing.recoveryID])
        XCTAssertTrue(failures[0].1.contains("Bad"))
        XCTAssertEqual(good.copies.count, 1)

        failures.removeAll()
        failing.hold = true
        tick()
        failing.recoverySnapshot.isClosing = true
        failing.pending?(FakeError())
        XCTAssertTrue(failures.isEmpty, "a closing document's aborted copy is not reported")
    }

    /// A commit that fails after the write still reports the failure and
    /// keeps no half-published record.
    func testAFailedCommitIsReported() throws {
        let failingFiles = FailingManifestFiles()
        let scheduler = try makeScheduler(fileManager: failingFiles)
        var failures: [(UUID, String)] = []
        scheduler.onFailure = { candidate, message in failures.append((candidate.recoveryID, message)) }
        let document = FakeDocument(name: "Fragile")
        scheduler.track(document, isReady: ready())
        scheduler.start()
        failingFiles.failManifest = true
        tick()
        XCTAssertEqual(failures.map(\.0), [document.recoveryID])
        XCTAssertTrue(failures[0].1.contains("Fragile"))
        XCTAssertNil(scheduler.store.record(for: document.recoveryID))
    }

    /// `PaletteEditScope.isFieldEditing` detects a live field editor —
    /// the condition the readiness closure checks.
    func testFieldEditingDetection() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 40),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let field = NSTextField(string: "")
        field.isEditable = true
        field.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
        window.contentView?.addSubview(field)
        XCTAssertFalse(PaletteEditScope.isFieldEditing(window))
        window.makeFirstResponder(field)
        XCTAssertTrue(PaletteEditScope.isFieldEditing(window))
        window.makeFirstResponder(nil)
        XCTAssertFalse(PaletteEditScope.isFieldEditing(window))
    }
}
