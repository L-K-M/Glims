import XCTest
@testable import GlimsKit

@MainActor
final class InfoPointerSamplingTests: XCTestCase {
    func testOnlyLatestPositionIsReadAfterAnInFlightRequest() {
        typealias Sampler = InfoPointerSampling
        let first = Sampler.Position(x: 1, y: 2)
        let skipped = Sampler.Position(x: 3, y: 4)
        let latest = Sampler.Position(x: 5, y: 6)
        let sample = EngineSession.SampledColor(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        var requested: [Sampler.Position] = []
        var replies: [(@MainActor (Sampler.Sample) -> Void)] = []
        var displayed: [Sampler.Position] = []
        let sampler = Sampler(read: { position, completion in
            requested.append(position)
            replies.append(completion)
        }, publish: { position, _ in displayed.append(position) })

        sampler.request(first)
        sampler.request(skipped)
        sampler.request(latest)
        XCTAssertEqual(requested, [first])
        replies.removeFirst()(.success(sample))
        XCTAssertEqual(requested, [first, latest])
        XCTAssertTrue(displayed.isEmpty)
        replies.removeFirst()(.success(sample))
        XCTAssertEqual(displayed, [latest])
    }

    func testInvalidationDropsAnOldResultAndItsWaitingPosition() {
        typealias Sampler = InfoPointerSampling
        let sample = EngineSession.SampledColor(red: 0, green: 0, blue: 0, alpha: 1)
        var requested: [Sampler.Position] = []
        var replies: [(@MainActor (Sampler.Sample) -> Void)] = []
        var displayed: [Sampler.Position] = []
        let sampler = Sampler(read: { position, completion in
            requested.append(position)
            replies.append(completion)
        }, publish: { position, _ in displayed.append(position) })

        sampler.request(.init(x: 1, y: 1))
        sampler.request(.init(x: 2, y: 2))
        sampler.invalidate()
        replies.removeFirst()(.success(sample))
        XCTAssertEqual(requested.count, 1)
        XCTAssertTrue(displayed.isEmpty)
        let newPosition = Sampler.Position(x: 9, y: 9)
        sampler.request(newPosition)
        replies.removeFirst()(.success(sample))
        XCTAssertEqual(displayed, [newPosition])
    }
}
