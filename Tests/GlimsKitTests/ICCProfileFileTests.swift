import CoreGraphics
import XCTest
@testable import GlimsKit

final class ICCProfileFileTests: XCTestCase {
    func testBoundedFileReadKeepsExactProfileBytes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("proof.icc")
        let data = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?)
        try data.write(to: url)
        XCTAssertEqual(try ICCProfileFile.read(url), data)
        try Data().write(to: url)
        XCTAssertThrowsError(try ICCProfileFile.read(url))
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: UInt64(CanvasSoftProof.maximumICCBytes + 1))
        try handle.close()
        XCTAssertThrowsError(try ICCProfileFile.read(url))
        XCTAssertThrowsError(try ICCProfileFile.read(folder))
    }
}
