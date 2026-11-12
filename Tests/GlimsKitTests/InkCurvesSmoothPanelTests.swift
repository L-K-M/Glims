import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class InkCurvesSmoothPanelTests: XCTestCase {
    final class Probe {
        var changes: [EngineSession.InkCurvesSettings] = []
        var applied: [EngineSession.InkCurvesSettings] = []
    }
    private func panel(_ probe: Probe) -> InkCurvesPanel {
        _ = NSApplication.shared
        return InkCurvesPanel(inkName: "Cyan", changed: { probe.changes.append($0) },
                              apply: { probe.applied.append($0) }, cancel: {})
    }
    private func select(_ popup: NSPopUpButton, _ index: Int) {
        popup.selectItem(at: index)
        NSApp.sendAction(popup.action!, to: popup.target, from: popup)
    }
    private func edit(_ field: NSTextField, _ text: String, _ panel: InkCurvesPanel) {
        field.stringValue = text
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: field))
    }
    private func key(_ code: UInt16, _ panel: InkCurvesPanel) {
        panel.graph.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: panel.window!.windowNumber,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: code)!)
    }
    private func stage(_ points: [EngineSession.CurvePoint], _ panel: InkCurvesPanel) {
        XCTAssertEqual(panel.graph.onBeginEdit?(), true)
        panel.graph.onStateEdit?(.smooth, points, panel.graph.state.samples)
        panel.graph.onEndInteraction?(0)
    }

    func testSmoothToFreehandPreservesExactSamplesAndCurrentPreview() {
        let probe = Probe(); let p = panel(probe)
        defer { p.finish() }
        select(p.modePopup, 0)
        XCTAssertEqual(p.graph.state.points.count, 9)
        edit(p.outputField, "0.375", p)
        let samples = p.graph.state.samples
        p.setPreviewState(current: true)
        probe.changes.removeAll()
        select(p.modePopup, 1)
        XCTAssertEqual(p.graph.state.samples, samples)
        XCTAssertTrue(p.applyButton.isEnabled)
        XCTAssertTrue(probe.changes.isEmpty)
    }

    func testResetDiscardsInvalidDraftAndRestoresCanonicalSmoothIdentity() {
        let probe = Probe(); let p = panel(probe)
        defer { p.finish() }
        select(p.modePopup, 0)
        edit(p.outputField, "invalid", p)
        p.resetButton.performClick(nil)
        XCTAssertEqual(p.graph.state.kind, .smooth)
        XCTAssertEqual(p.graph.state.points, [.init(x: 0, y: 0), .init(x: 1, y: 1)])
        XCTAssertEqual(p.graph.state.samples, EngineSession.InkCurvesSettings().samples)
        p.setPreviewState(current: true)
        XCTAssertTrue(p.applyButton.isEnabled)
        XCTAssertTrue(probe.applied.isEmpty)
    }

    func testKeyboardEditEndsOwnershipAndNoOpKeepsPreview() {
        let probe = Probe(); let p = panel(probe)
        defer { p.finish() }
        select(p.modePopup, 0); p.resetButton.performClick(nil)
        p.setPreviewState(current: true)
        probe.changes.removeAll()
        key(125, p) // first point is already at zero
        XCTAssertTrue(probe.changes.isEmpty)
        XCTAssertTrue(p.applyButton.isEnabled)
        key(126, p)
        XCTAssertEqual(probe.changes.count, 1)
        XCTAssertEqual(p.graph.state.points.first?.y, 1.0 / 255)
        p.setPreviewState(current: true)
        XCTAssertTrue(p.modePopup.isEnabled)
        XCTAssertTrue(p.applyButton.isEnabled)
    }

    func testDeletingFinalPointRetainsSamplesAndAllowsApply() {
        let probe = Probe(); let p = panel(probe)
        defer { p.finish() }
        select(p.modePopup, 0); p.resetButton.performClick(nil)
        key(51, p)
        let last = p.graph.state.samples
        p.setPreviewState(current: true); probe.changes.removeAll()
        key(51, p)
        XCTAssertTrue(p.graph.state.points.isEmpty)
        XCTAssertEqual(p.graph.state.samples, last)
        XCTAssertTrue(probe.changes.isEmpty)
        XCTAssertFalse(p.inputField.isEnabled)
        XCTAssertTrue(p.applyButton.isEnabled)
        p.applyButton.performClick(nil)
        XCTAssertEqual(probe.applied.last?.samples, last)
    }

    func testPointSelectionAndUnchangedEndEditingRetainExactValues() {
        let probe = Probe(); let p = panel(probe)
        defer { p.finish() }
        select(p.modePopup, 0)
        edit(p.sampleIndexField, "1", p)
        let original = p.graph.state
        p.setPreviewState(current: true); probe.changes.removeAll()
        p.controlTextDidEndEditing(.init(name: NSControl.textDidEndEditingNotification, object: p.inputField))
        XCTAssertEqual(p.graph.state.points, original.points)
        XCTAssertEqual(p.graph.state.samples, original.samples)
        edit(p.sampleIndexField, "2", p)
        XCTAssertEqual(p.graph.state.points, original.points)
        XCTAssertEqual(p.graph.state.samples, original.samples)
        XCTAssertTrue(probe.changes.isEmpty)
        XCTAssertTrue(p.applyButton.isEnabled)
    }

    func testInvalidPointDraftCannotBeDiscardedByChangingIndex() {
        let probe = Probe(); let p = panel(probe)
        defer { p.finish() }
        select(p.modePopup, 0)
        let accepted = p.graph.state
        edit(p.outputField, "invalid", p)
        edit(p.sampleIndexField, "1", p)
        p.setPreviewState(current: true)
        XCTAssertFalse(p.applyButton.isEnabled)
        XCTAssertEqual(p.outputField.stringValue, "invalid")
        XCTAssertEqual(p.graph.state, accepted)
    }

    func testModeAndTypeActionsInspectUnreportedDraft() {
        let probe = Probe(); let p = panel(probe)
        defer { p.finish() }
        select(p.modePopup, 0)
        let accepted = p.graph.state
        p.outputField.stringValue = "invalid"
        select(p.modePopup, 1)
        XCTAssertEqual(p.modePopup.indexOfSelectedItem, 0)
        XCTAssertEqual(p.outputField.stringValue, "invalid")
        XCTAssertEqual(p.graph.state, accepted)
        select(p.pointTypePopup, 1)
        XCTAssertEqual(p.graph.state, accepted)
        XCTAssertEqual(p.outputField.stringValue, "invalid")
    }

    func testPointTypeUsesRequestedValueAndUnchangedSamplesKeepPreview() {
        let probe = Probe(); let p = panel(probe)
        defer { p.finish() }
        select(p.modePopup, 0)
        stage([.init(x: 0, y: 0), .init(x: 1, y: 0)], p)
        p.setPreviewState(current: true); probe.changes.removeAll()
        select(p.pointTypePopup, 1)
        XCTAssertEqual(p.graph.state.points[0].kind, .corner)
        XCTAssertEqual(p.graph.state.samples, Array(repeating: 0.0, count: 256))
        XCTAssertTrue(probe.changes.isEmpty)
        XCTAssertTrue(p.applyButton.isEnabled)
    }

    func testPointLimitRefusesAndRestoresLastAcceptedGraph() {
        let probe = Probe(); let p = panel(probe)
        defer { p.finish() }
        select(p.modePopup, 0)
        let points = (0..<256).map { EngineSession.CurvePoint(x: Double($0) / 255, y: 0.5) }
        stage(points, p)
        let accepted = p.graph.state
        probe.changes.removeAll()
        var tooMany = points; tooMany.append(.init(x: 1, y: 1))
        stage(tooMany, p)
        XCTAssertEqual(p.graph.state, accepted)
        XCTAssertEqual(p.graph.state.points.count, 256)
        XCTAssertTrue(probe.changes.isEmpty)
        p.resetButton.performClick(nil)
        XCTAssertEqual(p.graph.state.points.count, 2)
    }
    func testCancelledSmoothPointerDraftRestoresStateAndReleasesControls() throws {
        let probe = Probe(); let p = panel(probe)
        defer { p.finish() }
        select(p.modePopup, 0); p.resetButton.performClick(nil)
        let window = try XCTUnwrap(p.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let graph = p.graph
        func mouse(_ type: NSEvent.EventType, x: Double, y: Double, clicks: Int = 1) throws {
            let plot = graph.bounds.insetBy(dx: 12, dy: 12)
            let point = graph.convert(NSPoint(x: plot.minX + x * plot.width,
                                             y: plot.minY + y * plot.height), to: nil)
            let event = try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
            switch type {
            case .leftMouseDown: graph.mouseDown(with: event)
            case .leftMouseDragged: graph.mouseDragged(with: event)
            default: graph.mouseUp(with: event)
            }
        }
        p.setPreviewState(current: true); probe.changes.removeAll()
        let original = graph.state
        try mouse(.leftMouseDown, x: 0.4, y: 0.6, clicks: 2)
        try mouse(.leftMouseDragged, x: 0.5, y: 0.75)
        XCTAssertTrue(graph.isInteracting)
        XCTAssertFalse(p.applyButton.isEnabled)
        key(53, p)
        XCTAssertFalse(graph.isInteracting)
        XCTAssertEqual(graph.state, original)
        XCTAssertTrue(probe.changes.isEmpty)
        XCTAssertTrue(p.applyButton.isEnabled)

        try mouse(.leftMouseDown, x: 0.4, y: 0.6, clicks: 2)
        XCTAssertTrue(graph.isInteracting)
        _ = graph.resignFirstResponder()
        XCTAssertFalse(graph.isInteracting)
        XCTAssertEqual(graph.state, original)
        XCTAssertTrue(probe.changes.isEmpty)
        XCTAssertTrue(p.applyButton.isEnabled)

        try mouse(.leftMouseDown, x: 0.4, y: 0.6, clicks: 2)
        try mouse(.leftMouseDragged, x: 0.5, y: 0.75)
        try mouse(.leftMouseUp, x: 0.5, y: 0.75)
        XCTAssertEqual(probe.changes.count, 1)
        XCTAssertEqual(graph.state.points.count, 3)
        XCTAssertEqual(graph.state.points[1], .init(x: 0.5, y: 0.75))
        XCTAssertFalse(p.applyButton.isEnabled)
        p.setPreviewState(current: true)
        XCTAssertTrue(p.applyButton.isEnabled)
    }

}
