import Foundation

/// Reserves file writes on the main actor so two document windows cannot
/// acquire the same save target while asynchronous Save As calls overlap.
@MainActor
final class FileWriteCoordinator {
    private var reservations: [UUID: (owner: UUID, url: URL)] = [:]

    enum Conflict: LocalizedError {
        case alreadyOpen(String)
        var errorDescription: String? {
            switch self {
            case .alreadyOpen(let name): return "\u{201C}\(name)\u{201D} is already open or being written by another image. Choose a different filename."
            }
        }
    }

    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        if lhs.standardizedFileURL.resolvingSymlinksInPath() == rhs.standardizedFileURL.resolvingSymlinksInPath() { return true }
        guard let left = try? lhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
              let right = try? rhs.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject else { return false }
        return left.isEqual(right)
    }

    func reserve(_ url: URL, owner: UUID, openFiles: [(owner: UUID, url: URL)], opening: [URL]) throws -> UUID {
        let otherFiles = openFiles.filter { $0.owner != owner }.map(\.url)
            + reservations.values.filter { $0.owner != owner }.map(\.url) + opening
        guard !otherFiles.contains(where: { Self.sameFile($0, url) }) else {
            throw Conflict.alreadyOpen(url.lastPathComponent)
        }
        let token = UUID()
        reservations[token] = (owner, url)
        return token
    }

    func owner(writing url: URL) -> UUID? {
        reservations.values.first { Self.sameFile($0.url, url) }?.owner
    }

    func release(_ token: UUID) { reservations.removeValue(forKey: token) }
}
