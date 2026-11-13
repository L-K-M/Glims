import CGlimsEngine
import Darwin
import XCTest
@testable import GlimsKit

final class LabCurvesTransportTests: XCTestCase {
    private final class Producer {
        var calls: [String] = []
        var image: Int32 = 0
        var token: UInt64 = 0
        var target: GlimsLabSnapshotTarget?
        var settings: GlimsLabCurvesSettings?
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
        api.image_curves_lab = { engine, image, settings, error in
            let p = Producer.from(engine); p.settings = settings?.pointee
            return p.record("direct", image, error)
        }
        api.image_lab_snapshot_begin = { engine, image, target, token, error in
            let p = Producer.from(engine); p.target = target?.pointee
            p.cleared = p.cleared && token?.pointee == 0
            token?.pointee = p.returnedToken
            return p.record("begin", image, error)
        }
        api.image_lab_snapshot_curves = { engine, image, token, settings, result, error in
            let p = Producer.from(engine); p.token = token; p.settings = settings?.pointee
            p.cleared = p.cleared && result?.pointee == 0
            result?.pointee = p.returnedImage
            return p.record("render", image, error)
        }
        api.image_lab_snapshot_apply_curves = { engine, image, token, settings, error in
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
    private func assertSettings(_ native: GlimsLabCurvesSettings?, axis: EngineSession.LabAxis, samples: [Double]) throws {
        let native = try XCTUnwrap(native)
        XCTAssertEqual(Int(native.struct_size), MemoryLayout<GlimsLabCurvesSettings>.size)
        XCTAssertEqual(native.axis, axis.id)
        XCTAssertEqual(native.role, axis.role.rawValue)
        XCTAssertEqual(UUID(uuid: native.uuid), axis.uuid)
        XCTAssertEqual(withUnsafeBytes(of: native.samples) { Array($0.bindMemory(to: Double.self)) }, samples)
    }

    func testExactIdentityAndOwnedTables() {
        let expected = (0..<256).map { Double($0) / 255 }
        XCTAssertEqual(EngineSession.LabCurvesSettings().samples, expected)
        var source = expected
        let value = EngineSession.LabCurvesSettings(samples: source)
        source[0] = 0.25
        XCTAssertEqual(value.samples, expected)
        XCTAssertTrue(EngineSession.LabCurvesSettings(samples: Array(expected.reversed())).isValid)
        for count in [0, 255, 257] {
            XCTAssertFalse(EngineSession.LabCurvesSettings(samples: Array(repeating: 0.5, count: count)).isValid)
        }
        for bad in [Double.nan, .infinity, -.infinity, -Double.leastNonzeroMagnitude, 1.0000000001] {
            var samples = expected; samples[129] = bad
            XCTAssertFalse(EngineSession.LabCurvesSettings(samples: samples).isValid)
        }
    }

    func testEachPhysicalRoleAndExactTableCrossTheBoundary() throws {
        for role in EngineSession.LabAxisRole.allCases {
            try withSession { session, p in
                let target = self.axis(role)
                let samples = (0..<256).map { Double(($0 * 47) % 256) / 255 }
                let settings = EngineSession.LabCurvesSettings(samples: samples)
                XCTAssertTrue(session.supportsLabCurves)
                XCTAssertTrue(session.supportsLabCurveSnapshots)
                try session.applyLabCurves(9, axis: target, settings: settings)
                try self.assertSettings(p.settings, axis: target, samples: samples)
                XCTAssertEqual(p.image, 9)
                let token = try session.beginLabCurvesSnapshot(9, axis: target)
                XCTAssertEqual(token, 77)
                let sent = try XCTUnwrap(p.target)
                XCTAssertEqual(Int(sent.struct_size), MemoryLayout<GlimsLabSnapshotTarget>.size)
                XCTAssertEqual(sent.axis, target.id); XCTAssertEqual(sent.role, role.rawValue)
                XCTAssertEqual(UUID(uuid: sent.uuid), target.uuid)
                XCTAssertEqual(try session.renderLabCurvesSnapshot(9, token: token, axis: target, settings: settings), 91)
                try self.assertSettings(p.settings, axis: target, samples: samples)
                XCTAssertEqual(p.token, token)
                try session.applyLabCurvesSnapshot(9, token: token, axis: target, settings: settings)
                try self.assertSettings(p.settings, axis: target, samples: samples)
                XCTAssertEqual(p.calls, ["direct", "begin", "render", "apply"])
                // Transport does not manufacture an extra end after successful apply.
                try session.endLabCurvesSnapshot(9, token: 88)
                XCTAssertEqual(p.calls.last, "end"); XCTAssertEqual(p.token, 88)
                XCTAssertTrue(p.cleared)
            }
        }
    }

    func testShortFacadeAndMissingSlotsRefuseWithoutDispatch() throws {
        let direct = MemoryLayout<GlimsEngineAPI>.offset(of: \.image_curves_lab)!
        try withSession(configure: { $0.struct_size = UInt32(direct) }, guarded: true) { session, p in
            XCTAssertFalse(session.supportsLabCurves)
            XCTAssertFalse(session.supportsLabCurveSnapshots)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { try session.applyLabCurves(9, axis: self.axis(), settings: .init()) }
            XCTAssertTrue(p.calls.isEmpty)
        }
        let end = MemoryLayout<GlimsEngineAPI>.offset(of: \.image_lab_snapshot_end)!
        try withSession(configure: { $0.struct_size = UInt32(end) }, guarded: true) { session, p in
            XCTAssertTrue(session.supportsLabCurves)
            XCTAssertFalse(session.supportsLabCurveSnapshots)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { _ = try session.beginLabCurvesSnapshot(9, axis: self.axis()) }
            XCTAssertTrue(p.calls.isEmpty)
        }
        for missing in 1..<16 {
            try withSession(configure: {
                if missing & 1 != 0 { $0.image_lab_snapshot_begin = nil }
                if missing & 2 != 0 { $0.image_lab_snapshot_curves = nil }
                if missing & 4 != 0 { $0.image_lab_snapshot_apply_curves = nil }
                if missing & 8 != 0 { $0.image_lab_snapshot_end = nil }
            }) { session, p in
                XCTAssertTrue(session.supportsLabCurves)
                XCTAssertFalse(session.supportsLabCurveSnapshots)
                self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { _ = try session.beginLabCurvesSnapshot(9, axis: self.axis()) }
                XCTAssertTrue(p.calls.isEmpty)
            }
        }
        try withSession(configure: { $0.image_curves_lab = nil }) { session, p in
            XCTAssertFalse(session.supportsLabCurves)
            XCTAssertTrue(session.supportsLabCurveSnapshots, "Snapshots do not depend on direct or ink/RGB slots")
            _ = try session.beginLabCurvesSnapshot(9, axis: self.axis())
            XCTAssertEqual(p.calls, ["begin"])
        }
    }

    func testMalformedRequestsDoNotDispatch() throws {
        try withSession { session, p in
            for target in [self.axis(id: 0), self.axis(selected: false),
                           .init(id: 13, role: .a, isSelected: true, uuid: UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)), name: "a")] {
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.applyLabCurves(9, axis: target, settings: .init()) }
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { _ = try session.beginLabCurvesSnapshot(9, axis: target) }
            }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.applyLabCurves(0, axis: self.axis(), settings: .init()) }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { _ = try session.renderLabCurvesSnapshot(9, token: 0, axis: self.axis(), settings: .init()) }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.endLabCurvesSnapshot(0, token: 77) }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.endLabCurvesSnapshot(9, token: 0) }
            for samples in [[Double](), [.nan], Array(repeating: 1.1, count: 256)] {
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.applyLabCurves(9, axis: self.axis(), settings: .init(samples: samples)) }
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { _ = try session.renderLabCurvesSnapshot(9, token: 77, axis: self.axis(), settings: .init(samples: samples)) }
                self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.applyLabCurvesSnapshot(9, token: 77, axis: self.axis(), settings: .init(samples: samples)) }
            }
            XCTAssertTrue(p.calls.isEmpty)
        }
    }

    func testMissingReturnedHandlesAndNativeFailures() throws {
        try withSession { session, p in
            p.returnedToken = 0
            self.assertStatus(GLIMS_STATUS_FAILED) { _ = try session.beginLabCurvesSnapshot(9, axis: self.axis()) }
            for bad in [Int32(0), -1, 9] {
                p.returnedImage = bad
                self.assertStatus(GLIMS_STATUS_FAILED) { _ = try session.renderLabCurvesSnapshot(9, token: 77, axis: self.axis(), settings: .init()) }
            }
            p.status = GLIMS_STATUS_BUSY; p.withMessage = true
            self.assertStatus(GLIMS_STATUS_BUSY) { try session.applyLabCurves(9, axis: self.axis(), settings: .init()) }
            self.assertStatus(GLIMS_STATUS_BUSY) { _ = try session.beginLabCurvesSnapshot(9, axis: self.axis()) }
            self.assertStatus(GLIMS_STATUS_BUSY) { _ = try session.renderLabCurvesSnapshot(9, token: 77, axis: self.axis(), settings: .init()) }
            self.assertStatus(GLIMS_STATUS_BUSY) { try session.applyLabCurvesSnapshot(9, token: 77, axis: self.axis(), settings: .init()) }
            XCTAssertEqual(p.freed, 4)
            self.assertStatus(GLIMS_STATUS_BUSY) { try session.endLabCurvesSnapshot(9, token: 77) }
        }
    }
}
