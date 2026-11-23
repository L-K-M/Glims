import XCTest
import CoreGraphics
@testable import GlimsKit

/// The six layer edits the Recorder saves at format version 33: the codec
/// round trip, the version anchor, strict fields and binding pairing.
final class RecorderLayerEditsTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let layerSymbolJSON = #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#
    private let channelSymbolJSON = #"{"id":"33333333-3333-3333-3333-333333333333","description":{"name":"Channel","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#
    private let layerBinding = #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#
    private let contextBinding = #"{"kind":"context","context":{"layers":["22222222-2222-2222-2222-222222222222"],"channels":[],"target":{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"},"masks":[{"owner":"22222222-2222-2222-2222-222222222222","isPresent":false,"enabled":false,"editing":false,"showing":false}],"quickMask":{"enabled":false,"inverted":false,"color":{"space":"srgb","red":1,"green":0,"blue":0,"alpha":1}}}}"#

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func file(version: Int, symbols: String, records: String) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Layer edits","origin":{"imageLabel":"A","initialWidth":200,"initialHeight":150},"symbols":["#
            + symbols + #"],"records":["# + records + "]}"
    }
    private func success(_ command: String, binding: String, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func document(_ command: String, version: Int = 33, binding: String = #"{"kind":"none"}"#,
                          symbols: String = "") -> String {
        file(version: version, symbols: symbols, records: success(command, binding: binding))
    }

    func testLayerEditsRoundTripThroughTheCodec() throws {
        let cases: [(String, String, String)] = [
            (#"{"tag":"moveLayer","offset":{"x":3,"y":-2}}"#, #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#, layerSymbolJSON),
            (#"{"tag":"duplicateLayers"}"#, #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#, layerSymbolJSON),
            (#"{"tag":"deleteLayers"}"#, #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#, layerSymbolJSON),
            (#"{"tag":"mergeVisible"}"#, #"{"kind":"none"}"#, ""),
            (#"{"tag":"addLayerMask","source":"alphaTransfer","edit":true}"#, #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#, layerSymbolJSON),
            (#"{"tag":"selectSimilar","threshold":0.25,"antialias":false,"sampleMerged":true}"#, #"{"kind":"none"}"#, ""),
            (#"{"tag":"selectSimilar","threshold":0.25,"antialias":false,"sampleMerged":false}"#, contextBinding, layerSymbolJSON),
        ]
        for (command, binding, symbols) in cases {
            let value = try RecorderFileCodec.decode(bytes(document(command, binding: binding, symbols: symbols)))
            let encoded = try RecorderFileCodec.encode(value)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":33"#), command)
            XCTAssertEqual(try RecorderFileCodec.decode(encoded), value, command)
            _ = try RecorderFileSemanticBridge.prepare(value)
        }

        let moved = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"moveLayer","offset":{"x":3,"y":-2}}"#, binding: layerBinding, symbols: layerSymbolJSON)))
        guard case .success(.moveLayer(let offset), .layer(let bound)) = moved.records.first?.outcome else {
            return XCTFail("The layer move was lost")
        }
        XCTAssertEqual(offset, .init(x: 3, y: -2))
        XCTAssertEqual(bound, symbol)
        let masked = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"addLayerMask","source":"grayscale","edit":true}"#, binding: layerBinding, symbols: layerSymbolJSON)))
        guard case .success(.addLayerMask(let source, let edit), .layer)? = masked.records.first?.outcome else {
            return XCTFail("The layer mask was lost")
        }
        XCTAssertEqual(source, .grayscale)
        XCTAssertTrue(edit)
        let similar = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"selectSimilar","threshold":0.25,"antialias":false,"sampleMerged":true}"#)))
        guard case .success(.selectSimilar(let threshold, let antialias, let sampleMerged), .none)? = similar.records.first?.outcome else {
            return XCTFail("Select Similar was lost")
        }
        XCTAssertEqual(threshold, 0.25)
        XCTAssertFalse(antialias)
        XCTAssertTrue(sampleMerged)
    }

    func testVersionAnchorAndOlderVersionRefusal() throws {
        XCTAssertEqual(RecorderFileCodec.layerEditsVersion, 33)
        XCTAssertEqual(RecorderFileCodec.latestVersion, 33)
        let commands = [
            #"{"tag":"moveLayer","offset":{"x":1,"y":0}}"#,
            #"{"tag":"duplicateLayers"}"#,
            #"{"tag":"deleteLayers"}"#,
            #"{"tag":"mergeVisible"}"#,
            #"{"tag":"addLayerMask","source":"white","edit":false}"#,
            #"{"tag":"selectSimilar","threshold":0.5,"antialias":true,"sampleMerged":true}"#,
        ]
        for command in commands {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command, version: 32))),
                                 command)
        }
        // A version 33 file without any of the six is refused.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 33))))
        // A plain crop alone does not write version 33.
        let plain = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 1)))
        XCTAssertFalse(String(decoding: try RecorderFileCodec.encode(plain), as: UTF8.self)
            .contains(#""version":33"#))
    }

    func testStrictFieldsRefuse() {
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"moveLayer","offset":{"x":1,"y":0},"future":0}"#, binding: layerBinding, symbols: layerSymbolJSON))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"moveLayer","offset":{"x":524289,"y":0}}"#, binding: layerBinding, symbols: layerSymbolJSON))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"moveLayer","offset":{"x":-524289,"y":0}}"#, binding: layerBinding, symbols: layerSymbolJSON))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"moveLayer","offset":{"x":1.5,"y":0}}"#, binding: layerBinding, symbols: layerSymbolJSON))))
        for command in [
            #"{"tag":"duplicateLayers","future":0}"#,
            #"{"tag":"deleteLayers","future":0}"#,
            #"{"tag":"mergeVisible","future":0}"#,
            #"{"tag":"addLayerMask","source":"white","edit":false,"future":0}"#,
            #"{"tag":"addLayerMask","source":"future","edit":false}"#,
            #"{"tag":"addLayerMask","source":"white"}"#,
            #"{"tag":"selectSimilar","threshold":0.5,"antialias":true}"#,
            #"{"tag":"selectSimilar","threshold":1.5,"antialias":true,"sampleMerged":true}"#,
            #"{"tag":"selectSimilar","threshold":-0.1,"antialias":true,"sampleMerged":true}"#,
            #"{"tag":"selectSimilar","threshold":0.5,"antialias":true,"sampleMerged":true,"future":0}"#,
        ] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command))), command)
        }
    }

    func testBindingPairingRules() {
        let layerCommands = [
            #"{"tag":"moveLayer","offset":{"x":1,"y":0}}"#,
            #"{"tag":"duplicateLayers"}"#,
            #"{"tag":"deleteLayers"}"#,
            #"{"tag":"addLayerMask","source":"white","edit":false}"#,
        ]
        for command in layerCommands {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command))),
                                 "none binding: \(command)")
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
                command, binding: #"{"kind":"layer","symbol":"33333333-3333-3333-3333-333333333333"}"#,
                symbols: channelSymbolJSON))), "channel symbol: \(command)")
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"mergeVisible"}"#, binding: layerBinding, symbols: layerSymbolJSON))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"selectSimilar","threshold":0.5,"antialias":true,"sampleMerged":true}"#,
            binding: layerBinding, symbols: layerSymbolJSON))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"selectSimilar","threshold":0.5,"antialias":true,"sampleMerged":false}"#))))
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"selectSimilar","threshold":0.5,"antialias":true,"sampleMerged":false}"#,
            binding: contextBinding, symbols: layerSymbolJSON))))
    }

    func testSemanticPropertiesAndSnapshotRoundTrip() throws {
        XCTAssertEqual(SemanticImageCommand.moveLayer(offset: .zero).title, "Move Layer")
        XCTAssertEqual(SemanticImageCommand.duplicateLayers.title, "Duplicate Layers")
        XCTAssertEqual(SemanticImageCommand.deleteLayers.title, "Delete Layers")
        XCTAssertEqual(SemanticImageCommand.mergeVisible.title, "Merge Visible")
        XCTAssertEqual(SemanticImageCommand.addLayerMask(source: .white, edit: true).title, "Add Layer Mask")
        XCTAssertEqual(SemanticImageCommand.selectSimilar(threshold: 0.5, antialias: true, sampleMerged: true).title,
                       "Select Similar")
        XCTAssertTrue(SemanticImageCommand.moveLayer(offset: .zero).requiresResolvedFloatingSelection)
        XCTAssertTrue(SemanticImageCommand.duplicateLayers.requiresResolvedFloatingSelection)
        XCTAssertTrue(SemanticImageCommand.deleteLayers.requiresResolvedFloatingSelection)
        XCTAssertTrue(SemanticImageCommand.mergeVisible.requiresResolvedFloatingSelection)
        XCTAssertTrue(SemanticImageCommand.addLayerMask(source: .white, edit: true).requiresResolvedFloatingSelection)
        XCTAssertFalse(SemanticImageCommand.selectSimilar(threshold: 0.5, antialias: true, sampleMerged: true)
            .requiresResolvedFloatingSelection)
        XCTAssertFalse(RecorderFileCommand.moveLayer(offset: .init(x: 1, y: 0)).isTargetIndependent)
        XCTAssertFalse(RecorderFileCommand.duplicateLayers.isTargetIndependent)
        XCTAssertFalse(RecorderFileCommand.deleteLayers.isTargetIndependent)
        XCTAssertFalse(RecorderFileCommand.addLayerMask(source: .white, edit: true).isTargetIndependent)
        XCTAssertTrue(RecorderFileCommand.mergeVisible.isTargetIndependent)
        XCTAssertTrue(RecorderFileCommand.selectSimilar(threshold: 0.5, antialias: true, sampleMerged: true)
            .isTargetIndependent)
        XCTAssertFalse(RecorderFileCommand.selectSimilar(threshold: 0.5, antialias: true, sampleMerged: false)
            .isTargetIndependent)

        let description = RecorderTargetDescription(name: "Layer", kind: .pixel, ancestors: [],
                                                    siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 10, height: 10))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description)])
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let first = try log.reserve()
        try log.resolve(first, with: .success(.moveLayer(offset: CGSize(width: 2, height: 1))))
        let second = try log.reserve()
        try log.resolve(second, with: .success(.mergeVisible))
        try log.stopRecording()
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Layer edits",
                                                       origin: .init(imageLabel: "A", initialWidth: 200, initialHeight: 150),
                                                       descriptions: catalog, bindings: [0: .layer(symbol)])
        XCTAssertEqual(snapshot.records.count, 2)
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":33"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), snapshot)
        guard case .success(.moveLayer(let offset), .layer)? = snapshot.records.first?.outcome else {
            return XCTFail("The snapshot lost the layer move")
        }
        XCTAssertEqual(offset, .init(x: 2, y: 1))
    }
}
