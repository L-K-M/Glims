import CGlimsEngine
import Darwin
import XCTest
@testable import GlimsKit

final class LabLayerFillTransportTests: XCTestCase {
    private final class Producer {
        var ordinaryCalls = 0
        var guardedCalls = 0
        var image: Int32 = 0
        var settings: GlimsLabLayerColorFillSettings?
        var status = GLIMS_STATUS_OK
        var message: String?
        var freed = 0
        var stopped = false

        static func from(_ engine: OpaquePointer?) -> Producer {
            Unmanaged<Producer>.fromOpaque(UnsafeRawPointer(engine!)).takeUnretainedValue()
        }

        func errorString(_ value: String) -> UnsafeMutablePointer<CChar> {
            let prefix = MemoryLayout<UnsafeMutableRawPointer>.size
            let bytes = Array(value.utf8) + [0]
            let allocation = UnsafeMutableRawPointer.allocate(byteCount: prefix + bytes.count,
                                                               alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
            allocation.storeBytes(of: Unmanaged.passUnretained(self).toOpaque(), as: UnsafeMutableRawPointer.self)
            bytes.withUnsafeBytes { allocation.advanced(by: prefix).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            return allocation.advanced(by: prefix).assumingMemoryBound(to: CChar.self)
        }
    }

    private func makeAPI() -> GlimsEngineAPI {
        var api = GlimsEngineAPI()
        api.api_version = GLIMS_ENGINE_API_VERSION
        api.struct_size = UInt32(MemoryLayout<GlimsEngineAPI>.size)
        api.start = { config, result, error in
            error?.pointee = nil
            guard let path = config?.pointee.user_directory,
                  let address = UInt(URL(fileURLWithPath: String(cString: path)).lastPathComponent),
                  let pointer = OpaquePointer(bitPattern: address) else { return GLIMS_STATUS_INVALID_ARGUMENT }
            result?.pointee = pointer
            return GLIMS_STATUS_OK
        }
        api.stop = { Producer.from($0).stopped = true }
        api.engine_version = { _ in nil }
        api.free_string = { string in
            guard let string else { return }
            let base = UnsafeMutableRawPointer(string).advanced(by: -MemoryLayout<UnsafeMutableRawPointer>.size)
            let owner = base.load(as: UnsafeMutableRawPointer.self)
            Unmanaged<Producer>.fromOpaque(owner).takeUnretainedValue().freed += 1
            base.deallocate()
        }
        api.image_lab_layer_identity = { _, _, _, _ in GLIMS_STATUS_UNSUPPORTED }
        api.image_fill_lab_layer_srgb = { engine, _, _, _ in
            Producer.from(engine).ordinaryCalls += 1
            return GLIMS_STATUS_OK
        }
        api.image_fill_lab_layer_srgb_empty_selection = { engine, image, settings, error in
            let producer = Producer.from(engine)
            producer.guardedCalls += 1
            producer.image = image
            producer.settings = settings?.pointee
            error?.pointee = producer.message.map { producer.errorString($0) }
            return producer.status
        }
        return api
    }

    private func withSession(_ producer: Producer = Producer(),
                             configure: (inout GlimsEngineAPI) -> Void = { _ in },
                             guardedPrefix: Bool = false,
                             _ body: (EngineSession, Producer) throws -> Void) throws {
        var api = makeAPI(); configure(&api)
        let directory = URL(fileURLWithPath: "/fake-engine/\(UInt(bitPattern: Unmanaged.passUnretained(producer).toOpaque()))")
        func run(_ pointer: UnsafePointer<GlimsEngineAPI>) throws {
            let session = try EngineSession.start(api: pointer, userDirectory: directory,
                                                  cacheDirectory: directory, onEvent: { _ in })
            defer { session.stop() }
            try body(session, producer)
        }
        try withExtendedLifetime(producer) {
            if guardedPrefix {
                let page = Int(getpagesize()), count = Int(api.struct_size)
                let allocation = mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)!
                guard allocation != MAP_FAILED else { throw POSIXError(.ENOMEM) }
                defer { munmap(allocation, page * 2) }
                guard mprotect(allocation.advanced(by: page), page, PROT_NONE) == 0 else { throw POSIXError(.EACCES) }
                let start = allocation.advanced(by: page - count)
                withUnsafeBytes(of: &api) { start.copyMemory(from: $0.baseAddress!, byteCount: count) }
                try run(UnsafePointer(start.assumingMemoryBound(to: GlimsEngineAPI.self)))
            } else {
                try withUnsafePointer(to: &api, run)
            }
        }
        XCTAssertTrue(producer.stopped)
    }

    private let target = EngineSession.LabLayerFillTarget(root: 17, uuid: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!)
    private let color = EngineSession.RGBAColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)

    func testOlderGuardPagePrefixRefusesGuardedCallButKeepsOrdinaryFill() throws {
        try withSession(configure: {
            $0.struct_size = UInt32(MemoryLayout<GlimsEngineAPI>.offset(of: \.image_fill_lab_layer_srgb_empty_selection)!)
        }, guardedPrefix: true) { session, producer in
            XCTAssertTrue(session.supportsLabLayerColorFill)
            XCTAssertFalse(session.supportsLabLayerColorFillEmptySelection)
            XCTAssertThrowsError(try session.fillLabLayer(19, target: target, color: color, opacity: 0.5, requireEmptySelection: true))
            XCTAssertEqual(producer.guardedCalls, 0)
            try session.fillLabLayer(19, target: target, color: color, opacity: 0.5)
            XCTAssertEqual(producer.ordinaryCalls, 1)
        }
    }

    func testMissingGuardedSlotRefusesWithoutCallingOrdinaryFill() throws {
        try withSession(configure: { $0.image_fill_lab_layer_srgb_empty_selection = nil }) { session, producer in
            XCTAssertFalse(session.supportsLabLayerColorFillEmptySelection)
            XCTAssertThrowsError(try session.fillLabLayer(19, target: target, color: color, opacity: 0.5, requireEmptySelection: true))
            XCTAssertEqual(producer.ordinaryCalls, 0)
            XCTAssertEqual(producer.guardedCalls, 0)
        }
    }

    func testGuardedFillSendsCapturedIdentityAndPropagatesNativeError() throws {
        let producer = Producer()
        try withSession(producer) { session, state in
            XCTAssertTrue(session.supportsLabLayerColorFillEmptySelection)
            try session.fillLabLayer(19, target: target, color: color, opacity: 0.5, requireEmptySelection: true)
            XCTAssertEqual(state.guardedCalls, 1)
            XCTAssertEqual(state.ordinaryCalls, 0)
            XCTAssertEqual(state.image, 19)
            XCTAssertEqual(state.settings?.struct_size, UInt32(MemoryLayout<GlimsLabLayerColorFillSettings>.size))
            XCTAssertEqual(state.settings?.root, 17)
            XCTAssertEqual(state.settings.map { UUID(uuid: $0.uuid) }, target.uuid)
            XCTAssertEqual(state.settings?.color.red, 0.2)
            XCTAssertEqual(state.settings?.color.green, 0.4)
            XCTAssertEqual(state.settings?.color.blue, 0.6)
            XCTAssertEqual(state.settings?.color.alpha, 0.8)
            XCTAssertEqual(state.settings?.opacity, 0.5)
            state.status = GLIMS_STATUS_INVALID_ARGUMENT
            state.message = "Clear the selection"
            XCTAssertThrowsError(try session.fillLabLayer(19, target: target, color: color, opacity: 0.5, requireEmptySelection: true)) {
                guard let error = $0 as? EngineSession.EngineError else { return XCTFail("Unexpected error: \($0)") }
                XCTAssertEqual(error.status, Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue))
                XCTAssertEqual(error.message, "Clear the selection")
            }
            XCTAssertEqual(state.freed, 1)
        }
    }
}
