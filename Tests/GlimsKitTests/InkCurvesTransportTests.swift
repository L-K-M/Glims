import CGlimsEngine
import Darwin
import XCTest
@testable import GlimsKit

/// Transport tests for scalar ink Curves slots 199–201 against an owned C
/// table. No native engine, filesystem access, or desktop integration.
final class InkCurvesTransportTests: XCTestCase {
    private final class Producer {
        var directStatus = GLIMS_STATUS_OK
        var directMessage: String?
        var directCalls = 0
        var directImage: Int32 = 0
        var directChannel: Int32 = 0
        var directSettings: GlimsInkCurvesSettings?
        var directErrorWasCleared = false
        var directFreedStrings = 0

        var beginStatus = GLIMS_STATUS_OK
        var beginMessage: String?
        var beginCalls = 0
        var beginImage: Int32 = 0
        var beginChannel: Int32 = 0
        var beginToken: UInt64 = 77
        var beginTokenWasCleared = false
        var beginErrorWasCleared = false
        var beginFreedStrings = 0

        var renderStatus = GLIMS_STATUS_OK
        var renderMessage: String?
        var renderCalls = 0
        var renderImage: Int32 = 0
        var renderToken: UInt64 = 0
        var renderSettings: GlimsInkCurvesSettings?
        var renderCopy: Int32 = 91
        var renderCopyWasCleared = false
        var renderErrorWasCleared = false
        var renderFreedStrings = 0

        var applyStatus = GLIMS_STATUS_OK
        var applyMessage: String?
        var applyCalls = 0
        var applyImage: Int32 = 0
        var applyToken: UInt64 = 0
        var applySettings: GlimsInkCurvesSettings?
        var applyErrorWasCleared = false
        var applyFreedStrings = 0

        var endCalls = 0
        var endStatuses: [GlimsStatus] = []
        var endImage: Int32 = 0
        var endToken: UInt64 = 0

        var closed: [Int32] = []
        var stopped = false

        static func from(_ engine: OpaquePointer?) -> Producer {
            Unmanaged<Producer>.fromOpaque(UnsafeRawPointer(engine!)).takeUnretainedValue()
        }

        func allocateString(_ value: String, counter: String) -> UnsafeMutablePointer<CChar> {
            let prefix = MemoryLayout<UnsafeMutableRawPointer>.stride * 2
            let bytes = Array(value.utf8) + [0]
            let allocation = UnsafeMutableRawPointer.allocate(
                byteCount: prefix + bytes.count,
                alignment: MemoryLayout<UnsafeMutableRawPointer>.alignment)
            allocation.storeBytes(of: Unmanaged.passUnretained(self).toOpaque(), as: UnsafeMutableRawPointer.self)
            let marker: UInt64 = ["direct": 1, "begin": 2, "render": 3, "apply": 4][counter]!
            allocation.advanced(by: MemoryLayout<UnsafeMutableRawPointer>.stride)
                .storeBytes(of: marker, as: UInt64.self)
            bytes.withUnsafeBytes {
                allocation.advanced(by: prefix).copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
            return allocation.advanced(by: prefix).assumingMemoryBound(to: CChar.self)
        }

        static func releaseString(_ string: UnsafeMutablePointer<CChar>?) {
            guard let string else { return }
            let base = UnsafeMutableRawPointer(string).advanced(by: -MemoryLayout<UnsafeMutableRawPointer>.stride * 2)
            let owner = base.load(as: UnsafeMutableRawPointer.self)
            let counter = base.advanced(by: MemoryLayout<UnsafeMutableRawPointer>.stride).load(as: UInt64.self)
            let producer = Unmanaged<Producer>.fromOpaque(owner).takeUnretainedValue()
            switch counter {
            case 1: producer.directFreedStrings += 1
            case 2: producer.beginFreedStrings += 1
            case 3: producer.renderFreedStrings += 1
            case 4: producer.applyFreedStrings += 1
            default: XCTFail("Unknown string owner counter: \(counter)")
            }
            base.deallocate()
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
        // Independent unrelated slot: must not be required or called by Curves wrappers.
        table.image_ink_snapshot_levels = { _, _, _, _, _, _ in GLIMS_STATUS_FAILED }
        table.image_ink_snapshot_apply = { _, _, _, _, _ in GLIMS_STATUS_FAILED }

        table.image_curves_ink = { engine, image, channel, settings, error in
            let producer = Producer.from(engine)
            producer.directCalls += 1
            producer.directImage = image
            producer.directChannel = channel
            producer.directSettings = settings?.pointee
            producer.directErrorWasCleared = error?.pointee == nil
            error?.pointee = producer.directMessage.map { producer.allocateString($0, counter: "direct") }
            return producer.directStatus
        }
        table.image_ink_snapshot_begin = { engine, image, channel, token, error in
            let producer = Producer.from(engine)
            producer.beginCalls += 1
            producer.beginImage = image
            producer.beginChannel = channel
            producer.beginTokenWasCleared = token?.pointee == 0
            producer.beginErrorWasCleared = error?.pointee == nil
            token?.pointee = producer.beginToken
            error?.pointee = producer.beginMessage.map { producer.allocateString($0, counter: "begin") }
            return producer.beginStatus
        }
        table.image_ink_snapshot_curves = { engine, image, token, settings, copy, error in
            let producer = Producer.from(engine)
            producer.renderCalls += 1
            producer.renderImage = image
            producer.renderToken = token
            producer.renderSettings = settings?.pointee
            producer.renderCopyWasCleared = copy?.pointee == 0
            producer.renderErrorWasCleared = error?.pointee == nil
            copy?.pointee = producer.renderCopy
            error?.pointee = producer.renderMessage.map { producer.allocateString($0, counter: "render") }
            return producer.renderStatus
        }
        table.image_ink_snapshot_apply_curves = { engine, image, token, settings, error in
            let producer = Producer.from(engine)
            producer.applyCalls += 1
            producer.applyImage = image
            producer.applyToken = token
            producer.applySettings = settings?.pointee
            producer.applyErrorWasCleared = error?.pointee == nil
            error?.pointee = producer.applyMessage.map { producer.allocateString($0, counter: "apply") }
            return producer.applyStatus
        }
        table.image_ink_snapshot_end = { engine, image, token in
            let producer = Producer.from(engine)
            producer.endCalls += 1
            producer.endImage = image
            producer.endToken = token
            let status = GLIMS_STATUS_OK
            producer.endStatuses.append(status)
            return status
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
                              _ operation: () throws -> Void) {
        XCTAssertThrowsError(try operation(), file: file, line: line) {
            guard let error = $0 as? EngineSession.EngineError else {
                return XCTFail("Unexpected error type: \($0)", file: file, line: line)
            }
            XCTAssertEqual(error.status, Int32(expected.rawValue), file: file, line: line)
            if let message { XCTAssertEqual(error.message, message, file: file, line: line) }
        }
    }

    private func sampleCurve() -> [Double] {
        (0..<256).map { index in
            let x = Double(index) / 255.0
            return x < 0.5 ? x * 0.25 : (0.125 + (x - 0.5) * 1.75)
        }
    }

    private func readSamples(_ native: GlimsInkCurvesSettings) -> [Double] {
        withUnsafeBytes(of: native.samples) { bytes in
            Array(bytes.bindMemory(to: Double.self))
        }
    }

    func testSettingsValidationAndIdentityDefault() {
        XCTAssertEqual(EngineSession.InkCurvesSettings.sampleCount, 256)
        XCTAssertEqual(EngineSession.InkCurvesSettings().samples, EngineSession.InkCurvesSettings.identitySamples)
        XCTAssertTrue(EngineSession.InkCurvesSettings().isValid)

        var nonMonotone = EngineSession.InkCurvesSettings()
        nonMonotone.samples = sampleCurve().reversed()
        XCTAssertTrue(nonMonotone.isValid, "Nonmonotone tables are permitted")

        var wrongCount = EngineSession.InkCurvesSettings(); wrongCount.samples = [0, 1]
        XCTAssertFalse(wrongCount.isValid)
        var nan = EngineSession.InkCurvesSettings(); nan.samples[5] = .nan
        XCTAssertFalse(nan.isValid)
        var inf = EngineSession.InkCurvesSettings(); inf.samples[5] = .infinity
        XCTAssertFalse(inf.isValid)
        var below = EngineSession.InkCurvesSettings(); below.samples[5] = -Double.leastNonzeroMagnitude
        XCTAssertFalse(below.isValid)
        var above = EngineSession.InkCurvesSettings(); above.samples[5] = 1.0000000001
        XCTAssertFalse(above.isValid)
    }

    func testArrayCopySemantics() throws {
        var draft = EngineSession.InkCurvesSettings.identitySamples
        let settings = EngineSession.InkCurvesSettings(samples: draft)
        draft[0] = 0.5
        draft[255] = 0.25
        XCTAssertEqual(settings.samples[0], 0.0)
        XCTAssertEqual(settings.samples[255], 1.0)

        try withSession { session, producer in
            var transportSettings = EngineSession.InkCurvesSettings(samples: sampleCurve())
            try session.applyInkCurves(11, channel: 3, settings: transportSettings)
            transportSettings.samples[7] = 0.99
            XCTAssertEqual(producer.directCalls, 1)
            let sent = try XCTUnwrap(producer.directSettings)
            XCTAssertEqual(self.readSamples(sent)[7], self.sampleCurve()[7], accuracy: 0)
        }
    }

    func testDirectCurvesCapabilityAndIndependence() throws {
        let directOffset = MemoryLayout<GlimsEngineAPI>.offset(of: \.image_curves_ink)!
        try withSession(configure: { $0.struct_size = UInt32(directOffset) }, guardedPrefix: true) { session, producer in
            XCTAssertFalse(session.supportsInkCurves)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) {
                try session.applyInkCurves(11, channel: 3, settings: .init())
            }
            XCTAssertEqual(producer.directCalls, 0)
        }

        try withSession(configure: {
            $0.image_ink_snapshot_begin = nil
            $0.image_ink_snapshot_curves = nil
            $0.image_ink_snapshot_apply_curves = nil
            $0.image_ink_snapshot_end = nil
        }) { session, producer in
            XCTAssertTrue(session.supportsInkCurves, "Direct Curves needs only slot 199")
            XCTAssertFalse(session.supportsInkCurveSnapshots)
            try session.applyInkCurves(11, channel: 3, settings: .init(samples: self.sampleCurve()))
            XCTAssertEqual(producer.directCalls, 1)
        }
    }

    func testSnapshotCapabilityIndependenceAndShortStructRefusal() throws {
        let applyOffset = MemoryLayout<GlimsEngineAPI>.offset(of: \.image_ink_snapshot_apply_curves)!
        try withSession(configure: { $0.struct_size = UInt32(applyOffset) }, guardedPrefix: true) { session, producer in
            XCTAssertFalse(session.supportsInkCurveSnapshots)
            self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { _ = try session.beginInkCurvesSnapshot(11, channel: 3) }
            XCTAssertEqual(producer.beginCalls, 0)
        }

        for missing in 1..<16 {
            try withSession(configure: {
                if missing & 1 != 0 { $0.image_ink_snapshot_begin = nil }
                if missing & 2 != 0 { $0.image_ink_snapshot_curves = nil }
                if missing & 4 != 0 { $0.image_ink_snapshot_apply_curves = nil }
                if missing & 8 != 0 { $0.image_ink_snapshot_end = nil }
            }) { session, producer in
                XCTAssertFalse(session.supportsInkCurveSnapshots, "Missing snapshot capabilities: \(missing)")
                self.assertStatus(GLIMS_STATUS_UNSUPPORTED) { _ = try session.beginInkCurvesSnapshot(11, channel: 3) }
                XCTAssertEqual(producer.beginCalls, 0)
            }
        }

        try withSession(configure: {
            $0.image_ink_snapshot_levels = nil
            $0.image_ink_snapshot_apply = nil
        }) { session, producer in
            XCTAssertTrue(session.supportsInkCurveSnapshots, "Curves snapshots must not require Levels render/apply slots")
            producer.beginToken = 88
            let token = try session.beginInkCurvesSnapshot(11, channel: 3)
            XCTAssertEqual(token, 88)
            XCTAssertEqual(producer.beginCalls, 1)
        }
    }

    func testDirectApplyTransportCapturesIdsAndFullPreciseSamples() throws {
        try withSession { session, producer in
            let samples = sampleCurve()
            try session.applyInkCurves(42, channel: 7, settings: EngineSession.InkCurvesSettings(samples: samples))
            XCTAssertEqual(producer.directCalls, 1)
            XCTAssertEqual(producer.directImage, 42)
            XCTAssertEqual(producer.directChannel, 7)
            XCTAssertTrue(producer.directErrorWasCleared)
            let sent = try XCTUnwrap(producer.directSettings)
            XCTAssertEqual(Int(sent.struct_size), MemoryLayout<GlimsInkCurvesSettings>.size)
            XCTAssertEqual(readSamples(sent), samples)
            XCTAssertEqual(producer.directFreedStrings, 0)
        }
    }

    func testMalformedSettingsNeverDispatch() throws {
        try withSession { session, producer in
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                try session.applyInkCurves(0, channel: 3, settings: .init())
            }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                try session.applyInkCurves(11, channel: 0, settings: .init())
            }
            var bad = EngineSession.InkCurvesSettings(); bad.samples = [0, 1]
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                try session.applyInkCurves(11, channel: 3, settings: bad)
            }
            bad.samples = Array(repeating: 0.0, count: 256); bad.samples[10] = .nan
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                try session.applyInkCurves(11, channel: 3, settings: bad)
            }
            bad.samples[10] = 2
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                try session.applyInkCurves(11, channel: 3, settings: bad)
            }
            XCTAssertEqual(producer.directCalls, 0)
        }

        try withSession { session, producer in
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { _ = try session.beginInkCurvesSnapshot(0, channel: 3) }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { _ = try session.beginInkCurvesSnapshot(11, channel: 0) }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.renderInkCurvesSnapshot(0, token: 1, settings: .init())
            }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.renderInkCurvesSnapshot(11, token: 0, settings: .init())
            }
            var bad = EngineSession.InkCurvesSettings(); bad.samples[0] = -1
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                _ = try session.renderInkCurvesSnapshot(11, token: 1, settings: bad)
            }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                try session.applyInkCurvesSnapshot(11, token: 0, settings: .init())
            }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) {
                try session.applyInkCurvesSnapshot(11, token: 1, settings: bad)
            }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.endInkCurvesSnapshot(0, token: 1) }
            self.assertStatus(GLIMS_STATUS_INVALID_ARGUMENT) { try session.endInkCurvesSnapshot(11, token: 0) }
            XCTAssertEqual(producer.beginCalls, 0)
            XCTAssertEqual(producer.renderCalls, 0)
            XCTAssertEqual(producer.applyCalls, 0)
            XCTAssertEqual(producer.endCalls, 0)
        }
    }

    func testSnapshotTransportCapturesTokenIdsAndSamples() throws {
        try withSession { session, producer in
            producer.beginToken = 1234
            producer.renderCopy = 55
            let token = try session.beginInkCurvesSnapshot(9, channel: 4)
            XCTAssertEqual(token, 1234)
            XCTAssertEqual(producer.beginImage, 9)
            XCTAssertEqual(producer.beginChannel, 4)
            XCTAssertTrue(producer.beginTokenWasCleared)
            XCTAssertTrue(producer.beginErrorWasCleared)

            let samples = sampleCurve()
            let copy = try session.renderInkCurvesSnapshot(9, token: token, settings: .init(samples: samples))
            XCTAssertEqual(copy, 55)
            XCTAssertEqual(producer.renderImage, 9)
            XCTAssertEqual(producer.renderToken, 1234)
            XCTAssertTrue(producer.renderCopyWasCleared)
            XCTAssertEqual(readSamples(try XCTUnwrap(producer.renderSettings)), samples)

            try session.applyInkCurvesSnapshot(9, token: token, settings: .init(samples: samples))
            XCTAssertEqual(producer.applyImage, 9)
            XCTAssertEqual(producer.applyToken, 1234)
            XCTAssertEqual(readSamples(try XCTUnwrap(producer.applySettings)), samples)

            try session.endInkCurvesSnapshot(9, token: token)
            XCTAssertEqual(producer.endImage, 9)
            XCTAssertEqual(producer.endToken, 1234)
            XCTAssertEqual(producer.endCalls, 1)
        }
    }

    func testMissingOrZeroReturnedHandlesAndTokensRefuse() throws {
        try withSession { session, producer in
            producer.beginToken = 0
            self.assertStatus(GLIMS_STATUS_FAILED) { _ = try session.beginInkCurvesSnapshot(11, channel: 3) }
            XCTAssertEqual(producer.beginCalls, 1)
        }
        try withSession { session, producer in
            producer.renderCopy = 0
            self.assertStatus(GLIMS_STATUS_FAILED) {
                _ = try session.renderInkCurvesSnapshot(11, token: 5, settings: .init())
            }
            XCTAssertEqual(producer.renderCalls, 1)
        }
        try withSession { session, producer in
            producer.renderCopy = -1
            self.assertStatus(GLIMS_STATUS_FAILED) {
                _ = try session.renderInkCurvesSnapshot(11, token: 5, settings: .init())
            }
            XCTAssertEqual(producer.renderCalls, 1)
        }
    }

    func testNativeFailuresPropagateAndFreeMessages() throws {
        let direct = Producer(); direct.directStatus = GLIMS_STATUS_BUSY; direct.directMessage = "busy now"
        try withSession(direct) { session, state in
            self.assertStatus(GLIMS_STATUS_BUSY, message: "busy now") {
                try session.applyInkCurves(11, channel: 3, settings: .init())
            }
            XCTAssertEqual(state.directFreedStrings, 1)
        }

        let begin = Producer(); begin.beginStatus = GLIMS_STATUS_LOCKED; begin.beginMessage = "locked"
        try withSession(begin) { session, state in
            self.assertStatus(GLIMS_STATUS_LOCKED, message: "locked") {
                _ = try session.beginInkCurvesSnapshot(11, channel: 3)
            }
            XCTAssertEqual(state.beginFreedStrings, 1)
        }

        let render = Producer(); render.renderStatus = GLIMS_STATUS_CANCELLED; render.renderMessage = "cancelled"
        try withSession(render) { session, state in
            self.assertStatus(GLIMS_STATUS_CANCELLED, message: "cancelled") {
                _ = try session.renderInkCurvesSnapshot(11, token: 5, settings: .init())
            }
            XCTAssertEqual(state.renderFreedStrings, 1)
        }

        let apply = Producer(); apply.applyStatus = GLIMS_STATUS_FAILED; apply.applyMessage = "apply failed"
        try withSession(apply) { session, state in
            self.assertStatus(GLIMS_STATUS_FAILED, message: "apply failed") {
                try session.applyInkCurvesSnapshot(11, token: 5, settings: .init())
            }
            XCTAssertEqual(state.applyFreedStrings, 1)
        }

        try withSession(configure: {
            $0.image_ink_snapshot_end = { engine, image, token in
                let producer = Producer.from(engine)
                producer.endCalls += 1
                producer.endImage = image
                producer.endToken = token
                producer.endStatuses.append(GLIMS_STATUS_NOT_FOUND)
                return GLIMS_STATUS_NOT_FOUND
            }
        }) { session, producer in
            self.assertStatus(GLIMS_STATUS_NOT_FOUND) { try session.endInkCurvesSnapshot(11, token: 5) }
            XCTAssertEqual(producer.endCalls, 1)
        }
    }
}
