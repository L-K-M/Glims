import CGlimsEngine
import Darwin
import XCTest
@testable import GlimsKit

final class InkBrushCaptureTransportTests: XCTestCase {
    private final class Producer {
        var calls: [String] = []
        var status = GLIMS_STATUS_OK
        var stopped = false
        var freed = 0
        var withMessage = false
        var cleared = true

        var returnedStroke: Int32 = 73
        var returnedResource: UInt64 = 901
        var resolveStatus = GLIMS_STATUS_OK

        var resolvedKind: UInt32?
        var resolvedName: String?
        var resolvedCollection: String??
        var resolvedInternal: Bool?

        var beginImage: Int32 = 0
        var beginResource: UInt64 = 0
        var beginTarget: GlimsInkStrokeTarget?
        var beginBrush: GlimsBrushSettings?
        var beginPacket: [GlimsStrokeSampleV2] = []
        var beginExpectedFingerprint: String?
        var factsBrushName: String?
        var factsBrushCollection: String??
        var factsBrushInternal = false
        var factsFingerprint: String?

        static func from(_ engine: OpaquePointer?) -> Producer {
            Unmanaged<Producer>.fromOpaque(UnsafeRawPointer(engine!)).takeUnretainedValue()
        }

        func clearAndMaybeFail(_ error: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> GlimsStatus {
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

        func capturePacket(_ packet: UnsafePointer<GlimsStrokePacketV2>?) {
            guard let packet else { beginPacket = []; return }
            let p = packet.pointee
            guard p.count > 0, let samples = p.samples else { beginPacket = []; return }
            let stride = Int(p.sample_stride)
            beginPacket = (0..<Int(p.count)).map { index in
                samples.load(fromByteOffset: index * stride, as: GlimsStrokeSampleV2.self)
            }
        }

        func fillFacts(_ facts: UnsafeMutablePointer<GlimsStrokeCaptureFacts>?) {
            guard let facts else { return }
            facts.pointee.brush_internal = factsBrushInternal
            facts.pointee.brush_name = factsBrushName.map { makeOwnedString($0) }
            facts.pointee.brush_collection = factsBrushCollection.flatMap { $0.map(makeOwnedString) }
            facts.pointee.fingerprint = factsFingerprint.map { makeOwnedString($0) }
        }

        func makeOwnedString(_ value: String) -> UnsafeMutablePointer<CChar> {
            let prefix = MemoryLayout<UnsafeMutableRawPointer>.stride
            let bytes = Array(value.utf8) + [0]
            let memory = UnsafeMutableRawPointer.allocate(byteCount: prefix + bytes.count,
                                                          alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
            memory.storeBytes(of: Unmanaged.passUnretained(self).toOpaque(), as: UnsafeMutableRawPointer.self)
            bytes.withUnsafeBytes { memory.advanced(by: prefix).copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            return memory.advanced(by: prefix).assumingMemoryBound(to: CChar.self)
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
        api.resource_resolve = { engine, kind, name, collection, isInternal, handle, error in
            let p = Producer.from(engine)
            p.calls.append("resolve")
            p.resolvedKind = kind
            p.resolvedName = name.map { String(cString: $0) }
            p.resolvedCollection = .some(collection.map { String(cString: $0) })
            p.resolvedInternal = isInternal
            handle?.pointee = p.returnedResource
            return p.clearAndMaybeFail(error) == GLIMS_STATUS_OK ? p.resolveStatus : p.status
        }
        api.stroke_continue_v2 = { _, _, _, _ in GLIMS_STATUS_OK }
        api.stroke_end = { engine, stroke in
            let p = Producer.from(engine); p.calls.append("end:\(stroke)"); return GLIMS_STATUS_OK
        }
        api.stroke_begin_ink_with_capture_facts = { engine, image, brush, target, settings, packet, fingerprint, result, facts, error in
            let p = Producer.from(engine)
            p.calls.append("ink_capture_begin")
            p.beginImage = image
            p.beginResource = brush
            p.beginTarget = target?.pointee
            p.beginBrush = settings?.pointee
            p.beginPacket = []
            p.capturePacket(packet)
            p.beginExpectedFingerprint = fingerprint.map { String(cString: $0) }
            result?.pointee = p.returnedStroke
            p.fillFacts(facts)
            return p.clearAndMaybeFail(error)
        }
        api.stroke_cancel_ink = { engine, stroke in
            let p = Producer.from(engine); p.calls.append("cancel_ink:\(stroke)"); return GLIMS_STATUS_OK
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
            } else {
                try withUnsafePointer(to: &api, run)
            }
        }
        XCTAssertTrue(producer.stopped)
    }

    private func identity(role: EngineSession.InkRole = .cyan,
                          uuid: UUID = UUID(uuidString: "00010203-0405-0607-0809-0A0B0C0D0E0F")!,
                          mode: EngineSession.ColorMode = .cmyk) -> EngineSession.InkChannelIdentity {
        .init(colorMode: mode, role: role, ordinal: role == .unspecified ? 2 : UInt32(role.rawValue - 1),
              count: mode == .cmyk ? 4 : 5, uuid: uuid)
    }

    private func brush(identity: EngineSession.ResourceIdentity? = nil,
                       tool: EngineSession.Brush.Tool = .paintbrush) -> EngineSession.Brush {
        var b = EngineSession.Brush(tool: tool, size: 24, opacity: 0.75, red: 0.2, green: 0.4, blue: 0.6, hardness: 0.5)
        b.resource = identity
        return b
    }

    private func resource(name: String = "2. Hardness 050", collection: String? = "Glims", isInternal: Bool = true) -> EngineSession.ResourceIdentity {
        .init(name: name, collection: collection, isInternal: isInternal)
    }

    private func sample(rotation: Double? = nil, tangent: Double? = nil) -> EngineSession.StrokeSampleV2 {
        .init(point: .init(x: 12.5, y: 34.25, pressure: 0.625, xTilt: -0.25, yTilt: 0.5, timeMilliseconds: 17),
              rotationTurns: rotation, tangentialPressure: tangent)
    }

    private func assertStatus(_ status: GlimsStatus, _ body: () throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? EngineSession.EngineError)?.status, Int32(status.rawValue), file: file, line: line)
        }
    }

    func testGuardedLegacy207AndMissingCaptureRefuseWithoutNativeCalls() throws {
        let legacy207 = MemoryLayout<GlimsEngineAPI>.offset(of: \.stroke_begin_ink_with_capture_facts)!
        let partial208 = MemoryLayout<GlimsEngineAPI>.offset(of: \.stroke_cancel_ink)!
        for prefix in [legacy207, partial208] {
            try withSession(configure: { $0.struct_size = UInt32(prefix) }, guarded: true) { session, p in
                XCTAssertFalse(session.supportsInkBrushCapture)
                self.assertStatus(GLIMS_STATUS_UNSUPPORTED) {
                    _ = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: self.identity(),
                                                            brush: self.brush(), first: self.sample())
                }
                self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { try session.cancelInkStroke(11) }
                XCTAssertTrue(p.calls.isEmpty)
            }
        }
        try withSession(configure: { $0.stroke_begin_ink_with_capture_facts = nil }) { session, p in
            XCTAssertFalse(session.supportsInkBrushCapture)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) {
                _ = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: self.identity(),
                                                        brush: self.brush(), first: self.sample())
            }
            XCTAssertTrue(p.calls.isEmpty)
        }
    }

    func testMissingContinueOrEndV2AndCancelRefuseWithoutNativeCalls() throws {
        try withSession(configure: { $0.stroke_continue_v2 = nil }) { session, p in
            XCTAssertFalse(session.supportsInkBrushCapture)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) {
                _ = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: self.identity(),
                                                        brush: self.brush(), first: self.sample())
            }
            XCTAssertTrue(p.calls.isEmpty)
        }
        try withSession(configure: { $0.stroke_end = nil }) { session, p in
            XCTAssertFalse(session.supportsInkBrushCapture)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) {
                _ = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: self.identity(),
                                                        brush: self.brush(), first: self.sample())
            }
            XCTAssertTrue(p.calls.isEmpty)
        }
        try withSession(configure: { $0.stroke_cancel_ink = nil }) { session, p in
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { try session.cancelInkStroke(11) }
            XCTAssertTrue(p.calls.isEmpty)
        }
    }

    func testFullCapturePassesTargetBrushV2AxesFingerprintAndResolvesExpectedBrush() throws {
        let expectedBrush = resource(name: "Expected", collection: "Pack", isInternal: false)
        let fingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        try withSession { session, p in
            p.factsBrushName = expectedBrush.name
            p.factsBrushCollection = .some(expectedBrush.collection)
            p.factsBrushInternal = expectedBrush.isInternal
            p.factsFingerprint = fingerprint
            let ident = identity(role: .magenta)
            let result = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: ident,
                                                             brush: brush(identity: resource(name: "Different")),
                                                             first: sample(rotation: 0.875, tangent: -0.375),
                                                             expected: .init(brush: expectedBrush, fingerprint: fingerprint))

            XCTAssertEqual(result.stroke, 73)
            XCTAssertEqual(result.facts, .init(brush: expectedBrush, fingerprint: fingerprint))
            XCTAssertEqual(p.calls, ["resolve", "ink_capture_begin"])
            XCTAssertEqual(p.resolvedName, expectedBrush.name)
            XCTAssertEqual(p.resolvedCollection, .some(expectedBrush.collection))
            XCTAssertEqual(p.resolvedInternal, expectedBrush.isInternal)
            XCTAssertEqual(p.beginImage, 9)
            XCTAssertEqual(p.beginResource, 901)
            XCTAssertEqual(p.beginExpectedFingerprint, fingerprint)
            let target = try XCTUnwrap(p.beginTarget)
            XCTAssertEqual(Int(target.struct_size), MemoryLayout<GlimsInkStrokeTarget>.size)
            XCTAssertEqual(target.channel, 4)
            XCTAssertEqual(target.color_mode, GLIMS_COLOR_MODE_CMYK.rawValue)
            XCTAssertEqual(target.role, GLIMS_INK_ROLE_MAGENTA.rawValue)
            XCTAssertEqual(UUID(uuid: target.uuid), ident.uuid)
            let settings = try XCTUnwrap(p.beginBrush)
            XCTAssertEqual(Int(settings.struct_size), MemoryLayout<GlimsBrushSettings>.size)
            XCTAssertEqual(settings.tool, 0)
            XCTAssertEqual(settings.size, 24)
            XCTAssertEqual(settings.opacity, 0.75)
            XCTAssertEqual(settings.red, 0.2)
            XCTAssertEqual(settings.green, 0.4)
            XCTAssertEqual(settings.blue, 0.6)
            XCTAssertEqual(settings.hardness, 0.5)
            XCTAssertTrue(settings.pressure_size)
            let packet = try XCTUnwrap(p.beginPacket.first)
            XCTAssertEqual(packet.flags, UInt32(GLIMS_STROKE_SAMPLE_HAS_ROTATION.rawValue | GLIMS_STROKE_SAMPLE_HAS_TANGENTIAL_PRESSURE.rawValue))
            XCTAssertEqual(packet.x, 12.5)
            XCTAssertEqual(packet.y, 34.25)
            XCTAssertEqual(packet.pressure, 0.625)
            XCTAssertEqual(packet.xtilt, -0.25)
            XCTAssertEqual(packet.ytilt, 0.5)
            XCTAssertEqual(packet.time_ms, 17)
            XCTAssertEqual(packet.rotation_turns, 0.875)
            XCTAssertEqual(packet.tangential_pressure, -0.375)
            XCTAssertEqual(p.freed, 3)
        }
    }

    func testAbsentOptionalAxesUseNoFlagsAndNilFactsAcceptedWhenLive() throws {
        let fingerprint = String(repeating: "a", count: 64)
        try withSession { session, p in
            let result = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: identity(),
                                                             brush: brush(), first: sample())
            XCTAssertEqual(result.stroke, 73)
            XCTAssertNil(result.facts)
            let native = try XCTUnwrap(p.beginPacket.first)
            XCTAssertEqual(native.flags, 0)
            XCTAssertEqual(native.rotation_turns, 0)
            XCTAssertEqual(native.tangential_pressure, 0)
        }
        try withSession { session, p in
            p.factsBrushName = "Loose"
            p.factsBrushCollection = .some(nil)
            p.factsBrushInternal = false
            p.factsFingerprint = fingerprint
            let expected = EngineSession.StrokeCaptureFacts(brush: .init(name: "Loose", collection: nil, isInternal: false), fingerprint: fingerprint)
            let result = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: identity(),
                                                             brush: brush(), first: sample(),
                                                             expected: expected)
            XCTAssertEqual(result.facts, expected)
            XCTAssertEqual(p.freed, 2)
        }
    }

    func testExplicitZeroAxesAndEmptyCollectionRemainPresent() throws {
        try withSession { session, p in
            p.factsBrushName = "Empty collection"
            p.factsBrushCollection = .some("")
            p.factsFingerprint = String(repeating: "c", count: 64)
            let result = try session.beginInkStrokeCapturing(image: 9, channel: 4,
                identity: identity(role: .unspecified, mode: .multichannel), brush: brush(),
                first: sample(rotation: 0, tangent: 0))
            XCTAssertEqual(result.facts?.brush.collection, "")
            let packet = try XCTUnwrap(p.beginPacket.first)
            XCTAssertEqual(packet.flags, 3)
            XCTAssertEqual(packet.rotation_turns, 0)
            XCTAssertEqual(packet.tangential_pressure, 0)
            XCTAssertEqual(p.beginTarget?.color_mode, GLIMS_COLOR_MODE_MULTICHANNEL.rawValue)
            XCTAssertEqual(p.beginTarget?.role, GLIMS_INK_ROLE_UNSPECIFIED.rawValue)
            XCTAssertEqual(p.freed, 3)
        }
    }

    func testInvalidInputsAndInvalidFingerprintMakeZeroNativeCalls() throws {
        try withSession { session, p in
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.beginInkStrokeCapturing(image: 0, channel: 4, identity: self.identity(), brush: self.brush(), first: self.sample())
            }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.beginInkStrokeCapturing(image: 9, channel: 0, identity: self.identity(), brush: self.brush(), first: self.sample())
            }
            let badId = EngineSession.InkChannelIdentity(colorMode: .rgb, role: .cyan, ordinal: 0, count: 4, uuid: self.identity().uuid)
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: badId, brush: self.brush(), first: self.sample())
            }
            var badBrush = self.brush(); badBrush.size = 0
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: self.identity(), brush: badBrush, first: self.sample())
            }
            let badSample = EngineSession.StrokeSampleV2(point: .init(x: 1, y: 1, pressure: 2, xTilt: 0, yTilt: 0, timeMilliseconds: 0), rotationTurns: nil, tangentialPressure: nil)
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: self.identity(), brush: self.brush(), first: badSample)
            }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: self.identity(), brush: self.brush(), first: self.sample(),
                                                        expected: .init(brush: self.resource(), fingerprint: "not-hex"))
            }
            XCTAssertTrue(p.calls.isEmpty)
        }
    }

    func testExplicitExpectedResolvedIdMustBeNonzero() throws {
        try withSession { session, p in
            p.returnedResource = 0
            self.assertStatus(GLIMS_STATUS_NOT_FOUND) {
                _ = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: self.identity(),
                                                        brush: self.brush(), first: self.sample(),
                                                        expected: .init(brush: self.resource(), fingerprint: String(repeating: "b", count: 64)))
            }
            XCTAssertEqual(p.calls, ["resolve"])
        }
    }

    func testNativeFailureAndTypedCancelPropagateAndFreeFactStrings() throws {
        try withSession { session, p in
            p.status = GLIMS_STATUS_BUSY
            p.withMessage = true
            p.returnedStroke = 0
            p.factsBrushName = "Transient"
            p.factsBrushCollection = .some("Temp")
            p.factsFingerprint = String(repeating: "e", count: 64)
            self.assertStatus(GLIMS_STATUS_BUSY) {
                _ = try session.beginInkStrokeCapturing(image: 9, channel: 4, identity: self.identity(),
                                                        brush: self.brush(), first: self.sample())
            }
            XCTAssertEqual(p.calls, ["ink_capture_begin"])
            XCTAssertTrue(p.cleared)
            XCTAssertEqual(p.freed, 4)
            try session.cancelInkStroke(55)
            XCTAssertEqual(p.calls.last, "cancel_ink:55")
        }
    }
}
