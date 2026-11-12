import Foundation

/// One native ink snapshot is shared by the two scalar adjustment routes.
enum InkAdjustmentKind: Equatable {
    case levels, curves

    var title: String { self == .levels ? "Levels" : "Curves" }

    func isSupported(by session: EngineSession) -> Bool {
        switch self {
        case .levels: return session.supportsInkLevelSnapshots
        case .curves: return session.supportsInkCurveSnapshots
        }
    }

    func begin(_ session: EngineSession, image: Int32, channel: Int32) throws -> UInt64 {
        switch self {
        case .levels: return try session.beginInkLevelsSnapshot(image, channel: channel)
        case .curves: return try session.beginInkCurvesSnapshot(image, channel: channel)
        }
    }

    func end(_ session: EngineSession, image: Int32, token: UInt64) throws {
        switch self {
        case .levels: try session.endInkLevelsSnapshot(image, token: token)
        case .curves: try session.endInkCurvesSnapshot(image, token: token)
        }
    }
}

enum InkAdjustmentSettings: Equatable {
    case levels(EngineSession.InkLevelsSettings)
    case curves(EngineSession.InkCurvesSettings)

    var kind: InkAdjustmentKind {
        switch self { case .levels: return .levels; case .curves: return .curves }
    }
    var isValid: Bool {
        switch self { case .levels(let value): return value.isValid; case .curves(let value): return value.isValid }
    }

    func render(_ session: EngineSession, image: Int32, token: UInt64) throws -> Int32 {
        switch self {
        case .levels(let value): return try session.renderInkLevelsSnapshot(image, token: token, settings: value)
        case .curves(let value): return try session.renderInkCurvesSnapshot(image, token: token, settings: value)
        }
    }

    func apply(_ session: EngineSession, image: Int32, token: UInt64) throws {
        switch self {
        case .levels(let value): try session.applyInkLevelsSnapshot(image, token: token, settings: value)
        case .curves(let value): try session.applyInkCurvesSnapshot(image, token: token, settings: value)
        }
    }
}

protocol InkPreviewSettings: Equatable {
    var isValid: Bool { get }
    var adjustment: InkAdjustmentSettings { get }
}

extension EngineSession.InkLevelsSettings: InkPreviewSettings {
    var adjustment: InkAdjustmentSettings { .levels(self) }
}

extension EngineSession.InkCurvesSettings: InkPreviewSettings {
    var adjustment: InkAdjustmentSettings { .curves(self) }
}
