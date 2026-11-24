import XCTest
@testable import GlimsKit

/// Image > Adjust > Variations' Recorder rows at format version 35: the
/// codec round trip, the version anchor, the closed settings schema and
/// the explicit layer binding.
final class RecorderVariationsTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let layerSymbolJSON = #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#
    private let layerBinding = #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#
    private let channelSymbolJSON = #"{"id":"33333333-3333-3333-3333-333333333333","description":{"name":"Channel","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":10,"height":10}}}"#

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func file(version: Int, symbols: String, records: String) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Variations","origin":{"imageLabel":"A","initialWidth":200,"initialHeight":150},"symbols":["#
            + symbols + #"],"records":["# + records + "]}"
    }
    private func success(_ command: String, binding: String, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func document(_ command: String, version: Int = 35, binding: String = #"{"kind":"none"}"#,
                          symbols: String = "") -> String {
        file(version: version, symbols: symbols, records: success(command, binding: binding))
    }

    private let fullCommand = #"{"tag":"applyVariations","settings":{"shadows":{"cyanRed":0.2,"magentaGreen":0,"yellowBlue":0},"midtones":{"cyanRed":0,"magentaGreen":-0.3,"yellowBlue":0},"highlights":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0.4},"lightness":0.1,"saturation":-0.2}}"#

    func testRoundTripThroughTheCodec() throws {
        let value = try RecorderFileCodec.decode(bytes(document(
            fullCommand, binding: layerBinding, symbols: layerSymbolJSON)))
        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":35"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
        let prepared = try RecorderFileSemanticBridge.prepare(value)
        guard case .success(.applyVariations(let settings))? = prepared.log.records.first?.resolution else {
            return XCTFail("The Variations row was lost")
        }
        XCTAssertEqual(settings.lightness, 0.1)
        XCTAssertEqual(settings.saturation, -0.2)
        XCTAssertEqual(settings.shadows.cyanRed, 0.2)
        XCTAssertEqual(settings.midtones.magentaGreen, -0.3)
        XCTAssertEqual(settings.highlights.yellowBlue, 0.4)

        let decoded = try RecorderFileCodec.decode(bytes(document(
            fullCommand, binding: layerBinding, symbols: layerSymbolJSON)))
        guard case .success(.applyVariations, .layer(let bound))? = decoded.records.first?.outcome else {
            return XCTFail("The Variations command or its binding was lost")
        }
        XCTAssertEqual(bound, symbol)
    }

    func testVersionAnchorAndOlderVersionRefusal() throws {
        XCTAssertEqual(RecorderFileCodec.variationsVersion, 35)
        XCTAssertGreaterThanOrEqual(RecorderFileCodec.latestVersion, RecorderFileCodec.variationsVersion)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            fullCommand, version: 34, binding: layerBinding, symbols: layerSymbolJSON))))
        // A version 35 file without a Variations row is refused.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 35))))
        // A plain crop alone does not write version 35.
        let plain = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 1)))
        XCTAssertFalse(String(decoding: try RecorderFileCodec.encode(plain), as: UTF8.self)
            .contains(#""version":35"#))
    }

    func testSettingsRules() {
        let bad: [String] = [
            // Identity changes nothing.
            #"{"tag":"applyVariations","settings":{"shadows":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"midtones":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"highlights":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"lightness":0,"saturation":0}}"#,
            // Out-of-range corrections.
            #"{"tag":"applyVariations","settings":{"shadows":{"cyanRed":1.5,"magentaGreen":0,"yellowBlue":0},"midtones":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"highlights":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"lightness":0,"saturation":0}}"#,
            #"{"tag":"applyVariations","settings":{"shadows":{"cyanRed":-1.0001,"magentaGreen":0,"yellowBlue":0},"midtones":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"highlights":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"lightness":0,"saturation":0}}"#,
            #"{"tag":"applyVariations","settings":{"shadows":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"midtones":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"highlights":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"lightness":2,"saturation":0}}"#,
            #"{"tag":"applyVariations","settings":{"shadows":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"midtones":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"highlights":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"lightness":0,"saturation":-2}}"#,
            // Missing and unknown fields.
            #"{"tag":"applyVariations","settings":{"shadows":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"midtones":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"highlights":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"lightness":0}}"#,
            #"{"tag":"applyVariations","settings":{"shadows":{"cyanRed":0,"magentaGreen":0},"midtones":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"highlights":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"lightness":0,"saturation":0}}"#,
            #"{"tag":"applyVariations","settings":{"shadows":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"midtones":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"highlights":{"cyanRed":0,"magentaGreen":0,"yellowBlue":0},"lightness":0,"saturation":0,"future":1}}"#,
        ]
        for command in bad {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
                command, binding: layerBinding, symbols: layerSymbolJSON))), command)
        }
    }

    func testBindingPairingRules() {
        for binding in [#"{"kind":"none"}"#,
                        #"{"kind":"layer","symbol":"33333333-3333-3333-3333-333333333333"}"#] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
                fullCommand, binding: binding,
                symbols: binding == #"{"kind":"none"}"# ? "" : channelSymbolJSON))),
                "binding: \(binding)")
        }
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(
            fullCommand, binding: layerBinding, symbols: layerSymbolJSON))))
    }

    func testSemanticPropertiesAndSnapshotRoundTrip() throws {
        var settings = EngineSession.VariationsSettings()
        settings.shadows.cyanRed = 0.2
        settings.midtones.magentaGreen = -0.3
        settings.highlights.yellowBlue = 0.4
        settings.lightness = 0.1
        settings.saturation = -0.2
        let command = SemanticImageCommand.applyVariations(settings)
        XCTAssertEqual(command.title, "Variations")
        XCTAssertTrue(command.isLayerAdjustment)
        XCTAssertTrue(command.requiresResolvedFloatingSelection)
        XCTAssertFalse(RecorderFileCommand.applyVariations(try RecorderVariationsValue(settings)).isTargetIndependent)
        XCTAssertThrowsError(try RecorderVariationsValue(EngineSession.VariationsSettings())) { error in
            XCTAssertEqual(error as? RecorderFileError,
                           .invalid("A recorded Variations value changes nothing."))
        }
        // An out-of-range value names the range, not "changes nothing".
        var outOfRange = settings
        outOfRange.lightness = 2
        XCTAssertThrowsError(try RecorderVariationsValue(outOfRange)) { error in
            XCTAssertEqual(error as? RecorderFileError,
                           .invalid("A recorded Variations value must be finite and between -1 and 1."))
        }

        let description = RecorderTargetDescription(name: "Layer", kind: .pixel, ancestors: [],
                                                    siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 10, height: 10))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description)])
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let first = try log.reserve()
        try log.resolve(first, with: .success(command))
        try log.stopRecording()
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Variations",
                                                       origin: .init(imageLabel: "A", initialWidth: 200, initialHeight: 150),
                                                       descriptions: catalog, bindings: [0: .layer(symbol)])
        XCTAssertEqual(snapshot.records.count, 1)
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":35"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), snapshot)
        guard case .success(.applyVariations(let stored), .layer)? = snapshot.records.first?.outcome else {
            return XCTFail("The snapshot lost Variations")
        }
        XCTAssertEqual(try stored.settings(), settings)
    }
}
