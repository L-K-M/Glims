import XCTest
@testable import GlimsKit

final class LayerFitPolicyTests: XCTestCase {
    private func cache(_ ids: [Int32]) -> (
        kinds: [Int32: EngineSession.LayerKind],
        locks: [Int32: EngineSession.LayerLockState]
    ) {
        let unique = Set(ids)
        let kinds: [Int32: EngineSession.LayerKind] = Dictionary(uniqueKeysWithValues: unique.map { ($0, .pixel) })
        let locks: [Int32: EngineSession.LayerLockState] = Dictionary(
            uniqueKeysWithValues: unique.map { ($0, .init(local: [], effective: [])) })
        return (kinds, locks)
    }

    func testPixelSelectionAcceptsEitherOrderAndIgnoresUnselectedKind() {
        let ids: [Int32] = [9, 3]
        var state = cache(ids)
        state.kinds[44] = .group // An unselected group does not disqualify pixel layers.
        XCTAssertNil(LayerFitPolicy.refusal(ids: ids, kinds: state.kinds, locks: state.locks))
        XCTAssertNil(LayerFitPolicy.refusal(ids: [3, 9], kinds: state.kinds, locks: state.locks))
    }

    func testOneAnd256PositiveUniqueLayersAreAccepted() {
        let largest: [Int32] = Array(Int32(1)...Int32(256))
        for ids in [[Int32.max], largest] {
            let state = cache(ids)
            XCTAssertNil(LayerFitPolicy.refusal(ids: ids, kinds: state.kinds, locks: state.locks))
        }
    }

    func testEmptyInvalidDuplicateAnd257SelectionsAreRefused() {
        let invalid: [[Int32]] = [[], [0], [-1], [Int32.min], [7, 7], Array(Int32(1)...Int32(257))]
        for ids in invalid {
            // Even invalid ids are cached, isolating vector validation from stale-state checks.
            let state = cache(ids)
            let reason = LayerFitPolicy.refusal(ids: ids, kinds: state.kinds, locks: state.locks)
            XCTAssertNotNil(reason, "Must refuse the complete invalid vector: \(ids)")
            XCTAssertFalse(reason?.isEmpty ?? true)
        }
    }

    func testEverySelectedLayerRequiresCachedKindAndLocks() {
        let ids: [Int32] = [7, 9]
        let complete = cache(ids)
        XCTAssertNil(LayerFitPolicy.refusal(ids: ids, kinds: complete.kinds, locks: complete.locks))
        var kinds = complete.kinds
        kinds.removeValue(forKey: 9)
        XCTAssertNotNil(LayerFitPolicy.refusal(ids: ids, kinds: kinds, locks: complete.locks))
        var locks = complete.locks
        locks.removeValue(forKey: 9)
        XCTAssertNotNil(LayerFitPolicy.refusal(ids: ids, kinds: complete.kinds, locks: locks))
    }

    func testGroupsAndGenuineStructuredSourcesAreRefused() {
        let ids: [Int32] = [2, 5]
        for kind: EngineSession.LayerKind in [.group, .text, .link, .vector] {
            var state = cache(ids)
            state.kinds[5] = kind // A nonprimary selected source must also be checked.
            let reason = LayerFitPolicy.refusal(ids: ids, kinds: state.kinds, locks: state.locks)
            XCTAssertNotNil(reason, "Must refuse \(kind)")
            XCTAssertTrue(reason?.contains("Rasterize") == true)
        }
    }

    func testAlphaOnlyLocksAllowFit() {
        let ids: [Int32] = [2, 5]
        var state = cache(ids)
        state.locks[5] = .init(local: [.alpha], effective: [.alpha])
        XCTAssertNil(LayerFitPolicy.refusal(ids: ids, kinds: state.kinds, locks: state.locks))
    }

    func testInheritedPixelLockRefusesEvenWithLocalLocksClear() {
        let ids: [Int32] = [2, 5]
        var state = cache(ids)
        state.locks[5] = .init(local: [], effective: [.pixels])
        XCTAssertTrue(state.locks[5]?.local.isEmpty == true)
        let reason = LayerFitPolicy.refusal(ids: ids, kinds: state.kinds, locks: state.locks)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("parent groups") == true)
    }

    func testInheritedPositionLockRefusesEvenWithLocalLocksClear() {
        let ids: [Int32] = [2, 5]
        var state = cache(ids)
        state.locks[5] = .init(local: [], effective: [.position, .alpha])
        XCTAssertTrue(state.locks[5]?.local.isEmpty == true)
        let reason = LayerFitPolicy.refusal(ids: ids, kinds: state.kinds, locks: state.locks)
        XCTAssertNotNil(reason)
        XCTAssertTrue(reason?.contains("position") == true)
    }
}
