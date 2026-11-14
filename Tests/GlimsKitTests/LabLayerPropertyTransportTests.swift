import CGlimsEngine
import Darwin
import XCTest
@testable import GlimsKit

final class LabLayerPropertyTransportTests: XCTestCase {
    private final class Producer {
        var ordinaryCalls = 0
        var guardedCalls = 0
        var image: Int32 = 0
        var settings: GlimsLabLayerPropertyChange?
        var status = GLIMS_STATUS_OK
        var message: String?
        var freed = 0
        var stopped = false
        var snapshotRows: [GlimsLabLayerSnapshotRow] = []
        var snapshotCount: Int32?
        var snapshotCalls = 0

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
        api.image_lab_layer_identity = { _, _, _, result in
            guard let result else { return GLIMS_STATUS_INVALID_ARGUMENT }
            result.pointee.uuid = (0, 17, 34, 51, 68, 85, 102, 119, 136, 153, 170, 187, 204, 221, 238, 255)
            return GLIMS_STATUS_OK
        }
        api.layer_change = { engine, _, _, _, _ in
            Producer.from(engine).ordinaryCalls += 1
            return GLIMS_STATUS_OK
        }
        api.image_change_lab_layer_properties = { engine, image, settings, error in
            let producer = Producer.from(engine)
            producer.guardedCalls += 1
            producer.image = image
            producer.settings = settings?.pointee
            error?.pointee = producer.message.map { producer.errorString($0) }
            return producer.status
        }
        api.image_lab_layer_snapshot = { engine, _, rows, capacity, count in
            let producer = Producer.from(engine)
            producer.snapshotCalls += 1
            count?.pointee = producer.snapshotCount ?? Int32(producer.snapshotRows.count)
            if let rows {
                for index in 0..<min(Int(capacity), producer.snapshotRows.count) {
                    rows[index] = producer.snapshotRows[index]
                }
            }
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
    private let change = EngineSession.LayerChange(isVisible: false, opacity: 0.375)

    func testLayerSnapshotRefusesOldPrefixAndMissingSlot() throws {
        try withSession(configure: {
            $0.struct_size = UInt32(MemoryLayout<GlimsEngineAPI>.offset(of: \.image_lab_layer_snapshot)!)
        }, guardedPrefix: true) { session, producer in
            XCTAssertFalse(session.supportsLabLayerSnapshot)
            XCTAssertThrowsError(try session.labLayerSnapshot(19))
            XCTAssertEqual(producer.snapshotCalls, 0)
        }
        try withSession(configure: { $0.image_lab_layer_snapshot = nil }) { session, producer in
            XCTAssertFalse(session.supportsLabLayerSnapshot)
            XCTAssertThrowsError(try session.labLayerSnapshot(19))
            XCTAssertEqual(producer.snapshotCalls, 0)
        }
    }

    func testLayerSnapshotPairsRowsAndRejectsMalformedNativeResults() throws {
        let producer = Producer()
        var first = GlimsLabLayerSnapshotRow(), second = GlimsLabLayerSnapshotRow()
        first.layer.id = 17; first.layer.opacity = 0.375; first.layer.visible = true
        first.uuid = target.uuid.uuid
        second.layer.id = 23; second.layer.opacity = 0.75
        second.uuid = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!.uuid
        producer.snapshotRows = [first, second]
        try withSession(producer) { session, state in
            XCTAssertTrue(session.supportsLabLayerSnapshot)
            let rows = try session.labLayerSnapshot(19)
            XCTAssertEqual(rows.map(\.layer.id), [17, 23])
            XCTAssertEqual(rows.map(\.identity), [UUID(uuid: first.uuid), UUID(uuid: second.uuid)])
            XCTAssertEqual(rows.map(\.layer.opacity), [0.375, 0.75])
            XCTAssertEqual(state.snapshotCalls, 1)
            state.snapshotCount = 257
            XCTAssertThrowsError(try session.labLayerSnapshot(19))
            state.snapshotCount = -1
            XCTAssertThrowsError(try session.labLayerSnapshot(19))
            state.snapshotCount = nil
            state.snapshotRows[1].layer.id = first.layer.id
            XCTAssertThrowsError(try session.labLayerSnapshot(19))
            state.snapshotRows[1] = second
            state.snapshotRows[1].uuid = first.uuid
            XCTAssertThrowsError(try session.labLayerSnapshot(19))
            state.snapshotRows[1] = second
            state.snapshotRows[1].uuid = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            XCTAssertThrowsError(try session.labLayerSnapshot(19))
            state.snapshotRows[1] = second
            state.snapshotRows[1].layer.id = 0
            XCTAssertThrowsError(try session.labLayerSnapshot(19))
            state.snapshotRows[1] = second
            state.status = GLIMS_STATUS_UNSUPPORTED
            XCTAssertThrowsError(try session.labLayerSnapshot(19))
        }
    }

    func testOlderGuardPagePrefixRefusesGuardedCallButKeepsOrdinaryChange() throws {
        try withSession(configure: {
            $0.struct_size = UInt32(MemoryLayout<GlimsEngineAPI>.offset(of: \.image_change_lab_layer_properties)!)
        }, guardedPrefix: true) { session, producer in
            XCTAssertFalse(session.supportsLabLayerPropertyChange)
            XCTAssertThrowsError(try session.changeLabLayer(19, target: target, change: change))
            XCTAssertEqual(producer.guardedCalls, 0)
            try session.changeLayer(17, image: 19, change)
            XCTAssertEqual(producer.ordinaryCalls, 1)
        }
    }

    func testMissingGuardedSlotRefusesWithoutCallingOrdinaryChange() throws {
        try withSession(configure: { $0.image_change_lab_layer_properties = nil }) { session, producer in
            XCTAssertFalse(session.supportsLabLayerPropertyChange)
            XCTAssertThrowsError(try session.changeLabLayer(19, target: target, change: change))
            XCTAssertEqual(producer.ordinaryCalls, 0)
            XCTAssertEqual(producer.guardedCalls, 0)
        }
    }

    func testIdentityIsRequiredButColorFillIsNot() throws {
        try withSession(configure: { $0.image_lab_layer_identity = nil }) { session, producer in
            XCTAssertFalse(session.supportsLabLayerPropertyChange)
            XCTAssertThrowsError(try session.changeLabLayer(19, target: target, change: change))
            XCTAssertEqual(producer.ordinaryCalls, 0)
        }
        try withSession(configure: { $0.image_fill_lab_layer_srgb = nil }) { session, _ in
            XCTAssertFalse(session.supportsLabLayerColorFill)
            XCTAssertTrue(session.supportsLabLayerPropertyChange)
            XCTAssertEqual(try session.labLayerPropertyTarget(19, root: 17), target)
        }
        try withSession(configure: {
            $0.image_lab_layer_identity = { _, _, _, result in
                result?.pointee.uuid = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                return GLIMS_STATUS_OK
            }
        }) { session, _ in
            XCTAssertThrowsError(try session.labLayerPropertyTarget(19, root: 17))
        }
    }

    func testGuardedChangeSendsCapturedIdentityAndPropagatesNativeError() throws {
        let producer = Producer()
        try withSession(producer) { session, state in
            XCTAssertTrue(session.supportsLabLayerPropertyChange)
            try session.changeLabLayer(19, target: target, change: change)
            XCTAssertEqual(state.guardedCalls, 1)
            XCTAssertEqual(state.ordinaryCalls, 0)
            XCTAssertEqual(state.image, 19)
            XCTAssertEqual(state.settings?.struct_size, UInt32(MemoryLayout<GlimsLabLayerPropertyChange>.size))
            XCTAssertEqual(state.settings?.root, 17)
            XCTAssertEqual(state.settings.map { UUID(uuid: $0.uuid) }, target.uuid)
            XCTAssertEqual(state.settings?.change.struct_size, UInt32(MemoryLayout<GlimsLayerChange>.size))
            XCTAssertEqual(state.settings?.change.properties, GLIMS_LAYER_VISIBLE.rawValue | GLIMS_LAYER_OPACITY.rawValue)
            XCTAssertEqual(state.settings?.change.visible, false)
            XCTAssertEqual(state.settings?.change.opacity, 0.375)
            try session.changeLabLayer(19, target: target, change: .init(name: "Über layer"))
            XCTAssertEqual(state.settings?.change.properties, GLIMS_LAYER_NAME.rawValue)
            var name = try XCTUnwrap(state.settings?.change.name)
            let text = withUnsafeBytes(of: &name) { bytes in
                String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
            }
            XCTAssertEqual(text, "Über layer")
            state.status = GLIMS_STATUS_INVALID_ARGUMENT
            state.message = "The captured Lab layer has changed."
            XCTAssertThrowsError(try session.changeLabLayer(19, target: target, change: change)) {
                guard let error = $0 as? EngineSession.EngineError else { return XCTFail("Unexpected error: \($0)") }
                XCTAssertEqual(error.status, Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue))
                XCTAssertEqual(error.message, "The captured Lab layer has changed.")
            }
            XCTAssertEqual(state.freed, 1)
        }
    }

    func testRecordedLayerPropertiesUseGuardedLabTarget() throws {
        try withSession { session, producer in
            let command = SemanticImageCommand.layerProperties(.init(change))
            try command.apply(session: session, image: 19, labLayerTarget: target)
            XCTAssertEqual(producer.guardedCalls, 1)
            XCTAssertEqual(producer.ordinaryCalls, 0)
            XCTAssertEqual(producer.settings.map { UUID(uuid: $0.uuid) }, target.uuid)
        }
    }
}
