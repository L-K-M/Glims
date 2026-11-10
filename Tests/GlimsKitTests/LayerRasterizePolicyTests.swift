import XCTest
@testable import GlimsKit

final class LayerRasterizePolicyTests: XCTestCase {
    private let unlocked = EngineSession.LayerLockState(local: [], effective: [])
    private let editableText = EngineSession.LayerSource(kind: .text, isRasterized: false, hasSource: true)
    private let rasterizedText = EngineSession.LayerSource(kind: .text, isRasterized: true, hasSource: true)

    private func refusal(_ ids: [Int32],
                         layerIDs: Set<Int32>? = nil,
                         sources: [Int32: EngineSession.LayerSource]? = nil,
                         locks: [Int32: EngineSession.LayerLockState]? = nil,
                         request: LayerRasterizePolicy.Request = .confirmation) -> String? {
        let knownIDs = Set(ids)
        return LayerRasterizePolicy.refusal(ids: ids, layerIDs: layerIDs ?? knownIDs,
            sources: sources ?? Dictionary(uniqueKeysWithValues: knownIDs.map { ($0, editableText) }),
            locks: locks ?? Dictionary(uniqueKeysWithValues: knownIDs.map { ($0, unlocked) }),
            request: request)
    }

    func testRetainedTextLinkAndVectorSourcesAcceptEitherCapturedOrder() {
        let sources: [Int32: EngineSession.LayerSource] = [
            2: editableText,
            7: .init(kind: .link, isRasterized: false, hasSource: true),
            9: .init(kind: .vector, isRasterized: false, hasSource: true),
            44: .init(kind: .group, isRasterized: false, hasSource: false),
        ]
        XCTAssertNil(refusal([2, 7, 9], sources: sources))
        XCTAssertNil(refusal([9, 2, 7], sources: sources))
    }

    func testOneAnd256DistinctPositiveSourcesAreAccepted() {
        XCTAssertNil(refusal([Int32.max]))
        XCTAssertNil(refusal(Array(Int32(1)...Int32(256))))
    }

    func testInvalidVectorsRefuseEvenWhenAllTheirIDsAreCached() {
        let invalid: [[Int32]] = [[], [0], [-1], [Int32.min], [7, 7], Array(Int32(1)...Int32(257))]
        for ids in invalid {
            for request: LayerRasterizePolicy.Request in [.confirmation, .explicitCommand] {
                let reason = refusal(ids, request: request)
                XCTAssertNotNil(reason, "Must refuse the entire captured vector: \(ids)")
                XCTAssertFalse(reason?.isEmpty ?? true)
            }
        }
    }

    func testMissingLastRowSourceOrLockCacheRefusesTheWholeVector() {
        let ids: [Int32] = [3, 8]
        XCTAssertNil(refusal(ids))
        // A stale source/lock cache must not turn an absent row into a layer.
        XCTAssertNotNil(refusal(ids, layerIDs: [3]))
        XCTAssertNotNil(refusal(ids, sources: [3: editableText]))
        XCTAssertNotNil(refusal(ids, locks: [3: unlocked]))
    }

    func testPixelsAndGroupsRefuseEvenWithAnInventedRetainedSourceFlag() {
        for kind: EngineSession.LayerKind in [.pixel, .group] {
            let sources: [Int32: EngineSession.LayerSource] = [
                3: editableText, 8: .init(kind: kind, isRasterized: true, hasSource: true),
            ]
            XCTAssertNotNil(refusal([3, 8], sources: sources), "Must refuse \(kind)")
        }
    }

    func testMissingRetainedSourceRefusesEditableAndRasterizedMembers() {
        for kind: EngineSession.LayerKind in [.text, .link, .vector] {
            for rasterized in [false, true] {
                let sources: [Int32: EngineSession.LayerSource] = [
                    3: editableText, 8: .init(kind: kind, isRasterized: rasterized, hasSource: false),
                ]
                XCTAssertNotNil(refusal([3, 8], sources: sources))
                XCTAssertNotNil(refusal([3, 8], sources: sources, request: .explicitCommand))
            }
        }
    }

    func testMixedAlreadyRasterizedAndEditableMembersAreEligible() {
        for kind: EngineSession.LayerKind in [.text, .link, .vector] {
            let sources: [Int32: EngineSession.LayerSource] = [
                3: .init(kind: kind, isRasterized: true, hasSource: true), 8: editableText,
            ]
            XCTAssertNil(refusal([3, 8], sources: sources))
            XCTAssertNil(refusal([8, 3], sources: sources, request: .explicitCommand))
        }
    }

    func testAllNoOpIsAValidExplicitCommandButOffersNoConfirmation() {
        let sources: [Int32: EngineSession.LayerSource] = [
            3: rasterizedText, 8: .init(kind: .link, isRasterized: true, hasSource: true),
        ]
        XCTAssertNil(refusal([3, 8], sources: sources, request: .explicitCommand))
        XCTAssertNotNil(refusal([3, 8], sources: sources, request: .confirmation))
    }

    func testAlphaOnlyLocksDoNotBlockRasterization() {
        let locks: [Int32: EngineSession.LayerLockState] = [
            3: unlocked, 8: .init(local: [.alpha], effective: [.alpha]),
        ]
        XCTAssertNil(refusal([3, 8], locks: locks))
    }

    func testEffectivePixelAndPositionLocksIncludeParentLocks() {
        for lock: EngineSession.LayerLocks in [.pixels, .position, [.pixels, .position, .alpha]] {
            for local: EngineSession.LayerLocks in [[], lock] {
                let locks: [Int32: EngineSession.LayerLockState] = [
                    3: unlocked, 8: .init(local: local, effective: lock),
                ]
                let reason = refusal([3, 8], locks: locks)
                XCTAssertNotNil(reason)
                XCTAssertTrue(reason?.contains("parent groups") == true)
            }
        }
    }

    func testNoOpMembersStillRequireKnownLocksAndUnlockedPixelsAndPosition() {
        let sources: [Int32: EngineSession.LayerSource] = [3: rasterizedText, 8: editableText]
        XCTAssertNotNil(refusal([3, 8], sources: sources, locks: [8: unlocked]))
        for lock: EngineSession.LayerLocks in [.pixels, .position] {
            XCTAssertNotNil(refusal([3, 8], sources: sources,
                locks: [3: .init(local: [], effective: lock), 8: unlocked]))
        }
    }
}
