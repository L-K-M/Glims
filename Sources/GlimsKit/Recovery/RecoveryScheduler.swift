import AppKit
import Foundation

/// A document the recovery scheduler can copy, reduced to the reads and
/// the one write it needs. `ImageDocument` conforms; unit tests drive
/// fakes. Everything runs on the main actor.
@MainActor
protocol RecoveryCandidate: AnyObject {
    /// The identity the document's recovery record is filed under while
    /// it is open.
    var recoveryID: UUID { get }
    /// A consistent read of the state admission and suppression check.
    var recoverySnapshot: RecoverySnapshot { get }
    /// A counted, engine-wide-admitted native copy at `url`
    /// (`ImageDocument.saveCopy` — never a direct session save).
    func saveRecoveryCopy(to url: URL, completion: @escaping @MainActor (Error?) -> Void)
}

/// The document state one recovery pass consults.
struct RecoverySnapshot: Equatable {
    var name = ""
    var nativeURL: URL?
    var importedSourceURL: URL?
    /// The undo-history revision; unchanged since the last copy
    /// suppresses a duplicate write. `nil` never suppresses.
    var revision: UInt64?
    /// Closing now would lose work.
    var isDirty = false
    /// A pointer stroke is being painted right now.
    var strokeIsActive = false
    /// No queued or running work, no closing/clipboard/preview gate and
    /// no engine-wide activity or plug-in (`pendingWork == 0 &&
    /// acceptsEdits` on the document).
    var canAcceptCopy = false
    /// The document has started closing; its copy must not be kept.
    var isClosing = false
}

/// Periodically writes native recovery copies of changed, dirty
/// documents into a `RecoveryStore`.
///
/// Copies are serialized: at most one `saveCopy` — including the
/// store-finalize stage — is in flight at a time, counted in `copying`
/// for the scheduler's whole lifecycle. Each pass walks the tracked
/// documents in round-robin order and copies every eligible one; a
/// document whose history revision already has a committed copy is
/// skipped. `interval` (default 120 s) is the idle gap between passes.
///
/// Engine-wide admission commits every live document's in-flight text,
/// field and stroke input before entering the engine — fine for a
/// user's Save, never acceptable as a side effect of a background
/// copy. So a pass only runs while every tracked document reports ready
/// (no canvas text editor, no field editor in its window, preview or
/// aimed palettes, no active stroke); the check and the admission share
/// one main-actor turn, leaving no event-loop gap an edit could slip
/// through.
@MainActor
final class RecoveryScheduler {

    /// Arms one tick; returns its cancellation. Production uses a
    /// one-shot Timer; tests record the interval and fire by hand.
    typealias Arm = @MainActor (_ interval: TimeInterval,
                                _ tick: @escaping @MainActor () -> Void) -> () -> Void

    nonisolated static let defaultInterval: TimeInterval = 120

    private final class Entry {
        weak var document: (any RecoveryCandidate)?
        /// The document window's own readiness check; false means a
        /// text or field edit is in flight and nothing may be committed.
        let isReady: @MainActor () -> Bool
        /// The revision this run last committed a copy for.
        var copiedRevision: UInt64?
        init(document: any RecoveryCandidate, isReady: @escaping @MainActor () -> Bool) {
            self.document = document
            self.isReady = isReady
        }
    }

    let store: RecoveryStore
    let interval: TimeInterval
    private let arm: Arm
    private var entries: [UUID: Entry] = [:]
    /// Registration order; the pass cursor walks it round-robin.
    private var order: [UUID] = []
    private var cursor = 0
    private var running = false
    private var cancelTick: (() -> Void)?
    /// Documents this pass already served — a failed copy waits for the
    /// next pass instead of spinning inside this one.
    private var servedThisPass: Set<UUID> = []
    /// The document whose copy is being written and finalized; covers
    /// admission, the engine write and the store commit, so the whole
    /// stage counts for lifecycle and nothing overlaps it.
    private(set) var copying: UUID?

    init(store: RecoveryStore, interval: TimeInterval = RecoveryScheduler.defaultInterval,
         arm: @escaping Arm = RecoveryScheduler.timerArm) {
        self.store = store
        self.interval = interval
        self.arm = arm
    }

    /// The default arm: a one-shot Timer; the scheduler re-arms after
    /// each pass, so `interval` is idle time between passes, not a
    /// period a long pass can overrun.
    static func timerArm(interval: TimeInterval, tick: @escaping @MainActor () -> Void) -> () -> Void {
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { _ in
            DispatchQueue.main.async { tick() }
        }
        return { timer.invalidate() }
    }

    func start() {
        guard !running else { return }
        running = true
        armNext()
    }

    /// Stops future passes. A copy already in flight finishes and is
    /// cleaned up normally.
    func stop() {
        running = false
        cancelTick?()
        cancelTick = nil
    }

    /// Registers a document's window-scoped readiness. Documents hold
    /// weakly: registration is per open document, and `untrack` on a
    /// real close drops its record.
    func track(_ document: any RecoveryCandidate, isReady: @escaping @MainActor () -> Bool) {
        let id = document.recoveryID
        guard entries[id] == nil else { return }
        let entry = Entry(document: document, isReady: isReady)
        entry.copiedRevision = store.record(for: id)?.revision
        entries[id] = entry
        order.append(id)
    }

    /// A document closed for good: stop tracking it and delete its
    /// record — no recovery copy survives an explicit close. A copy
    /// still in flight finishes writing to its temporary, which the
    /// completion then discards.
    func untrack(_ document: any RecoveryCandidate) {
        let id = document.recoveryID
        entries[id] = nil
        order.removeAll { $0 == id }
        if cursor > order.count { cursor = order.count }
        store.discard(id)
    }

    /// One timer tick: begins a pass unless a copy is still running.
    func tick() {
        guard running, copying == nil else { return }
        servedThisPass = []
        serveNextCandidate()
    }

    private func armNext() {
        guard running else { return }
        cancelTick = arm(interval) { [weak self] in self?.tick() }
    }

    /// Ends a pass and schedules the next one after the idle interval.
    private func endPass() {
        armNext()
    }

    /// Copies the next eligible document, then resumes; with none left
    /// the pass ends.
    private func serveNextCandidate() {
        guard running else { return endPass() }
        guard let (id, document) = nextCandidate() else { return endPass() }
        beginCopy(id: id, document: document)
    }

    /// Drops registrations whose documents are gone. Records stay:
    /// only an explicit close deletes them.
    private func pruneDead() {
        let dead = order.filter { entries[$0]?.document == nil }
        dead.forEach { entries[$0] = nil }
        order.removeAll { dead.contains($0) }
        if cursor > order.count { cursor = order.count }
    }

    /// The next document worth copying, walking on from where the last
    /// candidate was taken so one document cannot starve the others.
    /// Returns nil when any tracked document has input in flight —
    /// admission would commit it for every document, not just this one —
    /// or when nothing is both dirty and changed.
    private func nextCandidate() -> (UUID, any RecoveryCandidate)? {
        pruneDead()
        guard !order.isEmpty else { return nil }
        // Admission commits every live document's in-flight input, so
        // any unreadiness anywhere defers the whole pass.
        guard entries.allSatisfy({ $0.value.isReady() && $0.value.document?.recoverySnapshot.strokeIsActive != true })
        else { return nil }
        cursor %= order.count
        for _ in order.indices {
            let id = order[cursor]
            cursor = (cursor + 1) % order.count
            guard !servedThisPass.contains(id),
                  let document = entries[id]?.document else { continue }
            let snapshot = document.recoverySnapshot
            guard snapshot.isDirty, snapshot.canAcceptCopy,
                  !snapshot.strokeIsActive, !snapshot.isClosing else { continue }
            if let revision = snapshot.revision,
               entries[id]?.copiedRevision == revision,
               store.copyExists(for: id) { continue }
            return (id, document)
        }
        return nil
    }

    /// Writes the copy to its temporary name through document admission,
    /// then commits it over the last one. A failure or a document that
    /// closed meanwhile discards the temporary and keeps the previous
    /// record; the document is retried on a later pass.
    private func beginCopy(id: UUID, document: any RecoveryCandidate) {
        let temp = store.temporaryCopyURL(for: id)
        let snapshot = document.recoverySnapshot
        copying = id
        servedThisPass.insert(id)
        document.saveRecoveryCopy(to: temp) { [weak self] error in
            guard let self else { return }
            self.copying = nil
            let entry = self.entries[id]
            if error == nil, entry != nil,
               let live = entry?.document, !live.recoverySnapshot.isClosing {
                do {
                    let record = try self.store.commitCopy(at: temp, for: id, metadata: Metadata(
                        name: snapshot.name, nativeURL: snapshot.nativeURL,
                        importedSourceURL: snapshot.importedSourceURL,
                        revision: snapshot.revision))
                    entry?.copiedRevision = record.revision
                } catch {
                    self.store.discardTemporary(temp)
                }
            } else {
                self.store.discardTemporary(temp)
            }
            self.serveNextCandidate()
        }
    }

    private typealias Metadata = RecoveryStore.Metadata
}

extension ImageDocument: RecoveryCandidate {
    var recoverySnapshot: RecoverySnapshot {
        RecoverySnapshot(name: name,
                         nativeURL: fileState.nativeURL,
                         importedSourceURL: fileState.importedSourceURL,
                         revision: history?.revision,
                         isDirty: hasUnsavedChanges,
                         strokeIsActive: strokeIsActive,
                         canAcceptCopy: pendingWork == 0 && acceptsEdits,
                         isClosing: isClosing)
    }

    /// The copy goes through `saveCopy` so it shares the engine-wide
    /// admission and close-drain counting every file call gets.
    func saveRecoveryCopy(to url: URL, completion: @escaping @MainActor (Error?) -> Void) {
        saveCopy(to: url, label: "Saving a recovery copy", completion: completion)
    }
}
