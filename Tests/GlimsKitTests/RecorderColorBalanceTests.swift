import XCTest
@testable import GlimsKit

/// Strict recording-format version 8 coverage: a newly applied Color
/// Balance adjustment on an explicitly bound layer. Every fixture spells
/// out its own JSON; nothing reuses the production encoder.
final class RecorderColorBalanceTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private let origin = RecorderFileValue.Origin(imageLabel: "A", initialWidth: 41, initialHeight: 29)
    private let layerSymbol = #"{"id":"66666666-6666-6666-6666-666666666666","description":{"name":"Color Balance target","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
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

    /// A tonal-range literal with all three corrections nonzero, in wire
    /// field order.
    private func range(cyanRed: Double = 0.11, magentaGreen: Double = -0.22, yellowBlue: Double = 0.33) -> String {
        "{\"cyanRed\":\(cyanRed),\"magentaGreen\":\(magentaGreen),\"yellowBlue\":\(yellowBlue)}"
    }
    /// All nine corrections nonzero by default, Preserve Lightness off.
    private func settings(shadows: String? = nil, midtones: String? = nil, highlights: String? = nil,
                          preserveLuminosity: Bool = false) -> String {
        #"{"shadows":"# + (shadows ?? range())
            + #","midtones":"# + (midtones ?? range(cyanRed: -0.44, magentaGreen: 0.55, yellowBlue: -0.66))
            + #","highlights":"# + (highlights ?? range(cyanRed: 0.77, magentaGreen: -0.88, yellowBlue: 0.99))
            + #","preserveLuminosity":"# + String(preserveLuminosity) + "}"
    }
    private func command(_ settings: String? = nil) -> String {
        #"{"tag":"applyColorBalance","settings":"# + (settings ?? self.settings()) + "}"
    }
    private func document(_ rows: String, symbols: String = "", version: Int = 8) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Color Balance","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":["#
            + symbols + #"],"records":["# + rows + "]}"
    }
    private func success(_ command: String, binding: String = #"{"kind":"none"}"#, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func colorBalanceDocument(command: String? = nil, binding: String? = nil,
                                      symbols: String? = nil, version: Int = 8) -> String {
        document(success(command ?? self.command(), binding: binding ?? layerBinding),
                 symbols: symbols ?? layerSymbol, version: version)
    }

    /// The same values as the `settings` literal, as owned file and
    /// frontend types. All nine corrections nonzero, Preserve off.
    private var fileBalance: RecorderColorBalanceValue {
        .init(shadows: .init(cyanRed: 0.11, magentaGreen: -0.22, yellowBlue: 0.33),
              midtones: .init(cyanRed: -0.44, magentaGreen: 0.55, yellowBlue: -0.66),
              highlights: .init(cyanRed: 0.77, magentaGreen: -0.88, yellowBlue: 0.99),
              preserveLuminosity: false)
    }
    private var engineBalance: EngineSession.ColorBalanceSettings {
        EngineSession.ColorBalanceSettings(
            shadows: .init(cyanRed: 0.11, magentaGreen: -0.22, yellowBlue: 0.33),
            midtones: .init(cyanRed: -0.44, magentaGreen: 0.55, yellowBlue: -0.66),
            highlights: .init(cyanRed: 0.77, magentaGreen: -0.88, yellowBlue: 0.99),
            preserveLuminosity: false)
    }

    func testVersionEightApplyColorBalanceLiteralDecodes() throws {
        let value = try RecorderFileCodec.decode(bytes(colorBalanceDocument()))
        XCTAssertEqual(value.records.count, 1)
        XCTAssertEqual(value.symbols.count, 1)
        guard case .success(.applyColorBalance(let balance), .layer(let id)) = value.records[0].outcome else {
            return XCTFail("The Color Balance command or its layer binding was lost")
        }
        XCTAssertEqual(id, symbol)
        XCTAssertEqual(balance, fileBalance)
    }

    func testEveryCorrectionAndLuminosityRoundTripsExactly() throws {
        for preserve in [false, true] {
            let text = colorBalanceDocument(command: command(settings(preserveLuminosity: preserve)))
            let value = try RecorderFileCodec.decode(bytes(text))
            guard case .success(.applyColorBalance(let balance), _) = value.records[0].outcome else {
                return XCTFail("Missing Color Balance command")
            }
            let expected = RecorderColorBalanceValue(shadows: fileBalance.shadows, midtones: fileBalance.midtones,
                highlights: fileBalance.highlights, preserveLuminosity: preserve)
            XCTAssertEqual(balance, expected)
            XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(value)), value)
        }
        // The closed correction bounds themselves stay valid.
        for correction in [-1.0, 0.0, 1.0] {
            let literal = range(cyanRed: correction, magentaGreen: correction, yellowBlue: correction)
            XCTAssertNoThrow(try RecorderFileCodec.decode(
                bytes(colorBalanceDocument(command: command(settings(shadows: literal))))))
        }
    }

    func testUnknownOrMissingFieldsAndWrongTypesReject() {
        let mutations = [
            (#""tag":"applyColorBalance""#, #""tag":"applyColorBalance","future":0"#),   // unknown command field
            (#""preserveLuminosity":false"#, #""preserveLuminosity":false,"future":0"#), // unknown settings field
            (#""cyanRed":0.11"#, #""future":0,"cyanRed":0.11"#),                         // unknown range field
            (#""cyanRed":0.11"#, #""cyanRed":0.11,"cyanRed":0.12"#),                     // duplicate range field
            (#""cyanRed":0.11"#, #""cyanRed":"0.11""#),                                  // correction as string
            (#""magentaGreen":-0.22"#, #""magentaGreen":true"#),                         // correction as bool
            (#""preserveLuminosity":false"#, #""preserveLuminosity":0"#),                // luminosity as number
            (#""preserveLuminosity":false"#, #""preserveLuminosity":"false""#),          // luminosity as string
            (#""cyanRed":0.11"#, #""cyanRed":1e309"#),                                   // nonfinite overflow
        ]
        for (old, new) in mutations {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(colorBalanceDocument(), old, new))), old)
        }
        // A missing tonal range and a missing range field both reject.
        let missingHighlights = replace(settings(), ",\"highlights\":" + range(cyanRed: 0.77, magentaGreen: -0.88, yellowBlue: 0.99), "")
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: bytes(missingHighlights)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(colorBalanceDocument(command: command(missingHighlights)))))
        let missingField = command(settings(shadows: #"{"cyanRed":0.11,"magentaGreen":-0.22}"#))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(colorBalanceDocument(command: missingField))))
        // A range object is not optional or substitutable.
        let typed = command(settings(shadows: "5"))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(colorBalanceDocument(command: typed))))
    }

    func testOutOfRangeCorrectionsReject() {
        for literal in [range(cyanRed: -1.01), range(cyanRed: 1.01), range(magentaGreen: 2),
                        range(yellowBlue: -2), range(magentaGreen: -.infinity), range(yellowBlue: .infinity)] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(
                bytes(colorBalanceDocument(command: command(settings(midtones: literal))))), literal)
        }
    }

    func testVersionEightAnchorAndEarlierVersionRejection() {
        rejects(colorBalanceDocument(version: 7), reason: "version 8")
        rejects(colorBalanceDocument(version: 1), reason: "version 8")
        rejects(document(success(#"{"tag":"scale","width":1,"height":1}"#), version: 8),
                reason: "Version 8 requires a successful Color Balance command")
        // A version 8 file may still carry the earlier command families.
        let mixed = document(success(#"{"tag":"scale","width":1,"height":1}"#) + ","
            + success(command(), binding: layerBinding, ordinal: 1), symbols: layerSymbol)
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(mixed)))
    }

    func testExplicitLayerBindingIsMandatory() {
        rejects(colorBalanceDocument(binding: #"{"kind":"none"}"#), reason: "binding kinds disagree")
        rejects(colorBalanceDocument(binding: #"{"kind":"channel","symbol":"66666666-6666-6666-6666-666666666666"}"#,
                                     symbols: channelSymbol), reason: "binding kinds disagree")
        rejects(colorBalanceDocument(symbols: channelSymbol), reason: "layer description")
        let unknown = #"{"kind":"layer","symbol":"77777777-7777-7777-7777-777777777777"}"#
        rejects(colorBalanceDocument(binding: unknown), reason: "missing symbol")
        // Every non-channel layer kind binds, like Levels and Curves.
        for kind in ["pixel", "group", "text", "link", "vector"] {
            let symbolJSON = #"{"id":"66666666-6666-6666-6666-666666666666","description":{"name":"T","kind":""#
                + kind + #"","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1}}}"#
            XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(colorBalanceDocument(symbols: symbolJSON))), kind)
        }
    }

    func testApplyColorBalanceSelectsVersionEightAcrossMixedCommands() throws {
        let transform = #"{"tag":"transformLayer","matrix":{"a":0.5,"b":0.25,"c":-0.75,"d":1.25,"tx":-4.5,"ty":8},"interpolation":"loHalo"}"#
        let rows = success(command(), binding: layerBinding) + "," + success(transform, binding: layerBinding, ordinal: 1)
        let value = try RecorderFileCodec.decode(bytes(document(rows, symbols: layerSymbol)))
        let encoded = try RecorderFileCodec.encode(value)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains(#""version":8"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
    }

    func testEncodingRejectsInvalidCallerBuiltValues() {
        func value(_ balance: RecorderColorBalanceValue,
                   binding: RecorderBindingDescription? = nil) -> RecorderFileValue {
            let description = RecorderTargetDescription(name: "Target", kind: .pixel, ancestors: [],
                siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
            return .init(recordingID: recordingID, name: "Color Balance", origin: origin,
                symbols: [.init(id: symbol, description: description)],
                records: [.init(ordinal: 0, outcome: .success(.applyColorBalance(balance), binding ?? .layer(symbol)))])
        }
        XCTAssertNoThrow(try RecorderFileCodec.encode(value(fileBalance)))
        XCTAssertThrowsError(try RecorderFileCodec.encode(value(fileBalance, binding: RecorderBindingDescription.none)))
        for invalid in [Double.nan, .infinity, -.infinity, -1.01, 1.01] {
            let bad = RecorderColorBalanceValue.Range(cyanRed: invalid, magentaGreen: 0, yellowBlue: 0)
            let balance = RecorderColorBalanceValue(shadows: bad, midtones: fileBalance.midtones,
                highlights: fileBalance.highlights, preserveLuminosity: fileBalance.preserveLuminosity)
            XCTAssertThrowsError(try balance.validated())
            XCTAssertThrowsError(try RecorderFileCodec.encode(value(balance)))
            XCTAssertThrowsError(try balance.settings())
        }
        // An invalid native value refuses the bridge instead of producing a
        // partial file value.
        var native = engineBalance
        native.highlights.yellowBlue = 2
        XCTAssertThrowsError(try RecorderColorBalanceValue(native))
    }

    func testRecordedColorBalanceSnapshotsAsVersionEightWithExplicitLayerSymbol() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.applyColorBalance(engineBalance)))
        try log.stopRecording()
        let description = RecorderTargetDescription(name: "Color Balance target", kind: .pixel, ancestors: [],
            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description)])
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Color Balance",
                                                      origin: origin, descriptions: catalog, bindings: [0: .layer(symbol)])
        guard case .success(.applyColorBalance(let balance), .layer(let id)) = snapshot.records[0].outcome else {
            return XCTFail("The recorded Color Balance or its explicit layer binding was lost")
        }
        XCTAssertEqual(balance, fileBalance)
        XCTAssertEqual(id, symbol)
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":8"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), snapshot)
    }

    func testColorBalanceWithoutCapturedBindingNeverSnapshots() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.applyColorBalance(engineBalance)))
        try log.stopRecording()
        func snapshot(_ bindings: [Int: RecorderBindingDescription]) throws -> RecorderFileValue {
            try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Color Balance",
                                           origin: origin, descriptions: .init(), bindings: bindings)
        }
        XCTAssertThrowsError(try snapshot([:]))
        XCTAssertThrowsError(try snapshot([0: .none]))
        XCTAssertThrowsError(try snapshot([0: .unavailable("Capture failed")]))
        XCTAssertThrowsError(try snapshot([0: .channel(symbol)]))
    }

    func testPreparedLiteralRestoresTheExactFrontendSettings() throws {
        let prepared = try RecorderFileSemanticBridge.prepare(try RecorderFileCodec.decode(bytes(colorBalanceDocument())))
        XCTAssertEqual(prepared.log.records.count, 1)
        guard case .success(.applyColorBalance(let settings)) = prepared.log.records[0].resolution else {
            return XCTFail("The prepared Color Balance command was lost")
        }
        XCTAssertEqual(settings, engineBalance)
        XCTAssertFalse(prepared.log.isRecording)
        XCTAssertFalse(prepared.log.isReplaying)
    }

    func testApplyColorBalanceIsALayerBoundResolveFirstCommand() throws {
        let command = SemanticImageCommand.applyColorBalance(engineBalance)
        XCTAssertEqual(command.title, "Color Balance")
        XCTAssertTrue(command.requiresResolvedFloatingSelection)
        XCTAssertTrue(command.isLayerAdjustment)
        // The command needs an explicit layer binding at apply; execution
        // itself is exercised only by the native acceptance matrix.
        XCTAssertEqual(try RecorderFileCommand(.applyColorBalance(engineBalance)),
                       .applyColorBalance(fileBalance))
    }
}
