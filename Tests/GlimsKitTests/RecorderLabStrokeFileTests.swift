import XCTest
@testable import GlimsKit

final class RecorderLabStrokeFileTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let symbol = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let axis = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!

    private func literal(version: Int,
                         command: String,
                         binding: String = """
                         {"kind":"lab","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","role":"a","precision":"u16","uuid":"01234567-89ab-cdef-0123-456789abcdef"}
                         """) -> Data {
        Data("""
        {"format":"ch.lkmc.Glims.recording","version":\(version),"recordingID":"11111111-2222-3333-4444-555555555555","name":"Lab stroke recording",
        "origin":{"imageLabel":"Lab.xcf","initialWidth":7,"initialHeight":9},
        "symbols":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","description":{"name":"a*","kind":"channel","ancestors":[],"siblingIndex":1,"bounds":{"x":0,"y":0,"width":7,"height":9}}}],
        "records":[{"ordinal":0,"outcome":"success","command":\(command),"binding":\(binding)}]}
        """.utf8)
    }

    private func strokeCommand(tag: String = "completeLabStroke",
                               value: String = "-64.25",
                               settingsExtra: String = "",
                               factsExtra: String = "",
                               firstExtra: String = "",
                               batch1FirstExtra: String = "",
                               batch1SecondExtra: String = "",
                               batch2Extra: String = "",
                               batches: String? = nil) -> String {
        let settings = #"{"value":\#(value),"size":9.5,"opacity":0.75,"hardness":0.4\#(settingsExtra)}"#
        let facts = #"{"brush":{"name":"Owned Brush","isInternal":false\#(factsExtra)},"fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"}"#
        let first = #"{"x":1,"y":2,"pressure":0.5,"xTilt":0.25,"yTilt":-0.25,"timeMilliseconds":4294967294\#(firstExtra)}"#
        let point1 = #"{"x":3,"y":4,"pressure":0.6,"xTilt":0.1,"yTilt":-0.1,"timeMilliseconds":4294967295\#(batch1FirstExtra)}"#
        let point2 = #"{"x":5,"y":6,"pressure":0.7,"xTilt":0.2,"yTilt":-0.2,"timeMilliseconds":0\#(batch1SecondExtra)}"#
        let point3 = #"{"x":7,"y":8,"pressure":0.8,"xTilt":0.3,"yTilt":-0.3,"timeMilliseconds":1\#(batch2Extra)}"#
        let bodyBatches = batches ?? "[[\(point1),\(point2)], [\(point3)]]"
        return #"{"tag":"\#(tag)","settings":\#(settings),"facts":\#(facts),"first":\#(first),"batches":\#(bodyBatches)}"#
    }

    private func ownedBrushFacts(collection: String? = nil) -> EngineSession.StrokeCaptureFacts {
        .init(brush: .init(name: "Owned Brush", collection: collection, isInternal: false),
              fingerprint: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
    }

    func testVersion14LabStrokeRoundTripsPhysicalValueAndOptionalSemantics() throws {
        // Hand-authored golden literal (never encoder-produced). Rotation/tangential are
        // absent vs present-0 as distinct file facts; timestamps wrap modularly across batches.
        let command = strokeCommand(
            firstExtra: "",
            batch1FirstExtra: #","rotationTurns":0"#,          // present 0
            batch1SecondExtra: #","tangentialPressure":0"#,    // present 0, rotation absent
            batch2Extra: #","rotationTurns":0.125,"tangentialPressure":-0.5"#
        )
        let data = literal(version: 14, command: command)
        let decoded = try RecorderFileCodec.decode(data)

        XCTAssertEqual(decoded.recordingID, recordingID)
        XCTAssertEqual(decoded.records.count, 1)
        guard case .success(.completeLabStroke(let stroke), .lab(let bound, let identity)) = decoded.records[0].outcome else {
            return XCTFail("Expected v14 Lab stroke with Lab binding")
        }
        XCTAssertEqual(bound, symbol)
        XCTAssertEqual(identity, RecorderLabIdentity(role: .a, precision: .u16, uuid: axis))
        XCTAssertEqual(stroke.settings.value, -64.25)
        XCTAssertEqual(stroke.settings.size, 9.5)
        XCTAssertEqual(stroke.settings.opacity, 0.75)
        XCTAssertEqual(stroke.settings.hardness, 0.4)
        XCTAssertEqual(stroke.facts, ownedBrushFacts())
        let expectedTrace = RecorderTabletStrokeTrace(
            first: try .init(x: 1, y: 2, pressure: 0.5, xTilt: 0.25, yTilt: -0.25,
                             timeMilliseconds: 4_294_967_294),
            batches: [[
                try .init(x: 3, y: 4, pressure: 0.6, xTilt: 0.1, yTilt: -0.1,
                          timeMilliseconds: 4_294_967_295, rotationTurns: 0),
                try .init(x: 5, y: 6, pressure: 0.7, xTilt: 0.2, yTilt: -0.2,
                          timeMilliseconds: 0, tangentialPressure: 0),
            ], [
                try .init(x: 7, y: 8, pressure: 0.8, xTilt: 0.3, yTilt: -0.3,
                          timeMilliseconds: 1, rotationTurns: 0.125, tangentialPressure: -0.5),
            ]])
        XCTAssertEqual(stroke.trace, expectedTrace)
        XCTAssertEqual(stroke.trace.first.timeMilliseconds, 4_294_967_294)
        XCTAssertNil(stroke.trace.first.rotationTurns)
        XCTAssertNil(stroke.trace.first.tangentialPressure)
        XCTAssertEqual(stroke.trace.batches.count, 2)
        XCTAssertEqual(stroke.trace.batches[0].count, 2)
        XCTAssertEqual(stroke.trace.batches[0][0].timeMilliseconds, 4_294_967_295)
        XCTAssertEqual(stroke.trace.batches[0][0].rotationTurns, 0)
        XCTAssertNil(stroke.trace.batches[0][0].tangentialPressure)
        XCTAssertEqual(stroke.trace.batches[0][1].timeMilliseconds, 0)
        XCTAssertNil(stroke.trace.batches[0][1].rotationTurns)
        XCTAssertEqual(stroke.trace.batches[0][1].tangentialPressure, 0)
        XCTAssertEqual(stroke.trace.batches[1][0].rotationTurns, 0.125)
        XCTAssertEqual(stroke.trace.batches[1][0].tangentialPressure, -0.5)

        let encoded = try RecorderFileCodec.encode(decoded)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 14)
        let rows = try XCTUnwrap(json["records"] as? [[String: Any]])
        let encodedCommand = try XCTUnwrap(rows.first?["command"] as? [String: Any])
        let encodedSettings = try XCTUnwrap(encodedCommand["settings"] as? [String: Any])
        XCTAssertEqual(Set(encodedSettings.keys), Set(["value", "size", "opacity", "hardness"]))
        let encodedFirst = try XCTUnwrap(encodedCommand["first"] as? [String: Any])
        XCTAssertEqual(Set(encodedFirst.keys), Set(["x", "y", "pressure", "xTilt", "yTilt", "timeMilliseconds"]))
        let roundTripped = try RecorderFileCodec.decode(encoded)
        XCTAssertEqual(roundTripped, decoded)
        guard case .success(.completeLabStroke(let roundTripStroke), _) = roundTripped.records[0].outcome else {
            return XCTFail("Round trip lost Lab stroke")
        }
        XCTAssertNil(roundTripStroke.trace.first.rotationTurns)
        XCTAssertEqual(roundTripStroke.trace.batches[0][0].rotationTurns, 0) // present 0 preserved
        XCTAssertNil(roundTripStroke.trace.batches[0][0].tangentialPressure)
        XCTAssertEqual(roundTripStroke.trace.batches[0][1].tangentialPressure, 0)
    }

    func testLabStrokeTagRequiresVersion14() {
        let command = strokeCommand()
        for version in 1...13 {
            XCTAssertThrowsError(try RecorderFileCodec.decode(literal(version: version, command: command)),
                                 "completeLabStroke must be rejected for version \(version)")
        }
    }

    func testMalformedLabStrokeLiteralsAreRejected() {
        let baseline = literal(version: 14, command: strokeCommand(
            firstExtra: #","rotationTurns":0,"tangentialPressure":0"#,
            batch1FirstExtra: #","rotationTurns":0"#,
            batch1SecondExtra: #","tangentialPressure":0"#,
            batch2Extra: #","rotationTurns":0.125,"tangentialPressure":-0.5"#))
        XCTAssertNoThrow(try RecorderFileCodec.decode(baseline), "Malformed cases start from a valid literal")
        func reject(_ mutate: (inout String) -> Void, _ name: String, file: StaticString = #filePath, line: UInt = #line) {
            let original = String(decoding: baseline, as: UTF8.self)
            var text = original
            mutate(&text)
            XCTAssertNotEqual(text, original, "Mutation must change its intended field: \(name)", file: file, line: line)
            XCTAssertThrowsError(try RecorderFileCodec.decode(Data(text.utf8)), name, file: file, line: line)
        }

        reject({ $0 = $0.replacingOccurrences(of: "\"hardness\":0.4", with: "\"hardness\":0.4,\"extra\":1") }, "unknown settings key")
        reject({ $0 = $0.replacingOccurrences(of: ",\"hardness\":0.4", with: "") }, "missing settings key")
        reject({ $0 = $0.replacingOccurrences(of: "\"facts\":{\"brush\"", with: "\"facts\":{\"extra\":true,\"brush\"") }, "unknown facts key")
        reject({ $0 = $0.replacingOccurrences(of: "\"name\":\"Owned Brush\"", with: "\"name\":\"Owned Brush\",\"nativeID\":7") }, "unknown brush identity key")
        reject({ $0 = $0.replacingOccurrences(of: "\"x\":1,\"y\":2", with: "\"x\":1,\"y\":2,\"nativeSample\":0") }, "unknown point key")
        reject({ $0 = $0.replacingOccurrences(of: "\"x\":1,", with: "") }, "missing required point key")
        reject({ $0 = $0.replacingOccurrences(of: "\"fingerprint\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"",
                                              with: "\"fingerprint\":\"0123456789ABCDEF0123456789abcdef0123456789abcdef0123456789abcdef\"") }, "non-lower-hex fingerprint")
        reject({ $0 = $0.replacingOccurrences(of: "\"fingerprint\":\"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\"",
                                              with: "\"fingerprint\":\"0123\"") }, "short fingerprint")
        reject({ $0 = $0.replacingOccurrences(of: "\"timeMilliseconds\":4294967294", with: "\"timeMilliseconds\":-1") }, "negative timestamp")
        reject({ $0 = $0.replacingOccurrences(of: "\"timeMilliseconds\":4294967294", with: "\"timeMilliseconds\":4294967296") }, "oversized timestamp")
        reject({ $0 = $0.replacingOccurrences(of: "\"timeMilliseconds\":4294967294", with: "\"timeMilliseconds\":1.5") }, "non-integer timestamp")
        reject({ $0 = $0.replacingOccurrences(of: "\"pressure\":0.5", with: "\"pressure\":\"0.5\"") }, "wrong point type")
        reject({ $0 = $0.replacingOccurrences(of: "\"rotationTurns\":0.125", with: "\"rotationTurns\":null") }, "null optional rotation")
        reject({ $0 = $0.replacingOccurrences(of: "\"tangentialPressure\":-0.5", with: "\"tangentialPressure\":null") }, "null optional tangential")
        reject({ $0 = $0.replacingOccurrences(of: "\"rotationTurns\":0,\"tangentialPressure\":0", with: "\"rotationTurns\":null,\"tangentialPressure\":0") }, "null first-point rotation")
        reject({ $0 = $0.replacingOccurrences(of: "\"isInternal\":false", with: "\"isInternal\":false,\"collection\":null") }, "null optional collection")
        reject({ $0 = $0.replacingOccurrences(of: "\"rotationTurns\":0.125", with: "\"rotationTurns\":1") }, "rotation out of range")
        reject({ $0 = $0.replacingOccurrences(of: "\"tangentialPressure\":-0.5", with: "\"tangentialPressure\":1.5") }, "tangential out of range")
        reject({ $0 = $0.replacingOccurrences(of: "\"pressure\":0.5", with: "\"pressure\":2") }, "point out of range")
        reject({ $0 = $0.replacingOccurrences(of: "\"x\":1", with: "\"x\":1e309") }, "non-finite point")
        reject({ $0 = $0.replacingOccurrences(of: "\"value\":-64.25", with: "\"value\":\"-64.25\"") }, "wrong settings type")
        reject({ $0 = $0.replacingOccurrences(of: "\"size\":9.5", with: "\"size\":null") }, "null settings")
        reject({ $0 = $0.replacingOccurrences(of: "\"isInternal\":false", with: "\"isInternal\":0") }, "wrong facts type")
        reject({ $0 = $0.replacingOccurrences(of: "\"name\":\"Owned Brush\"", with: "\"name\":\"\"") }, "empty brush name")
        reject({ $0 = $0.replacingOccurrences(of: "[{\"x\":3,\"y\":4,\"pressure\":0.6,\"xTilt\":0.1,\"yTilt\":-0.1,\"timeMilliseconds\":4294967295,\"rotationTurns\":0},{\"x\":5,\"y\":6,\"pressure\":0.7,\"xTilt\":0.2,\"yTilt\":-0.2,\"timeMilliseconds\":0,\"tangentialPressure\":0}]",
                                              with: "[]") }, "empty batch")
        reject({ $0 = $0.replacingOccurrences(of: "\"timeMilliseconds\":1,\"rotationTurns\":0.125",
                                              with: "\"timeMilliseconds\":4294967295,\"rotationTurns\":0.125") }, "timestamp backward across boundary")
    }

    func testLiteralPacketAndWholeStrokeLimitsAreIndependent() {
        func point(_ i: Int, time: UInt32) -> String {
            #"{"x":\#(i),"y":1,"pressure":0.5,"xTilt":0,"yTilt":0,"timeMilliseconds":\#(time)}"#
        }

        // Excessive packet: one batch with 4097 points. (4096 is the packet cap)
        let atPacketLimit = (0..<4096).map { point($0, time: UInt32($0)) }.joined(separator: ",")
        XCTAssertNoThrow(try RecorderFileCodec.decode(literal(version: 14,
            command: strokeCommand(batches: "[[\(atPacketLimit)]]"))), "4096 samples with valid timestamp order are admitted")
        let oversizedBatch = (0..<4097).map { point($0, time: UInt32($0)) }.joined(separator: ",")
        let oversizedPacket = strokeCommand(batches: "[[\(oversizedBatch)]]")
        XCTAssertThrowsError(try RecorderFileCodec.decode(literal(version: 14, command: oversizedPacket)))

        // Excessive total stroke: 65537 points = first + 65536 in 16 batches of 4096.
        // Construct many short fixed manual point strings; isolate count failure, not huge single batch.
        var remaining = 65_536
        var time: UInt32 = 1
        var batches: [String] = []
        while remaining > 0 {
            let count = min(4096, remaining)
            let batch = (0..<count).map { _ in
                defer { time &+= 1 }
                return point(1, time: time)
            }.joined(separator: ",")
            batches.append("[\(batch)]")
            remaining -= count
        }
        XCTAssertEqual(batches.count, 16)
        XCTAssertEqual(batches.last.map { $0.filter { $0 == "{" }.count }, 4096)
        let oversizedStroke = strokeCommand(batches: "[\(batches.joined(separator: ","))]")
        XCTAssertThrowsError(try RecorderFileCodec.decode(literal(version: 14, command: oversizedStroke)))
    }

    func testCallerCreatedInvalidStrokesAndCumulativeFileBudget() throws {
        let facts = ownedBrushFacts()
        let first = try RecorderTabletStrokeTrace.Point(x: 0, y: 0, pressure: 0.5, xTilt: 0, yTilt: 0, timeMilliseconds: 0)
        let validBatch = try [RecorderTabletStrokeTrace.Point(x: 1, y: 1, pressure: 0.5, xTilt: 0, yTilt: 0, timeMilliseconds: 1)]
        let validTrace = RecorderTabletStrokeTrace(first: first, batches: [validBatch]) // 2 points
        let validSettings = RecorderLabStrokeCommand.Settings(value: 0, size: 8, opacity: 1, hardness: 0.5)
        let validStroke = try RecorderLabStrokeCommand(settings: validSettings, trace: validTrace, facts: facts).validated()
        XCTAssertNoThrow(try RecorderFileCodec.encode(makeLabStrokeFile(
            commands: [(validStroke, identity(role: .lightness, precision: .u16))])))

        let backwardFirst = try RecorderTabletStrokeTrace.Point(
            x: 0, y: 0, pressure: 0.5, xTilt: 0, yTilt: 0, timeMilliseconds: 2)
        for invalidTrace in [
            RecorderTabletStrokeTrace(first: first, batches: [[]]),
            RecorderTabletStrokeTrace(first: backwardFirst, batches: [validBatch]),
        ] {
            let invalidStroke = RecorderLabStrokeCommand(settings: validSettings, trace: invalidTrace, facts: facts)
            let badFile = try makeLabStrokeFile(commands: [(invalidStroke, identity(role: .lightness, precision: .u16))])
            XCTAssertThrowsError(try RecorderFileCodec.encode(badFile), "Caller-created invalid trace must not encode")
        }

        // Cumulative file point budget is 100000 across successful polygons/strokes.
        // Build individually valid traces (<=65536 points, batches <=4096) to exercise file budget.
        let boundIdentity = RecorderLabIdentity(role: .a, precision: .u16, uuid: axis)
        let part32k = try makeTrace(pointCount: 32_768) // 32768
        let part17k = try makeTrace(pointCount: 17_232) // total 50000
        let part50k = try makeTrace(pointCount: 50_000) // total 100000 boundary
        let boundary = try makeLabStrokeFile(commands: [
            (RecorderLabStrokeCommand(settings: validSettings, trace: part32k, facts: facts), boundIdentity),
            (RecorderLabStrokeCommand(settings: validSettings, trace: part17k, facts: facts), boundIdentity),
            (RecorderLabStrokeCommand(settings: validSettings, trace: part50k, facts: facts), boundIdentity),
        ])
        XCTAssertNoThrow(try RecorderFileCodec.encode(boundary), "Cumulative 100000 points should be accepted")

        let tiny = validTrace
        let overBudget = try makeLabStrokeFile(commands: [
            (RecorderLabStrokeCommand(settings: validSettings, trace: part32k, facts: facts), boundIdentity),
            (RecorderLabStrokeCommand(settings: validSettings, trace: part17k, facts: facts), boundIdentity),
            (RecorderLabStrokeCommand(settings: validSettings, trace: part50k, facts: facts), boundIdentity),
            (RecorderLabStrokeCommand(settings: validSettings, trace: tiny, facts: facts), boundIdentity),
        ])
        XCTAssertThrowsError(try RecorderFileCodec.encode(overBudget), "Cumulative points above 100000 must be refused")

        // Sanity: decoded valid command can be constructed through direct initializer path.
        let decodedValid = try RecorderFileCodec.decode(literal(version: 14, command: strokeCommand()))
        guard case .success(.completeLabStroke(let decodedStroke), _) = decodedValid.records[0].outcome else {
            return XCTFail("Expected decoded Lab stroke")
        }
        _ = try RecorderLabStrokeCommand(settings: decodedStroke.settings, trace: decodedStroke.trace, facts: decodedStroke.facts).validated()
    }

    func testPhysicalRolePrecisionAndRangeRules() throws {
        let trace = try makeTrace(pointCount: 2)
        func encodeStroke(role: RecorderLabIdentity.Role, precision: RecorderLabIdentity.Precision, value: Double) throws {
            let settings = RecorderLabStrokeCommand.Settings(value: value, size: 8, opacity: 1, hardness: 0.5)
            let command = RecorderLabStrokeCommand(settings: settings, trace: trace, facts: ownedBrushFacts())
            let file = try makeLabStrokeFile(commands: [(command, identity(role: role, precision: precision))])
            _ = try RecorderFileCodec.encode(file)
        }

        // Nominal physical ranges are valid for integer precisions.
        for precision in [RecorderLabIdentity.Precision.u8, .u16] {
            XCTAssertNoThrow(try encodeStroke(role: .lightness, precision: precision, value: 0))
            XCTAssertNoThrow(try encodeStroke(role: .lightness, precision: precision, value: 100))
            XCTAssertNoThrow(try encodeStroke(role: .a, precision: precision, value: -128))
            XCTAssertNoThrow(try encodeStroke(role: .a, precision: precision, value: 127))
            XCTAssertNoThrow(try encodeStroke(role: .b, precision: precision, value: -128))
            XCTAssertNoThrow(try encodeStroke(role: .b, precision: precision, value: 127))
            // Out of nominal but finite is accepted for float only.
            XCTAssertThrowsError(try encodeStroke(role: .lightness, precision: precision, value: 100.001))
            XCTAssertThrowsError(try encodeStroke(role: .a, precision: precision, value: 127.001))
            XCTAssertThrowsError(try encodeStroke(role: .b, precision: precision, value: -128.001))
        }
        XCTAssertNoThrow(try encodeStroke(role: .lightness, precision: .float, value: 100.001))
        XCTAssertNoThrow(try encodeStroke(role: .a, precision: .float, value: 127.001))
        XCTAssertNoThrow(try encodeStroke(role: .b, precision: .float, value: -128.001))
        XCTAssertNoThrow(try encodeStroke(role: .a, precision: .float, value: Double(Float.greatestFiniteMagnitude)))

        // Above Float.max is refused (no broad legal/color assumptions beyond file contract).
        XCTAssertThrowsError(try encodeStroke(role: .a, precision: .float, value: Double(Float.greatestFiniteMagnitude) * 2))
        XCTAssertThrowsError(try encodeStroke(role: .lightness, precision: .u16, value: .infinity))
    }

    func testHandAuthoredVersion13FillLabStillRoundTripsAsVersion13() throws {
        let command = #"{"tag":"fillLab","value":-0.5,"opacity":0.75}"#
        let data = literal(version: 13, command: command)
        let decoded = try RecorderFileCodec.decode(data)
        guard case .success(.fillLab(let fill), .lab(let bound, let identity)) = decoded.records[0].outcome else {
            return XCTFail("Expected v13 Lab fill")
        }
        XCTAssertEqual(bound, symbol)
        XCTAssertEqual(identity, RecorderLabIdentity(role: .a, precision: .u16, uuid: axis))
        XCTAssertEqual(fill.value, -0.5)
        XCTAssertEqual(fill.opacity, 0.75)

        let encoded = try RecorderFileCodec.encode(decoded)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 13, "Old v13 Lab fill must continue to encode as v13")
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), decoded)
    }

    private func identity(role: RecorderLabIdentity.Role, precision: RecorderLabIdentity.Precision) -> RecorderLabIdentity {
        .init(role: role, precision: precision, uuid: axis)
    }

    private func makeLabStrokeFile(commands: [(RecorderLabStrokeCommand, RecorderLabIdentity)]) throws -> RecorderFileValue {
        let symbols = [RecorderFileValue.Symbol(id: symbol, description: .init(name: "a*", kind: .channel, ancestors: [], siblingIndex: 1,
            bounds: .init(x: 0, y: 0, width: 7, height: 9)))]
        let records = commands.enumerated().map { index, pair in
            RecorderFileValue.Record(ordinal: index, outcome: .success(.completeLabStroke(pair.0), .lab(symbol: symbol, identity: pair.1)))
        }
        return RecorderFileValue(recordingID: recordingID, name: "Lab stroke recording",
            origin: .init(imageLabel: "Lab.xcf", initialWidth: 7, initialHeight: 9), symbols: symbols, records: records)
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
        let trace = RecorderTabletStrokeTrace(first: first, batches: batches)
        XCTAssertEqual(1 + batches.reduce(0) { $0 + $1.count }, pointCount)
        return trace
    }
}
