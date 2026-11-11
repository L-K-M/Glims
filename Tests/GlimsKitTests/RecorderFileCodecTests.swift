import XCTest
import CoreGraphics
@testable import GlimsKit

final class RecorderFileCodecTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let origin = RecorderFileValue.Origin(imageLabel: "A", initialWidth: 41, initialHeight: 29)
    private let options = #"{"operation":"intersect","antialias":false,"feather":-2.5,"cornerRadius":0,"threshold":1.5,"contiguous":false,"sampleMerged":true}"#
    private let symbolJSON = #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Original组","kind":"group","ancestors":[{"name":"Root","kind":"group","siblingIndex":0}],"siblingIndex":1,"bounds":{"x":-4,"y":7,"width":41,"height":29}}}"#

    /// Authored JSON values, not produced by the codec or native command apply.
    private var allFamilies: String {
        let rows = #"""
        {"ordinal":0,"outcome":"success","command":{"tag":"selectionShape","shape":{"tag":"polygon","points":[{"x":-4,"y":0.5},{"x":8.25,"y":2},{"x":2,"y":10}]},"options":OPTIONS},"binding":{"kind":"none"}},
        {"ordinal":1,"outcome":"success","command":{"tag":"selectColor","point":{"x":-1.5,"y":9.75},"options":OPTIONS},"binding":{"kind":"none"}},
        {"ordinal":2,"outcome":"success","command":{"tag":"selectCommand","command":"invert","radius":0},"binding":{"kind":"none"}},
        {"ordinal":3,"outcome":"success","command":{"tag":"transformImage","transform":"flipVertical"},"binding":{"kind":"none"}},
        {"ordinal":4,"outcome":"success","command":{"tag":"scale","width":35,"height":43},"binding":{"kind":"none"}},
        {"ordinal":5,"outcome":"success","command":{"tag":"resizeCanvas","width":45,"height":49,"offset":{"x":-4.75,"y":0},"fill":{"space":"srgb","red":0.2,"green":0.35,"blue":0.6,"alpha":0.8}},"binding":{"kind":"none"}},
        {"ordinal":6,"outcome":"success","command":{"tag":"crop","rect":{"x":-2.25,"y":1.5,"width":40.25,"height":45}},"binding":{"kind":"none"}},
        {"ordinal":7,"outcome":"success","command":{"tag":"layerProperties","properties":{"name":"","visible":false,"opacity":0,"mode":"pass-through"}},"binding":{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}},
        {"ordinal":8,"outcome":"failure","reason":"Engine refused\nunchanged"},
        {"ordinal":9,"outcome":"cancelled","reason":""}
        """#
        return document(rows.replacingOccurrences(of: "OPTIONS", with: options), symbols: symbolJSON, name: "Eight families")
    }
    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func replace(_ text: String, _ before: String, _ after: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let range = text.range(of: before) else { XCTFail("Fixture mutation did not match: \(before)", file: file, line: line); return text }
        return text.replacingCharacters(in: range, with: after)
    }
    private func document(_ rows: String, symbols: String = "", name: String = "Named") -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":1,"recordingID":"11111111-1111-1111-1111-111111111111","name":""# + name + #"","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":["# + symbols + #"],"records":["# + rows + "]}"
    }
    private func success(_ command: String, binding: String = #"{"kind":"none"}"#, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func rejects(_ text: String, reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(text)), file: file, line: line) {
            XCTAssertTrue($0.localizedDescription.contains(reason), $0.localizedDescription, file: file, line: line)
        }
    }

    private let transformSymbolJSON = #"{"id":"55555555-5555-5555-5555-555555555555","description":{"name":"Transform me","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":-4,"y":7,"width":41,"height":29}}}"#
    private let transformBinding = #"{"kind":"layer","symbol":"55555555-5555-5555-5555-555555555555"}"#
    private let transformCommand = #"{"tag":"transformLayer","matrix":{"a":0.5,"b":0.25,"c":-0.75,"d":1.25,"tx":-4.5,"ty":8},"interpolation":"loHalo"}"#
    private func transformDocument(_ command: String? = nil, binding: String? = nil, symbols: String? = nil, version: Int = 4) -> String {
        let text = document(success(command ?? transformCommand, binding: binding ?? transformBinding),
                            symbols: symbols ?? transformSymbolJSON)
        return text.replacingOccurrences(of: "\"version\":1", with: "\"version\":\(version)")
    }

    func testIndependentLiteralHasEveryFamilyAndBothUnsuccessfulOutcomes() throws {
        let value = try RecorderFileCodec.decode(bytes(allFamilies))
        XCTAssertEqual(value.recordingID, recordingID)
        XCTAssertEqual(value.name, "Eight families")
        XCTAssertEqual(value.origin, origin)
        XCTAssertEqual(value.records.count, 10)
        XCTAssertEqual(value.symbols.first?.description.name, "Original组")
        XCTAssertEqual(value.symbols.first?.description.ancestors.first?.name, "Root")
        guard case .success(.selectionShape(.polygon(let points), let firstOptions), .none) = value.records[0].outcome,
              case .success(.selectColor(let point, let colorOptions), .none) = value.records[1].outcome,
              case .success(.selectCommand(.invert, radius: 0), .none) = value.records[2].outcome,
              case .success(.transformImage(.flipVertical), .none) = value.records[3].outcome,
              case .success(.scale(width: 35, height: 43), .none) = value.records[4].outcome,
              case .success(.resizeCanvas(width: 45, height: 49, let offset, let fill), .none) = value.records[5].outcome,
              case .success(.crop(let rect), .none) = value.records[6].outcome,
              case .success(.layerProperties(let properties), .layer(let id)) = value.records[7].outcome else {
            return XCTFail("Literal commands did not retain their typed values")
        }
        XCTAssertEqual(points, [.init(x: -4, y: 0.5), .init(x: 8.25, y: 2), .init(x: 2, y: 10)])
        XCTAssertEqual(firstOptions, .init(operation: .intersect, antialias: false, feather: -2.5, cornerRadius: 0,
                                         threshold: 1.5, contiguous: false, sampleMerged: true))
        XCTAssertEqual(point, .init(x: -1.5, y: 9.75)); XCTAssertEqual(colorOptions, firstOptions)
        XCTAssertEqual(offset, .init(x: -4.75, y: 0))
        XCTAssertEqual([fill.red, fill.green, fill.blue, fill.alpha], [0.2, 0.35, 0.6, 0.8])
        XCTAssertEqual(rect, .init(x: -2.25, y: 1.5, width: 40.25, height: 45))
        XCTAssertEqual(properties.name, ""); XCTAssertEqual(properties.visible, false)
        XCTAssertEqual(properties.opacity, 0); XCTAssertEqual(properties.mode?.name, "pass-through"); XCTAssertEqual(id, symbol)
        XCTAssertEqual(value.records[8].outcome, .failure("Engine refused\nunchanged"))
        XCTAssertEqual(value.records[9].outcome, .cancelled(""))
    }

    func testEncoderHasIndependentCanonicalBytes() throws {
        let value = RecorderFileValue(recordingID: recordingID, name: "Named", origin: origin, symbols: [],
            records: [.init(ordinal: 0, outcome: .success(.scale(width: 1, height: 1), .none))])
        let expected = #"{"format":"ch.lkmc.Glims.recording","name":"Named","origin":{"imageLabel":"A","initialHeight":29,"initialWidth":41},"recordingID":"11111111-1111-1111-1111-111111111111","records":[{"binding":{"kind":"none"},"command":{"height":1,"tag":"scale","width":1},"ordinal":0,"outcome":"success"}],"symbols":[],"version":1}"#
        XCTAssertEqual(try RecorderFileCodec.encode(value), bytes(expected))
    }

    func testUnknownKeysAtEveryCommonObjectBoundaryRejectWholeFile() {
        let mutations = [
            (#""version":1"#, #""version":1,"future":0"#),
            (#""initialHeight":29"#, #""initialHeight":29,"future":0"#),
            (#""id":"22222222-2222-2222-2222-222222222222""#, #""future":0,"id":"22222222-2222-2222-2222-222222222222""#),
            (#""name":"Original组""#, #""future":0,"name":"Original组""#),
            (#""name":"Root""#, #""future":0,"name":"Root""#),
            (#""width":41,"height":29"#, #""future":0,"width":41,"height":29"#),
            (#""ordinal":0"#, #""ordinal":0,"future":0"#),
            (#""tag":"selectionShape""#, #""future":0,"tag":"selectionShape""#),
            (#""tag":"polygon""#, #""future":0,"tag":"polygon""#),
            (#""x":-4,"y":0.5"#, #""future":0,"x":-4,"y":0.5"#),
            (#""operation":"intersect""#, #""future":0,"operation":"intersect""#),
            (#""kind":"none""#, #""future":0,"kind":"none""#),
            (#""space":"srgb""#, #""future":0,"space":"srgb""#),
            (#""properties":{"name":"""#, #""properties":{"future":0,"name":"""#),
        ]
        for (old, new) in mutations { XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(allFamilies, old, new))), old) }
    }

    func testDuplicateDecodedKeysAndMalformedLexicalInputReject() {
        let duplicates = [
            (#""version":1"#, #""version":1,"version":1"#),
            (#""red":0.2"#, #""red":0.2,"\u0072ed":0.3"#),
            (#""operation":"intersect""#, #""operation":"intersect","operation":"replace""#),
        ]
        for (old, new) in duplicates { XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(allFamilies, old, new)))) }
        for token in ["NaN", "Infinity", "-Infinity", "01", "-01", "+1", ".1", "1.", "1e", "1e309", "1e-400", String(repeating: "1", count: 129)] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(allFamilies, #""red":0.2"#, "\"red\":\(token)"))), token)
        }
        for name in [#"\ud800"#, #"\udc00"#, #"\ud800\u0041"#, #"\x41"#, "unescaped\ncontrol"] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(allFamilies, "Eight families", name))))
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data([0xC3, 0x28])))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(allFamilies + "{}")))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(String(allFamilies.dropLast()))))
    }

    func testWrongTypesFutureTagsInvalidReferencesAndOrdinalsReject() {
        let mutations = [
            (#""version":1"#, #""version":2"#), (#""version":1"#, #""version":"1""#),
            (#""recordingID":"11111111-1111-1111-1111-111111111111""#, #""recordingID":"{11111111-1111-1111-1111-111111111111}""#),
            (#""width":35"#, #""width":35.0"#), (#""width":35"#, #""width":true"#),
            (#""visible":false"#, #""visible":0"#), (#""opacity":0"#, #""opacity":false"#),
            (#""name":"","visible""#, #""name":null,"visible""#),
            (#""tag":"crop""#, #""tag":"futureStroke""#), (#""transform":"flipVertical""#, #""transform":5"#),
            (#""operation":"intersect""#, #""operation":"futureOperation""#),
            (#""tag":"polygon""#, #""tag":"futureShape""#),
            (#""command":"invert""#, #""command":"futureSelection""#),
            (#""kind":"group","ancestors""#, #""kind":"futureLayer","ancestors""#),
            (#""mode":"pass-through""#, #""mode":"behind""#), (#""space":"srgb""#, #""space":"displayP3""#),
            (#""alpha":0.8"#, #""alpha":1.01"#), (#""ordinal":1"#, #""ordinal":0"#),
            (#""outcome":"failure""#, #""outcome":"pending""#),
            (#""kind":"none""#, #""kind":"unavailable""#),
            (#""symbol":"22222222-2222-2222-2222-222222222222""#, #""symbol":222"#),
            (#""symbol":"22222222-2222-2222-2222-222222222222""#, #""symbol":"33333333-3333-3333-3333-333333333333""#),
            (#""kind":"group","ancestors""#, #""kind":"channel","ancestors""#),
        ]
        for (old, new) in mutations { XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(allFamilies, old, new))), old) }
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(allFamilies, #""symbols":["#, #""symbols":["# + symbolJSON + ","))))
    }

    func testUnicodeAndZeroOffCanvasValuesAreNotNormalized() throws {
        let unicode = try RecorderFileCodec.decode(bytes(document("", name: #"e\u0301\ud83d\ude00"#)))
        XCTAssertEqual(Array(unicode.name.utf8), [101, 204, 129, 240, 159, 152, 128])
        let shapes = ["rectangle", "ellipse"]
        for shape in shapes {
            let command = "{\"tag\":\"selectionShape\",\"shape\":{\"tag\":\"\(shape)\",\"rect\":{\"x\":-1.5,\"y\":0.5,\"width\":0,\"height\":0}},\"options\":\(options)}"
            let value = try RecorderFileCodec.decode(bytes(document(success(command))))
            XCTAssertEqual(value.records.count, 1)
        }
        let offset = #"{"tag":"resizeCanvas","width":1,"height":1,"offset":{"x":-2147483648.75,"y":0},"fill":{"space":"srgb","red":0,"green":0,"blue":0,"alpha":0}}"#
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(success(offset)))))
        let empty = #"{"tag":"layerProperties","properties":{}}"#
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(success(empty, binding: #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#), symbols: symbolJSON))))
        let smallGrow = #"{"tag":"selectCommand","command":"grow","radius":0.1}"#
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document(success(smallGrow)))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(success(replace(smallGrow, "0.1", "0"))))))
    }

    func testNegativeCropSizePreservesPayloadAndCoreGraphicsExtents() throws {
        let crop = CGRect(x: 9, y: 11, width: -3, height: -5)
        XCTAssertEqual(crop.size.width, -3)
        XCTAssertEqual(crop.size.height, -5)
        XCTAssertEqual([crop.minX, crop.minY, crop.width, crop.height], [6, 6, 3, 5])
        let literal = document(success(#"{"tag":"crop","rect":{"x":9,"y":11,"width":-3,"height":-5}}"#))
        let expected = try RecorderFileCodec.decode(bytes(literal))
        guard case .success(.crop(let rectangle), .none) = expected.records[0].outcome else {
            return XCTFail("Negative crop payload was lost")
        }
        XCTAssertEqual(rectangle, .init(x: 9, y: 11, width: -3, height: -5))

        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.crop(crop)))
        try log.stopRecording()
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Named", origin: origin,
                                                       descriptions: .init(), bindings: [:])
        XCTAssertEqual(snapshot, expected)
        XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(snapshot)), expected)
    }

    func testLayerTransformKeepsExactCoefficientsAndNamedInterpolation() throws {
        let value = try RecorderFileCodec.decode(bytes(transformDocument()))
        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
        // The codec must not renumber, reorder or drop the six exact
        // coefficients or the owned interpolation tag on re-export.
        let text = String(decoding: encoded, as: UTF8.self)
        for fragment in [#""a":0.5"#, #""b":0.25"#, #""c":-0.75"#, #""d":1.25"#, #""tx":-4.5"#, #""ty":8"#,
                         #""interpolation":"loHalo""#, #""version":4"#] {
            XCTAssertTrue(text.contains(fragment), fragment)
        }
    }

    func testLayerTransformRejectsWrongVersionMissingVersionAnchorAndEveryUnsafeMatrix() {
        rejects(transformDocument(version: 3), reason: "version 4")
        rejects(transformDocument(#"{"tag":"scale","width":1,"height":1}"#, binding: #"{"kind":"none"}"#),
                reason: "Version 4 requires a successful layer transform")
        let degenerate = #"{"a":1,"b":1,"c":1,"d":1,"tx":0,"ty":0}"#
        let overflowing = #"{"a":1e308,"b":0,"c":0,"d":1e308,"tx":0,"ty":0}"#
        let identity = #"{"a":1,"b":0,"c":0,"d":1,"tx":0,"ty":0}"#
        for matrix in [degenerate, overflowing] {
            let command = #"{"tag":"transformLayer","matrix":"# + matrix + #","interpolation":"cubic"}"#
            rejects(transformDocument(command), reason: "matrix")
        }
        rejects(transformDocument(#"{"tag":"transformLayer","matrix":"# + identity + #","interpolation":"cubic"}"#),
                reason: "identity")
        let underThreshold = #"{"a":1e-10,"b":0,"c":0,"d":1,"tx":0,"ty":0}"#
        rejects(transformDocument(#"{"tag":"transformLayer","matrix":"# + underThreshold + #","interpolation":"cubic"}"#), reason: "matrix")
    }

    func testRecordedLayerTransformSnapshotsAsVersion4WithExplicitLayerSymbol() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.transformLayer(
            matrix: CGAffineTransform(a: 0.5, b: 0.25, c: -0.75, d: 1.25, tx: -4.5, ty: 8),
            interpolation: .loHalo)))
        try log.stopRecording()
        let symbol = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let description = RecorderTargetDescription(name: "Transform me", kind: .pixel, ancestors: [],
            siblingIndex: 0, bounds: .init(x: -4, y: 7, width: 41, height: 29))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description)])
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Named",
                                                      origin: origin, descriptions: catalog, bindings: [0: .layer(symbol)])
        guard case .success(.transformLayer(let matrix, let interpolation), .layer(let id)) = snapshot.records[0].outcome else {
            return XCTFail("The recorded transform or its explicit layer binding was lost")
        }
        XCTAssertEqual(matrix, .init(a: 0.5, b: 0.25, c: -0.75, d: 1.25, tx: -4.5, ty: 8))
        XCTAssertEqual(interpolation, .loHalo)
        XCTAssertEqual(id, symbol)
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":4"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), snapshot)
    }

    func testLayerTransformWithoutCapturedBindingNeverSnapshots() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.transformLayer(matrix: CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 0, ty: 0),
                                                            interpolation: .linear)))
        try log.stopRecording()
        XCTAssertThrowsError(try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Named",
                                                          origin: origin, descriptions: .init(), bindings: [:]))
    }

    func testLayerTransformRejectsUnknownFieldsValuesAndForeignBindings() {
        let mutations = [
            (#""a":0.5"#, #""a":0.5,"future":0"#),
            (#","ty":8"#, ""), // missing member
            (#""interpolation":"loHalo""#, #""interpolation":"bilinear""#),
            (#""interpolation":"loHalo""#, #""interpolation":2"#),
            (#""matrix":{"a""#, #""future":0,"matrix":{"a""#),
            (#""kind":"layer","symbol":"55555555-5555-5555-5555-555555555555""#, #""kind":"none""#),
            (#""kind":"layer","symbol":"55555555-5555-5555-5555-555555555555""#, #""kind":"channel","symbol":"55555555-5555-5555-5555-555555555555""#),
            (#""kind":"pixel","ancestors""#, #""kind":"channel","ancestors""#),
            (#""kind":"pixel","ancestors""#, #""kind":"quickMask","ancestors""#),
        ]
        for (old, new) in mutations {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(transformDocument(), old, new))), old)
        }
    }

    func testEveryResourcePolicyLimitIsEnforced() throws {
        rejects(String(repeating: " ", count: RecorderFileLimits.bytes + 1), reason: "16 MiB")
        XCTAssertNoThrow(try RecorderFileCodec.decode(bytes(document("", name: String(repeating: "é", count: RecorderFileLimits.stringBytes / 2)))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document("", name: String(repeating: "é", count: RecorderFileLimits.stringBytes / 2 + 1)))))
        let deep = String(repeating: "[", count: 66) + "0" + String(repeating: "]", count: 66)
        rejects(deep, reason: "nesting exceeds 64")
        let manyValues = "[" + Array(repeating: "0", count: RecorderFileLimits.values).joined(separator: ",") + "]"
        rejects(manyValues, reason: "Too many JSON values")
        let rows = (0...RecorderFileLimits.records).map { "{\"ordinal\":\($0),\"outcome\":\"failure\",\"reason\":\"\"}" }.joined(separator: ",")
        rejects(document(rows), reason: "oversized array")
        rejects(document("", symbols: Array(repeating: symbolJSON, count: RecorderFileLimits.symbols + 1).joined(separator: ",")), reason: "oversized array")
        let points = Array(repeating: #"{"x":0,"y":0}"#, count: RecorderFileLimits.points + 1).joined(separator: ",")
        let polygon = "{\"tag\":\"selectionShape\",\"shape\":{\"tag\":\"polygon\",\"points\":[\(points)]},\"options\":\(options)}"
        rejects(document(success(polygon)), reason: "oversized array")
    }

    func testPolygonBudgetIsSharedAcrossRecords() throws {
        func polygon(_ count: Int) -> String {
            let points = Array(repeating: #"{"x":0,"y":0}"#, count: count).joined(separator: ",")
            return "{\"tag\":\"selectionShape\",\"shape\":{\"tag\":\"polygon\",\"points\":[\(points)]},\"options\":\(options)}"
        }
        let first = success(polygon(50_000))
        let boundary = document(first + "," + success(polygon(50_000), ordinal: 1))
        XCTAssertEqual(try RecorderFileCodec.decode(bytes(boundary)).records.count, 2)
        rejects(document(first + "," + success(polygon(50_001), ordinal: 1)), reason: "Invalid polygon point count")
    }

    func testDecodeFailurePreservesTheExistingCandidateAndInputBytes() throws {
        var current = try RecorderFileCodec.decode(bytes(allFamilies))
        let old = current
        let input = bytes(replace(allFamilies, #""tag":"crop""#, #""tag":"futureCommand""#))
        let originalBytes = input
        do { current = try RecorderFileCodec.decode(input); XCTFail("Future command must reject the whole candidate") }
        catch { XCTAssertEqual(current, old); XCTAssertEqual(input, originalBytes) }
    }

    func testSnapshotBridgeMatchesIndependentAllFamilyLiteral() throws {
        var settings = EngineSession.SelectOptions()
        settings.operation = .intersect; settings.antialias = false; settings.feather = -2.5
        settings.cornerRadius = 0; settings.threshold = 1.5; settings.contiguous = false; settings.sampleMerged = true
        let commands: [SemanticImageCommand] = [
            .selectionShape(.polygon([CGPoint(x: -4, y: 0.5), CGPoint(x: 8.25, y: 2), CGPoint(x: 2, y: 10)]), options: settings),
            .selectColor(CGPoint(x: -1.5, y: 9.75), options: settings), .selectCommand(.invert, radius: 0), .transformImage(.flipVertical),
            .scale(width: 35, height: 43), .resizeCanvas(width: 45, height: 49, offset: CGPoint(x: -4.75, y: 0),
                fill: try RecorderColor(red: 0.2, green: 0.35, blue: 0.6, alpha: 0.8)),
            .crop(CGRect(x: -2.25, y: 1.5, width: 40.25, height: 45)),
            .layerProperties(.init(.init(name: "", isVisible: false, opacity: 0, mode: "pass-through"))),
        ]
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        for command in commands { let token = try log.reserve(); try log.resolve(token, with: .success(command)) }
        let failure = try log.reserve(); try log.resolve(failure, with: .failure("Engine refused\nunchanged"))
        let cancelled = try log.reserve(); try log.resolve(cancelled, with: .cancelled(""))
        try log.stopRecording()
        let original = RecorderTargetDescription(name: "Original组", kind: .group, ancestors: [.init(name: "Root", kind: .group, siblingIndex: 0)],
            siblingIndex: 1, bounds: .init(x: -4, y: 7, width: 41, height: 29))
        var catalog = RecorderDescriptionCatalog(); catalog.acceptFirst([symbol: .available(original)])
        let result = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Eight families", origin: origin,
            descriptions: catalog, bindings: [7: .layer(symbol)])
        XCTAssertEqual(result, try RecorderFileCodec.decode(bytes(allFamilies)))
        XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(result)), result)
        XCTAssertEqual(log.records.count, 10)
    }

    func testSnapshotRefusesUnsettledRecordingAndReplay() throws {
        func snapshot(_ log: RecorderLog<SemanticImageCommand>) throws -> RecorderFileValue {
            try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Named", origin: origin, descriptions: .init(), bindings: [:])
        }
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        XCTAssertThrowsError(try snapshot(log))
        let token = try log.reserve(); try log.stopRecording()
        XCTAssertThrowsError(try snapshot(log))
        try log.resolve(token, with: .success(.scale(width: 1, height: 1)))
        XCTAssertNoThrow(try snapshot(log))
        try log.beginReplay()
        XCTAssertThrowsError(try snapshot(log))
    }

    func testSnapshotMissingOrUnavailableTargetNeverReturnsASuccessfulPrefix() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let first = try log.reserve(); try log.resolve(first, with: .success(.scale(width: 1, height: 1)))
        let second = try log.reserve(); try log.resolve(second, with: .success(.layerProperties(.init(.init(opacity: 0)))))
        try log.stopRecording()
        func snapshot(_ catalog: RecorderDescriptionCatalog, _ bindings: [Int: RecorderBindingDescription]) throws -> RecorderFileValue {
            try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Named", origin: origin, descriptions: catalog, bindings: bindings)
        }
        XCTAssertThrowsError(try snapshot(.init(), [:]))
        XCTAssertThrowsError(try snapshot(.init(), [1: .unavailable("Original target missing")]))
        var catalog = RecorderDescriptionCatalog(); catalog.acceptFirst([symbol: .unavailable("Missing at capture")])
        XCTAssertThrowsError(try snapshot(catalog, [1: .layer(symbol)]))
        XCTAssertEqual(log.records.count, 2)
        XCTAssertEqual(log.pendingCount, 0)
    }

    func testEncodingRejectsInvalidCallerValuesAndOwnedModeCatalogIsExplicit() throws {
        let invalid = RecorderFileValue(recordingID: recordingID, name: "Named", origin: origin, symbols: [],
            records: [.init(ordinal: 0, outcome: .success(.crop(.init(x: .nan, y: 0, width: 0, height: 0)), .none))])
        XCTAssertThrowsError(try RecorderFileCodec.encode(invalid))
        let settings = RecorderFileCommand.Options(operation: .replace, antialias: true, feather: 0, cornerRadius: 0,
                                                   threshold: 0, contiguous: true, sampleMerged: true)
        let points = Array(repeating: RecorderFileCommand.Point(x: 0, y: 0), count: RecorderFileLimits.points + 1)
        let oversized = RecorderFileValue(recordingID: recordingID, name: "Named", origin: origin, symbols: [],
            records: [.init(ordinal: 0, outcome: .success(.selectionShape(.polygon(points), settings), .none))])
        XCTAssertThrowsError(try RecorderFileCodec.encode(oversized)) {
            XCTAssertTrue($0.localizedDescription.contains("Invalid polygon point count"))
        }
        XCTAssertEqual(RecorderFileLayerMode.names.count, 59)
        for mode in ["normal-legacy", "overlay-legacy", "color-erase", "erase", "merge", "split", "pass-through"] { XCTAssertNoThrow(try RecorderFileLayerMode(mode)) }
        for mode in ["behind", "behind-legacy", "replace", "overwrite", "anti-erase", "future-mode", "NORMAL"] { XCTAssertThrowsError(try RecorderFileLayerMode(mode)) }
    }

    private let strokeBatches = #"[[{"pressure":0.0,"timeMilliseconds":0,"x":0.0,"xTilt":0.0,"y":1.0,"yTilt":-0.5},{"pressure":1.0,"timeMilliseconds":7,"x":2.25,"xTilt":0.5,"y":4.0,"yTilt":0.0}],[{"pressure":0.25,"timeMilliseconds":7,"x":3.0,"xTilt":-0.5,"y":5.0,"yTilt":1.0}]]"#
    private var strokeJSON: String {
        #"{"batches":"# + strokeBatches + #","facts":{"brush":{"collection":"","isInternal":false,"name":"Stock brush"},"fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"first":{"pressure":0.75,"timeMilliseconds":4294967295,"x":-1.5,"xTilt":-1.0,"y":3.5,"yTilt":0.5},"settings":{"antiErase":true,"blue":0.6,"green":0.4,"hardness":0.25,"opacity":0.75,"pressureSize":false,"red":0.2,"size":8.5,"tool":"eraser"},"tag":"completeStroke"}"#
    }
    private var strokeSymbol: String {
        #"{"description":{"ancestors":[],"bounds":{"height":29.0,"width":41.0,"x":0.0,"y":0.0},"kind":"pixel","name":"Original pixel layer","siblingIndex":0},"id":"22222222-2222-2222-2222-222222222222"}"#
    }
    private let strokeBinding = #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#
    private func strokeDocument(_ command: String, binding: String? = nil, version: Int = 2) -> String {
        let source = document(success(command, binding: binding ?? strokeBinding), symbols: strokeSymbol)
        return source.replacingOccurrences(of: #""version":1"#, with: #""version":"# + String(version))
    }

    func testVersionTwoStrokeLiteralHasCanonicalBytesAndExactSemanticBatches() throws {
        let decoded = try RecorderFileCodec.decode(bytes(strokeDocument(strokeJSON)))
        guard case .success(.completeStroke(let stroke), .layer(let id)) = decoded.records.first?.outcome else {
            return XCTFail("Missing explicit complete stroke")
        }
        XCTAssertEqual(id, symbol)
        let expectedSettings = try XCTUnwrap(RecorderStrokeCommand.Settings(tool: .eraser, size: 8.5, opacity: 0.75,
            red: 0.2, green: 0.4, blue: 0.6, hardness: 0.25, pressureSize: false, antiErase: true))
        XCTAssertEqual(stroke.settings, expectedSettings)
        XCTAssertEqual(stroke.facts.brush, .init(name: "Stock brush", collection: "", isInternal: false))
        XCTAssertEqual(stroke.facts.fingerprint, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
        XCTAssertEqual(stroke.trace.first, try .init(x: -1.5, y: 3.5, pressure: 0.75, xTilt: -1, yTilt: 0.5,
                                                   timeMilliseconds: UInt32.max))
        XCTAssertEqual(stroke.trace.batches, [
            [try .init(x: 0, y: 1, pressure: 0, xTilt: 0, yTilt: -0.5, timeMilliseconds: 0),
             try .init(x: 2.25, y: 4, pressure: 1, xTilt: 0.5, yTilt: 0, timeMilliseconds: 7)],
            [try .init(x: 3, y: 5, pressure: 0.25, xTilt: -0.5, yTilt: 1, timeMilliseconds: 7)],
        ])
        let canonical = #"{"format":"ch.lkmc.Glims.recording","name":"Named","origin":{"imageLabel":"A","initialHeight":29,"initialWidth":41},"recordingID":"11111111-1111-1111-1111-111111111111","records":[{"binding":"# + strokeBinding
            + #","command":"# + strokeJSON + #","ordinal":0,"outcome":"success"}],"symbols":["# + strokeSymbol + #"],"version":2}"#
        XCTAssertEqual(try RecorderFileCodec.encode(decoded), bytes(canonical))
        XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(decoded)), decoded)
        let prepared = try RecorderFileSemanticBridge.prepare(decoded)
        XCTAssertEqual(prepared.file, decoded)
        guard case .success(.completeStroke(let semantic)) = prepared.log.records.first?.resolution else {
            return XCTFail("Missing prepared stroke")
        }
        XCTAssertEqual(semantic, stroke)
        XCTAssertFalse(prepared.log.isRecording)
        XCTAssertFalse(prepared.log.isReplaying)
    }

    func testStrokeVersionAndPixelLayerBindingAreMandatory() {
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(strokeDocument(strokeJSON, version: 1))))
        for version in [0, 3, Int.max] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(strokeDocument(strokeJSON, version: version))))
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(document(success(#"{"tag":"scale","width":1,"height":1}"#)),
                                                                        #""version":1"#, #""version":2"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(strokeDocument(strokeJSON, binding: #"{"kind":"none"}"#))))
        for kind in ["group", "text", "link", "vector", "channel", "quickMask"] {
            let wrongLayer = replace(strokeDocument(strokeJSON), #""kind":"pixel""#, #""kind":""# + kind + #"""#)
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(wrongLayer)), kind)
        }
        let missing = replace(strokeDocument(strokeJSON), #""symbol":"22222222-2222-2222-2222-222222222222""#,
                              #""symbol":"33333333-3333-3333-3333-333333333333""#)
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(missing)))
    }

    func testStrokePayloadRejectsUnknownOrInvalidFields() {
        let mutations = [
            (#""tool":"eraser""#, #""tool":"paintbrush""#),
            (#""tool":"eraser""#, #""tool":3"#),
            (#""tool":"eraser""#, #""tool":"pencil""#), // antiErase is true.
            (#""size":8.5"#, #""size":0"#), (#""size":8.5"#, #""size":10000.1"#),
            (#""opacity":0.75"#, #""opacity":1.1"#), (#""red":0.2"#, #""red":-0.1"#),
            (#""hardness":0.25"#, #""hardness":null"#), (#""hardness":0.25"#, #""hardness":1.1"#),
            (#""pressureSize":false"#, #""pressureSize":0"#),
            (#""name":"Stock brush""#, #""name":"""#), (#""name":"Stock brush""#, #""name":"Stock\u0000brush""#),
            (#""collection":"""#, #""collection":null"#),
            (#""isInternal":false"#, #""isInternal":false,"resourceID":123"#),
            (#""fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef""#, #""fingerprint":"ABCDEF""#),
            (#""fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef""#, #""fingerprint":"0123456789abcdeF0123456789abcdef0123456789abcdef0123456789abcdef""#),
            (#""x":-1.5"#, #""x":524288.1"#), (#""y":3.5"#, #""y":-524288.1"#),
            (#""pressure":0.75"#, #""pressure":-0.01"#), (#""xTilt":-1.0"#, #""xTilt":1.1"#),
            (#""timeMilliseconds":4294967295"#, #""timeMilliseconds":4294967296"#),
            (#""timeMilliseconds":4294967295"#, #""timeMilliseconds":-1"#),
            (#""timeMilliseconds":4294967295"#, #""timeMilliseconds":1.0"#),
            (#""x":-1.5"#, #""x":-1.5,"x":2"#),
            (#""tag":"completeStroke""#, #""tag":"completeStroke","future":true"#),
        ]
        for (old, new) in mutations {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(strokeDocument(replace(strokeJSON, old, new)))), old)
        }
        let emptyBatch = replace(strokeJSON, strokeBatches, "[[]]")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(strokeDocument(emptyBatch))))
        let malformedBatches = replace(strokeJSON, strokeBatches, "[0]")
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(strokeDocument(malformedBatches))))
    }

    func testTapPreservesMissingOptionalFieldsAndSuccessfulStrokeSelectsVersionTwo() throws {
        var tap = replace(strokeJSON, strokeBatches, "[]")
        tap = replace(tap, #""collection":"","isInternal""#, #""isInternal""#)
        tap = replace(tap, #""hardness":0.25,"opacity""#, #""opacity""#)
        tap = replace(tap, #""antiErase":true"#, #""antiErase":false"#)
        tap = replace(tap, #""tool":"eraser""#, #""tool":"pencil""#)
        let value = try RecorderFileCodec.decode(bytes(strokeDocument(tap)))
        guard case .success(.completeStroke(let stroke), _) = value.records[0].outcome else { return XCTFail("Missing tap") }
        XCTAssertEqual(stroke.trace.batches, [])
        XCTAssertNil(stroke.settings.hardness)
        XCTAssertNil(stroke.facts.brush.collection)
        XCTAssertNotEqual(stroke.facts.brush, .init(name: "Stock brush", collection: "", isInternal: false))
        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":2"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
    }

    func testVersionTwoPreservesMixedCommandsAndInspectionOutcomes() throws {
        let first = success(strokeJSON, binding: strokeBinding)
        let second = success(#"{"tag":"transformImage","transform":"flipHorizontal"}"#, ordinal: 1)
        let failed = #"{"ordinal":2,"outcome":"failure","reason":"Stroke refused"}"#
        let cancelled = #"{"ordinal":3,"outcome":"cancelled","reason":"Cancelled after accepted work"}"#
        let text = document([first, second, failed, cancelled].joined(separator: ","), symbols: strokeSymbol)
            .replacingOccurrences(of: #""version":1"#, with: #""version":2"#)
        let decoded = try RecorderFileCodec.decode(bytes(text))
        let prepared = try RecorderFileSemanticBridge.prepare(decoded)
        XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(decoded)), decoded)
        XCTAssertEqual(prepared.log.records.count, 4)
        guard case .success(.transformImage(.flipHorizontal)) = prepared.log.records[1].resolution else {
            return XCTFail("The ordinary command changed inside version 2")
        }
        XCTAssertEqual(decoded.records[2].outcome, .failure("Stroke refused"))
        XCTAssertEqual(decoded.records[3].outcome, .cancelled("Cancelled after accepted work"))
        XCTAssertEqual(prepared.log.replayRefusal, .unsuccessfulRecording)
    }

    func testStrokeSnapshotNeedsCaptureTimeBindingAndMatchesLiteral() throws {
        let expected = try RecorderFileCodec.decode(bytes(strokeDocument(strokeJSON)))
        guard case .success(.completeStroke(let stroke), _) = expected.records[0].outcome else { return XCTFail("Missing stroke") }
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let accepted = try log.reserve()
        try log.resolve(accepted, with: .success(.completeStroke(stroke)))
        try log.stopRecording()
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(expected.symbols[0].description)])
        func snapshot(_ bindings: [Int: RecorderBindingDescription]) throws -> RecorderFileValue {
            try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Named", origin: origin,
                                           descriptions: catalog, bindings: bindings)
        }
        XCTAssertThrowsError(try snapshot([:]))
        XCTAssertThrowsError(try snapshot([0: .none]))
        XCTAssertThrowsError(try snapshot([0: .unavailable("Capture failed")]))
        XCTAssertEqual(try snapshot([0: .layer(symbol)]), expected)
        XCTAssertEqual(log.records.count, 1)
        XCTAssertEqual(log.pendingCount, 0)
    }

    func testStrokeAndPolygonPointBudgetsAreSharedAndBatchesStayNonempty() throws {
        let source = try RecorderFileCodec.decode(bytes(strokeDocument(strokeJSON)))
        guard case .success(.completeStroke(let stroke), _) = source.records[0].outcome else { return XCTFail("Missing stroke") }
        let point = stroke.trace.first
        let maximum = RecorderStrokeTrace(first: point, batches: [Array(repeating: point, count: 65_535)])
        XCTAssertEqual(try RecorderFileLimits.strokePointCount(maximum, remaining: 100_000), 65_536)
        let excess = RecorderStrokeTrace(first: point, batches: [Array(repeating: point, count: 65_536)])
        let settings = RecorderFileCommand.Options(operation: .replace, antialias: false, feather: 0,
                                                   cornerRadius: 0, threshold: 0, contiguous: true, sampleMerged: true)
        func file(_ trace: RecorderStrokeTrace, polygonCount: Int = 0) -> RecorderFileValue {
            let command = RecorderStrokeCommand(settings: stroke.settings, trace: trace, facts: stroke.facts)
            var rows: [RecorderFileValue.Record] = [.init(ordinal: 0, outcome: .success(.completeStroke(command), .layer(symbol)))]
            if polygonCount > 0 {
                rows.append(.init(ordinal: 1, outcome: .success(.selectionShape(.polygon(
                    Array(repeating: .init(x: 0, y: 0), count: polygonCount)), settings), .none)))
            }
            return .init(recordingID: recordingID, name: "Named", origin: origin, symbols: source.symbols, records: rows)
        }
        XCTAssertThrowsError(try RecorderFileCodec.encode(file(excess)))
        XCTAssertThrowsError(try RecorderFileCodec.encode(file(.init(first: point, batches: [[]]))))
        let boundary = try RecorderFileCodec.encode(file(maximum, polygonCount: 34_464))
        XCTAssertEqual(try RecorderFileCodec.decode(boundary).records.count, 2)
        XCTAssertThrowsError(try RecorderFileCodec.encode(file(maximum, polygonCount: 34_465)))
        let tooManySamples = "[" + Array(repeating: "0", count: 65_536).joined(separator: ",") + "]"
        let batchOverflow = replace(strokeJSON, strokeBatches, "[" + tooManySamples + "]")
        rejects(strokeDocument(batchOverflow), reason: "oversized array")
        let polygon = #"{"tag":"selectionShape","shape":{"tag":"polygon","points":["#
            + Array(repeating: #"{"x":0,"y":0}"#, count: 100_000).joined(separator: ",") + #"]},"options":"# + options + "}"
        let rows = success(polygon) + "," + success(replace(strokeJSON, strokeBatches, "[]"), binding: strokeBinding, ordinal: 1)
        let overflow = document(rows, symbols: strokeSymbol).replacingOccurrences(of: #""version":1"#, with: #""version":2"#)
        rejects(overflow, reason: "Invalid stroke point count")
    }
}
