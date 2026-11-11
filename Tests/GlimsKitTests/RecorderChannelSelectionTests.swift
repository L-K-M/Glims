import XCTest
import CoreGraphics
@testable import GlimsKit

/// Channel ▸ To Selection capture/replay representation: the closed version 3
/// schema, the explicit channel binding and the semantic bridge.
final class RecorderChannelSelectionTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let channel = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let layer = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let origin = RecorderFileValue.Origin(imageLabel: "A", initialWidth: 41, initialHeight: 29)

    private let channelSymbol = #"{"id":"33333333-3333-3333-3333-333333333333","description":{"name":"Right source","kind":"channel","ancestors":[],"siblingIndex":1,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let layerSymbol = #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let command = #"{"tag":"channelToSelection","operation":"add"}"#

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func document(_ rows: String, symbols: String = "", version: Int = 3) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Bound","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":["# + symbols + #"],"records":["# + rows + "]}"
    }
    private func success(_ command: String, binding: String = #"{"kind":"channel","symbol":"33333333-3333-3333-3333-333333333333"}"#, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func replace(_ text: String, _ before: String, _ after: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let range = text.range(of: before) else { XCTFail("Fixture mutation did not match: \(before)", file: file, line: line); return text }
        return text.replacingCharacters(in: range, with: after)
    }
    private var literal: String { document(success(command), symbols: channelSymbol) }

    func testVersionThreeChannelSelectionRoundTripsCanonically() throws {
        let value = try RecorderFileCodec.decode(bytes(literal))
        guard case .success(.channelToSelection(.add), .channel(let id)) = value.records[0].outcome else {
            return XCTFail("The channel selection row lost its typed values")
        }
        XCTAssertEqual(id, channel)
        XCTAssertEqual(value.symbols[0].description.kind, .channel)
        XCTAssertEqual(value.symbols[0].description.name, "Right source")
        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":3"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
        let canonical = #"{"format":"ch.lkmc.Glims.recording","name":"Bound","origin":{"imageLabel":"A","initialHeight":29,"initialWidth":41},"recordingID":"11111111-1111-1111-1111-111111111111","records":[{"binding":{"kind":"channel","symbol":"33333333-3333-3333-3333-333333333333"},"command":{"operation":"add","tag":"channelToSelection"},"ordinal":0,"outcome":"success"}],"symbols":[{"description":{"ancestors":[],"bounds":{"height":29.0,"width":41.0,"x":0.0,"y":0.0},"kind":"channel","name":"Right source","siblingIndex":1},"id":"33333333-3333-3333-3333-333333333333"}],"version":3}"#
        XCTAssertEqual(encoded, bytes(canonical))
    }

    func testOldVersionsStillReadAndRefuseTheNewTagAndUnknownVersions() throws {
        // Version 1 and 2 files without the new tag keep their exact behavior.
        let v1 = document(success(#"{"tag":"scale","width":35,"height":43}"#, binding: #"{"kind":"none"}"#), version: 1)
        XCTAssertEqual(try RecorderFileCodec.decode(bytes(v1)).records.count, 1)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(#"{"tag":"scale","width":1,"height":1}"#, binding: #"{"kind":"none"}"#), version: 2))),
                             "version 2 without a stroke is still refused")
        // The new tag is refused in every older version.
        for version in [1, 2] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(command), symbols: channelSymbol, version: version))), "v\(version)")
        }
        // Version 3 requires its own successful row; unknown versions refuse.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(#"{"tag":"scale","width":1,"height":1}"#, binding: #"{"kind":"none"}"#), version: 3))),
                             "version 3 without a channel selection")
        for version in [0, -1, 4, Int.max] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(command), symbols: channelSymbol, version: version))), "v\(version)")
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(literal, #""version":3"#, #""version":"3"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(literal, #""tag":"channelToSelection""#, #""tag":"futureChannel""#))))
    }

    func testChannelSelectionRejectsUnknownOperationFieldsAndWrongBindings() {
        let mutations = [
            (#""operation":"add""#, #""operation":"futureOperation""#),
            (#""operation":"add""#, #""operation":1"#),
            (#""operation":"add""#, #""operation":"add","radius":0"#),
            (#""tag":"channelToSelection""#, #""tag":"channelToSelection","source":"33333333-3333-3333-3333-333333333333""#),
            (#""kind":"channel","symbol""#, #""kind":"channel","future":0,"symbol""#),
            (#""kind":"channel""#, #""kind":"layer""#),
            (#""kind":"channel""#, #""kind":"none""#),
            (#""kind":"channel""#, #""kind":"context""#),
            (#""symbol":"33333333-3333-3333-3333-333333333333""#, #""symbol":"44444444-4444-4444-4444-444444444444""#),
            (#""kind":"channel","ancestors""#, #""kind":"quickMask","ancestors""#),
        ]
        for (old, new) in mutations { XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(literal, old, new))), old) }
        // The source symbol must keep a channel description.
        let pixelSource = replace(literal, #""kind":"channel","ancestors":[]"#, #""kind":"pixel","ancestors":[]"#)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(pixelSource)), "a pixel layer is not a channel source")
        let quickSource = replace(literal, #""kind":"channel","ancestors":[]"#, #""kind":"quickMask","ancestors":[]"#)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(quickSource)), "Quick Mask is not a saved-channel source")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(literal, #""symbols":["#, #""symbols":["# + channelSymbol + ","))),
                             "duplicate symbol")
    }

    func testChannelBindingIsNotAcceptedForOtherCommands() {
        let other = document(success(#"{"tag":"selectCommand","command":"invert","radius":0}"#), symbols: channelSymbol)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(other)), "a channel binding cannot serve a plain selection command")
        let scale = document(success(#"{"tag":"scale","width":1,"height":1}"#), symbols: channelSymbol)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(scale)))
    }

    private var strokeJSON: String {
        let fingerprint = String(repeating: "0", count: 64)
        return #"{"tag":"completeStroke","settings":{"tool":"pencil","size":2,"opacity":1,"red":0,"green":0,"blue":0,"pressureSize":false,"antiErase":false},"facts":{"brush":{"name":"B","isInternal":false},"fingerprint":"\#(fingerprint)"},"first":{"x":0,"y":0,"pressure":1,"xTilt":0,"yTilt":0,"timeMilliseconds":0},"batches":[]}"#
    }

    func testVersionThreeAlsoAcceptsStrokesAndMixedOutcomes() throws {
        let strokeBinding = #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#
        let rows = success(strokeJSON, binding: strokeBinding)
            + "," + success(command, ordinal: 1)
            + #",{"ordinal":2,"outcome":"failure","reason":"Refused"}"#
        let value = try RecorderFileCodec.decode(bytes(document(rows, symbols: layerSymbol + "," + channelSymbol)))
        XCTAssertEqual(value.records.count, 3)
        guard case .success(.completeStroke, .layer) = value.records[0].outcome,
              case .success(.channelToSelection(.add), .channel) = value.records[1].outcome,
              case .failure("Refused") = value.records[2].outcome else {
            return XCTFail("Version 3 mixed rows lost their values")
        }
        XCTAssertEqual(try RecorderFileCodec.decode(try RecorderFileCodec.encode(value)), value)
    }

    func testSnapshotAndBridgeMapChannelSelectionBothWays() throws {
        let expected = try RecorderFileCodec.decode(bytes(literal))
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.channelToSelection(.add)))
        try log.stopRecording()
        let description = RecorderTargetDescription(name: "Right source", kind: .channel, ancestors: [],
            siblingIndex: 1, bounds: .init(x: 0, y: 0, width: 41, height: 29))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([channel: .available(description)])
        func snapshot(_ bindings: [Int: RecorderBindingDescription]) throws -> RecorderFileValue {
            try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Bound", origin: origin,
                                           descriptions: catalog, bindings: bindings)
        }
        XCTAssertThrowsError(try snapshot([:]), "a missing capture-time binding refuses the export")
        XCTAssertThrowsError(try snapshot([0: .none]), "channel to selection cannot fall back to a none binding")
        XCTAssertThrowsError(try snapshot([0: .layer(layer)]))
        XCTAssertEqual(try snapshot([0: .channel(channel)]), expected)
        let prepared = try RecorderFileSemanticBridge.prepare(expected)
        guard case .success(.channelToSelection(.add)) = prepared.log.records[0].resolution else {
            return XCTFail("The bridge lost the channel selection command")
        }
        XCTAssertEqual(prepared.file, expected)
        XCTAssertEqual(try RecorderFileCodec.referencedSymbols(.channel(channel)), [channel])
    }

    func testSemanticCommandCarriesOnlyTheOperation() {
        let command = SemanticImageCommand.channelToSelection(.intersect)
        XCTAssertEqual(command.title, "Channel to Selection")
        XCTAssertFalse(command.requiresResolvedFloatingSelection)
        XCTAssertFalse(RecorderFileCommand.channelToSelection(.intersect).isTargetIndependent)
        XCTAssertEqual(RecorderFileCommand.channelToSelection(.replace), .channelToSelection(.replace))
    }
}
