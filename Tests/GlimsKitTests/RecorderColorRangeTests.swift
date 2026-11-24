import XCTest
@testable import GlimsKit

/// Select > Color Range's Recorder rows at format version 36: the codec
/// round trip, the version anchor, the closed settings schema and the
/// target-independent binding.
final class RecorderColorRangeTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let layerSymbolJSON = #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func file(version: Int, symbols: String, records: String) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Color Range","origin":{"imageLabel":"A","initialWidth":200,"initialHeight":150},"symbols":["#
            + symbols + #"],"records":["# + records + "]}"
    }
    private func success(_ command: String, binding: String, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func document(_ command: String, version: Int = 36,
                          binding: String = #"{"kind":"none"}"#, symbols: String = "") -> String {
        file(version: version, symbols: symbols, records: success(command, binding: binding))
    }

    private let sampledCommand = #"{"tag":"colorRange","mode":"sampledColors","fuzziness":40,"invert":false,"samples":[{"red":1,"green":0.4,"blue":0.4,"subtract":false},{"red":0,"green":1,"blue":0,"subtract":true}]}"#
    private let fixedCommand = #"{"tag":"colorRange","mode":"shadows","fuzziness":40,"invert":true,"samples":[]}"#

    func testRoundTripThroughTheCodec() throws {
        let value = try RecorderFileCodec.decode(bytes(document(sampledCommand)))
        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":36"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
        let prepared = try RecorderFileSemanticBridge.prepare(value)
        guard case .success(.colorRange(let settings))? = prepared.log.records.first?.resolution else {
            return XCTFail("The Color Range row was lost")
        }
        XCTAssertEqual(settings.mode, .sampled)
        XCTAssertEqual(settings.fuzziness, 40)
        XCTAssertFalse(settings.invert)
        XCTAssertEqual(settings.samples.count, 2)
        XCTAssertEqual(settings.samples[0].red, 1)
        XCTAssertEqual(settings.samples[1].green, 1)
        XCTAssertTrue(settings.samples[1].subtract)

        guard case .success(.colorRange, .none)? = value.records.first?.outcome else {
            return XCTFail("The Color Range command or its binding was lost")
        }

        let fixed = try RecorderFileCodec.decode(bytes(document(fixedCommand)))
        guard case .success(.colorRange(let settings))? = try RecorderFileSemanticBridge.prepare(fixed).log.records.first?.resolution else {
            return XCTFail("The fixed Color Range row was lost")
        }
        XCTAssertEqual(settings.mode, .shadows)
        XCTAssertTrue(settings.invert)
        XCTAssertEqual(settings.samples, [])
    }

    func testVersionAnchorAndOlderVersionRefusal() throws {
        XCTAssertEqual(RecorderFileCodec.colorRangeVersion, 36)
        XCTAssertGreaterThanOrEqual(RecorderFileCodec.latestVersion, RecorderFileCodec.colorRangeVersion)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            sampledCommand, version: 35))))
        // A version 36 file without a Color Range row is refused.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 36))))
        // A plain crop alone does not write version 36.
        let plain = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 1)))
        XCTAssertFalse(String(decoding: try RecorderFileCodec.encode(plain), as: UTF8.self)
            .contains(#""version":36"#))
    }

    func testSettingsRules() {
        let bad: [String] = [
            // Fuzziness outside 0...200.
            #"{"tag":"colorRange","mode":"sampledColors","fuzziness":201,"invert":false,"samples":[{"red":1,"green":1,"blue":1,"subtract":false}]}"#,
            #"{"tag":"colorRange","mode":"sampledColors","fuzziness":-1,"invert":false,"samples":[{"red":1,"green":1,"blue":1,"subtract":false}]}"#,
            // Subtract alone selects nothing.
            #"{"tag":"colorRange","mode":"sampledColors","fuzziness":40,"invert":false,"samples":[{"red":1,"green":1,"blue":1,"subtract":true}]}"#,
            // A fixed mode carries no samples.
            #"{"tag":"colorRange","mode":"reds","fuzziness":40,"invert":false,"samples":[{"red":1,"green":1,"blue":1,"subtract":false}]}"#,
            // Unknown mode, non-Boolean invert, non-finite component.
            #"{"tag":"colorRange","mode":"purples","fuzziness":40,"invert":false,"samples":[]}"#,
            #"{"tag":"colorRange","mode":"reds","fuzziness":40,"invert":2,"samples":[]}"#,
            #"{"tag":"colorRange","mode":"sampledColors","fuzziness":40,"invert":false,"samples":[{"red":1e999,"green":1,"blue":1,"subtract":false}]}"#,
            // Missing and unknown fields.
            #"{"tag":"colorRange","mode":"reds","fuzziness":40,"invert":false}"#,
            #"{"tag":"colorRange","mode":"reds","fuzziness":40,"invert":false,"samples":[],"future":1}"#,
            #"{"tag":"colorRange","mode":"reds","fuzziness":40,"invert":false,"samples":[{"red":1,"green":1,"subtract":false}]}"#,
        ]
        for command in bad {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command))), command)
        }

        // More than 64 samples are refused.
        let samples = (0..<65).map { _ in #"{"red":0,"green":0,"blue":0,"subtract":false}"# }.joined(separator: ",")
        let oversized = #"{"tag":"colorRange","mode":"sampledColors","fuzziness":40,"invert":false,"samples":["# + samples + "]}"
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(oversized))))

        // The inclusive limits decode: fuzziness 0 and 200, and 64 samples.
        let limit = (0..<64).map { _ in #"{"red":0,"green":0,"blue":0,"subtract":false}"# }.joined(separator: ",")
        for command in [
            #"{"tag":"colorRange","mode":"sampledColors","fuzziness":0,"invert":false,"samples":[{"red":1,"green":1,"blue":1,"subtract":false}]}"#,
            #"{"tag":"colorRange","mode":"sampledColors","fuzziness":200,"invert":false,"samples":[{"red":1,"green":1,"blue":1,"subtract":false}]}"#,
            #"{"tag":"colorRange","mode":"sampledColors","fuzziness":40,"invert":false,"samples":["# + limit + "]}",
        ] {
            XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(command))), command)
        }
    }

    func testBindingPairingRules() {
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            sampledCommand, binding: #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#,
            symbols: layerSymbolJSON))), "Color Range needs no layer binding")
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(sampledCommand))))
    }

    func testSemanticPropertiesAndSnapshotRoundTrip() throws {
        var settings = EngineSession.ColorRangeSettings()
        settings.samples = [.init(red: 1, green: 0.4, blue: 0.4, subtract: false),
                            .init(red: 0, green: 1, blue: 0, subtract: true)]
        let command = SemanticImageCommand.colorRange(settings)
        XCTAssertEqual(command.title, "Color Range")
        XCTAssertFalse(command.isLayerAdjustment)
        XCTAssertFalse(command.requiresResolvedFloatingSelection)
        let value = try RecorderFileCommand.colorRange(try RecorderColorRangeValue(settings))
        XCTAssertTrue(value.isTargetIndependent)
        XCTAssertThrowsError(try RecorderColorRangeValue(EngineSession.ColorRangeSettings()))

        // A fixed mode keeps its samples out of the file but returns them to
        // the dialog later only through the live settings, not the record.
        var fixedSettings = EngineSession.ColorRangeSettings()
        fixedSettings.mode = .highlights
        fixedSettings.samples = [.init(red: 0.5, green: 0.5, blue: 0.5, subtract: false)]
        let fixedValue = try RecorderColorRangeValue(fixedSettings)
        XCTAssertEqual(fixedValue.samples, [])
        XCTAssertEqual(try fixedValue.settings().mode, .highlights)

        let description = RecorderTargetDescription(name: "Layer", kind: .pixel, ancestors: [],
                                                    siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 10, height: 10))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description)])
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let first = try log.reserve()
        try log.resolve(first, with: .success(command))
        try log.stopRecording()
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Color Range",
                                                       origin: .init(imageLabel: "A", initialWidth: 200, initialHeight: 150),
                                                       descriptions: catalog, bindings: [0: .none])
        XCTAssertEqual(snapshot.records.count, 1)
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":36"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), snapshot)
        guard case .success(.colorRange(let stored), .none)? = snapshot.records.first?.outcome else {
            return XCTFail("The snapshot lost Color Range")
        }
        XCTAssertEqual(try stored.settings(), settings)
    }
}
