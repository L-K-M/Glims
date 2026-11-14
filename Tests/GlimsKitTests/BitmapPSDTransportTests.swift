import CGlimsEngine
import Darwin
import XCTest
@testable import GlimsKit

final class BitmapPSDTransportTests: XCTestCase {
    private final class Producer {
        var calls = 0
        var image: Int32 = 0
        var path = ""
        var stopped = false
        static func from(_ engine: OpaquePointer?) -> Producer {
            Unmanaged<Producer>.fromOpaque(UnsafeRawPointer(engine!)).takeUnretainedValue()
        }
    }

    private func withSession(short: Bool = false, missing: Bool = false,
                             _ body: (EngineSession, Producer) throws -> Void) throws {
        let producer = Producer()
        var api = GlimsEngineAPI()
        api.api_version = GLIMS_ENGINE_API_VERSION
        api.struct_size = UInt32(short ? MemoryLayout<GlimsEngineAPI>.offset(of: \.image_export_bitmap_psd)! : MemoryLayout<GlimsEngineAPI>.size)
        api.start = { config, result, _ in
            guard let path = config?.pointee.user_directory,
                  let address = UInt(URL(fileURLWithPath: String(cString: path)).lastPathComponent),
                  let pointer = OpaquePointer(bitPattern: address) else { return GLIMS_STATUS_INVALID_ARGUMENT }
            result?.pointee = pointer
            return GLIMS_STATUS_OK
        }
        api.stop = { Producer.from($0).stopped = true }
        api.engine_version = { _ in nil }
        api.free_string = { _ in }
        if !missing {
            api.image_export_bitmap_psd = { engine, image, path, error in
                let owner = Producer.from(engine)
                owner.calls += 1
                owner.image = image
                owner.path = path.map { String(cString: $0) } ?? ""
                error?.pointee = nil
                return GLIMS_STATUS_OK
            }
        }
        let directory = URL(fileURLWithPath: "/fixture/\(UInt(bitPattern: Unmanaged.passUnretained(producer).toOpaque()))")
        try withExtendedLifetime(producer) {
            if short {
                let page = Int(getpagesize()), size = Int(api.struct_size)
                let memory = mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)!
                guard memory != MAP_FAILED else { throw POSIXError(.ENOMEM) }
                defer { munmap(memory, page * 2) }
                guard mprotect(memory.advanced(by: page), page, PROT_NONE) == 0 else { throw POSIXError(.EACCES) }
                let start = memory.advanced(by: page - size)
                withUnsafeBytes(of: &api) { start.copyMemory(from: $0.baseAddress!, byteCount: size) }
                let session = try EngineSession.start(api: UnsafePointer(start.assumingMemoryBound(to: GlimsEngineAPI.self)), userDirectory: directory, cacheDirectory: directory, onEvent: { _ in })
                defer { session.stop() }
                try body(session, producer)
            } else {
                try withUnsafePointer(to: &api) { pointer in
                    let session = try EngineSession.start(api: pointer, userDirectory: directory, cacheDirectory: directory, onEvent: { _ in })
                    defer { session.stop() }
                    try body(session, producer)
                }
            }
        }
        XCTAssertTrue(producer.stopped)
    }

    func testBitmapUsesOptionalSlotAndRefusesOldOrMissingAdapter() throws {
        var settings = ExportSettings()
        settings.format = .psd
        settings.psdColor = .bitmap
        settings.psdLayout = .merged
        for (short, missing) in [(true, false), (false, true)] {
            try withSession(short: short, missing: missing) { session, producer in
                XCTAssertFalse(session.supportsBitmapPSD)
                XCTAssertThrowsError(try session.export(17, to: "/tmp/output.psd", settings: settings))
                XCTAssertEqual(producer.calls, 0)
            }
        }
        try withSession { session, producer in
            XCTAssertTrue(session.supportsBitmapPSD)
            try session.export(17, to: "/tmp/output.psd", settings: settings)
            XCTAssertEqual(producer.calls, 1)
            XCTAssertEqual(producer.image, 17)
            XCTAssertEqual(producer.path, "/tmp/output.psd")
            settings.psdLayout = .layers
            XCTAssertThrowsError(try session.export(17, to: "/tmp/output.psd", settings: settings))
            XCTAssertEqual(producer.calls, 1)
        }
    }
}
