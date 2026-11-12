import XCTest
@testable import GlimsKit

/// Recorder v12 ink Curves: exact 256-sample table on explicitly bound ink.
/// Decode fixtures are spelled out; encode/decode and bridge/snapshot are
/// asserted independently of production self-oracles where possible.
final class RecorderInkCurvesTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let symbol = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let inkUUID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

    private var origin: RecorderFileValue.Origin {
        .init(imageLabel: "Ink.tif", initialWidth: 41, initialHeight: 29)
    }

    private var targetDescription: RecorderTargetDescription {
        .init(name: "Cyan", kind: .channel, ancestors: [],
              siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
    }

    private var catalog: RecorderDescriptionCatalog {
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(targetDescription)])
        return catalog
    }

    private var cmykIdentity: RecorderInkIdentity { .init(mode: .cmyk, role: .cyan, uuid: inkUUID) }
    private var multiIdentity: RecorderInkIdentity { .init(mode: .multichannel, role: .unspecified, uuid: inkUUID) }

    private var inkBinding: RecorderBindingDescription { .ink(symbol: symbol, identity: cmykIdentity) }
    private var multiBinding: RecorderBindingDescription { .ink(symbol: symbol, identity: multiIdentity) }

    private func identitySamples() -> [Double] { (0..<256).map { Double($0) / 255.0 } }
    private func exactTable() -> [Double] {
        // All 256 exact, finite, in-range, nonmonotone values.
        (0..<256).map { i in
            let t = Double(i) / 255.0
            let wave = (Double((i * 37) % 256) / 255.0)
            return i == 0 ? 0 : (i == 255 ? 1 : (t * 0.35 + wave * 0.65))
        }
    }

    private func samplesJSON(_ samples: [Double]) -> String {
        "[" + samples.map { String($0) }.joined(separator: ",") + "]"
    }

    private let channelSymbolJSON = #"{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","description":{"name":"Cyan","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let layerSymbolJSON = #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let quickSymbolJSON = #"{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","description":{"name":"Quick","kind":"quickMask","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let cmykBindingJSON = #"{"kind":"ink","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","mode":"cmyk","role":"cyan","uuid":"01234567-89ab-cdef-0123-456789abcdef"}"#
    private let multiBindingJSON = #"{"kind":"ink","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","mode":"multichannel","role":"unspecified","uuid":"01234567-89ab-cdef-0123-456789abcdef"}"#
    private let layerBindingJSON = #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#

    private func commandJSON(samples: [Double]) -> String {
        #"{"tag":"applyInkCurves","samples":"# + samplesJSON(samples) + "}"
    }

    private func document(rows: String, symbols: String, version: Int = 12) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-2222-3333-4444-555555555555","name":"Ink","origin":{"imageLabel":"Ink.tif","initialWidth":41,"initialHeight":29},"symbols":["#
            + symbols + #"],"records":["# + rows + "]}"
    }

    private func success(_ command: String, binding: String, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func replace(_ text: String, _ before: String, _ after: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let range = text.range(of: before) else { XCTFail("Fixture mutation did not match: \(before)", file: file, line: line); return text }
        return text.replacingCharacters(in: range, with: after)
    }

    // MARK: - Exact table save/load/bridge

    func testExactAll256TableSaveLoadAndBridgeRoundTrip() throws {
        let samples = exactTable()
        XCTAssertEqual(samples.count, 256)
        let fileCurves = RecorderFileCommand.InkCurves(samples: samples)
        XCTAssertTrue(fileCurves.isValid)

        let literal = document(rows: success(commandJSON(samples: samples), binding: cmykBindingJSON), symbols: channelSymbolJSON)
        let decoded = try RecorderFileCodec.decode(bytes(literal))
        guard case .success(.applyInkCurves(let value), .ink(let id, let identity)) = decoded.records[0].outcome else {
            return XCTFail("Expected applyInkCurves with ink binding")
        }
        XCTAssertEqual(id, symbol)
        XCTAssertEqual(identity, cmykIdentity)
        XCTAssertEqual(value.samples, samples, "All 256 samples must round-trip exactly")

        let encoded = try RecorderFileCodec.encode(decoded)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains(#""version":12"#))
        XCTAssertTrue(json.contains(#""tag":"applyInkCurves""#))
        XCTAssertTrue(json.contains(#""samples":["#))
        XCTAssertFalse(json.contains(#""trc""#), "Ink curves must not carry RGB/TRC tags")
        XCTAssertFalse(json.contains(#""value""#), "Ink curves must not carry named RGB channels")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rows = try XCTUnwrap(root["records"] as? [[String: Any]])
        let encodedCommand = try XCTUnwrap(rows.first?["command"] as? [String: Any])
        XCTAssertEqual(Set(encodedCommand.keys), ["tag", "samples"], "No native IDs or unrelated fields")
        let redecoded = try RecorderFileCodec.decode(encoded)
        XCTAssertEqual(redecoded, decoded)

        // Semantic/file bridge round-trip
        let prepared = try RecorderFileSemanticBridge.prepare(decoded)
        guard case .success(let command) = prepared.log.records[0].resolution,
              case .applyInkCurves(let semantic) = command else {
            return XCTFail("Expected semantic applyInkCurves")
        }
        XCTAssertEqual(semantic.samples, samples)
        XCTAssertEqual(command.title, "Ink Curves")
        XCTAssertTrue(command.requiresResolvedFloatingSelection)
        XCTAssertFalse(command.isLayerAdjustment)
        let back = try RecorderFileCommand(command)
        XCTAssertEqual(back, .applyInkCurves(fileCurves))

        // Detached snapshot preserves exact samples and binding
        let snapshot = try RecorderFileCodec.snapshot(prepared.log, recordingID: recordingID, name: "Ink",
                                                     origin: origin, descriptions: catalog,
                                                     bindings: [0: inkBinding])
        XCTAssertEqual(snapshot, decoded)
    }

    func testIdentitySamplesAndBothInkModesSurvive() throws {
        let samples = identitySamples()
        for (bindingJSON, binding, identity) in [
            (cmykBindingJSON, inkBinding, cmykIdentity),
            (multiBindingJSON, multiBinding, multiIdentity),
        ] {
            let literal = document(rows: success(commandJSON(samples: samples), binding: bindingJSON), symbols: channelSymbolJSON)
            let decoded = try RecorderFileCodec.decode(bytes(literal))
            guard case .success(.applyInkCurves(let value), .ink(_, let got)) = decoded.records[0].outcome else {
                return XCTFail("Expected applyInkCurves")
            }
            XCTAssertEqual(value.samples, samples)
            XCTAssertEqual(got, identity)
            XCTAssertTrue(got.isValid)
            let prepared = try RecorderFileSemanticBridge.prepare(decoded)
            let snapshot = try RecorderFileCodec.snapshot(prepared.log, recordingID: recordingID, name: "Ink",
                                                         origin: origin, descriptions: catalog, bindings: [0: binding])
            XCTAssertEqual(snapshot, decoded)
        }
    }

    // MARK: - Family-specific minimum version / old behavior preserved

    func testVersionTwelveRequiredOnlyForApplyInkCurvesAndRejectsOldVersion() throws {
        let samples = identitySamples()
        let curvesRow = success(commandJSON(samples: samples), binding: cmykBindingJSON)
        // v11 and below must reject applyInkCurves
        for version in 1...11 {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows: curvesRow, symbols: channelSymbolJSON, version: version))),
                                 "applyInkCurves must need v12 in v\(version)")
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows: curvesRow, symbols: channelSymbolJSON, version: 13))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(document(rows: curvesRow, symbols: channelSymbolJSON), #""version":12"#, #""version":"12""#))))

        // v12 requires at least one successful applyInkCurves
        let editInk = #"{"tag":"editInk","operation":"fill","intensity":0.25,"opacity":0.5}"#
        let v12NoCurves = document(rows: success(editInk, binding: cmykBindingJSON), symbols: channelSymbolJSON, version: 12)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(v12NoCurves)))

        // Existing families keep their version selection/behavior (v11 for ink edit/levels only)
        let v11 = document(rows: success(editInk, binding: cmykBindingJSON), symbols: channelSymbolJSON, version: 11)
        let decodedV11 = try RecorderFileCodec.decode(bytes(v11))
        let encodedV11 = try RecorderFileCodec.encode(decodedV11)
        XCTAssertTrue(String(decoding: encodedV11, as: UTF8.self).contains(#""version":11"#), "editInk/applyInkLevels must not silently become v12")

        let inkLevels = #"{"tag":"applyInkLevels","lowInput":0.1,"highInput":0.9,"gamma":2.0,"lowOutput":0.2,"highOutput":0.8,"clampInput":true,"clampOutput":false}"#
        let v11Levels = document(rows: success(inkLevels, binding: cmykBindingJSON), symbols: channelSymbolJSON, version: 11)
        let decodedLevels = try RecorderFileCodec.decode(bytes(v11Levels))
        XCTAssertTrue(String(decoding: try RecorderFileCodec.encode(decodedLevels), as: UTF8.self).contains(#""version":11"#))

        // Mixed ink command families: highest required version is v12 when curves present
        let mixed = document(rows: success(editInk, binding: cmykBindingJSON) + "," + success(curvesRowCommand(), binding: cmykBindingJSON, ordinal: 1),
                             symbols: channelSymbolJSON)
        let decodedMixed = try RecorderFileCodec.decode(bytes(mixed))
        XCTAssertTrue(String(decoding: try RecorderFileCodec.encode(decodedMixed), as: UTF8.self).contains(#""version":12"#))

        // v1..10 rules unchanged (v1 still valid for independent command)
        let v1 = #"{"format":"ch.lkmc.Glims.recording","version":1,"recordingID":"11111111-2222-3333-4444-555555555555","name":"S","origin":{"imageLabel":"A","initialWidth":1,"initialHeight":1},"symbols":[],"records":[{"ordinal":0,"outcome":"success","command":{"tag":"scale","width":1,"height":1},"binding":{"kind":"none"}}]}"#
        XCTAssertEqual(try RecorderFileCodec.decode(bytes(v1)).records.count, 1)
    }

    private func curvesRowCommand(samples: [Double]? = nil) -> String { commandJSON(samples: samples ?? identitySamples()) }

    // MARK: - Malformed count/unit/nonfinite/unknown fields and no native IDs

    func testMalformedCurvesRejectedByDecodeAndEncode() {
        let samples = identitySamples()
        let base = document(rows: success(commandJSON(samples: samples), binding: cmykBindingJSON), symbols: channelSymbolJSON)

        // unknown/extra fields, wrong structure, no native IDs
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(base, #""tag":"applyInkCurves""#, #""tag":"applyInkCurves","future":0"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(base, #""tag":"applyInkCurves""#, #""tag":"applyInkCurves","ordinal":1"#))))
        let nested = #"{"tag":"applyInkCurves","settings":{"samples":"# + samplesJSON(samples) + "}}"
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows: success(nested, binding: cmykBindingJSON), symbols: channelSymbolJSON))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(base, #""tag":"applyInkCurves""#, #""tag":"applyInkCurves","channel":1234"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(base, #""samples":"#, #""trc":"linear","samples":"#))))

        // wrong count
        let short = document(rows: success(commandJSON(samples: Array(samples.dropLast())), binding: cmykBindingJSON), symbols: channelSymbolJSON)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(short)))
        let long = document(rows: success(commandJSON(samples: samples + [0.5]), binding: cmykBindingJSON), symbols: channelSymbolJSON)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(long)))
        let empty = document(rows: success(#"{"tag":"applyInkCurves","samples":[]}"#, binding: cmykBindingJSON), symbols: channelSymbolJSON)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(empty)))

        // non-finite / out of unit range
        func badSample(_ v: String) -> String {
            var s = samples.map { String($0) }
            s[10] = v
            return "[" + s.joined(separator: ",") + "]"
        }
        for bad in ["1e309", "NaN", "Infinity", "-Infinity", "\"0.5\"", "true", "-0.0000001", "1.0000001"] {
            let mutated = document(rows: success(#"{"tag":"applyInkCurves","samples":"# + badSample(bad) + "}", binding: cmykBindingJSON), symbols: channelSymbolJSON)
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(mutated)), "should reject sample \(bad)")
        }

        // encode validates caller-created values with same rules
        let desc = targetDescription
        func makeValue(_ samples: [Double], identity: RecorderInkIdentity = RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!)) -> RecorderFileValue {
            .init(recordingID: recordingID, name: "Ink", origin: origin,
                  symbols: [.init(id: symbol, description: desc)],
                  records: [.init(ordinal: 0, outcome: .success(.applyInkCurves(.init(samples: samples)), .ink(symbol: symbol, identity: identity)))])
        }
        XCTAssertThrowsError(try RecorderFileCodec.encode(makeValue(Array(samples.dropLast()))))
        var nan = samples; nan[0] = .nan
        XCTAssertThrowsError(try RecorderFileCodec.encode(makeValue(nan)))
        var below = samples; below[1] = -0.1
        XCTAssertThrowsError(try RecorderFileCodec.encode(makeValue(below)))
        var above = samples; above[2] = 1.1
        XCTAssertThrowsError(try RecorderFileCodec.encode(makeValue(above)))
        var nonMonotone = samples; nonMonotone.swapAt(10, 20)
        XCTAssertNoThrow(try RecorderFileCodec.encode(makeValue(nonMonotone)), "nonmonotone table is valid")
    }

    // MARK: - Ink binding, identity compatibility, no native IDs

    func testInkTargetBindingAndCompatibilityChecksForCurves() throws {
        let samples = identitySamples()
        let row = success(commandJSON(samples: samples), binding: cmykBindingJSON)

        // Must be ink binding on channel symbol with valid consistent identity
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows: row, symbols: quickSymbolJSON))), "needs channel description")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows: success(commandJSON(samples: samples), binding: layerBindingJSON), symbols: channelSymbolJSON + "," + layerSymbolJSON))), "binding kind mismatch")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows: success(commandJSON(samples: samples), binding: #"{"kind":"channel","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#), symbols: channelSymbolJSON))))

        // Invalid / incompatible identity (mode-role mismatch, zero uuid) rejected
        let zero = replace(cmykBindingJSON, #""uuid":"01234567-89ab-cdef-0123-456789abcdef""#, #""uuid":"00000000-0000-0000-0000-000000000000""#)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows: success(commandJSON(samples: samples), binding: zero), symbols: channelSymbolJSON))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows: success(commandJSON(samples: samples), binding: replace(cmykBindingJSON, #""role":"cyan""#, #""role":"unspecified""#)), symbols: channelSymbolJSON))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows: success(commandJSON(samples: samples), binding: replace(multiBindingJSON, #""role":"unspecified""#, #""role":"cyan""#)), symbols: channelSymbolJSON))))

        // Same identity checks as existing ink families (mode/role/UUID) and no auto/cross-image/global binding: file keeps durable UUID+role+mode and snapshot/bridge require explicit binding.
        let otherUUID = replace(cmykBindingJSON, #""uuid":"01234567-89ab-cdef-0123-456789abcdef""#, #""uuid":"55555555-5555-5555-5555-555555555555""#)
        let rowsInconsistent = row + "," + success(commandJSON(samples: samples), binding: otherUUID, ordinal: 1)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows: rowsInconsistent, symbols: channelSymbolJSON))), "inconsistent identity across records")

        // Exhaustive compatibility with existing ink replay preflight semantics: matching in owning doc requires mode/role/uuid equality; explicit destination permission requires mode/role.
        let recorded = cmykIdentity
        let same = RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: inkUUID)
        let differentUUID = RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!)
        let differentRole = RecorderInkIdentity(mode: .cmyk, role: .magenta, uuid: inkUUID)
        let differentMode = RecorderInkIdentity(mode: .multichannel, role: .unspecified, uuid: inkUUID)
        XCTAssertTrue(recorded.permitsExplicitBinding(to: same))
        XCTAssertTrue(recorded.matchesInOwningDocument(same))
        XCTAssertTrue(recorded.permitsExplicitBinding(to: differentUUID), "explicit binding checks role/mode, not UUID")
        XCTAssertFalse(recorded.matchesInOwningDocument(differentUUID), "owning-doc replay requires UUID equality")
        XCTAssertFalse(recorded.permitsExplicitBinding(to: differentRole))
        XCTAssertFalse(recorded.permitsExplicitBinding(to: differentMode))
        XCTAssertFalse(recorded.matchesInOwningDocument(differentRole))
        XCTAssertFalse(recorded.matchesInOwningDocument(differentMode))

        // Snapshot refuses missing/wrong binding for applyInkCurves
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.applyInkCurves(EngineSession.InkCurvesSettings(samples: samples))))
        try log.stopRecording()
        func snapshot(_ bindings: [Int: RecorderBindingDescription]) throws -> RecorderFileValue {
            try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Ink", origin: origin, descriptions: catalog, bindings: bindings)
        }
        XCTAssertThrowsError(try snapshot([:]))
        XCTAssertThrowsError(try snapshot([0: .none]))
        XCTAssertThrowsError(try snapshot([0: .layer(symbol)]))
        XCTAssertThrowsError(try snapshot([0: .channel(symbol)]))
        _ = try snapshot([0: inkBinding])
    }

    func testOldCommandsNeverAcceptInkCurvesBindingAndFailureOnlyNoV12() throws {
        let samples = identitySamples()
        let curves = success(commandJSON(samples: samples), binding: cmykBindingJSON)
        for command in [
            #"{"tag":"scale","width":1,"height":1}"#,
            #"{"tag":"selectCommand","command":"invert","radius":0}"#,
            #"{"tag":"channelToSelection","operation":"add"}"#,
        ] {
            let rows = curves + "," + success(command, binding: cmykBindingJSON, ordinal: 1)
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows: rows, symbols: channelSymbolJSON))))
        }
        let rows = #"{"ordinal":0,"outcome":"failure","reason":"applyInkCurves refused"},{"ordinal":1,"outcome":"cancelled","reason":"stopped"}"#
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows: rows, symbols: "", version: 12))))
        let v1 = try RecorderFileCodec.decode(bytes(document(rows: rows, symbols: "", version: 1)))
        XCTAssertTrue(String(decoding: try RecorderFileCodec.encode(v1), as: UTF8.self).contains(#""version":1"#))
    }
}
