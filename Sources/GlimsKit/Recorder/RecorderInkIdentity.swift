import Foundation

extension RecorderInkIdentity {
    init(_ native: EngineSession.InkChannelIdentity) throws {
        let mode: Mode
        switch native.colorMode {
        case .cmyk: mode = .cmyk
        case .multichannel: mode = .multichannel
        default: throw RecorderFileError.invalid("The target is not a native ink channel.")
        }
        let role: Role
        switch native.role {
        case .unspecified: role = .unspecified
        case .cyan: role = .cyan
        case .magenta: role = .magenta
        case .yellow: role = .yellow
        case .black: role = .black
        }
        self.init(mode: mode, role: role, uuid: native.uuid)
        guard isValid else { throw RecorderFileError.invalid("The ink channel identity is invalid.") }
    }

    /// The caller supplies an explicit destination choice. This only validates
    /// its numeric ink role; it never discovers or automatically selects it.
    func permitsExplicitBinding(to destination: RecorderInkIdentity) -> Bool {
        isValid && destination.isValid && mode == destination.mode && role == destination.role
    }

    /// Used only with an image-owned runtime channel after capture or explicit
    /// installation. UUID equality alone cannot authorize cross-image binding.
    func matchesInOwningDocument(_ current: RecorderInkIdentity) -> Bool {
        permitsExplicitBinding(to: current) && uuid == current.uuid
    }

    var targetTitle: String {
        switch role {
        case .cyan: return "CMYK Cyan ink"
        case .magenta: return "CMYK Magenta ink"
        case .yellow: return "CMYK Yellow ink"
        case .black: return "CMYK Black ink"
        case .unspecified: return "Multichannel ink"
        }
    }
}
