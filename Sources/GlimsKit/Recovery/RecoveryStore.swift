import Darwin
import Foundation

/// On-disk recovery copies of open documents, written by
/// `RecoveryScheduler` and read back by a later recovery UI.
///
/// Layout, all under `base` (mode 0700):
///
///     <run-UUID>/run.json        the run's identity and owner pid   0600
///     <run-UUID>/<doc-UUID>.json the document's record (manifest)   0600
///     <run-UUID>/<doc-UUID>.<generation-UUID>.xcf  a copy           0600
///
/// Each app run owns one folder named by a fresh UUID and stamped with
/// its pid, so several instances can share the store and a later run
/// can tell crashed runs' records from live ones. Every write lands in
/// a same-folder temporary name first and is renamed over its target in
/// one step: a crash or failure mid-write keeps the previously
/// committed copy, and temporary litter is swept without touching
/// folders whose owner process is still alive.
///
/// The store only ever reads, writes or deletes names it formed itself
/// from UUIDs inside run folders — never a path a manifest names. A
/// decoded record's fields (its source URLs included) are data for the
/// recovery UI, not paths to act on.
final class RecoveryStore {

    /// The identity a run stamps its folder with (`run.json`).
    struct Run: Codable, Equatable {
        var schemaVersion = RecoveryStore.schemaVersion
        var runID: UUID
        var pid: Int32
        var started: Date
    }

    /// One open document's recovery record (`<doc-UUID>.json`).
    struct Record: Codable, Equatable {
        var schemaVersion = RecoveryStore.schemaVersion
        var documentID: UUID
        /// The document's display name when the copy was made.
        var name: String
        /// The native file the document saves to, if it has one.
        var nativeURL: URL?
        /// The foreign file the document was imported from, if any.
        var importedSourceURL: URL?
        /// The copy's name inside the run folder. Always
        /// a document UUID and generation UUID, checked on decode.
        /// A manifest can never name a path outside the run folder.
        var copyFilename: String
        /// When the copy was committed.
        var date: Date
        /// The document history revision the copy holds, for
        /// duplicate-write suppression.
        var revision: UInt64?
    }

    /// What a record says about its document, minus fields the store
    /// assigns (the document id, copy name and commit date).
    struct Metadata: Equatable {
        var name: String
        var nativeURL: URL?
        var importedSourceURL: URL?
        var revision: UInt64?
    }

    /// A recoverable document found on disk: a dead or ended run's
    /// committed copy with the identity the recovery UI needs.
    struct RecoveredDocument: Equatable {
        var runID: UUID
        var documentID: UUID
        var name: String
        var nativeURL: URL?
        var importedSourceURL: URL?
        /// The committed copy inside its run folder.
        var copyURL: URL
        var date: Date
        var revision: UInt64?
    }

    enum StoreError: LocalizedError {
        case invalidTemporaryName(String)
        /// The candidate's run is this run, is still alive, or its owner
        /// marker can no longer be read — its files are left alone.
        case runUnavailable(UUID)
        /// The manifest on disk is gone or no longer describes the
        /// candidate the caller was shown.
        case recordMismatch(UUID)
        var errorDescription: String? {
            switch self {
            case .invalidTemporaryName(let name):
                return "\(name) is not a recovery temporary this run issued."
            case .runUnavailable(let id):
                return "The recovery record's run \(id.uuidString) is still running or cannot be verified to have ended."
            case .recordMismatch(let id):
                return "The recovery record \(id.uuidString) is no longer the one that was selected."
            }
        }
    }

    static let schemaVersion = 2
    /// The run folder marker.
    static let runFilename = "run.json"

    let base: URL
    let runID: UUID
    let ownerPID: Int32
    private let files: FileManager
    private let now: () -> Date
    private let processIsAlive: (Int32) -> Bool

    /// `ownerPID` and `processIsAlive` default to this process and
    /// `kill(pid, 0)`; tests inject both. EPERM counts as alive — the
    /// run belongs to someone else either way, so its files stay.
    init(base: URL, runID: UUID = UUID(),
         ownerPID: Int32 = ProcessInfo.processInfo.processIdentifier,
         fileManager: FileManager = .default,
         now: @escaping () -> Date = Date.init,
         processIsAlive: ((Int32) -> Bool)? = nil) {
        self.base = base
        self.runID = runID
        self.ownerPID = ownerPID
        self.files = fileManager
        self.now = now
        self.processIsAlive = processIsAlive ?? { pid in
            kill(pid, 0) == 0 || errno == EPERM
        }
    }

    /// This run's folder inside the store.
    var runDirectory: URL {
        base.appendingPathComponent(runID.uuidString, isDirectory: true)
    }

    static func copyName(for id: UUID) -> String { "\(id.uuidString).xcf" }
    static func manifestName(for id: UUID) -> String { "\(id.uuidString).json" }

    /// A temporary name inside the run folder that still ends in `ext`,
    /// so the engine picks the right file plug-in for the copy.
    private static func temporaryName(for id: UUID, ext: String) -> String {
        ".\(id.uuidString).tmp-\(UUID().uuidString).\(ext)"
    }

    /// Where the next copy for `id` is written before it is committed.
    /// The engine saves into this exact name.
    func temporaryCopyURL(for id: UUID) -> URL {
        runDirectory.appendingPathComponent(Self.temporaryName(for: id, ext: "xcf"))
    }

    func copyURL(for id: UUID) -> URL {
        runDirectory.appendingPathComponent(record(for: id)?.copyFilename ?? Self.copyName(for: id))
    }

    private static func isCopyName(_ name: String, for id: UUID) -> Bool {
        if name == copyName(for: id) { return true } // first store format
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts[0] == id.uuidString
            && UUID(uuidString: String(parts[1])) != nil && parts[2] == "xcf"
    }

    private func manifestURL(for id: UUID) -> URL {
        runDirectory.appendingPathComponent(Self.manifestName(for: id))
    }

    func copyExists(for id: UUID) -> Bool {
        files.fileExists(atPath: copyURL(for: id).path)
    }

    /// Creates the store and this run's folder, sweeps stale temporaries
    /// and writes `run.json`. Only files this run — or a run whose owner
    /// is provably dead — left behind are touched.
    func prepare() throws {
        try files.createDirectory(at: base, withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        // Healing permissions covers a store left over from older builds.
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: base.path)
        try files.createDirectory(at: runDirectory, withIntermediateDirectories: false,
                                  attributes: [.posixPermissions: 0o700])
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: runDirectory.path)
        sweepStaleFiles()
        let run = Run(runID: runID, pid: ownerPID, started: now())
        try commit(data: encoder().encode(run), to: runDirectory.appendingPathComponent(Self.runFilename),
                   temporary: runDirectory.appendingPathComponent(".run.tmp-\(UUID().uuidString).json"))
    }

    /// Publishes an immutable generation, then atomically changes the
    /// manifest's pointer to it. A failed manifest write leaves both the
    /// earlier pixels and their metadata intact; only after publication
    /// may the previous generation be removed.
    @discardableResult
    func commitCopy(at temp: URL, for id: UUID, metadata: Metadata) throws -> Record {
        guard isOwnTemporary(temp, for: id, ext: "xcf"),
              files.fileExists(atPath: temp.path) else {
            throw StoreError.invalidTemporaryName(temp.lastPathComponent)
        }
        let previous = record(for: id)
        let name = "\(id.uuidString).\(UUID().uuidString).xcf"
        let generation = runDirectory.appendingPathComponent(name)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temp.path)
        try replace(temp, with: generation)
        let record = Record(documentID: id, name: metadata.name,
                            nativeURL: metadata.nativeURL,
                            importedSourceURL: metadata.importedSourceURL,
                            copyFilename: name, date: now(), revision: metadata.revision)
        let manifestTemp = runDirectory.appendingPathComponent(Self.temporaryName(for: id, ext: "json"))
        do {
            try commit(data: encoder().encode(record), to: manifestURL(for: id), temporary: manifestTemp)
        } catch {
            try? files.removeItem(at: generation)
            discardTemporary(manifestTemp)
            throw error
        }
        if let previous {
            try? files.removeItem(at: runDirectory.appendingPathComponent(previous.copyFilename))
        }
        return record
    }

    /// Removes an uncommitted temporary. Only ever deletes names this
    /// run issued inside its own folder.
    func discardTemporary(_ url: URL) {
        guard url.deletingLastPathComponent().path == runDirectory.path,
              url.lastPathComponent.hasPrefix("."),
              url.lastPathComponent.contains(".tmp-") else { return }
        try? files.removeItem(at: url)
    }

    /// Deletes `id`'s record, copy and leftover temporaries — only for
    /// a document of this run that closed for good. Prior runs' records
    /// are never touched.
    func discard(_ id: UUID) {
        try? files.removeItem(at: manifestURL(for: id))
        for entry in (try? files.contentsOfDirectory(at: runDirectory, includingPropertiesForKeys: nil)) ?? []
        where Self.isCopyName(entry.lastPathComponent, for: id)
                || entry.lastPathComponent.hasPrefix(".\(id.uuidString).tmp-") {
            try? files.removeItem(at: entry)
        }
    }

    /// The record of a document in this run's folder, if one was
    /// committed and still validates.
    func record(for id: UUID) -> Record? {
        readRecord(at: manifestURL(for: id), expectedID: id)
    }

    /// Recoverable documents from other runs whose owner process is
    /// gone. The current run and runs with a live owner are skipped;
    /// malformed run folders, manifests and stray files are skipped one
    /// at a time. Pure read: nothing is moved or deleted here.
    func discoverRecoverableDocuments() -> [RecoveredDocument] {
        guard let runs = try? files.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])
        else { return [] }
        var found: [RecoveredDocument] = []
        for dir in runs {
            guard dir.lastPathComponent != runID.uuidString,
                  let otherRun = UUID(uuidString: dir.lastPathComponent),
                  (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let entries = try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            else { continue }
            // Only a validated run marker can say the run ended: a folder
            // whose owner cannot be read is left unoffered, like a live one.
            guard let owner = readRun(dir)?.pid, !processIsAlive(owner) else { continue }
            for entry in entries where entry.pathExtension == "json"
                    && entry.lastPathComponent != Self.runFilename {
                guard let documentID = UUID(uuidString: entry.deletingPathExtension().lastPathComponent),
                      let record = readRecord(at: entry, expectedID: documentID),
                      files.fileExists(atPath: dir.appendingPathComponent(record.copyFilename).path)
                else { continue }
                found.append(RecoveredDocument(runID: otherRun, documentID: documentID,
                                               name: record.name,
                                               nativeURL: record.nativeURL,
                                               importedSourceURL: record.importedSourceURL,
                                               copyURL: dir.appendingPathComponent(record.copyFilename),
                                               date: record.date, revision: record.revision))
            }
        }
        return found.sorted { ($0.date, $0.documentID.uuidString) < ($1.date, $1.documentID.uuidString) }
    }

    /// Re-reads a discovered candidate against the store: its run is
    /// still a dead foreign run, its manifest still decodes to the same
    /// record, and the copy it names is still there. A candidate is a
    /// snapshot — a later discard or another run's crash can make it
    /// stale, so every action on it re-validates instead of trusting the
    /// row.
    func recoverableDocument(matching candidate: RecoveredDocument) -> RecoveredDocument? {
        let dir = base.appendingPathComponent(candidate.runID.uuidString, isDirectory: true)
        guard candidate.runID != runID,
              let owner = readRun(dir)?.pid, !processIsAlive(owner),
              let record = readRecord(at: dir.appendingPathComponent(Self.manifestName(for: candidate.documentID)),
                                      expectedID: candidate.documentID),
              matches(record, candidate),
              files.fileExists(atPath: dir.appendingPathComponent(record.copyFilename).path)
        else { return nil }
        return RecoveredDocument(runID: candidate.runID, documentID: candidate.documentID,
                                 name: record.name,
                                 nativeURL: record.nativeURL,
                                 importedSourceURL: record.importedSourceURL,
                                 copyURL: dir.appendingPathComponent(record.copyFilename),
                                 date: record.date, revision: record.revision)
    }

    /// Deletes a prior run's recovery record and its copy. Only names
    /// this store forms from the candidate's validated UUIDs are
    /// removed: `candidate.copyURL` and the record's source URLs are
    /// never deletion targets, so a crafted candidate can never delete
    /// outside the private store. The run's owner is re-checked dead and
    /// the manifest re-validated against the candidate, so a stale row
    /// cannot delete a changed record or a live run's files.
    func discardRecoverable(_ candidate: RecoveredDocument) throws {
        guard candidate.runID != runID else { throw StoreError.runUnavailable(candidate.runID) }
        let dir = base.appendingPathComponent(candidate.runID.uuidString, isDirectory: true)
        guard let owner = readRun(dir)?.pid else {
            throw StoreError.runUnavailable(candidate.runID)
        }
        guard !processIsAlive(owner) else { throw StoreError.runUnavailable(candidate.runID) }
        let manifest = dir.appendingPathComponent(Self.manifestName(for: candidate.documentID))
        guard let record = readRecord(at: manifest, expectedID: candidate.documentID),
              matches(record, candidate)
        else { throw StoreError.recordMismatch(candidate.documentID) }
        // The copy goes first: a failure keeps the whole record intact
        // rather than orphaning large pixels next to a live manifest.
        let copy = dir.appendingPathComponent(record.copyFilename)
        if files.fileExists(atPath: copy.path) { try files.removeItem(at: copy) }
        try files.removeItem(at: manifest)
        // Leftover temporaries of the same document are swept too.
        for entry in (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where entry.lastPathComponent.hasPrefix(".\(candidate.documentID.uuidString).tmp-") {
            try? files.removeItem(at: entry)
        }
        // A run folder holding only its marker has nothing recoverable left.
        let remaining = (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        if remaining.allSatisfy({ $0.lastPathComponent == Self.runFilename
                || ($0.lastPathComponent.hasPrefix(".") && $0.lastPathComponent.contains(".tmp-")) }) {
            try? files.removeItem(at: dir)
        }
    }

    /// Whether the record decoded from disk still describes the
    /// candidate the UI showed — same copy, name, date, revision and
    /// source fields.
    private func matches(_ record: Record, _ candidate: RecoveredDocument) -> Bool {
        record.name == candidate.name && record.date == candidate.date
            && record.revision == candidate.revision
            && record.nativeURL == candidate.nativeURL
            && record.importedSourceURL == candidate.importedSourceURL
            && record.copyFilename == candidate.copyURL.lastPathComponent
    }

    // MARK: Internal

    /// Writes `data` to `temporary` privately, then renames it over
    /// `target`. The same-folder rename is the atomic replace.
    private func commit(data: Data, to target: URL, temporary: URL) throws {
        try data.write(to: temporary)
        try files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        try replace(temporary, with: target)
    }

    /// `rename(2)` over an existing file — the primitive that keeps the
    /// last committed copy until its replacement is complete.
    private func replace(_ temp: URL, with target: URL) throws {
        guard rename(temp.path, target.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EPERM)
        }
    }

    /// Whether `url` is a name `temporaryCopyURL`/manifest commits issue
    /// for `id` inside this run's own folder. Commit and discard must
    /// never act on an arbitrary path.
    private func isOwnTemporary(_ url: URL, for id: UUID, ext: String) -> Bool {
        url.deletingLastPathComponent().path == runDirectory.path
            && url.lastPathComponent.hasPrefix(".\(id.uuidString).tmp-")
            && url.pathExtension == ext
    }

    /// Decodes and validates a manifest at `url`. Every field the store
    /// later relies on is checked against the name it was stored under:
    /// the document id equals the file's UUID name and the copy
    /// filename equals the one derived from it — so a crafted manifest
    /// can never point the store at another path.
    private func readRecord(at url: URL, expectedID: UUID) -> Record? {
        guard let data = try? Data(contentsOf: url),
              let record = try? decoder().decode(Record.self, from: data),
              (1...Self.schemaVersion).contains(record.schemaVersion),
              record.documentID == expectedID,
              Self.isCopyName(record.copyFilename, for: expectedID),
              !record.name.isEmpty,
              isValid(record.nativeURL), isValid(record.importedSourceURL)
        else { return nil }
        return record
    }

    /// Record source URLs are only ever informational for the recovery
    /// UI; they must still be file URLs, like the ones documents hold.
    private func isValid(_ url: URL?) -> Bool {
        url.map { $0.isFileURL } ?? true
    }

    private func readRun(_ dir: URL) -> Run? {
        let url = dir.appendingPathComponent(Self.runFilename)
        guard let data = try? Data(contentsOf: url),
              let run = try? decoder().decode(Run.self, from: data),
              (1...Self.schemaVersion).contains(run.schemaVersion),
              run.runID.uuidString == dir.lastPathComponent
        else { return nil }
        return run
    }

    /// Removes temp files this run — or a run whose owner is provably
    /// dead — left behind, and prunes finished run folders that hold no
    /// recoverable content. A folder whose owner is alive or unknown is
    /// never touched, so a run mid-`prepare` cannot be swept under its
    /// owner. Content means anything but `run.json` and temporaries;
    /// prior runs' records always remain.
    private func sweepStaleFiles() {
        guard let runs = try? files.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey])
        else { return }
        for dir in runs where UUID(uuidString: dir.lastPathComponent) != nil
                && (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            let own = dir.lastPathComponent == runID.uuidString
            let deadOwner = readRun(dir).map { !processIsAlive($0.pid) } ?? false
            guard own || deadOwner else { continue }
            let entries = (try? files.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            var hasContent = false
            for entry in entries {
                let name = entry.lastPathComponent
                if name.hasPrefix(".") && name.contains(".tmp-") {
                    try? files.removeItem(at: entry)
                } else if name != Self.runFilename {
                    hasContent = true
                }
            }
            if deadOwner && !hasContent { try? files.removeItem(at: dir) }
        }
    }

    private func encoder() -> JSONEncoder { JSONEncoder() }
    private func decoder() -> JSONDecoder { JSONDecoder() }
}
