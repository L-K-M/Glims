import Darwin
import XCTest
@testable import GlimsKit

final class RecorderBatchInputsTests: XCTestCase {
    private var root: URL!
    private let files = FileManager.default
    override func setUpWithError() throws {
        root = files.temporaryDirectory.appendingPathComponent("glims-batch-inputs-\(UUID().uuidString)").resolvingSymlinksInPath()
        try files.createDirectory(at: root, withIntermediateDirectories: false)
    }
    override func tearDownWithError() throws { try files.removeItem(at: root) }
    private func folder(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try files.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
    private func file(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(name.utf8).write(to: url)
        return url
    }

    func testFlatFolderSortsFilesAndSkipsHiddenNestedAndLinkedEntries() throws {
        let directory = try folder("Input")
        let z = try file("Input/Z.png"), a = try file("Input/A.xcf")
        _ = try file("Input/.hidden.png")
        _ = try folder("Input/Nested")
        _ = try file("Input/Nested/Image.png")
        let outside = try file("Outside.png")
        try files.createSymbolicLink(at: directory.appendingPathComponent("Link.png"), withDestinationURL: outside)
        XCTAssertEqual(try RecorderBatchInputs.resolve([directory]), [a, z])
    }

    func testSelectionsPreserveOrderAndDeduplicateFilesAndFolderAliases() throws {
        let directory = try folder("Input"), a = try file("Input/A.png"), z = try file("Input/Z.png")
        let alias = root.appendingPathComponent("Alias")
        try files.createSymbolicLink(at: alias, withDestinationURL: directory)
        XCTAssertEqual(try RecorderBatchInputs.resolve([z, directory, a, alias, z]), [z, a])
    }

    func testExplicitFileSymlinkResolvesAndUnknownFormatsRemainInputs() throws {
        let target = try file("Unknown.extension"), alias = root.appendingPathComponent("Selected.png")
        try files.createSymbolicLink(at: alias, withDestinationURL: target)
        XCTAssertEqual(try RecorderBatchInputs.resolve([alias, target]), [target])
    }

    func testEmptyMissingSpecialAndRemoteLocationsRefuse() throws {
        XCTAssertThrowsError(try RecorderBatchInputs.resolve([]))
        XCTAssertThrowsError(try RecorderBatchInputs.resolve([try folder("Empty")]))
        XCTAssertThrowsError(try RecorderBatchInputs.resolve([root.appendingPathComponent("Missing")]))
        let fifo = root.appendingPathComponent("Pipe")
        XCTAssertEqual(mkfifo(fifo.path, mode_t(0o600)), 0)
        XCTAssertThrowsError(try RecorderBatchInputs.resolve([fifo]))
        for url in [URL(string: "https://example.invalid/image.png")!, URL(string: "file://remote.invalid/image.png")!,
                    URL(string: "file:///tmp/image.png?ignored=1")!, root.appendingPathComponent("bad\0name")] {
            XCTAssertThrowsError(try RecorderBatchInputs.resolve([url]))
        }
    }

    func testExpandedLimitCountsDistinctFiles() throws {
        let folder = try folder("Input")
        let a = try file("Input/A.png"), b = try file("Input/B.png")
        XCTAssertEqual(try RecorderBatchInputs.resolve([a, folder, a], limit: 2), [a, b])
        _ = try file("Input/C.png")
        XCTAssertThrowsError(try RecorderBatchInputs.resolve([folder], limit: 2))
        XCTAssertThrowsError(try RecorderBatchInputs.resolve([a], limit: 0))
    }
}
