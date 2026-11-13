import CGlimsEngine
import Darwin
import XCTest
@testable import GlimsKit

final class LabBrushCaptureTransportTests: XCTestCase {
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
        var beginSettings: GlimsLabBrushSettings?
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
        api.image_lab_axes = { engine, image, axes in
            let p = Producer.from(engine)
            p.calls.append("lab_axes")
            guard let axes else { return p.status }
            var out = GlimsLabAxes()
            out.struct_size = UInt32(MemoryLayout<GlimsLabAxes>.size)
            out.component = GLIMS_COLOR_COMPONENT_FLOAT.rawValue
            out.count = 3
            let rows: [GlimsLabAxisInfo] = [
                .init(id: 11, role: GLIMS_LAB_AXIS_LIGHTNESS.rawValue, selected: 1,
                      uuid: (0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15), name: (76,42,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
                .init(id: 12, role: GLIMS_LAB_AXIS_A.rawValue, selected: 0,
                      uuid: (1,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15), name: (97,42,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)),
                .init(id: 13, role: GLIMS_LAB_AXIS_B.rawValue, selected: 0,
                      uuid: (2,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15), name: (98,42,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
            ]
            out.axes = (rows[0], rows[1], rows[2])
            axes.pointee = out
            _ = image
            return GLIMS_STATUS_OK
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
        api.stroke_begin_lab = { engine, image, brush, settings, packet, result, error in
            let p = Producer.from(engine)
            p.calls.append("legacy_begin")
            p.beginImage = image
            p.beginResource = brush
            p.beginSettings = settings?.pointee
            p.capturePacket(packet)
            result?.pointee = p.returnedStroke
            return p.clearAndMaybeFail(error)
        }
        api.stroke_cancel_lab = { engine, stroke in
            let p = Producer.from(engine); p.calls.append("cancel:\(stroke)"); return GLIMS_STATUS_OK
        }
        api.stroke_continue_v2 = { _, _, _, _ in GLIMS_STATUS_OK }
        api.stroke_end = { engine, stroke in
            let p = Producer.from(engine); p.calls.append("end:\(stroke)"); return GLIMS_STATUS_OK
        }
        api.stroke_begin_lab_with_capture_facts = { engine, image, brush, settings, packet, fingerprint, result, facts, error in
            let p = Producer.from(engine)
            p.calls.append("capture_begin")
            p.beginImage = image
            p.beginResource = brush
            p.beginSettings = settings?.pointee
            p.capturePacket(packet)
            p.beginExpectedFingerprint = fingerprint.map { String(cString: $0) }
            result?.pointee = p.returnedStroke
            p.fillFacts(facts)
            return p.clearAndMaybeFail(error)
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

    private func axis() -> EngineSession.LabAxis {
        .init(id: 11, role: .lightness, isSelected: true,
              uuid: UUID(uuidString: "00010203-0405-0607-0809-0A0B0C0D0E0F")!, name: "L*")
    }

    private func brush(identity: EngineSession.ResourceIdentity? = nil) -> EngineSession.Brush {
        var brush = EngineSession.Brush(tool: .paintbrush, size: 24, opacity: 0.75, hardness: 0.5)
        brush.resource = identity
        return brush
    }

    private func identity(name: String = "2. Hardness 050", collection: String? = "Glims", isInternal: Bool = true) -> EngineSession.ResourceIdentity {
        .init(name: name, collection: collection, isInternal: isInternal)
    }

    private func sample(rotation: Double? = nil, tangent: Double? = nil, x: Double = 12.5, y: Double = 34.25) -> EngineSession.StrokeSampleV2 {
        .init(point: .init(x: x, y: y, pressure: 0.625, xTilt: -0.25, yTilt: 0.5, timeMilliseconds: 17),
              rotationTurns: rotation, tangentialPressure: tangent)
    }

    private func assertStatus(_ status: GlimsStatus, _ body: () throws -> Void,
                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) {
            XCTAssertEqual(($0 as? EngineSession.EngineError)?.status, Int32(status.rawValue), file: file, line: line)
        }
    }

    private func assertSettings(_ settings: GlimsLabBrushSettings?, axis: EngineSession.LabAxis,
                                value: Double, opacity: Double, size: Double, hardness: Double,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let settings = try XCTUnwrap(settings, file: file, line: line)
        XCTAssertEqual(Int(settings.struct_size), MemoryLayout<GlimsLabBrushSettings>.size, file: file, line: line)
        XCTAssertEqual(settings.axis, axis.id, file: file, line: line)
        XCTAssertEqual(settings.role, axis.role.rawValue, file: file, line: line)
        XCTAssertEqual(UUID(uuid: settings.uuid), axis.uuid, file: file, line: line)
        XCTAssertEqual(settings.value, value, file: file, line: line)
        XCTAssertEqual(settings.opacity, opacity, file: file, line: line)
        XCTAssertEqual(settings.size, size, file: file, line: line)
        XCTAssertEqual(settings.hardness, hardness, file: file, line: line)
    }

    func testShort206PrefixAndAbsentCaptureSlotReportUnavailable() throws {
        let slot = MemoryLayout<GlimsEngineAPI>.offset(of: \.stroke_begin_lab_with_capture_facts)!
        try withSession(configure: { $0.struct_size = UInt32(slot) }, guarded: true) { session, p in
            XCTAssertTrue(session.supportsLabBrush)
            XCTAssertFalse(session.supportsLabBrushCapture)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) {
                _ = try session.beginLabStrokeCapturing(image: 9, axis: self.axis(), value: 50,
                                                        brush: self.brush(), first: self.sample(),
                                                        expected: .init(brush: self.identity(), fingerprint: String(repeating: "a", count: 64)))
            }
            XCTAssertTrue(p.calls.isEmpty)
        }
        try withSession(configure: { $0.stroke_begin_lab_with_capture_facts = nil }) { session, p in
            XCTAssertFalse(session.supportsLabBrushCapture)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) {
                _ = try session.beginLabStrokeCapturing(image: 9, axis: self.axis(), value: 50,
                                                        brush: self.brush(), first: self.sample(),
                                                        expected: .init(brush: self.identity(), fingerprint: String(repeating: "b", count: 64)))
            }
            XCTAssertTrue(p.calls.isEmpty)
        }
    }

    func testLegacyLiveFallbackAllowedButExpectedFactsRefuseBeforeNativeCall() throws {
        let ident = identity(name: "Legacy", collection: nil, isInternal: false)
        try withSession(configure: { $0.stroke_begin_lab_with_capture_facts = nil }) { session, p in
            let result = try session.beginLabStrokeCapturing(image: 9, axis: self.axis(), value: 42.5,
                                                             brush: self.brush(identity: ident), first: self.sample())
            XCTAssertEqual(result.stroke, 73)
            XCTAssertNil(result.facts)
            XCTAssertEqual(p.calls, ["resolve", "legacy_begin"])
            XCTAssertEqual(p.resolvedKind, GLIMS_RESOURCE_BRUSH.rawValue)
            XCTAssertEqual(p.resolvedName, ident.name)
            XCTAssertEqual(p.resolvedCollection, .some(nil))
            XCTAssertEqual(p.resolvedInternal, ident.isInternal)
            XCTAssertEqual(p.beginResource, 901)

            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) {
                _ = try session.beginLabStrokeCapturing(image: 9, axis: self.axis(), value: 42.5,
                                                        brush: self.brush(identity: ident), first: self.sample(),
                                                        expected: .init(brush: ident, fingerprint: String(repeating: "c", count: 64)))
            }
            XCTAssertEqual(p.calls, ["resolve", "legacy_begin"], "expected replay must refuse before any native begin call")
        }
    }

    func testFullCapturePassesRequestPacketExpectedFingerprintAndReturnsOwnedFacts() throws {
        let capturedIdentity = identity(name: "Ink Mask", collection: "Lab", isInternal: true)
        let expectedFingerprint = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
        try withSession { session, p in
            p.factsBrushName = capturedIdentity.name
            p.factsBrushCollection = .some(capturedIdentity.collection)
            p.factsBrushInternal = capturedIdentity.isInternal
            p.factsFingerprint = expectedFingerprint
            let first = self.sample(rotation: 0.875, tangent: -0.375)
            let expected = EngineSession.StrokeCaptureFacts(brush: capturedIdentity, fingerprint: expectedFingerprint)
            let result = try session.beginLabStrokeCapturing(image: 9, axis: self.axis(), value: -12.25,
                                                             brush: self.brush(), first: first, expected: expected)

            XCTAssertEqual(result.stroke, 73)
            XCTAssertEqual(result.facts, expected)
            XCTAssertEqual(p.calls, ["resolve", "capture_begin"])
            XCTAssertEqual(p.resolvedKind, GLIMS_RESOURCE_BRUSH.rawValue)
            XCTAssertEqual(p.resolvedName, capturedIdentity.name)
            XCTAssertEqual(p.resolvedCollection, .some(capturedIdentity.collection))
            XCTAssertEqual(p.resolvedInternal, capturedIdentity.isInternal)
            XCTAssertEqual(p.beginImage, 9)
            XCTAssertEqual(p.beginResource, 901)
            XCTAssertEqual(p.beginExpectedFingerprint, expectedFingerprint)
            try self.assertSettings(p.beginSettings, axis: self.axis(), value: -12.25, opacity: 0.75, size: 24, hardness: 0.5)

            XCTAssertEqual(p.beginPacket.count, 1)
            let native = try XCTUnwrap(p.beginPacket.first)
            XCTAssertEqual(Int(native.struct_size), MemoryLayout<GlimsStrokeSampleV2>.size)
            XCTAssertEqual(native.flags, UInt32(GLIMS_STROKE_SAMPLE_HAS_ROTATION.rawValue | GLIMS_STROKE_SAMPLE_HAS_TANGENTIAL_PRESSURE.rawValue))
            XCTAssertEqual(native.x, 12.5)
            XCTAssertEqual(native.y, 34.25)
            XCTAssertEqual(native.pressure, 0.625)
            XCTAssertEqual(native.xtilt, -0.25)
            XCTAssertEqual(native.ytilt, 0.5)
            XCTAssertEqual(native.time_ms, 17)
            XCTAssertEqual(native.rotation_turns, 0.875)
            XCTAssertEqual(native.tangential_pressure, -0.375)
            XCTAssertTrue(p.cleared)
            XCTAssertEqual(p.freed, 3, "returned brush name, collection and fingerprint must be freed exactly once")
        }
    }

    func testOptionalAxesAreExplicitFlagsAndZeroValuesWhenAbsentOrZero() throws {
        try withSession { session, p in
            let result = try session.beginLabStrokeCapturing(image: 9, axis: self.axis(), value: 1,
                                                             brush: self.brush(), first: self.sample())
            XCTAssertEqual(result.stroke, 73)
            XCTAssertNil(result.facts)
            let absent = try XCTUnwrap(p.beginPacket.first)
            XCTAssertEqual(absent.flags, 0)
            XCTAssertEqual(absent.rotation_turns, 0)
            XCTAssertEqual(absent.tangential_pressure, 0)
        }
        try withSession { session, p in
            let result = try session.beginLabStrokeCapturing(image: 9, axis: self.axis(), value: 1,
                                                             brush: self.brush(), first: self.sample(rotation: 0, tangent: 0))
            XCTAssertEqual(result.stroke, 73)
            XCTAssertNil(result.facts)
            let presentZero = try XCTUnwrap(p.beginPacket.first)
            XCTAssertEqual(presentZero.flags, UInt32(GLIMS_STROKE_SAMPLE_HAS_ROTATION.rawValue | GLIMS_STROKE_SAMPLE_HAS_TANGENTIAL_PRESSURE.rawValue))
            XCTAssertEqual(presentZero.rotation_turns, 0)
            XCTAssertEqual(presentZero.tangential_pressure, 0)
        }
    }

    func testNullCollectionFactIsPreservedAndFreedExactlyOnce() throws {
        let fingerprint = String(repeating: "f", count: 64)
        try withSession { session, p in
            p.factsBrushName = "Loose Brush"
            p.factsBrushCollection = .some(nil)
            p.factsBrushInternal = false
            p.factsFingerprint = fingerprint
            let expected = EngineSession.StrokeCaptureFacts(brush: .init(name: "Loose Brush", collection: nil, isInternal: false),
                                                            fingerprint: fingerprint)
            let result = try session.beginLabStrokeCapturing(image: 9, axis: self.axis(), value: 3,
                                                             brush: self.brush(), first: self.sample(),
                                                             expected: expected)
            XCTAssertEqual(result.facts, expected)
            XCTAssertEqual(result.facts?.brush.collection, nil)
            XCTAssertEqual(p.freed, 2, "NULL collection is distinct and only returned strings are freed")
        }
    }

    func testNativeFailurePropagatesStatusMessageAndLeavesNoAcceptedStroke() throws {
        try withSession { session, p in
            p.status = GLIMS_STATUS_BUSY
            p.withMessage = true
            p.returnedStroke = 0
            p.factsBrushName = "Transient"
            p.factsBrushCollection = .some("Temp")
            p.factsFingerprint = String(repeating: "e", count: 64)
            self.assertStatus(GLIMS_STATUS_BUSY) {
                _ = try session.beginLabStrokeCapturing(image: 9, axis: self.axis(), value: 7,
                                                        brush: self.brush(), first: self.sample())
            }
            XCTAssertEqual(p.calls, ["capture_begin"])
            XCTAssertTrue(p.cleared)
            XCTAssertEqual(p.freed, 4, "owned error and any returned fact strings must be released on failure paths")
        }
    }

    func testInvalidTypedInputRefusesWithoutDispatch() throws {
        try withSession { session, p in
            var invalidBrush = self.brush()
            invalidBrush.size = 0
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.beginLabStrokeCapturing(image: 9, axis: self.axis(), value: 10,
                                                        brush: invalidBrush, first: self.sample())
            }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.beginLabStrokeCapturing(image: 0, axis: self.axis(), value: 10,
                                                        brush: self.brush(), first: self.sample())
            }
            let badAxis = EngineSession.LabAxis(id: 0, role: .lightness, isSelected: false,
                                                uuid: UUID(uuidString: "00010203-0405-0607-0809-0A0B0C0D0E0F")!, name: "L*")
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.beginLabStrokeCapturing(image: 9, axis: badAxis, value: 10,
                                                        brush: self.brush(), first: self.sample())
            }
            let badSample = EngineSession.StrokeSampleV2(point: .init(x: 1, y: 1, pressure: 2, xTilt: 0, yTilt: 0, timeMilliseconds: 0),
                                                         rotationTurns: nil, tangentialPressure: nil)
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.beginLabStrokeCapturing(image: 9, axis: self.axis(), value: 10,
                                                        brush: self.brush(), first: badSample)
            }
            XCTAssertTrue(p.calls.isEmpty)
        }
    }
}
