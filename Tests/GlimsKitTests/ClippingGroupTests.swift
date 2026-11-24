import AppKit
import XCTest
@testable import GlimsKit

/// The pure parts of Layer > Group with Previous, Ungroup and Merge
/// Group: the structural rules over the cached clipping roles, and the
/// Layers palette's marker and underline decisions. No engine or document
/// is needed.
final class ClippingGroupTests: XCTestCase {

    private func makeLayer(id: Int32, parent: Int32 = 0, depth: Int = 0,
                           kind: EngineSession.LayerKind = .pixel,
                           name: String? = nil,
                           clipping: EngineSession.LayerClipping = .none) -> EngineSession.Layer {
        EngineSession.Layer(id: id, parent: parent, depth: depth, kind: kind,
                            name: name ?? "Layer \(id)", mode: "normal",
                            isVisible: true, hasMask: false, isSelected: false, opacity: 1,
                            bounds: .zero, filterCount: 0, clipping: clipping)
    }

    private let baseClipping = EngineSession.LayerClipping(role: .base, base: 1, group: 9)
    private let clippedClipping = EngineSession.LayerClipping(role: .clipped, base: 1, group: 9)
    private let groupClipping = EngineSession.LayerClipping(role: .group, base: 1, group: 9)

    func testGroupWithPreviousRules() {
        let base = makeLayer(id: 1)
        let upper = makeLayer(id: 2)
        XCTAssertNil(ClippingCommandRules.refusal(command: .groupWithPrevious, layerID: 2,
                                                  layers: [upper, base]))
        // The bottom layer has no sibling below.
        XCTAssertEqual(ClippingCommandRules.refusal(command: .groupWithPrevious, layerID: 1,
                                                    layers: [upper, base]),
                       "There is no layer below to clip to.")
        // Already clipped refuses.
        let clipped = makeLayer(id: 2, clipping: clippedClipping)
        XCTAssertEqual(ClippingCommandRules.refusal(command: .groupWithPrevious, layerID: 2,
                                                    layers: [clipped, base]),
                       "The layer is already clipped.")
        // A group layer refuses.
        let group = makeLayer(id: 2, kind: .group)
        XCTAssertEqual(ClippingCommandRules.refusal(command: .groupWithPrevious, layerID: 2,
                                                    layers: [group, base]),
                       "A layer group cannot be clipped.")
        // A genuine editable source refuses.
        let text = makeLayer(id: 2, kind: .text)
        XCTAssertEqual(ClippingCommandRules.refusal(command: .groupWithPrevious, layerID: 2,
                                                    layers: [text, base]),
                       "Rasterize the text layer before clipping it.")
        // The layer below must be a pixel layer or a clipping group.
        let lowerGroup = makeLayer(id: 1, kind: .group)
        XCTAssertEqual(ClippingCommandRules.refusal(command: .groupWithPrevious, layerID: 2,
                                                    layers: [upper, lowerGroup]),
                       "The layer below must be a pixel layer or a clipping group.")
        // Directly above a clipping group, the layer joins it.
        let clippingGroup = makeLayer(id: 9, kind: .group, clipping: groupClipping)
        XCTAssertNil(ClippingCommandRules.refusal(command: .groupWithPrevious, layerID: 2,
                                                  layers: [upper, clippingGroup,
                                                           makeLayer(id: 3, parent: 9, depth: 1,
                                                                     clipping: clippedClipping),
                                                           makeLayer(id: 1, parent: 9, depth: 1,
                                                                     clipping: baseClipping)]))
        // A layer listed below in another parent is not "below": a
        // parent-blind rule would find `base` and accept.
        let cousin = makeLayer(id: 2, parent: 7, depth: 1)
        XCTAssertEqual(ClippingCommandRules.refusal(command: .groupWithPrevious, layerID: 2,
                                                    layers: [cousin, base]),
                       "There is no layer below to clip to.")
    }

    func testUngroupAndMergeGroupRules() {
        let outside = makeLayer(id: 5)
        let layers = [
            makeLayer(id: 1, clipping: baseClipping),
            makeLayer(id: 2, clipping: clippedClipping),
            makeLayer(id: 9, kind: .group, clipping: groupClipping),
            outside,
        ]
        for command in [EngineSession.ClippingCommand.ungroup, .mergeGroup] {
            XCTAssertNil(ClippingCommandRules.refusal(command: command, layerID: 1, layers: layers))
            XCTAssertNil(ClippingCommandRules.refusal(command: command, layerID: 2, layers: layers))
            XCTAssertNil(ClippingCommandRules.refusal(command: command, layerID: 9, layers: layers))
        }
        XCTAssertEqual(ClippingCommandRules.refusal(command: .ungroup, layerID: 5, layers: layers),
                       "Choose a clipping group, its base or one of its clipped layers.")
        XCTAssertEqual(ClippingCommandRules.refusal(command: .mergeGroup, layerID: 5, layers: layers),
                       "Choose a clipping group or one of its layers.")
        XCTAssertEqual(ClippingCommandRules.refusal(command: .groupWithPrevious, layerID: 5,
                                                    layers: layers),
                       "There is no layer below to clip to.")
    }

    /// Mirrors the engine fixture: a layer moved into the group without
    /// clipping keeps Ungroup from dissolving the group, which would take
    /// that layer with it, while a release that leaves a clipped layer
    /// below stays available.
    func testUngroupRefusesToDissolveAroundAnUnclippedMember() {
        let group = makeLayer(id: 9, kind: .group, clipping: groupClipping)
        let plain = makeLayer(id: 4, parent: 9, depth: 1)
        let upper = makeLayer(id: 3, parent: 9, depth: 1, clipping: clippedClipping)
        let lower = makeLayer(id: 2, parent: 9, depth: 1, clipping: clippedClipping)
        let base = makeLayer(id: 1, parent: 9, depth: 1, clipping: baseClipping)
        let refusal = "The clipping group has layers that are not clipped to its base."

        let mixed = [group, plain, upper, lower, base]
        XCTAssertEqual(ClippingCommandRules.refusal(command: .ungroup, layerID: 9, layers: mixed), refusal)
        XCTAssertEqual(ClippingCommandRules.refusal(command: .ungroup, layerID: 1, layers: mixed), refusal)
        XCTAssertEqual(ClippingCommandRules.refusal(command: .ungroup, layerID: 2, layers: mixed), refusal)
        XCTAssertNil(ClippingCommandRules.refusal(command: .ungroup, layerID: 3, layers: mixed))
        XCTAssertNil(ClippingCommandRules.refusal(command: .mergeGroup, layerID: 9, layers: mixed))

        let clippedOnly = [group, upper, lower, base]
        for id: Int32 in [9, 3, 2, 1] {
            XCTAssertNil(ClippingCommandRules.refusal(command: .ungroup, layerID: id, layers: clippedOnly))
        }
    }

    func testLowerBoundaryStrip() {
        let bounds = NSRect(x: 0, y: 0, width: 200, height: LayerRowView.rowHeight)
        XCTAssertTrue(LayerRowView.isInLowerBoundary(NSPoint(x: 40, y: 0), bounds: bounds))
        XCTAssertTrue(LayerRowView.isInLowerBoundary(NSPoint(x: 40, y: LayerRowView.lowerBoundaryHeight),
                                                     bounds: bounds))
        XCTAssertFalse(LayerRowView.isInLowerBoundary(NSPoint(x: 40, y: LayerRowView.lowerBoundaryHeight + 1),
                                                      bounds: bounds))
        XCTAssertFalse(LayerRowView.isInLowerBoundary(NSPoint(x: 40, y: bounds.maxY - 1), bounds: bounds))
    }

    /// Option-click hit-testing reads NSApp.currentEvent, which a unit
    /// test cannot set; the row claims the strip only with a handler, and
    /// a new row has none until the palette installs one.
    @MainActor
    func testNewRowHasNoBoundaryHandler() {
        let commit: LayerRowView.Commit = { _, _ in true }
        let row = LayerRowView(layer: makeLayer(id: 2, name: "Tint"),
                               context: .init(document: NSObject(), layerID: 2), commit: commit)
        XCTAssertNil(row.onLowerBoundaryOptionClick)
    }

    func testPaletteMarkerAndUnderlineDecisions() {
        XCTAssertTrue(ClippingRowPresentation.showsMarker(role: .clipped))
        XCTAssertFalse(ClippingRowPresentation.showsMarker(role: .base))
        XCTAssertFalse(ClippingRowPresentation.showsMarker(role: .group))
        XCTAssertFalse(ClippingRowPresentation.showsMarker(role: .none))

        XCTAssertTrue(ClippingRowPresentation.underlinesName(role: .base))
        XCTAssertFalse(ClippingRowPresentation.underlinesName(role: .clipped))
        XCTAssertFalse(ClippingRowPresentation.underlinesName(role: .group))
        XCTAssertFalse(ClippingRowPresentation.underlinesName(role: .none))
        XCTAssertEqual(ClippingRowPresentation.markerAccessibility, "Clipped to the layer below")
    }

    @MainActor
    func testGroupDetailsSayClippingGroup() {
        let group = makeLayer(id: 9, kind: .group, name: "Clipping Group", clipping: groupClipping)
        XCTAssertEqual(LayersPaletteController.detailsSuffix(for: group), "  (Clipping Group)")
        let ordinary = makeLayer(id: 9, kind: .group, name: "Set")
        XCTAssertEqual(LayersPaletteController.detailsSuffix(for: ordinary), "  (group)")
        let clipped = makeLayer(id: 2, name: "Tint", clipping: clippedClipping)
        XCTAssertEqual(LayersPaletteController.detailsSuffix(for: clipped), "")
        XCTAssertEqual(LayersPaletteController.title(for: clipped), "● Tint")
    }

    @MainActor
    func testRowShowsTheMarkerAndUnderlinesTheBase() {
        let commit: LayerRowView.Commit = { _, _ in true }
        let clipped = LayerRowView(layer: makeLayer(id: 2, name: "Tint", clipping: clippedClipping),
                                   context: .init(document: NSObject(), layerID: 2),
                                   commit: commit)
        XCTAssertFalse(clipped.clipMarker.isHidden)
        let clippedStyle = clipped.nameField.attributedStringValue
            .attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(clippedStyle ?? 0, 0, "only the base's name is underlined")

        let baseRow = LayerRowView(layer: makeLayer(id: 1, name: "Base", clipping: baseClipping),
                                   context: .init(document: NSObject(), layerID: 1),
                                   commit: commit)
        XCTAssertTrue(baseRow.clipMarker.isHidden)
        XCTAssertNotNil(baseRow.nameField.attributedStringValue
            .attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int)

        let plain = LayerRowView(layer: makeLayer(id: 3, name: "Plain"),
                                 context: .init(document: NSObject(), layerID: 3),
                                 commit: commit)
        XCTAssertTrue(plain.clipMarker.isHidden)
        XCTAssertNil(plain.nameField.attributedStringValue
            .attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int)
    }
}
