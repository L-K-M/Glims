import CGlimsEngine
import Darwin
import XCTest
@testable import GlimsKit

final class TabletStrokeCaptureTransportTests: XCTestCase {
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
        var beginDrawable: Int32 = 0
        var beginBrush: GlimsBrushSettings?
        var beginPacket: [GlimsStrokeSampleV2] = []
        var continuedPackets: [[GlimsStrokeSampleV2]] = []
        var continueStatus = GLIMS_STATUS_OK
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
        api.stroke_continue_v2 = { engine, stroke, packet, error in
            let p = Producer.from(engine)
            p.calls.append("continue:\(stroke)")
            let first = p.beginPacket
            p.capturePacket(packet)
            p.continuedPackets.append(p.beginPacket)
            p.beginPacket = first
            error?.pointee = nil
            return p.continueStatus
        }
        api.stroke_end = { engine, stroke in
            let p = Producer.from(engine); p.calls.append("end:\(stroke)"); return GLIMS_STATUS_OK
        }
        api.stroke_begin_v2_with_capture_facts = { engine, image, drawable, brush, settings, packet, fingerprint, result, facts, error in
            let p = Producer.from(engine)
            p.calls.append("tablet_capture_begin")
            p.beginImage = image
            p.beginDrawable = drawable
            p.beginResource = brush
            p.beginBrush = settings?.pointee
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

    func testShortOrIncompleteTablesRefuseWithoutFallbackOrReadingPastPrefix() throws {
        let prefix = MemoryLayout<GlimsEngineAPI>.offset(of: \.stroke_begin_v2_with_capture_facts)!
        try withSession(configure: { $0.struct_size = UInt32(prefix) }, guarded: true) { session, p in
            XCTAssertFalse(session.supportsTabletStrokeCapture)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) {
                _ = try session.beginTabletStrokeCapturing(image: 9, drawable: 4, brush: .init(), first: self.sample())
            }
            XCTAssertTrue(p.calls.isEmpty)
        }
        for configure: (inout GlimsEngineAPI) -> Void in [
            { $0.stroke_begin_v2_with_capture_facts = nil },
            { $0.stroke_continue_v2 = nil },
            { $0.stroke_end = nil }
        ] {
            try withSession(configure: configure) { session, p in
                XCTAssertFalse(session.supportsTabletStrokeCapture)
                self.assertStatus(GLIMS_STATUS_UNSUPPORTED) {
                    _ = try session.beginTabletStrokeCapturing(image: 9, drawable: 4, brush: .init(), first: self.sample())
                }
                XCTAssertTrue(p.calls.isEmpty)
            }
        }
    }

    func testGuardedCapturePassesBrushIdentityFingerprintAndOptionalAxes() throws {
        let identity = EngineSession.ResourceIdentity(name: "Expected", collection: "Pack", isInternal: false)
        let fingerprint = String(repeating: "a", count: 64)
        try withSession { session, p in
            p.factsBrushName = identity.name
            p.factsBrushCollection = .some(identity.collection)
            p.factsBrushInternal = identity.isInternal
            p.factsFingerprint = fingerprint
            var brush = EngineSession.Brush(); brush.resource = .init(name: "Other", collection: nil, isInternal: true)
            let result = try session.beginTabletStrokeCapturing(image: 9, drawable: 4, brush: brush,
                first: sample(rotation: 0.875, tangent: -0.375), expected: .init(brush: identity, fingerprint: fingerprint))
            XCTAssertEqual(result.stroke, 73)
            XCTAssertEqual(result.facts, .init(brush: identity, fingerprint: fingerprint))
            XCTAssertEqual(p.calls, ["resolve", "tablet_capture_begin"])
            XCTAssertEqual(p.resolvedName, "Expected")
            XCTAssertEqual(p.beginImage, 9); XCTAssertEqual(p.beginDrawable, 4); XCTAssertEqual(p.beginResource, 901)
            XCTAssertEqual(p.beginExpectedFingerprint, fingerprint)
            XCTAssertEqual(p.beginPacket.count, 1)
            XCTAssertEqual(p.beginPacket.first?.flags, 3)
            XCTAssertEqual(p.beginPacket.first?.rotation_turns, 0.875)
            XCTAssertEqual(p.beginPacket.first?.tangential_pressure, -0.375)
            XCTAssertEqual(p.freed, 3)
        }
    }

    func testMalformedReplayAndSamplesRefuseBeforeResourceResolution() throws {
        let identity = EngineSession.ResourceIdentity(name: "Expected", collection: nil, isInternal: false)
        try withSession { session, p in
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.beginTabletStrokeCapturing(image: 9, drawable: 4, brush: .init(), first: self.sample(),
                    expected: .init(brush: identity, fingerprint: "BAD"))
            }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.beginTabletStrokeCapturing(image: 9, drawable: 4, brush: .init(), first: self.sample(rotation: 1))
            }
            XCTAssertTrue(p.calls.isEmpty)
        }
    }

    func testNativeFailureFreesOwnedFactsAndError() throws {
        try withSession { session, p in
            p.status = GLIMS_STATUS_FAILED; p.withMessage = true
            p.factsBrushName = "Brush"; p.factsBrushCollection = .some("Pack"); p.factsFingerprint = String(repeating: "a", count: 64)
            self.assertStatus(GLIMS_STATUS_FAILED) {
                _ = try session.beginTabletStrokeCapturing(image: 9, drawable: 4, brush: .init(), first: self.sample())
            }
            XCTAssertEqual(p.calls, ["tablet_capture_begin"])
            XCTAssertTrue(p.cleared)
            XCTAssertEqual(p.freed, 4)
        }
    }
    func testEraserBackgroundRequiresCapabilityAndReachesTabletCapture() throws {
        var brush = EngineSession.Brush(tool: .eraser)
        brush.eraserBackground = .init(red: 0.1, green: 0.4, blue: 0.7)
        let prefix = MemoryLayout<GlimsEngineAPI>.offset(of: \.brush_settings_features)!
        try withSession(configure: { $0.struct_size = UInt32(prefix) }, guarded: true) { session, producer in
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) {
                _ = try session.beginTabletStrokeCapturing(image: 9, drawable: 4, brush: brush, first: self.sample())
            }
            XCTAssertTrue(producer.calls.isEmpty)
        }
        try withSession(configure: { $0.brush_settings_features = { 1 } }) { session, producer in
            _ = try session.beginTabletStrokeCapturing(image: 9, drawable: 4, brush: brush, first: self.sample())
            let native = try XCTUnwrap(producer.beginBrush)
            XCTAssertTrue(native.has_eraser_background)
            XCTAssertTrue(native.record_eraser_background)
            XCTAssertEqual(native.eraser_background_red, 0.1, accuracy: 0.0001)
            XCTAssertEqual(native.eraser_background_green, 0.4, accuracy: 0.0001)
            XCTAssertEqual(native.eraser_background_blue, 0.7, accuracy: 0.0001)
        }
    }

    func testEraserBackgroundOptInIsOnlySetForCapture() throws {
        var brush = EngineSession.Brush(tool: .eraser)
        brush.eraserBackground = .init(red: 0.1, green: 0.4, blue: 0.7)
        try withSession(configure: { api in
            api.brush_settings_features = { 1 }
            api.stroke_begin_v2 = { engine, _, _, _, settings, _, result, error in
                let producer = Producer.from(engine); producer.beginBrush = settings?.pointee
                result?.pointee = producer.returnedStroke; error?.pointee = nil
                return GLIMS_STATUS_OK
            }
            api.stroke_begin = { engine, _, _, settings, _, result, error in
                let producer = Producer.from(engine); producer.beginBrush = settings?.pointee
                result?.pointee = producer.returnedStroke; error?.pointee = nil
                return GLIMS_STATUS_OK
            }
            api.stroke_begin_with_capture_facts = { engine, _, _, _, settings, _, _, result, _, error in
                let producer = Producer.from(engine); producer.beginBrush = settings?.pointee
                result?.pointee = producer.returnedStroke; error?.pointee = nil
                return GLIMS_STATUS_OK
            }
        }) { session, producer in
            _ = try session.beginTabletStroke(image: 9, drawable: 4, brush: brush, first: self.sample())
            XCTAssertEqual(producer.beginBrush?.record_eraser_background, false)
            _ = try session.beginStroke(image: 9, drawable: 4, brush: brush, first: self.sample().point)
            XCTAssertEqual(producer.beginBrush?.record_eraser_background, false)
            _ = try session.beginStrokeCapturing(image: 9, drawable: 4, brush: brush, first: self.sample().point)
            XCTAssertEqual(producer.beginBrush?.record_eraser_background, true)
        }
    }

    func testReplaySendsV2BatchesAndEndsAfterSuccessOrFailure() throws {
        let identity = EngineSession.ResourceIdentity(name: "Expected", collection: nil, isInternal: false)
        let fingerprint = String(repeating: "b", count: 64)
        let first = try RecorderTabletStrokeTrace.Point(native: sample(rotation: 0.25, tangent: -0.5))
        let laterNative = EngineSession.StrokeSampleV2(point: .init(x: 15, y: 18, timeMilliseconds: 18),
                                                       rotationTurns: 0.75, tangentialPressure: 0.5)
        let later = try RecorderTabletStrokeTrace.Point(native: laterNative)
        let settings = try XCTUnwrap(RecorderStrokeCommand.Settings(EngineSession.Brush()))
        let command = RecorderTabletStrokeCommand(settings: settings, trace: .init(first: first, batches: [[later]]),
                                                   facts: .init(brush: identity, fingerprint: fingerprint))
        for status in [GLIMS_STATUS_OK, GLIMS_STATUS_FAILED] {
            try withSession { session, p in
                p.factsBrushName = identity.name; p.factsFingerprint = fingerprint; p.continueStatus = status
                if status == GLIMS_STATUS_OK {
                    try command.apply(session: session, image: 9, layer: 4)
                } else {
                    self.assertStatus(GLIMS_STATUS_FAILED) { try command.apply(session: session, image: 9, layer: 4) }
                }
                XCTAssertEqual(p.calls, ["resolve", "tablet_capture_begin", "continue:73", "end:73"])
                XCTAssertEqual(p.beginExpectedFingerprint, fingerprint)
                XCTAssertEqual(p.beginPacket.first?.rotation_turns, 0.25)
                XCTAssertEqual(p.continuedPackets.first?.first?.rotation_turns, 0.75)
                XCTAssertEqual(p.continuedPackets.first?.first?.tangential_pressure, 0.5)
            }
        }
    }

}
