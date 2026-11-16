import Foundation
import XCTest
@testable import GlimsKit

final class RecorderTabletStrokeFileTests: XCTestCase {
    private func fixture(tool: String = "paintbrush", version: Int = 21) -> [String: Any] {
        let point: [String: Any] = ["x": 4.5, "y": 8.5, "pressure": 0.5, "xTilt": -0.25, "yTilt": 0.5,
                                    "timeMilliseconds": UInt32.max, "rotationTurns": 0.75, "tangentialPressure": -0.5]
        let next: [String: Any] = ["x": 10, "y": 12, "pressure": 1, "xTilt": 0, "yTilt": 0,
                                   "timeMilliseconds": 0, "rotationTurns": 0.25, "tangentialPressure": 1]
        let command: [String: Any] = ["tag": "completeTabletStroke", "settings": ["tool": tool, "size": 8,
            "opacity": 0.75, "red": 0.2, "green": 0.4, "blue": 0.6, "pressureSize": true, "antiErase": false],
            "facts": ["brush": ["name": "Brush", "isInternal": false], "fingerprint": String(repeating: "a", count: 64)],
            "first": point, "batches": [[next]]]
        let symbol = "22222222-2222-2222-2222-222222222222"
        return ["format": "ch.lkmc.Glims.recording", "version": version,
                "recordingID": "11111111-1111-1111-1111-111111111111", "name": "Tablet fixture",
                "origin": ["imageLabel": "A", "initialWidth": 32, "initialHeight": 24],
                "symbols": [["id": symbol, "description": ["name": "Pixel", "kind": "pixel", "ancestors": [],
                    "siblingIndex": 0, "bounds": ["x": 0, "y": 0, "width": 32, "height": 24]]]],
                "records": [["ordinal": 0, "outcome": "success", "binding": ["kind": "layer", "symbol": symbol],
                             "command": command]]]
    }

    private func decode(_ object: [String: Any]) throws -> RecorderFileValue {
        try RecorderFileCodec.decode(JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
    }

    private func mapCommand(_ root: [String: Any], _ transform: (inout [String: Any]) -> Void) -> [String: Any] {
        var root = root, records = root["records"] as! [[String: Any]], command = records[0]["command"] as! [String: Any]
        transform(&command); records[0]["command"] = command; root["records"] = records
        return root
    }

    func testEveryOrdinaryToolRoundTripsV2AxesBatchesAndWrapInVersion21() throws {
        for tool in ["pencil", "eraser", "paintbrush", "spongeDesaturate", "spongeSaturate"] {
            let decoded = try decode(fixture(tool: tool))
            guard case .success(.completeTabletStroke(let stroke), .layer) = decoded.records.first?.outcome else {
                return XCTFail("missing V2 stroke for \(tool)")
            }
            XCTAssertEqual(stroke.settings.tool.rawValue, tool)
            XCTAssertEqual(stroke.trace.first.rotationTurns, 0.75)
            XCTAssertEqual(stroke.trace.first.tangentialPressure, -0.5)
            XCTAssertEqual(stroke.trace.first.timeMilliseconds, UInt32.max)
            XCTAssertEqual(stroke.trace.batches.first?.first?.timeMilliseconds, 0)
            XCTAssertEqual(stroke.trace.batches.first?.first?.rotationTurns, 0.25)
            let encoded = try RecorderFileCodec.encode(decoded)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["version"] as? Int, 21)
            XCTAssertEqual(try RecorderFileCodec.decode(encoded), decoded)
            let prepared = try RecorderFileSemanticBridge.prepare(decoded)
            XCTAssertEqual(prepared.file, decoded)
            guard case .success(.completeTabletStroke(let semantic)) = prepared.log.records.first?.resolution else {
                return XCTFail("semantic bridge dropped the tablet gesture")
            }
            XCTAssertEqual(semantic, stroke)
        }
    }

    func testEraserBackgroundUsesStrictVersion22AndSurvivesTabletRoundTrip() throws {
        let value = mapCommand(fixture(tool: "eraser", version: 22)) { command in
            var settings = command["settings"] as! [String: Any]
            settings["eraserBackground"] = ["red": 0.1, "green": 0.4, "blue": 0.7]
            command["settings"] = settings
        }
        let file = try decode(value)
        guard case .success(.completeTabletStroke(let stroke), .layer) = file.records.first?.outcome else {
            return XCTFail("missing tablet Eraser")
        }
        XCTAssertEqual(stroke.settings.brush.eraserBackground, .init(red: 0.1, green: 0.4, blue: 0.7))
        let bytes = try RecorderFileCodec.encode(file)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 22)
        XCTAssertEqual(try RecorderFileCodec.decode(bytes), file)
        XCTAssertEqual(try RecorderFileSemanticBridge.prepare(file).file, file)

        var oldVersion = value; oldVersion["version"] = 21
        XCTAssertThrowsError(try decode(oldVersion))
        XCTAssertThrowsError(try decode(fixture(tool: "eraser", version: 22)))
        XCTAssertThrowsError(try decode(mapCommand(value) { command in
            var settings = command["settings"] as! [String: Any]; settings["tool"] = "pencil"; command["settings"] = settings
        }))
        XCTAssertThrowsError(try decode(mapCommand(value) { command in
            var settings = command["settings"] as! [String: Any]
            settings["eraserBackground"] = ["red": 1.1, "green": 0.4, "blue": 0.7]; command["settings"] = settings
        }))
        XCTAssertThrowsError(try decode(mapCommand(value) { command in
            var settings = command["settings"] as! [String: Any]
            settings["eraserBackground"] = ["red": 0.1, "green": 0.4, "blue": 0.7, "alpha": 1]; command["settings"] = settings
        }))
    }

    func testVersionAndIdentityAndSampleValidationAreStrict() throws {
        for version in [1, 2, 16, 20] { XCTAssertThrowsError(try decode(fixture(version: version))) }
        XCTAssertThrowsError(try decode(mapCommand(fixture()) { $0["tag"] = "completeStroke" }))
        XCTAssertThrowsError(try decode(mapCommand(fixture()) { command in
            var facts = command["facts"] as! [String: Any]; facts["fingerprint"] = "BAD"; command["facts"] = facts
        }))
        XCTAssertThrowsError(try decode(mapCommand(fixture()) { command in
            var point = command["first"] as! [String: Any]; point["rotationTurns"] = 1; command["first"] = point
        }))
        XCTAssertThrowsError(try decode(mapCommand(fixture()) { command in command["batches"] = [[]] }))
        XCTAssertThrowsError(try decode(mapCommand(fixture()) { command in
            var settings = command["settings"] as! [String: Any]; settings["antiErase"] = true; command["settings"] = settings
        }))
        var wrongBinding = fixture(); var records = wrongBinding["records"] as! [[String: Any]]
        records[0]["binding"] = ["kind": "image"]; wrongBinding["records"] = records
        XCTAssertThrowsError(try decode(wrongBinding))
    }
}
