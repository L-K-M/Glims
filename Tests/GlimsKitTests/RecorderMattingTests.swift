import XCTest
@testable import GlimsKit

/// Layer > Matting's Recorder rows at format version 34: the codec round
/// trip, the version anchor, strict width rules and the explicit layer
/// binding.
final class RecorderMattingTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let layerSymbolJSON = #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#
    private let layerBinding = #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#
    private let channelSymbolJSON = #"{"id":"33333333-3333-3333-3333-333333333333","description":{"name":"Channel","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func file(version: Int, symbols: String, records: String) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Matting","origin":{"imageLabel":"A","initialWidth":200,"initialHeight":150},"symbols":["#
            + symbols + #"],"records":["# + records + "]}"
    }
    private func success(_ command: String, binding: String, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func document(_ command: String, version: Int = 34, binding: String = #"{"kind":"none"}"#,
                          symbols: String = "") -> String {
        file(version: version, symbols: symbols, records: success(command, binding: binding))
    }

    func testMattingRoundTripThroughTheCodec() throws {
        let cases: [(String, String)] = [
            (#"{"tag":"matting","operation":"defringe","width":2}"#, layerBinding),
            (#"{"tag":"matting","operation":"removeBlackMatte"}"#, layerBinding),
            (#"{"tag":"matting","operation":"removeWhiteMatte"}"#, layerBinding),
        ]
        for (command, binding) in cases {
            let value = try RecorderFileCodec.decode(bytes(document(command, binding: binding, symbols: layerSymbolJSON)))
            let encoded = try RecorderFileCodec.encode(value)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":34"#), command)
            XCTAssertEqual(try RecorderFileCodec.decode(encoded), value, command)
            _ = try RecorderFileSemanticBridge.prepare(value)
        }

        let defringe = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"matting","operation":"defringe","width":200}"#,
            binding: layerBinding, symbols: layerSymbolJSON)))
        guard case .success(.matting(let operation, let width), .layer(let bound))? = defringe.records.first?.outcome else {
            return XCTFail("The Defringe row was lost")
        }
        XCTAssertEqual(operation, .defringe)
        XCTAssertEqual(width, 200)
        XCTAssertEqual(bound, symbol)

        let black = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"matting","operation":"removeBlackMatte"}"#,
            binding: layerBinding, symbols: layerSymbolJSON)))
        guard case .success(.matting(let operation, let width), .layer)? = black.records.first?.outcome else {
            return XCTFail("The Remove Black Matte row was lost")
        }
        XCTAssertEqual(operation, .removeBlackMatte)
        XCTAssertNil(width)

        let white = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"matting","operation":"removeWhiteMatte"}"#,
            binding: layerBinding, symbols: layerSymbolJSON)))
        guard case .success(.matting(let operation, let width), .layer)? = white.records.first?.outcome else {
            return XCTFail("The Remove White Matte row was lost")
        }
        XCTAssertEqual(operation, .removeWhiteMatte)
        XCTAssertNil(width)
    }

    func testVersionAnchorAndOlderVersionRefusal() throws {
        XCTAssertEqual(RecorderFileCodec.mattingVersion, 34)
        XCTAssertEqual(RecorderFileCodec.latestVersion, RecorderFileCodec.variationsVersion)
        let commands = [
            #"{"tag":"matting","operation":"defringe","width":1}"#,
            #"{"tag":"matting","operation":"removeBlackMatte"}"#,
            #"{"tag":"matting","operation":"removeWhiteMatte"}"#,
        ]
        for command in commands {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command, version: 33))),
                                 command)
        }
        // A version 34 file without a matting row is refused.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 34))))
        // A plain crop alone does not write the newest version.
        let plain = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 1)))
        XCTAssertFalse(String(decoding: try RecorderFileCodec.encode(plain), as: UTF8.self)
            .contains(#""version":\(RecorderFileCodec.latestVersion)"#))
    }

    func testWidthRulesAndUnknownOperation() {
        for command in [
            #"{"tag":"matting","operation":"defringe"}"#,
            #"{"tag":"matting","operation":"defringe","width":0}"#,
            #"{"tag":"matting","operation":"defringe","width":201}"#,
            #"{"tag":"matting","operation":"defringe","width":1.5}"#,
            #"{"tag":"matting","operation":"removeBlackMatte","width":1}"#,
            #"{"tag":"matting","operation":"removeWhiteMatte","width":2}"#,
            #"{"tag":"matting","operation":"future"}"#,
            #"{"tag":"matting","operation":"defringe","width":1,"future":0}"#,
        ] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
                command, binding: layerBinding, symbols: layerSymbolJSON))), command)
        }
    }

    func testBindingPairingRules() {
        for command in [
            #"{"tag":"matting","operation":"defringe","width":1}"#,
            #"{"tag":"matting","operation":"removeBlackMatte"}"#,
            #"{"tag":"matting","operation":"removeWhiteMatte"}"#,
        ] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command))),
                                 "none binding: \(command)")
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
                command, binding: #"{"kind":"layer","symbol":"33333333-3333-3333-3333-333333333333"}"#,
                symbols: channelSymbolJSON))), "channel symbol: \(command)")
        }
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"matting","operation":"removeBlackMatte"}"#,
            binding: layerBinding, symbols: layerSymbolJSON))))
    }

    func testSemanticPropertiesAndSnapshotRoundTrip() throws {
        XCTAssertEqual(SemanticImageCommand.matting(.defringe, width: 2).title, "Defringe")
        XCTAssertEqual(SemanticImageCommand.matting(.removeBlackMatte, width: 0).title, "Remove Black Matte")
        XCTAssertEqual(SemanticImageCommand.matting(.removeWhiteMatte, width: 0).title, "Remove White Matte")
        XCTAssertTrue(SemanticImageCommand.matting(.defringe, width: 2).requiresResolvedFloatingSelection)
        XCTAssertFalse(RecorderFileCommand.matting(.defringe, width: 2).isTargetIndependent)
        XCTAssertFalse(RecorderFileCommand.matting(.removeBlackMatte, width: nil).isTargetIndependent)

        let description = RecorderTargetDescription(name: "Layer", kind: .pixel, ancestors: [],
                                                    siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 10, height: 10))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description)])
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let first = try log.reserve()
        try log.resolve(first, with: .success(.matting(.defringe, width: 2)))
        let second = try log.reserve()
        try log.resolve(second, with: .success(.matting(.removeWhiteMatte, width: 0)))
        try log.stopRecording()
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Matting",
                                                       origin: .init(imageLabel: "A", initialWidth: 200, initialHeight: 150),
                                                       descriptions: catalog, bindings: [0: .layer(symbol), 1: .layer(symbol)])
        XCTAssertEqual(snapshot.records.count, 2)
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":34"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), snapshot)
        guard case .success(.matting(let operation, let width), .layer)? = snapshot.records.first?.outcome else {
            return XCTFail("The snapshot lost Defringe")
        }
        XCTAssertEqual(operation, .defringe)
        XCTAssertEqual(width, 2)
        guard case .success(.matting(let operation, let width), .layer)? = snapshot.records.last?.outcome else {
            return XCTFail("The snapshot lost Remove White Matte")
        }
        XCTAssertEqual(operation, .removeWhiteMatte)
        XCTAssertNil(width)
    }
}
