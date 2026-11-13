import Foundation

/// Physical Lab identity is document-scoped. A matching UUID never supplies
/// permission to bind another image automatically.
struct RecorderLabIdentity: Equatable {
    enum Role: String, CaseIterable { case lightness, a, b }
    enum Precision: String, CaseIterable { case u8, u16, float }
    let role: Role
    let precision: Precision
    let uuid: UUID

    init(role: Role, precision: Precision, uuid: UUID) {
        self.role = role; self.precision = precision; self.uuid = uuid
    }

    init(axis: EngineSession.LabAxis, component: EngineSession.ColorComponent) throws {
        switch axis.role {
        case .lightness: role = .lightness
        case .a: role = .a
        case .b: role = .b
        }
        switch component {
        case .u8: precision = .u8
        case .u16: precision = .u16
        case .float: precision = .float
        default: throw RecorderFileError.invalid("This Lab precision cannot be recorded.")
        }
        uuid = axis.uuid
        guard isValid else { throw RecorderFileError.invalid("The Lab channel identity is invalid.") }
    }

    var isValid: Bool {
        uuid != UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }

    var nativeRole: EngineSession.LabAxisRole {
        switch role { case .lightness: return .lightness; case .a: return .a; case .b: return .b }
    }

    func permitsExplicitBinding(to destination: Self) -> Bool {
        isValid && destination.isValid && role == destination.role && precision == destination.precision
    }

    func matchesInOwningDocument(_ current: Self) -> Bool {
        permitsExplicitBinding(to: current) && uuid == current.uuid
    }

    var targetTitle: String { "Lab \(nativeRole.title) (\(precision.rawValue))" }
}
