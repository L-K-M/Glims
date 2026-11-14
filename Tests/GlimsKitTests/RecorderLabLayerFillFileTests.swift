import XCTest
@testable import GlimsKit

final class RecorderLabLayerFillFileTests: XCTestCase {
    private let layer = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    private func fill(opacity: Double = 0.625) throws -> RecorderLabLayerFillValue {
        let color = try RecorderColor(red: 0.125, green: 0.375, blue: 0.875, alpha: 0.75)
        return .init(color: color, opacity: opacity)
    }

    private func file(binding: RecorderBindingDescription? = nil,
                      kind: RecorderTargetDescription.Kind = .pixel,
                      opacity: Double = 0.625) throws -> RecorderFileValue {
        let symbol = RecorderFileValue.Symbol(id: layer, description: .init(name: "Layer", kind: kind,
            ancestors: [], siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 7, height: 9)))
        return .init(recordingID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, name: "Layer Fill",
                     origin: .init(imageLabel: "Lab.xcf", initialWidth: 7, initialHeight: 9), symbols: [symbol],
                     records: [.init(ordinal: 0, outcome: .success(.fillLabLayer(try fill(opacity: opacity)), binding ?? .layer(layer)))])
    }

    func testVersion19RoundTripsAndPreparesDetachedRecording() throws {
        let original = try file()
        let bytes = try RecorderFileCodec.encode(original)
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertTrue(json.contains(#""version":19"#))
        XCTAssertTrue(json.contains(#""tag":"fillLabLayer""#))
        let decoded = try RecorderFileCodec.decode(bytes)
        XCTAssertEqual(decoded, original)
        let prepared = try RecorderFileSemanticBridge.prepare(decoded)
        guard case .success(.fillLabLayer(let captured)) = prepared.log.records[0].resolution else {
            return XCTFail("The detached log lost the layered Lab Fill")
        }
        XCTAssertEqual(captured, try fill())
        var descriptions = RecorderDescriptionCatalog()
        descriptions.acceptFirst([layer: .available(original.symbols[0].description)])
        let snapshot = try RecorderFileCodec.snapshot(prepared.log, recordingID: original.recordingID, name: original.name,
            origin: original.origin, descriptions: descriptions, bindings: [0: .layer(layer)])
        XCTAssertEqual(snapshot, original)
    }

    func testVersionBindingAndPayloadFailClosed() throws {
        let bytes = try RecorderFileCodec.encode(file())
        let json = try XCTUnwrap(String(data: bytes, encoding: .utf8))
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(json.replacingOccurrences(of: #""version":19"#, with: #""version":18"#).utf8)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(json.replacingOccurrences(of: #""version":19"#, with: #""version":20"#).utf8)))
        XCTAssertThrowsError(try RecorderFileCodec.encode(file(binding: RecorderBindingDescription.none)))
        XCTAssertThrowsError(try RecorderFileCodec.encode(file(kind: .channel)))
        let outOfRange = try file(opacity: 1.1)
        XCTAssertThrowsError(try RecorderFileCodec.encode(outOfRange))
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(json.replacingOccurrences(of: #""opacity":0.625"#, with: #""opacity":1.1"#).utf8)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(json.replacingOccurrences(of: #""red":0.125"#, with: #""red":1.1"#).utf8)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(json.replacingOccurrences(of: #""space":"srgb""#, with: #""space":"lab""#).utf8)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(json.replacingOccurrences(of: #""tag":"fillLabLayer""#, with: #""unexpected":1,"tag":"fillLabLayer""#).utf8)))
    }

    func testOpacityMustBeFiniteAndWithinNativeRange() throws {
        for value in [-Double.infinity, -0.01, 1.01, Double.infinity, Double.nan] {
            let constructed = try fill(opacity: value)
            XCTAssertThrowsError(try constructed.validated(), "opacity \(value) should be rejected")
        }
        XCTAssertNoThrow(try fill(opacity: 0).validated())
        XCTAssertNoThrow(try fill(opacity: 1).validated())
    }

    func testVersion19CannotBeClaimedWithoutSuccessfulLayerFill() throws {
        let original = try file()
        let onlyFailure = RecorderFileValue(recordingID: original.recordingID, name: original.name, origin: original.origin,
                                           symbols: original.symbols, records: [.init(ordinal: 0, outcome: .failure("Failed"))])
        let json = try XCTUnwrap(String(data: RecorderFileCodec.encode(onlyFailure), encoding: .utf8))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 1)
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(json.replacingOccurrences(of: #""version":1"#, with: #""version":19"#).utf8)))
    }
}
