import XCTest
@testable import GlimsKit

final class TabletStrokeInputTests: XCTestCase {
    private let point = EngineSession.StrokePoint(x: 12, y: 16, pressure: 0.75, xTilt: 0.25, yTilt: -0.5, timeMilliseconds: 123)
    private let both = TabletStrokeInput.Capabilities(rotation: true, tangentialPressure: true)

    func testClockUsesCheckedFloorAndUnsignedWrap() {
        XCTAssertEqual(TabletStrokeInput.milliseconds(0), 0)
        XCTAssertEqual(TabletStrokeInput.milliseconds(10.0625), 10_062)
        XCTAssertEqual(TabletStrokeInput.milliseconds(4_294_968), 704)
        XCTAssertEqual(TabletStrokeInput.milliseconds(8_589_936), 1408)
    }

    func testMalformedClockNeverConvertsThroughAnInt() {
        for time in [-1, Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude] {
            XCTAssertNil(TabletStrokeInput.milliseconds(time))
        }
        XCTAssertNotNil(TabletStrokeInput.milliseconds(1e100))
    }

    func testRotationHasLiteralWrappedTurns() {
        for (degrees, turns) in [(0.0, 0.0), (90, 0.25), (180, 0.5), (270, 0.75), (360, 0), (-90, 0.75), (-720, 0)] {
            XCTAssertEqual(TabletStrokeInput.rotationTurns(degrees), turns)
        }
        for value in [Double.nan, .infinity, -.infinity] { XCTAssertNil(TabletStrokeInput.rotationTurns(value)) }
        XCTAssertEqual(TabletStrokeInput.rotationTurns(-Double.leastNormalMagnitude), 0)
    }

    func testOnlyMatchingAdvertisedCapabilitiesChooseV2() {
        let devices: [UInt: TabletStrokeInput.Capabilities] = [42: both, 43: .init(rotation: false, tangentialPressure: false)]
        XCTAssertEqual(TabletStrokeInput.capture(deviceID: 42, devices: devices)?.deviceID, 42)
        XCTAssertNil(TabletStrokeInput.capture(deviceID: nil, devices: devices))
        XCTAssertNil(TabletStrokeInput.capture(deviceID: 44, devices: devices))
        XCTAssertNil(TabletStrokeInput.capture(deviceID: 43, devices: devices))
    }

    func testPressCaptureSurvivesLaterCacheReplacementAndClear() throws {
        var devices: [UInt: TabletStrokeInput.Capabilities] = [42: both]
        let capture = try XCTUnwrap(TabletStrokeInput.capture(deviceID: 42, devices: devices))
        devices[42] = .init(rotation: false, tangentialPressure: false)
        devices.removeAll()
        XCTAssertNil(TabletStrokeInput.capture(deviceID: 42, devices: devices))
        XCTAssertEqual(capture.capabilities, both)
        XCTAssertEqual(TabletStrokeInput.sample(point: point, capture: capture, deviceID: 42,
            rotationDegrees: 90, tangentialPressure: -1)?.rotationTurns, 0.25)
    }

    func testSignedTangentIsOwnedWithoutInventedWheelCalibration() throws {
        let capture = TabletStrokeInput.Capture(deviceID: 42, capabilities: both)
        for tangent in [-1.0, 0, 1] {
            let sample = try XCTUnwrap(TabletStrokeInput.sample(point: point, capture: capture, deviceID: 42,
                rotationDegrees: 270, tangentialPressure: tangent))
            XCTAssertEqual(sample.point, point)
            XCTAssertEqual(sample.rotationTurns, 0.75)
            XCTAssertEqual(sample.tangentialPressure, tangent)
        }
    }

    func testWrongDeviceAndMouseResetOptionalAxesPerSample() throws {
        let capture = TabletStrokeInput.Capture(deviceID: 42, capabilities: both)
        for device: UInt? in [nil, 43] {
            let sample = try XCTUnwrap(TabletStrokeInput.sample(point: point, capture: capture, deviceID: device,
                rotationDegrees: .nan, tangentialPressure: .nan))
            XCTAssertNil(sample.rotationTurns); XCTAssertNil(sample.tangentialPressure)
            XCTAssertEqual(sample.point, point)
        }
    }

    func testEachAxisIsIndependentAndRequiredOnlyWhenCaptured() {
        let rotation = TabletStrokeInput.Capture(deviceID: 42, capabilities: .init(rotation: true, tangentialPressure: false))
        let tangent = TabletStrokeInput.Capture(deviceID: 42, capabilities: .init(rotation: false, tangentialPressure: true))
        XCTAssertEqual(TabletStrokeInput.sample(point: point, capture: rotation, deviceID: 42,
            rotationDegrees: -90, tangentialPressure: nil)?.rotationTurns, 0.75)
        XCTAssertNil(TabletStrokeInput.sample(point: point, capture: rotation, deviceID: 42,
            rotationDegrees: nil, tangentialPressure: 0))
        XCTAssertEqual(TabletStrokeInput.sample(point: point, capture: tangent, deviceID: 42,
            rotationDegrees: nil, tangentialPressure: -0.5)?.tangentialPressure, -0.5)
        XCTAssertNil(TabletStrokeInput.sample(point: point, capture: tangent, deviceID: 42,
            rotationDegrees: 0, tangentialPressure: nil))
    }

    func testV2StrictRangesAndNonfiniteFieldsRefuseBeforePacking() {
        let valid = EngineSession.StrokeSampleV2(point: point, rotationTurns: 0.25, tangentialPressure: -1)
        XCTAssertTrue(valid.isValid)
        let changes: [(inout EngineSession.StrokePoint) -> Void] = [
            { $0.x = .nan }, { $0.y = .infinity }, { $0.pressure = .nan },
            { $0.xTilt = .nan }, { $0.yTilt = .nan }, { $0.x = 524_289 },
            { $0.y = -524_289 }, { $0.pressure = -0.1 }, { $0.pressure = 1.1 },
            { $0.xTilt = -1.1 }, { $0.yTilt = 1.1 }
        ]
        for change in changes {
            var bad = point; change(&bad)
            XCTAssertFalse(EngineSession.StrokeSampleV2(point: bad, rotationTurns: nil, tangentialPressure: nil).isValid)
        }
        for rotation in [-0.1, 1, Double.nan, .infinity] {
            XCTAssertFalse(EngineSession.StrokeSampleV2(point: point, rotationTurns: rotation, tangentialPressure: nil).isValid)
        }
        for tangent in [-1.1, 1.1, Double.nan, .infinity] {
            XCTAssertFalse(EngineSession.StrokeSampleV2(point: point, rotationTurns: nil, tangentialPressure: tangent).isValid)
        }
    }

    func testInclusiveCoordinateAndBaseAxisEndpoints() {
        let edge = EngineSession.StrokePoint(x: -524_288, y: 524_288, pressure: 0, xTilt: -1, yTilt: 1, timeMilliseconds: .max)
        XCTAssertTrue(EngineSession.StrokeSampleV2(point: edge, rotationTurns: 0, tangentialPressure: 1).isValid)
        XCTAssertEqual(EngineSession.StrokePoint(x: 0, y: 0).pressure, 1)
    }
}
