import Foundation

/// The layer tree as the Layers outline shows it, built from the engine's
/// rows (top of the stack first, depth-first). Nodes are stable for the
/// tree's lifetime; a rebuild compares layers by id.
struct LayerTree {

    /// One layer row with its place in the tree.
    final class Node {
        let layer: EngineSession.Layer
        fileprivate(set) weak var parent: Node?
        fileprivate(set) var children: [Node] = []

        var id: Int32 { layer.id }

        fileprivate init(layer: EngineSession.Layer) {
            self.layer = layer
        }
    }

    /// The top level's rows, top of the stack first.
    let roots: [Node]
    let nodesByID: [Int32: Node]

    init(layers: [EngineSession.Layer]) {
        var byID: [Int32: Node] = [:]
        var roots: [Node] = []
        let nodes = layers.map { Node(layer: $0) }
        for node in nodes { byID[node.id] = node }
        for node in nodes {
            // A row whose parent the list does not contain joins the top
            // level rather than disappearing.
            if let parent = byID[node.layer.parent] {
                node.parent = parent
                parent.children.append(node)
            } else {
                roots.append(node)
            }
        }
        self.roots = roots
        self.nodesByID = byID
    }

    /// The children of `parent` (0: the top level), top first.
    func children(of parent: Int32) -> [Node] {
        parent == 0 ? roots : (nodesByID[parent]?.children ?? [])
    }

    /// The node's position among its siblings, top first.
    func index(of node: Node) -> Int {
        let siblings = node.parent?.children ?? roots
        return siblings.firstIndex { $0 === node } ?? 0
    }

    /// Whether `ancestor` is `node` or one of its parents.
    func contains(_ ancestor: Node, node: Node) -> Bool {
        var current: Node? = node
        while let item = current {
            if item === ancestor { return true }
            current = item.parent
        }
        return false
    }

    /// Where Layer ▸ New Layer Group puts the group with `active` the
    /// selected item: the active group's first child, else directly above
    /// the active layer in the same parent, else at the top of the tree.
    func newGroupPlacement(nearActive active: Int32?) -> (parent: Int32, index: Int32) {
        guard let id = active, let node = nodesByID[id] else { return (0, 0) }
        if node.layer.kind == .group { return (node.id, 0) }
        return (node.parent?.id ?? 0, Int32(index(of: node)))
    }

    /// What a proposed drop resolves to. `index` in `.move` counts the
    /// new parent's children after removing the item, as the engine's
    /// reparent_layer expects.
    enum DropResolution: Equatable {
        /// The item may move to `parent` (0: the top level) at `index`.
        case move(parent: Int32, index: Int32)
        /// The drop leaves the item where it is.
        case unchanged
        /// An unknown or unattached id, a non-group parent, a cycle or an
        /// out-of-range position: the drop cannot happen.
        case invalid
    }

    /// Resolves dropping `item` into `parent`'s children at `rawIndex`, a
    /// position in the parent's child list as displayed — which still
    /// contains `item` when it is dragged within its own parent. The
    /// validation mirrors the engine's: same-image attached ids, groups
    /// only as parents, never into the item's own subtree, in range after
    /// the item's slot is removed.
    func resolveDrop(item: Int32, ontoParent parent: Int32, at rawIndex: Int32) -> DropResolution {
        guard let node = nodesByID[item], node.id != parent else { return .invalid }
        let siblings: [Node]
        if parent == 0 {
            siblings = roots
        } else {
            guard let group = nodesByID[parent], group.layer.kind == .group,
                  !contains(node, node: group) else { return .invalid }
            siblings = group.children
        }
        guard rawIndex >= 0, rawIndex <= siblings.count else { return .invalid }

        guard let current = siblings.firstIndex(where: { $0 === node }) else {
            return .move(parent: parent, index: rawIndex)
        }
        // The item is already a child of the drop's parent: positions at
        // or right after its own slot change nothing, and below them the
        // freed slot shifts the index by one.
        if rawIndex == current || rawIndex == current + 1 { return .unchanged }
        return .move(parent: parent, index: rawIndex > current ? rawIndex - 1 : rawIndex)
    }

    /// Why each lock the engine enforces on `node` applies: the item's
    /// own locks, locks it inherits from a locked ancestor, and for a
    /// group the locks held inside it (the engine sets a group's PIXELS
    /// and POSITION effective bits when a descendant is locked).
    struct LockSources: Equatable {
        /// The item's own locks.
        var local: EngineSession.LayerLocks = []
        /// Locks an ancestor holds that the engine enforces on the item.
        var inherited: EngineSession.LayerLocks = []
        /// For a group, effective locks no ancestor explains: a locked
        /// layer inside it.
        var descendant: EngineSession.LayerLocks = []
        /// What the engine enforces on the item altogether.
        var effective: EngineSession.LayerLocks = []
    }

    /// The lock's sources for `node`; `states` maps layer ids to the
    /// state the engine last reported for them.
    func lockSources(for node: Node, states: [Int32: EngineSession.LayerLockState]) -> LockSources {
        var sources = LockSources(local: states[node.id]?.local ?? [],
                                  effective: states[node.id]?.effective ?? [])
        var ancestor = node.parent
        while let parent = ancestor {
            sources.inherited.formUnion(states[parent.id]?.local ?? [])
            ancestor = parent.parent
        }
        sources.inherited.formIntersection(sources.effective)
        sources.descendant = sources.effective.subtracting(sources.local.union(sources.inherited))
        return sources
    }
}
