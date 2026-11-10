import XCTest
@testable import GlimsKit

final class RecorderLogTests: XCTestCase {
    private struct Command: Equatable {
        let name: String
        var values: [Int]
        init(_ name: String, values: [Int] = []) {
            self.name = name
            self.values = values
        }
    }
    private typealias Log = RecorderLog<Command>

    private func assertRefusal<T>(_ expected: Log.Refusal,
                                  file: StaticString = #filePath, line: UInt = #line,
                                  _ action: () throws -> T) {
        do {
            _ = try action()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as Log.Refusal {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    private func recorded(_ names: [String]) throws -> Log {
        var log = Log()
        try log.startRecording()
        for name in names {
            let token = try log.reserve()
            try log.resolve(token, with: .success(Command(name)))
        }
        try log.stopRecording()
        return log
    }

    private func successes(_ log: Log) -> [String] {
        log.records.compactMap {
            if case .success(let command) = $0.resolution { return command.name }
            return nil
        }
    }

    func testOutOfOrderCompletionsPublishInAcceptanceOrder() throws {
        var log = Log()
        try log.startRecording()
        let first = try log.reserve()
        let second = try log.reserve()
        let third = try log.reserve()
        try log.resolve(third, with: .success(Command("third")))
        try log.resolve(second, with: .success(Command("second")))
        XCTAssertTrue(log.records.isEmpty)
        XCTAssertEqual(log.pendingCount, 1)
        try log.resolve(first, with: .success(Command("first")))
        XCTAssertEqual(successes(log), ["first", "second", "third"])
        XCTAssertEqual(log.records.map(\.ordinal), [0, 1, 2])
        XCTAssertEqual(log.pendingCount, 0)
    }

    func testFailureAndCancellationRemainVisibleInOrderedLog() throws {
        var log = Log()
        try log.startRecording()
        let first = try log.reserve()
        let second = try log.reserve()
        let third = try log.reserve()
        try log.resolve(third, with: .cancelled("user stopped"))
        try log.resolve(second, with: .failure("target removed"))
        XCTAssertTrue(log.records.isEmpty)
        try log.resolve(first, with: .success(Command("paint")))
        XCTAssertEqual(log.records.count, 3)
        guard case .failure(let failure) = log.records[1].resolution,
              case .cancelled(let cancellation) = log.records[2].resolution else {
            return XCTFail("Unsuccessful reservations must retain their status")
        }
        XCTAssertEqual(failure, "target removed")
        XCTAssertEqual(cancellation, "user stopped")
        try log.stopRecording()
        assertRefusal(.unsuccessfulRecording) { try log.beginReplay() }
    }

    func testStopFencesAdmissionButPendingWorkMaySettle() throws {
        var log = Log()
        try log.startRecording()
        let token = try log.reserve()
        try log.stopRecording()
        assertRefusal(.notRecording) { try log.reserve() }
        assertRefusal(.pendingReservations) { try log.beginReplay() }
        try log.resolve(token, with: .success(Command("late success")))
        XCTAssertEqual(successes(log), ["late success"])
        XCTAssertNil(log.replayRefusal)
        try log.beginReplay()
        XCTAssertEqual(try log.nextReplayStep().command.name, "late success")
    }

    func testClearAndNewEpochRejectOldCompletions() throws {
        var log = Log()
        try log.startRecording()
        let cleared = try log.reserve()
        log.clear()
        assertRefusal(.staleReservation) { try log.resolve(cleared, with: .success(Command("wrong"))) }
        try log.startRecording()
        let stopped = try log.reserve()
        try log.stopRecording()
        try log.startRecording()
        let current = try log.reserve()
        assertRefusal(.staleReservation) { try log.resolve(stopped, with: .success(Command("wrong"))) }
        try log.resolve(current, with: .success(Command("current")))
        XCTAssertEqual(successes(log), ["current"])
    }

    func testForeignAndDuplicateReservationsCannotChangeLog() throws {
        var first = Log()
        var second = Log()
        try first.startRecording()
        try second.startRecording()
        let foreign = try first.reserve()
        let local = try second.reserve()
        assertRefusal(.staleReservation) { try second.resolve(foreign, with: .success(Command("foreign"))) }
        XCTAssertEqual(second.pendingCount, 1)
        try second.resolve(local, with: .success(Command("local")))
        assertRefusal(.alreadyResolved) { try second.resolve(local, with: .failure("duplicate")) }
        XCTAssertEqual(successes(second), ["local"])
    }

    func testReplayRequiresStoppedCompleteSuccessfulRecording() throws {
        var log = Log()
        assertRefusal(.emptyRecording) { try log.beginReplay() }
        try log.startRecording()
        assertRefusal(.alreadyRecording) { try log.startRecording() }
        assertRefusal(.alreadyRecording) { try log.beginReplay() }
        let token = try log.reserve()
        try log.stopRecording()
        assertRefusal(.pendingReservations) { try log.beginReplay() }
        try log.resolve(token, with: .cancelled("cancelled"))
        assertRefusal(.unsuccessfulRecording) { try log.beginReplay() }
        log.clear()
        assertRefusal(.emptyRecording) { try log.beginReplay() }
    }

    func testReplayKeepsFrozenValuesAfterLogAndCallerValuesChange() throws {
        var log = Log()
        try log.startRecording()
        let token = try log.reserve()
        var command = Command("stroke", values: [1, 2])
        try log.resolve(token, with: .success(command))
        let second = try log.reserve()
        try log.resolve(second, with: .success(Command("filter")))
        try log.stopRecording()
        try log.beginReplay()
        command.values.append(3)
        log.clear()
        XCTAssertTrue(log.records.isEmpty)
        assertRefusal(.replaying) { try log.startRecording() }
        assertRefusal(.replaying) { try log.reserve() }
        let stroke = try log.nextReplayStep()
        XCTAssertEqual(stroke.command, Command("stroke", values: [1, 2]))
        try log.acknowledgeReplay(stroke.token, outcome: .success)
        let filter = try log.nextReplayStep()
        XCTAssertEqual(filter.command.name, "filter")
        try log.acknowledgeReplay(filter.token, outcome: .success)
        XCTAssertEqual(log.replayStatus, .finished(total: 2))
        assertRefusal(.notReplaying) { try log.nextReplayStep() }
    }

    func testReplayHasOnlyOneInFlightCommand() throws {
        var log = try recorded(["first", "second"])
        try log.beginReplay()
        let first = try log.nextReplayStep()
        assertRefusal(.awaitingAcknowledgment) { try log.nextReplayStep() }
        XCTAssertEqual(log.replayStatus, .running(index: 0, total: 2))
        try log.acknowledgeReplay(first.token, outcome: .success)
        let second = try log.nextReplayStep()
        assertRefusal(.staleReplayStep) { try log.acknowledgeReplay(first.token, outcome: .success) }
        XCTAssertEqual(second.index, 1)
        try log.acknowledgeReplay(second.token, outcome: .success)
        XCTAssertEqual(log.replayStatus, .finished(total: 2))
    }

    func testReplayFailureStopsBeforeNextCommand() throws {
        var log = try recorded(["first", "second", "must not run"])
        try log.beginReplay()
        let first = try log.nextReplayStep()
        try log.acknowledgeReplay(first.token, outcome: .success)
        let step = try log.nextReplayStep()
        try log.acknowledgeReplay(step.token, outcome: .failure("missing target"))
        XCTAssertEqual(log.replayStatus, .failed(index: 1, reason: "missing target"))
        assertRefusal(.notReplaying) { try log.nextReplayStep() }
        assertRefusal(.notReplaying) { try log.acknowledgeReplay(step.token, outcome: .success) }
        XCTAssertEqual(log.replayStatus, .failed(index: 1, reason: "missing target"))
    }

    func testCancellationAndRestartFenceLateAcknowledgment() throws {
        var log = try recorded(["first", "second"])
        try log.beginReplay()
        let cancelled = try log.nextReplayStep()
        try log.cancelReplay()
        XCTAssertEqual(log.replayStatus, .cancelled(index: 0))
        assertRefusal(.notReplaying) { try log.nextReplayStep() }
        assertRefusal(.notReplaying) { try log.acknowledgeReplay(cancelled.token, outcome: .success) }
        try log.beginReplay()
        let restarted = try log.nextReplayStep()
        assertRefusal(.staleReplayStep) { try log.acknowledgeReplay(cancelled.token, outcome: .success) }
        XCTAssertEqual(log.replayStatus, .running(index: 0, total: 2))
        try log.acknowledgeReplay(restarted.token, outcome: .success)
        XCTAssertEqual(try log.nextReplayStep().command.name, "second")
    }

    func testReplayRefusesRecursiveRecordingAndForeignAcknowledgment() throws {
        var first = try recorded(["one"])
        var second = try recorded(["two"])
        try first.beginReplay()
        try second.beginReplay()
        let foreign = try first.nextReplayStep()
        let local = try second.nextReplayStep()
        assertRefusal(.replaying) { try second.startRecording() }
        assertRefusal(.replaying) { try second.reserve() }
        assertRefusal(.replaying) { try second.beginReplay() }
        assertRefusal(.staleReplayStep) { try second.acknowledgeReplay(foreign.token, outcome: .success) }
        try second.acknowledgeReplay(local.token, outcome: .success)
        XCTAssertEqual(second.replayStatus, .finished(total: 1))
    }

    func testCancellationBeforeSchedulingPreventsAnyStep() throws {
        var log = try recorded(["never scheduled"])
        try log.beginReplay()
        try log.cancelReplay()
        assertRefusal(.notReplaying) { try log.nextReplayStep() }
        XCTAssertEqual(log.replayStatus, .cancelled(index: 0))
        try log.startRecording()
        XCTAssertTrue(log.records.isEmpty)
        XCTAssertTrue(log.isRecording)
        XCTAssertEqual(log.replayStatus, .idle)
    }

    func testCancellationBetweenStepsPreservesNextIndex() throws {
        var log = try recorded(["first", "never scheduled"])
        try log.beginReplay()
        let first = try log.nextReplayStep()
        try log.acknowledgeReplay(first.token, outcome: .success)
        try log.cancelReplay()
        XCTAssertEqual(log.replayStatus, .cancelled(index: 1))
        assertRefusal(.notReplaying) { try log.nextReplayStep() }
        log.clear()
        XCTAssertEqual(log.replayStatus, .idle)
    }
}
