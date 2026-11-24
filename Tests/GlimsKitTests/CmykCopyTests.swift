import CGlimsEngine
import XCTest
@testable import GlimsKit

/// Exercises the CMYK copy transport with a C function table. The fake
/// engine owns no native images and never touches the filesystem or desktop.
final class CmykCopyTests: XCTestCase {
    private final class Producer {
        var status = GLIMS_STATUS_OK
        var result: Int32 = 91
        var message: String?
        var calls = 0
        var source: Int32 = 0
        var settings: GlimsCmykCopySettings?
        var profileBytes: [UInt8] = []
        var outputWasCleared = false
        var errorWasCleared = false
        var freedStrings = 0
        var stopped = false

        static func from(_ engine: OpaquePointer?) -> Producer {
            Unmanaged<Producer>.fromOpaque(UnsafeRawPointer(engine!)).takeUnretainedValue()
        }

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
        table.image_convert_cmyk_copy = { engine, source, settings, result, error in
            let producer = Producer.from(engine)
            producer.calls += 1
            producer.source = source
            producer.settings = settings?.pointee
            producer.outputWasCleared = result?.pointee == 0
            producer.errorWasCleared = error?.pointee == nil
            if let pointer = settings?.pointee.profile_icc, settings!.pointee.profile_length > 0 {
                producer.profileBytes = Array(UnsafeBufferPointer(start: pointer,
                                                                  count: settings!.pointee.profile_length))
            }
            result?.pointee = producer.result
            error?.pointee = producer.message.map { producer.allocateString($0) }
            return producer.status
        }
        return table
    }

    private func withSession(_ producer: Producer = Producer(),
                             _ body: (EngineSession, Producer) throws -> Void) throws {
        var table = api()
        let directory = URL(fileURLWithPath: "/fake-engine/\(UInt(bitPattern: Unmanaged.passUnretained(producer).toOpaque()))")
        try withExtendedLifetime(producer) {
            try withUnsafePointer(to: &table) { pointer in
                let session = try EngineSession.start(api: pointer, userDirectory: directory,
                                                       cacheDirectory: directory, onEvent: { _ in })
                defer { session.stop() }
                try body(session, producer)
            }
        }
        XCTAssertTrue(producer.stopped)
    }

    func testCmykDestinationMarshalsSettingsAndProfile() throws {
        try withSession { session, producer in
            let icc = Data([0x00, 0x11, 0x22, 0x33, 0x61, 0x63, 0x73, 0x70])
            let result = try session.convertedCmykCopy(image: 7, destination: .cmyk,
                                                       component: .u16, profile: icc)
            XCTAssertEqual(result, 91)
            XCTAssertEqual(producer.calls, 1)
            XCTAssertEqual(producer.source, 7)
            XCTAssertTrue(producer.outputWasCleared && producer.errorWasCleared)
            XCTAssertEqual(producer.settings?.struct_size,
                           UInt32(MemoryLayout<GlimsCmykCopySettings>.size))
            XCTAssertEqual(producer.settings?.destination_mode, GLIMS_COLOR_MODE_CMYK.rawValue)
            XCTAssertEqual(producer.settings?.output_component, GLIMS_COLOR_COMPONENT_U16.rawValue)
            XCTAssertEqual(producer.profileBytes, Array(icc))
        }
    }

    func testRgbDestinationSendsNoProfile() throws {
        try withSession { session, producer in
            let result = try session.convertedCmykCopy(image: 7, destination: .rgb,
                                                       component: .float, profile: nil)
            XCTAssertEqual(result, 91)
            XCTAssertEqual(producer.settings?.destination_mode, GLIMS_COLOR_MODE_RGB.rawValue)
            XCTAssertEqual(producer.settings?.output_component, GLIMS_COLOR_COMPONENT_FLOAT.rawValue)
            XCTAssertTrue(producer.profileBytes.isEmpty)
            XCTAssertNil(producer.settings?.profile_icc)
            XCTAssertEqual(producer.settings?.profile_length, 0)
        }
    }

    func testCmykDestinationRequiresProfile() throws {
        try withSession { session, producer in
            XCTAssertThrowsError(try session.convertedCmykCopy(image: 7, destination: .cmyk,
                                                               component: .u8, profile: nil)) { error in
                guard let engineError = error as? EngineSession.EngineError else {
                    return XCTFail("Unexpected error type: \(error)")
                }
                XCTAssertEqual(engineError.status, Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue))
            }
            XCTAssertEqual(producer.calls, 0, "a missing profile must not reach the engine")
        }
    }

    func testUnsupportedEngineRefusesBeforeCall() throws {
        let producer = Producer()
        try withSession(producer) { session, _ in
            XCTAssertTrue(session.supportsCmykCopy)
            _ = session
        }
        var table = api()
        table.struct_size = UInt32(MemoryLayout<GlimsEngineAPI>.offset(of: \.image_convert_cmyk_copy)!)
        let directory = URL(fileURLWithPath: "/fake-engine/\(UInt(bitPattern: Unmanaged.passUnretained(producer).toOpaque()))")
        try withExtendedLifetime(producer) {
            try withUnsafePointer(to: &table) { pointer in
                let session = try EngineSession.start(api: pointer, userDirectory: directory,
                                                       cacheDirectory: directory, onEvent: { _ in })
                defer { session.stop() }
                XCTAssertFalse(session.supportsCmykCopy)
                XCTAssertThrowsError(try session.convertedCmykCopy(image: 7, destination: .rgb,
                                                                   component: .float, profile: nil)) { error in
                    guard let engineError = error as? EngineSession.EngineError else {
                        return XCTFail("Unexpected error type: \(error)")
                    }
                    XCTAssertEqual(engineError.status, Int32(GLIMS_STATUS_UNSUPPORTED.rawValue))
                }
            }
        }
        XCTAssertEqual(producer.calls, 0)
    }

    func testFailurePropagatesStatusAndFreesError() throws {
        let producer = Producer()
        producer.status = GLIMS_STATUS_CANCELLED
        producer.message = "cancelled"
        producer.result = 0
        try withSession(producer) { session, _ in
            XCTAssertThrowsError(try session.convertedCmykCopy(image: 7, destination: .rgb,
                                                               component: .float, profile: nil)) { error in
                guard let engineError = error as? EngineSession.EngineError else {
                    return XCTFail("Unexpected error type: \(error)")
                }
                XCTAssertEqual(engineError.status, Int32(GLIMS_STATUS_CANCELLED.rawValue))
            }
        }
        XCTAssertEqual(producer.freedStrings, 1)
    }

    func testResultIdentityIsChecked() throws {
        let producer = Producer()
        producer.result = 7 // same as the source image
        try withSession(producer) { session, _ in
            XCTAssertThrowsError(try session.convertedCmykCopy(image: 7, destination: .rgb,
                                                               component: .float, profile: nil))
        }
    }
}
