import AppKit
import XCTest
@testable import GlimsKit

/// The Select ▸ Float Selected Pixels / Float a Copy policy, read purely
/// from cached document state — the same function the menu validation and
/// the document command use. The gates mirror the native preflight in
/// `glims_selection_float`.
final class FloatSelectedPixelsPolicyTests: XCTestCase {
    private static let inactive = EngineSession.FloatingState(floating: 0, target: 0, targetKind: nil)
    private static func active(_ floating: Int32, target: Int32, kind: EngineSession.FloatingTargetKind) -> EngineSession.FloatingState {
        EngineSession.FloatingState(floating: floating, target: target, targetKind: kind)
    }
    private static func layer(_ id: Int32, kind: EngineSession.LayerKind = .pixel, hasMask: Bool = false) -> EngineSession.Layer {
        EngineSession.Layer(id: id, parent: 0, depth: 0, kind: kind, name: "L\(id)", mode: "normal",
                            isVisible: true, hasMask: hasMask, isSelected: false, opacity: 1,
                            bounds: CGRect(x: 0, y: 0, width: 64, height: 64), filterCount: 0)
    }
    private static let unlocked = EngineSession.LayerLockState(local: [], effective: [])
    private static let pixelLocked = EngineSession.LayerLockState(local: [.pixels], effective: [.pixels])
    private static let alphaLocked = EngineSession.LayerLockState(local: [.alpha], effective: [.alpha])
    private static let positionLocked = EngineSession.LayerLockState(local: [.position], effective: [.position])
    private static let channel = EngineSession.Channel(id: 77, name: "c", isVisible: true, isSelected: true,
                                                       isQuickMask: false, opacity: 1, color: .red)
    private static let textSource = EngineSession.LayerSource(kind: .text, isRasterized: false, hasSource: true)
    private static let rasterizedText = EngineSession.LayerSource(kind: .text, isRasterized: true, hasSource: true)

    private func float(_ drawable: Int32?, mode: EngineSession.FloatMode = .move,
                       hasSelection: Bool = true,
                       state: EngineSession.FloatingState = FloatSelectedPixelsPolicyTests.inactive,
                       layers: [EngineSession.Layer] = [FloatSelectedPixelsPolicyTests.layer(1)],
                       maskStates: [Int32: EngineSession.MaskState] = [:],
                       channels: [EngineSession.Channel] = [],
                       sources: [Int32: EngineSession.LayerSource] = [:],
                       locks: [Int32: EngineSession.LayerLockState] = [1: FloatSelectedPixelsPolicyTests.unlocked],
                       acceptsEdits: Bool = true, pendingTarget: Bool = false) -> FloatingControlsLogic.FloatTarget {
        FloatingControlsLogic.floatTarget(drawable, mode: mode, hasSelection: hasSelection, state: state,
                                          layers: layers, maskStates: maskStates, channels: channels,
                                          sources: sources, locks: locks,
                                          acceptsEdits: acceptsEdits, pendingTarget: pendingTarget)
    }

    func testFloatRequiresAnExplicitTargetId() {
        XCTAssertFalse(float(nil).allowed)
        XCTAssertFalse(float(0).allowed)
        XCTAssertEqual(float(1).drawable, 1)
        XCTAssertFalse(float(999).allowed, "an id outside the cached lists is refused")
        XCTAssertEqual(float(1, mode: .copy).drawable, 1)
    }

    func testFloatGatesOnCachedStateOnly() {
        let active = Self.active(9, target: 1, kind: .layer)
        XCTAssertEqual(float(1, state: active).reason, FloatingControlsLogic.resolveFirstReason,
                       "an active floating selection refuses resolve-first, never a silent anchor")
        XCTAssertFalse(float(1, hasSelection: false).allowed, "an empty selection refuses")
        XCTAssertTrue(float(1, hasSelection: false).reason?.contains("no selection") == true)
        XCTAssertFalse(float(1, acceptsEdits: false).allowed, "busy/closing/preview/save/clipboard refuse")
        XCTAssertFalse(float(1, pendingTarget: true).allowed, "a pending target change refuses")
        XCTAssertFalse(float(1, mode: .copy, acceptsEdits: false).allowed, "COPY gates on busy too")
    }

    func testFloatRefusesGroups() {
        let group = Self.layer(1, kind: .group)
        for mode: EngineSession.FloatMode in [.move, .copy] {
            let result = float(1, mode: mode, layers: [group])
            XCTAssertFalse(result.allowed)
            XCTAssertTrue(result.reason?.contains("group") == true)
        }
    }

    func testStructuredSourceGateAppliesToTheLayerTargetOnly() {
        // A genuine editable text layer refuses rasterize-first in both
        // modes — the native check reads the source of a layer target
        // regardless of cut.
        for mode: EngineSession.FloatMode in [.move, .copy] {
            let result = float(1, mode: mode, sources: [1: Self.textSource])
            XCTAssertFalse(result.allowed)
            XCTAssertTrue(result.reason?.contains("rasterize") == true)
        }
        // A rasterized instance counts as pixels.
        XCTAssertTrue(float(1, sources: [1: Self.rasterizedText]).allowed)
        // The same text layer's mask is NOT source-gated: only the
        // target's own kind matters.
        let mask = EngineSession.MaskState(mask: 42, enabled: true, editing: true, showing: false)
        let maskedText = Self.layer(1, kind: .text, hasMask: true)
        let masked = float(42, mode: .move, layers: [maskedText], maskStates: [1: mask],
                           sources: [1: Self.textSource])
        XCTAssertEqual(masked.drawable, 42)
        // A channel target is not source-gated either.
        XCTAssertEqual(float(77, mode: .copy, channels: [Self.channel]).drawable, 77)
    }

    func testMoveHonorsPixelAndAlphaLocksCopyDoesNot() {
        XCTAssertTrue(float(1, mode: .move, locks: [1: Self.pixelLocked]).reason?.contains("pixels are locked") == true)
        XCTAssertTrue(float(1, mode: .move, locks: [1: Self.alphaLocked]).reason?.contains("transparency is locked") == true)
        // COPY is non-destructive: a locked target is allowed (the native
        // anchor rechecks locks at resolution time).
        XCTAssertTrue(float(1, mode: .copy, locks: [1: Self.pixelLocked]).allowed)
        XCTAssertTrue(float(1, mode: .copy, locks: [1: Self.alphaLocked]).allowed)
        // A position-only lock does not gate a cut.
        XCTAssertTrue(float(1, mode: .move, locks: [1: Self.positionLocked]).allowed)
    }

    func testMaskTargetLockGateMatchesNative() {
        let mask = EngineSession.MaskState(mask: 42, enabled: true, editing: true, showing: false)
        let maskStates: [Int32: EngineSession.MaskState] = [1: mask]
        // MOVE through a mask is gated by the owning layer's content lock.
        XCTAssertTrue(float(42, mode: .move, maskStates: maskStates, locks: [1: Self.pixelLocked])
            .reason?.contains("locked") == true)
        // COPY on the same locked layer's mask is allowed.
        XCTAssertEqual(float(42, mode: .copy, maskStates: maskStates, locks: [1: Self.pixelLocked]).drawable, 42)
        // An unlocked mask accepts both modes.
        XCTAssertEqual(float(42, mode: .move, maskStates: maskStates).drawable, 42)
    }

    func testChannelTargetNeedsNoLockOrSourceGate() {
        XCTAssertEqual(float(77, mode: .move, channels: [Self.channel]).drawable, 77)
        XCTAssertEqual(float(77, mode: .copy, channels: [Self.channel]).drawable, 77)
    }

    func testFloatTooltipsStateCutVsCopyAndSelectionClear() {
        XCTAssertTrue(FloatingControlsLogic.floatMoveTooltip.contains("Cut"))
        XCTAssertTrue(FloatingControlsLogic.floatMoveTooltip.contains("transparent hole"))
        XCTAssertTrue(FloatingControlsLogic.floatMoveTooltip.contains("selection is cleared"))
        XCTAssertTrue(FloatingControlsLogic.floatCopyTooltip.contains("copy"))
        XCTAssertTrue(FloatingControlsLogic.floatCopyTooltip.contains("unchanged"))
        XCTAssertTrue(FloatingControlsLogic.floatCopyTooltip.contains("selection is cleared"))
    }
}
