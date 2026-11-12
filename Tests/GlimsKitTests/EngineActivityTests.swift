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
        var admissions = 0
        defer { release.signal() }
        XCTAssertTrue(activity.perform(label: "Saving", didAdmit: {
            XCTAssertTrue(activity.isBusy)
            admissions += 1
        }, work: { release.wait() }) { finished = true })
        XCTAssertEqual(admissions, 1)
        XCTAssertTrue(activity.isBusy)
        XCTAssertFalse(activity.perform(label: "Overlapping", didAdmit: { admissions += 1 },
                                        work: { XCTFail("Refused work ran") }) {})
        XCTAssertEqual(admissions, 1, "Refused work never reserves command state")
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
