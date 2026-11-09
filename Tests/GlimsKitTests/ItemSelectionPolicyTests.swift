import XCTest
@testable import GlimsKit

/// Pure tests for the channel/path selection policy: the single-target
/// rules over the cached ordered id lists — no first-row fallback, no
/// stale remembered row — and the kind-named multi-selection refusals.
final class ItemSelectionPolicyTests: XCTestCase {
    private typealias Policy = ItemSelectionPolicy
    private typealias Kind = EngineSession.ItemSetKind

    // MARK: Channel target

    func testExactlyOneSelectedExistingChannelIsTheTarget() {
        XCTAssertEqual(Policy.channelTarget([7], existing: [7]), 7)
        XCTAssertEqual(Policy.channelTarget([7, 9], existing: [7, 9]), nil,
                       "several selected channels are ambiguous: no target, never the first")
        XCTAssertEqual(Policy.channelTarget([], existing: [7]), nil)
        XCTAssertEqual(Policy.channelTarget([7], existing: [9]), nil,
                       "a stale id is not a target")
        XCTAssertEqual(Policy.channelTarget([7, 7], existing: [7]), nil,
                       "a duplicated id is not a single target")
    }

    func testAnySelectedChannelMakesTheChannelTargetActive() {
        XCTAssertFalse(Policy.isChannelTargetActive([]))
        XCTAssertTrue(Policy.isChannelTargetActive([7]))
        XCTAssertTrue(Policy.isChannelTargetActive([7, 9]),
                      "even with no single active channel, channel-target edits refuse")
    }

    // MARK: Active path

    func testExactlyOneSelectedExistingPathIsActive() {
        XCTAssertEqual(Policy.activePath([3], existing: [3]), 3)
        XCTAssertNil(Policy.activePath([3, 4], existing: [3, 4]),
                     "several selected paths leave no active path")
        XCTAssertNil(Policy.activePath([], existing: [3]))
        XCTAssertNil(Policy.activePath([3], existing: [4]), "a stale path is never active")
    }

    // MARK: Multi and refusals

    func testIsMultiCountsPastOne() {
        XCTAssertFalse(Policy.isMulti(0))
        XCTAssertFalse(Policy.isMulti(1))
        XCTAssertTrue(Policy.isMulti(2))
    }

    func testRefusalNamesTheKindAndTheCount() {
        XCTAssertNil(Policy.refusal(count: 1, kind: .channel, action: "Paint"))
        XCTAssertNil(Policy.refusal(count: 0, kind: .path, action: "Edit the path"))
        let channel = Policy.refusal(count: 3, kind: .channel, action: "Paint")
        XCTAssertEqual(channel, "Choose one channel first: Paint works on a single channel, and 3 channels are selected.")
        let path = Policy.refusal(count: 2, kind: .path, action: "Stroke Path")
        XCTAssertEqual(path, "Choose one path first: Stroke Path works on a single path, and 2 paths are selected.")
        XCTAssertTrue(Policy.refusal(count: 2, kind: .layer, action: "Move Layer")?.contains("layers") == true)
    }
}
