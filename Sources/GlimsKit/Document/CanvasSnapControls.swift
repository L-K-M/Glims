import AppKit
import CoreGraphics

/// One entry of View ▸ Snap To. Each kind maps to the planner target kinds
/// it enables; Canvas is the image edge and centre, Layer Bounds another
/// layer's edge and centre.
enum SnapToKind: String, CaseIterable {
    case guides = "Guides"
    case grid = "Grid"
    case canvas = "Canvas"
    case layerBounds = "Layer Bounds"

    /// The planner target kinds this toggle enables.
    var targets: CanvasSnapPlanner.Target {
        switch self {
        case .guides: return .guide
        case .grid: return .grid
        case .canvas: return [.imageEdge, .imageCenter]
        case .layerBounds: return [.layerEdge, .layerCenter]
        }
    }
}

/// View ▸ Snap To's cached per-window state. Pure view state, every entry
/// OFF by default: toggling changes only what the Move tool snaps to and
/// what the canvas draws during a move — never image pixels, the file's
/// dirty state, history, selection, export or print. Each window keeps its
/// own instance (the canvas owns it), so two windows never couple.
struct SnapToViewState: Equatable {
    var guides = false
    var grid = false
    var canvas = false
    var layerBounds = false

    /// Whether every entry is off, i.e. no snapping at all.
    var isEmpty: Bool { !guides && !grid && !canvas && !layerBounds }

    /// Whether `kind`'s entry is on.
    func isEnabled(_ kind: SnapToKind) -> Bool {
        switch kind {
        case .guides: return guides
        case .grid: return grid
        case .canvas: return canvas
        case .layerBounds: return layerBounds
        }
    }

    /// The planner targets the enabled entries select; empty when all are
    /// off, which makes the planner return no correction at all.
    var targets: CanvasSnapPlanner.Target {
        var result = CanvasSnapPlanner.Target()
        for kind in SnapToKind.allCases where isEnabled(kind) {
            result.formUnion(kind.targets)
        }
        return result
    }

    /// The entry's checkmark state for its menu item.
    func menuState(_ kind: SnapToKind) -> NSControl.StateValue {
        isEnabled(kind) ? .on : .off
    }

    mutating func toggle(_ kind: SnapToKind) {
        switch kind {
        case .guides: guides.toggle()
        case .grid: grid.toggle()
        case .canvas: canvas.toggle()
        case .layerBounds: layerBounds.toggle()
        }
    }
}

/// Builds the planner's candidate geometry from cached document state
/// only — no engine call, no per-drag RPC. The moving layer's own family
/// (the layer, its ancestors and its descendants) never becomes a snap
/// target for itself.
enum SnapTargetCache {
    /// The ids a move of `moving` must exclude from the other-layer
    /// candidates: the moving layer itself, every ancestor group and
    /// every descendant. An unknown id excludes only itself.
    static func excludedLayerIDs(layers: [EngineSession.Layer], moving: Int32) -> Set<Int32> {
        let tree = LayerTree(layers: layers)
        var excluded: Set<Int32> = [moving]
        guard let node = tree.nodesByID[moving] else { return excluded }
        var ancestor = node.parent
        while let parent = ancestor {
            excluded.insert(parent.id)
            ancestor = parent.parent
        }
        var stack = [node]
        while let item = stack.popLast() {
            for child in item.children {
                excluded.insert(child.id)
                stack.append(child)
            }
        }
        return excluded
    }

    /// The other layers' rects a move of `moving` may snap to, in the
    /// layer list's order. Degenerate rects (non-finite or zero-size) are
    /// dropped here so one bad row cannot fail the whole plan closed.
    static func otherLayerRects(layers: [EngineSession.Layer], moving: Int32) -> [CGRect] {
        let excluded = excludedLayerIDs(layers: layers, moving: moving)
        return layers.filter { !excluded.contains($0.id) && isUsable($0.bounds) }.map { $0.bounds }
    }

    /// One planning request assembled from cached state: the moving rect
    /// at its proposed position, the image bounds from `imageSize`, the
    /// guides split by orientation, the display grid and the other
    /// layers' rects with `moving`'s family excluded.
    static func plannerInput(movingRect: CGRect, imageSize: CGSize,
                             guides: [EngineSession.Guide], grid: EngineSession.Grid,
                             layers: [EngineSession.Layer], moving: Int32) -> CanvasSnapPlanner.Input {
        CanvasSnapPlanner.Input(
            movingRect: movingRect,
            imageBounds: CGRect(origin: .zero, size: imageSize),
            verticalGuides: guides.filter { $0.orientation == .vertical }.map { Double($0.position) },
            horizontalGuides: guides.filter { $0.orientation == .horizontal }.map { Double($0.position) },
            grid: CanvasSnapPlanner.Grid(spacingX: grid.spacingX, spacingY: grid.spacingY,
                                         offsetX: grid.offsetX, offsetY: grid.offsetY),
            otherLayerRects: otherLayerRects(layers: layers, moving: moving))
    }

    /// A rect usable as a snap candidate: finite with positive size.
    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
            && rect.size.width > 0 && rect.size.height > 0
    }
}
