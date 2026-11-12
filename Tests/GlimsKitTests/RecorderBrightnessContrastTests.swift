import XCTest
@testable import GlimsKit

/// Strict recording-format version 10 coverage: a newly applied
/// Brightness/Contrast adjustment on an explicitly bound layer. Every fixture
/// spells out its own JSON; nothing reuses the production encoder.
final class RecorderBrightnessContrastTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private let origin = RecorderFileValue.Origin(imageLabel: "A", initialWidth: 41, initialHeight: 29)
    private let layerSymbol = #"{"id":"66666666-6666-6666-6666-666666666666","description":{"name":"Brightness/Contrast target","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let channelSymbol = #"{"id":"66666666-6666-6666-6666-666666666666","description":{"name":"Saved alpha","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let layerBinding = #"{"kind":"layer","symbol":"66666666-6666-6666-6666-666666666666"}"#

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func replace(_ text: String, _ before: String, _ after: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let range = text.range(of: before) else { XCTFail("Fixture mutation did not match: \(before)", file: file, line: line); return text }
        return text.replacingCharacters(in: range, with: after)
    }
    private func rejects(_ text: String, reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(text)), file: file, line: line) {
            XCTAssertTrue($0.localizedDescription.contains(reason), $0.localizedDescription, file: file, line: line)
        }
    }

    private func settings(brightness: Double = 0.3, contrast: Double = -0.25) -> String {
        "{\"brightness\":\(brightness),\"contrast\":\(contrast)}"
    }
    private func command(_ settings: String? = nil) -> String {
        #"{"tag":"applyBrightnessContrast","settings":"# + (settings ?? self.settings()) + "}"
    }
    private func document(_ rows: String, symbols: String = "", version: Int = 10) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Brightness/Contrast","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":["#
            + symbols + #"],"records":["# + rows + "]}"
    }
    private func success(_ command: String, binding: String = #"{"kind":"none"}"#, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func brightnessContrastDocument(command: String? = nil, binding: String? = nil,
                                            symbols: String? = nil, version: Int = 10) -> String {
        document(success(command ?? self.command(), binding: binding ?? layerBinding),
                 symbols: symbols ?? layerSymbol, version: version)
    }

    private var fileValue: RecorderBrightnessContrastValue { .init(brightness: 0.3, contrast: -0.25) }
    private var engineValue: EngineSession.BrightnessContrastSettings { .init(brightness: 0.3, contrast: -0.25) }

    func testVersionTenApplyBrightnessContrastLiteralDecodes() throws {
        let value = try RecorderFileCodec.decode(bytes(brightnessContrastDocument()))
        XCTAssertEqual(value.records.count, 1)
        XCTAssertEqual(value.symbols.count, 1)
        guard case .success(.applyBrightnessContrast(let settings), .layer(let id)) = value.records[0].outcome else {
            return XCTFail("The Brightness/Contrast command or its layer binding was lost")
        }
        XCTAssertEqual(id, symbol)
        XCTAssertEqual(settings, fileValue)
    }

    func testBoundaryValuesRoundTripExactly() throws {
        for pair in [(-1.0, -1.0), (-1.0, 1.0), (0.0, 0.0), (1.0, -1.0), (1.0, 1.0)] {
            let value = try RecorderFileCodec.decode(bytes(brightnessContrastDocument(command: command(settings(brightness: pair.0, contrast: pair.1)))))
            guard case .success(.applyBrightnessContrast(let settings), _) = value.records[0].outcome else { return XCTFail("Missing command") }
            XCTAssertEqual(settings, .init(brightness: pair.0, contrast: pair.1))
            XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(value)), value)
        }
    }

    func testUnknownMissingOrWrongFieldsReject() {
        let mutations = [
            (#""tag":"applyBrightnessContrast""#, #""tag":"applyBrightnessContrast","future":0"#),
            (#""brightness":0.3"#, #""brightness":0.3,"future":0"#),
            (#""brightness":0.3"#, #""brightness":0.3,"brightness":0.4"#),
            (#""brightness":0.3"#, #""brightness":"0.3""#),
            (#""contrast":-0.25"#, #""contrast":true"#),
            (#""brightness":0.3"#, #""brightness":1e309"#),
        ]
        for (old, new) in mutations {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(brightnessContrastDocument(), old, new))), old)
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(brightnessContrastDocument(command: #"{"tag":"applyBrightnessContrast","settings":{"brightness":0.3}}"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(brightnessContrastDocument(command: #"{"tag":"applyBrightnessContrast","settings":5}"#))))
    }

    func testOutOfRangeOrNonfiniteValuesReject() {
        for pair in [(-1.01, 0.0), (1.01, 0.0), (0.0, -1.01), (0.0, 1.01), (Double.nan, 0.0), (0.0, .infinity), (0.0, -.infinity)] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(brightnessContrastDocument(command: command(settings(brightness: pair.0, contrast: pair.1))))))
        }
    }

    func testVersionTenAnchorAndEarlierVersionRejection() {
        rejects(brightnessContrastDocument(version: 9), reason: "version 10")
        rejects(brightnessContrastDocument(version: 1), reason: "version 10")
        rejects(document(success(#"{"tag":"scale","width":1,"height":1}"#), version: 10),
                reason: "Version 10 requires a successful Brightness/Contrast command")
        let mixed = document(success(#"{"tag":"scale","width":1,"height":1}"#) + ","
            + success(command(), binding: layerBinding, ordinal: 1), symbols: layerSymbol)
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(mixed)))
    }

    func testExplicitLayerBindingIsMandatory() {
        rejects(brightnessContrastDocument(binding: #"{"kind":"none"}"#), reason: "binding kinds disagree")
        rejects(brightnessContrastDocument(binding: #"{"kind":"channel","symbol":"66666666-6666-6666-6666-666666666666"}"#,
                                           symbols: channelSymbol), reason: "binding kinds disagree")
        rejects(brightnessContrastDocument(symbols: channelSymbol), reason: "layer description")
        let unknown = #"{"kind":"layer","symbol":"77777777-7777-7777-7777-777777777777"}"#
        rejects(brightnessContrastDocument(binding: unknown), reason: "missing symbol")
        for kind in ["pixel", "group", "text", "link", "vector"] {
            let symbolJSON = #"{"id":"66666666-6666-6666-6666-666666666666","description":{"name":"T","kind":""#
                + kind + #"","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1}}}"#
            XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(brightnessContrastDocument(symbols: symbolJSON))), kind)
        }
    }

    func testApplyBrightnessContrastSelectsVersionTenAcrossMixedCommands() throws {
        let transform = #"{"tag":"transformLayer","matrix":{"a":0.5,"b":0.25,"c":-0.75,"d":1.25,"tx":-4.5,"ty":8},"interpolation":"loHalo"}"#
        let rows = success(command(), binding: layerBinding) + "," + success(transform, binding: layerBinding, ordinal: 1)
        let value = try RecorderFileCodec.decode(bytes(document(rows, symbols: layerSymbol)))
        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":10"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
    }

    func testEncodingRejectsInvalidCallerBuiltValues() {
        func value(_ settings: RecorderBrightnessContrastValue,
                   binding: RecorderBindingDescription? = nil) -> RecorderFileValue {
            let description = RecorderTargetDescription(name: "Target", kind: .pixel, ancestors: [],
                siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
            return .init(recordingID: recordingID, name: "Brightness/Contrast", origin: origin,
                symbols: [.init(id: symbol, description: description)],
                records: [.init(ordinal: 0, outcome: .success(.applyBrightnessContrast(settings), binding ?? .layer(symbol)))])
        }
        XCTAssertNoThrow(try RecorderFileCodec.encode(value(fileValue)))
        XCTAssertThrowsError(try RecorderFileCodec.encode(value(fileValue, binding: RecorderBindingDescription.none)))
        for invalid in [Double.nan, .infinity, -.infinity, -1.01, 1.01] {
            let bad = RecorderBrightnessContrastValue(brightness: invalid, contrast: 0)
            XCTAssertThrowsError(try bad.validated())
            XCTAssertThrowsError(try RecorderFileCodec.encode(value(bad)))
            XCTAssertThrowsError(try bad.settings())
        }
        var native = engineValue; native.brightness = 2
        XCTAssertThrowsError(try RecorderBrightnessContrastValue(native))
    }

    func testRecordedBrightnessContrastSnapshotsAsVersionTenWithExplicitLayerSymbol() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.applyBrightnessContrast(engineValue)))
        try log.stopRecording()
        let description = RecorderTargetDescription(name: "Brightness/Contrast target", kind: .pixel, ancestors: [],
            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description)])
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Brightness/Contrast",
                                                      origin: origin, descriptions: catalog, bindings: [0: .layer(symbol)])
        guard case .success(.applyBrightnessContrast(let settings), .layer(let id)) = snapshot.records[0].outcome else {
            return XCTFail("The recorded Brightness/Contrast or its explicit layer binding was lost")
        }
        XCTAssertEqual(settings, fileValue)
        XCTAssertEqual(id, symbol)
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":10"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), snapshot)
    }

    func testBrightnessContrastWithoutCapturedBindingNeverSnapshots() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.applyBrightnessContrast(engineValue)))
        try log.stopRecording()
        func snapshot(_ bindings: [Int: RecorderBindingDescription]) throws -> RecorderFileValue {
            try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Brightness/Contrast",
                                           origin: origin, descriptions: .init(), bindings: bindings)
        }
        XCTAssertThrowsError(try snapshot([:]))
        XCTAssertThrowsError(try snapshot([0: .none]))
        XCTAssertThrowsError(try snapshot([0: .unavailable("Capture failed")]))
        XCTAssertThrowsError(try snapshot([0: .channel(symbol)]))
    }

    func testPreparedLiteralRestoresTheExactFrontendSettings() throws {
        let prepared = try RecorderFileSemanticBridge.prepare(try RecorderFileCodec.decode(bytes(brightnessContrastDocument())))
        XCTAssertEqual(prepared.log.records.count, 1)
        guard case .success(.applyBrightnessContrast(let settings)) = prepared.log.records[0].resolution else {
            return XCTFail("The prepared Brightness/Contrast command was lost")
        }
        XCTAssertEqual(settings, engineValue)
        XCTAssertFalse(prepared.log.isRecording)
        XCTAssertFalse(prepared.log.isReplaying)
    }

    func testApplyBrightnessContrastIsALayerBoundResolveFirstCommand() throws {
        let command = SemanticImageCommand.applyBrightnessContrast(engineValue)
        XCTAssertEqual(command.title, "Brightness/Contrast")
        XCTAssertTrue(command.requiresResolvedFloatingSelection)
        XCTAssertTrue(command.isLayerAdjustment)
        XCTAssertEqual(try RecorderFileCommand(.applyBrightnessContrast(engineValue)),
                       .applyBrightnessContrast(fileValue))
    }
}
