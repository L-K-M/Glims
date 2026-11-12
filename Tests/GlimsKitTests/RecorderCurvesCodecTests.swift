import XCTest
@testable import GlimsKit

/// Strict recording-format version 7 coverage: a newly applied Curves
/// adjustment on an explicitly bound layer. Every channel preserves both
/// curve representations and the HDR bypass flag.
final class RecorderCurvesCodecTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "88888888-8888-8888-8888-888888888888")!
    private let origin = RecorderFileValue.Origin(imageLabel: "A", initialWidth: 41, initialHeight: 29)
    private let layerSymbol = #"{"id":"88888888-8888-8888-8888-888888888888","description":{"name":"Curves target","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let channelSymbol = #"{"id":"88888888-8888-8888-8888-888888888888","description":{"name":"Saved alpha","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let layerBinding = #"{"kind":"layer","symbol":"88888888-8888-8888-8888-888888888888"}"#

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

    private func samples(_ fill: (Int) -> Double = { Double($0) / 255 }) -> String {
        "[" + (0..<256).map { String(fill($0)) }.joined(separator: ",") + "]"
    }
    private func pointList(_ list: [(Double, Double, String)]) -> String {
        "[" + list.map { "{\"x\":\($0.0),\"y\":\($0.1),\"kind\":\"\($0.2)\"}" }.joined(separator: ",") + "]"
    }
    private func channel(kind: String = "smooth", identity: Bool = false,
                         points: String = "[]", samples: String? = nil) -> String {
        "{\"kind\":\"\(kind)\",\"identity\":\(identity),\"points\":\(points),\"samples\":\(samples ?? self.samples())}"
    }
    private func settings(trc: String = "nonlinear", value: String? = nil, red: String? = nil,
                          green: String? = nil, blue: String? = nil, alpha: String? = nil) -> String {
        #"{"trc":""# + trc + #"","value":"# + (value ?? channel(
            kind: "smooth", points: pointList([(0, 0, "smooth"), (0.25, 0.5, "corner"), (0.25, 0.75, "smooth"), (1, 1, "corner")]),
            samples: samples { _ in 0.25 }))
            + #","red":"# + (red ?? channel(kind: "free", identity: true,
            points: pointList([(0.5, 0.5, "corner")]), samples: samples { Double($0) / 255 }))
            + #","green":"# + (green ?? channel(kind: "free",
            samples: samples { 1 - Double($0) / 255 }))
            + #","blue":"# + (blue ?? channel(kind: "smooth", identity: true,
            points: pointList([(0, 1, "smooth"), (1, 0, "smooth")]), samples: samples { _ in 0.9 }))
            + #","alpha":"# + (alpha ?? channel(kind: "smooth",
            points: pointList([(0.1, 0.2, "smooth"), (0.1, 0.8, "smooth")]), samples: samples { _ in 0.4 })) + "}"
    }
    private func command(_ settings: String? = nil) -> String {
        #"{"tag":"applyCurves","settings":"# + (settings ?? self.settings()) + "}"
    }
    private func document(_ rows: String, symbols: String = "", version: Int = 7) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Curves","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":["#
            + symbols + #"],"records":["# + rows + "]}"
    }
    private func success(_ command: String, binding: String = #"{"kind":"none"}"#, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func curvesDocument(command: String? = nil, binding: String? = nil, symbols: String? = nil, version: Int = 7) -> String {
        document(success(command ?? self.command(), binding: binding ?? layerBinding),
                 symbols: symbols ?? layerSymbol, version: version)
    }

    /// The same values as the `settings` literal, as owned file types.
    private var fileCurves: RecorderCurvesValue {
        typealias V = RecorderCurvesValue
        func point(_ x: Double, _ y: Double, _ kind: V.PointKind = .smooth) -> V.Point {
            .init(x: x, y: y, kind: kind)
        }
        return V(trc: .nonlinear,
            value: .init(kind: .smooth, identity: false,
                points: [point(0, 0), point(0.25, 0.5, .corner), point(0.25, 0.75), point(1, 1, .corner)],
                samples: Array(repeating: 0.25, count: 256)),
            red: .init(kind: .free, identity: true,
                points: [point(0.5, 0.5, .corner)],
                samples: (0..<256).map { Double($0) / 255 }),
            green: .init(kind: .free, identity: false, points: [],
                samples: (0..<256).map { 1 - Double($0) / 255 }),
            blue: .init(kind: .smooth, identity: true,
                points: [point(0, 1), point(1, 0)],
                samples: Array(repeating: 0.9, count: 256)),
            alpha: .init(kind: .smooth, identity: false,
                points: [point(0.1, 0.2), point(0.1, 0.8)],
                samples: Array(repeating: 0.4, count: 256)))
    }

    func testVersionSevenMixedFiveChannelLiteralDecodesExactly() throws {
        let value = try RecorderFileCodec.decode(bytes(curvesDocument()))
        XCTAssertEqual(value.records.count, 1)
        XCTAssertEqual(value.symbols.count, 1)
        guard case .success(.applyCurves(let curves), .layer(let id)) = value.records[0].outcome else {
            return XCTFail("The Curves command or its layer binding was lost")
        }
        XCTAssertEqual(id, symbol)
        XCTAssertEqual(curves, fileCurves)
    }

    func testSemanticBridgeAndSnapshotCommandKeepTheWholeLiteral() throws {
        let value = try RecorderFileCodec.decode(bytes(curvesDocument()))
        let prepared = try RecorderFileSemanticBridge.prepare(value)
        guard case .success(.applyCurves(let settings)) = prepared.log.records[0].resolution else {
            return XCTFail("Curves semantic command missing")
        }
        XCTAssertEqual(try RecorderCurvesValue(settings), fileCurves)
        XCTAssertEqual(try RecorderFileCommand(.applyCurves(settings)), .applyCurves(fileCurves))
        XCTAssertTrue(SemanticImageCommand.applyCurves(settings).requiresResolvedFloatingSelection)
        XCTAssertTrue(SemanticImageCommand.applyCurves(settings).isLayerAdjustment)
        XCTAssertEqual(SemanticImageCommand.applyCurves(settings).title, "Curves")
    }

    func testEveryOwnedTRCAndKindCombinationRoundTrips() throws {
        for trc in ["linear", "nonlinear", "perceptual"] {
            for kind in ["smooth", "free"] {
                let text = curvesDocument(command: command(settings(trc: trc,
                    alpha: channel(kind: kind, identity: kind == "smooth",
                                   points: pointList([(0.4, 0.6, "corner")])))))
                let value = try RecorderFileCodec.decode(bytes(text))
                guard case .success(.applyCurves(let curves), _) = value.records[0].outcome else {
                    return XCTFail("Missing Curves command")
                }
                XCTAssertEqual(curves.trc.rawValue, trc)
                XCTAssertEqual(curves.alpha.kind.rawValue, kind)
                XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(value)), value)
            }
        }
    }

    func testApplyCurvesSelectsVersionSevenAndLowerCommandsAreRetained() throws {
        let scale = #"{"tag":"scale","width":35,"height":43}"#
        let rows = success(scale) + "," + success(command(), binding: layerBinding, ordinal: 1)
        let value = try RecorderFileCodec.decode(bytes(document(rows, symbols: layerSymbol)))
        XCTAssertEqual(value.records.count, 2)
        guard case .success(.scale(width: 35, height: 43), .none) = value.records[0].outcome,
              case .success(.applyCurves, .layer) = value.records[1].outcome else {
            return XCTFail("The lower command did not survive version 7")
        }
        let encoded = try RecorderFileCodec.encode(value)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains(#""version":7"#))
        XCTAssertTrue(text.contains(#""tag":"applyCurves""#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
    }

    func testForgedVersionsReject() {
        for version in [0, 1, 5, 6, 8, Int.max] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(curvesDocument(version: version))), "\(version)")
        }
        rejects(curvesDocument(version: 6), reason: "version 7")
        rejects(document(success(#"{"tag":"scale","width":1,"height":1}"#), version: 7),
                reason: "Version 7 requires a successful Curves command")
        // A version 7 file may still carry every earlier command family.
        let mixed = document(success(#"{"tag":"scale","width":1,"height":1}"#) + ","
            + success(command(), binding: layerBinding, ordinal: 1), symbols: layerSymbol)
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(mixed)))
    }

    func testUnknownFieldsTagsKindsAndWrongTypesReject() {
        let mutations = [
            (#""tag":"applyCurves""#, #""tag":"applyCurves","future":0"#),          // unknown command field
            (#""trc":"nonlinear""#, #""trc":"nonlinear","future":0"#),             // unknown settings field
            (#""kind":"smooth","identity":false,"points":"#, #""future":0,"kind":"smooth","identity":false,"points":"#), // unknown channel field
            (#""x":0.0,"y":0.0,"kind":"smooth""#, #""x":0.0,"y":0.0,"kind":"smooth","future":0"#), // unknown point field
            (#""trc":"nonlinear""#, #""trc":"cielab""#),                           // unknown TRC
            (#""trc":"nonlinear""#, #""trc":2"#),                                  // TRC as number
            (#""trc":"nonlinear""#, #""trc":"NonLinear""#),                        // case is significant
            (#""kind":"smooth","identity":false"#, #""kind":"cubic","identity":false"#),   // unknown channel kind
            (#""kind":"smooth","identity":false"#, #""kind":1,"identity":false"#),          // channel kind as number
            (#""kind":"corner"},{"x":0.25"#, #""kind":"bezier"},{"x":0.25"#),               // unknown point kind
            (#""identity":false"#, #""identity":0"#),                              // identity as number
            (#""identity":true"#, #""identity":"true""#),                          // identity as string
            (#""x":0.5,"y":0.5,"kind":"corner""#, #""x":"0.5","y":0.5,"kind":"corner""#), // coordinate as string
            (#""x":0.5,"y":0.5,"kind":"corner""#, #""x":null,"y":0.5,"kind":"corner""#),  // coordinate as null
            (#""trc":"nonlinear""#, #""trc":"nonlinear","trc":"linear""#),         // duplicate field
        ]
        for (old, new) in mutations {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(curvesDocument(), old, new))), old)
        }
        // A missing channel and a missing channel field both reject.
        let missingAlpha = replace(settings(), #","alpha":{"kind""#, ",\"alphaMISSING\":{\"kind\"")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(curvesDocument(command: command(missingAlpha)))))
        let missingSamples = command(settings(value: #"{"kind":"smooth","identity":false,"points":[]}"#))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(curvesDocument(command: missingSamples))))
        // A channel object is not optional or substitutable.
        let typed = command(settings(value: "5"))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(curvesDocument(command: typed))))
    }

    func testInvalidSamplesAndPointsReject() {
        for count in [0, 1, 255, 257] {
            let bad = command(settings(value: channel(samples:
                "[" + Array(repeating: "0.5", count: count).joined(separator: ",") + "]")))
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(curvesDocument(command: bad))), "\(count)")
        }
        for token in ["-0.01", "1.01", "1e309", "\"x\"", "true"] {
            var table = samples()
            table = replace(table, "0.00392156862745098", token)
            let bad = command(settings(red: channel(samples: table)))
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(curvesDocument(command: bad))), token)
        }
        for list in [
            [(-0.01, 0.5, "smooth")], [(1.01, 0.5, "smooth")], [(0.5, -0.01, "smooth")],
            [(0.5, 1.01, "smooth")], [(0.8, 0.0, "smooth"), (0.2, 1.0, "smooth")],
        ] {
            let bad = command(settings(green: channel(kind: "smooth", points: pointList(list))))
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(curvesDocument(command: bad))), "\(list)")
        }
        // The final channel is validated like every other.
        let badAlpha = command(settings(alpha: channel(kind: "smooth",
            points: pointList([(0.9, 0.1, "smooth"), (0.1, 0.9, "smooth")]))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(curvesDocument(command: badAlpha))))
    }

    func testCurvesPointsShareTheFilePointBudget() throws {
        func polygon(_ count: Int) -> String {
            let vertices = Array(repeating: #"{"x":0,"y":0}"#, count: count).joined(separator: ",")
            return "{\"tag\":\"selectionShape\",\"shape\":{\"tag\":\"polygon\",\"points\":[\(vertices)]},\"options\":{\"operation\":\"replace\",\"antialias\":false,\"feather\":0,\"cornerRadius\":0,\"threshold\":0,\"contiguous\":false,\"sampleMerged\":true}}"
        }
        func curvesWithPoints(_ count: Int) -> String {
            let vertices = Array(repeating: (0.5, 0.5, "smooth"), count: count / 5)
            let channel = channel(kind: "smooth", points: pointList(vertices))
            return command(settings(value: channel, red: channel, green: channel, blue: channel, alpha: channel))
        }
        let boundary = document(success(polygon(50_000)) + ","
            + success(curvesWithPoints(50_000), binding: layerBinding, ordinal: 1), symbols: layerSymbol)
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(boundary)))
        let over = document(success(polygon(50_000)) + ","
            + success(curvesWithPoints(50_005), binding: layerBinding, ordinal: 1), symbols: layerSymbol)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(over)))
        // A single channel can also exceed the whole remaining budget.
        let vertices = Array(repeating: (0.5, 0.5, "smooth"), count: 65_537)
        let huge = curvesDocument(command: command(settings(value: channel(kind: "smooth", points: pointList(vertices)))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(huge)))
    }

    func testExplicitLayerBindingIsMandatory() {
        rejects(curvesDocument(binding: #"{"kind":"none"}"#), reason: "binding kinds disagree")
        rejects(curvesDocument(binding: #"{"kind":"channel","symbol":"88888888-8888-8888-8888-888888888888"}"#,
                               symbols: channelSymbol), reason: "binding kinds disagree")
        rejects(curvesDocument(symbols: channelSymbol), reason: "layer description")
        let unknown = #"{"kind":"layer","symbol":"77777777-7777-7777-7777-777777777777"}"#
        rejects(curvesDocument(binding: unknown), reason: "missing symbol")
        // Every non-channel layer kind binds, like a layer transform.
        for kind in ["pixel", "group", "text", "link", "vector"] {
            let symbolJSON = #"{"id":"88888888-8888-8888-8888-888888888888","description":{"name":"T","kind":""#
                + kind + #"","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1}}}"#
            XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(curvesDocument(symbols: symbolJSON))), kind)
        }
    }

    func testEncodingRejectsInvalidCallerBuiltCurves() {
        typealias V = RecorderCurvesValue
        func value(_ curves: V, binding: RecorderBindingDescription? = nil) -> RecorderFileValue {
            let description = RecorderTargetDescription(name: "Target", kind: .pixel, ancestors: [],
                siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
            return .init(recordingID: recordingID, name: "Curves", origin: origin,
                symbols: [.init(id: symbol, description: description)],
                records: [.init(ordinal: 0, outcome: .success(.applyCurves(curves), binding ?? .layer(symbol)))])
        }
        var curves = fileCurves
        XCTAssertNoThrow(try RecorderFileCodec.encode(value(curves)))
        XCTAssertThrowsError(try RecorderFileCodec.encode(value(curves, binding: RecorderBindingDescription.none)))
        let shortSamples = V.Channel(kind: .smooth, identity: false, points: [],
                                     samples: Array(repeating: 0.5, count: 255))
        curves = V(trc: .linear, value: shortSamples, red: fileCurves.red, green: fileCurves.green,
                   blue: fileCurves.blue, alpha: fileCurves.alpha)
        XCTAssertThrowsError(try RecorderFileCodec.encode(value(curves)))
        let unordered = V.Channel(kind: .smooth, identity: false,
            points: [.init(x: 0.8, y: 0, kind: .smooth), .init(x: 0.2, y: 1, kind: .smooth)],
            samples: Array(repeating: 0.5, count: 256))
        curves = V(trc: .perceptual, value: fileCurves.value, red: fileCurves.red, green: fileCurves.green,
                   blue: fileCurves.blue, alpha: unordered)
        XCTAssertThrowsError(try RecorderFileCodec.encode(value(curves)))
        for invalid in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            let badPoint = V.Channel(kind: .free, identity: false,
                points: [.init(x: invalid, y: 0.5, kind: .corner)], samples: Array(repeating: 0.5, count: 256))
            curves = V(trc: .linear, value: fileCurves.value, red: badPoint, green: fileCurves.green,
                       blue: fileCurves.blue, alpha: fileCurves.alpha)
            XCTAssertThrowsError(try RecorderFileCodec.encode(value(curves)), "\(invalid)")
            var table = Array(repeating: 0.5, count: 256)
            table[17] = invalid
            let badSample = V.Channel(kind: .free, identity: false, points: [], samples: table)
            curves = V(trc: .linear, value: fileCurves.value, red: fileCurves.red, green: badSample,
                       blue: fileCurves.blue, alpha: fileCurves.alpha)
            XCTAssertThrowsError(try RecorderFileCodec.encode(value(curves)), "\(invalid)")
        }
        // Encoding over the shared point budget rejects before writing.
        var vertices: [V.Point] = []
        for _ in 0..<20_001 { vertices.append(.init(x: 0.5, y: 0.5, kind: .smooth)) }
        let fat = V.Channel(kind: .smooth, identity: false, points: vertices,
                            samples: Array(repeating: 0.5, count: 256))
        curves = V(trc: .linear, value: fat, red: fat, green: fat, blue: fat, alpha: fat)
        XCTAssertThrowsError(try RecorderFileCodec.encode(value(curves)))
    }

    func testDecodeFailurePreservesTheExistingCandidateAndInputBytes() throws {
        var current = try RecorderFileCodec.decode(bytes(curvesDocument()))
        let old = current
        let input = bytes(replace(curvesDocument(), #""trc":"nonlinear""#, #""trc":"future""#))
        let originalBytes = input
        do { current = try RecorderFileCodec.decode(input); XCTFail("A forged tag must reject the whole candidate") }
        catch { XCTAssertEqual(current, old); XCTAssertEqual(input, originalBytes) }
        // The decoded value does not alias the input bytes: re-decoding the
        // untouched document yields the same detached value.
        XCTAssertEqual(try RecorderFileCodec.decode(bytes(curvesDocument())), old)
    }
}
