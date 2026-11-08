import AppKit
import XCTest
@testable import GlimsKit

/// The floating-selection controls' policy, read purely from cached
/// document state — the same functions the menu validation, the Layers
/// palette footer and the document commands use.
final class FloatingControlsLogicTests: XCTestCase {
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
    private static let channel = EngineSession.Channel(id: 77, name: "c", isVisible: true, isSelected: true,
                                                       isQuickMask: false, opacity: 1, color: .red)

    private func pasteInto(_ drawable: Int32?, state: EngineSession.FloatingState = FloatingControlsLogicTests.inactive,
                           layers: [EngineSession.Layer] = [FloatingControlsLogicTests.layer(1)],
                           maskStates: [Int32: EngineSession.MaskState] = [:],
                           channels: [EngineSession.Channel] = [],
                           sources: [Int32: EngineSession.LayerSource] = [:],
                           locks: [Int32: EngineSession.LayerLockState] = [1: FloatingControlsLogicTests.unlocked],
                           acceptsEdits: Bool = true, pendingTarget: Bool = false) -> FloatingControlsLogic.PasteIntoTarget {
        FloatingControlsLogic.pasteIntoTarget(drawable, state: state, layers: layers, maskStates: maskStates,
                                              channels: channels, sources: sources, locks: locks,
                                              acceptsEdits: acceptsEdits, pendingTarget: pendingTarget)
    }

    private func resolution(_ command: EngineSession.FloatingCommand,
                            state: EngineSession.FloatingState,
                            maskStates: [Int32: EngineSession.MaskState] = [:],
                            sources: [Int32: EngineSession.LayerSource] = [:],
                            locks: [Int32: EngineSession.LayerLockState] = [1: FloatingControlsLogicTests.unlocked],
                            acceptsEdits: Bool = true, pendingTarget: Bool = false) -> FloatingControlsLogic.Readiness {
        FloatingControlsLogic.resolution(command, state: state, layers: [FloatingControlsLogicTests.layer(1, hasMask: maskStates.isEmpty == false)],
                                         maskStates: maskStates, sources: sources, locks: locks,
                                         acceptsEdits: acceptsEdits, pendingTarget: pendingTarget)
    }

    func testPasteIntoRequiresAnExplicitTargetId() {
        XCTAssertFalse(pasteInto(nil).allowed)
        XCTAssertFalse(pasteInto(0).allowed)
        XCTAssertEqual(pasteInto(1).drawable, 1)
        XCTAssertFalse(pasteInto(999).allowed, "an id outside the cached lists is refused")
    }

    func testPasteIntoGates() {
        let active = Self.active(9, target: 1, kind: .layer)
        XCTAssertEqual(pasteInto(1, state: active).reason, FloatingControlsLogic.resolveFirstReason,
                       "an active floating selection gates Paste Into resolve-first")
        XCTAssertFalse(pasteInto(1, acceptsEdits: false).allowed, "busy/closing/preview refuse")
        XCTAssertFalse(pasteInto(1, pendingTarget: true).allowed, "a pending target change refuses")
        XCTAssertFalse(pasteInto(1, layers: [FloatingControlsLogicTests.layer(1, kind: .group)]).allowed, "groups refuse")
        XCTAssertTrue(pasteInto(1, locks: [1: FloatingControlsLogicTests.pixelLocked]).reason?.contains("locked") == true)
        let text = EngineSession.LayerSource(kind: .text, isRasterized: false, hasSource: true)
        XCTAssertTrue(pasteInto(1, sources: [1: text]).reason?.contains("rasterize") == true,
                      "a genuine editable structured target refuses rasterize-first")
        let rasterized = EngineSession.LayerSource(kind: .text, isRasterized: true, hasSource: true)
        XCTAssertTrue(pasteInto(1, sources: [1: rasterized]).allowed,
                      "an already rasterized instance counts as pixels")
    }

    func testPasteIntoAcceptsMaskAndChannelTargets() {
        let mask = EngineSession.MaskState(mask: 42, enabled: true, editing: true, showing: false)
        XCTAssertEqual(pasteInto(42, maskStates: [1: mask]).drawable, 42)
        XCTAssertTrue(pasteInto(42, maskStates: [1: mask], locks: [1: FloatingControlsLogicTests.pixelLocked]).reason?.contains("locked") == true,
                      "a mask whose layer is pixel-locked refuses")
        XCTAssertEqual(pasteInto(77, channels: [FloatingControlsLogicTests.channel]).drawable, 77)
    }

    func testResolutionRequiresAnActiveFloatingSelection() {
        XCTAssertFalse(resolution(.anchor, state: FloatingControlsLogicTests.inactive).allowed)
        XCTAssertFalse(resolution(.discard, state: FloatingControlsLogicTests.inactive).allowed)
        XCTAssertFalse(resolution(.toLayer, state: FloatingControlsLogicTests.inactive).allowed)
    }

    func testAnchorRechecksCachedPixelLocks() {
        let state = Self.active(9, target: 1, kind: .layer)
        XCTAssertTrue(resolution(.anchor, state: state).allowed)
        XCTAssertTrue(resolution(.anchor, state: state, locks: [1: FloatingControlsLogicTests.pixelLocked]).reason?.contains("locked") == true)
        // A mask target's lock is the owning layer's.
        let mask = EngineSession.MaskState(mask: 42, enabled: true, editing: true, showing: false)
        let maskState = Self.active(9, target: 42, kind: .layerMask)
        XCTAssertTrue(resolution(.anchor, state: maskState, maskStates: [1: mask], locks: [1: FloatingControlsLogicTests.pixelLocked])
            .reason?.contains("locked") == true)
        // Channels hold no pixel locks.
        let channelState = Self.active(9, target: 77, kind: .channel)
        XCTAssertTrue(resolution(.anchor, state: channelState).allowed)
    }

    func testNewLayerGatesForMaskAndChannelAttachments() {
        let maskState = Self.active(9, target: 42, kind: .layerMask)
        let channelState = Self.active(9, target: 77, kind: .channel)
        for state in [maskState, channelState] {
            let readiness = resolution(.toLayer, state: state)
            XCTAssertFalse(readiness.allowed)
            XCTAssertTrue(readiness.reason?.contains("mask or channel") == true)
        }
        let layerState = Self.active(9, target: 1, kind: .layer)
        XCTAssertTrue(resolution(.toLayer, state: layerState).allowed)
        let text = EngineSession.LayerSource(kind: .text, isRasterized: false, hasSource: true)
        XCTAssertTrue(resolution(.toLayer, state: layerState, sources: [1: text]).reason?.contains("rasterize") == true)
    }

    func testDiscardAndBusyGates() {
        let state = Self.active(9, target: 1, kind: .layer)
        XCTAssertTrue(resolution(.discard, state: state).allowed)
        XCTAssertFalse(resolution(.discard, state: state, acceptsEdits: false).allowed)
        XCTAssertFalse(resolution(.anchor, state: state, pendingTarget: true).allowed)
    }

    func testResolveFirstGateOnlyWhileActive() {
        XCTAssertNil(FloatingControlsLogic.resolveFirstGate(FloatingControlsLogicTests.inactive))
        XCTAssertEqual(FloatingControlsLogic.resolveFirstGate(Self.active(9, target: 1, kind: .layer)),
                       FloatingControlsLogic.resolveFirstReason)
    }

    func testNewLayerTooltipIsHonestAboutClipping() {
        XCTAssertTrue(FloatingControlsLogic.newLayerTooltip.contains("clipping"))
        XCTAssertTrue(FloatingControlsLogic.newLayerTooltip.contains("not necessarily"))
    }
}
