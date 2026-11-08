import AppKit
import XCTest
@testable import GlimsKit

/// The pure policy behind moving an existing floating selection: the
/// cached readiness gate, the worker-side same-identity check, the
/// whole-pixel commit delta, the release (cancel) decision and the
/// capture-bounds validity — plus the snap-planner reuse on the captured
/// floating bounds. No engine, window or document is involved.
final class FloatingMovePolicyTests: XCTestCase {
    private static let inactive = EngineSession.FloatingState(floating: 0, target: 0, targetKind: nil)
    private static let active = EngineSession.FloatingState(floating: 9, target: 1, targetKind: .layer)
    private static let maskActive = EngineSession.FloatingState(floating: 9, target: 42, targetKind: .layerMask)

    // MARK: Readiness (cached gate)

    func testFloatingMoveReadinessRequiresAnActiveFloatingSelection() {
        XCTAssertFalse(FloatingControlsLogic.floatingMoveReadiness(Self.inactive,
            acceptsEdits: true, pendingTarget: false).allowed,
            "with no floating selection there is nothing to move")
        XCTAssertTrue(FloatingControlsLogic.floatingMoveReadiness(Self.active,
            acceptsEdits: true, pendingTarget: false).allowed)
        XCTAssertTrue(FloatingControlsLogic.floatingMoveReadiness(Self.maskActive,
            acceptsEdits: true, pendingTarget: false).allowed,
            "a mask-attached floating selection can be moved too (attachment is preserved)")
    }

    func testFloatingMoveReadinessBusyAndPendingGates() {
        XCTAssertFalse(FloatingControlsLogic.floatingMoveReadiness(Self.active,
            acceptsEdits: false, pendingTarget: false).allowed)
        XCTAssertFalse(FloatingControlsLogic.floatingMoveReadiness(Self.active,
            acceptsEdits: true, pendingTarget: true).allowed)
        let busy = FloatingControlsLogic.floatingMoveReadiness(Self.active,
            acceptsEdits: false, pendingTarget: false)
        XCTAssertTrue(busy.reason?.contains("operation") == true)
    }

    // MARK: Worker-side fresh-state identity check

    func testFreshStateMustMatchExactly() {
        XCTAssertTrue(FloatingControlsLogic.floatingStateStillMatches(
            expected: Self.active, fresh: Self.active))
        // A different floating id is a different floating selection.
        XCTAssertFalse(FloatingControlsLogic.floatingStateStillMatches(
            expected: Self.active,
            fresh: EngineSession.FloatingState(floating: 10, target: 1, targetKind: .layer)))
        // Same id but a different attachment target.
        XCTAssertFalse(FloatingControlsLogic.floatingStateStillMatches(
            expected: Self.active,
            fresh: EngineSession.FloatingState(floating: 9, target: 2, targetKind: .layer)))
        // Same id but a different target kind.
        XCTAssertFalse(FloatingControlsLogic.floatingStateStillMatches(
            expected: Self.active, fresh: Self.maskActive))
    }

    func testDetachedSameIdNeverMatches() {
        // New Layer (Detach) converts the floating id into an ordinary
        // layer: the fresh read then reports no active floating
        // selection at all, so the captured id is never moved again.
        XCTAssertFalse(FloatingControlsLogic.floatingStateStillMatches(
            expected: Self.active, fresh: Self.inactive))
        // The reverse (capture while inactive, fresh active) never
        // matches either.
        XCTAssertFalse(FloatingControlsLogic.floatingStateStillMatches(
            expected: Self.inactive, fresh: Self.active))
    }

    // MARK: Whole-pixel commit delta

    func testWholePixelDeltaRoundsToWholeImagePixels() {
        let bounds = CGRect(x: 10, y: 10, width: 16, height: 16)
        XCTAssertEqual(FloatingControlsLogic.wholePixelDelta(bounds: bounds,
            proposed: bounds.offsetBy(dx: 6.4, dy: 4.6)), CGSize(width: 6, height: 5))
        XCTAssertEqual(FloatingControlsLogic.wholePixelDelta(bounds: bounds,
            proposed: bounds.offsetBy(dx: -3.5, dy: 2.5)), CGSize(width: -4, height: 2),
            "ties round away from zero, like the pointer path's rounded()")
        XCTAssertEqual(FloatingControlsLogic.wholePixelDelta(bounds: bounds, proposed: bounds),
                       .zero, "a no-drag release commits a zero delta (native no-op semantics)")
    }

    // MARK: Release (cancel) decision

    func testCancelledOrStaleReleaseCommitsNothing() {
        let bounds = CGRect(x: 10, y: 10, width: 16, height: 16)
        let proposed = bounds.offsetBy(dx: 6, dy: 5)
        XCTAssertNil(FloatingControlsLogic.commitDelta(cancelled: true, stillValid: true,
                                                       bounds: bounds, proposed: proposed),
                     "Escape/tool-change/close cancellation commits nothing")
        XCTAssertNil(FloatingControlsLogic.commitDelta(cancelled: false, stillValid: false,
                                                       bounds: bounds, proposed: proposed),
                     "an invalid capture refuses the release instead of falling through")
        XCTAssertEqual(FloatingControlsLogic.commitDelta(cancelled: false, stillValid: true,
                                                         bounds: bounds, proposed: proposed),
                       CGSize(width: 6, height: 5))
    }

    // MARK: Capture-bounds validity

    func testUsableMoveBounds() {
        XCTAssertTrue(FloatingControlsLogic.usableMoveBounds(CGRect(x: 10, y: 10, width: 16, height: 16)))
        XCTAssertFalse(FloatingControlsLogic.usableMoveBounds(CGRect(x: 10, y: 10, width: 0, height: 16)))
        XCTAssertFalse(FloatingControlsLogic.usableMoveBounds(CGRect(x: 10, y: 10, width: 16, height: -1)))
        XCTAssertFalse(FloatingControlsLogic.usableMoveBounds(CGRect(x: CGFloat.nan, y: 0, width: 4, height: 4)))
        XCTAssertFalse(FloatingControlsLogic.usableMoveBounds(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 4)))
        XCTAssertFalse(FloatingControlsLogic.usableMoveBounds(.zero))
    }

    // MARK: Snap-planner reuse on the captured floating bounds

    private static func layer(_ id: Int32, _ bounds: CGRect) -> EngineSession.Layer {
        EngineSession.Layer(id: id, parent: 0, depth: 0, kind: .pixel, name: "L\(id)", mode: "normal",
                            isVisible: true, hasMask: false, isSelected: false, opacity: 1,
                            bounds: bounds, filterCount: 0)
    }

    func testPlannerInputExcludesTheFloatingLayerItself() {
        let floating = Self.layer(9, CGRect(x: 10, y: 10, width: 16, height: 16))
        let other = Self.layer(1, CGRect(x: 40, y: 40, width: 8, height: 8))
        let input = SnapTargetCache.plannerInput(
            movingRect: floating.bounds.offsetBy(dx: 5, dy: 0),
            imageSize: CGSize(width: 64, height: 64),
            guides: [], grid: EngineSession.Grid(),
            layers: [floating, other], moving: 9)
        XCTAssertEqual(input.otherLayerRects, [other.bounds],
                       "the floating layer is not its own snap candidate; the attachment target stays one")
    }

    func testWholePixelPreviewMatchesTheCommittedDelta() {
        // The view-only preview and the committed move must be the same
        // whole-image-pixel translation of the captured bounds.
        let bounds = CGRect(x: 10, y: 10, width: 16, height: 16)
        let raw = bounds.offsetBy(dx: 13.4, dy: -7.6)
        let preview = SnapTargetCache.pixelMove(bounds: bounds, proposed: raw, plan: .none)
        XCTAssertEqual(preview.rect, bounds.offsetBy(dx: 13, dy: -8))
        XCTAssertEqual(FloatingControlsLogic.wholePixelDelta(bounds: bounds, proposed: preview.rect),
                       FloatingControlsLogic.wholePixelDelta(bounds: bounds, proposed: raw),
                       "the committed delta is identical to the previewed whole-pixel delta")

        // A matched snap correction flows through the same rounding: the
        // displayed rect equals the committed rect.
        let plan = CanvasSnapPlanner.Result(dx: 2.4, dy: 0, x: nil, y: nil)
        let snapped = SnapTargetCache.pixelMove(bounds: bounds,
                                                proposed: raw.offsetBy(dx: plan.dx, dy: plan.dy), plan: plan)
        XCTAssertEqual(FloatingControlsLogic.wholePixelDelta(bounds: bounds, proposed: snapped.rect),
                       CGSize(width: 16, height: -8))
    }

    func testPlannerSnapsTheFloatingBoundsToACandidate() {
        // Reuse of the existing planner: a floating rect dragged near the
        // image edge plans a trailing-edge correction to the edge.
        let bounds = CGRect(x: 10, y: 10, width: 16, height: 16)
        let scale = 1.0
        let tolerance = CanvasSnapPlanner.defaultViewPointTolerance / scale
        let raw = bounds.offsetBy(dx: (64 - 0.75 * tolerance) - bounds.maxX, dy: 0)
        let input = SnapTargetCache.plannerInput(movingRect: raw, imageSize: CGSize(width: 64, height: 64),
                                                 guides: [], grid: EngineSession.Grid(),
                                                 layers: [Self.layer(9, bounds)], moving: 9)
        let plan = CanvasSnapPlanner.plan(input: input,
                                          config: CanvasSnapPlanner.Config(targets: [.imageEdge, .imageCenter]),
                                          canvasScale: scale)
        XCTAssertEqual(plan.x?.target, .imageEdge)
        XCTAssertEqual(plan.x?.targetCoordinate, 64)
        let preview = SnapTargetCache.pixelMove(bounds: bounds,
                                                proposed: raw.offsetBy(dx: plan.dx, dy: plan.dy), plan: plan)
        XCTAssertEqual(preview.rect.maxX, 64)
        XCTAssertEqual(FloatingControlsLogic.wholePixelDelta(bounds: bounds, proposed: preview.rect),
                       CGSize(width: 64 - bounds.minX, height: 0))
    }
}
