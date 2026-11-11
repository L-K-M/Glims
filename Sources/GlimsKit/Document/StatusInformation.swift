import Foundation

/// Measurements of this window's completed canvas tiles, never the native
/// image's allocation or the process's memory use.
struct CanvasRenderMetrics: Equatable {
    let cachedPixelBytes: UInt64
    let lastTileSeconds: TimeInterval?

    init(cachedPixelBytes: UInt64 = 0, lastTileSeconds: TimeInterval? = nil) {
        self.cachedPixelBytes = cachedPixelBytes
        self.lastTileSeconds = lastTileSeconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    static func pixelPayloadBytes(bytesPerRow: Int, height: Int) -> UInt64 {
        UInt64(bytesPerRow) * UInt64(height)
    }

    static func elapsedSeconds(start: UInt64, end: UInt64) -> TimeInterval? {
        guard end >= start else { return nil }
        return TimeInterval(end - start) / 1_000_000_000
    }
}

enum StatusInformationChoice: Int, CaseIterable {
    case dimensions, workingProfile, precision, canvasCacheMemory, lastTileTime

    var label: String {
        switch self {
        case .dimensions: return "Dimensions"
        case .workingProfile: return "Working profile"
        case .precision: return "Precision"
        case .canvasCacheMemory: return "Canvas cache"
        case .lastTileTime: return "Last tile"
        }
    }

    var help: String {
        switch self {
        case .dimensions: return "The image's width and height in pixels."
        case .workingProfile: return "The working image's effective color profile."
        case .precision: return "The working image's component precision and transfer curve."
        case .canvasCacheMemory:
            return "Cached canvas tile pixel payload only: bytes per row × height. Excludes engine and process memory."
        case .lastTileTime:
            return "Elapsed render time of the last successful tile accepted for this canvas generation."
        }
    }
}

/// Supplied from document and canvas caches. Selecting a field never reads
/// the engine, starts work or changes the image.
struct StatusInformationSnapshot: Equatable {
    var width = 0
    var height = 0
    var profileLabel = ""
    var precisionLabel = ""
    var renderMetrics = CanvasRenderMetrics()

    func value(for choice: StatusInformationChoice) -> String {
        switch choice {
        case .dimensions:
            return width > 0 && height > 0 ? "\(width) × \(height) px" : "Unavailable"
        case .workingProfile:
            return profileLabel.isEmpty ? "Unavailable" : profileLabel
        case .precision:
            return precisionLabel.isEmpty ? "Unavailable" : precisionLabel
        case .canvasCacheMemory:
            let bytes = renderMetrics.cachedPixelBytes
            if bytes < 1_024 { return "\(bytes) B" }
            if bytes < 1_048_576 { return String(format: "%.1f KiB", Double(bytes) / 1_024) }
            return String(format: "%.1f MiB", Double(bytes) / 1_048_576)
        case .lastTileTime:
            guard let seconds = renderMetrics.lastTileSeconds else { return "Unavailable" }
            return seconds < 1 ? String(format: "%.2f ms", seconds * 1_000)
                : String(format: "%.2f s", seconds)
        }
    }

    func title(for choice: StatusInformationChoice) -> String {
        "\(choice.label): \(value(for: choice))"
    }
}
