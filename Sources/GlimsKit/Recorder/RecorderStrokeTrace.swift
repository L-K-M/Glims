import Foundation

/// Owned V1 samples from a completed gesture. Batch boundaries are retained;
/// they describe accepted native calls, not reconstructed pointer history.
struct RecorderStrokeTrace: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        let x, y, pressure, xTilt, yTilt: Double
        let timeMilliseconds: UInt32

        init(x: Double, y: Double, pressure: Double, xTilt: Double, yTilt: Double,
             timeMilliseconds: UInt32) throws {
            guard (-524_288...524_288).contains(x), (-524_288...524_288).contains(y),
                  (0...1).contains(pressure), (-1...1).contains(xTilt), (-1...1).contains(yTilt) else {
                throw RecorderStrokeAccumulator.Failure.invalidPoint
            }
            self.x = x
            self.y = y
            self.pressure = pressure
            self.xTilt = xTilt
            self.yTilt = yTilt
            self.timeMilliseconds = timeMilliseconds
        }
    }

    let first: Point
    let batches: [[Point]]
}

/// A single input-queue accumulator. It retains only successfully accepted
/// batches, and publishes one whole stroke or the first refusal at end.
struct RecorderStrokeAccumulator {
    enum Failure: LocalizedError, Equatable {
        case invalidPoint, tooManyPoints, refused(String)

        var errorDescription: String? {
            switch self {
            case .invalidPoint: return "A stroke sample is outside the supported recording range."
            case .tooManyPoints: return "The stroke exceeds the recording's sample limit."
            case .refused(let reason): return reason
            }
        }
    }

    static let maximumPoints = 65_536
    private let first: RecorderStrokeTrace.Point
    private var batches: [[RecorderStrokeTrace.Point]] = []
    private var count = 1
    private var failure: Failure?
    private var finished = false

    init(first: RecorderStrokeTrace.Point) {
        self.first = first
    }

    mutating func appendAccepted(_ points: [RecorderStrokeTrace.Point]) {
        guard !finished, failure == nil, !points.isEmpty else { return }
        guard points.count <= Self.maximumPoints - count else {
            refuse(.tooManyPoints)
            return
        }
        count += points.count
        batches.append(points)
    }

    mutating func refuse(_ reason: Failure) {
        guard !finished, failure == nil else { return }
        failure = reason
        batches.removeAll()
    }

    mutating func finish() -> Result<RecorderStrokeTrace, Failure>? {
        guard !finished else { return nil }
        finished = true
        if let failure { return .failure(failure) }
        let trace = RecorderStrokeTrace(first: first, batches: batches)
        batches.removeAll()
        return .success(trace)
    }
}
