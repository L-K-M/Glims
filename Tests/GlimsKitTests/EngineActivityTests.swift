import XCTest
@testable import GlimsKit

@MainActor
final class EngineActivityTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTAssertTrue(condition())
    }

    func testRefusesOverlappingAdmissionWithoutBlockingMain() {
        let activity = EngineActivity()
        let release = DispatchSemaphore(value: 0)
        var finished = false
        defer { release.signal() }
        XCTAssertTrue(activity.perform(label: "Saving", work: { release.wait() }) { finished = true })
        XCTAssertTrue(activity.isBusy)
        XCTAssertFalse(activity.perform(label: "Overlapping", work: { XCTFail("Refused work ran") }) {})
        release.signal()
        waitUntil { finished }
        XCTAssertFalse(activity.isBusy)
    }

    func testQueuedCleanupWaitsWhenAnEarlierIdleActionStartsAnotherOperation() {
        let activity = EngineActivity()
        let first = DispatchSemaphore(value: 0)
        let second = DispatchSemaphore(value: 0)
        var secondStarted = false
        var cleanedUp = false
        defer { first.signal(); second.signal() }
        XCTAssertTrue(activity.perform(label: "First", work: { first.wait() }) {})
        activity.performWhenReady(label: "Second", work: {
            DispatchQueue.main.async { secondStarted = true }
            second.wait()
        })
        activity.whenIdle { cleanedUp = true }
        first.signal()
        waitUntil { secondStarted }
        XCTAssertTrue(activity.isBusy)
        XCTAssertFalse(cleanedUp, "Cleanup must wait for the new engine owner too")
        second.signal()
        waitUntil { cleanedUp }
        XCTAssertFalse(activity.isBusy)
    }
}
