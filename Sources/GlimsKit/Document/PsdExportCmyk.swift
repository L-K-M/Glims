import AppKit
import CoreGraphics
import Foundation

/// The PSD output's color encoding. "Document" keeps the document's RGB or
/// grayscale pixels; "CMYK" converts them for output only — editing stays RGB.
enum PsdOutputColor: String, CaseIterable, Equatable, Sendable {
    case document
    case cmyk

    var title: String {
        switch self {
        case .document: return "Document RGB/Grayscale"
        case .cmyk: return "CMYK"
        }
    }

    var explanation: String {
        switch self {
        case .document:
            return "Exports the document's RGB or grayscale pixels."
        case .cmyk:
            return "Converts an RGB image to CMYK for this PSD using the chosen profile (relative colorimetric with black-point compensation). Output is 8-bit for 8-bit images and 16-bit otherwise. Editing stays RGB."
        }
    }
}

/// A CMYK destination profile captured for one export choice: the name the user
/// read and the exact ICC bytes the export will embed. Immutable value data, so
/// a successful export, Repeat Export and Batch keep these bytes even if the
/// installed profile later changes or disappears.
struct PsdCmykProfile: Equatable, Sendable {
    static let minimumICCByteCount = 1
    static let maximumICCByteCount = 4 * 1024 * 1024

    let displayName: String
    let iccData: Data

    init(displayName: String, iccData: Data) throws {
        let trimmed = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.missingProfile }
        guard Self.isValidICCData(iccData) else { throw ValidationError.invalidProfile }
        self.displayName = trimmed
        self.iccData = iccData
    }

    static func isValidICCData(_ data: Data) -> Bool {
        guard (minimumICCByteCount...maximumICCByteCount).contains(data.count) else { return false }
        guard let space = CGColorSpace(iccData: data as CFData) else { return false }
        return space.model == .cmyk
    }

    enum ValidationError: LocalizedError, Equatable {
        case missingProfile
        case invalidProfile

        var errorDescription: String? {
            switch self {
            case .missingProfile:
                return "Choose a CMYK profile before exporting."
            case .invalidProfile:
                return "Choose a valid installed CMYK profile no larger than 4 MB."
            }
        }
    }
}

/// A discovered, selectable installed CMYK profile.
struct PsdCmykProfileCatalogEntry: Equatable, Sendable {
    let profile: PsdCmykProfile
}

/// Reads installed CMYK profiles off the main thread. The form consumes it
/// lazily and only while CMYK output is chosen.
protocol PsdCmykProfileCatalogLoading: Sendable {
    func loadCatalog() throws -> [PsdCmykProfileCatalogEntry]
}

struct PsdCmykProfileCatalog: Equatable {
    enum State: Equatable {
        case idle
        case loading
        case loaded([PsdCmykProfileCatalogEntry])
        case failed(String)
    }

    var state: State = .idle

    static let installMessage = "Install a printer profile with ColorSync to add it here."
    static let emptyMessage = "No installed CMYK profiles are available. \(installMessage)"
    static let failedPrefix = "Could not read installed CMYK profiles."

    static func discoveredEntries() -> [PsdCmykProfileCatalogEntry] {
        let spaces = NSColorSpace.availableColorSpaces(with: .cmyk)
        var seen: [Data: PsdCmykProfileCatalogEntry] = [:]
        for space in spaces {
            guard let data = space.iccProfileData, !data.isEmpty else { continue }
            // Device CMYK with no usable ICC and non-CMYK/oversize profiles are
            // excluded; only actual CMYK ICC bytes in range are selectable.
            guard PsdCmykProfile.isValidICCData(data) else { continue }
            guard seen[data] == nil else { continue }
            let name = space.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = (name?.isEmpty == false) ? name! : "CMYK Profile"
            if let profile = try? PsdCmykProfile(displayName: displayName, iccData: data) {
                seen[data] = PsdCmykProfileCatalogEntry(profile: profile)
            }
        }
        return seen.values.sorted { lhs, rhs in
            lhs.profile.displayName.localizedCaseInsensitiveCompare(rhs.profile.displayName) == .orderedAscending
        }
    }
}

struct LivePsdCmykProfileCatalogLoader: PsdCmykProfileCatalogLoading {
    func loadCatalog() throws -> [PsdCmykProfileCatalogEntry] {
        PsdCmykProfileCatalog.discoveredEntries()
    }
}
