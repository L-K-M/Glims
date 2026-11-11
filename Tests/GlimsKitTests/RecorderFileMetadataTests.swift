import Foundation
import XCTest
@testable import GlimsKit

final class RecorderFileMetadataTests: XCTestCase {
    private typealias Log = RecorderLog<String>
    private let origin = RecorderFileValue.Origin(imageLabel: "Original image", initialWidth: 41, initialHeight: 29)

    func testDefaultDraftIsCleanAndExplicitNameKeepsItsIdentityAndOrigin() throws {
        var metadata = RecorderFileMetadata(origin: origin)
        let id = metadata.recordingID
        let log = Log()
        XCTAssertEqual(metadata.name, "Original image Recording")
        XCTAssertFalse(metadata.hasUnsavedChanges(in: log, revision: UUID(), savedRevision: nil))
        XCTAssertFalse(try metadata.rename("Original image Recording"))
        XCTAssertTrue(try metadata.rename("Own name"))
        XCTAssertTrue(metadata.hasUnsavedChanges(in: log, revision: UUID(), savedRevision: nil))
        XCTAssertEqual(metadata.recordingID, id)
        XCTAssertEqual(metadata.origin, origin)
        XCTAssertEqual(metadata.name, "Own name")
        XCTAssertNotEqual(RecorderFileMetadata(origin: origin).recordingID, id)
    }

    func testInvalidNamesPreserveDraftAndByteDistinctNamesAreRealEdits() throws {
        var metadata = RecorderFileMetadata(origin: origin)
        let original = metadata
        XCTAssertThrowsError(try metadata.rename(""))
        XCTAssertThrowsError(try metadata.rename(String(repeating: "é", count: RecorderFileLimits.stringBytes / 2 + 1)))
        XCTAssertEqual(metadata, original)
        XCTAssertTrue(try metadata.rename("é"))
        XCTAssertTrue(try metadata.rename("e\u{301}"))
        XCTAssertEqual(Array(metadata.name.utf8), [101, 204, 129])
        XCTAssertFalse(try metadata.rename("e\u{301}"))
    }

    func testPendingAndEachSettledOutcomeCountAsUnsavedContent() throws {
        let metadata = RecorderFileMetadata(origin: origin)
        let oldRevision = UUID()
        let revision = UUID()
        let outcomes: [Log.Resolution] = [.success("edit"), .failure("refused"), .cancelled("")]
        for outcome in outcomes {
            var log = Log()
            try log.startRecording()
            XCTAssertFalse(metadata.hasUnsavedChanges(in: log, revision: revision, savedRevision: oldRevision))
            let pending = try log.reserve()
            try log.stopRecording()
            XCTAssertTrue(metadata.hasUnsavedChanges(in: log, revision: revision, savedRevision: oldRevision))
            try log.resolve(pending, with: outcome)
            XCTAssertEqual(log.pendingCount, 0)
            XCTAssertTrue(metadata.hasUnsavedChanges(in: log, revision: revision, savedRevision: oldRevision))
            XCTAssertFalse(metadata.hasUnsavedChanges(in: log, revision: revision, savedRevision: revision))
        }
    }

    func testNamedLoadedEmptyFileAndItsUnusedDescriptionSurviveSaveAs() throws {
        let symbol = RecorderFileValue.Symbol(id: UUID(), description: .init(name: "Unused alpha", kind: .channel,
            ancestors: [], siblingIndex: 2, bounds: .init(x: -2, y: 4, width: 41, height: 29)))
        let file = RecorderFileValue(recordingID: UUID(), name: "Saved empty", origin: origin, symbols: [symbol], records: [])
        var metadata = RecorderFileMetadata(file: file)
        let revision = UUID()
        let empty = Log()
        XCTAssertFalse(metadata.hasUnsavedChanges(in: empty, revision: revision, savedRevision: revision))
        XCTAssertEqual(metadata.namedCopy(of: file), file)
        XCTAssertTrue(try metadata.rename("Explicit new name"))
        XCTAssertTrue(metadata.hasUnsavedChanges(in: empty, revision: UUID(), savedRevision: revision))
        let named = metadata.namedCopy(of: file)
        XCTAssertEqual(named.name, "Explicit new name")
        XCTAssertEqual(named.recordingID, file.recordingID)
        XCTAssertEqual(named.origin, file.origin)
        XCTAssertEqual(named.symbols, [symbol])
        XCTAssertTrue(named.records.isEmpty)
    }

    func testReplayPresentationKeepsAnExactlySavedRecordingClean() throws {
        let metadata = RecorderFileMetadata(origin: origin)
        let revision = UUID()
        var log = try Log(settledRecords: [.init(ordinal: 0, resolution: .success("command"))])
        try log.beginReplay()
        XCTAssertFalse(metadata.hasUnsavedChanges(in: log, revision: revision, savedRevision: revision))
        let step = try log.nextReplayStep()
        try log.acknowledgeReplay(step.token, outcome: .failure("new native context"))
        XCTAssertFalse(metadata.hasUnsavedChanges(in: log, revision: revision, savedRevision: revision))
    }
}
