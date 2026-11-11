import AppKit
import XCTest
@testable import GlimsKit

/// The Layers palette's committed-effect rows without an engine: how the
/// snapshot interleaves them with layer children, how a drop index maps
/// back past the effect prefix, which stack commands a row may offer,
/// and how the row's own eye and staleness guards behave.
@MainActor
final class EffectRowTests: XCTestCase {

    private func layer(_ id: Int32, parent: Int32 = 0, depth: Int = 0,
                       kind: EngineSession.LayerKind = .pixel,
                       filterCount: Int = 0) -> EngineSession.Layer {
        EngineSession.Layer(id: id, parent: parent, depth: depth, kind: kind,
                            name: "L\(id)", mode: "normal", isVisible: true,
                            hasMask: false, isSelected: false, opacity: 1,
                            bounds: .zero, filterCount: filterCount)
    }

    private func effect(_ id: Int32, name: String? = nil,
                        operation: String? = nil, enabled: Bool = true,
                        opacity: Double = 1) -> EngineSession.Effect {
        EngineSession.Effect(id: id, name: name ?? "fx\(id)", operation: operation ?? "op\(id)",
                             isEnabled: enabled, opacity: opacity)
    }

    /// Group 4 holds layer 3 and carries two committed effects; root
    /// holds layer 5 and the group, layer 1 sits last.
    private func fixture() -> (snapshot: LayerListSnapshot, owner: NSObject) {
        let owner = NSObject()
        let snapshot = LayerListSnapshot(
            document: owner,
            layers: [layer(5), layer(4, kind: .group, filterCount: 2),
                     layer(3, parent: 4, depth: 1), layer(1)],
            effects: [4: [effect(11), effect(12, enabled: false)]])
        return (snapshot, owner)
    }

    // MARK: Snapshot rows

    func testEffectRowsPrecedeLayerChildrenTopFirst() {
        let (snapshot, _) = fixture()
        let group = snapshot.tree.nodesByID[4]!
        let children = snapshot.displayedChildren(of: group)
        XCTAssertEqual(children.count, 3)
        XCTAssertEqual((children[0] as? EffectItem)?.effect.id, 11)
        XCTAssertEqual((children[1] as? EffectItem)?.effect.id, 12)
        XCTAssertEqual((children[2] as? LayerTree.Node)?.id, 3)
        // A layer without effects shows only its (empty) layer children.
        XCTAssertTrue(snapshot.displayedChildren(of: snapshot.tree.nodesByID[5]!).isEmpty)
    }

    func testEffectRowsNeedTheSnapshotDocument() {
        // No document identity: effect rows cannot guard their commands,
        // so the snapshot keeps none.
        let snapshot = LayerListSnapshot(document: nil, layers: [layer(5)],
                                         effects: [5: [effect(11)]])
        XCTAssertTrue(snapshot.effects(of: snapshot.tree.nodesByID[5]!).isEmpty)
    }

    func testEffectResolutionRejectsStaleContexts() {
        let (snapshot, owner) = fixture()
        let row = snapshot.effects(of: snapshot.tree.nodesByID[4]!)[0]
        let live: [Int32: [EngineSession.Effect]] = [4: [effect(11), effect(12)]]

        XCTAssertTrue(snapshot.effect(for: row, for: owner, currentEffects: live) === row)
        // The effect went away between snapshot and lookup.
        XCTAssertNil(snapshot.effect(for: row, for: owner, currentEffects: [4: [effect(12)]]))
        // The drawable itself lost its stack.
        XCTAssertNil(snapshot.effect(for: row, for: owner, currentEffects: [:]))
        // Another document's palette asking about this row.
        XCTAssertNil(snapshot.effect(for: row, for: NSObject(), currentEffects: live))
        // A layer node is not an effect row.
        XCTAssertNil(snapshot.effect(for: snapshot.tree.nodesByID[3], for: owner,
                                     currentEffects: live))
        // An item bound to another document is not this document's row.
        let foreign = EffectItem(document: NSObject(), drawable: 4, effect: effect(11))
        XCTAssertNil(snapshot.effect(for: foreign, for: owner, currentEffects: live))
    }

    // MARK: Drop index mapping

    func testDisplayedIndexMapsPastTheEffectPrefix() {
        // Two effect rows on the parent: display 0-1 are effects, 2 is
        // layer child 0.
        XCTAssertNil(LayerListSnapshot.layerChildIndex(forDisplayedIndex: 0, effectCount: 2))
        XCTAssertNil(LayerListSnapshot.layerChildIndex(forDisplayedIndex: 1, effectCount: 2))
        XCTAssertEqual(LayerListSnapshot.layerChildIndex(forDisplayedIndex: 2, effectCount: 2), 0)
        XCTAssertEqual(LayerListSnapshot.layerChildIndex(forDisplayedIndex: 4, effectCount: 2), 2)
        // No effects: the display index is the layer index.
        XCTAssertEqual(LayerListSnapshot.layerChildIndex(forDisplayedIndex: 0, effectCount: 0), 0)
        XCTAssertEqual(LayerListSnapshot.layerChildIndex(forDisplayedIndex: 3, effectCount: 0), 3)
    }

    // MARK: Command policy

    private let pixelLayer = EngineSession.Layer(
        id: 4, parent: 0, depth: 0, kind: .pixel, name: "L4", mode: "normal",
        isVisible: true, hasMask: false, isSelected: false, opacity: 1,
        bounds: .zero, filterCount: 2)

    func testMovesRespectStackPosition() {
        let top = effect(11), bottom = effect(12)
        // Top of a two-effect stack cannot rise; the bottom cannot sink.
        XCTAssertFalse(EffectCommands.enabled(.raise, at: 0, of: 2, effect: top,
                                              layer: pixelLayer, locks: []))
        XCTAssertFalse(EffectCommands.enabled(.toTop, at: 0, of: 2, effect: top,
                                              layer: pixelLayer, locks: []))
        XCTAssertTrue(EffectCommands.enabled(.lower, at: 0, of: 2, effect: top,
                                             layer: pixelLayer, locks: []))
        XCTAssertTrue(EffectCommands.enabled(.raise, at: 1, of: 2, effect: bottom,
                                             layer: pixelLayer, locks: []))
        XCTAssertFalse(EffectCommands.enabled(.lower, at: 1, of: 2, effect: bottom,
                                              layer: pixelLayer, locks: []))
        XCTAssertFalse(EffectCommands.enabled(.toBottom, at: 1, of: 2, effect: bottom,
                                              layer: pixelLayer, locks: []))
        // A single effect has nowhere to go; remove still applies.
        XCTAssertFalse(EffectCommands.enabled(.raise, at: 0, of: 1, effect: top,
                                              layer: pixelLayer, locks: []))
        XCTAssertTrue(EffectCommands.enabled(.remove, at: 0, of: 1, effect: top,
                                             layer: pixelLayer, locks: []))
    }

    func testMergeNeedsAnEnabledEffectOnAnUnlockedPixelLayer() {
        let fx = effect(11)
        for kind in [EngineSession.LayerKind.group, .text, .link, .vector] {
            let layer = EngineSession.Layer(id: 4, parent: 0, depth: 0, kind: kind, name: "L4",
                                            mode: "normal", isVisible: true, hasMask: false,
                                            isSelected: false, opacity: 1, bounds: .zero,
                                            filterCount: 1)
            XCTAssertFalse(EffectCommands.enabled(.merge, at: 0, of: 1, effect: fx,
                                                  layer: layer, locks: []),
                           "merge must stay off on \(kind)")
        }
        XCTAssertTrue(EffectCommands.enabled(.merge, at: 0, of: 1, effect: fx,
                                             layer: pixelLayer, locks: []))
        XCTAssertFalse(EffectCommands.enabled(.merge, at: 0, of: 1, effect: fx,
                                              layer: pixelLayer, locks: [.pixels]))
        XCTAssertFalse(EffectCommands.enabled(.merge, at: 0, of: 1,
                                              effect: effect(11, enabled: false),
                                              layer: pixelLayer, locks: []))
        // A vanished layer row offers nothing; remove still stands.
        XCTAssertFalse(EffectCommands.enabled(.merge, at: 0, of: 1, effect: fx,
                                              layer: nil, locks: []))
        XCTAssertTrue(EffectCommands.enabled(.remove, at: 0, of: 1, effect: fx,
                                             layer: nil, locks: []))
    }

    // MARK: Row view

    private final class Commit {
        var changes: [EngineSession.EffectChange] = []
        var items: [EffectItem] = []
        var accepted = true
        func call(_ item: EffectItem, _ change: EngineSession.EffectChange) -> Bool {
            items.append(item)
            changes.append(change)
            return accepted
        }
    }

    private func makeRow(effect fx: EngineSession.Effect? = nil,
                         commit: Commit = Commit()) -> EffectRowView {
        EffectRowView(item: EffectItem(document: NSObject(), drawable: 4,
                                       effect: fx ?? effect(11)),
                      isSelected: false, commit: commit.call)
    }

    func testEyeCommitsTheToggleAndRevertsWhenRefused() {
        let commit = Commit()
        let row = makeRow(commit: commit)
        row.eye.performClick(nil)
        XCTAssertEqual(commit.changes.count, 1)
        XCTAssertEqual(commit.changes[0].isEnabled, false)
        XCTAssertEqual(row.eye.state, .off)

        commit.accepted = false
        row.eye.performClick(nil)
        XCTAssertEqual(commit.changes[1].isEnabled, true)
        XCTAssertEqual(row.eye.state, .off, "a refused toggle shows the effect's state again")
    }

    func testRowShowsNameBadgeAndOpacity() {
        let full = makeRow()
        XCTAssertNil(full.opacityLabel, "full opacity keeps the readout out")
        XCTAssertEqual(full.nameLabel.stringValue, "fx11")
        XCTAssertEqual(full.accessibilityLabel(), "Filter fx11")
        XCTAssertEqual(full.eye.accessibilityLabel(), "Disable fx11")

        let dimmed = makeRow(effect: effect(12, name: "Soft blur", enabled: false, opacity: 0.4))
        XCTAssertEqual(dimmed.opacityLabel?.stringValue, "40%")
        XCTAssertEqual(dimmed.eye.state, .off)
        XCTAssertEqual(dimmed.eye.accessibilityLabel(), "Enable Soft blur")
    }

    func testOpacityTextClampsAndRounds() {
        XCTAssertEqual(EffectRowView.opacityText(1), "100%")
        XCTAssertEqual(EffectRowView.opacityText(0.655), "66%")
        XCTAssertEqual(EffectRowView.opacityText(0), "0%")
        XCTAssertEqual(EffectRowView.opacityText(1.4), "100%")
        XCTAssertEqual(EffectRowView.opacityText(-0.2), "0%")
    }

    func testRowLaysOutAtPaletteWidthAndZeroFrame() {
        let row = makeRow(effect: effect(11, name: "A very long filter name that must truncate"))
        XCTAssertEqual(row.frame, .zero)
        row.frame = NSRect(x: 0, y: 0, width: 200, height: LayerRowView.rowHeight)
        row.layoutSubtreeIfNeeded()
        XCTAssertTrue(row.nameLabel.lineBreakMode == .byTruncatingTail)
        XCTAssertGreaterThanOrEqual(row.fittingSize.height, 22)
        XCTAssertTrue(row.arrangedSubviews.first === row.eye,
                      "the eye stays the leading control at 200pt")
    }

    func testRowCarriesItsOwnIdentity() {
        let owner = NSObject()
        let item = EffectItem(document: owner, drawable: 7, effect: effect(21))
        let commit = Commit()
        let row = EffectRowView(item: item, isSelected: true, commit: commit.call)
        row.eye.performClick(nil)
        XCTAssertTrue(commit.items.first?.document === owner)
        XCTAssertEqual(commit.items.first?.drawable, 7)
        XCTAssertEqual(commit.items.first?.effect.id, 21)
    }

    // MARK: Badge accessibility

    /// The row's semantic badge, found by its user label ("Filter"
    /// unselected, "Selected filter" selected) while walking the
    /// view tree, never by private type or arranged-subview position.
    /// Unignored AX children would omit precisely the missing element
    /// that this regression needs to inspect.
    private func badge(in row: EffectRowView) -> NSView? {
        let badgeLabels: Set<String> = ["Filter", "Selected filter"]
        func search(_ element: Any) -> NSView? {
            guard let view = element as? NSView else { return nil }
            if let label = view.accessibilityLabel(), badgeLabels.contains(label) {
                return view
            }
            let children: [Any] = view.subviews
            for child in children {
                if let found = search(child) { return found }
            }
            return nil
        }
        return search(row)
    }

    func testBadgeIsAnAccessibilityElementWithImageRole() {
        let row = makeRow()
        guard let badge = badge(in: row) else {
            XCTFail("no view carries the badge label \"Filter\" or \"Selected filter\"")
            return
        }
        XCTAssertTrue(badge.isAccessibilityElement(),
                      "the fx badge must be an accessibility element itself")
        XCTAssertEqual(badge.accessibilityRole(), .image,
                       "the badge is a drawn mark, so its role is image")
    }

    func testBadgeLabelTracksUpdateSelected() {
        let row = makeRow()
        guard let badge = badge(in: row) else {
            XCTFail("no view carries the badge label \"Filter\" or \"Selected filter\"")
            return
        }
        XCTAssertEqual(badge.accessibilityLabel(), "Filter")

        row.updateSelected(true)
        XCTAssertEqual(badge.accessibilityLabel(), "Selected filter")
        XCTAssertTrue(self.badge(in: row) === badge,
                      "the selected label still belongs to the same badge element")

        row.updateSelected(false)
        XCTAssertEqual(badge.accessibilityLabel(), "Filter")

        // A row built selected starts with the selected label.
        let selected = EffectRowView(
            item: EffectItem(document: NSObject(), drawable: 4, effect: effect(11)),
            isSelected: true, commit: Commit().call)
        XCTAssertEqual(self.badge(in: selected)?.accessibilityLabel(), "Selected filter")
    }
}
