import Foundation

/// Metadata for the current recording, separate from image file metadata.
struct RecorderFileMetadata: Equatable {
    let recordingID: UUID
    let origin: RecorderFileValue.Origin
    private(set) var name: String
    private var hasExplicitName = false

    init(origin: RecorderFileValue.Origin) {
        self.recordingID = UUID()
        self.origin = origin
        let proposed = origin.imageLabel.isEmpty ? "Recording" : "\(origin.imageLabel) Recording"
        self.name = proposed.utf8.count <= RecorderFileLimits.stringBytes ? proposed : "Recording"
    }

    init(file: RecorderFileValue) {
        self.recordingID = file.recordingID
        self.origin = file.origin
        self.name = file.name
    }

    mutating func rename(_ proposed: String) throws -> Bool {
        guard !proposed.isEmpty else { throw RecorderFileError.invalid("A recording needs a name.") }
        guard proposed.utf8.count <= RecorderFileLimits.stringBytes else {
            throw RecorderFileError.invalid("The recording name exceeds 64 KiB of UTF-8.")
        }
        guard !name.utf8.elementsEqual(proposed.utf8) else { return false }
        name = proposed
        hasExplicitName = true
        return true
    }

    func hasUnsavedChanges<Command>(in log: RecorderLog<Command>, revision: UUID, savedRevision: UUID?) -> Bool {
        guard revision != savedRevision else { return false }
        return hasExplicitName || log.pendingCount > 0 || !log.records.isEmpty
    }

    /// A loaded file may include unused descriptions. Keep its complete
    /// original value when producing a copy with the current intrinsic name.
    func namedCopy(of file: RecorderFileValue) -> RecorderFileValue {
        RecorderFileValue(recordingID: file.recordingID, name: name, origin: file.origin,
                          symbols: file.symbols, records: file.records)
    }
}
