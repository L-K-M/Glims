import Foundation

/// One cancellable delay for transient canvas admission failures. Its caller
/// keeps cached pixels and blocks immediate reads while this delay is pending.
@MainActor
final class CanvasBusyRetry {
    /// Arms once after returning; cancellation may race an already queued fire.
    typealias Arm = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    private let arm: Arm
    private var pendingID: UUID?
    private var cancellation: CanvasBusyRetryCancellation?
    private var delay: TimeInterval = 0.05

    var isPending: Bool { pendingID != nil }

    init(arm: @escaping Arm = CanvasBusyRetry.dispatchArm) { self.arm = arm }

    /// False leaves the caller's existing permanent-error path unchanged.
    @discardableResult
    func scheduleIfBusy(_ error: Error, canRetry: @escaping @MainActor () -> Bool,
                        retry: @escaping @MainActor () -> Void) -> Bool {
        guard (error as? EngineSession.EngineError)?.isBusy == true else { return false }
        guard canRetry() else { reset(); return true }
        guard pendingID == nil else { return true }
        let id = UUID()
        pendingID = id
        let interval = delay
        delay = min(delay * 2, 1)
        cancellation = CanvasBusyRetryCancellation(arm(interval) { [weak self] in
            guard let self, self.pendingID == id else { return }
            self.pendingID = nil
            self.cancellation = nil
            guard canRetry() else { self.delay = 0.05; return }
            retry()
        })
        return true
    }

    /// Success, generation replacement and shutdown all invalidate queued fires.
    func reset() {
        pendingID = nil
        cancellation = nil
        delay = 0.05
    }

    static func dispatchArm(_ delay: TimeInterval,
                            fire: @escaping @MainActor () -> Void) -> () -> Void {
        let item = DispatchWorkItem { DispatchQueue.main.async { fire() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return { item.cancel() }
    }
}

/// Automatic release also cancels when the canvas/helper dies, without making
/// a nonisolated view deinitializer enter main-actor scheduler state.
private final class CanvasBusyRetryCancellation {
    private let cancel: () -> Void
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}
