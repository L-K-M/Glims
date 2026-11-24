import XCTest
@testable import GlimsKit

/// Layer > Group with Previous, Ungroup and Merge Group at format version
/// 37: the codec round trip, the version anchor, the owned command tags,
/// the explicit layer binding and Merge Group's produced symbol.
final class RecorderClippingTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let produced = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let layerSymbolJSON = #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#
    private let producedSymbolJSON = #"{"id":"44444444-4444-4444-4444-444444444444","description":{"name":"Base","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#
    private var bothSymbolsJSON: String { layerSymbolJSON + "," + producedSymbolJSON }
    private let channelSymbolJSON = #"{"id":"33333333-3333-3333-3333-333333333333","description":{"name":"Channel","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#
    private let layerBinding = #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func file(version: Int, symbols: String, records: String) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Clipping","origin":{"imageLabel":"A","initialWidth":200,"initialHeight":150},"symbols":["#
            + symbols + #"],"records":["# + records + "]}"
    }
    private func success(_ command: String, binding: String, ordinal: Int = 0, produces: String? = nil) -> String {
        var text = "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
        if let produces {
            text.insert(contentsOf: ",\"produces\":\"\(produces)\"", at: text.index(before: text.endIndex))
        }
        return text
    }
    private func document(_ command: String, version: Int = 37, binding: String = #"{"kind":"none"}"#,
                          symbols: String = "", produces: String? = nil) -> String {
        file(version: version, symbols: symbols, records: success(command, binding: binding, produces: produces))
    }

    func testClippingRoundTripThroughTheCodec() throws {
        let cases: [(String, String)] = [
            (#"{"tag":"clipping","command":"groupWithPrevious"}"#, layerBinding),
            (#"{"tag":"clipping","command":"ungroup"}"#, layerBinding),
        ]
        for (command, binding) in cases {
            let value = try RecorderFileCodec.decode(bytes(document(command, binding: binding, symbols: layerSymbolJSON)))
            let encoded = try RecorderFileCodec.encode(value)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":37"#), command)
            XCTAssertEqual(try RecorderFileCodec.decode(encoded), value, command)
            _ = try RecorderFileSemanticBridge.prepare(value)
        }

        let merged = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"clipping","command":"mergeGroup"}"#, binding: layerBinding,
            symbols: bothSymbolsJSON, produces: produced.uuidString)))
        guard case .success(.clipping(let command), .layer(let bound))? = merged.records.first?.outcome else {
            return XCTFail("Merge Group was lost")
        }
        XCTAssertEqual(command, .mergeGroup)
        XCTAssertEqual(bound, symbol)
        XCTAssertEqual(merged.records.first?.produces, produced)

        let grouped = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"clipping","command":"groupWithPrevious"}"#, binding: layerBinding,
            symbols: layerSymbolJSON)))
        guard case .success(.clipping(let command), .layer)? = grouped.records.first?.outcome else {
            return XCTFail("Group with Previous was lost")
        }
        XCTAssertEqual(command, .groupWithPrevious)
        XCTAssertNil(grouped.records.first?.produces)
    }

    func testVersionAnchorAndOlderVersionRefusal() throws {
        XCTAssertEqual(RecorderFileCodec.clippingVersion, 37)
        XCTAssertGreaterThanOrEqual(RecorderFileCodec.latestVersion, RecorderFileCodec.clippingVersion)
        for command in [
            #"{"tag":"clipping","command":"groupWithPrevious"}"#,
            #"{"tag":"clipping","command":"ungroup"}"#,
            #"{"tag":"clipping","command":"mergeGroup"}"#,
        ] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command, version: 36))),
                                 command)
        }
        // A version 37 file without a clipping row is refused.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 37))))
        // A plain crop alone does not write version 37.
        let plain = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 1)))
        XCTAssertFalse(String(decoding: try RecorderFileCodec.encode(plain), as: UTF8.self)
            .contains(#""version":37"#))
    }

    func testProducedSymbolRules() {
        // Group with Previous cannot produce; Merge Group must.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"clipping","command":"groupWithPrevious"}"#, binding: layerBinding,
            symbols: bothSymbolsJSON, produces: produced.uuidString))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"clipping","command":"ungroup"}"#, binding: layerBinding,
            symbols: bothSymbolsJSON, produces: produced.uuidString))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"clipping","command":"mergeGroup"}"#, binding: layerBinding,
            symbols: layerSymbolJSON))))
        // Unknown symbol and channel-kind descriptions.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"clipping","command":"mergeGroup"}"#, binding: layerBinding,
            symbols: layerSymbolJSON, produces: produced.uuidString))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"clipping","command":"mergeGroup"}"#, binding: layerBinding,
            symbols: layerSymbolJSON + "," + channelSymbolJSON,
            produces: "33333333-3333-3333-3333-333333333333"))))
        // Same-row use and a second producer refuse.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"clipping","command":"mergeGroup"}"#,
            binding: #"{"kind":"layer","symbol":"\#(produced.uuidString)"}"#,
            symbols: bothSymbolsJSON, produces: produced.uuidString))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(file(version: 37, symbols: bothSymbolsJSON,
            records: success(#"{"tag":"clipping","command":"mergeGroup"}"#, binding: layerBinding,
                            produces: produced.uuidString)
                + "," + success(#"{"tag":"clipping","command":"mergeGroup"}"#, binding: layerBinding,
                                ordinal: 1, produces: produced.uuidString)))))
        // A later row may bind the produced layer.
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(file(version: 37, symbols: bothSymbolsJSON,
            records: success(#"{"tag":"clipping","command":"mergeGroup"}"#, binding: layerBinding,
                            produces: produced.uuidString)
                + "," + success(#"{"tag":"deleteLayers"}"#,
                                binding: #"{"kind":"layer","symbol":"\#(produced.uuidString)"}"#,
                                ordinal: 1)))))
    }

    func testStrictFieldsAndBindingPairing() {
        for command in [
            #"{"tag":"clipping","command":"future"}"#,
            #"{"tag":"clipping","command":"mergeGroup","future":0}"#,
            #"{"tag":"clipping"}"#,
        ] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
                command, binding: layerBinding, symbols: layerSymbolJSON))), command)
        }
        for command in [
            #"{"tag":"clipping","command":"groupWithPrevious"}"#,
            #"{"tag":"clipping","command":"ungroup"}"#,
            #"{"tag":"clipping","command":"mergeGroup"}"#,
        ] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command))),
                                 "none binding: \(command)")
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
                command, binding: #"{"kind":"layer","symbol":"33333333-3333-3333-3333-333333333333"}"#,
                symbols: channelSymbolJSON))), "channel symbol: \(command)")
        }
    }

    func testSemanticPropertiesAndSnapshotRoundTrip() throws {
        XCTAssertEqual(SemanticImageCommand.clipping(.groupWithPrevious).title, "Group with Previous")
        XCTAssertEqual(SemanticImageCommand.clipping(.ungroup).title, "Ungroup")
        XCTAssertEqual(SemanticImageCommand.clipping(.mergeGroup).title, "Merge Group")
        XCTAssertTrue(SemanticImageCommand.clipping(.groupWithPrevious).requiresResolvedFloatingSelection)
        XCTAssertTrue(SemanticImageCommand.clipping(.ungroup).requiresResolvedFloatingSelection)
        XCTAssertTrue(SemanticImageCommand.clipping(.mergeGroup).requiresResolvedFloatingSelection)
        XCTAssertFalse(RecorderFileCommand.clipping(.groupWithPrevious).isTargetIndependent)
        XCTAssertFalse(RecorderFileCommand.clipping(.ungroup).isTargetIndependent)
        XCTAssertFalse(RecorderFileCommand.clipping(.mergeGroup).isTargetIndependent)

        let description = RecorderTargetDescription(name: "Layer", kind: .pixel, ancestors: [],
                                                    siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 10, height: 10))
        let producedDescription = RecorderTargetDescription(name: "Base", kind: .pixel, ancestors: [],
                                                            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 10, height: 10))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description), produced: .available(producedDescription)])
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let first = try log.reserve()
        try log.resolve(first, with: .success(.clipping(.mergeGroup)))
        try log.stopRecording()
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Clipping",
                                                       origin: .init(imageLabel: "A", initialWidth: 200, initialHeight: 150),
                                                       descriptions: catalog, bindings: [0: .layer(symbol)],
                                                       produced: [0: produced])
        XCTAssertEqual(snapshot.records.count, 1)
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":37"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(produced.uuidString))
        guard case .success(.clipping(let command), .layer)? = snapshot.records.first?.outcome else {
            return XCTFail("The snapshot lost Merge Group")
        }
        XCTAssertEqual(command, .mergeGroup)
        XCTAssertEqual(snapshot.records.first?.produces, produced)
    }
}
