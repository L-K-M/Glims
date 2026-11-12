import CGlimsEngine
import Darwin
import XCTest
@testable import GlimsKit

/// Runs the real Swift transport against an owned C table. No native engine,
/// filesystem import, AppKit window, or user preferences are involved.
final class NativeCMYKPSDImportTransportTests: XCTestCase {
    private final class Producer {
        var status = GLIMS_STATUS_OK
        var result: Int32 = 83
        var message: String?
        var calls = 0
        var ordinaryOpenCalls = 0
        var pathBytes: [UInt8] = []
        var outputWasCleared = false
        var errorWasCleared = false
        var freedStrings = 0
        var closed: [Int32] = []
        var stopped = false

        static func from(_ engine: OpaquePointer?) -> Producer {
            Unmanaged<Producer>.fromOpaque(UnsafeRawPointer(engine!)).takeUnretainedValue()
        }

        // An owner prefix lets free_string count exact releases without mutable
        // global state, so independent fixtures can run concurrently.
        func allocateString(_ value: String) -> UnsafeMutablePointer<CChar> {
            let prefix = MemoryLayout<UnsafeMutableRawPointer>.size
            let bytes = Array(value.utf8) + [0]
            let allocation = UnsafeMutableRawPointer.allocate(
                byteCount: prefix + bytes.count, alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
            allocation.storeBytes(of: Unmanaged.passUnretained(self).toOpaque(), as: UnsafeMutableRawPointer.self)
            bytes.withUnsafeBytes { allocation.advanced(by: prefix).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            return allocation.advanced(by: prefix).assumingMemoryBound(to: CChar.self)
        }

        static func releaseString(_ string: UnsafeMutablePointer<CChar>?) {
            guard let string else { return }
            let allocation = UnsafeMutableRawPointer(string).advanced(by: -MemoryLayout<UnsafeMutableRawPointer>.size)
            let owner = allocation.load(as: UnsafeMutableRawPointer.self)
            Unmanaged<Producer>.fromOpaque(owner).takeUnretainedValue().freedStrings += 1
            allocation.deallocate()
        }
    }

    private func api() -> GlimsEngineAPI {
        var table = GlimsEngineAPI()
        table.api_version = GLIMS_ENGINE_API_VERSION
        table.struct_size = UInt32(MemoryLayout<GlimsEngineAPI>.size)
        table.start = { config, engine, error in
            error?.pointee = nil
            guard let directory = config?.pointee.user_directory,
                  let address = UInt(URL(fileURLWithPath: String(cString: directory)).lastPathComponent),
                  let pointer = OpaquePointer(bitPattern: address) else { return GLIMS_STATUS_INVALID_ARGUMENT }
            engine?.pointee = pointer
            return GLIMS_STATUS_OK
        }
        table.stop = { Producer.from($0).stopped = true }
        table.engine_version = { _ in nil }
        table.free_string = { Producer.releaseString($0) }
        table.image_close = { engine, image in
            Producer.from(engine).closed.append(image)
            return GLIMS_STATUS_OK
        }
        table.image_open = { engine, _, result, error in
            Producer.from(engine).ordinaryOpenCalls += 1
            result?.pointee = 999
            error?.pointee = nil
            return GLIMS_STATUS_OK
        }
        table.image_import_native_cmyk_psd = { engine, path, result, error in
            let producer = Producer.from(engine)
            producer.calls += 1
            producer.pathBytes = path.map { Array(String(cString: $0).utf8) } ?? []
            producer.outputWasCleared = result?.pointee == 0
            producer.errorWasCleared = error?.pointee == nil
            result?.pointee = producer.result
            error?.pointee = producer.message.map { producer.allocateString($0) }
            return producer.status
        }
        return table
    }

    private func withSession(_ producer: Producer = Producer(),
                             configure: (inout GlimsEngineAPI) -> Void = { _ in },
                             guardedPrefix: Bool = false,
                             _ body: (EngineSession, Producer) throws -> Void) throws {
        var table = api()
        configure(&table)
        let address = UInt(bitPattern: Unmanaged.passUnretained(producer).toOpaque())
        let directory = URL(fileURLWithPath: "/fake-engine/\(address)")
        func run(_ pointer: UnsafePointer<GlimsEngineAPI>) throws {
            let session = try EngineSession.start(api: pointer, userDirectory: directory,
                                                  cacheDirectory: directory, onEvent: { _ in })
            defer { session.stop() }
            try body(session, producer)
        }
        try withExtendedLifetime(producer) {
            if guardedPrefix {
                let page = Int(getpagesize()), size = Int(table.struct_size)
                XCTAssertLessThan(size, page)
                let allocation = mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)!
                guard allocation != MAP_FAILED else { throw POSIXError(.ENOMEM) }
                defer { munmap(allocation, page * 2) }
                guard mprotect(allocation.advanced(by: page), page, PROT_NONE) == 0 else { throw POSIXError(.EACCES) }
                let start = allocation.advanced(by: page - size)
                withUnsafeBytes(of: &table) { start.copyMemory(from: $0.baseAddress!, byteCount: size) }
                try run(UnsafePointer(start.assumingMemoryBound(to: GlimsEngineAPI.self)))
            } else {
                try withUnsafePointer(to: &table, run)
            }
        }
        XCTAssertTrue(producer.stopped)
        XCTAssertEqual(producer.ordinaryOpenCalls, 0, "Explicit preserving import must never fall back to Open")
    }

    private func assertStatus(_ expected: GlimsStatus, message: String? = nil,
                              file: StaticString = #filePath, line: UInt = #line,
                              _ operation: () throws -> Int32) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            guard let error = $0 as? EngineSession.EngineError else {
                return XCTFail("Unexpected error type: \($0)", file: file, line: line)
            }
            XCTAssertEqual(error.status, Int32(expected.rawValue), file: file, line: line)
            if let message { XCTAssertEqual(error.message, message, file: file, line: line) }
        }
    }

    func testSlot197PrefixAtGuardPageDoesNotReadOrAdvertiseSlot198() throws {
        let offset = MemoryLayout<GlimsEngineAPI>.offset(of: \.image_import_native_cmyk_psd)!
        XCTAssertEqual(offset, 8 + 197 * MemoryLayout<UnsafeRawPointer>.size)
        try withSession(configure: { $0.struct_size = UInt32(offset) }, guardedPrefix: true) { session, producer in
            XCTAssertFalse(session.supportsNativeCMYKPSDImport)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { try session.importNativeCMYKPSD(path: "/source.psd") }
            XCTAssertEqual(producer.calls, 0)
        }
    }

    func testCompleteSlotWithNullPointerRefusesWithoutFallback() throws {
        try withSession(configure: { $0.image_import_native_cmyk_psd = nil }) { session, producer in
            XCTAssertFalse(session.supportsNativeCMYKPSDImport)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { try session.importNativeCMYKPSD(path: "/source.psd") }
            XCTAssertEqual(producer.calls, 0)
        }
    }

    func testPartialSlotIsRejectedByTheSessionTableLoader() throws {
        var table = api()
        let offset = MemoryLayout<GlimsEngineAPI>.offset(of: \.image_import_native_cmyk_psd)!
        table.struct_size = UInt32(offset + MemoryLayout.size(ofValue: table.image_import_native_cmyk_psd) - 1)
        try withUnsafePointer(to: &table) { pointer in
            XCTAssertThrowsError(try EngineLibrary.copyAPI(pointer)) { error in
                guard case EngineLibrary.LoadError.unsupportedVersion = error else {
                    return XCTFail("Unexpected partial-slot error: \(error)")
                }
            }
        }
    }

    func testAbsolutePathBytesAndPositiveHandleTransferWithoutOtherOptionalFeatures() throws {
        // Decomposed accent and percent characters must remain filesystem bytes,
        // not be normalized, URL-decoded, or passed through an Open fallback.
        let path = "/tmp/CMYK e\u{301} 印刷 100%25.psd"
        try withSession { session, producer in
            XCTAssertTrue(session.supportsNativeCMYKPSDImport)
            XCTAssertFalse(session.supportsLabConvertedCopy)
            let image = try session.importNativeCMYKPSD(path: path)
            XCTAssertEqual(image, 83)
            XCTAssertEqual(producer.calls, 1)
            XCTAssertEqual(producer.pathBytes, Array(path.utf8))
            XCTAssertTrue(producer.outputWasCleared && producer.errorWasCleared)
            XCTAssertEqual(producer.closed, [])
            try session.closeImage(image)
            XCTAssertEqual(producer.closed, [83])
        }
    }

    func testInvalidPathsAreRejectedBeforeEitherNativeImportOrOpen() throws {
        try withSession { session, producer in
            for path in ["", "source.psd", "./source.psd", "../source.psd", "~/source.psd",
                         "file:///tmp/source.psd", "https://example.invalid/source.psd", "/tmp/a\0b.psd", "\0/tmp/source.psd"] {
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.importNativeCMYKPSD(path: path) }
            }
            XCTAssertEqual(producer.calls, 0)
            XCTAssertEqual(producer.closed, [])
            XCTAssertEqual(producer.freedStrings, 0)
        }
    }

    func testProducerErrorsPreserveStatusAndMessageAndFreeExactlyOnce() throws {
        for status in [GLIMS_STATUS_BUSY, GLIMS_STATUS_CANCELLED, GLIMS_STATUS_UNSUPPORTED,
                       GLIMS_STATUS_NOT_FOUND, GLIMS_STATUS_INVALID_ARGUMENT, GLIMS_STATUS_FAILED] {
            let producer = Producer()
            producer.status = status; producer.result = 0; producer.message = "Exact import failure reason"
            try withSession(producer) { session, state in
                self.assertStatus(status, message: "Exact import failure reason") {
                    try session.importNativeCMYKPSD(path: "/source.psd")
                }
                XCTAssertEqual(state.calls, 1)
                XCTAssertEqual(state.freedStrings, 1)
                XCTAssertEqual(state.closed, [])
            }
        }
    }

    func testFailedStatusNeverOwnsOrClosesUnexpectedReturnedHandles() throws {
        for result in [Int32.min, -1, 0, 83, Int32.max] {
            let producer = Producer()
            producer.status = GLIMS_STATUS_FAILED; producer.result = result; producer.message = "No image published"
            try withSession(producer) { session, state in
                self.assertStatus(GLIMS_STATUS_FAILED, message: "No image published") {
                    try session.importNativeCMYKPSD(path: "/source.psd")
                }
                XCTAssertEqual(state.closed, [])
                XCTAssertEqual(state.freedStrings, 1)
            }
        }
    }

    func testMalformedSuccessRejectsNonpositiveHandlesAndFreesAnnotation() throws {
        for result in [Int32.min, -1, 0] {
            let producer = Producer()
            producer.result = result; producer.message = "Unexpected success annotation"
            try withSession(producer) { session, state in
                self.assertStatus(GLIMS_STATUS_FAILED) { try session.importNativeCMYKPSD(path: "/source.psd") }
                XCTAssertEqual(state.closed, [])
                XCTAssertEqual(state.freedStrings, 1)
            }
        }
    }

    func testSuccessAnnotationAndFailureWithoutAnErrorString() throws {
        let success = Producer(); success.message = "Success annotation"
        try withSession(success) { session, state in
            XCTAssertEqual(try session.importNativeCMYKPSD(path: "/source.psd"), 83)
            XCTAssertEqual(state.freedStrings, 1)
        }
        let failure = Producer(); failure.status = GLIMS_STATUS_CANCELLED; failure.result = 0
        try withSession(failure) { session, state in
            self.assertStatus(GLIMS_STATUS_CANCELLED) { try session.importNativeCMYKPSD(path: "/source.psd") }
            XCTAssertEqual(state.freedStrings, 0)
            XCTAssertEqual(state.closed, [])
        }
    }
}
