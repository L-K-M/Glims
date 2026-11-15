import XCTest
@testable import GlimsKit

/// Pure admission and file-value checks. The identity and digest below are
/// authored format fixtures, not evidence of a native brush or pixel match.
final class RecorderSpongeAdmissionTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbolID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func brush(_ tool: EngineSession.Brush.Tool, antiErase: Bool = false) -> EngineSession.Brush {
        var value = EngineSession.Brush()
        value.tool = tool
        value.size = 8.5
        value.opacity = 0.75
        value.red = 0.2
        value.green = 0.4
        value.blue = 0.6
        value.hardness = 0.25
        value.antiErase = antiErase
        // Keep the real Brush default pressureSize=true. This fixture must
        // exercise ordinary default-pressure Paintbrush admission.
        return value
    }

    private func trace() throws -> RecorderStrokeTrace {
        try .init(first: .init(x: -1.5, y: 3.5, pressure: 0.25, xTilt: -0.5, yTilt: 0.5,
                               timeMilliseconds: 1), batches: [
            [.init(x: 2.25, y: 4, pressure: 0.75, xTilt: 0.25, yTilt: 0, timeMilliseconds: 7)],
            [.init(x: 3, y: 5, pressure: 1, xTilt: 0, yTilt: -0.25, timeMilliseconds: 12)],
        ])
    }

    private func command(_ settings: RecorderStrokeCommand.Settings) throws -> RecorderStrokeCommand {
        try .init(settings: settings, trace: trace(), facts: .init(
            brush: .init(name: "Authored brush identity", collection: "fixture", isInternal: false),
            fingerprint: digest))
    }

    private func file(_ stroke: RecorderStrokeCommand) -> RecorderFileValue {
        .init(recordingID: recordingID, name: "Admission fixture",
              origin: .init(imageLabel: "A", initialWidth: 32, initialHeight: 24),
              symbols: [.init(id: symbolID, description: .init(name: "Original pixel layer", kind: .pixel,
                  ancestors: [], siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 32, height: 24)))],
              records: [.init(ordinal: 0, outcome: .success(.completeStroke(stroke), .layer(symbolID)))])
    }

    /// Independent strict JSON: the tool tag is literal input to the decoder,
    /// never obtained from the production Tool enum or encoder.
    private func literal(tool: String = "paintbrush", version: Int = 2, antiErase: Bool = false) -> Data {
        let text = #"""
        {"format":"ch.lkmc.Glims.recording","version":\#(version),"recordingID":"11111111-1111-1111-1111-111111111111","name":"Admission fixture","origin":{"imageLabel":"A","initialWidth":32,"initialHeight":24},"symbols":[{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Original pixel layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":32,"height":24}}}],"records":[{"ordinal":0,"outcome":"success","binding":{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"},"command":{"tag":"completeStroke","settings":{"tool":"\#(tool)","size":8.5,"opacity":0.75,"red":0.2,"green":0.4,"blue":0.6,"hardness":0.25,"pressureSize":true,"antiErase":\#(antiErase)},"facts":{"brush":{"name":"Authored brush identity","collection":"fixture","isInternal":false},"fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"first":{"x":-1.5,"y":3.5,"pressure":0.25,"xTilt":-0.5,"yTilt":0.5,"timeMilliseconds":1},"batches":[[{"x":2.25,"y":4,"pressure":0.75,"xTilt":0.25,"yTilt":0,"timeMilliseconds":7}],[{"x":3,"y":5,"pressure":1,"xTilt":0,"yTilt":-0.25,"timeMilliseconds":12}]]}}]}
        """#
        return Data(text.utf8)
    }

    private func assertPrepared(_ source: RecorderFileValue, stroke: RecorderStrokeCommand,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let prepared = try RecorderFileSemanticBridge.prepare(source)
        XCTAssertEqual(prepared.file, source, file: file, line: line)
        XCTAssertEqual(prepared.log.records.count, 1, file: file, line: line)
        guard case .success(.completeStroke(let actual)) = prepared.log.records.first?.resolution else {
            return XCTFail("The semantic bridge lost the complete stroke", file: file, line: line)
        }
        XCTAssertEqual(actual, stroke, file: file, line: line)
        XCTAssertFalse(prepared.log.isRecording, file: file, line: line)
        XCTAssertFalse(prepared.log.isReplaying, file: file, line: line)
        XCTAssertEqual(prepared.log.pendingCount, 0, file: file, line: line)
        XCTAssertNil(prepared.log.replayRefusal, file: file, line: line)
    }

    func testSpongeDirectionsCaptureSettingsAndRoundTripThroughVersionTwenty() throws {
        let cases: [(EngineSession.Brush.Tool, String, String)] = [
            (.spongeDesaturate, "spongeDesaturate", "Sponge Desaturate Stroke"),
            (.spongeSaturate, "spongeSaturate", "Sponge Saturate Stroke"),
        ]
        for (tool, wire, title) in cases {
            let input = brush(tool)
            let settings = try XCTUnwrap(RecorderStrokeCommand.Settings(input), wire)
            XCTAssertEqual(settings.tool.rawValue, wire)
            XCTAssertEqual(settings.brush, input)
            let stroke = try command(settings)
            XCTAssertEqual(stroke.title, title)
            let decoded = try RecorderFileCodec.decode(literal(tool: wire, version: 20))
            XCTAssertEqual(decoded, file(stroke))
            let encoded = try RecorderFileCodec.encode(decoded)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertEqual(object["version"] as? Int, 20)
            XCTAssertEqual(try RecorderFileCodec.decode(encoded), decoded)
            try assertPrepared(decoded, stroke: stroke)
        }
    }

    func testSpongeCannotMasqueradeAsAnOlderFileVersionOrAntiErase() throws {
        for tool in ["spongeDesaturate", "spongeSaturate"] {
            for version in [2, 18, 19] {
                XCTAssertThrowsError(try RecorderFileCodec.decode(literal(tool: tool, version: version)), "\(tool) version \(version)")
            }
            XCTAssertThrowsError(try RecorderFileCodec.decode(literal(tool: tool, version: 20, antiErase: true)))
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(literal(tool: "paintbrush", version: 20)),
                             "Version 20 is reserved for files containing a Sponge stroke")
        let ordinary = try RecorderFileCodec.decode(literal(tool: "paintbrush", version: 2))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: RecorderFileCodec.encode(ordinary)) as? [String: Any])
        XCTAssertEqual(object["version"] as? Int, 2)
    }
}
