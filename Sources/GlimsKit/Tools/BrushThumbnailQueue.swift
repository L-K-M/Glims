import Foundation

/// The brush chooser's lazy thumbnail pipeline. Pure bookkeeping — it never
/// touches the engine or AppKit: which catalog rows still need a native
/// render, which batch is in flight, and which attempts finished. Both
/// succeeded and failed attempts are cached for the current generation, so
/// a single bad thumbnail is never retried and never disturbs the rest of
/// the catalog. The panel drives the queue with small bounded native
/// batches through the global engine gate.
final class BrushThumbnailQueue {
    enum Status: Equatable {
        case pending
        case inFlight
        case rendered
        case failed(String)
    }

    /// One native batch renders at most this many thumbnails, so a huge
    /// catalog is previewed incrementally as rows appear, never eagerly.
    static let batchSize = 32

    private(set) var generation = 0
    private var order: [EngineSession.ResourceID] = []
    private var status: [EngineSession.ResourceID: Status] = [:]

    var pendingCount: Int { order.count }
    var inFlightCount: Int { status.values.reduce(0) { count, entry in
        if case .inFlight = entry { return count + 1 }
        return count
    } }
    /// Nothing left to render and nothing on the engine.
    var isIdle: Bool { order.isEmpty && inFlightCount == 0 }

    /// Arms the queue for a fresh catalog delivery: drops every previous
    /// attempt cache and adopts `generation`.
    func begin(generation: Int) {
        self.generation = generation
        order.removeAll()
        status.removeAll()
    }

    /// Closing the chooser invalidates everything; a late native batch is
    /// dropped by the generation check in `complete`.
    func invalidate() {
        generation += 1
        order.removeAll()
        status.removeAll()
    }

    /// Enqueues ids never requested this generation; duplicates (already
    /// pending, in flight, rendered or failed) are ignored. `priority` ids
    /// (the resolved current brush) jump to the front of the queue.
    /// Returns how many ids were newly enqueued.
    @discardableResult
    func request(_ ids: [EngineSession.ResourceID], priority: Bool = false) -> Int {
        var added = 0
        for id in ids where status[id] == nil {
            status[id] = .pending
            if priority { order.insert(id, at: 0) } else { order.append(id) }
            added += 1
        }
        return added
    }

    /// Takes the next bounded batch for a native render and marks it in
    /// flight. Returns [] while a previous batch is still in flight (no
    /// overlapping batches) or when nothing is pending.
    func beginBatch(max: Int = batchSize) -> [EngineSession.ResourceID] {
        guard inFlightCount == 0, !order.isEmpty else { return [] }
        let count = min(max, order.count)
        let batch = Array(order.prefix(count))
        order.removeFirst(count)
        for id in batch { status[id] = .inFlight }
        return batch
    }

    /// Returns a refused batch (the engine gate was busy) to the front of
    /// the pending queue, preserving its order.
    func requeue(_ ids: [EngineSession.ResourceID]) {
        for id in ids.reversed() {
            guard case .inFlight = status[id] else { continue }
            status[id] = .pending
            order.insert(id, at: 0)
        }
    }

    /// Records one native batch's outcome. Returns false — changing nothing
    /// — when `generation` is stale (the panel closed meanwhile). Rendered
    /// and failed ids are cached; neither is ever requested again this
    /// generation.
    @discardableResult
    func complete(generation: Int, rendered: [EngineSession.ResourceID],
                  failed: [EngineSession.ResourceID: String]) -> Bool {
        guard generation == self.generation else { return false }
        for id in rendered where isInFlight(id) { status[id] = .rendered }
        for (id, message) in failed where isInFlight(id) { status[id] = .failed(message) }
        return true
    }

    func status(of id: EngineSession.ResourceID) -> Status? { status[id] }

    private func isInFlight(_ id: EngineSession.ResourceID) -> Bool {
        guard let entry = status[id] else { return false }
        if case .inFlight = entry { return true }
        return false
    }
}
