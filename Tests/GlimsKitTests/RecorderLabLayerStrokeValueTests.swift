import XCTest
@testable import GlimsKit

final class RecorderLabLayerStrokeValueTests: XCTestCase {
    private func command(brush: EngineSession.Brush = .init(), name: String = "Brush",
                         collection: String? = nil, digest: String = String(repeating: "a", count: 64),
                         trace: RecorderTabletStrokeTrace? = nil) throws -> RecorderLabLayerStrokeCommand {
        let point = try RecorderTabletStrokeTrace.Point(x: 4, y: 5, pressure: 0.7, xTilt: 0, yTilt: 0,
                                                       timeMilliseconds: 1)
        return .init(settings: try XCTUnwrap(RecorderStrokeCommand.Settings(brush)),
                     trace: trace ?? .init(first: point, batches: []),
                     facts: .init(brush: .init(name: name, collection: collection, isInternal: false), fingerprint: digest))
    }

    func testSettingsAndTabletAxesSurviveValidation() throws {
        var brush = EngineSession.Brush()
        brush.red = 0.2; brush.green = 0.4; brush.blue = 0.7; brush.pressureSize = true
        let next = try RecorderTabletStrokeTrace.Point(x: 5, y: 6, pressure: 0.8, xTilt: 0, yTilt: 0,
                                                       timeMilliseconds: 2, rotationTurns: 0.5, tangentialPressure: -0.5)
        let first = try RecorderTabletStrokeTrace.Point(x: 4, y: 5, pressure: 0.7, xTilt: 0, yTilt: 0,
                                                        timeMilliseconds: 1)
        let value = try command(brush: brush, trace: .init(first: first, batches: [[next]]))
        XCTAssertEqual(try value.validated(), value)
        XCTAssertEqual(value.settings.brush.red, 0.2)
        XCTAssertTrue(value.settings.brush.pressureSize)
        XCTAssertEqual(value.trace.batches[0][0].nativeSample.rotationTurns, 0.5)
        XCTAssertEqual(value.trace.batches[0][0].nativeSample.tangentialPressure, -0.5)
    }

    func testRefusesUnsupportedToolsAndUnverifiableIdentity() throws {
        var brush = EngineSession.Brush(); brush.tool = .pencil
        XCTAssertThrowsError(try command(brush: brush).validated())
        brush.tool = .paintbrush; brush.size = 0.5
        XCTAssertThrowsError(try command(brush: brush).validated())
        for name in ["", "bad\0name", String(repeating: "a", count: RecorderFileLimits.stringBytes + 1)] {
            XCTAssertThrowsError(try command(name: name).validated())
        }
        XCTAssertThrowsError(try command(collection: "bad\0collection").validated())
        for digest in ["", String(repeating: "A", count: 64), String(repeating: "g", count: 64), String(repeating: "a", count: 63)] {
            XCTAssertThrowsError(try command(digest: digest).validated())
        }
    }

    func testRejectsInvalidTraceOrderingAndOversizedBatches() throws {
        let first = try RecorderTabletStrokeTrace.Point(x: 1, y: 1, pressure: 1, xTilt: 0, yTilt: 0, timeMilliseconds: 10)
        let before = try RecorderTabletStrokeTrace.Point(x: 1, y: 1, pressure: 1, xTilt: 0, yTilt: 0, timeMilliseconds: 9)
        for batches in [[[]], [[before]], [Array(repeating: first, count: 4097)]] {
            XCTAssertThrowsError(try command(trace: .init(first: first, batches: batches)).validated())
        }
    }
}
