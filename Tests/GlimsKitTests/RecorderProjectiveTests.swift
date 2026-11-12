import CoreGraphics
import Foundation
import XCTest
@testable import GlimsKit

final class RecorderProjectiveTests: XCTestCase {
    private typealias Projective = RecorderFileCommand.Projective
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let origin = RecorderFileValue.Origin(imageLabel: "Original", initialWidth: 100, initialHeight: 100)
    private let matrixJSON = #"{"h00":2,"h01":3,"h02":5,"h10":7,"h11":11,"h12":13,"h20":0.01,"h21":0.02,"h22":1}"#
    private let bindingJSON = #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#
    private let symbolJSON = #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Original layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":100,"height":100}}}"#

    private var matrix: Projective {
        .init(h00: 2, h01: 3, h02: 5, h10: 7, h11: 11, h12: 13, h20: 0.01, h21: 0.02, h22: 1)
    }

    private func document(version: Int = 6, matrix: String? = nil,
                          interpolation: String = "linear", rows: String? = nil) -> String {
        let command = #"{"tag":"transformProjectiveLayer","matrix":"# + (matrix ?? matrixJSON)
            + #","interpolation":""# + interpolation + #""}"#
        let row = #"{"ordinal":0,"outcome":"success","command":"# + command
            + #","binding":"# + bindingJSON + "}"
        return #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Perspective","origin":{"imageLabel":"Original","initialWidth":100,"initialHeight":100},"symbols":["#
            + symbolJSON + #"],"records":["# + (rows ?? row) + "]}"
    }

    private func decode(_ text: String) throws -> RecorderFileValue {
        try RecorderFileCodec.decode(Data(text.utf8))
    }

    private func changed(_ text: String, _ before: String, _ after: String,
                         file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let range = text.range(of: before) else {
            XCTFail("Fixture mutation did not match: \(before)", file: file, line: line)
            return text
        }
        return text.replacingCharacters(in: range, with: after)
    }

    private func fileValue(_ value: Projective) -> RecorderFileValue {
        let description = RecorderTargetDescription(name: "Original layer", kind: .pixel, ancestors: [],
            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 100, height: 100))
        return .init(recordingID: recordingID, name: "Perspective", origin: origin,
                     symbols: [.init(id: symbol, description: description)],
                     records: [.init(ordinal: 0, outcome: .success(.transformProjectiveLayer(value,
                         interpolation: .linear), .layer(symbol)))])
    }

    private func assertPoint(_ point: CGPoint?, x: Double, y: Double,
                             file: StaticString = #filePath, line: UInt = #line) {
        guard let point else { return XCTFail("Missing mapped point", file: file, line: line) }
        XCTAssertEqual(point.x, x, accuracy: 1e-10, file: file, line: line)
        XCTAssertEqual(point.y, y, accuracy: 1e-10, file: file, line: line)
    }

    func testLiteralPreservesAllNineDistinctCoefficientsAndAnalyticMapping() throws {
        let file = try decode(document())
        guard case .success(.transformProjectiveLayer(let actual, let interpolation), .layer(let target))
                = file.records[0].outcome else { return XCTFail("Missing projective layer command") }
        XCTAssertEqual(actual, matrix)
        XCTAssertEqual(actual.projectiveTransform.coefficients, [2, 3, 5, 7, 11, 13, 0.01, 0.02, 1])
        XCTAssertEqual(interpolation, .linear)
        XCTAssertEqual(target, symbol)
        // Numerators are 85 and 303; W is 1.5. Every coefficient matters.
        assertPoint(actual.projectiveTransform.project(CGPoint(x: 10, y: 20)), x: 170.0 / 3, y: 202)
        XCTAssertFalse(RecorderFileCommand.transformProjectiveLayer(actual, interpolation: .linear).isTargetIndependent)
        let data = try RecorderFileCodec.encode(file)
        XCTAssertEqual(try RecorderFileCodec.decode(data), file)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""version":6"#))
    }

    func testEveryOwnedInterpolationSurvivesCodecAndSemanticBridge() throws {
        let cases: [(String, EngineSession.Interpolation)] = [
            ("none", .none), ("linear", .linear), ("cubic", .cubic), ("noHalo", .noHalo), ("loHalo", .loHalo),
        ]
        for (tag, expected) in cases {
            let file = try decode(document(interpolation: tag))
            let prepared = try RecorderFileSemanticBridge.prepare(file)
            guard case .success(.transformProjectiveLayer(let value, let interpolation))
                    = prepared.log.records[0].resolution else { return XCTFail("Missing semantic projective command") }
            XCTAssertEqual(value, matrix.projectiveTransform)
            XCTAssertEqual(interpolation, expected)
            XCTAssertTrue(SemanticImageCommand.transformProjectiveLayer(matrix: value,
                interpolation: interpolation).requiresResolvedFloatingSelection)
            let restored = try RecorderFileCommand(.transformProjectiveLayer(matrix: value, interpolation: interpolation))
            guard case .success(let saved, _) = file.records[0].outcome else { return XCTFail("Missing file command") }
            XCTAssertEqual(restored, saved)
        }
    }

    func testSnapshotNeedsCaptureTimeLayerBindingAndRetainsCoefficients() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        let token = try log.reserve()
        try log.resolve(token, with: .success(.transformProjectiveLayer(matrix: matrix.projectiveTransform,
                                                                       interpolation: .loHalo)))
        try log.stopRecording()
        XCTAssertThrowsError(try RecorderFileCodec.snapshot(log, recordingID: recordingID,
            name: "Perspective", origin: origin, descriptions: .init(), bindings: [:]))
        var descriptions = RecorderDescriptionCatalog()
        descriptions.acceptFirst([symbol: .available(RecorderTargetDescription(name: "Original layer",
            kind: .pixel, ancestors: [], siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 100, height: 100)))])
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Perspective",
            origin: origin, descriptions: descriptions, bindings: [0: .layer(symbol)])
        guard case .success(.transformProjectiveLayer(let value, let interpolation), .layer(let target))
                = snapshot.records[0].outcome else { return XCTFail("Snapshot lost its explicit target") }
        XCTAssertEqual(value, matrix)
        XCTAssertEqual(interpolation, .loHalo)
        XCTAssertEqual(target, symbol)
        XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(snapshot)), snapshot)
    }

    func testVersionSixIsRequiredAndOlderVersionsKeepTheirCommandFamilies() throws {
        for version in 1...5 { XCTAssertThrowsError(try decode(document(version: version))) }
        XCTAssertThrowsError(try decode(document(version: 5,
            rows: #"{"ordinal":0,"outcome":"failure","reason":"No successful command"}"#))) {
            XCTAssertTrue($0.localizedDescription.contains("Version 5 requires a successful Levels"))
        }
        XCTAssertThrowsError(try decode(document(version: 7)))
        XCTAssertThrowsError(try decode(document(rows: #"{"ordinal":0,"outcome":"cancelled","reason":"Cancelled"}"#)))
        XCTAssertThrowsError(try decode(document(rows: #"{"ordinal":0,"outcome":"success","command":{"tag":"scale","width":20,"height":30},"binding":{"kind":"none"}}"#)))
        let old = try decode(document(version: 1,
            rows: #"{"ordinal":0,"outcome":"failure","reason":"Unsuccessful projective operation"}"#))
        XCTAssertTrue(String(decoding: try RecorderFileCodec.encode(old), as: UTF8.self).contains(#""version":1"#))
    }

    func testMixedAffineAndProjectiveSuccessesEncodeHighestVersion() throws {
        let base = try decode(document())
        let affine = RecorderFileCommand.transformLayer(.init(a: 2, b: 0, c: 0, d: 1, tx: 3, ty: 4),
                                                        interpolation: .cubic)
        let mixed = RecorderFileValue(recordingID: base.recordingID, name: base.name, origin: base.origin,
            symbols: base.symbols, records: [base.records[0],
                .init(ordinal: 1, outcome: .success(affine, .layer(symbol))),
                .init(ordinal: 2, outcome: .failure("Later command failed"))])
        let bytes = try RecorderFileCodec.encode(mixed)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(#""version":6"#))
        XCTAssertEqual(try RecorderFileCodec.decode(bytes), mixed)
        let legacy = RecorderFileValue(recordingID: base.recordingID, name: base.name, origin: base.origin,
            symbols: base.symbols, records: [.init(ordinal: 0, outcome: .success(affine, .layer(symbol)))])
        XCTAssertTrue(String(decoding: try RecorderFileCodec.encode(legacy), as: UTF8.self).contains(#""version":4"#))
    }

    func testLevelsAndProjectiveCommandsCoexistWithoutDowngradingEitherSchema() throws {
        let base = try decode(document())
        var settings = EngineSession.LevelsSettings()
        settings.value.gamma = 1.8
        settings.clampInput = false
        let levels = try RecorderFileCommand(.applyLevels(settings))
        let records: [RecorderFileValue.Record] = [base.records[0],
            .init(ordinal: 1, outcome: .success(levels, .layer(symbol)))]
        let combined = RecorderFileValue(recordingID: base.recordingID, name: base.name,
            origin: base.origin, symbols: base.symbols, records: records)
        let bytes = try RecorderFileCodec.encode(combined)
        XCTAssertTrue(String(decoding: bytes, as: UTF8.self).contains(#""version":6"#))
        XCTAssertEqual(try RecorderFileCodec.decode(bytes), combined)
        let prepared = try RecorderFileSemanticBridge.prepare(combined)
        guard case .success(.applyLevels(let actual)) = prepared.log.records[1].resolution else {
            return XCTFail("Levels was lost from the v6 recording")
        }
        XCTAssertEqual(actual, settings)
        let levelsOnly = RecorderFileValue(recordingID: base.recordingID, name: base.name,
            origin: base.origin, symbols: base.symbols,
            records: [.init(ordinal: 0, outcome: .success(levels, .layer(symbol)))])
        let legacy = try RecorderFileCodec.encode(levelsOnly)
        XCTAssertTrue(String(decoding: legacy, as: UTF8.self).contains(#""version":5"#))
        XCTAssertEqual(try RecorderFileCodec.decode(legacy), levelsOnly)
    }

    func testStrictFieldsInterpolationBindingsAndNoNativeIDs() {
        let mutations = [
            (#""h00":2"#, #""h00":2,"future":0"#),
            (#","h22":1"#, ""),
            (#""interpolation":"linear""#, #""interpolation":"bilinear""#),
            (#""interpolation":"linear""#, #""interpolation":2"#),
            (#""matrix":{"h00""#, #""layer":42,"matrix":{"h00""#),
            (bindingJSON, #"{"kind":"none"}"#),
            (bindingJSON, #"{"kind":"channel","symbol":"22222222-2222-2222-2222-222222222222"}"#),
            (bindingJSON, #"{"kind":"layer","symbol":42}"#),
            (#""kind":"pixel""#, #""kind":"channel""#),
            (#""kind":"pixel""#, #""kind":"quickMask""#),
        ]
        for (before, after) in mutations {
            XCTAssertThrowsError(try decode(changed(document(), before, after)), before)
        }
        XCTAssertThrowsError(try decode(changed(document(), #","binding":"# + bindingJSON, "")))
    }

    func testNonfiniteSingularZeroAndScalarIdentitiesRejectWholeFile() {
        for token in ["NaN", "Infinity", "1e309"] {
            XCTAssertThrowsError(try decode(changed(document(), #""h00":2"#, #""h00":"# + token)))
        }
        let rejected: [ProjectiveTransform] = [
            .init(h00: 1, h01: 2, h02: 3, h10: 2, h11: 4, h12: 6, h20: 0, h21: 0, h22: 1),
            .init(h00: 0, h01: 0, h02: 0, h10: 0, h11: 0, h12: 0, h20: 0, h21: 0, h22: 0),
            .identity,
            .init(h00: 2, h01: 0, h02: 0, h10: 0, h11: 2, h12: 0, h20: 0, h21: 0, h22: 2),
            .init(h00: -3, h01: 0, h02: 0, h10: 0, h11: -3, h12: 0, h20: 0, h21: 0, h22: -3),
            .init(h00: Double.nan, h01: 0, h02: 0, h10: 0, h11: 1, h12: 0, h20: 0, h21: 0, h22: 1),
            .init(h00: 1, h01: 0, h02: 0, h10: 0, h11: 1, h12: 0, h20: Double.infinity, h21: 0, h22: 1),
        ]
        for transform in rejected {
            let value = Projective(transform)
            XCTAssertThrowsError(try value.validated())
            XCTAssertThrowsError(try RecorderFileCodec.encode(fileValue(value)))
            XCTAssertNil(value.outputBounds(for: .init(x: 0, y: 0, width: 100, height: 100)))
        }
        let singular = #"{"h00":1,"h01":2,"h02":3,"h10":2,"h11":4,"h12":6,"h20":0,"h21":0,"h22":1}"#
        XCTAssertThrowsError(try decode(document(matrix: singular)))
        for scale in [1, 2, -3] {
            let identity = "{\"h00\":\(scale),\"h01\":0,\"h02\":0,\"h10\":0,\"h11\":\(scale),\"h12\":0,\"h20\":0,\"h21\":0,\"h22\":\(scale)}"
            XCTAssertThrowsError(try decode(document(matrix: identity)))
        }
    }

    func testScalarEquivalenceDoesNotNormalizeStoredCoefficients() throws {
        for scale in [1.0, 2, -3, 1e150, 1e-150] {
            let value = Projective(h00: 2 * scale, h01: 3 * scale, h02: 5 * scale,
                h10: 7 * scale, h11: 11 * scale, h12: 13 * scale,
                h20: 0.01 * scale, h21: 0.02 * scale, h22: scale)
            XCTAssertEqual(try value.validated(), value)
            let file = fileValue(value)
            XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(file)), file)
            assertPoint(value.projectiveTransform.project(CGPoint(x: 10, y: 20)), x: 170.0 / 3, y: 202)
            XCTAssertNotNil(value.outputBounds(for: .init(x: 0, y: 0, width: 100, height: 100)))
        }
    }

    func testZeroH22IsAdmissibleAwayFromItsHorizon() throws {
        let value = Projective(h00: 1, h01: 0, h02: 1, h10: 0, h11: 1, h12: 0,
                               h20: 1, h21: 0, h22: 0)
        XCTAssertNoThrow(try value.validated())
        assertPoint(value.projectiveTransform.project(CGPoint(x: 10, y: 20)), x: 1.1, y: 2)
        XCTAssertNotNil(value.outputBounds(for: .init(x: 10, y: 0, width: 10, height: 10)))
        XCTAssertNil(value.outputBounds(for: .init(x: -10, y: 0, width: 20, height: 10)))
        XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(fileValue(value))), fileValue(value))
    }

    func testFreshBoundsControlAdmissionWithoutAdaptingTheMatrix() throws {
        let value = Projective(h00: 1, h01: 0, h02: 0, h10: 0, h11: 1, h12: 0,
                               h20: -0.1, h21: 0, h22: 1)
        // The stored symbol describes 0...100, crossing W=0 at x=10.
        // That hint cannot prevent loading a recording for a safe new layer.
        XCTAssertNoThrow(try RecorderFileCodec.encode(fileValue(value)))
        XCTAssertNotNil(value.outputBounds(for: .init(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertNil(value.outputBounds(for: .init(x: 0, y: 0, width: 20, height: 10)))
        XCTAssertNil(value.outputBounds(for: .init(x: 0, y: 0, width: 9.99, height: 1)))
        XCTAssertNil(value.outputBounds(for: .init(x: 0, y: 0, width: -1, height: 1)))
        XCTAssertEqual(value.projectiveTransform.coefficients, [1, 0, 0, 0, 1, 0, -0.1, 0, 1])
        // Source-independent validation permits a finite invertible matrix;
        // actual coordinate and size limits still reject replay safely.
        let huge = Projective(h00: 2, h01: 0, h02: 0, h10: 0, h11: 2, h12: 0,
                              h20: 0, h21: 0, h22: 1)
        XCTAssertNoThrow(try huge.validated())
        XCTAssertNil(huge.outputBounds(for: .init(x: 0, y: 0, width: 300_000, height: 1)))
        XCTAssertNil(huge.outputBounds(for: .init(x: 600_000, y: 0, width: 1, height: 1)))
    }
}
