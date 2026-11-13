import XCTest
@testable import GlimsKit

final class RecorderLabLayerStrokeFileTests: XCTestCase {
    private let layer = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    private func stroke() throws -> RecorderLabLayerStrokeCommand {
        var brush = EngineSession.Brush()
        brush.size = 12; brush.opacity = 0.75; brush.red = 0.2; brush.green = 0.5; brush.blue = 0.9
        brush.pressureSize = true; brush.hardness = 0.4
        let first = try RecorderTabletStrokeTrace.Point(x: 1, y: 2, pressure: 0.5, xTilt: 0.2, yTilt: -0.1,
                                                         timeMilliseconds: UInt32.max)
        let next = try RecorderTabletStrokeTrace.Point(x: 3, y: 4, pressure: 0.8, xTilt: 0, yTilt: 0,
                                                        timeMilliseconds: 0, rotationTurns: 0, tangentialPressure: -0.5)
        return .init(settings: try XCTUnwrap(RecorderStrokeCommand.Settings(brush)),
                     trace: .init(first: first, batches: [[next]]),
                     facts: .init(brush: .init(name: "Owned Brush", collection: nil, isInternal: false),
                                  fingerprint: String(repeating: "a", count: 64)))
    }

    private func file(binding: RecorderBindingDescription? = nil,
                      kind: RecorderTargetDescription.Kind = .pixel) throws -> RecorderFileValue {
        let symbol = RecorderFileValue.Symbol(id: layer, description: .init(name: "Layer", kind: kind,
            ancestors: [], siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 7, height: 9)))
        return .init(recordingID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, name: "Layer Brush",
                     origin: .init(imageLabel: "Lab.xcf", initialWidth: 7, initialHeight: 9), symbols: [symbol],
                     records: [.init(ordinal: 0, outcome: .success(.completeLabLayerStroke(try stroke()), binding ?? .layer(layer)))])
    }

    func testVersion18RoundTripsAndPreparesSemanticRecording() throws {
        let original = try file()
        let bytes = try RecorderFileCodec.encode(original)
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(json.contains(#""version":18"#))
        XCTAssertTrue(json.contains(#""tag":"completeLabLayerStroke""#))
        let decoded = try RecorderFileCodec.decode(bytes)
        XCTAssertEqual(decoded, original)
        let prepared = try RecorderFileSemanticBridge.prepare(decoded)
        XCTAssertEqual(prepared.file, original)
        guard case .success(.completeLabLayerStroke(let captured)) = prepared.log.records[0].resolution else {
            return XCTFail("The detached log lost the layered Lab stroke")
        }
        XCTAssertEqual(captured, try stroke())
        var descriptions = RecorderDescriptionCatalog()
        descriptions.acceptFirst([layer: .available(original.symbols[0].description)])
        let snapshot = try RecorderFileCodec.snapshot(prepared.log, recordingID: original.recordingID, name: original.name,
            origin: original.origin, descriptions: descriptions, bindings: [0: .layer(layer)])
        XCTAssertEqual(snapshot, original)
    }

    func testVersionAndBindingFailClosed() throws {
        let bytes = try RecorderFileCodec.encode(file())
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(json.replacingOccurrences(of: #""version":18"#, with: #""version":17"#).utf8)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(json.replacingOccurrences(of: #""version":18"#, with: #""version":19"#).utf8)))
        XCTAssertThrowsError(try RecorderFileCodec.encode(file(binding: RecorderBindingDescription.none)))
        XCTAssertThrowsError(try RecorderFileCodec.encode(file(kind: .channel)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(json.replacingOccurrences(of: #""tool":"paintbrush""#, with: #""tool":"pencil""#).utf8)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(json.replacingOccurrences(of: String(repeating: "a", count: 64), with: String(repeating: "A", count: 64)).utf8)))
    }

    func testFilePointBudgetCountsAllLayeredBrushStrokes() throws {
        let original = try file()
        let single = try stroke()
        let point = single.trace.first
        let trace = RecorderTabletStrokeTrace(first: point,
            batches: Array(repeating: Array(repeating: point, count: 4096), count: 15)
                + [Array(repeating: point, count: 4095)])
        let large = RecorderLabLayerStrokeCommand(settings: single.settings, trace: trace, facts: single.facts)
        XCTAssertNoThrow(try large.validated())
        let records = (0..<2).map { RecorderFileValue.Record(ordinal: $0,
            outcome: .success(.completeLabLayerStroke(large), .layer(layer))) }
        let oversized = RecorderFileValue(recordingID: original.recordingID, name: original.name,
                                          origin: original.origin, symbols: original.symbols, records: records)
        XCTAssertThrowsError(try RecorderFileCodec.encode(oversized))
    }

    func testVersion18CannotBeClaimedWithoutSuccessfulLayerStroke() throws {
        let original = try file()
        let onlyFailure = RecorderFileValue(recordingID: original.recordingID, name: original.name, origin: original.origin,
                                           symbols: original.symbols, records: [.init(ordinal: 0, outcome: .failure("Failed"))])
        let json = try XCTUnwrap(String(data: RecorderFileCodec.encode(onlyFailure), encoding: .utf8))
        XCTAssertTrue(json.contains(#""version":1"#))
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(json.replacingOccurrences(of: #""version":1"#, with: #""version":18"#).utf8)))
    }
}
