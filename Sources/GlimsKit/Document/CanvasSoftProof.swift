import CoreGraphics
import CGlimsEngine
import Foundation

/// Immutable, window-owned display simulation. It never changes the image's
/// working profile or its saved simulation metadata.
struct CanvasSoftProof: Equatable, Sendable {
    let profileICC: Data
    let profileName: String
    let proofIntent: EngineSession.ProfileIntent
    let displayIntent: EngineSession.ProfileIntent
    let blackPointCompensation: Bool

    static let maximumICCBytes = 16 * 1024 * 1024

    init(profileICC: Data, profileName: String,
         proofIntent: EngineSession.ProfileIntent = .relativeColorimetric,
         displayIntent: EngineSession.ProfileIntent = .relativeColorimetric,
         blackPointCompensation: Bool = false) throws {
        guard (1...Self.maximumICCBytes).contains(profileICC.count) else {
            throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                message: "The proof profile must contain at most 16 MiB of ICC data.")
        }
        // Profile class/transform compatibility remains the native proofing
        // constructor's decision, including CMYK profiles Quartz can open.
        guard CGColorSpace(iccData: profileICC as CFData) != nil else {
            throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                message: "The selected file is not a usable ICC color profile.")
        }
        self.profileICC = profileICC
        self.profileName = profileName
        self.proofIntent = proofIntent
        self.displayIntent = displayIntent
        self.blackPointCompensation = blackPointCompensation
    }
}
