import XCTest
@testable import GlimsKit

/// The owned Curves value keeps every native field — TRC, per-channel kind,
/// the HDR bypass identity flag, all points with their kinds, and all 256
/// samples — through both directions of the facade bridge.
final class RecorderCurvesValueTests: XCTestCase {
    private typealias Value = RecorderCurvesValue
    private typealias Settings = EngineSession.CurvesSettings
    private typealias State = EngineSession.CurveState
    private typealias Point = EngineSession.CurvePoint

    /// Independently specified mixed state: every channel differs in kind,
    /// identity, point list and sample table, and channels keep data the
    /// active representation does not render.
    private var engineSettings: Settings {
        var settings = Settings()
        settings.trc = .nonlinear

        var value = State(kind: .smooth, identity: false, samples: Array(repeating: 0.25, count: 256))
        value.points = [Point(x: 0, y: 0), Point(x: 0.25, y: 0.5, kind: .corner),
                        Point(x: 0.25, y: 0.75), Point(x: 1, y: 1, kind: .corner)]
        settings.value = value

        var red = State(kind: .free, identity: true,
                        points: [Point(x: 0.5, y: 0.5, kind: .corner)], samples: [])
        red.samples = (0..<256).map { Double($0) / 255 }
        settings.red = red

        var green = State(kind: .free, identity: false, points: [], samples: [])
        green.samples = (0..<256).map { 1 - Double($0) / 255 }
        settings.green = green

        let blue = State(kind: .smooth, identity: true,
                         points: [Point(x: 0, y: 1), Point(x: 1, y: 0)],
                         samples: Array(repeating: 0.9, count: 256))
        settings.blue = blue

        let alpha = State(kind: .smooth, identity: false,
                          points: [Point(x: 0.1, y: 0.2), Point(x: 0.1, y: 0.8)],
                          samples: Array(repeating: 0.4, count: 256))
        settings.alpha = alpha
        return settings
    }

    private var fileValue: Value {
        func point(_ x: Double, _ y: Double, _ kind: Value.PointKind = .smooth) -> Value.Point {
            .init(x: x, y: y, kind: kind)
        }
        return Value(trc: .nonlinear,
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

    func testMixedFiveChannelSettingsBridgeBothWaysExactly() throws {
        let settings = engineSettings
        let value = try Value(settings)
        XCTAssertEqual(value, fileValue)
        XCTAssertEqual(try value.settings(), settings)
        XCTAssertEqual(try Value(try fileValue.settings()), fileValue)
    }

    func testIdentityIsPreservedIndependentlyOfPointsAndSamples() throws {
        for kind in [EngineSession.CurveKind.smooth, .free] {
            var state = State(kind: kind, identity: false)
            // Inactive representation still carries data that must survive.
            state.points = [Point(x: 0.3, y: 0.7, kind: .corner)]
            state.samples = Array(repeating: 0.6, count: 256)
            var settings = Settings()
            settings.blue = state
            let restored = try (try Value(settings)).settings()
            XCTAssertFalse(restored.blue.identity)
            XCTAssertEqual(restored.blue.points, state.points)
            XCTAssertEqual(restored.blue.samples, state.samples)
            // A non-identity bypass survives even when the tables are the
            // identity ramp, because it is stored state, not derived.
            state.identity = true
            settings.blue = state
            XCTAssertTrue(try (try Value(settings)).settings().blue.identity)
        }
    }

    func testInactivePointsAndSamplesRoundTripUnmodified() throws {
        let settings = engineSettings
        // Free-kind channels keep an inactive smooth point list; smooth-kind
        // channels keep a rendered sample table that can differ from what
        // their own point list would generate.
        XCTAssertEqual(settings.green.kind, .free)
        XCTAssertEqual(settings.green.points, [])
        let flat = try Value(settings)
        XCTAssertEqual(flat.green.points, [])
        XCTAssertEqual(flat.blue.samples, Array(repeating: 0.9, count: 256))
        XCTAssertEqual(try flat.settings().red.samples.count, 256)
    }

    func testUnknownTRCRefusesInsteadOfBridging() {
        var settings = engineSettings
        settings.trc = .unknown
        XCTAssertThrowsError(try Value(settings)) {
            XCTAssertTrue($0.localizedDescription.contains("transfer curve"), $0.localizedDescription)
        }
    }

    func testNonfiniteAndOutOfRangePointsReject() {
        for number in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            var settings = engineSettings
            settings.value.points = [Point(x: number, y: 0.5)]
            XCTAssertThrowsError(try Value(settings), "\(number)")
            settings.value.points = [Point(x: 0.5, y: number)]
            XCTAssertThrowsError(try Value(settings), "\(number)")
        }
    }

    func testUnorderedAndOverlongPointSequencesReject() {
        var settings = engineSettings
        settings.value.points = [Point(x: 0.8, y: 0), Point(x: 0.2, y: 1)]
        XCTAssertThrowsError(try Value(settings))
        settings.value.points = (0...65_536).map { Point(x: Double($0) / 65_536, y: 0) }
        XCTAssertThrowsError(try Value(settings))
        settings.value.points = (0..<65_536).map { Point(x: Double($0) / 65_536, y: 0) }
        XCTAssertNoThrow(try Value(settings))
    }

    func testInvalidSampleTablesReject() {
        for count in [0, 255, 257] {
            var settings = engineSettings
            settings.red.samples = Array(repeating: 0.5, count: count)
            XCTAssertThrowsError(try Value(settings), "\(count)")
        }
        for number in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            var settings = engineSettings
            settings.red.samples[99] = number
            XCTAssertThrowsError(try Value(settings), "\(number)")
        }
    }

    func testCallerBuiltValuesRevalidateOnTheWayOut() {
        var value = fileValue
        value = Value(trc: value.trc, value: value.value, red: value.red,
                      green: .init(kind: .smooth, identity: true,
                                   points: [.init(x: 1, y: 0, kind: .smooth), .init(x: 0, y: 1, kind: .corner)],
                                   samples: Array(repeating: 0.5, count: 256)),
                      blue: value.blue, alpha: value.alpha)
        XCTAssertThrowsError(try value.settings())
        value = Value(trc: value.trc, value: value.value, red: value.red,
                      green: .init(kind: .free, identity: false, points: [],
                                   samples: Array(repeating: 0.5, count: 255)),
                      blue: value.blue, alpha: value.alpha)
        XCTAssertThrowsError(try value.settings())
    }

    func testEveryOwnedTRCAndKindRoundTrips() throws {
        for trc in [EngineSession.ColorTRC.linear, .nonlinear, .perceptual] {
            for kind in [EngineSession.CurveKind.smooth, .free] {
                var settings = engineSettings
                settings.trc = trc
                settings.alpha = State(kind: kind, identity: kind == .smooth,
                                       points: [Point(x: 0.4, y: 0.6, kind: .corner)],
                                       samples: Array(repeating: 0.1, count: 256))
                XCTAssertEqual(try (try Value(settings)).settings(), settings)
            }
        }
    }
}
