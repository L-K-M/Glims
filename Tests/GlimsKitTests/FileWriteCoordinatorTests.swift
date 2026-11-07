import XCTest
@testable import GlimsKit

@MainActor
final class FileWriteCoordinatorTests: XCTestCase {
    func testSaveAsCannotOverwriteAnotherOpenOrOpeningImage() throws {
        let writes = FileWriteCoordinator()
        let a = UUID(), b = UUID()
        let url = URL(fileURLWithPath: "/tmp/glims-file-target.xcf")
        XCTAssertThrowsError(try writes.reserve(url, owner: a, openFiles: [(b, url)], opening: []))
        XCTAssertThrowsError(try writes.reserve(url, owner: a, openFiles: [], opening: [url]))
        let token = try writes.reserve(url, owner: a, openFiles: [(a, url)], opening: [])
        writes.release(token)
    }

    func testConcurrentSaveAsTargetsStayReservedUntilEachWriteFinishes() throws {
        let writes = FileWriteCoordinator()
        let a = UUID(), b = UUID()
        let url = URL(fileURLWithPath: "/tmp/glims-save-as-target.xcf")
        let first = try writes.reserve(url, owner: a, openFiles: [], opening: [])
        let second = try writes.reserve(url, owner: a, openFiles: [], opening: [])
        writes.release(first)
        XCTAssertThrowsError(try writes.reserve(url, owner: b, openFiles: [], opening: []))
        writes.release(second)
        let third = try writes.reserve(url, owner: b, openFiles: [], opening: [])
        writes.release(third)
    }

    func testSymlinkAliasesIdentifyTheSameFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("original.xcf")
        let alias = folder.appendingPathComponent("alias.xcf")
        try Data().write(to: original)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: original)
        XCTAssertTrue(FileWriteCoordinator.sameFile(original, alias))
    }
}
