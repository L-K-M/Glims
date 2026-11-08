import AppKit
import XCTest
@testable import GlimsKit

/// The Layers palette row's mask affordances without an engine: the mask
/// thumbnail appears only for masked layers, both thumbnails take real
/// focus and clicks, the active-target ring and the disabled/shown mask
/// looks follow the state, and Option-click reports View Mask.
@MainActor
final class LayerMaskRowTests: XCTestCase {

    private func makeLayer(id: Int32 = 1, name: String = "Background",
                           hasMask: Bool = true) -> EngineSession.Layer {
        EngineSession.Layer(id: id, parent: 0, depth: 0, kind: .pixel, name: name, mode: "normal",
                            isVisible: true, hasMask: hasMask, isSelected: false, opacity: 1,
                            bounds: .zero, filterCount: 0)
    }

    private func makeMask(mask: Int32 = 42, enabled: Bool = true,
                          editing: Bool = false, showing: Bool = false) -> EngineSession.MaskState {
        EngineSession.MaskState(mask: mask, enabled: enabled, editing: editing, showing: showing)
    }

    private func makeRow(mask: EngineSession.MaskState? = nil,
                         target: ThumbnailButton.Target = .none,
                         hasMask: Bool = true) -> LayerRowView {
        LayerRowView(layer: makeLayer(hasMask: hasMask),
                     context: LayerRowView.Context(document: NSObject(), layerID: 1),
                     mask: mask, activeTarget: target,
                     commit: { _, _ in true })
    }

    /// Hosts the row in a real window and lays it out, the way the
    /// outline does, so frame and visibility checks see real geometry.
    private func host(_ row: LayerRowView, width: CGFloat = 240) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 60),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: width, height: 60))
        scroll.hasVerticalScroller = true
        // The outline gives each row its frame; a scroll view's
        // document view does not size itself.
        row.frame = NSRect(x: 0, y: 0, width: width, height: LayerRowView.rowHeight)
        scroll.documentView = row
        window.contentView = scroll
        window.orderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        row.layoutSubtreeIfNeeded()
        return window
    }

    func testMaskedRowShowsBothThumbnailsWithRealFrames() {
        let row = makeRow(mask: makeMask())
        let window = host(row)
        defer { window.close() }

        let layerThumb = row.layerThumb
        let maskThumb = try? XCTUnwrap(row.maskThumb)
        XCTAssertNotNil(maskThumb)
        for thumb in [layerThumb, maskThumb].compactMap({ $0 }) {
            XCTAssertGreaterThan(thumb.bounds.width, 0)
            XCTAssertGreaterThan(thumb.bounds.height, 0)
            XCTAssertGreaterThan(thumb.frame.width, 0)
            XCTAssertGreaterThan(thumb.frame.height, 0)
            // The button must sit inside the row's visible area, not just
            // exist offscreen.
            XCTAssertTrue(row.visibleRect.intersects(thumb.frame),
                          "\(thumb.kind) thumbnail frame \(thumb.frame) is visible in \(row.visibleRect)")
            XCTAssertTrue(row.bounds.intersects(thumb.frame))
        }
        XCTAssertNotEqual(layerThumb.frame.minX, maskThumb?.frame.minX ?? -1,
                          "the thumbnails sit side by side")
        XCTAssertLessThan(layerThumb.frame.maxX, maskThumb?.frame.minX ?? .greatestFiniteMagnitude,
                          "the layer thumbnail sits left of the mask thumbnail")
    }

    func testUnmaskedRowHasNoMaskThumbnail() {
        let row = makeRow(mask: nil, hasMask: false)
        XCTAssertNil(row.maskThumb)
        XCTAssertNotNil(row.layerThumb)
    }

    func testActiveTargetRingFollowsThePickedDrawable() {
        let layerTarget = makeRow(mask: makeMask(), target: .layer)
        XCTAssertTrue(layerTarget.layerThumb.isActiveTarget)
        XCTAssertEqual(layerTarget.maskThumb?.isActiveTarget, false)

        let maskTarget = makeRow(mask: makeMask(editing: true), target: .mask)
        XCTAssertFalse(maskTarget.layerThumb.isActiveTarget)
        XCTAssertEqual(maskTarget.maskThumb?.isActiveTarget, true)

        let idle = makeRow(mask: makeMask(), target: .none)
        XCTAssertFalse(idle.layerThumb.isActiveTarget)
        XCTAssertEqual(idle.maskThumb?.isActiveTarget, false)
    }

    func testMaskThumbnailReflectsEnabledAndShowing() {
        let enabled = makeRow(mask: makeMask(enabled: true, showing: false))
        XCTAssertEqual(enabled.maskThumb?.isDimmed, false)
        XCTAssertEqual(enabled.maskThumb?.showsBadge, false)

        let disabled = makeRow(mask: makeMask(enabled: false))
        XCTAssertEqual(disabled.maskThumb?.isDimmed, true)

        let showing = makeRow(mask: makeMask(showing: true))
        XCTAssertEqual(showing.maskThumb?.showsBadge, true)
    }

    func testMaskThumbnailUpdatesOnReload() {
        let row = makeRow(mask: makeMask(enabled: true, showing: false), target: .layer)
        XCTAssertEqual(row.maskThumb?.isDimmed, false)

        row.updateMask(makeMask(enabled: false, showing: true), activeTarget: .mask)
        XCTAssertEqual(row.maskThumb?.isDimmed, true)
        XCTAssertEqual(row.maskThumb?.showsBadge, true)
        XCTAssertEqual(row.maskThumb?.isActiveTarget, true)
        XCTAssertFalse(row.layerThumb.isActiveTarget)
    }

    func testThumbnailClicksReportThePickAndOption() {
        let row = makeRow(mask: makeMask())
        var picks: [(LayerRowView.ThumbnailPick, Bool)] = []
        row.onThumbnail = { picks.append(($0, $1)) }

        row.layerThumb.performClick(nil)
        row.maskThumb?.performClick(nil)
        XCTAssertEqual(picks.count, 2)
        XCTAssertEqual(picks[0].0, .layer)
        XCTAssertEqual(picks[1].0, .mask)
        XCTAssertFalse(picks.allSatisfy { $0.1 })

        // Option-click on the mask thumbnail is View Mask.
        row.optionIsDown = { true }
        row.maskThumb?.performClick(nil)
        XCTAssertEqual(picks.last?.0, .mask)
        XCTAssertEqual(picks.last?.1, true)

        // Option on the layer thumbnail still picks the layer.
        row.layerThumb.performClick(nil)
        XCTAssertEqual(picks.last?.0, .layer)
        XCTAssertEqual(picks.last?.1, true)
    }

    func testThumbnailAccessibility() {
        let row = makeRow(mask: makeMask(enabled: false, editing: true, showing: true))
        XCTAssertEqual(row.layerThumb.accessibilityLabel(), "Background layer")
        XCTAssertEqual(row.maskThumb?.accessibilityLabel(), "Background mask")
        let help = row.maskThumb?.accessibilityHelp() ?? ""
        XCTAssertTrue(help.contains("disabled"))
        XCTAssertTrue(help.contains("being edited"))
        XCTAssertTrue(help.contains("shown on the canvas"))
        XCTAssertTrue(help.contains("Option-click"))
    }

    func testThumbnailsTakeKeyboardFocus() {
        let row = makeRow(mask: makeMask())
        XCTAssertTrue(row.layerThumb.acceptsFirstResponder)
        XCTAssertEqual(row.maskThumb?.acceptsFirstResponder, true)
        // The buttons are real controls in the row's arranged subviews.
        XCTAssertTrue(row.arrangedSubviews.contains { $0 === row.layerThumb })
        XCTAssertTrue(row.arrangedSubviews.contains { $0 === row.maskThumb })
    }
}
