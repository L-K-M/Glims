import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class LabCurvesPanelTests: XCTestCase {
    private func makeAxis(_ role: EngineSession.LabAxisRole,
                          id: Int32 = 13,
                          selected: Bool = true,
                          name: String? = nil) -> EngineSession.LabAxis {
        EngineSession.LabAxis(id: id,
                              role: role,
                              isSelected: selected,
                              uuid: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!,
                              name: name ?? role.title)
    }

    func testPhysicalMappingForLightnessAndColorAxes() {
        _ = NSApplication.shared
        let lPanel = InkCurvesPanel(labAxis: makeAxis(.lightness),
                                    settings: .init(),
                                    changed: { _ in }, apply: { _ in }, cancel: {})
        defer { lPanel.finish() }
        XCTAssertEqual(lPanel.window?.title, "Lab Curves")
        XCTAssertEqual(lPanel.outputField.stringValue, "0")
        XCTAssertEqual(lPanel.inputField.stringValue, "0")

        lPanel.sampleIndexField.stringValue = "255"
        lPanel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: lPanel.sampleIndexField))
        XCTAssertEqual(lPanel.outputField.stringValue, "100")
        XCTAssertEqual(lPanel.inputField.stringValue, "100")

        let aPanel = InkCurvesPanel(labAxis: makeAxis(.a),
                                    settings: .init(),
                                    changed: { _ in }, apply: { _ in }, cancel: {})
        defer { aPanel.finish() }
        XCTAssertEqual(aPanel.outputField.stringValue, "-128")
        XCTAssertEqual(aPanel.inputField.stringValue, "-128")
        aPanel.sampleIndexField.stringValue = "255"
        aPanel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: aPanel.sampleIndexField))
        XCTAssertEqual(aPanel.outputField.stringValue, "127")
        XCTAssertEqual(aPanel.inputField.stringValue, "127")
    }

    func testInvalidPhysicalBoundsDoNotPublishChanges() {
        _ = NSApplication.shared
        var changes = 0
        let panel = InkCurvesPanel(labAxis: makeAxis(.lightness),
                                   settings: .init(),
                                   changed: { _ in changes += 1 },
                                   apply: { _ in },
                                   cancel: {})
        defer { panel.finish() }
        panel.setPreviewState(current: true)
        XCTAssertTrue(panel.applyButton.isEnabled)

        panel.outputField.stringValue = "101"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.outputField))
        panel.setPreviewState(current: true)
        XCTAssertFalse(panel.applyButton.isEnabled)
        XCTAssertEqual(changes, 0)

        panel.outputField.stringValue = "-1"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.outputField))
        XCTAssertFalse(panel.applyButton.isEnabled)
        XCTAssertEqual(changes, 0)

        panel.outputField.stringValue = "50"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.outputField))
        XCTAssertEqual(changes, 1)
    }

    func testIdentityAndUnchangedDraftPreservation() {
        _ = NSApplication.shared
        var samples = EngineSession.LabCurvesSettings().samples
        samples[10] = 0.123456789012345
        var changes: [EngineSession.LabCurvesSettings] = []
        let panel = InkCurvesPanel(labAxis: makeAxis(.a),
                                   settings: .init(samples: samples),
                                   changed: { changes.append($0) },
                                   apply: { _ in },
                                   cancel: {})
        defer { panel.finish() }
        panel.setPreviewState(current: true)

        panel.sampleIndexField.stringValue = "10"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.sampleIndexField))
        XCTAssertTrue(changes.isEmpty, "Browsing index with unchanged formatted output must not quantize or change samples")
        XCTAssertEqual(panel.graph.state.samples[10], samples[10])
        XCTAssertEqual(panel.graph.state.samples, samples)
        XCTAssertTrue(panel.applyButton.isEnabled)

        panel.resetButton.performClick(nil)
        XCTAssertEqual(changes.last?.samples, EngineSession.LabCurvesSettings().samples)
    }

    func testSmoothEditingUsesPhysicalCoordinates() {
        _ = NSApplication.shared
        var changes: [EngineSession.LabCurvesSettings] = []
        let panel = InkCurvesPanel(labAxis: makeAxis(.a),
                                   settings: .init(),
                                   changed: { changes.append($0) },
                                   apply: { _ in },
                                   cancel: {})
        defer { panel.finish() }
        panel.modePopup.selectItem(at: 0)
        NSApp.sendAction(panel.modePopup.action!, to: panel.modePopup.target, from: panel.modePopup)
        XCTAssertEqual(panel.graph.state.kind, .smooth)

        panel.sampleIndexField.stringValue = "1"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.sampleIndexField))

        // For smooth identity 9-point curve, index 1 is x=32, physical a* maps to -96
        panel.outputField.stringValue = "-64"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.outputField))

        XCTAssertFalse(changes.isEmpty)
        let y = panel.graph.state.points[1].y
        XCTAssertEqual(y, 0.25098039215686274, accuracy: 1e-12)
        XCTAssertEqual(panel.outputField.stringValue, "-64")
    }

    func testCancelSemanticsInvokeOnce() {
        _ = NSApplication.shared
        var canceled = 0
        let panel = InkCurvesPanel(labAxis: makeAxis(.b),
                                   settings: .init(),
                                   changed: { _ in },
                                   apply: { _ in },
                                   cancel: { canceled += 1 })
        panel.cancel()
        panel.cancel()
        panel.finish()
        XCTAssertEqual(canceled, 1)
        XCTAssertFalse(panel.window?.isVisible ?? true)
    }
}
