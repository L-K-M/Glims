import XCTest
@testable import GlimsKit

final class RecorderInkStrokeFileTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let symbol = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let inkUUID = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
    private let otherSymbol = UUID(uuidString: "bbbbbbbb-cccc-dddd-eeee-ffffffffffff")!

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    private func document(_ rows: String, symbols: String? = nil, name: String = "Ink stroke recording", version: Int = 16) -> String {
        let sym = symbols ?? #"{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","description":{"name":"Cyan","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":7,"height":9}}}"#
        return #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version) +
        #","recordingID":"11111111-2222-3333-4444-555555555555","name":""# + name +
        #"","origin":{"imageLabel":"Ink.xcf","initialWidth":7,"initialHeight":9},"symbols":["# + sym +
        #"],"records":["# + rows + "]}"
    }

    private func success(_ command: String, binding: String? = nil, ordinal: Int = 0) -> String {
        let bind = binding ?? #"{"kind":"ink","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","mode":"cmyk","role":"cyan","uuid":"01234567-89ab-cdef-0123-456789abcdef"}"#
        return #"{"ordinal":"# + String(ordinal) + #","outcome":"success","command":"# + command + #","binding":"# + bind + "}"
    }

    private func decodeRejects(_ text: String, _ reason: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(text)), reason, file: file, line: line)
    }

    private func strokeCommand(tag: String = "completeInkStroke",
                               tool: String = "paintbrush",
                               size: String = "12.5",
                               opacity: String = "0.75",
                               red: String = "0.2",
                               green: String = "0",
                               blue: String = "1",
                               pressureSize: String = "true",
                               antiErase: String = "false",
                               settingsExtra: String = "",
                               factsExtra: String = "",
                               firstExtra: String = "",
                               batch1FirstExtra: String = "",
                               batch1SecondExtra: String = "",
                               batch2Extra: String = "",
                               batches: String? = nil,
                               fingerprint: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") -> String {
        let settings = #"{"tool":"\#(tool)","size":\#(size),"opacity":\#(opacity),"red":\#(red),"green":\#(green),"blue":\#(blue),"pressureSize":\#(pressureSize),"antiErase":\#(antiErase)\#(settingsExtra)}"#
        let facts = #"{"brush":{"name":"Owned Brush","isInternal":false\#(factsExtra)},"fingerprint":"\#(fingerprint)"}"#
        let first = #"{"x":1,"y":2,"pressure":0.5,"xTilt":0.25,"yTilt":-0.25,"timeMilliseconds":4294967294\#(firstExtra)}"#
        let point1 = #"{"x":3,"y":4,"pressure":0.6,"xTilt":0.1,"yTilt":-0.1,"timeMilliseconds":4294967295\#(batch1FirstExtra)}"#
        let point2 = #"{"x":5,"y":6,"pressure":0.7,"xTilt":0.2,"yTilt":-0.2,"timeMilliseconds":0\#(batch1SecondExtra)}"#
        let point3 = #"{"x":7,"y":8,"pressure":0.8,"xTilt":0.3,"yTilt":-0.3,"timeMilliseconds":1\#(batch2Extra)}"#
        let bodyBatches = batches ?? "[[\(point1),\(point2)], [\(point3)]]"
        return #"{"tag":"\#(tag)","settings":\#(settings),"facts":\#(facts),"first":\#(first),"batches":\#(bodyBatches)}"#
    }

    private func makeFile(commands: [(RecorderInkStrokeCommand, RecorderBindingDescription)], origin: RecorderFileValue.Origin = .init(imageLabel: "Ink.xcf", initialWidth: 7, initialHeight: 9)) -> RecorderFileValue {
        let symbols = [RecorderFileValue.Symbol(id: symbol, description: .init(name: "Cyan", kind: .channel, ancestors: [], siblingIndex: 0,
            bounds: .init(x: 0, y: 0, width: 7, height: 9)))]
        let records = commands.enumerated().map { index, pair in
            RecorderFileValue.Record(ordinal: index, outcome: .success(.completeInkStroke(pair.0), pair.1))
        }
        return RecorderFileValue(recordingID: recordingID, name: "Ink stroke recording", origin: origin, symbols: symbols, records: records)
    }

    private func makeTrace(pointCount: Int) throws -> RecorderTabletStrokeTrace {
        precondition(pointCount >= 1)
        let first = try RecorderTabletStrokeTrace.Point(x: 0, y: 0, pressure: 0.5, xTilt: 0, yTilt: 0, timeMilliseconds: 0)
        var remaining = pointCount - 1
        var time: UInt32 = 1
        var batches: [[RecorderTabletStrokeTrace.Point]] = []
        while remaining > 0 {
            let count = min(4096, remaining)
            var batch: [RecorderTabletStrokeTrace.Point] = []
            batch.reserveCapacity(count)
            for i in 0..<count {
                batch.append(try RecorderTabletStrokeTrace.Point(x: Double(i % 16), y: 1, pressure: 0.5, xTilt: 0, yTilt: 0, timeMilliseconds: time))
                time &+= 1
            }
            batches.append(batch)
            remaining -= count
        }
        return RecorderTabletStrokeTrace(first: first, batches: batches)
    }

    func testVersion16InkStrokeRoundTripsExactPayloadOptionalNilVsZeroAndModularWrap() throws {
        // Hand-authored literal: normalized colored sRGB/pressureSize, hardness absent, rotation/tangential absent vs present 0, modular timestamps.
        let command = strokeCommand(
            settingsExtra: "", // no hardness
            firstExtra: "",
            batch1FirstExtra: #","rotationTurns":0"#,
            batch1SecondExtra: #","tangentialPressure":0"#,
            batch2Extra: #","rotationTurns":0.125,"tangentialPressure":-0.5"#
        )
        let data = bytes(document(success(command)))
        let decoded = try RecorderFileCodec.decode(data)

        XCTAssertEqual(decoded.records.count, 1)
        guard case .success(.completeInkStroke(let stroke), .ink(let bound, let identity)) = decoded.records[0].outcome else {
            return XCTFail("Expected v16 ink stroke with ink binding")
        }
        XCTAssertEqual(bound, symbol)
        XCTAssertEqual(identity, RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: inkUUID))
        XCTAssertEqual(stroke.settings.tool, .paintbrush)
        XCTAssertEqual(stroke.settings.size, 12.5)
        XCTAssertEqual(stroke.settings.opacity, 0.75)
        XCTAssertEqual(stroke.settings.red, 0.2)
        XCTAssertEqual(stroke.settings.green, 0)
        XCTAssertEqual(stroke.settings.blue, 1)
        XCTAssertEqual(stroke.settings.pressureSize, true)
        XCTAssertEqual(stroke.settings.antiErase, false)
        XCTAssertNil(stroke.settings.hardness)
        XCTAssertEqual(stroke.facts.brush.name, "Owned Brush")
        XCTAssertEqual(stroke.facts.brush.isInternal, false)
        XCTAssertNil(stroke.facts.brush.collection)
        XCTAssertEqual(stroke.facts.fingerprint, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")

        XCTAssertNil(stroke.trace.first.rotationTurns)
        XCTAssertNil(stroke.trace.first.tangentialPressure)
        XCTAssertEqual(stroke.trace.first.timeMilliseconds, 4_294_967_294)
        XCTAssertEqual(stroke.trace.batches[0][0].rotationTurns, 0) // present 0
        XCTAssertNil(stroke.trace.batches[0][0].tangentialPressure)
        XCTAssertNil(stroke.trace.batches[0][1].rotationTurns)
        XCTAssertEqual(stroke.trace.batches[0][1].tangentialPressure, 0)
        XCTAssertEqual(stroke.trace.batches[0][0].timeMilliseconds, 4_294_967_295)
        XCTAssertEqual(stroke.trace.batches[0][1].timeMilliseconds, 0) // modular wrap
        XCTAssertEqual(stroke.trace.batches[1][0].timeMilliseconds, 1)
        XCTAssertEqual(stroke.trace.batches[1][0].rotationTurns, 0.125)
        XCTAssertEqual(stroke.trace.batches[1][0].tangentialPressure, -0.5)

        let encoded = try RecorderFileCodec.encode(decoded)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 16)
        let rows = try XCTUnwrap(json["records"] as? [[String: Any]])
        let encodedCommand = try XCTUnwrap(rows.first?["command"] as? [String: Any])
        let encodedSettings = try XCTUnwrap(encodedCommand["settings"] as? [String: Any])
        XCTAssertEqual(Set(encodedSettings.keys), Set(["tool", "size", "opacity", "red", "green", "blue", "pressureSize", "antiErase"]))
        XCTAssertNil(encodedSettings["hardness"])
        XCTAssertEqual(encodedSettings["pressureSize"] as? Bool, true)
        let encodedFirst = try XCTUnwrap(encodedCommand["first"] as? [String: Any])
        XCTAssertEqual(Set(encodedFirst.keys), Set(["x", "y", "pressure", "xTilt", "yTilt", "timeMilliseconds"]))
        let encodedFacts = try XCTUnwrap(encodedCommand["facts"] as? [String: Any])
        XCTAssertEqual(Set(encodedFacts.keys), Set(["brush", "fingerprint"]))
        let encodedBrush = try XCTUnwrap(encodedFacts["brush"] as? [String: Any])
        XCTAssertEqual(Set(encodedBrush.keys), Set(["name", "isInternal"]))
        let binding = try XCTUnwrap(rows.first?["binding"] as? [String: Any])
        XCTAssertEqual(Set(binding.keys), Set(["kind", "symbol", "mode", "role", "uuid"]))
        let roundTripped = try RecorderFileCodec.decode(encoded)
        XCTAssertEqual(roundTripped, decoded)
        guard case .success(.completeInkStroke(let rt), _) = roundTripped.records[0].outcome else { return XCTFail() }
        XCTAssertNil(rt.trace.first.rotationTurns)
        XCTAssertEqual(rt.trace.batches[0][0].rotationTurns, 0)
        XCTAssertNil(rt.trace.batches[0][0].tangentialPressure)
        XCTAssertEqual(rt.trace.batches[0][1].tangentialPressure, 0)
    }

    func testPencilSuccessAndEraserAirbrushAntiEraseSizeRefusals() throws {
        let pencil = strokeCommand(tool: "pencil", settingsExtra: #","hardness":0.25"#)
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(success(pencil)))))
        decodeRejects(document(success(strokeCommand(tool: "eraser"))), "eraser rejected")
        decodeRejects(document(success(strokeCommand(tool: "airbrush"))), "airbrush rejected")
        decodeRejects(document(success(strokeCommand(antiErase: "true"))), "antiErase rejected")
        decodeRejects(document(success(strokeCommand(size: "0.5"))), "size < 1 rejected")
        decodeRejects(document(success(strokeCommand(size: "0"))), "size 0 rejected")
        decodeRejects(document(success(strokeCommand(red: "-0.01"))), "negative RGB refused")
        decodeRejects(document(success(strokeCommand(red: "1.01"))), "RGB above one refused")
    }

    func testStrictMissingUnknownWrongTypesNullAndVersionRules() {
        let baseline = bytes(document(success(strokeCommand(settingsExtra: #","hardness":0.5"#, factsExtra: #","collection":"Set""#, firstExtra: #","rotationTurns":0"#, batch2Extra: #","tangentialPressure":0"#))))
        XCTAssertNoThrow(try RecorderFileCodec.decode(baseline))
        func reject(_ mutate: (inout String) -> Void, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
            let original = String(decoding: baseline, as: UTF8.self)
            var text = original
            mutate(&text)
            XCTAssertNotEqual(text, original, name, file: file, line: line)
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(text)), name, file: file, line: line)
        }
        // settings
        reject({ $0 = $0.replacingOccurrences(of: #""tool":"paintbrush","#, with: "") }, "missing tool")
        reject({ $0 = $0.replacingOccurrences(of: #","pressureSize":true"#, with: "") }, "missing pressureSize")
        reject({ $0 = $0.replacingOccurrences(of: #""antiErase":false"#, with: #""antiErase":false,"extra":1"#) }, "unknown settings")
        reject({ $0 = $0.replacingOccurrences(of: #""hardness":0.5"#, with: #""hardness":null"#) }, "null hardness")
        reject({ $0 = $0.replacingOccurrences(of: #""opacity":0.75"#, with: #""opacity":"0.75""#) }, "wrong type opacity")
        reject({ $0 = $0.replacingOccurrences(of: #""tool":"paintbrush""#, with: #""tool":1"#) }, "wrong type tool")
        // facts
        reject({ $0 = $0.replacingOccurrences(of: #""facts":{"brush""#, with: #""facts":{"extra":true,"brush""#) }, "unknown facts")
        reject({ $0 = $0.replacingOccurrences(of: #""isInternal":false"#, with: #""isInternal":false,"nativeID":1"#) }, "unknown brush identity")
        reject({ $0 = $0.replacingOccurrences(of: #""fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef""#, with: #""fingerprint":"0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef""#) }, "non-lower hex")
        reject({ $0 = $0.replacingOccurrences(of: #""fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef""#, with: #""fingerprint":"0123""#) }, "short fingerprint")
        reject({ $0 = $0.replacingOccurrences(of: #""name":"Owned Brush""#, with: #""name":"""#) }, "empty name")
        // point
        reject({ $0 = $0.replacingOccurrences(of: #""x":1,"y":2"#, with: #""x":1,"y":2,"nativeSample":0"#) }, "unknown point")
        reject({ $0 = $0.replacingOccurrences(of: #""x":1,"#, with: "") }, "missing point field")
        reject({ $0 = $0.replacingOccurrences(of: #""pressure":0.5"#, with: #""pressure":"0.5""#) }, "wrong point type")
        reject({ $0 = $0.replacingOccurrences(of: #""timeMilliseconds":4294967294"#, with: #""timeMilliseconds":-1"#) }, "negative time")
        reject({ $0 = $0.replacingOccurrences(of: #""timeMilliseconds":4294967294"#, with: #""timeMilliseconds":4294967296"#) }, "oversized time")
        reject({ $0 = $0.replacingOccurrences(of: #""rotationTurns":0"#, with: #""rotationTurns":null"#) }, "null optional rotation")
        reject({ $0 = $0.replacingOccurrences(of: #""tangentialPressure":0"#, with: #""tangentialPressure":null"#) }, "null optional tangential")

        // new tag in old versions
        let cmd = strokeCommand()
        for version in 1...15 {
            decodeRejects(document(success(cmd), version: version), "tag wrong version \(version)")
        }
        // v16 without successful new command
        let ordinary = #"{"ordinal":0,"outcome":"success","command":{"tag":"scale","width":2,"height":2},"binding":{"kind":"none"}}"#
        decodeRejects(document(ordinary, version: 16), "v16 needs ink stroke")
        decodeRejects(document(#"{"ordinal":0,"outcome":"failure","reason":"nope"}"#, version: 16), "v16 failure-only")
    }

    func testBindingAndIdentityValidation() {
        let cmd = strokeCommand()
        let base = document(success(cmd))
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(base)))
        let layerSym = #"{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","description":{"name":"L","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1}}}"#
        decodeRejects(document(success(cmd, binding: #"{"kind":"none"}"#)), "none binding")
        decodeRejects(document(success(cmd, binding: #"{"kind":"channel","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#)), "untyped channel binding")
        decodeRejects(document(success(cmd, binding: #"{"kind":"layer","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#), symbols: layerSym), "layer binding")
        let labBind = #"{"kind":"lab","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","role":"a","precision":"u8","uuid":"01234567-89ab-cdef-0123-456789abcdef"}"#
        decodeRejects(document(success(cmd, binding: labBind)), "lab binding")
        // wrong ink role/mode/UUID
        decodeRejects(document(success(cmd, binding: #"{"kind":"ink","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","mode":"multichannel","role":"cyan","uuid":"01234567-89ab-cdef-0123-456789abcdef"}"#)), "bad multichannel role")
        decodeRejects(document(success(cmd, binding: #"{"kind":"ink","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","mode":"cmyk","role":"unspecified","uuid":"01234567-89ab-cdef-0123-456789abcdef"}"#)), "bad cmyk role")
        decodeRejects(document(success(cmd, binding: #"{"kind":"ink","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","mode":"multichannel","role":"unspecified","uuid":"00000000-0000-0000-0000-000000000000"}"#)), "zero uuid")
        // missing symbol
        decodeRejects(document(success(cmd, binding: #"{"kind":"ink","symbol":"bbbbbbbb-cccc-dddd-eeee-ffffffffffff","mode":"cmyk","role":"cyan","uuid":"01234567-89ab-cdef-0123-456789abcdef"}"#)), "missing symbol")
    }

    func testPacketWholeTraceAndCumulativeFileBudgets() throws {
        func point(_ i: Int, time: UInt32) -> String {
            #"{"x":\#(i),"y":1,"pressure":0.5,"xTilt":0,"yTilt":0,"timeMilliseconds":\#(time)}"#
        }
        let atPacket = (0..<4096).map { point($0, time: UInt32($0)) }.joined(separator: ",")
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(success(strokeCommand(batches: "[[\(atPacket)]]"))))), "4096 admitted")
        let overPacket = (0..<4097).map { point($0, time: UInt32($0)) }.joined(separator: ",")
        decodeRejects(document(success(strokeCommand(batches: "[[\(overPacket)]]"))), "4097 rejected")

        // 65536 = 16 batches of 4096 (manual fixed strings), plus first => 65537
        var remaining = 65_536
        var time: UInt32 = 1
        var batches: [String] = []
        while remaining > 0 {
            let count = min(4096, remaining)
            let batch = (0..<count).map { _ in defer { time &+= 1 }; return point(1, time: time) }.joined(separator: ",")
            batches.append("[\(batch)]")
            remaining -= count
        }
        decodeRejects(document(success(strokeCommand(batches: "[\(batches.joined(separator: ","))]"))), "65537 rejected")

        // Independent strokes share the 100000-point file budget; first points count too.
        let identity = RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: inkUUID)
        let binding: RecorderBindingDescription = .ink(symbol: symbol, identity: identity)
        let brush = RecorderStrokeCommand.Settings(tool: .paintbrush, size: 8, opacity: 1, red: 0, green: 0, blue: 0, hardness: 0.5, pressureSize: false, antiErase: false)!
        let facts = EngineSession.StrokeCaptureFacts(brush: .init(name: "Owned Brush", collection: nil, isInternal: false),
                                                     fingerprint: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        let s32 = RecorderInkStrokeCommand(settings: brush, trace: try makeTrace(pointCount: 32_768), facts: facts)
        let s17 = RecorderInkStrokeCommand(settings: brush, trace: try makeTrace(pointCount: 17_232), facts: facts)
        let s50 = RecorderInkStrokeCommand(settings: brush, trace: try makeTrace(pointCount: 50_000), facts: facts)
        let boundary = makeFile(commands: [(s32, binding), (s17, binding), (s50, binding)])
        XCTAssertNoThrow(try RecorderFileCodec.encode(boundary), "100000 boundary")
        let tiny = RecorderInkStrokeCommand(settings: brush, trace: try makeTrace(pointCount: 1), facts: facts)
        let over = makeFile(commands: [(s32, binding), (s17, binding), (s50, binding), (tiny, binding)])
        XCTAssertThrowsError(try RecorderFileCodec.encode(over), "100001 rejected")
    }

    func testOldV15LabSelectionStillEncodesDecodesAs15() throws {
        let shape = #"{"tag":"labSelectionShape","shape":{"tag":"rectangle","rect":{"x":1,"y":2,"width":3,"height":4}},"options":{"operation":"replace","antialias":true,"feather":0,"cornerRadius":0}}"#
        let json = #"{"format":"ch.lkmc.Glims.recording","version":15,"recordingID":"11111111-2222-3333-4444-555555555555","name":"Old","origin":{"imageLabel":"i","initialWidth":8,"initialHeight":8},"symbols":[],"records":[{"ordinal":0,"outcome":"success","command":\#(shape),"binding":{"kind":"none"}}]}"#
        let decoded = try RecorderFileCodec.decode(bytes(json))
        let encoded = try RecorderFileCodec.encode(decoded)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 15)
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), decoded)
    }

    func testSnapshotEncodingSharesCountBudget() throws {
        // Snapshot must enforce the same aggregate budget as file encoding.
        let identity = RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: inkUUID)
        let brush = RecorderStrokeCommand.Settings(tool: .paintbrush, size: 8, opacity: 1, red: 0, green: 0, blue: 0, hardness: nil, pressureSize: false, antiErase: false)!
        let facts = EngineSession.StrokeCaptureFacts(brush: .init(name: "Owned Brush", collection: nil, isInternal: false),
                                                     fingerprint: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        func semanticStroke(_ n: Int) throws -> SemanticImageCommand {
            .completeInkStroke(RecorderInkStrokeCommand(settings: brush, trace: try makeTrace(pointCount: n), facts: facts))
        }
        let r1 = RecorderLog<SemanticImageCommand>.Record(ordinal: 0, resolution: .success(try semanticStroke(32_768)))
        let r2 = RecorderLog<SemanticImageCommand>.Record(ordinal: 1, resolution: .success(try semanticStroke(17_232)))
        let r3 = RecorderLog<SemanticImageCommand>.Record(ordinal: 2, resolution: .success(try semanticStroke(50_000)))
        let log = try RecorderLog<SemanticImageCommand>(settledRecords: [r1, r2, r3])
        let desc = RecorderTargetDescription(name: "Cyan", kind: .channel, ancestors: [], siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 1, height: 1))
        var catalog = RecorderDescriptionCatalog(); catalog.acceptFirst([symbol: .available(desc)])
        let bind: RecorderBindingDescription = .ink(symbol: symbol, identity: identity)
        XCTAssertNoThrow(try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "n", origin: .init(imageLabel: "i", initialWidth: 1, initialHeight: 1), descriptions: catalog, bindings: [0: bind, 1: bind, 2: bind]))
        let r4 = RecorderLog<SemanticImageCommand>.Record(ordinal: 3, resolution: .success(try semanticStroke(1)))
        let overLog = try RecorderLog<SemanticImageCommand>(settledRecords: [r1, r2, r3, r4])
        XCTAssertThrowsError(try RecorderFileCodec.snapshot(overLog, recordingID: recordingID, name: "n", origin: .init(imageLabel: "i", initialWidth: 1, initialHeight: 1), descriptions: catalog, bindings: [0: bind, 1: bind, 2: bind, 3: bind]))
    }
}
