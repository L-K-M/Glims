import Foundation

/// A captured physical axis has one preview transaction, with typed settings.
enum LabAdjustmentKind: Equatable {
    case levels, curves
    var title: String { self == .levels ? "Levels" : "Curves" }
    func isSupported(by session: EngineSession) -> Bool {
        switch self {
        case .levels: return session.supportsLabLevelSnapshots
        case .curves: return session.supportsLabCurveSnapshots
        }
    }
    func begin(_ session: EngineSession, image: Int32, axis: EngineSession.LabAxis) throws -> UInt64 {
        switch self {
        case .levels: return try session.beginLabLevelsSnapshot(image, axis: axis)
        case .curves: return try session.beginLabCurvesSnapshot(image, axis: axis)
        }
    }
    func end(_ session: EngineSession, image: Int32, token: UInt64) throws {
        switch self {
        case .levels: try session.endLabLevelsSnapshot(image, token: token)
        case .curves: try session.endLabCurvesSnapshot(image, token: token)
        }
    }
}

enum LabAdjustmentSettings: Equatable {
    case levels(EngineSession.LabLevelsSettings)
    case curves(EngineSession.LabCurvesSettings)
    var kind: LabAdjustmentKind {
        switch self { case .levels: return .levels; case .curves: return .curves }
    }
    var isValid: Bool {
        switch self { case .levels(let value): return value.isValid; case .curves(let value): return value.isValid }
    }
    var command: SemanticImageCommand {
        switch self { case .levels(let value): return .applyLabLevels(value); case .curves(let value): return .applyLabCurves(value) }
    }
    func render(_ session: EngineSession, image: Int32, token: UInt64, axis: EngineSession.LabAxis) throws -> Int32 {
        switch self {
        case .levels(let value): return try session.renderLabLevelsSnapshot(image, token: token, axis: axis, settings: value)
        case .curves(let value): return try session.renderLabCurvesSnapshot(image, token: token, axis: axis, settings: value)
        }
    }
    func apply(_ session: EngineSession, image: Int32, token: UInt64, axis: EngineSession.LabAxis) throws {
        switch self {
        case .levels(let value): try session.applyLabLevelsSnapshot(image, token: token, axis: axis, settings: value)
        case .curves(let value): try session.applyLabCurvesSnapshot(image, token: token, axis: axis, settings: value)
        }
    }
}

protocol LabPreviewSettings: ComponentPreviewSettings {
    var adjustment: LabAdjustmentSettings { get }
}
extension EngineSession.LabLevelsSettings: LabPreviewSettings {
    var adjustment: LabAdjustmentSettings { .levels(self) }
}
extension EngineSession.LabCurvesSettings: LabPreviewSettings {
    var adjustment: LabAdjustmentSettings { .curves(self) }
}
