import XCTest
@testable import GlimsKit

/// Image > Adjust > Replace Color's Recorder rows at format version 38: the
/// codec round trip, the version anchor, the closed settings schema and the
/// explicit layer binding.
final class RecorderReplaceColorTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let layerSymbolJSON = #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func file(version: Int, symbols: String, records: String) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Replace Color","origin":{"imageLabel":"A","initialWidth":200,"initialHeight":150},"symbols":["#
            + symbols + #"],"records":["# + records + "]}"
    }
    private func success(_ command: String, binding: String, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func document(_ command: String, version: Int = 38,
                          binding: String = #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#,
                          symbols: String = "") -> String {
        file(version: version, symbols: symbols, records: success(command, binding: binding))
    }

    private let command = #"{"tag":"applyReplaceColor","settings":{"fuzziness":40,"samples":[{"red":1,"green":0.4,"blue":0.4,"subtract":false},{"red":0,"green":1,"blue":0,"subtract":true}],"hue":90,"saturation":-30,"lightness":20}}"#

    func testRoundTripThroughTheCodec() throws {
        let value = try RecorderFileCodec.decode(bytes(document(command, symbols: layerSymbolJSON)))
        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":38"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
        let prepared = try RecorderFileSemanticBridge.prepare(value)
        guard case .success(.applyReplaceColor(let settings))? = prepared.log.records.first?.resolution else {
            return XCTFail("The Replace Color row was lost")
        }
        XCTAssertEqual(settings.fuzziness, 40)
        XCTAssertEqual(settings.samples.count, 2)
        XCTAssertEqual(settings.samples[0].red, 1)
        XCTAssertEqual(settings.samples[1].green, 1)
        XCTAssertTrue(settings.samples[1].subtract)
        XCTAssertEqual(settings.hue, 90)
        XCTAssertEqual(settings.saturation, -30)
        XCTAssertEqual(settings.lightness, 20)

        guard case .success(.applyReplaceColor, .layer(let bound))? = value.records.first?.outcome else {
            return XCTFail("The Replace Color command or its binding was lost")
        }
        XCTAssertEqual(bound, symbol)
    }

    func testVersionAnchorAndOlderVersionRefusal() throws {
        XCTAssertEqual(RecorderFileCodec.replaceColorVersion, 38)
        XCTAssertGreaterThanOrEqual(RecorderFileCodec.latestVersion, RecorderFileCodec.replaceColorVersion)
        // Valid at version 38, so only the version can refuse it at 37.
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(command, symbols: layerSymbolJSON))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            command, version: 37, symbols: layerSymbolJSON))))
        // A version 38 file without a Replace Color row is refused.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 38,
            binding: #"{"kind":"none"}"#))))
        // A plain crop alone does not write version 38.
        let plain = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 1,
            binding: #"{"kind":"none"}"#)))
        XCTAssertFalse(String(decoding: try RecorderFileCodec.encode(plain), as: UTF8.self)
            .contains(#""version":38"#))
    }

    func testSettingsRules() {
        let bad: [String] = [
            // Fuzziness outside 0...200.
            #"{"tag":"applyReplaceColor","settings":{"fuzziness":201,"samples":[{"red":1,"green":1,"blue":1,"subtract":false}],"hue":0,"saturation":0,"lightness":0}}"#,
            // Hue outside -180...180.
            #"{"tag":"applyReplaceColor","settings":{"fuzziness":40,"samples":[{"red":1,"green":1,"blue":1,"subtract":false}],"hue":181,"saturation":0,"lightness":0}}"#,
            // Saturation outside -100...100.
            #"{"tag":"applyReplaceColor","settings":{"fuzziness":40,"samples":[{"red":1,"green":1,"blue":1,"subtract":false}],"hue":0,"saturation":-101,"lightness":0}}"#,
            // Lightness outside -100...100.
            #"{"tag":"applyReplaceColor","settings":{"fuzziness":40,"samples":[{"red":1,"green":1,"blue":1,"subtract":false}],"hue":0,"saturation":0,"lightness":101}}"#,
            // Subtract alone changes nothing.
            #"{"tag":"applyReplaceColor","settings":{"fuzziness":40,"samples":[{"red":1,"green":1,"blue":1,"subtract":true}],"hue":0,"saturation":0,"lightness":0}}"#,
            // Non-finite sample component.
            #"{"tag":"applyReplaceColor","settings":{"fuzziness":40,"samples":[{"red":1e999,"green":1,"blue":1,"subtract":false}],"hue":0,"saturation":0,"lightness":0}}"#,
            // No sample at all.
            #"{"tag":"applyReplaceColor","settings":{"fuzziness":40,"samples":[],"hue":0,"saturation":0,"lightness":0}}"#,
            // Missing and unknown fields, otherwise valid.
            #"{"tag":"applyReplaceColor","settings":{"fuzziness":40,"samples":[{"red":1,"green":1,"blue":1,"subtract":false}],"hue":0,"saturation":0}}"#,
            #"{"tag":"applyReplaceColor","settings":{"fuzziness":40,"samples":[{"red":1,"green":1,"blue":1,"subtract":false}],"hue":0,"saturation":0,"lightness":0,"future":1}}"#,
            #"{"tag":"applyReplaceColor","settings":{"fuzziness":40,"samples":[{"red":1,"green":1,"subtract":false}],"hue":0,"saturation":0,"lightness":0}}"#,
        ]
        for entry in bad {
            XCTAssertThrowsError(try RecorderFileCodec.decode(
                bytes(document(entry, symbols: layerSymbolJSON))), entry)
        }

        // More than eight samples are refused.
        let samples = (0..<9).map { _ in #"{"red":0,"green":0,"blue":0,"subtract":false}"# }.joined(separator: ",")
        let oversized = #"{"tag":"applyReplaceColor","settings":{"fuzziness":40,"samples":["# + samples + #"],"hue":0,"saturation":0,"lightness":0}}"#
        XCTAssertThrowsError(try RecorderFileCodec.decode(
            bytes(document(oversized, symbols: layerSymbolJSON))))
    }

    func testBindingPairingRules() {
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            command, binding: #"{"kind":"none"}"#))), "Replace Color needs its layer binding")
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(
            command, symbols: layerSymbolJSON))))
    }

    func testSemanticPropertiesAndSnapshotRoundTrip() throws {
        var settings = EngineSession.ReplaceColorSettings()
        settings.samples = [.init(red: 1, green: 0.4, blue: 0.4, subtract: false),
                            .init(red: 0, green: 1, blue: 0, subtract: true)]
        settings.hue = 90
        settings.saturation = -30
        settings.lightness = 20
        let command = SemanticImageCommand.applyReplaceColor(settings)
        XCTAssertEqual(command.title, "Replace Color")
        XCTAssertTrue(command.isLayerAdjustment)
        XCTAssertTrue(command.requiresResolvedFloatingSelection)
        let value = try RecorderFileCommand.applyReplaceColor(try RecorderReplaceColorValue(settings))
        XCTAssertFalse(value.isTargetIndependent)
        XCTAssertThrowsError(try RecorderReplaceColorValue(EngineSession.ReplaceColorSettings()))

        let description = RecorderTargetDescription(name: "Layer", kind: .pixel, ancestors: [],
                                                    siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 10, height: 10))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description)])
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let first = try log.reserve()
        try log.resolve(first, with: .success(command))
        try log.stopRecording()
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Replace Color",
                                                       origin: .init(imageLabel: "A", initialWidth: 200, initialHeight: 150),
                                                       descriptions: catalog, bindings: [0: .layer(symbol)])
        XCTAssertEqual(snapshot.records.count, 1)
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":38"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), snapshot)
        guard case .success(.applyReplaceColor(let stored), .layer(let bound))? = snapshot.records.first?.outcome else {
            return XCTFail("The snapshot lost Replace Color")
        }
        XCTAssertEqual(bound, symbol)
        XCTAssertEqual(try stored.settings(), settings)
    }
}
