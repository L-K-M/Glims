import CGlimsEngine
import XCTest
@testable import GlimsKit

/// Controllable one-shot scheduling only: no view, engine, real timer or sleep.
@MainActor
final class CanvasBusyRetryTests: XCTestCase {
    private final class Job {
        let delay: TimeInterval
        let fire: @MainActor () -> Void
        var cancelled = false
        init(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) {
            self.delay = delay; self.fire = fire
        }
    }
    private final class Clock {
        var jobs: [Job] = []
        func arm(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
            let job = Job(delay, fire)
            jobs.append(job)
            return { job.cancelled = true }
        }
    }
    private var busy: EngineSession.EngineError {
        .init(status: Int32(GLIMS_STATUS_BUSY.rawValue), message: "Busy")
    }

    func testBusyCoalescesAndDoesNotRetryInline() {
        let clock = Clock(), retry = CanvasBusyRetry(arm: clock.arm)
        var reads = 0
        XCTAssertTrue(retry.scheduleIfBusy(busy, canRetry: { true }, retry: { reads += 1 }))
        XCTAssertTrue(retry.scheduleIfBusy(busy, canRetry: { true }, retry: { reads += 100 }))
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(clock.jobs.count, 1)
        XCTAssertEqual(clock.jobs[0].delay, 0.05)
        XCTAssertTrue(retry.isPending)
        clock.jobs[0].fire()
        XCTAssertEqual(reads, 1)
        XCTAssertFalse(retry.isPending)
        clock.jobs[0].fire()
        XCTAssertEqual(reads, 1, "a queued fire is consumed at most once")
    }

    func testRepeatedBusyBacksOffToCapAndSuccessResetsDelay() {
        let clock = Clock(), retry = CanvasBusyRetry(arm: clock.arm)
        var reads = 0
        for _ in 0..<8 {
            retry.scheduleIfBusy(busy, canRetry: { true }, retry: { reads += 1 })
            clock.jobs.last!.fire()
        }
        XCTAssertEqual(clock.jobs.map(\.delay), [0.05, 0.1, 0.2, 0.4, 0.8, 1, 1, 1])
        XCTAssertEqual(reads, 8)
        retry.reset() // A successful tile store.
        retry.scheduleIfBusy(busy, canRetry: { true }, retry: {})
        XCTAssertEqual(clock.jobs.last?.delay, 0.05)
    }

    func testGenerationReplacementCancelsAndCannotWakeNewGeneration() {
        let clock = Clock(), retry = CanvasBusyRetry(arm: clock.arm)
        var generation = 1, reads = 0
        retry.scheduleIfBusy(busy, canRetry: { generation == 1 }, retry: { reads += 1 })
        let old = clock.jobs[0]
        generation = 2
        retry.reset() // Zoom, destination or backing generation changed.
        XCTAssertTrue(old.cancelled)
        retry.scheduleIfBusy(busy, canRetry: { generation == 2 }, retry: { reads += 10 })
        old.fire() // Deliberately fire despite cancellation.
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(retry.isPending, "stale callbacks cannot consume the new pending delay")
        XCTAssertEqual(clock.jobs[1].delay, 0.05)
        clock.jobs[1].fire()
        XCTAssertEqual(reads, 10)
    }

    func testClosingOrChangedGenerationAtFireDoesNotRead() {
        for closing in [false, true] {
            let clock = Clock(), retry = CanvasBusyRetry(arm: clock.arm)
            var current = true, reads = 0
            retry.scheduleIfBusy(busy, canRetry: { current }, retry: { reads += 1 })
            current = false // Either close began or the captured generation expired.
            if closing { retry.reset() } // stopRendering cancels explicitly.
            clock.jobs[0].fire()
            XCTAssertEqual(reads, 0)
            XCTAssertFalse(retry.isPending)
            current = true
            retry.scheduleIfBusy(busy, canRetry: { current }, retry: {})
            XCTAssertEqual(clock.jobs.last?.delay, 0.05)
        }
    }

    func testClosingBeforeBusyReplyDoesNotArmAndDeinitCancels() {
        let clock = Clock()
        var retry: CanvasBusyRetry? = CanvasBusyRetry(arm: clock.arm)
        var reads = 0
        XCTAssertTrue(retry!.scheduleIfBusy(busy, canRetry: { false }, retry: { reads += 1 }))
        XCTAssertTrue(clock.jobs.isEmpty)
        retry!.scheduleIfBusy(busy, canRetry: { true }, retry: { reads += 1 })
        weak var released = retry
        retry = nil
        XCTAssertNil(released, "scheduled callbacks must not keep the helper/canvas alive")
        XCTAssertTrue(clock.jobs[0].cancelled)
        clock.jobs[0].fire()
        XCTAssertEqual(reads, 0)
    }

    func testOnlyTypedBusyLeavesPermanentErrorRoute() {
        let clock = Clock(), retry = CanvasBusyRetry(arm: clock.arm)
        let errors: [Error] = [
            EngineSession.EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "Failed"),
            EngineSession.EngineError(status: Int32(GLIMS_STATUS_NOT_FOUND.rawValue), message: "Gone"),
            EngineSession.EngineError(status: Int32(GLIMS_STATUS_LOCKED.rawValue), message: "Locked"),
            NSError(domain: "other", code: Int(GLIMS_STATUS_BUSY.rawValue))
        ]
        var permanent = 0
        for error in errors {
            if !retry.scheduleIfBusy(error, canRetry: { true }, retry: { XCTFail("permanent failures cannot retry") }) {
                permanent += 1
            }
        }
        XCTAssertEqual(permanent, 4)
        XCTAssertTrue(clock.jobs.isEmpty)
        XCTAssertFalse(retry.isPending)
        XCTAssertTrue(retry.scheduleIfBusy(busy, canRetry: { true }, retry: {}))
        XCTAssertEqual(clock.jobs.count, 1)
    }
}
