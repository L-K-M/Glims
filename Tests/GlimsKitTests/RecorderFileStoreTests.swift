import Darwin
import Foundation
import XCTest
@testable import GlimsKit

final class RecorderFileStoreTests: XCTestCase {
    private var directory: URL!
    private let files = FileManager.default
    private let identifier = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    // Independently authored wire bytes, including unsuccessful inspection rows.
    private let literal = #"{"format":"ch.lkmc.Glims.recording","version":1,"recordingID":"11111111-1111-1111-1111-111111111111","name":"Named","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":[],"records":[{"ordinal":0,"outcome":"success","command":{"tag":"transformImage","transform":"flipHorizontal"},"binding":{"kind":"none"}},{"ordinal":1,"outcome":"failure","reason":"refused"},{"ordinal":2,"outcome":"cancelled","reason":"cancelled"}]}"#
    private let canonical = #"{"format":"ch.lkmc.Glims.recording","name":"Named","origin":{"imageLabel":"A","initialHeight":29,"initialWidth":41},"recordingID":"11111111-1111-1111-1111-111111111111","records":[{"binding":{"kind":"none"},"command":{"tag":"transformImage","transform":"flipHorizontal"},"ordinal":0,"outcome":"success"},{"ordinal":1,"outcome":"failure","reason":"refused"},{"ordinal":2,"outcome":"cancelled","reason":"cancelled"}],"symbols":[],"version":1}"#

    private var candidate: RecorderFileValue {
        .init(recordingID: identifier, name: "Named", origin: .init(imageLabel: "A", initialWidth: 41, initialHeight: 29), symbols: [], records: [
            .init(ordinal: 0, outcome: .success(.transformImage(.flipHorizontal), .none)),
            .init(ordinal: 1, outcome: .failure("refused")),
            .init(ordinal: 2, outcome: .cancelled("cancelled")),
        ])
    }

    override func setUpWithError() throws {
        directory = files.temporaryDirectory.appendingPathComponent("glims-recording-store-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        if let directory { try files.removeItem(at: directory) }
        directory = nil
    }

    private enum TestError: Error, Equatable { case stagedPrecommitException, workerTimedOut }
    private final class WorkerResult<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Result<Value, Error>?
        func set(_ value: Result<Value, Error>) { lock.lock(); defer { lock.unlock() }; self.value = value }
        func get() -> Result<Value, Error> { lock.lock(); defer { lock.unlock() }; return value! }
    }
    /// An async block, rather than DispatchQueue.sync, ensures actual background
    /// execution even when XCTest invokes the test method on the main thread.
    private func background<Value>(_ body: @escaping () throws -> Value) throws -> Value {
        let result = WorkerResult<Value>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            result.set(Result(catching: body)); done.signal()
        }
        guard done.wait(timeout: .now() + 30) == .success else {
            XCTFail("Recording store worker did not finish")
            throw TestError.workerTimedOut
        }
        return try result.get().get()
    }
    private func file(_ name: String = "Named.glimsrecording") -> URL { directory.appendingPathComponent(name, isDirectory: false) }
    private func contents(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    private func entries(_ directory: URL? = nil) throws -> [String] {
        try files.contentsOfDirectory(atPath: (directory ?? self.directory).path).sorted()
    }
    private func information(_ url: URL) throws -> stat {
        var result = stat()
        guard lstat(url.path, &result) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return result
    }

    func testLoadIndependentLiteralReturnsAllDetachedRowsWithoutChangingBytes() throws {
        let url = file("Résumé Recording.glimsrecording"), bytes = Data(literal.utf8)
        try bytes.write(to: url)
        let loaded = try background { try RecorderFileStore.load(from: url) }
        XCTAssertEqual(loaded, candidate)
        XCTAssertEqual(try contents(url), bytes)
        XCTAssertEqual(try entries(), [url.lastPathComponent])
    }

    func testNewSaveHasIndependentCanonicalBytesAndPrivateModeBits() throws {
        let url = file(), value = candidate
        try background { try RecorderFileStore.save(value, to: url) }
        XCTAssertEqual(try contents(url), Data(canonical.utf8))
        XCTAssertEqual(try information(url).st_mode & mode_t(0o777), mode_t(0o600))
        XCTAssertEqual(try background { try RecorderFileStore.load(from: url) }, value)
        XCTAssertEqual(try entries(), [url.lastPathComponent])
    }

    func testReplacementChangesOnlyTheNamedEntryAndPreservesHardLinkAlias() throws {
        let url = file(), alias = file("Other hard link.glimsrecording"), old = Data("previous bytes".utf8), value = candidate
        try old.write(to: url)
        XCTAssertEqual(link(url.path, alias.path), 0)
        let oldIdentity = try information(url)
        try background { try RecorderFileStore.save(value, to: url) }
        XCTAssertEqual(try contents(url), Data(canonical.utf8))
        XCTAssertEqual(try contents(alias), old)
        XCTAssertEqual(try information(alias).st_ino, oldIdentity.st_ino)
        XCTAssertNotEqual(try information(url).st_ino, oldIdentity.st_ino)
        XCTAssertEqual(try entries(), [url.lastPathComponent, alias.lastPathComponent].sorted())
    }

    func testMalformedInputRefusesWithoutMutatingExistingCandidateOrFile() throws {
        let url = file(), original = candidate
        let malformed = Data(literal.replacingOccurrences(of: "\"version\":1", with: "\"version\":2").utf8)
        try malformed.write(to: url)
        XCTAssertThrowsError(try background { try RecorderFileStore.load(from: url) }) {
            XCTAssertTrue($0 is RecorderFileError)
        }
        XCTAssertEqual(candidate, original)
        XCTAssertEqual(try contents(url), malformed)
        XCTAssertEqual(try entries(), [url.lastPathComponent])
    }

    func testExactFileByteLimitLoadsAndOneExtraByteRefusesBeforeDecoding() throws {
        let url = file(), value = candidate
        var bounded = Data(literal.utf8)
        bounded.append(Data(repeating: 32, count: RecorderFileLimits.bytes - bounded.count))
        try bounded.write(to: url)
        XCTAssertEqual(try background { try RecorderFileStore.load(from: url) }, value)
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([32])); try handle.close()
        XCTAssertThrowsError(try background { try RecorderFileStore.load(from: url) }) {
            XCTAssertEqual($0 as? RecorderFileStore.StoreError, .oversized(url.path))
        }
        XCTAssertEqual(try information(url).st_size, off_t(RecorderFileLimits.bytes + 1))
        XCTAssertEqual(try entries(), [url.lastPathComponent])
    }

    func testEmptyRegularFileFailsCodecAndRemainsEmpty() throws {
        let url = file()
        try Data().write(to: url)
        XCTAssertThrowsError(try background { try RecorderFileStore.load(from: url) }) {
            XCTAssertTrue($0 is RecorderFileError)
        }
        XCTAssertEqual(try contents(url), Data())
        XCTAssertEqual(try entries(), [url.lastPathComponent])
    }

    func testFinalSymlinkIsRefusedForReadAndWriteWithoutTouchingItsTarget() throws {
        let target = file("Actual.glimsrecording"), alias = file("Symbolic.glimsrecording"), bytes = Data(literal.utf8), value = candidate
        try bytes.write(to: target)
        try files.createSymbolicLink(at: alias, withDestinationURL: target)
        for operation in [{ try RecorderFileStore.load(from: alias).name }, { try RecorderFileStore.save(value, to: alias); return "" }] {
            XCTAssertThrowsError(try background(operation)) {
                XCTAssertEqual($0 as? RecorderFileStore.StoreError, .notRegularFile(alias.path))
            }
        }
        XCTAssertEqual(try contents(target), bytes)
        XCTAssertEqual(try information(alias).st_mode & mode_t(S_IFMT), mode_t(S_IFLNK))
        XCTAssertEqual(try entries(), [target.lastPathComponent, alias.lastPathComponent].sorted())
    }

    func testDirectoryAndFIFORefuseReadAndWriteWithoutWaitingForStreamData() throws {
        let folder = file("Directory"), fifo = file("Pipe"), value = candidate
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        // A finite fallback also bounds an accidentally regressed stream read.
        // The production refusal must be the explicit regular-file error.
        let keeper = Darwin.open(fifo.path, O_RDWR | O_NONBLOCK | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(keeper, 0)
        let drained = DispatchSemaphore(value: 0), fallback = Data(literal.utf8)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            fallback.withUnsafeBytes { _ = Darwin.write(keeper, $0.baseAddress, $0.count) }
            Darwin.close(keeper); drained.signal()
        }
        defer { XCTAssertEqual(drained.wait(timeout: .now() + 3), .success) }
        for url in [folder, fifo] {
            XCTAssertThrowsError(try background { try RecorderFileStore.load(from: url) }) {
                XCTAssertEqual($0 as? RecorderFileStore.StoreError, .notRegularFile(url.path))
            }
            XCTAssertThrowsError(try background { try RecorderFileStore.save(value, to: url) }) {
                XCTAssertEqual($0 as? RecorderFileStore.StoreError, .notRegularFile(url.path))
            }
        }
        XCTAssertEqual(try information(fifo).st_mode & mode_t(S_IFMT), mode_t(S_IFIFO))
        XCTAssertEqual(try entries(), ["Directory", "Pipe"])
    }

    func testReadOnlyDeviceRefusalUsesTypeGate() throws {
        let null = URL(fileURLWithPath: "/dev/null")
        // Never attempt to replace a real device in a test.
        XCTAssertThrowsError(try background { try RecorderFileStore.load(from: null) }) {
            XCTAssertEqual($0 as? RecorderFileStore.StoreError, .notRegularFile(null.path))
        }
        XCTAssertEqual(try entries(), [])
    }

    func testMissingAndInvalidLocationsDoNotCreateFiles() throws {
        let missing = file(), missingParent = directory.appendingPathComponent("Absent/file.glimsrecording"), value = candidate
        XCTAssertThrowsError(try background { try RecorderFileStore.load(from: missing) }) {
            XCTAssertEqual($0 as? RecorderFileStore.StoreError, .io(operation: "open", path: missing.path, code: ENOENT))
        }
        XCTAssertThrowsError(try background { try RecorderFileStore.save(value, to: missingParent) }) {
            guard let error = $0 as? RecorderFileStore.StoreError, case .io(_, let path, let code) = error else { return XCTFail("Expected parent-open error") }
            XCTAssertEqual(path, missingParent.path); XCTAssertEqual(code, ENOENT)
        }
        let invalid = [URL(string: "https://example.invalid/recording")!, URL(string: "file://remote.invalid/tmp/recording")!,
                       URL(string: "file:///tmp/recording?ignored=yes")!, file("embedded\0name")]
        for url in invalid {
            XCTAssertThrowsError(try background { try RecorderFileStore.load(from: url) }) {
                guard let error = $0 as? RecorderFileStore.StoreError, case .invalidLocation = error else { return XCTFail("Expected local-file validation") }
            }
            XCTAssertThrowsError(try background { try RecorderFileStore.save(value, to: url) }) {
                guard let error = $0 as? RecorderFileStore.StoreError, case .invalidLocation = error else { return XCTFail("Expected local-file validation") }
            }
        }
        XCTAssertEqual(try entries(), [])
    }

    func testInvalidValueRefusesBeforeCreatingTemporaryOrReplacingOldBytes() throws {
        let url = file(), old = Data("older recording".utf8)
        try old.write(to: url)
        let invalid = RecorderFileValue(recordingID: identifier, name: "Invalid", origin: candidate.origin, symbols: [],
            records: [.init(ordinal: 0, outcome: .success(.scale(width: 0, height: 1), .none))])
        XCTAssertThrowsError(try background { try RecorderFileStore.save(invalid, to: url) }) {
            XCTAssertTrue($0 is RecorderFileError)
        }
        XCTAssertEqual(try contents(url), old)
        XCTAssertEqual(try entries(), [url.lastPathComponent])
    }

    func testStagedPrecommitExceptionPreservesOldBytesOrAbsenceAndRemovesTemporary() throws {
        let url = file(), old = Data("previous recording".utf8), value = candidate, expected = Data(canonical.utf8)
        for existing in [true, false] {
            if existing { try old.write(to: url) }
            XCTAssertThrowsError(try background {
                try RecorderFileStore.save(value, to: url, beforeCommit: {
                    let names = try self.entries().filter { $0.hasPrefix(".glimsrecording-") }
                    XCTAssertEqual(names.count, 1)
                    guard names.count == 1 else { throw TestError.stagedPrecommitException }
                    let staged = self.file(names[0])
                    XCTAssertEqual(try self.contents(staged), expected)
                    XCTAssertEqual(try self.information(staged).st_mode & mode_t(0o777), mode_t(0o600))
                    if existing { XCTAssertEqual(try self.contents(url), old) }
                    else { XCTAssertFalse(self.files.fileExists(atPath: url.path)) }
                    throw TestError.stagedPrecommitException
                })
            }) { XCTAssertEqual($0 as? TestError, .stagedPrecommitException) }
            if existing {
                XCTAssertEqual(try contents(url), old)
                XCTAssertEqual(try entries(), [url.lastPathComponent])
                try files.removeItem(at: url)
            } else { XCTAssertEqual(try entries(), []) }
        }
        // This is an actual staged exception, not injected write/fsync failure.
    }

    func testObservedConcurrentReplacementRefusesAndPreservesTheOtherWritersBytes() throws {
        let url = file(), old = Data("old".utf8), external = Data("external replacement".utf8), value = candidate
        try old.write(to: url)
        XCTAssertThrowsError(try background {
            try RecorderFileStore.save(value, to: url, beforeCommit: { try external.write(to: url, options: .atomic) })
        }) { XCTAssertEqual($0 as? RecorderFileStore.StoreError, .changed(url.path)) }
        XCTAssertEqual(try contents(url), external)
        XCTAssertEqual(try entries(), [url.lastPathComponent])
    }

    func testDestinationAppearingOrDisappearingBeforeCommitIsNotOverwritten() throws {
        let url = file(), external = Data("other writer".utf8), value = candidate
        XCTAssertThrowsError(try background {
            try RecorderFileStore.save(value, to: url, beforeCommit: { try external.write(to: url) })
        }) { XCTAssertEqual($0 as? RecorderFileStore.StoreError, .changed(url.path)) }
        XCTAssertEqual(try contents(url), external)
        XCTAssertThrowsError(try background {
            try RecorderFileStore.save(value, to: url, beforeCommit: { try self.files.removeItem(at: url) })
        }) { XCTAssertEqual($0 as? RecorderFileStore.StoreError, .changed(url.path)) }
        XCTAssertEqual(try entries(), [])
    }

    func testPinnedParentFollowsTheCapturedDirectoryAfterItIsRenamed() throws {
        let parent = directory.appendingPathComponent("Parent", isDirectory: true)
        let moved = directory.appendingPathComponent("Moved", isDirectory: true)
        try files.createDirectory(at: parent, withIntermediateDirectories: false)
        let url = parent.appendingPathComponent("Named.glimsrecording"), value = candidate, external = Data("replacement directory".utf8)
        try Data("original".utf8).write(to: url)
        try background {
            try RecorderFileStore.save(value, to: url, beforeCommit: {
                try self.files.moveItem(at: parent, to: moved)
                try self.files.createDirectory(at: parent, withIntermediateDirectories: false)
                try external.write(to: url)
            })
        }
        XCTAssertEqual(try contents(url), external)
        XCTAssertEqual(try contents(moved.appendingPathComponent(url.lastPathComponent)), Data(canonical.utf8))
        XCTAssertEqual(try entries(moved), [url.lastPathComponent])
        XCTAssertEqual(try entries(parent), [url.lastPathComponent])
    }

    func testCleanupDoesNotDeleteAnAlienReplacementAtTheTemporaryName() throws {
        let url = file(), old = Data("old".utf8), alien = Data("not the staged inode".utf8), value = candidate
        try old.write(to: url)
        XCTAssertThrowsError(try background {
            try RecorderFileStore.save(value, to: url, beforeCommit: {
                let names = try self.entries().filter { $0.hasPrefix(".glimsrecording-") }
                XCTAssertEqual(names.count, 1)
                guard names.count == 1 else { throw TestError.stagedPrecommitException }
                let temporary = self.file(names[0])
                try alien.write(to: temporary, options: .atomic)
            })
        }) { XCTAssertEqual($0 as? RecorderFileStore.StoreError, .changed(url.path)) }
        XCTAssertEqual(try contents(url), old)
        let remaining = try entries().filter { $0.hasPrefix(".glimsrecording-") }
        XCTAssertEqual(remaining.count, 1)
        if let name = remaining.first { XCTAssertEqual(try contents(file(name)), alien) }
    }

    func testMainThreadRefusesBeforeAnyFileIO() throws {
        let url = file(), value = candidate, old = Data("untouched".utf8)
        try old.write(to: url)
        let check = {
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertThrowsError(try RecorderFileStore.load(from: url)) {
                XCTAssertEqual($0 as? RecorderFileStore.StoreError, .backgroundRequired)
            }
            XCTAssertThrowsError(try RecorderFileStore.save(value, to: url)) {
                XCTAssertEqual($0 as? RecorderFileStore.StoreError, .backgroundRequired)
            }
        }
        if Thread.isMainThread { try check() } else { try DispatchQueue.main.sync(execute: check) }
        XCTAssertEqual(try contents(url), old)
        XCTAssertEqual(try entries(), [url.lastPathComponent])
    }
}
