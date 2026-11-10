import Foundation

/// A single owner's semantic recording and replay state. Callers serialize access
/// and supply immutable value commands; reference payloads with mutable state are
/// not suitable snapshots. No execution closures or engine handles are retained.
struct RecorderLog<Command> {
    struct Reservation: Equatable {
        fileprivate let epoch: UUID
        fileprivate let ordinal: Int
    }

    enum Resolution {
        case success(Command)
        case failure(String)
        case cancelled(String)
    }

    struct Record {
        let ordinal: Int
        let resolution: Resolution
    }

    struct ReplayToken: Equatable {
        fileprivate let generation: UUID
        fileprivate let index: Int
    }

    struct ReplayStep {
        let index: Int
        let command: Command
        let token: ReplayToken
    }

    enum ReplayOutcome {
        case success
        case failure(String)
    }

    enum ReplayStatus: Equatable {
        case idle
        case running(index: Int, total: Int)
        case finished(total: Int)
        case failed(index: Int, reason: String)
        case cancelled(index: Int)
    }

    enum Refusal: Error, Equatable {
        case alreadyRecording
        case notRecording
        case replaying
        case pendingReservations
        case unsuccessfulRecording
        case emptyRecording
        case staleReservation
        case alreadyResolved
        case notReplaying
        case awaitingAcknowledgment
        case staleReplayStep
    }

    private(set) var isRecording = false
    /// Only the settled acceptance-order prefix is published. Later outcomes
    /// wait for earlier reservations, including failures and cancellations.
    private(set) var records: [Record] = []
    private(set) var replayStatus: ReplayStatus = .idle

    private var epoch = UUID()
    private var nextOrdinal = 0
    private var unresolved: Set<Int> = []
    private var buffered: [Int: Resolution] = [:]
    private var replayGeneration = UUID()
    private var replayCommands: [Command] = []
    private var inFlight: ReplayToken?

    var pendingCount: Int { unresolved.count }

    var isReplaying: Bool {
        if case .running = replayStatus { return true }
        return false
    }

    /// Starting after Stop begins a fresh epoch, even if old work is pending.
    /// Its late callbacks cannot become commands in the new recording.
    mutating func startRecording() throws {
        guard !isReplaying else { throw Refusal.replaying }
        guard !isRecording else { throw Refusal.alreadyRecording }
        clear()
        isRecording = true
    }

    mutating func stopRecording() throws {
        guard !isReplaying else { throw Refusal.replaying }
        guard isRecording else { throw Refusal.notRecording }
        isRecording = false
    }

    /// Clearing the log does not mutate a replay's frozen command snapshot.
    mutating func clear() {
        epoch = UUID()
        nextOrdinal = 0
        unresolved.removeAll()
        buffered.removeAll()
        records.removeAll()
        isRecording = false
        if !isReplaying {
            replayStatus = .idle
            replayCommands.removeAll()
            inFlight = nil
        }
    }

    mutating func reserve() throws -> Reservation {
        guard !isReplaying else { throw Refusal.replaying }
        guard isRecording else { throw Refusal.notRecording }
        let ordinal = nextOrdinal
        nextOrdinal += 1
        unresolved.insert(ordinal)
        return Reservation(epoch: epoch, ordinal: ordinal)
    }

    /// Resolution is separate from admission so commands whose immutable values
    /// are only final at completion (for example a whole stroke) can reserve first.
    mutating func resolve(_ reservation: Reservation, with resolution: Resolution) throws {
        guard reservation.epoch == epoch else { throw Refusal.staleReservation }
        guard unresolved.remove(reservation.ordinal) != nil else { throw Refusal.alreadyResolved }
        buffered[reservation.ordinal] = resolution
        while let next = buffered.removeValue(forKey: records.count) {
            records.append(Record(ordinal: records.count, resolution: next))
        }
    }

    var replayRefusal: Refusal? {
        if isReplaying { return .replaying }
        if isRecording { return .alreadyRecording }
        if pendingCount != 0 { return .pendingReservations }
        for record in records {
            switch record.resolution {
            case .success: break
            case .failure, .cancelled: return .unsuccessfulRecording
            }
        }
        return records.isEmpty ? .emptyRecording : nil
    }

    /// Failed or cancelled reservations never silently become a partial macro.
    mutating func beginReplay() throws {
        if let refusal = replayRefusal { throw refusal }
        replayCommands = records.compactMap { record in
            if case .success(let command) = record.resolution { return command }
            return nil
        }
        replayGeneration = UUID()
        inFlight = nil
        replayStatus = .running(index: 0, total: replayCommands.count)
    }

    mutating func nextReplayStep() throws -> ReplayStep {
        guard case .running(let index, _) = replayStatus else { throw Refusal.notReplaying }
        guard inFlight == nil else { throw Refusal.awaitingAcknowledgment }
        let token = ReplayToken(generation: replayGeneration, index: index)
        inFlight = token
        return ReplayStep(index: index, command: replayCommands[index], token: token)
    }

    mutating func acknowledgeReplay(_ token: ReplayToken, outcome: ReplayOutcome) throws {
        guard case .running(let index, let total) = replayStatus else { throw Refusal.notReplaying }
        guard inFlight == token else { throw Refusal.staleReplayStep }
        inFlight = nil
        switch outcome {
        case .success:
            let next = index + 1
            replayStatus = next == total ? .finished(total: total) : .running(index: next, total: total)
        case .failure(let reason):
            replayStatus = .failed(index: index, reason: reason)
        }
        if !isReplaying { replayCommands.removeAll() }
    }

    /// The current command may already be executing; cancellation prevents any
    /// later scheduling, and its eventual acknowledgment cannot restart replay.
    mutating func cancelReplay() throws {
        guard case .running(let index, _) = replayStatus else { throw Refusal.notReplaying }
        inFlight = nil
        replayCommands.removeAll()
        replayStatus = .cancelled(index: index)
    }
}
