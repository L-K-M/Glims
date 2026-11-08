import XCTest
@testable import GlimsKit

/// Pure cached-state gating for Layer ▸ Rasterize Layer… and
/// Layer ▸ Restore Layer Source…: no engine, no window, no document —
/// only the cached source, lock and target inputs the menus read.
final class LayerSourceMenuPolicyTests: XCTestCase {
    private let editableText = EngineSession.LayerSource(kind: .text, isRasterized: false, hasSource: true)
    private let rasterizedText = EngineSession.LayerSource(kind: .text, isRasterized: true, hasSource: true)
    private let editableLink = EngineSession.LayerSource(kind: .link, isRasterized: false, hasSource: true)
    private let editableVector = EngineSession.LayerSource(kind: .vector, isRasterized: false, hasSource: true)
    private let rasterizedVector = EngineSession.LayerSource(kind: .vector, isRasterized: true, hasSource: true)
    private let pixel = EngineSession.LayerSource(kind: .pixel, isRasterized: false, hasSource: false)
    private let group = EngineSession.LayerSource(kind: .group, isRasterized: false, hasSource: false)
    private let rasterizedNoSource = EngineSession.LayerSource(kind: .text, isRasterized: true, hasSource: false)
    private let unlocked = EngineSession.LayerLockState(local: [], effective: [])
    private let localAlpha = EngineSession.LayerLockState(local: [.alpha], effective: [.alpha])
    private let inheritedPixels = EngineSession.LayerLockState(local: [], effective: [.pixels])
    private let inheritedPosition = EngineSession.LayerLockState(local: [], effective: [.position])
    private let localPixels = EngineSession.LayerLockState(local: [.pixels], effective: [.pixels])

    private func enabled(_ command: LayerSourceMenuPolicy.Command,
                         source: EngineSession.LayerSource?,
                         locks: EngineSession.LayerLockState? = nil,
                         targetIsLayer: Bool = true,
                         stateBlocked: Bool = false) -> Bool {
        LayerSourceMenuPolicy.isEnabled(command, source: source, locks: locks ?? unlocked,
                                       targetIsLayer: targetIsLayer, stateBlocked: stateBlocked)
    }

    func testRasterizeIsOfferedOnlyOnGenuineUnrasterizedSource() {
        XCTAssertTrue(enabled(.rasterize, source: editableText))
        XCTAssertTrue(enabled(.rasterize, source: editableLink))
        XCTAssertTrue(enabled(.rasterize, source: editableVector))
        XCTAssertFalse(enabled(.rasterize, source: rasterizedText))
        XCTAssertFalse(enabled(.rasterize, source: rasterizedVector))
        XCTAssertFalse(enabled(.rasterize, source: rasterizedNoSource))
    }

    func testRestoreIsOfferedOnlyOnRasterizedRetainedSource() {
        XCTAssertTrue(enabled(.restore, source: rasterizedText))
        XCTAssertTrue(enabled(.restore, source: rasterizedVector))
        XCTAssertFalse(enabled(.restore, source: editableText))
        XCTAssertFalse(enabled(.restore, source: editableLink))
        XCTAssertFalse(enabled(.restore, source: rasterizedNoSource))
    }

    func testOrdinaryPixelsAndGroupsOfferNeitherCommand() {
        for source in [pixel, group] {
            XCTAssertFalse(enabled(.rasterize, source: source))
            XCTAssertFalse(enabled(.restore, source: source))
        }
    }

    func testMissingCacheEntryOffersNeitherCommand() {
        XCTAssertFalse(enabled(.rasterize, source: nil))
        XCTAssertFalse(enabled(.restore, source: nil))
    }

    func testInheritedPixelOrPositionLocksDisableBothCommands() {
        for locks in [localPixels, inheritedPixels, inheritedPosition] {
            XCTAssertFalse(enabled(.rasterize, source: editableText, locks: locks))
            XCTAssertFalse(enabled(.restore, source: rasterizedText, locks: locks))
        }
    }

    func testAlphaLockAloneKeepsBothCommands() {
        XCTAssertTrue(enabled(.rasterize, source: editableText, locks: localAlpha))
        XCTAssertTrue(enabled(.restore, source: rasterizedText, locks: localAlpha))
    }

    func testMaskChannelAndBlockedStatesDisable() {
        XCTAssertFalse(enabled(.rasterize, source: editableText, targetIsLayer: false))
        XCTAssertFalse(enabled(.restore, source: rasterizedText, targetIsLayer: false))
        XCTAssertFalse(enabled(.rasterize, source: editableText, stateBlocked: true))
        XCTAssertFalse(enabled(.restore, source: rasterizedText, stateBlocked: true))
    }
}
