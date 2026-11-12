import CGlimsEngine
import Darwin
import XCTest
@testable import GlimsKit

/// Exercises the real session transport with a C function table. The fake
/// engine owns no native images and never touches the filesystem or desktop.
final class LabConvertedCopyTransportTests: XCTestCase {
    private final class Producer {
        var status = GLIMS_STATUS_OK
        var result: Int32 = 81
        var message: String?
        var calls = 0
        var source: Int32 = 0
        var settings: GlimsLabCopySettings?
        var outputWasCleared = false
        var errorWasCleared = false
        var freedStrings = 0
        var stopped = false
        var closed: [Int32] = []

        static func from(_ engine: OpaquePointer?) -> Producer {
            Unmanaged<Producer>.fromOpaque(UnsafeRawPointer(engine!)).takeUnretainedValue()
        }

        /// Keep the owner beside this fixture's allocated string, so free_string
        /// can count releases without global mutable state or a real engine.
        func allocateString(_ value: String) -> UnsafeMutablePointer<CChar> {
            let prefix = MemoryLayout<UnsafeMutableRawPointer>.size
            let bytes = Array(value.utf8) + [0]
            let allocation = UnsafeMutableRawPointer.allocate(
                byteCount: prefix + bytes.count,
                alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
            allocation.storeBytes(of: Unmanaged.passUnretained(self).toOpaque(),
                                  as: UnsafeMutableRawPointer.self)
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
            guard let config, let directory = config.pointee.user_directory,
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
        // Dependencies are capability-only here; creating or filling a second
        // image is not part of this transport and would fail the fixture.
        table.image_new_lab = { _, _, _, _, _, _ in GLIMS_STATUS_UNSUPPORTED }
        table.image_lab_axes = { _, _, _ in GLIMS_STATUS_UNSUPPORTED }
        table.image_fill_lab = { _, _, _, _ in GLIMS_STATUS_UNSUPPORTED }
        table.image_convert_lab_copy = { engine, source, settings, result, error in
            let producer = Producer.from(engine)
            producer.calls += 1
            producer.source = source
            producer.settings = settings?.pointee
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
        let directory = URL(fileURLWithPath: "/fake-engine/\(UInt(bitPattern: Unmanaged.passUnretained(producer).toOpaque()))")
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

    func testSlot196PrefixEndsAtGuardPageAndDoesNotAdvertiseConversion() throws {
        try withSession(configure: {
            $0.struct_size = UInt32(MemoryLayout<GlimsEngineAPI>.offset(of: \.image_convert_lab_copy)!)
        }, guardedPrefix: true) { session, producer in
            XCTAssertTrue(session.supportsLabCreation && session.supportsLabAxes && session.supportsLabFill)
            XCTAssertFalse(session.supportsLabConvertedCopy)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { try session.convertedLabCopy(image: 27, destination: .lab) }
            XCTAssertEqual(producer.calls, 0)
        }
    }

    func testSlot197NeedsItsPointerAndEveryDocumentCapability() throws {
        for missing in 1..<16 {
            try withSession(configure: {
                if missing & 1 != 0 { $0.image_convert_lab_copy = nil }
                if missing & 2 != 0 { $0.image_new_lab = nil }
                if missing & 4 != 0 { $0.image_lab_axes = nil }
                if missing & 8 != 0 { $0.image_fill_lab = nil }
            }) { session, producer in
                XCTAssertFalse(session.supportsLabConvertedCopy, "Missing capabilities: \(missing)")
                self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { try session.convertedLabCopy(image: 27, destination: .linearRGB) }
                XCTAssertEqual(producer.calls, 0)
            }
        }
    }

    func testTypedDestinationsSendCompleteFloatMergedSettingsAndTransferSuccess() throws {
        for (destination, mode) in [(EngineSession.LabCopyDestination.lab, UInt32(6)), (.linearRGB, UInt32(1))] {
            try withSession { session, producer in
                XCTAssertTrue(session.supportsLabConvertedCopy)
                let result = try session.convertedLabCopy(image: 27, destination: destination)
                XCTAssertEqual(result, 81)
                XCTAssertEqual(producer.calls, 1)
                XCTAssertEqual(producer.source, 27)
                XCTAssertEqual(producer.settings?.struct_size, 16)
                XCTAssertEqual(producer.settings?.destination_mode, mode)
                XCTAssertEqual(producer.settings?.content, 1)
                XCTAssertEqual(producer.settings?.output_component, 5)
                XCTAssertTrue(producer.outputWasCleared && producer.errorWasCleared)
                XCTAssertEqual(producer.closed, []) // Ownership transferred to the caller.
                try session.closeImage(result)
                XCTAssertEqual(producer.closed, [81])
            }
        }
    }

    func testInvalidSourceNeverCallsProducer() throws {
        try withSession { session, producer in
            for source in [Int32.min, -1, 0] {
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.convertedLabCopy(image: source, destination: .lab) }
            }
            XCTAssertEqual(producer.calls, 0)
            XCTAssertEqual(producer.closed, [])
        }
    }

    func testErrorsRetainStatusAndMessageAndFreeTheirStringExactlyOnce() throws {
        for status in [GLIMS_STATUS_BUSY, GLIMS_STATUS_CANCELLED, GLIMS_STATUS_UNSUPPORTED, GLIMS_STATUS_FAILED] {
            let producer = Producer()
            producer.status = status; producer.result = 0; producer.message = "Precise producer reason"
            try withSession(producer) { session, state in
                self.assertStatus(status, message: "Precise producer reason") { try session.convertedLabCopy(image: 27, destination: .lab) }
                XCTAssertEqual(state.freedStrings, 1)
                XCTAssertEqual(state.calls, 1)
                XCTAssertEqual(state.closed, [])
            }
        }
    }

    func testFailureDoesNotOwnUnexpectedHandlesAndNeverClosesExistingDocuments() throws {
        for result in [Int32.min, -1, 27, 81] {
            let producer = Producer()
            producer.status = GLIMS_STATUS_FAILED; producer.result = result; producer.message = "Failed before publication"
            try withSession(producer) { session, state in
                self.assertStatus(GLIMS_STATUS_FAILED, message: "Failed before publication") {
                    try session.convertedLabCopy(image: 27, destination: .linearRGB)
                }
                XCTAssertEqual(state.closed, [])
                XCTAssertEqual(state.freedStrings, 1)
            }
        }
    }

    func testMalformedSuccessfulIdentityRejectsZeroNegativeAndSourceAlias() throws {
        for result in [Int32.min, -1, 0, 27] {
            let producer = Producer()
            producer.result = result; producer.message = "Unexpected success annotation"
            try withSession(producer) { session, state in
                self.assertStatus(GLIMS_STATUS_FAILED) { try session.convertedLabCopy(image: 27, destination: .lab) }
                XCTAssertEqual(state.closed, [])
                XCTAssertEqual(state.freedStrings, 1)
            }
        }
    }

    func testSuccessStringIsReleasedAndErrorWithoutStringStillHasCorrectStatus() throws {
        let success = Producer(); success.message = "Producer annotation"
        try withSession(success) { session, state in
            XCTAssertEqual(try session.convertedLabCopy(image: 27, destination: .lab), 81)
            XCTAssertEqual(state.freedStrings, 1)
        }
        let failure = Producer(); failure.status = GLIMS_STATUS_CANCELLED; failure.result = 0
        try withSession(failure) { session, state in
            self.assertStatus(GLIMS_STATUS_CANCELLED) { try session.convertedLabCopy(image: 27, destination: .lab) }
            XCTAssertEqual(state.freedStrings, 0)
        }
    }
}
