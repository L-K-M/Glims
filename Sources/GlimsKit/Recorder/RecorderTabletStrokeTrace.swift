import Foundation

/// Owned V2 tablet samples from a completed gesture. Batch boundaries are
/// retained exactly as accepted native calls; no pointer history is rebuilt.
struct RecorderTabletStrokeTrace: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        let x, y, pressure, xTilt, yTilt: Double
        let timeMilliseconds: UInt32
        let rotationTurns: Double?
        let tangentialPressure: Double?

        init(
            x: Double,
            y: Double,
            pressure: Double,
            xTilt: Double,
            yTilt: Double,
            timeMilliseconds: UInt32,
            rotationTurns: Double? = nil,
            tangentialPressure: Double? = nil
        ) throws {
            let finiteScalars = [x, y, pressure, xTilt, yTilt]
            guard finiteScalars.allSatisfy(\.isFinite),
                  (-524_288...524_288).contains(x),
                  (-524_288...524_288).contains(y),
                  (0...1).contains(pressure),
                  (-1...1).contains(xTilt),
                  (-1...1).contains(yTilt)
            else {
                throw RecorderTabletStrokeAccumulator.Failure.invalidSample
            }

            if let rotationTurns {
                guard rotationTurns.isFinite, rotationTurns >= 0, rotationTurns < 1 else {
                    throw RecorderTabletStrokeAccumulator.Failure.invalidSample
                }
            }
            if let tangentialPressure {
                guard tangentialPressure.isFinite, (-1...1).contains(tangentialPressure) else {
                    throw RecorderTabletStrokeAccumulator.Failure.invalidSample
                }
            }

            self.x = x
            self.y = y
            self.pressure = pressure
            self.xTilt = xTilt
            self.yTilt = yTilt
            self.timeMilliseconds = timeMilliseconds
            self.rotationTurns = rotationTurns
            self.tangentialPressure = tangentialPressure
        }

        init(native sample: EngineSession.StrokeSampleV2) throws {
            try self.init(
                x: sample.point.x,
                y: sample.point.y,
                pressure: sample.point.pressure,
                xTilt: sample.point.xTilt,
                yTilt: sample.point.yTilt,
                timeMilliseconds: sample.point.timeMilliseconds,
                rotationTurns: sample.rotationTurns,
                tangentialPressure: sample.tangentialPressure
            )
        }

        var nativeSample: EngineSession.StrokeSampleV2 {
            EngineSession.StrokeSampleV2(
                point: .init(
                    x: x,
                    y: y,
                    pressure: pressure,
                    xTilt: xTilt,
                    yTilt: yTilt,
                    timeMilliseconds: timeMilliseconds
                ),
                rotationTurns: rotationTurns,
                tangentialPressure: tangentialPressure
            )
        }
    }

    let first: Point
    let batches: [[Point]]
}

/// A single tablet stroke accumulator. It keeps only successfully accepted
/// batches and publishes one whole trace or the first refusal at finish.
struct RecorderTabletStrokeAccumulator {
    enum Failure: LocalizedError, Equatable, Sendable {
        case invalidSample
        case invalidTimestampOrder
        case tooManyPoints
        case refused(String)

        var errorDescription: String? {
            switch self {
            case .invalidSample:
                return "A tablet stroke sample is outside the supported recording range."
            case .invalidTimestampOrder:
                return "Tablet stroke samples are not in a safe timestamp order."
            case .tooManyPoints:
                return "The tablet stroke exceeds the recording's sample limit."
            case .refused(let reason):
                return reason
            }
        }
    }

    static let maximumPoints = 65_536

    private let first: RecorderTabletStrokeTrace.Point
    private var batches: [[RecorderTabletStrokeTrace.Point]] = []
    private var count = 1
    private var lastTimeMilliseconds: UInt32
    private var failure: Failure?
    private var finished = false

    init(first: RecorderTabletStrokeTrace.Point) {
        self.first = first
        self.lastTimeMilliseconds = first.timeMilliseconds
    }

    mutating func appendAccepted(_ points: [RecorderTabletStrokeTrace.Point]) {
        guard !finished, failure == nil, !points.isEmpty else { return }
        guard points.count <= Self.maximumPoints - count else {
            refuse(.tooManyPoints)
            return
        }

        var previous = lastTimeMilliseconds
        for point in points {
            let delta = point.timeMilliseconds &- previous
            guard delta <= 0x7fff_ffff else {
                refuse(.invalidTimestampOrder)
                return
            }
            previous = point.timeMilliseconds
        }

        count += points.count
        lastTimeMilliseconds = previous
        batches.append(points)
    }

    mutating func refuse(_ reason: Failure) {
        guard !finished, failure == nil else { return }
        failure = reason
        batches.removeAll()
    }

    mutating func finish() -> Result<RecorderTabletStrokeTrace, Failure>? {
        guard !finished else { return nil }
        finished = true
        if let failure { return .failure(failure) }
        let trace = RecorderTabletStrokeTrace(first: first, batches: batches)
        batches.removeAll()
        return .success(trace)
    }
}
