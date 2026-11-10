import Darwin
import Foundation

/// Background-only storage of detached recording candidates. No live log or
/// document state is read or replaced here. A successful load grants no replay
/// authority; a caller still needs explicit binding and installation.
///
/// A same-directory rename commits a save atomically. This is not a crash
/// recovery/durable-directory journal. Observed concurrent mutations refuse the
/// operation; another writer racing the final check has last-writer-wins
/// semantics. Final symlinks are refused. Ancestors use normal path resolution,
/// then the opened parent directory remains authoritative if its path moves.
enum RecorderFileStore {
    enum StoreError: Error, LocalizedError, Equatable {
        case backgroundRequired
        case invalidLocation(String)
        case notRegularFile(String)
        case oversized(String)
        case changed(String)
        case io(operation: String, path: String, code: Int32)
        case unconfirmedStage(destination: String, temporaryName: String, code: Int32)

        var errorDescription: String? {
            switch self {
            case .backgroundRequired: return "Recording file access must run on a background queue."
            case .invalidLocation(let path): return "Choose a local named recording file: \(path)"
            case .notRegularFile(let path): return "Choose a regular recording file without a final symbolic link: \(path)"
            case .oversized(let path): return "The recording exceeds the 16 MiB file limit: \(path)"
            case .changed(let path): return "The recording file changed during this operation; try again: \(path)"
            case .io(let operation, let path, let code):
                let reason = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription
                return "Could not \(operation) recording file \(path): \(reason)"
            case .unconfirmedStage(let destination, let temporaryName, let code):
                let reason = POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO).localizedDescription
                return "Could not inspect the staged recording: \(reason) (errno \(code)). This save did not replace \(destination). A staging file named \(temporaryName) may remain in its folder."
            }
        }
    }

    static func load(from url: URL) throws -> RecorderFileValue {
        try requireBackground()
        let location = try Location(url)
        let parent = try location.openParent()
        defer { Darwin.close(parent) }
        guard let observed = try status(parent: parent, name: location.name, path: location.path) else {
            throw StoreError.io(operation: "open", path: location.path, code: ENOENT)
        }
        try regular(observed, path: location.path)
        try boundedSize(observed, path: location.path)

        let descriptor = location.name.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw failure("open", location.path) }
        defer { Darwin.close(descriptor) }
        let before = try status(descriptor: descriptor, path: location.path)
        try regular(before, path: location.path)
        try boundedSize(before, path: location.path)
        guard sameVersion(observed, before) else { throw StoreError.changed(location.path) }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while data.count <= RecorderFileLimits.bytes {
            let capacity = min(buffer.count, RecorderFileLimits.bytes + 1 - data.count)
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, capacity)
            }
            if count < 0 {
                if errno == EINTR { continue }
                throw failure("read", location.path)
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= RecorderFileLimits.bytes else { throw StoreError.oversized(location.path) }
        let after = try status(descriptor: descriptor, path: location.path)
        guard sameVersion(before, after), after.st_size == off_t(data.count) else {
            throw StoreError.changed(location.path)
        }
        return try RecorderFileCodec.decode(data)
    }

    /// `beforeCommit` is a narrow internal staging checkpoint. A throwing test
    /// checkpoint proves pre-commit exception cleanup; it does not simulate an
    /// actual write/fsync fault. No paths are passed or callback retained.
    static func save(_ value: RecorderFileValue, to url: URL,
                     beforeCommit: (() throws -> Void)? = nil) throws {
        try requireBackground()
        let data = try RecorderFileCodec.encode(value)
        let location = try Location(url)
        let parent = try location.openParent()
        defer { Darwin.close(parent) }
        let observed = try status(parent: parent, name: location.name, path: location.path)
        if let observed { try regular(observed, path: location.path) }

        let temporary = ".glimsrecording-\(UUID().uuidString.lowercased()).tmp"
        var descriptor = temporary.withCString {
            Darwin.openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        }
        guard descriptor >= 0 else { throw failure("create temporary", location.path) }
        let identity: stat
        do { identity = try status(descriptor: descriptor, path: location.path) }
        catch {
            Darwin.close(descriptor)
            // Creation-time ownership cannot establish the entry's current
            // identity if this first fstat failed. Leave an unconfirmed name
            // alone rather than unlinking a possible concurrent replacement.
            if let issue = error as? StoreError, case .io(_, _, let code) = issue {
                throw StoreError.unconfirmedStage(destination: location.path, temporaryName: temporary, code: code)
            }
            throw error
        }
        var committed = false
        defer {
            if descriptor >= 0 { Darwin.close(descriptor) }
            if !committed { removeOwnedTemporary(parent: parent, name: temporary, identity: identity) }
        }
        try regular(identity, path: location.path)
        // Explicit 0600 mode bits, independent of the caller's umask. Any
        // additional filesystem ACL policy remains the filesystem's concern.
        guard Darwin.fchmod(descriptor, mode_t(0o600)) == 0 else { throw failure("protect temporary", location.path) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw failure("write temporary", location.path)
                }
                guard count > 0 else { throw StoreError.io(operation: "write temporary", path: location.path, code: EIO) }
                offset += count
            }
        }
        while Darwin.fsync(descriptor) != 0 {
            if errno == EINTR { continue }
            throw failure("sync temporary", location.path)
        }
        let staged = try status(descriptor: descriptor, path: location.path)
        guard staged.st_size == off_t(data.count) else { throw StoreError.changed(location.path) }
        // Do not retry close: an interrupted close may already have released its
        // descriptor, which another thread can then reuse.
        let closing = descriptor
        descriptor = -1
        guard Darwin.close(closing) == 0 else { throw failure("close temporary", location.path) }
        try beforeCommit?()

        let current = try status(parent: parent, name: location.name, path: location.path)
        if let current { try regular(current, path: location.path) }
        guard sameOptionalVersion(observed, current) else { throw StoreError.changed(location.path) }
        guard let temporaryStatus = try status(parent: parent, name: temporary, path: location.path),
              isRegular(temporaryStatus), sameVersion(staged, temporaryStatus) else {
            throw StoreError.changed(location.path)
        }
        let result = temporary.withCString { source in
            location.name.withCString { destination in Darwin.renameat(parent, source, parent, destination) }
        }
        guard result == 0 else { throw failure("replace", location.path) }
        // Commit boundary: never report a later failure as if old bytes survived.
        // Other hard links still name the old inode; only this entry is replaced.
        committed = true
    }

    private struct Location {
        let path: String
        let parent: String
        let name: String

        init(_ url: URL) throws {
            path = url.path
            let host = url.host ?? ""
            guard url.isFileURL, host.isEmpty || host == "localhost", url.query == nil, url.fragment == nil,
                  url.user == nil, url.password == nil, url.port == nil, path.hasPrefix("/"),
                  !path.utf8.contains(0), !path.hasSuffix("/") else { throw StoreError.invalidLocation(path) }
            name = (path as NSString).lastPathComponent
            parent = (path as NSString).deletingLastPathComponent
            guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
                throw StoreError.invalidLocation(path)
            }
        }

        func openParent() throws -> Int32 {
            let descriptor = parent.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
            guard descriptor >= 0 else { throw RecorderFileStore.failure("open parent of", path) }
            return descriptor
        }
    }

    private static func requireBackground() throws {
        guard !Thread.isMainThread else { throw StoreError.backgroundRequired }
    }
    private static func failure(_ operation: String, _ path: String) -> StoreError {
        .io(operation: operation, path: path, code: errno)
    }
    private static func isRegular(_ info: stat) -> Bool { info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) }
    private static func regular(_ info: stat, path: String) throws {
        guard isRegular(info) else { throw StoreError.notRegularFile(path) }
    }
    private static func boundedSize(_ info: stat, path: String) throws {
        guard info.st_size >= 0, info.st_size <= off_t(RecorderFileLimits.bytes) else { throw StoreError.oversized(path) }
    }
    private static func status(descriptor: Int32, path: String) throws -> stat {
        var info = stat()
        guard Darwin.fstat(descriptor, &info) == 0 else { throw failure("inspect", path) }
        return info
    }
    private static func status(parent: Int32, name: String, path: String) throws -> stat? {
        var info = stat()
        let result = name.withCString { Darwin.fstatat(parent, $0, &info, AT_SYMLINK_NOFOLLOW) }
        if result == 0 { return info }
        if errno == ENOENT { return nil }
        throw failure("inspect", path)
    }
    private static func sameIdentity(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }
    private static func sameVersion(_ first: stat, _ second: stat) -> Bool {
        sameIdentity(first, second) && first.st_mode == second.st_mode && first.st_size == second.st_size
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
    private static func sameOptionalVersion(_ first: stat?, _ second: stat?) -> Bool {
        switch (first, second) {
        case (nil, nil): return true
        case (.some(let first), .some(let second)): return sameVersion(first, second)
        default: return false
        }
    }
    private static func removeOwnedTemporary(parent: Int32, name: String, identity: stat) {
        var current = stat()
        let result = name.withCString { Darwin.fstatat(parent, $0, &current, AT_SYMLINK_NOFOLLOW) }
        guard result == 0, sameIdentity(identity, current) else { return }
        name.withCString { _ = Darwin.unlinkat(parent, $0, 0) }
    }
}
