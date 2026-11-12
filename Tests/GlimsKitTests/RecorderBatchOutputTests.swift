import Darwin
import XCTest
@testable import GlimsKit

final class RecorderBatchOutputTests: XCTestCase {
    private var directory: URL!
    private let files = FileManager.default
    private let original = Data("original input bytes".utf8)
    private let exported = Data("completed export bytes".utf8)

    override func setUpWithError() throws {
        directory = files.temporaryDirectory.appendingPathComponent("glims-batch-output-\(UUID().uuidString)")
        try files.createDirectory(at: directory, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws { try files.removeItem(at: directory) }

    private func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    private func output(source: String = "Photo.png", inputs: [URL]? = nil) throws -> RecorderBatchOutput {
        try RecorderBatchOutput(directory: directory, source: url(source), inputs: inputs ?? [url(source)], extension: "png")
    }
    private func entries() throws -> [String] { try files.contentsOfDirectory(atPath: directory.path).sorted() }

    func testPublishesOnlyCompletedFileAndPreservesSource() throws {
        try original.write(to: url("Photo.png"))
        let stage = try output()
        XCTAssertEqual(try entries().filter { !$0.hasPrefix(".") }, ["Photo.png"])
        var info = stat()
        XCTAssertEqual(lstat(stage.stagingURL.deletingLastPathComponent().path, &info), 0)
        XCTAssertEqual(info.st_mode & mode_t(0o777), mode_t(0o700))
        try exported.write(to: stage.stagingURL)
        let result = try stage.publish()
        XCTAssertEqual(result.url.lastPathComponent, "Photo edited.png")
        XCTAssertNil(result.cleanupWarning)
        XCTAssertEqual(try Data(contentsOf: result.url), exported)
        XCTAssertEqual(try Data(contentsOf: url("Photo.png")), original)
        XCTAssertEqual(try entries(), ["Photo edited.png", "Photo.png"])
        XCTAssertThrowsError(try stage.publish())
        XCTAssertNil(stage.discard())
        XCTAssertEqual(try Data(contentsOf: result.url), exported)
    }

    func testExistingFilesSymlinksAndDirectoriesAreNeverReplaced() throws {
        try original.write(to: url("Photo edited.png"))
        try files.createSymbolicLink(at: url("Photo edited 2.png"), withDestinationURL: url("Photo edited.png"))
        try files.createDirectory(at: url("Photo edited 3.png"), withIntermediateDirectories: false)
        let stage = try output()
        try exported.write(to: stage.stagingURL)
        let result = try stage.publish()
        XCTAssertEqual(result.url.lastPathComponent, "Photo edited 4.png")
        XCTAssertEqual(try Data(contentsOf: url("Photo edited.png")), original)
        XCTAssertEqual(try files.destinationOfSymbolicLink(atPath: url("Photo edited 2.png").path), url("Photo edited.png").path)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: url("Photo edited 3.png").path), [])
    }

    func testReservedInputNameRemainsReservedWhenInputDisappears() throws {
        let reserved = url("Photo edited.png")
        try original.write(to: reserved)
        let stage = try output(inputs: [url("Photo.png"), reserved])
        try files.removeItem(at: reserved)
        try exported.write(to: stage.stagingURL)
        XCTAssertEqual(try stage.publish().url.lastPathComponent, "Photo edited 2.png")
        XCTAssertFalse(files.fileExists(atPath: reserved.path))
    }

    func testIndependentStagesCannotReplaceEachOthersResults() throws {
        let first = try output(), second = try output()
        try original.write(to: first.stagingURL)
        try exported.write(to: second.stagingURL)
        let a = try first.publish(), b = try second.publish()
        XCTAssertNotEqual(a.url, b.url)
        XCTAssertEqual(try Data(contentsOf: a.url), original)
        XCTAssertEqual(try Data(contentsOf: b.url), exported)
    }

    func testDiscardAndAbandonedStageRemovePartialOutput() throws {
        let stage = try output()
        try exported.write(to: stage.stagingURL)
        XCTAssertNil(stage.discard())
        XCTAssertThrowsError(try stage.publish())
        XCTAssertEqual(try entries(), [])
        do {
            let abandoned = try output()
            try exported.write(to: abandoned.stagingURL)
        }
        XCTAssertEqual(try entries(), [])
    }

    func testMissingEmptySymlinkAndHardLinkedStageNeverPublish() throws {
        try original.write(to: url("Original"))
        for kind in ["missing", "empty", "symlink", "hardlink"] {
            let stage = try output()
            switch kind {
            case "empty": try Data().write(to: stage.stagingURL)
            case "symlink": try files.createSymbolicLink(at: stage.stagingURL, withDestinationURL: url("Original"))
            case "hardlink": XCTAssertEqual(link(url("Original").path, stage.stagingURL.path), 0)
            default: break
            }
            XCTAssertThrowsError(try stage.publish(), kind)
            XCTAssertNil(stage.discard())
            XCTAssertEqual(try Data(contentsOf: url("Original")), original)
            XCTAssertEqual(try entries(), ["Original"])
        }
    }

    func testChangedOutputFolderRefusesAndCleansOnlyOriginalStage() throws {
        let originalDirectory = directory!
        let moved = directory.appendingPathExtension("moved")
        defer { try? files.removeItem(at: moved) }
        let stage = try output()
        try exported.write(to: stage.stagingURL)
        try files.moveItem(at: originalDirectory, to: moved)
        try files.createDirectory(at: originalDirectory, withIntermediateDirectories: false)
        try original.write(to: url("Photo edited.png"))
        XCTAssertThrowsError(try stage.publish())
        XCTAssertNil(stage.discard())
        XCTAssertEqual(try Data(contentsOf: url("Photo edited.png")), original)
        XCTAssertEqual(try files.contentsOfDirectory(atPath: moved.path), [])
    }

    func testUnicodeLongNamesFitFilesystemAndRemainDistinct() throws {
        let source = String(repeating: "🌅", count: 100) + ".png"
        let first = try output(source: source), second = try output(source: source)
        try exported.write(to: first.stagingURL)
        try original.write(to: second.stagingURL)
        let a = try first.publish(), b = try second.publish()
        XCTAssertLessThanOrEqual(a.url.lastPathComponent.utf8.count, 255)
        XCTAssertLessThanOrEqual(b.url.lastPathComponent.utf8.count, 255)
        XCTAssertNotEqual(a.url, b.url)
        XCTAssertEqual(try Data(contentsOf: a.url), exported)
        XCTAssertEqual(try Data(contentsOf: b.url), original)
    }

    func testInvalidLocationsAndExtensionsCreateNothing() {
        for ext in ["", "../png", "PNG", "p\0ng", String(repeating: "p", count: 17)] {
            XCTAssertThrowsError(try RecorderBatchOutput(directory: directory, source: url("A"), inputs: [], extension: ext))
        }
        for target in [URL(string: "https://example.invalid/folder")!, URL(string: "file://remote.invalid/tmp")!] {
            XCTAssertThrowsError(try RecorderBatchOutput(directory: target, source: url("A"), inputs: [], extension: "png"))
        }
        XCTAssertEqual(try entries(), [])
    }

    func testPublishedFileSurvivesCleanupWarning() throws {
        let stage = try output()
        try exported.write(to: stage.stagingURL)
        let unexpected = stage.stagingURL.deletingLastPathComponent().appendingPathComponent("Keep")
        try original.write(to: unexpected)
        let result = try stage.publish()
        XCTAssertNotNil(result.cleanupWarning)
        XCTAssertEqual(try Data(contentsOf: result.url), exported)
        XCTAssertEqual(try Data(contentsOf: unexpected), original)
        XCTAssertNotNil(stage.discard())
        XCTAssertEqual(try Data(contentsOf: result.url), exported)
        // Only the fixture removes its extra entry; production never recurses.
        try files.removeItem(at: unexpected)
        XCTAssertNil(stage.discard())
    }

    func testReplacedStagingDirectoryIsNeverDeleted() throws {
        let stage = try output()
        try exported.write(to: stage.stagingURL)
        let temporary = stage.stagingURL.deletingLastPathComponent()
        let moved = url("Moved stage")
        try files.moveItem(at: temporary, to: moved)
        try files.createDirectory(at: temporary, withIntermediateDirectories: false)
        let foreign = temporary.appendingPathComponent("output.png")
        try original.write(to: foreign)
        XCTAssertThrowsError(try stage.publish())
        XCTAssertNotNil(stage.discard())
        XCTAssertEqual(try Data(contentsOf: foreign), original)
        XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("output.png")), exported)
    }
}
