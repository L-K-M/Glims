import XCTest
@testable import GlimsKit

/// Strict recording-format version 9 coverage: a newly applied
/// Hue/Saturation adjustment on an explicitly bound layer. Every fixture
/// spells out its own JSON; nothing reuses the production encoder.
final class RecorderHueSaturationTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private let origin = RecorderFileValue.Origin(imageLabel: "A", initialWidth: 41, initialHeight: 29)
    private let layerSymbol = #"{"id":"66666666-6666-6666-6666-666666666666","description":{"name":"Hue/Saturation target","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
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

    /// A named-range literal with all three corrections nonzero, in wire
    /// field order.
    private func range(hue: Double = 0.25, saturation: Double = -0.5, lightness: Double = 0.1) -> String {
        "{\"hue\":\(hue),\"saturation\":\(saturation),\"lightness\":\(lightness)}"
    }
    /// All 21 corrections nonzero by default, overlap midrange.
    private func settings(overlap: Double = 0.45, master: String? = nil, red: String? = nil,
                          yellow: String? = nil, green: String? = nil, cyan: String? = nil,
                          blue: String? = nil, magenta: String? = nil) -> String {
        #"{"overlap":"# + String(overlap)
            + #","master":"# + (master ?? range())
            + #","red":"# + (red ?? range(hue: -0.5, saturation: 0.3, lightness: -0.2))
            + #","yellow":"# + (yellow ?? range(hue: 0.15, saturation: 0.6, lightness: 0.4))
            + #","green":"# + (green ?? range(hue: -0.35, saturation: -0.7, lightness: 0.5))
            + #","cyan":"# + (cyan ?? range(hue: 0.65, saturation: 0.8, lightness: -0.6))
            + #","blue":"# + (blue ?? range(hue: -0.75, saturation: -0.9, lightness: 0.7))
            + #","magenta":"# + (magenta ?? range(hue: 0.9, saturation: 1.0, lightness: -0.8)) + "}"
    }
    private func command(_ settings: String? = nil) -> String {
        #"{"tag":"applyHueSaturation","settings":"# + (settings ?? self.settings()) + "}"
    }
    private func document(_ rows: String, symbols: String = "", version: Int = 9) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Hue/Saturation","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":["#
            + symbols + #"],"records":["# + rows + "]}"
    }
    private func success(_ command: String, binding: String = #"{"kind":"none"}"#, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func hueSaturationDocument(command: String? = nil, binding: String? = nil,
                                       symbols: String? = nil, version: Int = 9) -> String {
        document(success(command ?? self.command(), binding: binding ?? layerBinding),
                 symbols: symbols ?? layerSymbol, version: version)
    }

    /// The same values as the `settings` literal, as owned file and
    /// frontend types. All 21 corrections nonzero, overlap midrange.
    private var fileHueSaturation: RecorderHueSaturationValue {
        .init(overlap: 0.45,
              master: .init(hue: 0.25, saturation: -0.5, lightness: 0.1),
              red: .init(hue: -0.5, saturation: 0.3, lightness: -0.2),
              yellow: .init(hue: 0.15, saturation: 0.6, lightness: 0.4),
              green: .init(hue: -0.35, saturation: -0.7, lightness: 0.5),
              cyan: .init(hue: 0.65, saturation: 0.8, lightness: -0.6),
              blue: .init(hue: -0.75, saturation: -0.9, lightness: 0.7),
              magenta: .init(hue: 0.9, saturation: 1.0, lightness: -0.8))
    }
    private var engineHueSaturation: EngineSession.HueSaturationSettings {
        EngineSession.HueSaturationSettings(
            overlap: 0.45,
            master: .init(hue: 0.25, saturation: -0.5, lightness: 0.1),
            red: .init(hue: -0.5, saturation: 0.3, lightness: -0.2),
            yellow: .init(hue: 0.15, saturation: 0.6, lightness: 0.4),
            green: .init(hue: -0.35, saturation: -0.7, lightness: 0.5),
            cyan: .init(hue: 0.65, saturation: 0.8, lightness: -0.6),
            blue: .init(hue: -0.75, saturation: -0.9, lightness: 0.7),
            magenta: .init(hue: 0.9, saturation: 1.0, lightness: -0.8))
    }

    func testVersionNineApplyHueSaturationLiteralDecodes() throws {
        let value = try RecorderFileCodec.decode(bytes(hueSaturationDocument()))
        XCTAssertEqual(value.records.count, 1)
        XCTAssertEqual(value.symbols.count, 1)
        guard case .success(.applyHueSaturation(let hueSaturation), .layer(let id)) = value.records[0].outcome else {
            return XCTFail("The Hue/Saturation command or its layer binding was lost")
        }
        XCTAssertEqual(id, symbol)
        XCTAssertEqual(hueSaturation, fileHueSaturation)
    }

    func testEveryCorrectionAndOverlapRoundTripsExactly() throws {
        for overlap in [0.0, 0.45, 1.0] {
            let text = hueSaturationDocument(command: command(settings(overlap: overlap)))
            let value = try RecorderFileCodec.decode(bytes(text))
            guard case .success(.applyHueSaturation(let hueSaturation), _) = value.records[0].outcome else {
                return XCTFail("Missing Hue/Saturation command")
            }
            let expected = RecorderHueSaturationValue(overlap: overlap,
                master: fileHueSaturation.master, red: fileHueSaturation.red, yellow: fileHueSaturation.yellow,
                green: fileHueSaturation.green, cyan: fileHueSaturation.cyan,
                blue: fileHueSaturation.blue, magenta: fileHueSaturation.magenta)
            XCTAssertEqual(hueSaturation, expected)
            XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(value)), value)
        }
        // The closed correction bounds themselves stay valid.
        for correction in [-1.0, 0.0, 1.0] {
            let literal = range(hue: correction, saturation: correction, lightness: correction)
            XCTAssertNoThrow(try RecorderFileCodec.decode(
                bytes(hueSaturationDocument(command: command(settings(master: literal))))))
        }
    }

    func testUnknownOrMissingFieldsAndWrongTypesReject() {
        let mutations = [
            (#""tag":"applyHueSaturation""#, #""tag":"applyHueSaturation","future":0"#), // unknown command field
            (#""overlap":0.45"#, #""overlap":0.45,"future":0"#),                        // unknown settings field
            (#""hue":0.25"#, #""future":0,"hue":0.25"#),                               // unknown range field
            (#""hue":0.25"#, #""hue":0.25,"hue":0.26"#),                               // duplicate range field
            (#""hue":0.25"#, #""hue":"0.25""#),                                        // correction as string
            (#""saturation":-0.5"#, #""saturation":true"#),                            // correction as bool
            (#""overlap":0.45"#, #""overlap":true"#),                                  // overlap as bool
            (#""overlap":0.45"#, #""overlap":"0.45""#),                                // overlap as string
            (#""hue":0.25"#, #""hue":1e309"#),                                         // nonfinite overflow
        ]
        for (old, new) in mutations {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(hueSaturationDocument(), old, new))), old)
        }
        // A missing named range and a missing range field both reject.
        let missingMagenta = replace(settings(), ",\"magenta\":" + range(hue: 0.9, saturation: 1.0, lightness: -0.8), "")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: bytes(missingMagenta)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(hueSaturationDocument(command: command(missingMagenta)))))
        let missingField = command(settings(master: #"{"hue":0.25,"saturation":-0.5}"#))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(hueSaturationDocument(command: missingField))))
        // A range object is not optional or substitutable.
        let typed = command(settings(master: "5"))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(hueSaturationDocument(command: typed))))
        // Overlap itself is not optional.
        let missingOverlap = replace(settings(), #"{"overlap":0.45,"#, "{")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: bytes(missingOverlap)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(hueSaturationDocument(command: command(missingOverlap)))))
    }

    func testOutOfRangeCorrectionsAndOverlapReject() {
        for literal in [range(hue: -1.01), range(hue: 1.01), range(saturation: 2),
                        range(lightness: -2), range(saturation: -.infinity), range(lightness: .infinity)] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(
                bytes(hueSaturationDocument(command: command(settings(red: literal))))), literal)
        }
        for overlap in [-0.01, 1.01, Double.nan, .infinity, -.infinity] {
            let literal = settings(overlap: overlap)
            XCTAssertThrowsError(try RecorderFileCodec.decode(
                bytes(hueSaturationDocument(command: command(literal)))), literal)
        }
    }

    func testVersionNineAnchorAndEarlierVersionRejection() {
        rejects(hueSaturationDocument(version: 8), reason: "version 9")
        rejects(hueSaturationDocument(version: 1), reason: "version 9")
        rejects(document(success(#"{"tag":"scale","width":1,"height":1}"#), version: 9),
                reason: "Version 9 requires a successful Hue/Saturation command")
        // A version 9 file may still carry the earlier command families.
        let mixed = document(success(#"{"tag":"scale","width":1,"height":1}"#) + ","
            + success(command(), binding: layerBinding, ordinal: 1), symbols: layerSymbol)
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(mixed)))
    }

    func testExplicitLayerBindingIsMandatory() {
        rejects(hueSaturationDocument(binding: #"{"kind":"none"}"#), reason: "binding kinds disagree")
        rejects(hueSaturationDocument(binding: #"{"kind":"channel","symbol":"66666666-6666-6666-6666-666666666666"}"#,
                                      symbols: channelSymbol), reason: "binding kinds disagree")
        rejects(hueSaturationDocument(symbols: channelSymbol), reason: "layer description")
        let unknown = #"{"kind":"layer","symbol":"77777777-7777-7777-7777-777777777777"}"#
        rejects(hueSaturationDocument(binding: unknown), reason: "missing symbol")
        // Every non-channel layer kind binds, like the earlier adjustments.
        for kind in ["pixel", "group", "text", "link", "vector"] {
            let symbolJSON = #"{"id":"66666666-6666-6666-6666-666666666666","description":{"name":"T","kind":""#
                + kind + #"","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1}}}"#
            XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(hueSaturationDocument(symbols: symbolJSON))), kind)
        }
    }

    func testApplyHueSaturationSelectsVersionNineAcrossMixedCommands() throws {
        let transform = #"{"tag":"transformLayer","matrix":{"a":0.5,"b":0.25,"c":-0.75,"d":1.25,"tx":-4.5,"ty":8},"interpolation":"loHalo"}"#
        let rows = success(command(), binding: layerBinding) + "," + success(transform, binding: layerBinding, ordinal: 1)
        let value = try RecorderFileCodec.decode(bytes(document(rows, symbols: layerSymbol)))
        let encoded = try RecorderFileCodec.encode(value)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains(#""version":9"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
    }

    func testEncodingRejectsInvalidCallerBuiltValues() {
        func value(_ hueSaturation: RecorderHueSaturationValue,
                   binding: RecorderBindingDescription? = nil) -> RecorderFileValue {
            let description = RecorderTargetDescription(name: "Target", kind: .pixel, ancestors: [],
                siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
            return .init(recordingID: recordingID, name: "Hue/Saturation", origin: origin,
                symbols: [.init(id: symbol, description: description)],
                records: [.init(ordinal: 0, outcome: .success(.applyHueSaturation(hueSaturation), binding ?? .layer(symbol)))])
        }
        XCTAssertNoThrow(try RecorderFileCodec.encode(value(fileHueSaturation)))
        XCTAssertThrowsError(try RecorderFileCodec.encode(value(fileHueSaturation, binding: RecorderBindingDescription.none)))
        for invalid in [Double.nan, .infinity, -.infinity, -1.01, 1.01] {
            let bad = RecorderHueSaturationValue.Range(hue: invalid, saturation: 0, lightness: 0)
            let hueSaturation = RecorderHueSaturationValue(overlap: fileHueSaturation.overlap,
                master: bad, red: fileHueSaturation.red, yellow: fileHueSaturation.yellow,
                green: fileHueSaturation.green, cyan: fileHueSaturation.cyan,
                blue: fileHueSaturation.blue, magenta: fileHueSaturation.magenta)
            XCTAssertThrowsError(try hueSaturation.validated())
            XCTAssertThrowsError(try RecorderFileCodec.encode(value(hueSaturation)))
            XCTAssertThrowsError(try hueSaturation.settings())
        }
        for invalid in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            let hueSaturation = RecorderHueSaturationValue(overlap: invalid,
                master: fileHueSaturation.master, red: fileHueSaturation.red, yellow: fileHueSaturation.yellow,
                green: fileHueSaturation.green, cyan: fileHueSaturation.cyan,
                blue: fileHueSaturation.blue, magenta: fileHueSaturation.magenta)
            XCTAssertThrowsError(try hueSaturation.validated())
            XCTAssertThrowsError(try RecorderFileCodec.encode(value(hueSaturation)))
            XCTAssertThrowsError(try hueSaturation.settings())
        }
        // An invalid native value refuses the bridge instead of producing a
        // partial file value.
        var native = engineHueSaturation
        native.blue.hue = 2
        XCTAssertThrowsError(try RecorderHueSaturationValue(native))
        native = engineHueSaturation
        native.overlap = 1.5
        XCTAssertThrowsError(try RecorderHueSaturationValue(native))
    }

    func testRecordedHueSaturationSnapshotsAsVersionNineWithExplicitLayerSymbol() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.applyHueSaturation(engineHueSaturation)))
        try log.stopRecording()
        let description = RecorderTargetDescription(name: "Hue/Saturation target", kind: .pixel, ancestors: [],
            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description)])
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Hue/Saturation",
                                                      origin: origin, descriptions: catalog, bindings: [0: .layer(symbol)])
        guard case .success(.applyHueSaturation(let hueSaturation), .layer(let id)) = snapshot.records[0].outcome else {
            return XCTFail("The recorded Hue/Saturation or its explicit layer binding was lost")
        }
        XCTAssertEqual(hueSaturation, fileHueSaturation)
        XCTAssertEqual(id, symbol)
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":9"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), snapshot)
    }

    func testHueSaturationWithoutCapturedBindingNeverSnapshots() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.applyHueSaturation(engineHueSaturation)))
        try log.stopRecording()
        func snapshot(_ bindings: [Int: RecorderBindingDescription]) throws -> RecorderFileValue {
            try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Hue/Saturation",
                                           origin: origin, descriptions: .init(), bindings: bindings)
        }
        XCTAssertThrowsError(try snapshot([:]))
        XCTAssertThrowsError(try snapshot([0: .none]))
        XCTAssertThrowsError(try snapshot([0: .unavailable("Capture failed")]))
        XCTAssertThrowsError(try snapshot([0: .channel(symbol)]))
    }

    func testPreparedLiteralRestoresTheExactFrontendSettings() throws {
        let prepared = try RecorderFileSemanticBridge.prepare(try RecorderFileCodec.decode(bytes(hueSaturationDocument())))
        XCTAssertEqual(prepared.log.records.count, 1)
        guard case .success(.applyHueSaturation(let settings)) = prepared.log.records[0].resolution else {
            return XCTFail("The prepared Hue/Saturation command was lost")
        }
        XCTAssertEqual(settings, engineHueSaturation)
        XCTAssertFalse(prepared.log.isRecording)
        XCTAssertFalse(prepared.log.isReplaying)
    }

    func testApplyHueSaturationIsALayerBoundResolveFirstCommand() throws {
        let command = SemanticImageCommand.applyHueSaturation(engineHueSaturation)
        XCTAssertEqual(command.title, "Hue/Saturation")
        XCTAssertTrue(command.requiresResolvedFloatingSelection)
        XCTAssertTrue(command.isLayerAdjustment)
        // The command needs an explicit layer binding at apply; execution
        // itself is exercised only by the native acceptance matrix.
        XCTAssertEqual(try RecorderFileCommand(.applyHueSaturation(engineHueSaturation)),
                       .applyHueSaturation(fileHueSaturation))
    }
}
