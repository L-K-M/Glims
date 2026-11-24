import XCTest
import CoreGraphics
@testable import GlimsKit

/// The six layer edits the Recorder saves at format version 33: the codec
/// round trip, the version anchor, strict fields and binding pairing.
final class RecorderLayerEditsTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let produced = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let producedSymbolJSON = #"{"id":"44444444-4444-4444-4444-444444444444","description":{"name":"Copy","kind":"pixel","ancestors":[],"siblingIndex":1,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#
    private let layerSymbolJSON = #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#
    private var bothSymbolsJSON: String { layerSymbolJSON + "," + producedSymbolJSON }
    private let channelSymbolJSON = #"{"id":"33333333-3333-3333-3333-333333333333","description":{"name":"Channel","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#
    private let layerBinding = #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#
    private let contextBinding = #"{"kind":"context","context":{"layers":["22222222-2222-2222-2222-222222222222"],"channels":[],"target":{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"},"masks":[{"owner":"22222222-2222-2222-2222-222222222222","isPresent":false,"enabled":false,"editing":false,"showing":false}],"quickMask":{"enabled":false,"inverted":false,"color":{"space":"srgb","red":1,"green":0,"blue":0,"alpha":1}}}}"#

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func file(version: Int, symbols: String, records: String) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Layer edits","origin":{"imageLabel":"A","initialWidth":200,"initialHeight":150},"symbols":["#
            + symbols + #"],"records":["# + records + "]}"
    }
    private func success(_ command: String, binding: String, ordinal: Int = 0, produces: String? = nil) -> String {
        var text = "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
        if let produces {
            text.insert(contentsOf: ",\"produces\":\"\(produces)\"", at: text.index(before: text.endIndex))
        }
        return text
    }
    fileprivate func document(_ command: String, version: Int = RecorderFileCodec.layerEditsVersion, binding: String = #"{"kind":"none"}"#,
                          symbols: String = "", produces: String? = nil) -> String {
        file(version: version, symbols: symbols, records: success(command, binding: binding, produces: produces))
    }

    func testLayerEditsRoundTripThroughTheCodec() throws {
        let cases: [(String, String, String, String?)] = [
            (#"{"tag":"moveLayer","offset":{"x":3,"y":-2}}"#, #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#, layerSymbolJSON, nil),
            (#"{"tag":"duplicateLayers"}"#, #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#, bothSymbolsJSON, produced.uuidString),
            (#"{"tag":"deleteLayers"}"#, #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#, layerSymbolJSON, nil),
            (#"{"tag":"mergeVisible"}"#, #"{"kind":"none"}"#, producedSymbolJSON, produced.uuidString),
            (#"{"tag":"addLayerMask","source":"alphaTransfer","edit":true}"#, #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#, layerSymbolJSON, nil),
            (#"{"tag":"selectSimilar","threshold":0.25,"antialias":false,"sampleMerged":true}"#, #"{"kind":"none"}"#, "", nil),
            (#"{"tag":"selectSimilar","threshold":0.25,"antialias":false,"sampleMerged":false}"#, contextBinding, layerSymbolJSON, nil),
        ]
        for (command, binding, symbols, produces) in cases {
            let value = try RecorderFileCodec.decode(bytes(document(command, binding: binding, symbols: symbols,
                                                                produces: produces)))
            let encoded = try RecorderFileCodec.encode(value)
            XCTAssertNotNil(String(decoding: encoded, as: UTF8.self)
                .range(of: #""version":\#(RecorderFileCodec.layerEditsVersion)[^0-9]"#,
                       options: .regularExpression), command)
            XCTAssertEqual(try RecorderFileCodec.decode(encoded), value, command)
            _ = try RecorderFileSemanticBridge.prepare(value)
        }

        let duplicated = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"duplicateLayers"}"#, binding: layerBinding, symbols: bothSymbolsJSON,
            produces: produced.uuidString)))
        guard case .success(.duplicateLayers, .layer)? = duplicated.records.first?.outcome else {
            return XCTFail("Duplicate Layers was lost")
        }
        XCTAssertEqual(duplicated.records.first?.produces, produced)
        let encodedDuplicate = try RecorderFileCodec.encode(duplicated)
        let duplicateText = String(decoding: encodedDuplicate, as: UTF8.self)
        XCTAssertTrue(duplicateText.contains(#""produces":"\#(produced.uuidString)""#), duplicateText)
        XCTAssertTrue(duplicateText.contains("\"name\":\"Copy\""), duplicateText)
        let merged = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"mergeVisible"}"#, binding: #"{"kind":"none"}"#, symbols: producedSymbolJSON,
            produces: produced.uuidString)))
        guard case .success(.mergeVisible, .none)? = merged.records.first?.outcome else {
            return XCTFail("Merge Visible was lost")
        }
        XCTAssertEqual(merged.records.first?.produces, produced)

        let moved = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"moveLayer","offset":{"x":3,"y":-2}}"#, binding: layerBinding, symbols: layerSymbolJSON)))
        guard case .success(.moveLayer(let offset), .layer(let bound))? = moved.records.first?.outcome else {
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
        XCTAssertGreaterThanOrEqual(RecorderFileCodec.latestVersion, RecorderFileCodec.layerEditsVersion)
        // Each command decodes at version 33 with its valid binding, so the
        // version 32 refusal comes from the version alone.
        let layer = ValidBase(binding: layerBinding, symbols: layerSymbolJSON, produces: nil)
        let none = ValidBase(binding: #"{"kind":"none"}"#, symbols: "", produces: nil)
        let commands: [(ValidBase, String)] = [
            (layer, #"{"tag":"moveLayer","offset":{"x":1,"y":0}}"#),
            (ValidBase(binding: layerBinding, symbols: bothSymbolsJSON, produces: produced.uuidString),
             #"{"tag":"duplicateLayers"}"#),
            (layer, #"{"tag":"deleteLayers"}"#),
            (ValidBase(binding: #"{"kind":"none"}"#, symbols: producedSymbolJSON, produces: produced.uuidString),
             #"{"tag":"mergeVisible"}"#),
            (layer, #"{"tag":"addLayerMask","source":"white","edit":false}"#),
            (none, #"{"tag":"selectSimilar","threshold":0.5,"antialias":true,"sampleMerged":true}"#),
        ]
        for (base, command) in commands {
            XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(base.document(command, in: self))), command)
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(base.document(command, version: 32, in: self))),
                                 command)
        }
        // A version 33 file without any of the six is refused.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: RecorderFileCodec.layerEditsVersion))))
        // A plain crop alone does not write version 33.
        let plain = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 1)))
        XCTAssertFalse(String(decoding: try RecorderFileCodec.encode(plain), as: UTF8.self)
            .range(of: #""version":\#(RecorderFileCodec.layerEditsVersion)[^0-9]"#,
                   options: .regularExpression) != nil)
    }

    func testStrictFieldsRefuse() {
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"moveLayer","offset":{"x":1,"y":0},"future":0}"#, binding: layerBinding, symbols: layerSymbolJSON))))
        for edge in [524288, -524288] {
            XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(
                #"{"tag":"moveLayer","offset":{"x":\#(edge),"y":\#(edge)}}"#, binding: layerBinding,
                symbols: layerSymbolJSON))), "\(edge)")
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"moveLayer","offset":{"x":524289,"y":0}}"#, binding: layerBinding, symbols: layerSymbolJSON))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"moveLayer","offset":{"x":-524289,"y":0}}"#, binding: layerBinding, symbols: layerSymbolJSON))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"moveLayer","offset":{"x":1.5,"y":0}}"#, binding: layerBinding, symbols: layerSymbolJSON))))
        // Each refusal sits on a document that decodes without the bad
        // field, so only that field can cause it.
        let duplicate = ValidBase(binding: layerBinding, symbols: bothSymbolsJSON, produces: produced.uuidString)
        let delete = ValidBase(binding: layerBinding, symbols: layerSymbolJSON, produces: nil)
        let merge = ValidBase(binding: #"{"kind":"none"}"#, symbols: producedSymbolJSON, produces: produced.uuidString)
        let mask = delete
        let similar = ValidBase(binding: #"{"kind":"none"}"#, symbols: "", produces: nil)
        let cases: [(base: ValidBase, valid: String, invalid: String)] = [
            (duplicate, #"{"tag":"duplicateLayers"}"#, #"{"tag":"duplicateLayers","future":0}"#),
            (delete, #"{"tag":"deleteLayers"}"#, #"{"tag":"deleteLayers","future":0}"#),
            (merge, #"{"tag":"mergeVisible"}"#, #"{"tag":"mergeVisible","future":0}"#),
            (mask, #"{"tag":"addLayerMask","source":"white","edit":false}"#,
             #"{"tag":"addLayerMask","source":"white","edit":false,"future":0}"#),
            (mask, #"{"tag":"addLayerMask","source":"white","edit":false}"#,
             #"{"tag":"addLayerMask","source":"future","edit":false}"#),
            (mask, #"{"tag":"addLayerMask","source":"white","edit":false}"#,
             #"{"tag":"addLayerMask","source":"white"}"#),
            (similar, #"{"tag":"selectSimilar","threshold":0.5,"antialias":true,"sampleMerged":true}"#,
             #"{"tag":"selectSimilar","threshold":0.5,"antialias":true}"#),
            (similar, #"{"tag":"selectSimilar","threshold":1,"antialias":true,"sampleMerged":true}"#,
             #"{"tag":"selectSimilar","threshold":1.5,"antialias":true,"sampleMerged":true}"#),
            (similar, #"{"tag":"selectSimilar","threshold":0,"antialias":true,"sampleMerged":true}"#,
             #"{"tag":"selectSimilar","threshold":-0.1,"antialias":true,"sampleMerged":true}"#),
            (similar, #"{"tag":"selectSimilar","threshold":0.5,"antialias":true,"sampleMerged":true}"#,
             #"{"tag":"selectSimilar","threshold":0.5,"antialias":true,"sampleMerged":true,"future":0}"#),
        ]
        for (base, valid, invalid) in cases {
            XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(base.document(valid, in: self))), valid)
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(base.document(invalid, in: self))), invalid)
        }
    }

    /// The binding, symbols and produced symbol that make a command's
    /// row valid, so a test can vary the command alone.
    private struct ValidBase {
        var binding: String
        var symbols: String
        var produces: String?

        func document(_ command: String, version: Int = RecorderFileCodec.layerEditsVersion, in test: RecorderLayerEditsTests) -> String {
            test.document(command, version: version, binding: binding, symbols: symbols, produces: produces)
        }
    }

    func testProducedSymbolRules() throws {
        let producer = #"{"tag":"duplicateLayers"}"#
        let producedID = produced.uuidString
        // Missing produces.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            producer, binding: layerBinding, symbols: bothSymbolsJSON))))
        // Another command cannot produce.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"moveLayer","offset":{"x":1,"y":0}}"#, binding: layerBinding,
            symbols: bothSymbolsJSON, produces: producedID))))
        // Unknown symbol.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            producer, binding: layerBinding, symbols: layerSymbolJSON, produces: producedID))))
        // Channel-kind description.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            producer, binding: layerBinding, symbols: layerSymbolJSON + "," + channelSymbolJSON,
            produces: "33333333-3333-3333-3333-333333333333"))))
        // A failed row cannot carry produces; the identical recording with
        // the field removed decodes, so the refusal comes from `produces`.
        _ = try RecorderFileCodec.decode(bytes(file(version: RecorderFileCodec.layerEditsVersion, symbols: bothSymbolsJSON,
            records: success(#"{"tag":"moveLayer","offset":{"x":1,"y":0}}"#, binding: layerBinding)
                + "," + #"{"ordinal":1,"outcome":"failure","reason":"Failed"}"#)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(file(version: RecorderFileCodec.layerEditsVersion, symbols: bothSymbolsJSON,
            records: #"{"ordinal":0,"outcome":"failure","reason":"Failed","produces":"\#(producedID)"}"#))))
        // Same-row use.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            producer, binding: #"{"kind":"layer","symbol":"\#(producedID)"}"#,
            symbols: bothSymbolsJSON, produces: producedID))))
        // Two producers of one symbol.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(file(version: RecorderFileCodec.layerEditsVersion, symbols: bothSymbolsJSON,
            records: success(producer, binding: layerBinding, produces: producedID)
                + "," + success(producer, binding: layerBinding, ordinal: 1, produces: producedID)))))
        // Use before production: row 0 binds the produced symbol, row 1 creates it.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(file(version: RecorderFileCodec.layerEditsVersion, symbols: bothSymbolsJSON,
            records: success(#"{"tag":"layerProperties","properties":{"opacity":0.5}}"#,
                           binding: #"{"kind":"layer","symbol":"\#(producedID)"}"#)
                + "," + success(producer, binding: layerBinding, ordinal: 1, produces: producedID)))))
        // Valid later use.
        let valid = try RecorderFileCodec.decode(bytes(file(version: RecorderFileCodec.layerEditsVersion, symbols: bothSymbolsJSON,
            records: success(producer, binding: layerBinding, produces: producedID)
                + "," + success(#"{"tag":"deleteLayers"}"#,
                                binding: #"{"kind":"layer","symbol":"\#(producedID)"}"#, ordinal: 1))))
        XCTAssertEqual(valid.records.first?.produces, produced)
        XCTAssertNil(valid.records.last?.produces)
        guard case .success(.deleteLayers, .layer(let bound))? = valid.records.last?.outcome else {
            return XCTFail("The later row lost its produced-layer binding")
        }
        XCTAssertEqual(bound, produced)
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
        let producedDescription = RecorderTargetDescription(name: "Copy", kind: .pixel, ancestors: [],
                                                            siblingIndex: 1, bounds: .init(x: 0, y: 0, width: 10, height: 10))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description), produced: .available(producedDescription)])
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let first = try log.reserve()
        try log.resolve(first, with: .success(.moveLayer(offset: CGSize(width: 2, height: 1))))
        let second = try log.reserve()
        try log.resolve(second, with: .success(.mergeVisible))
        try log.stopRecording()
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Layer edits",
                                                       origin: .init(imageLabel: "A", initialWidth: 200, initialHeight: 150),
                                                       descriptions: catalog, bindings: [0: .layer(symbol)],
                                                       produced: [1: produced])
        XCTAssertEqual(snapshot.records.count, 2)
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertNotNil(String(decoding: encoded, as: UTF8.self)
            .range(of: #""version":\#(RecorderFileCodec.layerEditsVersion)[^0-9]"#,
                   options: .regularExpression))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(produced.uuidString))
        guard case .success(.moveLayer(let offset), .layer)? = snapshot.records.first?.outcome else {
            return XCTFail("The snapshot lost the layer move")
        }
        XCTAssertEqual(offset, .init(x: 2, y: 1))
        guard case .success(.mergeVisible, .none)? = snapshot.records.last?.outcome else {
            return XCTFail("The snapshot lost the merged layer")
        }
        XCTAssertEqual(snapshot.records.last?.produces, produced)
    }
}
