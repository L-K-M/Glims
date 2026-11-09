import Foundation

extension EngineSession {
    enum CurveChannel: UInt32, CaseIterable {
        case value = 1, red, green, blue, alpha
        var title: String { ["Value", "Red", "Green", "Blue", "Alpha"][Int(rawValue) - 1] }
    }
    enum CurveKind: UInt32 { case smooth = 1, free }
    enum CurvePointKind: UInt32 { case smooth = 1, corner }
    struct CurvePoint: Equatable {
        var x: Double
        var y: Double
        var kind: CurvePointKind = .smooth
        var isValid: Bool { x.isFinite && y.isFinite && (0...1).contains(x) && (0...1).contains(y) }
    }
    struct CurveState: Equatable {
        var kind: CurveKind = .smooth
        var identity = true
        var points = [CurvePoint(x: 0, y: 0), CurvePoint(x: 1, y: 1)]
        var samples = (0..<256).map { Double($0) / 255 }
        var isValid: Bool {
            Self.validPoints(points) && samples.count == 256 &&
                samples.allSatisfy { $0.isFinite && (0...1).contains($0) }
        }
        static func validPoints(_ points: [CurvePoint]) -> Bool {
            points.count <= 65_536 && points.allSatisfy(\.isValid) &&
                zip(points, points.dropFirst()).allSatisfy { $0.x <= $1.x }
        }
    }
    struct CurvesSettings: Equatable {
        var trc: ColorTRC = .perceptual
        var value = CurveState()
        var red = CurveState()
        var green = CurveState()
        var blue = CurveState()
        var alpha = CurveState()
        subscript(channel: CurveChannel) -> CurveState {
            get {
                switch channel {
                case .value: return value
                case .red: return red
                case .green: return green
                case .blue: return blue
                case .alpha: return alpha
                }
            }
            set {
                switch channel {
                case .value: value = newValue
                case .red: red = newValue
                case .green: green = newValue
                case .blue: blue = newValue
                case .alpha: alpha = newValue
                }
            }
        }
        var isValid: Bool {
            trc != .unknown && CurveChannel.allCases.allSatisfy { self[$0].isValid }
        }
    }
    enum CurveEdit: Equatable {
        case smooth(channel: CurveChannel, points: [CurvePoint])
        case free(channel: CurveChannel, samples: [Double])
        case reset(channel: CurveChannel)
        var channel: CurveChannel {
            switch self {
            case .smooth(let channel, _), .free(let channel, _), .reset(let channel): return channel
            }
        }
        var isValid: Bool {
            switch self {
            case .smooth(_, let points): return CurveState.validPoints(points)
            case .free(_, let samples):
                return samples.count == 256 && samples.allSatisfy { $0.isFinite && (0...1).contains($0) }
            case .reset: return true
            }
        }
    }
}
