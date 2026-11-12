import AppKit
import XCTest
import RigiUI
@testable import GlimsKit

/// The Channels palette body without an engine: the component rows, the
/// flat channel list, the Quick Mask and selection controls, and the
/// footer commands. Checks drive the real controls — clicks through
/// `performClick`, refused callbacks through each control's own action
/// dispatch — and read the semantic `Action`s the palette reports.
@MainActor
final class ChannelsPaletteViewTests: XCTestCase {
    @MainActor
    func testInkChannelControlsPreserveTargetAndAttributeEditing() throws {
        let view = ChannelsPaletteView()
        var actions: [ChannelsPaletteView.Action] = []
        view.onAction = { actions.append($0) }
        view.update(.init(components: componentState(mode: .multichannel, supported: []),
            channels: [channel(7)], activeChannel: 7, hasSelectedChannels: true,
            quickMask: quickMask(), acceptsEdits: true, multichannel: true))
        XCTAssertTrue(view.componentRows.isEmpty)
        XCTAssertTrue(try XCTUnwrap(view.channelRows.first).eyeToggle.isEnabled)
        XCTAssertTrue(try XCTUnwrap(view.channelRows.first).thumbnail.isEnabled)
        XCTAssertFalse(view.quickMaskButton.isEnabled)
        XCTAssertFalse(view.returnToLayersButton.isEnabled)
        XCTAssertFalse(view.selectionPopup.isEnabled)
        let bar = try XCTUnwrap(descendant(of: view, as: ClassicPaletteButtonBar.self))
        let new = try XCTUnwrap(footerButton("New Channel", in: bar))
        let duplicate = try XCTUnwrap(footerButton("Duplicate Channel", in: bar))
        let delete = try XCTUnwrap(footerButton("Delete Channel", in: bar))
        let edit = try XCTUnwrap(footerButton("Edit Channel", in: bar))
        XCTAssertFalse(new.isEnabled); XCTAssertFalse(duplicate.isEnabled); XCTAssertFalse(delete.isEnabled)
        XCTAssertTrue(edit.isEnabled)
        fire(new); fire(duplicate); fire(delete); fire(view.quickMaskButton); fire(view.returnToLayersButton)
        XCTAssertTrue(actions.isEmpty, "stale disabled callbacks cannot emit unsupported actions")
        fire(edit)
        XCTAssertEqual(actions, [.editChannel(7)])
    }

    // MARK: Fixtures

    private let rgbBits: EngineSession.Components = [.red, .green, .blue, .alpha]

    private func componentState(mode: EngineSession.ComponentMode = .rgb,
                                supported: EngineSession.Components,
                                active: EngineSession.Components = [],
                                visible: EngineSession.Components = []) -> EngineSession.ComponentState {
        EngineSession.ComponentState(mode: mode, supported: supported,
                                     active: active, visible: visible)
    }

    private func channel(_ id: Int32, name: String? = nil, isVisible: Bool = true,
                         isSelected: Bool = false, isQuickMask: Bool = false) -> EngineSession.Channel {
        EngineSession.Channel(id: id, name: name ?? "Channel \(id)", isVisible: isVisible,
                              isSelected: isSelected, isQuickMask: isQuickMask,
                              opacity: 1, color: .black)
    }

    private func quickMask(enabled: Bool = false) -> EngineSession.QuickMaskState {
        EngineSession.QuickMaskState(enabled: enabled, channel: enabled ? 50 : 0,
                                     inverted: false, color: .black)
    }

    private func snapshot(components: EngineSession.ComponentState? = nil,
                          channels: [EngineSession.Channel] = [],
                          activeChannel: Int32? = nil,
                          quickMask: EngineSession.QuickMaskState? = nil,
                          acceptsEdits: Bool = false) -> ChannelsPaletteView.Snapshot {
        ChannelsPaletteView.Snapshot(components: components, channels: channels,
                                     activeChannel: activeChannel, quickMask: quickMask,
                                     acceptsEdits: acceptsEdits)
    }

    /// An editable snapshot over the standard RGB component model unless
    /// `components` says otherwise.
    private func editable(channels: [EngineSession.Channel] = [],
                          activeChannel: Int32? = nil,
                          quickMask: EngineSession.QuickMaskState? = nil,
                          components: EngineSession.ComponentState? = nil) -> ChannelsPaletteView.Snapshot {
        snapshot(components: components ?? componentState(supported: rgbBits,
                                                        active: [.red], visible: rgbBits),
                 channels: channels, activeChannel: activeChannel,
                 quickMask: quickMask, acceptsEdits: true)
    }

    private func makeCGImage(width: Int = 8, height: Int = 8) -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .calibratedRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.cgImage!
    }

    /// The footer button carrying `titlePrefix`, found through the bar's
    /// real control hierarchy (the bar keeps its buttons private).
    private func footerButton(_ titlePrefix: String,
                              in bar: ClassicPaletteButtonBar) -> ClassicToolbarButton? {
        var match: ClassicToolbarButton?
        func walk(_ view: NSView) {
            if match != nil { return }
            if let button = view as? ClassicToolbarButton,
               button.toolTip?.hasPrefix(titlePrefix) == true {
                match = button
                return
            }
            view.subviews.forEach(walk)
        }
        walk(bar)
        return match
    }

    /// Sends a control's action the way its tracking would have, without
    /// the enabled check — proves the palette's own guards refuse stale
    /// or disabled callbacks.
    private func fire(_ control: NSControl) {
        control.sendAction(control.action, to: control.target)
    }

    private func descendant<T: NSView>(of view: NSView, as type: T.Type) -> T? {
        for subview in view.subviews {
            if let match = subview as? T { return match }
            if let match = descendant(of: subview, as: type) { return match }
        }
        return nil
    }

    /// Records the semantic actions the palette reports.
    private final class ActionLog {
        var actions: [ChannelsPaletteView.Action] = []
    }

    // MARK: Component rows

    func testComponentRowsMatchTheSupportedModel() {
        let view = ChannelsPaletteView()

        view.update(.init(components: componentState(supported: rgbBits,
                                                     active: [.red], visible: rgbBits),
                          acceptsEdits: true))
        XCTAssertEqual(view.componentRows.map(\.component), [.red, .green, .blue, .alpha])
        // The toggles start on the snapshot's bits.
        XCTAssertEqual(view.componentRows[0].eyeToggle.state, .on)
        XCTAssertEqual(view.componentRows[0].editToggle.state, .on)
        XCTAssertEqual(view.componentRows[1].eyeToggle.state, .on)
        XCTAssertEqual(view.componentRows[1].editToggle.state, .off)

        view.update(.init(components: componentState(mode: .grayscale,
                                                     supported: [.gray, .alpha]),
                          acceptsEdits: true))
        XCTAssertEqual(view.componentRows.map(\.component), [.gray, .alpha])

        view.update(.init(components: componentState(mode: .indexed, supported: [.indexed]),
                          acceptsEdits: true))
        XCTAssertEqual(view.componentRows.map(\.component), [.indexed])

        view.update(.init(components: componentState(mode: .indexed,
                                                     supported: [.indexed, .alpha]),
                          acceptsEdits: true))
        XCTAssertEqual(view.componentRows.map(\.component), [.indexed, .alpha])

        // Unsupported primaries drop out; alpha only shows when supported.
        view.update(.init(components: componentState(supported: [.red, .blue]),
                          acceptsEdits: true))
        XCTAssertEqual(view.componentRows.map(\.component), [.red, .blue])

        // No component model: no rows.
        view.update(.init())
        XCTAssertTrue(view.componentRows.isEmpty)
    }

    func testComponentEyeAndEditTogglesReportTheirOwnBits() {
        let view = ChannelsPaletteView()
        let log = ActionLog()
        view.onAction = { log.actions.append($0) }
        view.update(.init(components: componentState(supported: rgbBits,
                                                     active: [.red], visible: rgbBits),
                          acceptsEdits: true))

        let red = view.componentRows.first { $0.component == .red }!
        let green = view.componentRows.first { $0.component == .green }!

        red.eyeToggle.performClick(nil)
        green.editToggle.performClick(nil)
        red.editToggle.performClick(nil)

        XCTAssertEqual(log.actions, [
            .setComponentVisible(.red, false),
            .setComponentActive(.green, true),
            .setComponentActive(.red, false),
        ])
        // Each toggle moved only its own bit.
        XCTAssertEqual(red.eyeToggle.state, .off)
        XCTAssertEqual(red.editToggle.state, .off)
        XCTAssertEqual(green.eyeToggle.state, .on)
        XCTAssertEqual(green.editToggle.state, .on)
    }

    // MARK: Snapshot discipline

    func testSnapshotUpdatesAndThumbnailsNeverEmitActions() {
        let view = ChannelsPaletteView()
        let log = ActionLog()
        view.onAction = { log.actions.append($0) }
        let cg = makeCGImage()

        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1)], acceptsEdits: true))
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1), channel(2)], activeChannel: 2,
                          quickMask: quickMask(enabled: true), acceptsEdits: true))
        view.setThumbnail(cg, for: 1)
        view.setThumbnails([2: cg])
        view.update(.init())

        XCTAssertTrue(log.actions.isEmpty)
    }

    func testActiveChannelRingAndHighlightFollowTheSnapshotNotTheRowFlag() {
        let view = ChannelsPaletteView()
        // Channel 1 claims isSelected; the snapshot's activeChannel names 2.
        let first = channel(1, isSelected: true)
        let second = channel(2, isSelected: false)
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [first, second], activeChannel: 2,
                          acceptsEdits: true))

        XCTAssertEqual(view.effectiveActiveChannel, 2)
        XCTAssertTrue(view.channelRows[1].isTarget)
        XCTAssertTrue(view.channelRows[1].thumbnail.isActiveTarget)
        XCTAssertFalse(view.channelRows[0].isTarget)
        XCTAssertFalse(view.channelRows[0].thumbnail.isActiveTarget)

        // Layers as the target clears both marks even though row 1's flag
        // still says selected.
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [first, second], acceptsEdits: true))
        XCTAssertNil(view.effectiveActiveChannel)
        for row in view.channelRows {
            XCTAssertFalse(row.isTarget)
            XCTAssertFalse(row.thumbnail.isActiveTarget)
        }

        // A stale active id that no channel carries reads as the layers.
        XCTAssertNil(ChannelsPaletteView.effectiveActiveChannel(
            in: .init(channels: [first], activeChannel: 99)))
    }

    func testStaleRowCallbacksCannotReachTheChannelsThatReplacedThem() {
        let view = ChannelsPaletteView()
        let log = ActionLog()
        view.onAction = { log.actions.append($0) }
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1), channel(2)], acceptsEdits: true))
        let staleEye = view.channelRows[0].eyeToggle
        let staleThumb = view.channelRows[0].thumbnail

        // The reload swaps the whole list; the old row is detached but alive.
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(3), channel(4)], acceptsEdits: true))

        staleEye.performClick(nil)
        staleThumb.performClick(nil)

        XCTAssertTrue(log.actions.isEmpty)
        // The refused eye shows the state it was built with again.
        XCTAssertEqual(staleEye.state, .on)

        // The replacement rows still report their own ids.
        view.channelRows[0].thumbnail.performClick(nil)
        XCTAssertEqual(log.actions, [.selectChannel(3)])
    }

    // MARK: Guards

    func testBusyDocumentRefusesEveryEditButKeepsTheListReadable() {
        let view = ChannelsPaletteView()
        let log = ActionLog()
        view.onAction = { log.actions.append($0) }
        view.update(.init(components: componentState(supported: rgbBits,
                                                     active: [.red], visible: rgbBits),
                          channels: [channel(1), channel(2, isQuickMask: true)],
                          activeChannel: 1, quickMask: quickMask(enabled: false),
                          acceptsEdits: false))

        // Rows still render.
        XCTAssertEqual(view.componentRows.count, 4)
        XCTAssertEqual(view.channelRows.count, 2)

        // Nothing that changes the image is offered.
        for row in view.componentRows {
            XCTAssertFalse(row.eyeToggle.isEnabled)
            XCTAssertFalse(row.editToggle.isEnabled)
        }
        for row in view.channelRows {
            XCTAssertFalse(row.eyeToggle.isEnabled)
            XCTAssertFalse(row.thumbnail.isEnabled)
        }
        XCTAssertFalse(view.quickMaskButton.isEnabled)
        XCTAssertFalse(view.returnToLayersButton.isEnabled)
        XCTAssertFalse(view.selectionPopup.isEnabled)
        for prefix in ["New Channel", "Duplicate Channel",
                       "Edit Channel Attributes", "Delete Channel"] {
            XCTAssertEqual(footerButton(prefix, in: view.paletteButtonBar)?.isEnabled, false)
        }

        // Even a callback that fires anyway is refused by the palette's guards.
        fire(view.componentRows[0].eyeToggle)
        fire(view.componentRows[0].editToggle)
        fire(view.channelRows[0].eyeToggle)
        fire(view.channelRows[0].thumbnail)
        fire(view.quickMaskButton)
        fire(view.returnToLayersButton)
        fire(view.selectionPopup)
        for prefix in ["New Channel", "Duplicate Channel",
                       "Edit Channel Attributes", "Delete Channel"] {
            if let button = footerButton(prefix, in: view.paletteButtonBar) { fire(button) }
        }
        XCTAssertTrue(log.actions.isEmpty)
    }

    func testMissingComponentModelBlocksEditsButStillAllowsTargetPicks() {
        let view = ChannelsPaletteView()
        let log = ActionLog()
        view.onAction = { log.actions.append($0) }
        // Channels and an active target, but no component model read yet.
        view.update(.init(channels: [channel(1), channel(2)],
                          activeChannel: 1,
                          quickMask: quickMask(enabled: false),
                          acceptsEdits: true))

        XCTAssertTrue(view.componentRows.isEmpty)
        XCTAssertEqual(view.channelRows.count, 2)

        // Editing affordances are off.
        XCTAssertFalse(view.channelRows[0].eyeToggle.isEnabled)
        XCTAssertFalse(view.quickMaskButton.isEnabled)
        XCTAssertFalse(view.selectionPopup.isEnabled)
        XCTAssertEqual(footerButton("New Channel", in: view.paletteButtonBar)?.isEnabled, false)

        // Target picks need only acceptsEdits.
        XCTAssertTrue(view.channelRows[0].thumbnail.isEnabled)
        XCTAssertTrue(view.returnToLayersButton.isEnabled)
        view.channelRows[1].thumbnail.performClick(nil)
        view.returnToLayersButton.performClick(nil)
        XCTAssertEqual(log.actions, [.selectChannel(2), .returnToLayers])
    }

    // MARK: Quick Mask and target controls

    func testQuickMaskToggleAndReturnToLayers() {
        let view = ChannelsPaletteView()
        let log = ActionLog()
        view.onAction = { log.actions.append($0) }
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1)], activeChannel: 1,
                          quickMask: quickMask(enabled: false), acceptsEdits: true))

        XCTAssertEqual(view.quickMaskButton.state, .off)
        view.quickMaskButton.performClick(nil)
        XCTAssertEqual(log.actions, [.setQuickMask(true)])
        XCTAssertEqual(view.quickMaskButton.state, .on)
        view.quickMaskButton.performClick(nil)
        XCTAssertEqual(log.actions, [.setQuickMask(true), .setQuickMask(false)])

        view.returnToLayersButton.performClick(nil)
        XCTAssertEqual(log.actions, [.setQuickMask(true), .setQuickMask(false), .returnToLayers])

        // The snapshot drives the toggle's state.
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1)], activeChannel: 1,
                          quickMask: quickMask(enabled: true), acceptsEdits: true))
        XCTAssertEqual(view.quickMaskButton.state, .on)

        // No Quick Mask state: the toggle is refused and shows off again.
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1)], activeChannel: 1, acceptsEdits: true))
        XCTAssertFalse(view.quickMaskButton.isEnabled)
        fire(view.quickMaskButton)
        XCTAssertEqual(view.quickMaskButton.state, .off)
        XCTAssertEqual(log.actions.count, 3)

        // Layers as the target: Return to Layers is not offered.
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1)], quickMask: quickMask(enabled: true),
                          acceptsEdits: true))
        XCTAssertFalse(view.returnToLayersButton.isEnabled)
        fire(view.returnToLayersButton)
        XCTAssertEqual(log.actions.count, 3)
    }

    func testChannelToSelectionOffersAllFourOperations() {
        let view = ChannelsPaletteView()
        let log = ActionLog()
        view.onAction = { log.actions.append($0) }
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1), channel(2)], activeChannel: 2,
                          acceptsEdits: true))
        let popup = view.selectionPopup
        XCTAssertTrue(popup.isEnabled)

        let expected: [EngineSession.SelectOperation] = [.replace, .add, .subtract, .intersect]
        XCTAssertEqual(ChannelsPaletteView.selectionOperations, expected)
        for (index, operation) in expected.enumerated() {
            popup.selectItem(at: index)
            fire(popup)
            XCTAssertEqual(log.actions.last, .channelToSelection(2, operation))
        }
        XCTAssertEqual(log.actions.count, 4)

        // No active channel: refused even for a callback that fires anyway.
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1), channel(2)], acceptsEdits: true))
        XCTAssertFalse(popup.isEnabled)
        let before = log.actions.count
        fire(popup)
        XCTAssertEqual(log.actions.count, before)
    }

    // MARK: Footer

    func testFooterCommandsAndTheLiveQuickMaskDeleteRefusal() {
        let view = ChannelsPaletteView()
        let log = ActionLog()
        view.onAction = { log.actions.append($0) }
        let normal = channel(1, name: "Alpha")
        let mask = channel(2, name: "Quick Mask", isQuickMask: true)
        let bar = view.paletteButtonBar
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [normal, mask], activeChannel: 1,
                          quickMask: quickMask(enabled: true), acceptsEdits: true))

        footerButton("New Channel", in: bar)?.performClick(nil)
        footerButton("Duplicate Channel", in: bar)?.performClick(nil)
        footerButton("Edit Channel Attributes", in: bar)?.performClick(nil)
        footerButton("Delete Channel", in: bar)?.performClick(nil)

        XCTAssertEqual(log.actions, [
            .newChannel, .duplicateChannel(1), .editChannel(1), .deleteChannel(1),
        ])

        // The live Quick Mask is the active channel: it keeps duplicate
        // and attribute edits but refuses deletion — even for a callback
        // that fires past the disabled button.
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [normal, mask], activeChannel: 2,
                          quickMask: quickMask(enabled: true), acceptsEdits: true))
        let delete = footerButton("Delete Channel", in: bar)
        XCTAssertNotNil(delete)
        XCTAssertEqual(delete?.isEnabled, false)
        if let delete { fire(delete) }
        footerButton("Edit Channel Attributes", in: bar)?.performClick(nil)
        footerButton("Duplicate Channel", in: bar)?.performClick(nil)

        XCTAssertEqual(log.actions.suffix(2), [.editChannel(2), .duplicateChannel(2)])
        XCTAssertFalse(log.actions.contains(.deleteChannel(2)))

        // The Quick Mask row's own Eye still works: only delete and
        // rename are refused.
        let maskRow = view.channelRows.first { $0.channelID == 2 }!
        XCTAssertTrue(maskRow.isQuickMaskRow)
        maskRow.eyeToggle.performClick(nil)
        XCTAssertEqual(log.actions.last, .setChannelVisible(2, false))

        // With the layers as the target only New remains.
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [normal, mask], quickMask: quickMask(enabled: true),
                          acceptsEdits: true))
        for prefix in ["Duplicate Channel", "Edit Channel Attributes", "Delete Channel"] {
            XCTAssertEqual(footerButton(prefix, in: bar)?.isEnabled, false)
        }
        footerButton("New Channel", in: bar)?.performClick(nil)
        XCTAssertEqual(log.actions.last, .newChannel)
    }

    // MARK: Thumbnails

    func testSuppliedThumbnailImageIsWhatTheRowDisplays() {
        let view = ChannelsPaletteView()
        let cg = makeCGImage(width: 8, height: 8)
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1), channel(2)], acceptsEdits: true))
        view.setThumbnail(cg, for: 1)
        view.setThumbnails([2: cg])

        for row in view.channelRows {
            let shown = row.thumbnail.thumbnail
            XCTAssertNotNil(shown)
            XCTAssertEqual(shown?.size, NSSize(width: 8, height: 8))
            var rect = NSRect.zero
            XCTAssertTrue(shown?.cgImage(forProposedRect: &rect, context: nil, hints: nil) === cg)
        }

        // A reload rebuilds the rows and reapplies the kept thumbnails.
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1), channel(2)], acceptsEdits: true))
        XCTAssertNotNil(view.channelRows[0].thumbnail.thumbnail)
        XCTAssertNotNil(view.channelRows[1].thumbnail.thumbnail)

        // A thumbnail that lands before its channel's snapshot still shows up.
        view.setThumbnail(cg, for: 3)
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1), channel(2), channel(3)], acceptsEdits: true))
        XCTAssertNotNil(view.channelRows.first { $0.channelID == 3 }?.thumbnail.thumbnail)

        // Channels that leave the snapshot take their thumbnails with them.
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1)], acceptsEdits: true))
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: [channel(1), channel(3)], acceptsEdits: true))
        XCTAssertNil(view.channelRows.first { $0.channelID == 3 }?.thumbnail.thumbnail)
    }

    // MARK: Layout

    func testLayoutAtTheMinimumPaletteSize() {
        let size = ChannelsPaletteView.minimumContentSize
        let view = ChannelsPaletteView(frame: NSRect(origin: .zero, size: size))
        view.update(.init(components: componentState(supported: rgbBits,
                                                     active: [.red], visible: rgbBits),
                          channels: [channel(1), channel(2, name: "Mask", isQuickMask: true),
                                     channel(3)],
                          activeChannel: 1, quickMask: quickMask(enabled: true),
                          acceptsEdits: true))
        view.layoutSubtreeIfNeeded()

        // The fixed controls are offered and inside the palette.
        XCTAssertTrue(view.quickMaskButton.isEnabled)
        XCTAssertTrue(view.returnToLayersButton.isEnabled)
        XCTAssertTrue(view.selectionPopup.isEnabled)
        for control in [view.quickMaskButton, view.returnToLayersButton, view.selectionPopup] {
            let frame = view.convert(control.bounds, from: control)
            XCTAssertTrue(frame.width > 0 && frame.height > 0)
            XCTAssertTrue(view.bounds.contains(frame))
        }

        // The button bar spans the width and reaches the bottom edge
        // (the view is not flipped: the bottom edge is minY).
        let bar = view.paletteButtonBar
        let barFrame = view.convert(bar.bounds, from: bar)
        XCTAssertEqual(barFrame.width, size.width, accuracy: 0.5)
        XCTAssertEqual(barFrame.minY, view.bounds.minY, accuracy: 0.5)

        // The channel list scrolls in the space the fixed controls leave.
        let scroll = descendant(of: view, as: NSScrollView.self)
        XCTAssertNotNil(scroll)
        let scrollFrame = view.convert(scroll!.bounds, from: scroll!)
        XCTAssertGreaterThanOrEqual(scrollFrame.height, 80)
        XCTAssertTrue(view.bounds.contains(scrollFrame))

        // Rows keep the Layers palette's height and fit inside the width.
        XCTAssertEqual(view.componentRows.count, 4)
        XCTAssertEqual(view.channelRows.count, 3)
        for row in view.channelRows {
            XCTAssertEqual(row.frame.height, ChannelsPaletteView.rowHeight, accuracy: 0.5)
            XCTAssertLessThanOrEqual(row.frame.width, size.width + 0.5)
        }

        // A long list grows its document past the scroll view's height,
        // so the overflow stays reachable by scrolling.
        view.update(.init(components: componentState(supported: rgbBits),
                          channels: (1...30).map { channel(Int32($0)) },
                          acceptsEdits: true))
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(view.channelRows.count, 30)
        XCTAssertGreaterThan(scroll!.documentView?.frame.height ?? 0, scrollFrame.height)

        // The rule shows with the component model and hides without it.
        let rule = descendant(of: view, as: ClassicRuleView.self)
        XCTAssertEqual(rule?.isHidden, false)
        view.update(.init(channels: [channel(1)], acceptsEdits: false))
        XCTAssertEqual(rule?.isHidden, true)
        XCTAssertTrue(view.componentRows.isEmpty)
    }
}
