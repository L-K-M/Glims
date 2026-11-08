import CoreGraphics
import XCTest
@testable import GlimsKit

/// Pure tests for the per-window View ▸ Snap To policy and the cached
/// snap-target assembly. Every expected value is written out by hand from
/// the documented mapping (Canvas = image edge + centre, Layer Bounds =
/// layer edge + centre, all OFF by default), never derived from the
/// implementation.
final class SnapToControlsTests: XCTestCase {

    private func layer(_ id: Int32, _ parent: Int32 = 0, bounds: CGRect = CGRect(x: 0, y: 0, width: 10, height: 10),
                       kind: EngineSession.LayerKind = .pixel) -> EngineSession.Layer {
        EngineSession.Layer(id: id, parent: parent, depth: 0, kind: kind, name: "L\(id)", mode: "",
                            isVisible: true, hasMask: false, isSelected: false, opacity: 1,
                            bounds: bounds, filterCount: 0)
    }

    private func guide(_ id: Int32, _ orientation: EngineSession.GuideOrientation, _ position: Int32) -> EngineSession.Guide {
        EngineSession.Guide(id: id, orientation: orientation, position: position)
    }

    func testFractionalMovePreviewUsesCommittedPixelsAndClearsFalseMatch() {
        let bounds = CGRect(x: 0, y: 0, width: 10, height: 10)
        let match = CanvasSnapPlanner.AxisMatch(anchor: .leading, target: .grid,
                                                sourceCoordinate: 2.2, targetCoordinate: 2.5)
        let preview = SnapTargetCache.pixelMove(bounds: bounds,
            proposed: bounds.offsetBy(dx: 2.5, dy: -2.5),
            plan: .init(dx: 0.3, dy: 0, x: match, y: nil))
        XCTAssertEqual(preview.rect.origin, CGPoint(x: 3, y: -3))
        XCTAssertNil(preview.plan.x, "a whole-pixel move cannot align this anchor at 2.5")
    }

    func testIntegralMoveKeepsAccurateSnapIndicator() {
        let bounds = CGRect(x: 10, y: 20, width: 9, height: 11)
        let match = CanvasSnapPlanner.AxisMatch(anchor: .center, target: .grid,
                                                sourceCoordinate: 16.7, targetCoordinate: 17.5)
        let preview = SnapTargetCache.pixelMove(bounds: bounds,
            proposed: bounds.offsetBy(dx: 3, dy: 0.2),
            plan: .init(dx: 0.8, dy: 0, x: match, y: nil))
        XCTAssertEqual(preview.rect.origin, CGPoint(x: 13, y: 20))
        XCTAssertEqual(preview.plan.x, match, "a half-pixel center can align with integral translation")
    }

    // MARK: Defaults: every entry OFF

    func testDefaultsAreAllOff() {
        let state = SnapToViewState()
        XCTAssertTrue(state.isEmpty)
        XCTAssertTrue(state.targets.isEmpty)
        for kind in SnapToKind.allCases {
            XCTAssertFalse(state.isEnabled(kind), "\(kind.rawValue) defaults off")
            XCTAssertEqual(state.menuState(kind), .off, "\(kind.rawValue)'s checkmark defaults off")
        }
    }

    // MARK: Toggling is per-entry and independent

    func testTogglesAreIndependentPerEntry() {
        var state = SnapToViewState()
        state.toggle(.canvas)
        XCTAssertTrue(state.canvas && !state.guides && !state.grid && !state.layerBounds)
        XCTAssertFalse(state.isEmpty)
        XCTAssertEqual(state.menuState(.canvas), .on)
        XCTAssertEqual(state.menuState(.guides), .off)
        state.toggle(.guides)
        state.toggle(.canvas)
        XCTAssertTrue(state.guides && !state.canvas && !state.grid && !state.layerBounds,
                      "toggling Canvas off does not touch Guides")
        XCTAssertEqual(state, SnapToViewState(guides: true, grid: false, canvas: false, layerBounds: false))
    }

    // MARK: The target mapping

    func testCanvasMapsToImageEdgeAndCenter() {
        XCTAssertEqual(SnapToKind.canvas.targets, [.imageEdge, .imageCenter])
    }

    func testLayerBoundsMapsToLayerEdgeAndCenter() {
        XCTAssertEqual(SnapToKind.layerBounds.targets, [.layerEdge, .layerCenter])
    }

    func testGuidesAndGridMapToTheirOwnKinds() {
        XCTAssertEqual(SnapToKind.guides.targets, .guide)
        XCTAssertEqual(SnapToKind.grid.targets, .grid)
    }

    func testCombinedTargetsAreTheUnionOfEnabledEntries() {
        var state = SnapToViewState()
        state.toggle(.guides)
        state.toggle(.layerBounds)
        XCTAssertEqual(state.targets, [.guide, .layerEdge, .layerCenter])
        state.toggle(.canvas)
        state.toggle(.grid)
        XCTAssertEqual(state.targets, .all)
        state.toggle(.guides)
        XCTAssertEqual(state.targets, [.imageEdge, .imageCenter, .grid, .layerEdge, .layerCenter])
    }

    func testAllOffMeansThePlannerReturnsNoCorrection() {
        // A perfect candidate (the moving edge exactly on the image edge)
        // still snaps to nothing when every entry is off.
        let state = SnapToViewState()
        let result = CanvasSnapPlanner.plan(
            input: CanvasSnapPlanner.Input(movingRect: CGRect(x: 92, y: 10, width: 8, height: 8),
                                           imageBounds: CGRect(x: 0, y: 0, width: 100, height: 80),
                                           verticalGuides: [50], horizontalGuides: [],
                                           grid: CanvasSnapPlanner.Grid(spacingX: 10, spacingY: 10,
                                                                        offsetX: 0, offsetY: 0),
                                           otherLayerRects: [CGRect(x: 40, y: 40, width: 20, height: 20)]),
            config: CanvasSnapPlanner.Config(targets: state.targets), canvasScale: 1)
        XCTAssertEqual(result, .none)
    }

    // MARK: The moving layer's family is excluded from the other targets

    func testExcludedIDsCoverTheLayerItself() {
        let layers = [layer(1), layer(2)]
        XCTAssertEqual(SnapTargetCache.excludedLayerIDs(layers: layers, moving: 1), [1])
    }

    func testExcludedIDsCoverAncestors() {
        // 1 is a group, 2 a child of 1, 3 a child of 2: moving 3 excludes 3, 2 and 1.
        let layers = [layer(1, kind: .group), layer(2, 1, kind: .group), layer(3, 2)]
        XCTAssertEqual(SnapTargetCache.excludedLayerIDs(layers: layers, moving: 3), [1, 2, 3])
    }

    func testExcludedIDsCoverDescendants() {
        // Moving the group 1 excludes its whole subtree (2 and 3) but not 4.
        let layers = [layer(1, kind: .group), layer(2, 1), layer(3, 1), layer(4)]
        XCTAssertEqual(SnapTargetCache.excludedLayerIDs(layers: layers, moving: 1), [1, 2, 3])
    }

    func testUnknownMovingIDExcludesOnlyItself() {
        let layers = [layer(1), layer(2)]
        XCTAssertEqual(SnapTargetCache.excludedLayerIDs(layers: layers, moving: 99), [99])
    }

    func testOtherLayerRectsKeepSiblingsAndDropDegenerateRects() {
        let good = CGRect(x: 40, y: 40, width: 20, height: 20)
        let layers = [
            layer(1, kind: .group),
            layer(2, 1, bounds: good),                       // child of the moving group: excluded
            layer(3, 0, bounds: CGRect(x: 0, y: 0, width: 0, height: 5)), // degenerate: dropped
            layer(4, 0, bounds: good),                        // sibling: kept
            layer(5, 0, bounds: CGRect(x: Double.nan, y: 0, width: 5, height: 5)), // non-finite: dropped
        ]
        XCTAssertEqual(SnapTargetCache.otherLayerRects(layers: layers, moving: 1), [good])
    }

    // MARK: Planner input assembly from cached state

    func testPlannerInputSplitsGuidesByOrientationAndMapsTheGrid() {
        let grid = EngineSession.Grid(style: .solid, spacingX: 12, spacingY: 8, offsetX: 3, offsetY: -2,
                                      foreground: .black, background: .white)
        let input = SnapTargetCache.plannerInput(
            movingRect: CGRect(x: 5, y: 6, width: 7, height: 9),
            imageSize: CGSize(width: 400, height: 300),
            guides: [guide(1, .vertical, 200), guide(2, .horizontal, 90), guide(3, .vertical, 50)],
            grid: grid,
            layers: [layer(1), layer(2, 0, bounds: CGRect(x: 40, y: 40, width: 20, height: 20))],
            moving: 1)
        XCTAssertEqual(input.movingRect, CGRect(x: 5, y: 6, width: 7, height: 9))
        XCTAssertEqual(input.imageBounds, CGRect(x: 0, y: 0, width: 400, height: 300))
        XCTAssertEqual(input.verticalGuides, [200, 50])
        XCTAssertEqual(input.horizontalGuides, [90])
        XCTAssertEqual(input.grid, CanvasSnapPlanner.Grid(spacingX: 12, spacingY: 8, offsetX: 3, offsetY: -2))
        XCTAssertEqual(input.otherLayerRects, [CGRect(x: 40, y: 40, width: 20, height: 20)])
    }

    func testPlannerInputExcludesTheMovingLayerAndItsFamily() {
        let layers = [layer(1, kind: .group), layer(2, 1), layer(3, 0, bounds: CGRect(x: 9, y: 9, width: 4, height: 4))]
        let input = SnapTargetCache.plannerInput(movingRect: CGRect(x: 0, y: 0, width: 5, height: 5),
                                                 imageSize: CGSize(width: 100, height: 100),
                                                 guides: [], grid: EngineSession.Grid(), layers: layers, moving: 1)
        XCTAssertEqual(input.otherLayerRects, [CGRect(x: 9, y: 9, width: 4, height: 4)])
    }
}
