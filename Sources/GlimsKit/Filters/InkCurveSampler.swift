import Foundation

/// Port of GIMP's smooth curve sampling for ink edits.
///
/// Deliberately ports GPL behavior from
/// `_engine/src/GIMP_3_2_8/gimp/app/core/gimpcurve.c` (commit 7addd2b77efb798bbdc4d2fb082e786a48478ced),
/// functions `gimp_curve_calculate` and `gimp_curve_plot`.
enum InkCurveSampler {
    private static let sampleCount = 256
    private static let epsilon = 1e-6
    private static let maxPointCount = 256

    enum Error: Swift.Error, Equatable, CustomStringConvertible {
        case invalidPreviousSamples
        case invalidPointCount(Int)
        case invalidPoint(index: Int)
        case nondecreasingX(previousIndex: Int, index: Int)

        var description: String {
            switch self {
            case .invalidPreviousSamples:
                return "Previous samples must contain exactly 256 finite values in [0, 1]."
            case .invalidPointCount(let count):
                return "Curve point count \(count) must be between 0 and 256."
            case .invalidPoint(let index):
                return "Curve point at index \(index) must have finite coordinates in [0, 1]."
            case .nondecreasingX(let previousIndex, let index):
                return "Curve point x at index \(index) must be >= point x at index \(previousIndex)."
            }
        }
    }

    static func samples(points: [EngineSession.CurvePoint],
                        previousSamples: [Double]) throws -> [Double] {
        try validate(previousSamples: previousSamples)
        try validate(points: points)

        if points.isEmpty {
            return previousSamples
        }
        if points.count == 1 {
            return Array(repeating: clamp(points[0].y), count: sampleCount)
        }
        if isCanonicalIdentity(points) {
            return (0..<sampleCount).map { Double($0) / Double(sampleCount - 1) }
        }

        var samples = Array(repeating: 0.0, count: sampleCount)

        let first = points[0]
        let firstBoundary = gimpRound(first.x * Double(sampleCount - 1))
        if firstBoundary > 0 {
            for index in 0..<firstBoundary {
                samples[index] = first.y
            }
        }

        let last = points[points.count - 1]
        let lastBoundary = gimpRound(last.x * Double(sampleCount - 1))
        if lastBoundary < sampleCount {
            for index in lastBoundary..<sampleCount {
                samples[index] = last.y
            }
        }

        for index in 0..<(points.count - 1) {
            var p1 = max(index - 1, 0)
            let p2 = index
            let p3 = index + 1
            var p4 = min(index + 2, points.count - 1)

            if points[p2].kind == .corner {
                p1 = p2
            }
            if points[p3].kind == .corner {
                p4 = p3
            }

            plot(points: points, p1: p1, p2: p2, p3: p3, p4: p4, into: &samples)
        }

        for point in points {
            let index = gimpRound(point.x * Double(sampleCount - 1))
            if index >= 0 && index < sampleCount {
                samples[index] = point.y
            }
        }

        for index in samples.indices {
            samples[index] = clamp(samples[index])
        }

        return samples
    }

    private static func validate(previousSamples: [Double]) throws {
        guard previousSamples.count == sampleCount else { throw Error.invalidPreviousSamples }
        guard previousSamples.allSatisfy({ $0.isFinite && $0 >= 0.0 && $0 <= 1.0 }) else {
            throw Error.invalidPreviousSamples
        }
    }

    private static func validate(points: [EngineSession.CurvePoint]) throws {
        guard points.count <= maxPointCount else { throw Error.invalidPointCount(points.count) }
        var previousX: Double?
        for (index, point) in points.enumerated() {
            guard point.isValid else { throw Error.invalidPoint(index: index) }
            if let previousX, point.x < previousX {
                throw Error.nondecreasingX(previousIndex: index - 1, index: index)
            }
            previousX = point.x
        }
    }

    private static func isCanonicalIdentity(_ points: [EngineSession.CurvePoint]) -> Bool {
        guard points.count == 2 else { return false }
        let first = points[0]
        let second = points[1]
        return first.kind == .smooth && second.kind == .smooth
            && first.x == 0.0 && first.y == 0.0
            && second.x == 1.0 && second.y == 1.0
    }

    private static func plot(points: [EngineSession.CurvePoint],
                             p1: Int,
                             p2: Int,
                             p3: Int,
                             p4: Int,
                             into samples: inout [Double]) {
        let x0 = points[p2].x
        let y0 = points[p2].y
        let x3 = points[p3].x
        let y3 = points[p3].y

        let dx = x3 - x0
        let dy = y3 - y0

        if dx <= epsilon {
            let index = gimpRound(x0 * Double(sampleCount - 1))
            if index >= 0 && index < sampleCount {
                samples[index] = y3
            }
            return
        }

        let y1: Double
        let y2: Double

        if p1 == p2 && p3 == p4 {
            y1 = y0 + dy / 3.0
            y2 = y0 + dy * 2.0 / 3.0
        } else if p1 == p2 && p3 != p4 {
            let slope = (points[p4].y - y0) / (points[p4].x - x0)
            y2 = y3 - slope * dx / 3.0
            y1 = y0 + (y2 - y0) / 2.0
        } else if p1 != p2 && p3 == p4 {
            let slope = (y3 - points[p1].y) / (x3 - points[p1].x)
            y1 = y0 + slope * dx / 3.0
            y2 = y3 + (y1 - y3) / 2.0
        } else {
            let leftSlope = (y3 - points[p1].y) / (x3 - points[p1].x)
            y1 = y0 + leftSlope * dx / 3.0
            let rightSlope = (points[p4].y - y0) / (points[p4].x - x0)
            y2 = y3 - rightSlope * dx / 3.0
        }

        let count = gimpRound(dx * Double(sampleCount - 1))
        if count < 0 { return }

        for step in 0...count {
            let t = Double(step) / dx / Double(sampleCount - 1)
            let oneMinusT = 1.0 - t
            let y = y0 * oneMinusT * oneMinusT * oneMinusT
                + 3.0 * y1 * oneMinusT * oneMinusT * t
                + 3.0 * y2 * oneMinusT * t * t
                + y3 * t * t * t
            let index = step + gimpRound(x0 * Double(sampleCount - 1))
            if index >= 0 && index < sampleCount {
                samples[index] = clamp(y)
            }
        }
    }

    private static func gimpRound(_ value: Double) -> Int {
        Int(floor(value + 0.5))
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0.0), 1.0)
    }
}
