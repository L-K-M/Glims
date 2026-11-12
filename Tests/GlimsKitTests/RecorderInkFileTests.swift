import XCTest
@testable import GlimsKit

/// Strict recording-format version 11 coverage: flat ink edit/applyInkLevels
/// commands on explicitly bound ink channels. Every decode fixture spells out
/// its own JSON; nothing reuses the production encoder as a self-oracle.
final class RecorderInkFileTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let inkUUID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let zeroUUID = "00000000-0000-0000-0000-000000000000"
    private let origin = RecorderFileValue.Origin(imageLabel: "A", initialWidth: 41, initialHeight: 29)
    private let channelSymbol = #"{"id":"33333333-3333-3333-3333-333333333333","description":{"name":"Cyan","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let layerSymbol = #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let quickSymbol = #"{"id":"33333333-3333-3333-3333-333333333333","description":{"name":"Quick","kind":"quickMask","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let inkBinding = #"{"kind":"ink","symbol":"33333333-3333-3333-3333-333333333333","mode":"cmyk","role":"cyan","uuid":"44444444-4444-4444-4444-444444444444"}"#
    private let multiInkBinding = #"{"kind":"ink","symbol":"33333333-3333-3333-3333-333333333333","mode":"multichannel","role":"unspecified","uuid":"44444444-4444-4444-4444-444444444444"}"#
    private let layerBinding = #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#
    private let channelBinding = #"{"kind":"channel","symbol":"33333333-3333-3333-3333-333333333333"}"#

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func replace(_ text: String, _ before: String, _ after: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let range = text.range(of: before) else { XCTFail("Fixture mutation did not match: \(before)", file: file, line: line); return text }
        return text.replacingCharacters(in: range, with: after)
    }
    private func document(_ rows: String, symbols: String = "", version: Int = 11) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Ink","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":["#
            + symbols + #"],"records":["# + rows + "]}"
    }
    private func success(_ command: String, binding: String, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }

    private let editFill = #"{"tag":"editInk","operation":"fill","intensity":0.25,"opacity":0.5}"#
    private let editClear = #"{"tag":"editInk","operation":"clear","intensity":1.0,"opacity":1.0}"#
    private let editInvert = #"{"tag":"editInk","operation":"invert","intensity":0.0,"opacity":1.0}"#
    private let inkLevels = #"{"tag":"applyInkLevels","lowInput":0.1,"highInput":0.9,"gamma":2.0,"lowOutput":0.2,"highOutput":0.8,"clampInput":true,"clampOutput":false}"#
    private let inkLevelsReversed = #"{"tag":"applyInkLevels","lowInput":0.9,"highInput":0.1,"gamma":0.1,"lowOutput":0.8,"highOutput":0.2,"clampInput":false,"clampOutput":true}"#

    func testEditInkFillLiteralDecodesAndRoundTripsCanonically() throws {
        let literal = document(success(editFill, binding: inkBinding), symbols: channelSymbol)
        let value = try RecorderFileCodec.decode(bytes(literal))
        guard case .success(.editInk(let edit), .ink(let id, let identity)) = value.records[0].outcome else {
            return XCTFail("editInk row lost typed values")
        }
        XCTAssertEqual(id, symbol)
        XCTAssertEqual(edit.operation, .fill)
        XCTAssertEqual(edit.intensity, 0.25)
        XCTAssertEqual(edit.opacity, 0.5)
        XCTAssertEqual(identity, RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: inkUUID))

        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":11"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
        // Flat exact keys, canonical lowercase UUIDs and sorted object keys.
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#"{"intensity":0.25,"opacity":0.5,"operation":"fill","tag":"editInk"}"#))
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#"{"kind":"ink","mode":"cmyk","role":"cyan","symbol":"33333333-3333-3333-3333-333333333333","uuid":"44444444-4444-4444-4444-444444444444"}"#))
    }

    func testApplyInkLevelsLiteralDecodesBothModesAndRoundTrips() throws {
        for (binding, symbolJSON, mode, role) in [
            (inkBinding, channelSymbol, RecorderInkIdentity.Mode.cmyk, RecorderInkIdentity.Role.cyan),
            (multiInkBinding, channelSymbol, .multichannel, .unspecified),
        ] {
            let literal = document(success(inkLevels, binding: binding), symbols: symbolJSON)
            let value = try RecorderFileCodec.decode(bytes(literal))
            guard case .success(.applyInkLevels(let levels), .ink(let id, let identity)) = value.records[0].outcome else {
                return XCTFail("applyInkLevels row lost typed values")
            }
            XCTAssertEqual(id, symbol)
            XCTAssertEqual(identity.mode, mode)
            XCTAssertEqual(identity.role, role)
            XCTAssertEqual(levels, .init(lowInput: 0.1, highInput: 0.9, gamma: 2.0, lowOutput: 0.2, highOutput: 0.8, clampInput: true, clampOutput: false))
            XCTAssertEqual(try RecorderFileCodec.decode(try RecorderFileCodec.encode(value)), value)
        }
    }

    func testCanonicalClearInvertAndValidLevelsBoundsRoundTrip() throws {
        for (command, operation, intensity, opacity) in [ (editClear, RecorderFileCommand.InkEdit.Operation.clear, 1.0, 1.0), (editInvert, .invert, 0.0, 1.0) ] {
            let value = try RecorderFileCodec.decode(bytes(document(success(command, binding: inkBinding), symbols: channelSymbol)))
            guard case .success(.editInk(let edit), _) = value.records[0].outcome else { return XCTFail() }
            XCTAssertEqual(edit.operation, operation)
            XCTAssertEqual(edit.intensity, intensity)
            XCTAssertEqual(edit.opacity, opacity)
            XCTAssertEqual(try RecorderFileCodec.decode(try RecorderFileCodec.encode(value)), value)
        }
        // Equal and reversed endpoints are valid native mappings.
        let equal = #"{"tag":"applyInkLevels","lowInput":0.5,"highInput":0.5,"gamma":10.0,"lowOutput":1.0,"highOutput":0.0,"clampInput":true,"clampOutput":true}"#
        for command in [equal, inkLevelsReversed] {
            let value = try RecorderFileCodec.decode(bytes(document(success(command, binding: inkBinding), symbols: channelSymbol)))
            XCTAssertEqual(try RecorderFileCodec.decode(try RecorderFileCodec.encode(value)), value)
        }
    }

    func testVersionElevenAnchorFutureAndLowerVersionRules() throws {
        for version in 1...10 {
            for command in [editFill, inkLevels] {
                XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(command, binding: inkBinding), symbols: channelSymbol, version: version))), "ink needs v11")
            }
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(editFill, binding: inkBinding), symbols: channelSymbol, version: 12))), "unknown future version")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(editFill, binding: inkBinding), symbols: channelSymbol, version: 0))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(document(success(editFill, binding: inkBinding), symbols: channelSymbol), #""version":11"#, #""version":"11""#))))
        // v11 requires at least one successful new ink command.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(#"{"tag":"scale","width":1,"height":1}"#, binding: #"{"kind":"none"}"#), version: 11))))

        // Existing v1..10 rules unchanged.
        let v1 = #"{"format":"ch.lkmc.Glims.recording","version":1,"recordingID":"11111111-1111-1111-1111-111111111111","name":"S","origin":{"imageLabel":"A","initialWidth":1,"initialHeight":1},"symbols":[],"records":[{"ordinal":0,"outcome":"success","command":{"tag":"scale","width":1,"height":1},"binding":{"kind":"none"}}]}"#
        XCTAssertEqual(try RecorderFileCodec.decode(bytes(v1)).records.count, 1)
        let v10Need = #"{"format":"ch.lkmc.Glims.recording","version":10,"recordingID":"11111111-1111-1111-1111-111111111111","name":"S","origin":{"imageLabel":"A","initialWidth":1,"initialHeight":1},"symbols":[],"records":[{"ordinal":0,"outcome":"success","command":{"tag":"scale","width":1,"height":1},"binding":{"kind":"none"}}]}"#
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(v10Need)))
    }

    func testFlatExactKeysFieldTypesBoundsAndCanonicalRejection() {
        let base = document(success(editFill, binding: inkBinding), symbols: channelSymbol)
        let levelBase = document(success(inkLevels, binding: inkBinding), symbols: channelSymbol)
        let mutations = [
            (base, #""tag":"editInk""#, #""tag":"editInk","future":0"#),
            (base, #""tag":"editInk""#, #""tag":"editInk","settings":{}"#),
            (base, #""operation":"fill""#, #""operation":"future""#),
            (base, #""intensity":0.25"#, #""intensity":"0.25""#),
            (base, #""opacity":0.5"#, #""opacity":true"#),
            (base, #""intensity":0.25"#, #""intensity":-0.1"#),
            (base, #""opacity":0.5"#, #""opacity":1.1"#),
            (base, #""intensity":0.25"#, #""intensity":1e309"#),
            (base, #""opacity":0.5"#, #""opacity":NaN"#), // JSON itself forbids NaN.
            (levelBase, #""tag":"applyInkLevels""#, #""tag":"applyInkLevels","future":0"#),
            (levelBase, #""gamma":2.0"#, #""gamma":"2.0""#),
            (levelBase, #""lowInput":0.1"#, #""lowInput":-0.1"#),
            (levelBase, #""highOutput":0.8"#, #""highOutput":1.1"#),
            (levelBase, #""gamma":2.0"#, #""gamma":0.09"#),
            (levelBase, #""gamma":2.0"#, #""gamma":10.1"#),
            (levelBase, #""clampInput":true"#, #""clampInput":"true""#),
        ]
        for (text, old, new) in mutations {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(text, old, new))), old)
        }
        // missing keys / non-flat
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(base, #","opacity":0.5"#, ""))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(levelBase, #","clampOutput":false"#, ""))))

        // canonical clear/invert required
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(#"{"tag":"editInk","operation":"clear","intensity":0.5,"opacity":1.0}"#, binding: inkBinding), symbols: channelSymbol))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(#"{"tag":"editInk","operation":"clear","intensity":1.0,"opacity":0.5}"#, binding: inkBinding), symbols: channelSymbol))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(#"{"tag":"editInk","operation":"invert","intensity":0.0,"opacity":0.5}"#, binding: inkBinding), symbols: channelSymbol))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(#"{"tag":"editInk","operation":"invert","intensity":1.0,"opacity":1.0}"#, binding: inkBinding), symbols: channelSymbol))))
    }

    func testBindingValidationIdentityConsistencyAndWrongPairing() {
        // missing/wrong symbol-kind bindings
        let pixelDescription = replace(channelSymbol, #""kind":"channel""#, #""kind":"pixel""#)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(editFill, binding: inkBinding), symbols: pixelDescription))), "ink needs channel description")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(editFill, binding: inkBinding), symbols: quickSymbol))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(editFill, binding: layerBinding), symbols: channelSymbol + "," + layerSymbol))), "command/binding disagree")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(editFill, binding: channelBinding), symbols: channelSymbol))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(#"{"tag":"scale","width":1,"height":1}"#, binding: #"{"kind":"none"}"#) + "," + success(editFill, binding: replace(inkBinding, #""symbol":"33333333-3333-3333-3333-333333333333""#, #""symbol":"55555555-5555-5555-5555-555555555555""#), ordinal: 1), symbols: channelSymbol))), "missing symbol")

        // invalid identity / zero UUID / mode-role mismatch
        let zero = replace(inkBinding, #""uuid":"44444444-4444-4444-4444-444444444444""#, "\"uuid\":\"\(zeroUUID)\"")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(editFill, binding: zero), symbols: channelSymbol))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(editFill, binding: replace(inkBinding, #""mode":"cmyk""#, #""mode":"future""#)), symbols: channelSymbol))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(editFill, binding: replace(inkBinding, #""role":"cyan""#, #""role":"future""#)), symbols: channelSymbol))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(editFill, binding: replace(inkBinding, #""role":"cyan""#, #""role":"unspecified""#)), symbols: channelSymbol))), "CMYK named role required")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(editFill, binding: replace(multiInkBinding, #""role":"unspecified""#, #""role":"cyan""#)), symbols: channelSymbol))), "multichannel unspecified required")

        // inconsistent identity across records (same symbol, individually valid)
        let otherUUID = replace(inkBinding, #""uuid":"44444444-4444-4444-4444-444444444444""#, #""uuid":"55555555-5555-5555-5555-555555555555""#)
        let otherRole = #"{"kind":"ink","symbol":"33333333-3333-3333-3333-333333333333","mode":"cmyk","role":"magenta","uuid":"44444444-4444-4444-4444-444444444444"}"#
        let rowsUUID = success(editFill, binding: inkBinding) + "," + success(inkLevels, binding: otherUUID, ordinal: 1)
        let rowsRole = success(editFill, binding: inkBinding) + "," + success(inkLevels, binding: otherRole, ordinal: 1)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rowsUUID, symbols: channelSymbol))), "contradictory uuid")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rowsRole, symbols: channelSymbol))), "contradictory role")
        let rowsMode = success(editFill, binding: inkBinding) + "," + success(inkLevels, binding: multiInkBinding, ordinal: 1)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rowsMode, symbols: channelSymbol))), "contradictory mode")

        // old commands must never accept .ink
        for (command, binding, symbols) in [
            (#"{"tag":"scale","width":1,"height":1}"#, inkBinding, channelSymbol),
            (#"{"tag":"selectCommand","command":"invert","radius":0}"#, inkBinding, channelSymbol),
            (#"{"tag":"channelToSelection","operation":"add"}"#, inkBinding, channelSymbol),
            (#"{"tag":"transformImage","transform":"rotate90"}"#, inkBinding, channelSymbol),
        ] {
            // A separate valid ink row satisfies the v11 anchor, so rejection
            // must concern the old command's binding, not the file version.
            let rows = success(editFill, binding: inkBinding) + "," + success(command, binding: binding, ordinal: 1)
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows, symbols: symbols))), "old command with ink")
        }
    }

    func testMinimumVersionSelectionFailurePreservationAndEncodeValidation() throws {
        // minimum highest required by successful commands; v11 with ink + v10 command stays v11
        let bc = #"{"tag":"applyBrightnessContrast","settings":{"brightness":0.0,"contrast":0.0}}"#
        let mixed = document(success(editFill, binding: inkBinding) + "," + success(bc, binding: layerBinding, ordinal: 1),
                             symbols: channelSymbol + "," + layerSymbol)
        let decoded = try RecorderFileCodec.decode(bytes(mixed))
        let encoded = try RecorderFileCodec.encode(decoded)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":11"#))
        let onlyBrightness = try RecorderFileCodec.decode(bytes(document(success(bc, binding: layerBinding), symbols: layerSymbol, version: 10)))
        XCTAssertTrue(String(decoding: try RecorderFileCodec.encode(onlyBrightness), as: UTF8.self).contains(#""version":10"#))

        // failure/cancelled outcomes preserved and do not require ink success; v11 anchor comes from success
        let outcomeRows = #"{"ordinal":0,"outcome":"failure","reason":"Nope"}"# + ","
            + #"{"ordinal":1,"outcome":"cancelled","reason":"Stop"}"# + ","
            + success(inkLevels, binding: inkBinding, ordinal: 2)
        let out = try RecorderFileCodec.decode(bytes(document(outcomeRows, symbols: channelSymbol)))
        guard case .failure("Nope") = out.records[0].outcome, case .cancelled("Stop") = out.records[1].outcome else {
            return XCTFail("outcomes lost")
        }
        XCTAssertEqual(try RecorderFileCodec.decode(try RecorderFileCodec.encode(out)), out)

        // encode validates in-memory callers with same codec rules
        let desc = RecorderTargetDescription(name: "Cyan", kind: .channel, ancestors: [], siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
        let goodIdentity = RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: inkUUID)
        let base = RecorderFileValue(recordingID: recordingID, name: "Ink", origin: origin,
            symbols: [.init(id: symbol, description: desc)],
            records: [.init(ordinal: 0, outcome: .success(.editInk(.init(operation: .fill, intensity: 0.2, opacity: 0.3)), .ink(symbol: symbol, identity: goodIdentity)))])
        XCTAssertNoThrow(try RecorderFileCodec.encode(base))

        let badEdit = RecorderFileValue(recordingID: recordingID, name: "Ink", origin: origin,
            symbols: [.init(id: symbol, description: desc)],
            records: [.init(ordinal: 0, outcome: .success(.editInk(.init(operation: .clear, intensity: 0.5, opacity: 1.0)), .ink(symbol: symbol, identity: goodIdentity)))])
        XCTAssertThrowsError(try RecorderFileCodec.encode(badEdit))

        let badIdentity = RecorderInkIdentity(mode: .cmyk, role: .unspecified, uuid: inkUUID)
        let badInk = RecorderFileValue(recordingID: recordingID, name: "Ink", origin: origin,
            symbols: [.init(id: symbol, description: desc)],
            records: [.init(ordinal: 0, outcome: .success(.editInk(.init(operation: .fill, intensity: 0.2, opacity: 0.3)), .ink(symbol: symbol, identity: badIdentity)))])
        XCTAssertThrowsError(try RecorderFileCodec.encode(badInk))

        // inconsistent identity across successful records rejected by encode too
        let other = RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!)
        let inconsistent = RecorderFileValue(recordingID: recordingID, name: "Ink", origin: origin,
            symbols: [.init(id: symbol, description: desc)],
            records: [
                .init(ordinal: 0, outcome: .success(.editInk(.init(operation: .fill, intensity: 0.2, opacity: 0.3)), .ink(symbol: symbol, identity: goodIdentity))),
                .init(ordinal: 1, outcome: .success(.applyInkLevels(.init(lowInput: 0, highInput: 1, gamma: 1, lowOutput: 0, highOutput: 1, clampInput: false, clampOutput: false)), .ink(symbol: symbol, identity: other))),
            ])
        XCTAssertThrowsError(try RecorderFileCodec.encode(inconsistent))
    }

    func testExactBindingSchemaAndCommandDuplicatesReject() {
        for (before, after) in [
            (#""kind":"ink""#, #""kind":"ink","ordinal":0"#),
            (#""kind":"ink""#, #""kind":"ink","count":4"#),
            (#""mode":"cmyk""#, #""mode":4"#),
            (#""role":"cyan""#, #""role":null"#),
            (#""uuid":"44444444-4444-4444-4444-444444444444""#, #""uuid":"not-a-uuid""#),
            (#","uuid":"44444444-4444-4444-4444-444444444444""#, ""),
            (#""mode":"cmyk""#, #""mode":"cmyk","mode":"cmyk""#),
        ] {
            let binding = replace(inkBinding, before, after)
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(editFill, binding: binding), symbols: channelSymbol))), before)
        }
        for command in [
            replace(editFill, #""intensity":0.25"#, #""intensity":0.25,"intensity":0.25"#),
            replace(inkLevels, #""gamma":2.0"#, #""gamma":2.0,"gamma":2.0"#),
            #"{"tag":"applyInkLevels","settings":{"lowInput":0,"highInput":1,"gamma":1,"lowOutput":0,"highOutput":1,"clampInput":true,"clampOutput":true}}"#,
        ] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(command, binding: inkBinding), symbols: channelSymbol))))
        }
    }

    func testFailureOnlyDoesNotAcquireInkVersionOrSuccess() throws {
        let rows = #"{"ordinal":0,"outcome":"failure","reason":"editInk refused"},{"ordinal":1,"outcome":"cancelled","reason":"applyInkLevels cancelled"}"#
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(rows, version: 11))))
        let value = try RecorderFileCodec.decode(bytes(document(rows, version: 1)))
        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":1"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
        XCTAssertEqual(value.records.map(\.outcome), [.failure("editInk refused"), .cancelled("applyInkLevels cancelled")])
    }

    func testOwnedValueValidationAndInkReferences() throws {
        let identity = RecorderInkIdentity(mode: .multichannel, role: .unspecified, uuid: inkUUID)
        XCTAssertTrue(identity.isValid)
        XCTAssertEqual(try RecorderFileCodec.referencedSymbols(.ink(symbol: symbol, identity: identity)), [symbol])
        let description = RecorderTargetDescription(name: "Ink", kind: .channel, ancestors: [], siblingIndex: 0,
            bounds: .init(x: 0, y: 0, width: 41, height: 29))
        func value(_ command: RecorderFileCommand) -> RecorderFileValue {
            .init(recordingID: recordingID, name: "Ink", origin: origin,
                  symbols: [.init(id: symbol, description: description)],
                  records: [.init(ordinal: 0, outcome: .success(command, .ink(symbol: symbol, identity: identity)))])
        }
        for (intensity, opacity) in [(0.0, 0.0), (0.0, 1.0), (1.0, 0.0), (1.0, 1.0)] {
            let command = RecorderFileCommand.editInk(.init(operation: .fill, intensity: intensity, opacity: opacity))
            XCTAssertFalse(command.isTargetIndependent)
            XCTAssertEqual(try RecorderFileCodec.decode(try RecorderFileCodec.encode(value(command))), value(command))
        }
        for invalid in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            XCTAssertThrowsError(try RecorderFileCodec.encode(value(.editInk(.init(operation: .fill, intensity: invalid, opacity: 1)))))
            XCTAssertThrowsError(try RecorderFileCodec.encode(value(.editInk(.init(operation: .fill, intensity: 0, opacity: invalid)))))
            for field in 0..<4 {
                var endpoints = [0.0, 1.0, 0.0, 1.0]
                endpoints[field] = invalid
                let levels = RecorderFileCommand.InkLevels(lowInput: endpoints[0], highInput: endpoints[1], gamma: 1,
                    lowOutput: endpoints[2], highOutput: endpoints[3], clampInput: false, clampOutput: true)
                XCTAssertFalse(levels.isValid)
                XCTAssertThrowsError(try RecorderFileCodec.encode(value(.applyInkLevels(levels))))
            }
        }
        for invalid in [Double.nan, .infinity, -.infinity, 0.09, 10.01] {
            let levels = RecorderFileCommand.InkLevels(lowInput: 0, highInput: 1, gamma: invalid,
                lowOutput: 0, highOutput: 1, clampInput: true, clampOutput: false)
            XCTAssertFalse(RecorderFileCommand.applyInkLevels(levels).isTargetIndependent)
            XCTAssertThrowsError(try RecorderFileCodec.encode(value(.applyInkLevels(levels))))
        }
    }
}
