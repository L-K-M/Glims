import Darwin
import Foundation

/// One serially owned export. The engine writes in a private directory; only a
/// successful replay/export may publish it. Publication never replaces an entry.
/// This is atomic naming, not a crash-durable transaction or recovery journal.
final class RecorderBatchOutput {
    struct Published {
        let url: URL
        let cleanupWarning: String?
    }

    enum Failure: LocalizedError {
        case invalidLocation, changedFolder, invalidOutput, alreadyFinished, nameExhausted
        case io(String, Int32)

        var errorDescription: String? {
            switch self {
            case .invalidLocation: return "Choose a local output folder and a supported filename extension."
            case .changedFolder: return "The output folder moved or changed during Batch. Choose it again."
            case .invalidOutput: return "The export did not produce a complete regular file. No output was published."
            case .alreadyFinished: return "This Batch output has already finished."
            case .nameExhausted: return "No unused output name was available. Choose another output folder."
            case .io(let operation, let code):
                return "Could not \(operation): \(POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription)"
            }
        }
    }

    let stagingURL: URL
    private let directory: URL
    private let parent: Int32
    private let stage: Int32
    private let parentIdentity: stat
    private let stageIdentity: stat
    private let stageName: String
    private let fileName: String
    private let stem: String
    private let suffix: String
    private let excluded: Set<String>
    private let nameLimit: Int
    private var finished = false
    private var removedStage = false

    /// Invoke storage operations on the caller's serial file queue. Input URLs
    /// remain reserved even if another process removes an input during the run.
    init(directory: URL, source: URL, inputs: [URL], extension suffix: String) throws {
        guard directory.isFileURL, (directory.host ?? "").isEmpty || directory.host == "localhost",
              directory.query == nil, directory.fragment == nil, !directory.path.utf8.contains(0),
              !suffix.isEmpty, suffix.utf8.count <= 16,
              suffix.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) }) else {
            throw Failure.invalidLocation
        }
        self.directory = directory.resolvingSymlinksInPath().standardizedFileURL
        self.suffix = suffix
        let base = source.deletingPathExtension().lastPathComponent
        stem = base.isEmpty || base == "." || base == ".." ? "Image" : base
        excluded = Set(inputs.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        stageName = ".glims-batch-\(UUID().uuidString.lowercased())"
        fileName = "output.\(suffix)"
        stagingURL = self.directory.appendingPathComponent(stageName, isDirectory: true).appendingPathComponent(fileName)

        parent = Darwin.open(self.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.io("open the output folder", errno) }
        do { parentIdentity = try Self.info(parent) }
        catch { Darwin.close(parent); throw error }
        let limit = Darwin.fpathconf(parent, _PC_NAME_MAX)
        nameLimit = limit > 0 ? min(Int(limit), 255) : 255
        guard Darwin.mkdirat(parent, stageName, mode_t(0o700)) == 0 else {
            let code = errno; Darwin.close(parent); throw Failure.io("create the export folder", code)
        }
        stage = Darwin.openat(parent, stageName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard stage >= 0 else {
            let code = errno
            // Do not remove a name whose identity we could not establish.
            Darwin.close(parent); throw Failure.io("open the private export folder at \(stagingURL.deletingLastPathComponent().path)", code)
        }
        do { stageIdentity = try Self.info(stage) }
        catch { Darwin.close(stage); Darwin.close(parent); throw error }
    }

    deinit {
        _ = removeStage()
        Darwin.close(stage)
        Darwin.close(parent)
    }

    func publish() throws -> Published {
        guard !finished else { throw Failure.alreadyFinished }
        try verifyLocation()
        var output = stat()
        guard Darwin.fstatat(stage, fileName, &output, AT_SYMLINK_NOFOLLOW) == 0,
              output.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), output.st_nlink == 1,
              output.st_size > 0 else { throw Failure.invalidOutput }
        for index in 1...10_000 {
            let tail = index == 1 ? " edited.\(suffix)" : " edited \(index).\(suffix)"
            var base = stem
            while base.utf8.count + tail.utf8.count > nameLimit { base.removeLast() }
            let name = base + tail
            let destination = directory.appendingPathComponent(name)
            if excluded.contains(destination.path) { continue }
            // RENAME_EXCL also refuses a concurrently created file, symlink or
            // directory. There is no check-then-overwrite fallback.
            if Darwin.renameatx_np(stage, fileName, parent, name, UInt32(RENAME_EXCL)) == 0 {
                finished = true
                return Published(url: destination, cleanupWarning: removeStage())
            }
            if errno == EEXIST { continue }
            throw Failure.io("publish \(name)", errno)
        }
        throw Failure.nameExhausted
    }

    /// Cancelling leaves inputs and published outputs alone. A cleanup failure
    /// names the private directory so the result can report it without claiming
    /// that an already-published output was lost.
    func discard() -> String? {
        finished = true
        return removeStage()
    }

    private func verifyLocation() throws {
        var actualParent = stat(), actualStage = stat()
        guard Darwin.lstat(directory.path, &actualParent) == 0,
              Self.same(parentIdentity, actualParent),
              Darwin.fstatat(parent, stageName, &actualStage, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(stageIdentity, actualStage) else { throw Failure.changedFolder }
    }

    private func removeStage() -> String? {
        guard !removedStage else { return nil }
        var current = stat()
        guard Darwin.fstatat(parent, stageName, &current, AT_SYMLINK_NOFOLLOW) == 0,
              Self.same(stageIdentity, current) else {
            return "The private export folder changed; inspect \(stagingURL.deletingLastPathComponent().path)."
        }
        // Delete only the known entry in our opened private directory, never a
        // recursive path. A symlink here is unlinked, not followed.
        if Darwin.unlinkat(stage, fileName, 0) != 0 && errno != ENOENT {
            return "Could not remove the temporary export at \(stagingURL.path)."
        }
        guard Darwin.unlinkat(parent, stageName, AT_REMOVEDIR) == 0 else {
            return "Could not remove the temporary export folder at \(stagingURL.deletingLastPathComponent().path)."
        }
        removedStage = true
        return nil
    }

    private static func info(_ descriptor: Int32) throws -> stat {
        var result = stat()
        guard Darwin.fstat(descriptor, &result) == 0 else { throw Failure.io("inspect the output folder", errno) }
        return result
    }

    private static func same(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
            && first.st_mode & mode_t(S_IFMT) == second.st_mode & mode_t(S_IFMT)
    }
}
