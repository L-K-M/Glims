import XCTest
@testable import GlimsKit

final class LayerRestorePolicyTests: XCTestCase {
    private let unlocked = EngineSession.LayerLockState(local: [], effective: [])
    private let editableText = EngineSession.LayerSource(kind: .text, isRasterized: false, hasSource: true)
    private let rasterizedText = EngineSession.LayerSource(kind: .text, isRasterized: true, hasSource: true)

    private func refusal(_ ids: [Int32],
                         layerIDs: Set<Int32>? = nil,
                         sources: [Int32: EngineSession.LayerSource]? = nil,
                         locks: [Int32: EngineSession.LayerLockState]? = nil,
                         request: LayerRestorePolicy.Request = .confirmation) -> String? {
        let knownIDs = Set(ids)
        return LayerRestorePolicy.refusal(ids: ids, layerIDs: layerIDs ?? knownIDs,
            sources: sources ?? Dictionary(uniqueKeysWithValues: knownIDs.map { ($0, rasterizedText) }),
            locks: locks ?? Dictionary(uniqueKeysWithValues: knownIDs.map { ($0, unlocked) }),
            request: request)
    }

    func testRetainedTextLinkAndVectorSourcesAcceptEitherCapturedOrder() {
        let sources: [Int32: EngineSession.LayerSource] = [
            2: rasterizedText,
            7: .init(kind: .link, isRasterized: true, hasSource: true),
            9: .init(kind: .vector, isRasterized: true, hasSource: true),
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
            for request: LayerRestorePolicy.Request in [.confirmation, .explicitCommand] {
                let reason = refusal(ids, request: request)
                XCTAssertNotNil(reason, "Must refuse the entire captured vector: \(ids)")
                XCTAssertFalse(reason?.isEmpty ?? true)
            }
        }
    }

    func testMissingLastRowSourceOrLockCacheRefusesTheWholeVector() {
        let ids: [Int32] = [3, 8]
        XCTAssertNil(refusal(ids))
        XCTAssertNotNil(refusal(ids, layerIDs: [3]))
        XCTAssertNotNil(refusal(ids, sources: [3: rasterizedText]))
        XCTAssertNotNil(refusal(ids, locks: [3: unlocked]))
    }

    func testPixelsGroupsAndMissingRetainedSourceRefuse() {
        for kind: EngineSession.LayerKind in [.pixel, .group] {
            XCTAssertNotNil(refusal([3, 8], sources: [3: rasterizedText, 8: .init(kind: kind, isRasterized: true, hasSource: true)]))
        }
        for kind: EngineSession.LayerKind in [.text, .link, .vector] {
            for rasterized in [false, true] {
                XCTAssertNotNil(refusal([3, 8], sources: [3: rasterizedText, 8: .init(kind: kind, isRasterized: rasterized, hasSource: false)]))
            }
        }
    }

    func testMixedEditableNoopsAndRasterizedMembersAreEligible() {
        for kind: EngineSession.LayerKind in [.text, .link, .vector] {
            let sources: [Int32: EngineSession.LayerSource] = [
                3: rasterizedText, 8: .init(kind: kind, isRasterized: false, hasSource: true),
            ]
            XCTAssertNil(refusal([3, 8], sources: sources), "Mixed request must be eligible for \(kind)")
        }
    }

    func testConfirmationNeedsRasterizedMemberButExplicitCommandAllowsNoop() {
        let sources: [Int32: EngineSession.LayerSource] = [
            3: editableText, 8: .init(kind: .link, isRasterized: false, hasSource: true),
        ]
        XCTAssertNotNil(refusal([3, 8], sources: sources, request: .confirmation))
        XCTAssertNil(refusal([3, 8], sources: sources, request: .explicitCommand))
    }

    func testEffectivePixelsOrPositionLocksRefuseInheritedLocks() {
        let localPosition = EngineSession.LayerLockState(local: [.position], effective: [.position])
        let inheritedPixels = EngineSession.LayerLockState(local: [], effective: [.pixels, .alpha])
        XCTAssertNotNil(refusal([3, 8], locks: [3: unlocked, 8: localPosition]))
        XCTAssertNotNil(refusal([3, 8], locks: [3: unlocked, 8: inheritedPixels]))
        let alphaOnly = EngineSession.LayerLockState(local: [.alpha], effective: [.alpha])
        XCTAssertNil(refusal([3, 8], locks: [3: unlocked, 8: alphaOnly]))
    }
}
