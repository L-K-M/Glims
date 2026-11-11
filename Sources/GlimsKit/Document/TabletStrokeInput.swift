import Foundation

/// Owned press-time capability facts and normalization; no event is retained.
enum TabletStrokeInput {
    struct Capabilities: Equatable {
        let rotation, tangentialPressure: Bool
        var hasOptionalAxes: Bool { rotation || tangentialPressure }
    }

    struct Capture: Equatable {
        let deviceID: UInt
        let capabilities: Capabilities
    }

    static func capture(deviceID: UInt?, devices: [UInt: Capabilities]) -> Capture? {
        guard let deviceID, let capabilities = devices[deviceID], capabilities.hasOptionalAxes else { return nil }
        return Capture(deviceID: deviceID, capabilities: capabilities)
    }

    static func milliseconds(_ seconds: Double) -> UInt32? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let scaled = seconds * 1000
        guard scaled.isFinite else { return nil }
        return UInt32(exactly: floor(scaled).truncatingRemainder(dividingBy: 4_294_967_296))
    }

    static func rotationTurns(_ degrees: Double) -> Double? {
        guard degrees.isFinite else { return nil }
        let turns = (degrees / 360).truncatingRemainder(dividingBy: 1)
        let wrapped = turns < 0 ? turns + 1 : turns
        // Tiny negative turns can round to exactly one when adding one.
        return wrapped == 1 || wrapped == 0 ? 0 : wrapped
    }

    static func sample(point: EngineSession.StrokePoint, capture: Capture, deviceID: UInt?,
                       rotationDegrees: Double?, tangentialPressure: Double?) -> EngineSession.StrokeSampleV2? {
        var rotation: Double?, tangent: Double?
        if deviceID == capture.deviceID {
            if capture.capabilities.rotation {
                guard let rotationDegrees, let turns = rotationTurns(rotationDegrees) else { return nil }
                rotation = turns
            }
            if capture.capabilities.tangentialPressure {
                guard let tangentialPressure else { return nil }
                tangent = tangentialPressure
            }
        }
        let sample = EngineSession.StrokeSampleV2(point: point, rotationTurns: rotation, tangentialPressure: tangent)
        return sample.isValid ? sample : nil
    }
}
