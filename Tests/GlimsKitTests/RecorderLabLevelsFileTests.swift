import XCTest
@testable import GlimsKit

final class RecorderLabLevelsFileTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let symbol = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let labUUID = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
    private let channelSymbolJSON = #"{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","description":{"name":"a*","kind":"channel","ancestors":[],"siblingIndex":1,"bounds":{"x":0,"y":0,"width":7,"height":9}}}"#
    private let origin = RecorderFileValue.Origin(imageLabel: "Lab.xcf", initialWidth: 7, initialHeight: 9)

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func document(_ rows: String, symbols: String? = nil, version: Int = 17) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-2222-3333-4444-555555555555","name":"Lab","origin":{"imageLabel":"Lab.xcf","initialWidth":7,"initialHeight":9},"symbols":["#
            + (symbols ?? channelSymbolJSON) + #"],"records":["# + rows + "]}"
    }
    private func binding(role: String = "a", precision: String = "u16", symbol: String = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee", uuid: String = "01234567-89ab-cdef-0123-456789abcdef") -> String {
        #"{"kind":"lab","symbol":"\#(symbol)","role":"\#(role)","precision":"\#(precision)","uuid":"\#(uuid)"}"#
    }
    private func success(_ command: String, binding: String? = nil, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding ?? self.binding())}"
    }
    private func command(lowIn: String = "0.1", highIn: String = "0.9", gamma: String = "2.0",
                         lowOut: String = "0.2", highOut: String = "0.8",
                         clampIn: String = "true", clampOut: String = "false") -> String {
        #"{"tag":"applyLabLevels","lowInput":\#(lowIn),"highInput":\#(highIn),"gamma":\#(gamma),"lowOutput":\#(lowOut),"highOutput":\#(highOut),"clampInput":\#(clampIn),"clampOutput":\#(clampOut)}"#
    }
    private func replace(_ text: String, _ before: String, _ after: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let range = text.range(of: before) else { XCTFail("Missing \(before)", file: file, line: line); return text }
        return text.replacingCharacters(in: range, with: after)
    }
    private func channelDesc(name: String = "a*") -> RecorderTargetDescription {
        .init(name: name, kind: .channel, ancestors: [], siblingIndex: 1, bounds: .init(x: 0, y: 0, width: 7, height: 9))
    }

    func testHandAuthoredV17LiteralDecodesExactValuesAndAllFields() throws {
        let literal = document(success(command(lowIn: "0.0", highIn: "1.0", gamma: "0.1", lowOut: "1.0", highOut: "0.0", clampIn: "false", clampOut: "true")))
        let decoded = try RecorderFileCodec.decode(bytes(literal))
        guard case .success(.applyLabLevels(let levels), .lab(let id, let identity)) = decoded.records[0].outcome else {
            return XCTFail("Expected applyLabLevels with Lab binding")
        }
        XCTAssertEqual(id, symbol)
        XCTAssertEqual(identity, RecorderLabIdentity(role: .a, precision: .u16, uuid: labUUID))
        XCTAssertEqual(levels.lowInput, 0.0)
        XCTAssertEqual(levels.highInput, 1.0)
        XCTAssertEqual(levels.gamma, 0.1)
        XCTAssertEqual(levels.lowOutput, 1.0)
        XCTAssertEqual(levels.highOutput, 0.0)
        XCTAssertFalse(levels.clampInput)
        XCTAssertTrue(levels.clampOutput)
    }

    func testEncodeKeySetExactValuesAndSemanticSnapshotConversions() throws {
        let fileLevels = RecorderFileCommand.LabLevels(lowInput: 0.0, highInput: 1.0, gamma: 0.1, lowOutput: 1.0, highOutput: 0.0, clampInput: false, clampOutput: true)
        let identity = RecorderLabIdentity(role: .b, precision: .float, uuid: labUUID)
        let value = RecorderFileValue(recordingID: recordingID, name: "Lab", origin: origin,
            symbols: [.init(id: symbol, description: channelDesc(name: "b*"))],
            records: [.init(ordinal: 0, outcome: .success(.applyLabLevels(fileLevels), .lab(symbol: symbol, identity: identity)))])
        let encoded = try RecorderFileCodec.encode(value)
        let json = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(json.contains(#""version":17"#))
        XCTAssertTrue(json.contains(#""tag":"applyLabLevels""#))
        XCTAssertFalse(json.contains(#""trc""#))
        XCTAssertFalse(json.contains(#""mode""#))
        XCTAssertFalse(json.contains(#""ink""#))
        XCTAssertFalse(json.contains(#""red""#))
        XCTAssertFalse(json.contains(#""axis""#))
        XCTAssertFalse(json.contains(#""native""#))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let rows = try XCTUnwrap(root["records"] as? [[String: Any]])
        let cmd = try XCTUnwrap(rows.first?["command"] as? [String: Any])
        XCTAssertEqual(Set(cmd.keys), Set(["tag", "lowInput", "highInput", "gamma", "lowOutput", "highOutput", "clampInput", "clampOutput"]))
        XCTAssertEqual(cmd["lowInput"] as? Double, 0.0)
        XCTAssertEqual(cmd["highInput"] as? Double, 1.0)
        XCTAssertEqual(cmd["gamma"] as? Double, 0.1)
        XCTAssertEqual(cmd["lowOutput"] as? Double, 1.0)
        XCTAssertEqual(cmd["highOutput"] as? Double, 0.0)
        XCTAssertEqual(cmd["clampInput"] as? Bool, false)
        XCTAssertEqual(cmd["clampOutput"] as? Bool, true)
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)

        let semantic = try RecorderFileCommand(.applyLabLevels(.init(value: .init(lowInput: 0, highInput: 1, gamma: 0.1, lowOutput: 1, highOutput: 0), clampInput: false, clampOutput: true)))
        XCTAssertEqual(semantic, .applyLabLevels(fileLevels))
        let prepared = try RecorderFileSemanticBridge.prepare(value)
        guard case .success(.applyLabLevels(let settings)) = prepared.log.records[0].resolution else {
            return XCTFail("Expected semantic applyLabLevels")
        }
        XCTAssertEqual(settings.value.lowInput, 0.0)
        XCTAssertEqual(settings.value.highInput, 1.0)
        XCTAssertEqual(settings.value.gamma, 0.1)
        XCTAssertEqual(settings.value.lowOutput, 1.0)
        XCTAssertEqual(settings.value.highOutput, 0.0)
        XCTAssertFalse(settings.clampInput)
        XCTAssertTrue(settings.clampOutput)
        XCTAssertTrue(settings.isValid)
        XCTAssertEqual(SemanticImageCommand.applyLabLevels(settings).title, "Lab Levels")
        XCTAssertTrue(SemanticImageCommand.applyLabLevels(settings).requiresResolvedFloatingSelection)
        XCTAssertFalse(SemanticImageCommand.applyLabLevels(settings).isLayerAdjustment)

        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(channelDesc(name: "b*"))])
        let snapshot = try RecorderFileCodec.snapshot(prepared.log, recordingID: recordingID, name: "Lab",
                                                     origin: origin, descriptions: catalog,
                                                     bindings: [0: .lab(symbol: symbol, identity: identity)])
        XCTAssertEqual(snapshot, value)
    }

    func testAllLabRolesPrecisionsClampCombosAndEqualReversedEndpoints() throws {
        let combos: [(String, String, Bool)] = [("true","true", true), ("true","false", true), ("false","true", true), ("false","false", true)]
        for role in ["lightness", "a", "b"] {
            for precision in ["u8", "u16", "float"] {
                for (ci, co, _) in combos {
                    let cmd = command(lowIn: "0.9", highIn: "0.1", gamma: "10.0", lowOut: "0.0", highOut: "1.0", clampIn: ci, clampOut: co)
                    let lit = document(success(cmd, binding: binding(role: role, precision: precision)))
                    let decoded = try RecorderFileCodec.decode(bytes(lit))
                    guard case .success(.applyLabLevels(let levels), .lab(_, let identity)) = decoded.records[0].outcome else {
                        return XCTFail("Expected applyLabLevels for \(role)/\(precision)")
                    }
                    XCTAssertEqual(levels.lowInput, 0.9)
                    XCTAssertEqual(levels.highInput, 0.1)
                    XCTAssertEqual(levels.gamma, 10.0)
                    XCTAssertEqual(levels.lowOutput, 0.0)
                    XCTAssertEqual(levels.highOutput, 1.0)
                    XCTAssertEqual(levels.clampInput, ci == "true")
                    XCTAssertEqual(levels.clampOutput, co == "true")
                    XCTAssertEqual(identity.role.rawValue, role)
                    XCTAssertEqual(identity.precision.rawValue, precision)
                    XCTAssertEqual(try RecorderFileCodec.decode(try RecorderFileCodec.encode(decoded)), decoded)
                }
            }
        }
        let equal = document(success(command(lowIn: "0.5", highIn: "0.5", gamma: "1.0", lowOut: "0.5", highOut: "0.5", clampIn: "true", clampOut: "true")))
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(equal)))
    }

    func testMalformedRequiredMissingUnknownWrongTypesNullOutOfRangeNonFinite() {
        let base = document(success(command()))
        for missing in ["\"lowInput\":0.1,", "\"highInput\":0.9,", "\"gamma\":2.0,", "\"lowOutput\":0.2,", "\"highOutput\":0.8,", "\"clampInput\":true,", ",\"clampOutput\":false"] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(base, missing, ""))), missing)
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(base, "\"tag\":\"applyLabLevels\"", "\"tag\":\"applyLabLevels\",\"future\":1"))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(base, "\"tag\":\"applyLabLevels\"", "\"tag\":\"applyLabLevels\",\"nativeID\":1"))))
        for (old, new) in [("\"gamma\":2.0","\"gamma\":\"2.0\""), ("\"clampInput\":true","\"clampInput\":\"true\""),
                           ("\"lowInput\":0.1","\"lowInput\":null"), ("\"clampOutput\":false","\"clampOutput\":null"),
                           ("\"lowInput\":0.1","\"lowInput\":-0.0001"), ("\"highOutput\":0.8","\"highOutput\":1.0001"),
                           ("\"gamma\":2.0","\"gamma\":0.09"), ("\"gamma\":2.0","\"gamma\":10.01"),
                           ("\"lowInput\":0.1","\"lowInput\":1e309"), ("\"gamma\":2.0","\"gamma\":-1e309")] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(base, old, new))), old)
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(base, "\"tag\":\"applyLabLevels\"", "\"tag\":\"applyInkLevels\""))), "tag mismatch vs lab binding is not enough alone but decode path differs; covered by binding checks below")
    }

    func testBindingRefusalsGenericNoneInkInvalidLabMissingSymbol() {
        let cmd = command()
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(cmd, binding: #"{"kind":"none"}"#)))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(cmd, binding: #"{"kind":"channel","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"}"#)))))
        let layerSym = #"{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1}}}"#
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(cmd, binding: #"{"kind":"layer","symbol":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}"#), symbols: channelSymbolJSON + "," + layerSym))))
        let ink = #"{"kind":"ink","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","mode":"cmyk","role":"cyan","uuid":"01234567-89ab-cdef-0123-456789abcdef"}"#
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(cmd, binding: ink)))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(cmd, binding: binding(role: "cyan"))))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(cmd, binding: binding(precision: "half"))))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(cmd, binding: binding(uuid: "00000000-0000-0000-0000-000000000000"))))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(cmd, binding: binding(symbol: "ffffffff-ffff-ffff-ffff-ffffffffffff"))))))
        let missingRole = #"{"kind":"lab","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","precision":"u16","uuid":"01234567-89ab-cdef-0123-456789abcdef"}"#
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(cmd, binding: missingRole)))))
    }

    func testVersionRulesAndOldVersionLiteralsRemainStable() throws {
        for v in 1...16 {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(command()), version: v))), "v\(v)")
        }
        let v13Fill = #"{"format":"ch.lkmc.Glims.recording","version":13,"recordingID":"11111111-2222-3333-4444-555555555555","name":"Lab","origin":{"imageLabel":"Lab.xcf","initialWidth":7,"initialHeight":9},"symbols":[\#(channelSymbolJSON)],"records":[{"ordinal":0,"outcome":"success","command":{"tag":"fillLab","value":1.0,"opacity":1.0},"binding":\#(binding(role:"lightness",precision:"u8"))}]}"#
        let decodedFill = try RecorderFileCodec.decode(bytes(v13Fill))
        XCTAssertTrue(String(decoding: try RecorderFileCodec.encode(decodedFill), as: UTF8.self).contains(#""version":13"#))
        let v16InkStroke = #"{"format":"ch.lkmc.Glims.recording","version":16,"recordingID":"11111111-2222-3333-4444-555555555555","name":"Ink","origin":{"imageLabel":"Ink.tif","initialWidth":7,"initialHeight":9},"symbols":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","description":{"name":"Cyan","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":7,"height":9}}}],"records":[{"ordinal":0,"outcome":"success","command":{"tag":"completeInkStroke","settings":{"tool":"paintbrush","size":4,"opacity":1,"red":0.5,"green":0.5,"blue":0.5,"pressureSize":false,"antiErase":false},"facts":{"brush":{"name":"Default","isInternal":true},"fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"first":{"x":1,"y":1,"pressure":1,"xTilt":0,"yTilt":0,"timeMilliseconds":0},"batches":[]},"binding":{"kind":"ink","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","mode":"cmyk","role":"cyan","uuid":"01234567-89ab-cdef-0123-456789abcdef"}}]}"#
        let decodedInk = try RecorderFileCodec.decode(bytes(v16InkStroke))
        let encodedInk = try RecorderFileCodec.encode(decodedInk)
        XCTAssertTrue(String(decoding: encodedInk, as: UTF8.self).contains(#""version":16"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encodedInk), decodedInk)
        // v17 requires >=1 successful new command
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(""))), "empty v17 has no successful Lab Levels anchor")
        let noSuccess = document(#"{"ordinal":0,"outcome":"failure","reason":"x"}"#)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(noSuccess)))
        let oldOnly = document(success(#"{"tag":"fillLab","value":0.0,"opacity":1.0}"#))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(oldOnly)))
    }
}
