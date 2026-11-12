import Foundation

/// Flat, read-only input discovery. Call on the Batch file queue; image format
/// support remains the native loader's decision and is reported per file.
enum RecorderBatchInputs {
    enum Failure: LocalizedError {
        case invalidLocation(String), notRegular(String), empty, tooMany(Int), unreadableFolder(String)

        var errorDescription: String? {
            switch self {
            case .invalidLocation(let path): return "Choose local input files or folders: \(path)"
            case .notRegular(let path): return "Choose a regular image file or an ordinary folder: \(path)"
            case .empty: return "The selected folders contain no visible regular files. Choose input images."
            case .tooMany(let limit): return "Choose at most \(limit) distinct input files for one Batch."
            case .unreadableFolder(let path): return "Could not read the input folder: \(path)"
            }
        }
    }

    static func resolve(_ selection: [URL], limit: Int = 10_000) throws -> [URL] {
        guard limit > 0 else { throw Failure.tooMany(limit) }
        var files: [URL] = [], seenFiles = Set<String>(), seenSelections = Set<String>()
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isPackageKey]
        for selected in selection {
            let host = selected.host ?? ""
            guard selected.isFileURL, host.isEmpty || host == "localhost", selected.query == nil,
                  selected.fragment == nil, selected.user == nil, selected.password == nil, selected.port == nil,
                  !selected.path.utf8.contains(0) else { throw Failure.invalidLocation(selected.path) }
            let canonical = selected.resolvingSymlinksInPath().standardizedFileURL
            guard seenSelections.insert(canonical.path).inserted else { continue }
            let info = try canonical.resourceValues(forKeys: keys)
            if info.isRegularFile == true {
                if seenFiles.insert(canonical.path).inserted {
                    files.append(canonical)
                    guard files.count <= limit else { throw Failure.tooMany(limit) }
                }
                continue
            }
            guard info.isDirectory == true, info.isPackage != true else { throw Failure.notRegular(canonical.path) }
            var enumerationError: Error?
            guard let entries = FileManager.default.enumerator(at: canonical, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants],
                errorHandler: { _, error in enumerationError = error; return false }) else {
                throw Failure.unreadableFolder(canonical.path)
            }
            var discovered: [URL] = []
            for case let entry as URL in entries {
                let values = try entry.resourceValues(forKeys: keys)
                // A folder selection never follows links out of that folder.
                guard values.isSymbolicLink != true, values.isRegularFile == true else { continue }
                let input = entry.standardizedFileURL
                if seenFiles.insert(input.path).inserted {
                    discovered.append(input)
                    guard files.count + discovered.count <= limit else { throw Failure.tooMany(limit) }
                }
            }
            if let enumerationError { throw enumerationError }
            files += discovered.sorted { $0.path < $1.path }
        }
        guard !files.isEmpty else { throw Failure.empty }
        return files
    }
}
