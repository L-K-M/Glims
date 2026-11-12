import CGlimsEngine
import Darwin
import XCTest
@testable import GlimsKit

final class EngineAPIPrefixTests: XCTestCase {
    /// The producer ends immediately before an inaccessible page. Copying a
    /// current-size pointee from a legacy table would fault rather than merely
    /// reading zeroes from spare test allocation.
    private func withPrefix<T>(size: Int, version: UInt32 = GLIMS_ENGINE_API_VERSION,
                               advertisedSize: UInt32? = nil,
                               _ body: (UnsafePointer<GlimsEngineAPI>) throws -> T) throws -> T {
        let page = Int(getpagesize())
        precondition(size <= page && size >= 8)
        let allocation = mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)!
        guard allocation != MAP_FAILED else { throw POSIXError(.ENOMEM) }
        defer { munmap(allocation, page * 2) }
        guard mprotect(allocation.advanced(by: page), page, PROT_NONE) == 0 else { throw POSIXError(.EACCES) }
        let start = allocation.advanced(by: page - size)
        start.storeBytes(of: version, as: UInt32.self)
        start.storeBytes(of: advertisedSize ?? UInt32(size), toByteOffset: 4, as: UInt32.self)
        return try body(UnsafePointer(start.assumingMemoryBound(to: GlimsEngineAPI.self)))
    }

    func testLegacy182And184And188PrefixesEndAtGuardPage() throws {
        let sizes = [MemoryLayout<GlimsEngineAPI>.offset(of: \.image_edit_ink)!,
                     MemoryLayout<GlimsEngineAPI>.offset(of: \.image_ink_snapshot_begin)!,
                     MemoryLayout<GlimsEngineAPI>.offset(of: \.image_ink_channel_identity)!]
        for size in sizes {
            try withPrefix(size: size) { pointer in
                let copy = try EngineLibrary.copyAPI(pointer)
                XCTAssertEqual(copy.struct_size, UInt32(size))
                XCTAssertEqual(copy.api_version, GLIMS_ENGINE_API_VERSION)
                XCTAssertNil(copy.image_ink_channel_identity)
                withUnsafeBytes(of: copy) { bytes in
                    XCTAssertTrue(bytes[size...].allSatisfy { $0 == 0 })
                }
            }
        }
    }

    func testRejectsShortHeaderVersionAndPartialKnownSlot() throws {
        let minimum = MemoryLayout<GlimsEngineAPI>.offset(of: \.image_edit_ink)!
        try withPrefix(size: 8) { XCTAssertThrowsError(try EngineLibrary.copyAPI($0)) }
        try withPrefix(size: minimum, version: GLIMS_ENGINE_API_VERSION + 1) {
            XCTAssertThrowsError(try EngineLibrary.copyAPI($0))
        }
        // Use aligned backing storage; only the advertised table is partial.
        try withPrefix(size: minimum + 8, advertisedSize: UInt32(minimum + 1)) {
            XCTAssertThrowsError(try EngineLibrary.copyAPI($0))
        }
    }

    func testCurrentPrefixAndFutureTailAreCopiedOnlyThroughKnownFields() throws {
        let known = MemoryLayout<GlimsEngineAPI>.size
        for size in [known, known + 8] {
            try withPrefix(size: size) { pointer in
                let copy = try EngineLibrary.copyAPI(pointer)
                XCTAssertEqual(copy.struct_size, UInt32(size))
                XCTAssertNil(copy.image_ink_channel_identity)
            }
        }
    }
}
