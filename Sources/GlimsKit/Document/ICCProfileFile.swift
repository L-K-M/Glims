import Darwin
import Foundation

enum ICCProfileFile {
    private struct ReadError: LocalizedError {
        let errorDescription: String?
    }
    /// Read a regular file through its opened descriptor. The cap also
    /// holds if the file grows after it was selected or while being read.
    static func read(_ url: URL) throws -> Data {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            throw ReadError(errorDescription: "Choose a regular ICC profile file.")
        }
        guard info.st_size > 0, info.st_size <= CanvasSoftProof.maximumICCBytes else {
            throw ReadError(errorDescription: "The proof profile must contain between 1 byte and 16 MiB of ICC data.")
        }
        var data = Data()
        while data.count <= CanvasSoftProof.maximumICCBytes {
            let count = min(64 * 1024, CanvasSoftProof.maximumICCBytes + 1 - data.count)
            guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { return data }
            data.append(chunk)
        }
        throw ReadError(errorDescription: "The proof profile exceeds the 16 MiB limit.")
    }
}
