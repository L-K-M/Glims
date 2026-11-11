import XCTest
@testable import GlimsKit

/// Strict recording-format version 5 coverage: a newly applied Levels
/// adjustment on an explicitly bound layer.
final class RecorderLevelsTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private let origin = RecorderFileValue.Origin(imageLabel: "A", initialWidth: 41, initialHeight: 29)
    private let layerSymbol = #"{"id":"66666666-6666-6666-6666-666666666666","description":{"name":"Levels target","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
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

    /// A channel literal with non-neutral endpoints, in native field order.
    private func channel(lowInput: Double = 0.1, highInput: Double = 0.9, gamma: Double = 2.2,
                         lowOutput: Double = 0.05, highOutput: Double = 0.95) -> String {
        "{\"lowInput\":\(lowInput),\"highInput\":\(highInput),\"gamma\":\(gamma),\"lowOutput\":\(lowOutput),\"highOutput\":\(highOutput)}"
    }
    private func settings(trc: String = "nonlinear", clampInput: Bool = true, clampOutput: Bool = false,
                          value: String? = nil, red: String? = nil, green: String? = nil,
                          blue: String? = nil, alpha: String? = nil) -> String {
        #"{"trc":""# + trc + #"","clampInput":"# + String(clampInput) + #","clampOutput":"# + String(clampOutput)
            + #","value":"# + (value ?? channel()) + #","red":"# + (red ?? channel(lowInput: 0.2, gamma: 0.5))
            + #","green":"# + (green ?? channel(lowInput: 0.3, gamma: 0.7))
            + #","blue":"# + (blue ?? channel(lowInput: 0.4, gamma: 1.6))
            + #","alpha":"# + (alpha ?? channel(lowInput: 0.6, gamma: 3.3)) + "}"
    }
    private func command(_ settings: String? = nil) -> String {
        #"{"tag":"applyLevels","settings":"# + (settings ?? self.settings()) + "}"
    }
    private func document(_ rows: String, symbols: String = "", version: Int = 5) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Levels","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":["#
            + symbols + #"],"records":["# + rows + "]}"
    }
    private func success(_ command: String, binding: String = #"{"kind":"none"}"#, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func levelsDocument(command: String? = nil, binding: String? = nil, symbols: String? = nil, version: Int = 5) -> String {
        document(success(command ?? self.command(), binding: binding ?? layerBinding),
                 symbols: symbols ?? layerSymbol, version: version)
    }

    /// The same values as the `settings` literal, as owned file and
    /// frontend types. Both sides carry the five named channels.
    private var fileLevels: RecorderFileCommand.Levels {
        func channel(_ lowInput: Double, _ gamma: Double) -> RecorderFileCommand.Levels.Channel {
            .init(lowInput: lowInput, highInput: 0.9, gamma: gamma, lowOutput: 0.05, highOutput: 0.95)
        }
        return .init(trc: .nonlinear, clampInput: true, clampOutput: false,
            value: channel(0.1, 2.2), red: channel(0.2, 0.5), green: channel(0.3, 0.7),
            blue: channel(0.4, 1.6), alpha: channel(0.6, 3.3))
    }
    private var engineLevels: EngineSession.LevelsSettings {
        func channel(_ lowInput: Double, _ gamma: Double) -> EngineSession.LevelsSettings.Channel {
            .init(lowInput: lowInput, highInput: 0.9, gamma: gamma, lowOutput: 0.05, highOutput: 0.95)
        }
        var settings = EngineSession.LevelsSettings()
        settings.trc = .nonlinear
        settings.clampInput = true
        settings.clampOutput = false
        settings.value = channel(0.1, 2.2)
        settings.red = channel(0.2, 0.5)
        settings.green = channel(0.3, 0.7)
        settings.blue = channel(0.4, 1.6)
        settings.alpha = channel(0.6, 3.3)
        return settings
    }

    func testVersionFiveApplyLevelsLiteralDecodes() throws {
        let value = try RecorderFileCodec.decode(bytes(levelsDocument()))
        XCTAssertEqual(value.records.count, 1)
        XCTAssertEqual(value.symbols.count, 1)
        guard case .success(.applyLevels(let levels), .layer(let id)) = value.records[0].outcome else {
            return XCTFail("The Levels command or its layer binding was lost")
        }
        XCTAssertEqual(id, symbol)
        XCTAssertEqual(levels, fileLevels)
    }

    func testEveryOwnedTRCAndClampCombinationRoundTrips() throws {
        for trc in ["linear", "nonlinear", "perceptual"] {
            for clamps in [(true, true), (false, false), (true, false), (false, true)] {
                let text = levelsDocument(command: command(settings(trc: trc, clampInput: clamps.0, clampOutput: clamps.1)))
                let value = try RecorderFileCodec.decode(bytes(text))
                guard case .success(.applyLevels(let levels), _) = value.records[0].outcome else {
                    return XCTFail("Missing Levels command")
                }
                XCTAssertEqual(levels.trc.rawValue, trc)
                XCTAssertEqual(levels.clampInput, clamps.0); XCTAssertEqual(levels.clampOutput, clamps.1)
                XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(value)), value)
            }
        }
    }

    func testEqualAndInvertedEndpointsRemainValidNativeMappings() throws {
        for endpoints in [[0.5, 0.5, 0.4, 0.4], [0.8, 0.2, 0.9, 0.1]] {
            let literal = channel(lowInput: endpoints[0], highInput: endpoints[1],
                                  lowOutput: endpoints[2], highOutput: endpoints[3])
            let value = try RecorderFileCodec.decode(bytes(levelsDocument(command: command(settings(value: literal)))))
            guard case .success(.applyLevels(let levels), _) = value.records[0].outcome else {
                return XCTFail("Equal or inverted endpoints were refused")
            }
            XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(value)), value)
            XCTAssertEqual([levels.value.lowInput, levels.value.highInput,
                            levels.value.lowOutput, levels.value.highOutput], endpoints)
        }
    }

    func testUnknownOrMissingFieldsUnknownTRCAndWrongTypesReject() {
        let mutations = [
            (#""tag":"applyLevels""#, #""tag":"applyLevels","future":0"#),        // unknown command field
            (#""clampOutput":false"#, #""clampOutput":false,"future":0"#),       // unknown settings field
            (#""lowInput":0.1"#, #""future":0,"lowInput":0.1"#),                 // unknown channel field
            (#""gamma":2.2"#, #""gamma":2.2,"gamma":3"#),                        // duplicate channel field
            (#""gamma":2.2"#, #""gamma":"2.2""#),                               // gamma as string
            (#""lowInput":0.1"#, #""lowInput":true"#),                          // endpoint as bool
            (#""clampInput":true"#, #""clampInput":1"#),                        // clamp as number
            (#""trc":"nonlinear""#, #""trc":"cielab""#),                        // unknown TRC
            (#""trc":"nonlinear""#, #""trc":2"#),                               // TRC as number
            (#""trc":"nonlinear""#, #""trc":"NonLinear""#),                     // case is significant
            (#""gamma":2.2"#, #""gamma":1e309"#),                               // nonfinite overflow
        ]
        for (old, new) in mutations {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(levelsDocument(), old, new))), old)
        }
        // A missing channel and a missing channel field both reject.
        let missingAlpha = replace(settings(), #","alpha":{"lowInput""#, ",\"alphaMISSING\":{\"lowInput\"")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(levelsDocument(command: command(missingAlpha)))))
        let missingField = command(settings(value: #"{"lowInput":0.1,"highInput":0.9,"lowOutput":0.05,"highOutput":0.95}"#))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(levelsDocument(command: missingField))))
        // A channel object is not optional or substitutable.
        let typed = command(settings(value: "5"))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(levelsDocument(command: typed))))
    }

    func testOutOfRangeEndpointsAndGammaReject() {
        for channel in [channel(lowInput: -0.01), channel(lowInput: 1.01), channel(highInput: -0.5),
                        channel(lowOutput: 2), channel(highOutput: -1), channel(gamma: 0),
                        channel(gamma: 0.099), channel(gamma: 10.1), channel(gamma: -2)] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(
                bytes(levelsDocument(command: command(settings(value: channel))))), channel)
        }
        // The closed gamma bounds themselves remain valid.
        for gamma in [0.1, 10] {
            XCTAssertNoThrow(try RecorderFileCodec.decode(
                bytes(levelsDocument(command: command(settings(value: channel(gamma: gamma)))))))
        }
        for endpoint in [0.0, 1.0] {
            XCTAssertNoThrow(try RecorderFileCodec.decode(
                bytes(levelsDocument(command: command(settings(value: channel(lowInput: endpoint)))))))
        }
    }

    func testVersionFiveAnchorAndPreVersionFiveRejection() {
        rejects(levelsDocument(version: 4), reason: "version 5")
        rejects(levelsDocument(version: 1), reason: "version 5")
        rejects(levelsDocument(version: 6), reason: "Version 6 requires a successful projective")
        rejects(document(success(#"{"tag":"scale","width":1,"height":1}"#), version: 5),
                reason: "Version 5 requires a successful Levels command")
        // A version 5 file may still carry the earlier command families.
        let mixed = document(success(#"{"tag":"scale","width":1,"height":1}"#) + ","
            + success(command(), binding: layerBinding, ordinal: 1), symbols: layerSymbol)
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(mixed)))
    }

    func testExplicitLayerBindingIsMandatory() {
        rejects(levelsDocument(binding: #"{"kind":"none"}"#), reason: "binding kinds disagree")
        rejects(levelsDocument(binding: #"{"kind":"channel","symbol":"66666666-6666-6666-6666-666666666666"}"#,
                             symbols: channelSymbol), reason: "binding kinds disagree")
        rejects(levelsDocument(symbols: channelSymbol), reason: "layer description")
        let unknown = #"{"kind":"layer","symbol":"77777777-7777-7777-7777-777777777777"}"#
        rejects(levelsDocument(binding: unknown), reason: "missing symbol")
        // Every non-channel layer kind binds, like a layer transform.
        for kind in ["pixel", "group", "text", "link", "vector"] {
            let symbolJSON = #"{"id":"66666666-6666-6666-6666-666666666666","description":{"name":"T","kind":""#
                + kind + #"","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1}}}"#
            XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(levelsDocument(symbols: symbolJSON))), kind)
        }
    }

    func testApplyLevelsSelectsVersionFiveAcrossMixedCommands() throws {
        let transform = #"{"tag":"transformLayer","matrix":{"a":0.5,"b":0.25,"c":-0.75,"d":1.25,"tx":-4.5,"ty":8},"interpolation":"loHalo"}"#
        let rows = success(command(), binding: layerBinding) + "," + success(transform, binding: layerBinding, ordinal: 1)
        let value = try RecorderFileCodec.decode(bytes(document(rows, symbols: layerSymbol)))
        let encoded = try RecorderFileCodec.encode(value)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains(#""version":5"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
    }

    func testEncodingRejectsInvalidCallerBuiltLevels() {
        func value(_ levels: RecorderFileCommand.Levels,
                   binding: RecorderBindingDescription? = nil) -> RecorderFileValue {
            let description = RecorderTargetDescription(name: "Target", kind: .pixel, ancestors: [],
                siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
            return .init(recordingID: recordingID, name: "Levels", origin: origin,
                symbols: [.init(id: symbol, description: description)],
                records: [.init(ordinal: 0, outcome: .success(.applyLevels(levels), binding ?? .layer(symbol)))])
        }
        var levels = fileLevels
        XCTAssertNoThrow(try RecorderFileCodec.encode(value(levels)))
        XCTAssertThrowsError(try RecorderFileCodec.encode(value(levels, binding: RecorderBindingDescription.none)))
        let badGamma = RecorderFileCommand.Levels.Channel(lowInput: 0, highInput: 1, gamma: 0.01, lowOutput: 0, highOutput: 1)
        levels = RecorderFileCommand.Levels(trc: .linear, clampInput: false, clampOutput: false,
            value: badGamma, red: badGamma, green: badGamma, blue: badGamma, alpha: badGamma)
        XCTAssertThrowsError(try RecorderFileCodec.encode(value(levels)))
        let badEndpoint = RecorderFileCommand.Levels.Channel(lowInput: 0, highInput: 1, gamma: 1, lowOutput: 0, highOutput: 1.5)
        levels = RecorderFileCommand.Levels(trc: .perceptual, clampInput: true, clampOutput: true,
            value: badEndpoint, red: badEndpoint, green: badEndpoint, blue: badEndpoint, alpha: badEndpoint)
        XCTAssertThrowsError(try RecorderFileCodec.encode(value(levels)))
        for invalid in [Double.nan, .infinity, -.infinity] {
            let nonfinite = RecorderFileCommand.Levels.Channel(lowInput: invalid, highInput: 1, gamma: 1,
                                                               lowOutput: 0, highOutput: 1)
            levels = .init(trc: .linear, clampInput: false, clampOutput: false,
                value: nonfinite, red: fileLevels.red, green: fileLevels.green,
                blue: fileLevels.blue, alpha: fileLevels.alpha)
            XCTAssertThrowsError(try RecorderFileCodec.encode(value(levels)))
        }
    }

    func testRecordedLevelsSnapshotsAsVersionFiveWithExplicitLayerSymbol() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.applyLevels(engineLevels)))
        try log.stopRecording()
        let description = RecorderTargetDescription(name: "Levels target", kind: .pixel, ancestors: [],
            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description)])
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Levels",
                                                      origin: origin, descriptions: catalog, bindings: [0: .layer(symbol)])
        guard case .success(.applyLevels(let levels), .layer(let id)) = snapshot.records[0].outcome else {
            return XCTFail("The recorded Levels or its explicit layer binding was lost")
        }
        XCTAssertEqual(levels, fileLevels)
        XCTAssertEqual(id, symbol)
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":5"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), snapshot)
    }

    func testLevelsWithoutCapturedBindingNeverSnapshots() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.applyLevels(engineLevels)))
        try log.stopRecording()
        func snapshot(_ bindings: [Int: RecorderBindingDescription]) throws -> RecorderFileValue {
            try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Levels",
                                           origin: origin, descriptions: .init(), bindings: bindings)
        }
        XCTAssertThrowsError(try snapshot([:]))
        XCTAssertThrowsError(try snapshot([0: .none]))
        XCTAssertThrowsError(try snapshot([0: .unavailable("Capture failed")]))
        XCTAssertThrowsError(try snapshot([0: .channel(symbol)]))
    }

    func testPreparedLiteralRestoresTheExactFrontendSettings() throws {
        let prepared = try RecorderFileSemanticBridge.prepare(try RecorderFileCodec.decode(bytes(levelsDocument())))
        XCTAssertEqual(prepared.log.records.count, 1)
        guard case .success(.applyLevels(let settings)) = prepared.log.records[0].resolution else {
            return XCTFail("The prepared Levels command was lost")
        }
        XCTAssertEqual(settings, engineLevels)
        XCTAssertFalse(prepared.log.isRecording)
        XCTAssertFalse(prepared.log.isReplaying)
    }

    func testApplyLevelsIsALayerBoundResolveFirstCommand() {
        let command = SemanticImageCommand.applyLevels(engineLevels)
        XCTAssertEqual(command.title, "Levels")
        XCTAssertTrue(command.requiresResolvedFloatingSelection)
        // The command needs an explicit layer binding at apply; the engine
        // free contract cannot fabricate a session, so execution itself is
        // exercised only by the native acceptance matrix.
    }
}
