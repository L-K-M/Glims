import CGlimsEngine
import Darwin
import XCTest
@testable import GlimsKit

final class LabLevelsTransportTests: XCTestCase {
    private final class Producer {
        var calls: [String] = []
        var image: Int32 = 0
        var token: UInt64 = 0
        var target: GlimsLabSnapshotTarget?
        var settings: GlimsLabLevelsSettings?
        var status = GLIMS_STATUS_OK
        var returnedToken: UInt64 = 77
        var returnedImage: Int32 = 91
        var stopped = false
        var cleared = true
        var freed = 0
        var withMessage = false

        static func from(_ engine: OpaquePointer?) -> Producer {
            Unmanaged<Producer>.fromOpaque(UnsafeRawPointer(engine!)).takeUnretainedValue()
        }
        func record(_ call: String, _ image: Int32, _ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> GlimsStatus {
            calls.append(call); self.image = image
            if let error {
                cleared = cleared && error.pointee == nil
                if withMessage {
                    let prefix = MemoryLayout<UnsafeMutableRawPointer>.stride
                    let bytes = Array("native refusal".utf8) + [0]
                    let memory = UnsafeMutableRawPointer.allocate(byteCount: prefix + bytes.count,
                                                                 alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
                    memory.storeBytes(of: Unmanaged.passUnretained(self).toOpaque(), as: UnsafeMutableRawPointer.self)
                    bytes.withUnsafeBytes { memory.advanced(by: prefix).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
                    error.pointee = memory.advanced(by: prefix).assumingMemoryBound(to: CChar.self)
                }
            }
            return status
        }
    }

    private func table() -> GlimsEngineAPI {
        var api = GlimsEngineAPI()
        api.api_version = GLIMS_ENGINE_API_VERSION
        api.struct_size = UInt32(MemoryLayout<GlimsEngineAPI>.size)
        api.start = { config, result, error in
            error?.pointee = nil
            guard let directory = config?.pointee.user_directory,
                  let address = UInt(URL(fileURLWithPath: String(cString: directory)).lastPathComponent),
                  let pointer = OpaquePointer(bitPattern: address) else { return GLIMS_STATUS_INVALID_ARGUMENT }
            result?.pointee = pointer
            return GLIMS_STATUS_OK
        }
        api.stop = { Producer.from($0).stopped = true }
        api.engine_version = { _ in nil }
        api.free_string = { value in
            guard let value else { return }
            let base = UnsafeMutableRawPointer(value).advanced(by: -MemoryLayout<UnsafeMutableRawPointer>.stride)
            let owner = Unmanaged<Producer>.fromOpaque(base.load(as: UnsafeMutableRawPointer.self)).takeUnretainedValue()
            owner.freed += 1
            base.deallocate()
        }
        api.image_lab_axes = { _, _, _ in GLIMS_STATUS_UNSUPPORTED }
        api.image_levels_lab = { engine, image, settings, error in
            let p = Producer.from(engine); p.settings = settings?.pointee
            return p.record("direct", image, error)
        }
        api.image_lab_snapshot_begin = { engine, image, target, token, error in
            let p = Producer.from(engine); p.target = target?.pointee
            p.cleared = p.cleared && token?.pointee == 0
            token?.pointee = p.returnedToken
            return p.record("begin", image, error)
        }
        api.image_lab_snapshot_levels = { engine, image, token, settings, result, error in
            let p = Producer.from(engine); p.token = token; p.settings = settings?.pointee
            p.cleared = p.cleared && result?.pointee == 0
            result?.pointee = p.returnedImage
            return p.record("render", image, error)
        }
        api.image_lab_snapshot_apply_levels = { engine, image, token, settings, error in
            let p = Producer.from(engine); p.token = token; p.settings = settings?.pointee
            return p.record("apply", image, error)
        }
        api.image_lab_snapshot_end = { engine, image, token in
            let p = Producer.from(engine); p.token = token
            return p.record("end", image, nil)
        }
        return api
    }

    private func withSession(configure: (inout GlimsEngineAPI) -> Void = { _ in },
                             guarded: Bool = false, _ body: (EngineSession, Producer) throws -> Void) throws {
        let producer = Producer()
        var api = table(); configure(&api)
        let directory = URL(fileURLWithPath: "/fake-engine/\(UInt(bitPattern: Unmanaged.passUnretained(producer).toOpaque()))")
        func run(_ pointer: UnsafePointer<GlimsEngineAPI>) throws {
            let session = try EngineSession.start(api: pointer, userDirectory: directory,
                                                  cacheDirectory: directory, onEvent: { _ in })
            defer { session.stop() }
            try body(session, producer)
        }
        try withExtendedLifetime(producer) {
            if guarded {
                let page = Int(getpagesize()), count = Int(api.struct_size)
                XCTAssertLessThan(count, page)
                let memory = mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0)!
                guard memory != MAP_FAILED else { throw POSIXError(.ENOMEM) }
                defer { munmap(memory, page * 2) }
                guard mprotect(memory.advanced(by: page), page, PROT_NONE) == 0 else { throw POSIXError(.EACCES) }
                let prefix = memory.advanced(by: page - count)
                withUnsafeBytes(of: &api) { prefix.copyMemory(from: $0.baseAddress!, byteCount: count) }
                try run(UnsafePointer(prefix.assumingMemoryBound(to: GlimsEngineAPI.self)))
            } else { try withUnsafePointer(to: &api, run) }
        }
        XCTAssertTrue(producer.stopped)
    }

    private func axis(_ role: EngineSession.LabAxisRole = .a, id: Int32 = 13, selected: Bool = true) -> EngineSession.LabAxis {
        .init(id: id, role: role, isSelected: selected,
              uuid: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!, name: "Renamed physical axis")
    }
    private func assertStatus(_ status: GlimsStatus, _ body: () throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? EngineSession.EngineError)?.status, Int32(status.rawValue), file: file, line: line)
        }
    }
    private func assertSettings(_ native: GlimsLabLevelsSettings?, axis: EngineSession.LabAxis,
                                expected: EngineSession.LabLevelsSettings) throws {
        let n = try XCTUnwrap(native)
        XCTAssertEqual(Int(n.struct_size), MemoryLayout<GlimsLabLevelsSettings>.size)
        XCTAssertEqual(n.axis, axis.id); XCTAssertEqual(n.role, axis.role.rawValue)
        XCTAssertEqual(UUID(uuid: n.uuid), axis.uuid)
        XCTAssertEqual(n.value.low_input, expected.value.lowInput)
        XCTAssertEqual(n.value.high_input, expected.value.highInput)
        XCTAssertEqual(n.value.gamma, expected.value.gamma)
        XCTAssertEqual(n.value.low_output, expected.value.lowOutput)
        XCTAssertEqual(n.value.high_output, expected.value.highOutput)
        XCTAssertEqual(n.clamp_input, expected.clampInput ? 1 : 0)
        XCTAssertEqual(n.clamp_output, expected.clampOutput ? 1 : 0)
    }

    func testExactSettingsAndCapturedAxisThroughDirectAndSnapshotCalls() throws {
        for role in EngineSession.LabAxisRole.allCases {
            try withSession { session, p in
                let a = self.axis(role)
                let value = EngineSession.LabLevelsSettings(value: .init(lowInput: 0.123456789123,
                    highInput: 0.875, gamma: 1.8, lowOutput: 0.875, highOutput: 0.25),
                    clampInput: true, clampOutput: false)
                XCTAssertTrue(session.supportsLabLevels)
                XCTAssertTrue(session.supportsLabLevelSnapshots)
                try session.applyLabLevels(9, axis: a, settings: value)
                try self.assertSettings(p.settings, axis: a, expected: value)
                XCTAssertEqual(p.image, 9)
                let token = try session.beginLabLevelsSnapshot(9, axis: a)
                XCTAssertEqual(token, 77)
                let sent = try XCTUnwrap(p.target)
                XCTAssertEqual(Int(sent.struct_size), MemoryLayout<GlimsLabSnapshotTarget>.size)
                XCTAssertEqual(sent.axis, a.id); XCTAssertEqual(sent.role, role.rawValue)
                XCTAssertEqual(UUID(uuid: sent.uuid), a.uuid)
                XCTAssertEqual(try session.renderLabLevelsSnapshot(9, token: token, axis: a, settings: value), 91)
                try self.assertSettings(p.settings, axis: a, expected: value)
                try session.applyLabLevelsSnapshot(9, token: token, axis: a, settings: value)
                try self.assertSettings(p.settings, axis: a, expected: value)
                XCTAssertEqual(p.token, token)
                XCTAssertEqual(p.calls, ["direct", "begin", "render", "apply"])
                try session.endLabLevelsSnapshot(9, token: 88)
                XCTAssertEqual(p.calls.last, "end"); XCTAssertEqual(p.token, 88)
                XCTAssertTrue(p.cleared)
            }
        }
    }

    func testShortFacadeAndMissingSlotsRefuseBeforeDispatch() throws {
        let direct = MemoryLayout<GlimsEngineAPI>.offset(of: \.image_levels_lab)!
        try withSession(configure: { $0.struct_size = UInt32(direct) }, guarded: true) { session, p in
            XCTAssertFalse(session.supportsLabLevels); XCTAssertFalse(session.supportsLabLevelSnapshots)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { try session.applyLabLevels(9, axis: self.axis(), settings: .init()) }
            XCTAssertTrue(p.calls.isEmpty)
        }
        let last = MemoryLayout<GlimsEngineAPI>.offset(of: \.image_lab_snapshot_apply_levels)!
        try withSession(configure: { $0.struct_size = UInt32(last) }, guarded: true) { session, p in
            XCTAssertTrue(session.supportsLabLevels); XCTAssertFalse(session.supportsLabLevelSnapshots)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { _ = try session.beginLabLevelsSnapshot(9, axis: self.axis()) }
            XCTAssertTrue(p.calls.isEmpty)
        }
        for missing in 1..<16 {
            try withSession(configure: {
                if missing & 1 != 0 { $0.image_lab_snapshot_begin = nil }
                if missing & 2 != 0 { $0.image_lab_snapshot_levels = nil }
                if missing & 4 != 0 { $0.image_lab_snapshot_apply_levels = nil }
                if missing & 8 != 0 { $0.image_lab_snapshot_end = nil }
            }) { session, p in
                XCTAssertFalse(session.supportsLabLevelSnapshots)
                self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { _ = try session.beginLabLevelsSnapshot(9, axis: self.axis()) }
                XCTAssertTrue(p.calls.isEmpty)
            }
        }
        try withSession(configure: { $0.image_levels_lab = nil }) { session, p in
            XCTAssertFalse(session.supportsLabLevels)
            XCTAssertTrue(session.supportsLabLevelSnapshots, "Snapshots do not need the direct or Curves slots")
            _ = try session.beginLabLevelsSnapshot(9, axis: self.axis())
            XCTAssertEqual(p.calls, ["begin"])
        }
    }

    func testMalformedTargetsAndSettingsCannotReachProducer() throws {
        try withSession { session, p in
            for a in [self.axis(id: 0), self.axis(selected: false),
                      .init(id: 13, role: .a, isSelected: true, uuid: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)), name: "a")] {
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.applyLabLevels(9, axis: a, settings: .init()) }
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { _ = try session.beginLabLevelsSnapshot(9, axis: a) }
            }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.applyLabLevels(0, axis: self.axis(), settings: .init()) }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { _ = try session.renderLabLevelsSnapshot(9, token: 0, axis: self.axis(), settings: .init()) }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.endLabLevelsSnapshot(0, token: 77) }
            for bad in [Double.nan, .infinity, -.infinity, -0.1, 1.00001] {
                var invalid = EngineSession.LabLevelsSettings(); invalid.value.lowInput = bad
                XCTAssertFalse(invalid.isValid)
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.applyLabLevels(9, axis: self.axis(), settings: invalid) }
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { _ = try session.renderLabLevelsSnapshot(9, token: 77, axis: self.axis(), settings: invalid) }
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.applyLabLevelsSnapshot(9, token: 77, axis: self.axis(), settings: invalid) }
            }
            for bad in [Double.nan, .infinity, 0.0999999, 10.000001] {
                var invalid = EngineSession.LabLevelsSettings(); invalid.value.gamma = bad
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.applyLabLevels(9, axis: self.axis(), settings: invalid) }
            }
            XCTAssertTrue(p.calls.isEmpty)
        }
    }

    func testMissingReturnedHandlesAndNativeErrorOwnership() throws {
        try withSession { session, p in
            p.returnedToken = 0
            self.assertStatus(GLIMS_STATUS_FAILED) { _ = try session.beginLabLevelsSnapshot(9, axis: self.axis()) }
            for bad in [Int32(0), -1, 9] {
                p.returnedImage = bad
                self.assertStatus(GLIMS_STATUS_FAILED) { _ = try session.renderLabLevelsSnapshot(9, token: 77, axis: self.axis(), settings: .init()) }
            }
            p.status = GLIMS_STATUS_BUSY; p.withMessage = true
            self.assertStatus(GLIMS_STATUS_BUSY) { try session.applyLabLevels(9, axis: self.axis(), settings: .init()) }
            self.assertStatus(GLIMS_STATUS_BUSY) { _ = try session.beginLabLevelsSnapshot(9, axis: self.axis()) }
            self.assertStatus(GLIMS_STATUS_BUSY) { _ = try session.renderLabLevelsSnapshot(9, token: 77, axis: self.axis(), settings: .init()) }
            self.assertStatus(GLIMS_STATUS_BUSY) { try session.applyLabLevelsSnapshot(9, token: 77, axis: self.axis(), settings: .init()) }
            XCTAssertEqual(p.freed, 4)
            self.assertStatus(GLIMS_STATUS_BUSY) { try session.endLabLevelsSnapshot(9, token: 77) }
        }
    }
}
