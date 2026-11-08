import XCTest
import Darwin
import CGlimsEngine
@testable import GlimsKit

/// Pure contract tests for the image-metadata facade wrappers: the
/// facade-owned enum values must match the C header's slots, and the
/// owned string-vector decoder must read exactly `count` entries of a
/// NULL-terminated vector. No engine is started.
final class EngineMetadataTests: XCTestCase {

    func testMetadataDomainRawValuesMatchFacade() {
        XCTAssertEqual(EngineSession.MetadataDomain.exif.rawValue, GLIMS_METADATA_EXIF.rawValue)
        XCTAssertEqual(EngineSession.MetadataDomain.iptc.rawValue, GLIMS_METADATA_IPTC.rawValue)
        XCTAssertEqual(EngineSession.MetadataDomain.xmp.rawValue, GLIMS_METADATA_XMP.rawValue)
        XCTAssertEqual(EngineSession.MetadataDomain.allCases.count, 3)
        XCTAssertNil(EngineSession.MetadataDomain(rawValue: 0))
        XCTAssertNil(EngineSession.MetadataDomain(rawValue: 4))
    }

    func testMetadataEditRawValuesMatchFacade() {
        XCTAssertEqual(EngineSession.MetadataEdit.set.rawValue, GLIMS_METADATA_SET.rawValue)
        XCTAssertEqual(EngineSession.MetadataEdit.remove.rawValue, GLIMS_METADATA_REMOVE.rawValue)
        XCTAssertNil(EngineSession.MetadataEdit(rawValue: 0))
        XCTAssertNil(EngineSession.MetadataEdit(rawValue: 3))
    }

    func testStringVectorDecodesOwnedVector() {
        let first = strdup("Exif.Image.Artist")
        let second = strdup("Iptc.Application2.Keywords")
        defer { free(first); free(second) }
        var vector: [UnsafeMutablePointer<CChar>?] = [first, second, nil]
        vector.withUnsafeBufferPointer { buffer in
            XCTAssertEqual(
                EngineSession.stringVector(buffer.baseAddress, count: 2),
                ["Exif.Image.Artist", "Iptc.Application2.Keywords"])
        }
    }

    func testStringVectorEmptyAndNil() {
        XCTAssertEqual(EngineSession.stringVector(nil, count: 0), [])
        XCTAssertEqual(EngineSession.stringVector(nil, count: 3), [])
        var empty: [UnsafeMutablePointer<CChar>?] = [nil]
        empty.withUnsafeBufferPointer { buffer in
            XCTAssertEqual(EngineSession.stringVector(buffer.baseAddress, count: 0), [])
        }
    }

    func testStringVectorStopsAtCountEvenWithoutTerminator() {
        let first = strdup("one")
        let second = strdup("two")
        defer { free(first); free(second) }
        var vector: [UnsafeMutablePointer<CChar>?] = [first, second]
        vector.withUnsafeBufferPointer { buffer in
            XCTAssertEqual(EngineSession.stringVector(buffer.baseAddress, count: 1), ["one"])
        }
    }
}
