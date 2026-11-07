import AppKit
import XCTest
@testable import GlimsKit

/// The layer tree the palette builds from the engine's flat rows:
/// parentage and ordering, where a new group lands, and how a proposed
/// drop validates and resolves before the engine ever sees it.
final class LayerTreeTests: XCTestCase {

    private func layer(_ id: Int32, parent: Int32 = 0, depth: Int = 0,
                       kind: EngineSession.LayerKind = .pixel,
                       name: String = "") -> EngineSession.Layer {
        EngineSession.Layer(id: id, parent: parent, depth: depth, kind: kind,
                            name: name.isEmpty ? "L\(id)" : name, mode: "normal",
                            isVisible: true, hasMask: false, isSelected: false,
                            opacity: 1, bounds: .zero, filterCount: 0)
    }

    /// Top first, as the engine reports: group 4 holds 3 and 2, root holds
    /// 5 and 1 besides.
    private func fixture() -> LayerTree {
        LayerTree(layers: [
            layer(5), layer(4, kind: .group), layer(3, parent: 4, depth: 1),
            layer(2, parent: 4, depth: 1), layer(1),
        ])
    }

    func testBuildKeepsParentsAndOrder() {
        let tree = fixture()
        XCTAssertEqual(tree.roots.map(\.id), [5, 4, 1])
        XCTAssertEqual(tree.nodesByID[4]?.children.map(\.id), [3, 2])
        XCTAssertTrue(tree.nodesByID[3]?.parent === tree.nodesByID[4])
        XCTAssertEqual(tree.index(of: tree.nodesByID[2]!), 1)
    }

    func testOrphanedRowsJoinTheTopLevel() {
        // A row whose parent is not in the list still shows.
        let tree = LayerTree(layers: [layer(9, parent: 99, depth: 1), layer(8)])
        XCTAssertEqual(tree.roots.map(\.id), [9, 8])
    }

    private func assertPlacement(_ tree: LayerTree, _ active: Int32?, parent: Int32, index: Int32,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let placement = tree.newGroupPlacement(nearActive: active)
        XCTAssertEqual(placement.parent, parent, file: file, line: line)
        XCTAssertEqual(placement.index, index, file: file, line: line)
    }

    func testNewGroupGoesInsideTheActiveGroupOrAboveTheActiveLayer() {
        let tree = fixture()
        assertPlacement(tree, 4, parent: 4, index: 0)
        assertPlacement(tree, 2, parent: 4, index: 1)
        assertPlacement(tree, 1, parent: 0, index: 2)
        assertPlacement(tree, nil, parent: 0, index: 0)
        assertPlacement(tree, 42, parent: 0, index: 0)
    }

    func testDropOntoGroupAndBetweenSiblings() {
        let tree = fixture()
        // Drop onto the group: first child.
        XCTAssertEqual(tree.resolveDrop(item: 1, ontoParent: 4, at: 0), .move(parent: 4, index: 0))
        // Between the group's children.
        XCTAssertEqual(tree.resolveDrop(item: 1, ontoParent: 4, at: 1), .move(parent: 4, index: 1))
        // Out of the group to the top level.
        XCTAssertEqual(tree.resolveDrop(item: 3, ontoParent: 0, at: 0), .move(parent: 0, index: 0))
    }

    func testSameParentDropAdjustsTheIndexAfterRemoval() {
        let tree = fixture()
        // 3 moves below 2 inside group 4: the raw position 2 counts a list
        // still holding 3; after removal the index is 1.
        XCTAssertEqual(tree.resolveDrop(item: 3, ontoParent: 4, at: 2), .move(parent: 4, index: 1))
        XCTAssertEqual(tree.resolveDrop(item: 2, ontoParent: 4, at: 0), .move(parent: 4, index: 0))
        // Dropping on its own slot or right below it changes nothing.
        XCTAssertEqual(tree.resolveDrop(item: 3, ontoParent: 4, at: 0), .unchanged)
        XCTAssertEqual(tree.resolveDrop(item: 3, ontoParent: 4, at: 1), .unchanged)
        // Same for the top level: 5 sits at index 0 of three rows.
        XCTAssertEqual(tree.resolveDrop(item: 5, ontoParent: 0, at: 0), .unchanged)
        XCTAssertEqual(tree.resolveDrop(item: 5, ontoParent: 0, at: 1), .unchanged)
        XCTAssertEqual(tree.resolveDrop(item: 5, ontoParent: 0, at: 3), .move(parent: 0, index: 2))
    }

    func testDropRejectsCyclesNonGroupsUnknownAndRange() {
        let tree = fixture()
        // A group cannot go into itself or its own subtree.
        XCTAssertEqual(tree.resolveDrop(item: 4, ontoParent: 4, at: 0), .invalid)
        XCTAssertEqual(tree.resolveDrop(item: 4, ontoParent: 3, at: 0), .invalid)
        // Only groups take children.
        XCTAssertEqual(tree.resolveDrop(item: 1, ontoParent: 2, at: 0), .invalid)
        // Unknown or unattached ids.
        XCTAssertEqual(tree.resolveDrop(item: 77, ontoParent: 0, at: 0), .invalid)
        XCTAssertEqual(tree.resolveDrop(item: 1, ontoParent: 77, at: 0), .invalid)
        // Out of range.
        XCTAssertEqual(tree.resolveDrop(item: 1, ontoParent: 0, at: -1), .invalid)
        XCTAssertEqual(tree.resolveDrop(item: 1, ontoParent: 4, at: 3), .invalid)
    }

    func testContainsFindsTheNodeAndItsDescendants() {
        let tree = fixture()
        let group = tree.nodesByID[4]!
        XCTAssertTrue(tree.contains(group, node: group))
        XCTAssertTrue(tree.contains(group, node: tree.nodesByID[2]!))
        XCTAssertFalse(tree.contains(group, node: tree.nodesByID[5]!))
    }

    func testLockSourcesSeparateLocalInheritedAndDescendant() {
        let tree = fixture()
        var states: [Int32: EngineSession.LayerLockState] = [:]
        // Group 4 locks pixels; that locks 3 and 2 for the engine, and
        // layer 2 locks its own transparency too.
        states[4] = EngineSession.LayerLockState(local: [.pixels], effective: [.pixels])
        states[3] = EngineSession.LayerLockState(local: [], effective: [.pixels])
        states[2] = EngineSession.LayerLockState(local: [.alpha], effective: [.pixels, .alpha])
        states[1] = EngineSession.LayerLockState(local: [], effective: [])

        let child = tree.lockSources(for: tree.nodesByID[3]!, states: states)
        XCTAssertEqual(child.local, [])
        XCTAssertEqual(child.inherited, [.pixels])
        XCTAssertEqual(child.descendant, [])
        XCTAssertEqual(child.effective, [.pixels])

        let own = tree.lockSources(for: tree.nodesByID[2]!, states: states)
        XCTAssertEqual(own.local, [.alpha])
        XCTAssertEqual(own.inherited, [.pixels])

        let sibling = tree.lockSources(for: tree.nodesByID[1]!, states: states)
        XCTAssertEqual(sibling.effective, [])
    }
}
