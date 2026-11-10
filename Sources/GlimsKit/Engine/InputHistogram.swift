import Foundation

extension EngineSession {
    enum HistogramChannel: UInt32, CaseIterable {
        case value = 1, red = 2, green = 4, blue = 8, alpha = 16, luminance = 32
        var title: String {
            switch self {
            case .value: return "Value"
            case .red: return "Red"
            case .green: return "Green"
            case .blue: return "Blue"
            case .alpha: return "Alpha"
            case .luminance: return "Luminance"
            }
        }
    }
    struct InputHistogram: Equatable {
        var trc: ColorTRC
        var binCount: Int
        var channels: [HistogramChannel: [Double]]
        var isValid: Bool {
            trc != .unknown && (0...4096).contains(binCount) && channels[.value] != nil &&
                channels.values.allSatisfy { bins in
                    bins.count == binCount && bins.allSatisfy(\.isFinite)
                }
        }
        subscript(_ channel: HistogramChannel) -> [Double]? { channels[channel] }
    }
}
