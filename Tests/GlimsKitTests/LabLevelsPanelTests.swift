import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class LabLevelsPanelTests: XCTestCase {
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

    private func numericField(_ title: String, in panel: InkLevelsPanel) throws -> NSTextField {
        let fields = [panel.lowInputField, panel.highInputField, panel.gammaField,
                      panel.lowOutputField, panel.highOutputField]
        let match = fields.first { $0.accessibilityLabel() == title }
        return try XCTUnwrap(match, "Missing numeric field \(title)")
    }

    func testAllThreePhysicalRolesShowDomainEndsAndTitles() throws {
        _ = NSApplication.shared

        let lPanel = InkLevelsPanel(labAxis: makeAxis(.lightness),
                                    settings: .init(),
                                    changed: { _ in }, apply: { _ in }, cancel: {})
        defer { lPanel.finish() }
        XCTAssertEqual(lPanel.window?.title, "Lab Levels")
        XCTAssertEqual(try numericField("Low input", in: lPanel).stringValue, "0")
        XCTAssertEqual(try numericField("High input", in: lPanel).stringValue, "100")

        let aPanel = InkLevelsPanel(labAxis: makeAxis(.a),
                                    settings: .init(),
                                    changed: { _ in }, apply: { _ in }, cancel: {})
        defer { aPanel.finish() }
        XCTAssertEqual(aPanel.window?.title, "Lab Levels")
        XCTAssertEqual(try numericField("Low input", in: aPanel).stringValue, "-128")
        XCTAssertEqual(try numericField("High input", in: aPanel).stringValue, "127")

        let bPanel = InkLevelsPanel(labAxis: makeAxis(.b),
                                    settings: .init(),
                                    changed: { _ in }, apply: { _ in }, cancel: {})
        defer { bPanel.finish() }
        XCTAssertEqual(bPanel.window?.title, "Lab Levels")
        XCTAssertEqual(try numericField("Low output", in: bPanel).stringValue, "-128")
        XCTAssertEqual(try numericField("High output", in: bPanel).stringValue, "127")
    }

    func testEditedPhysicalEndpointsNormalizeAndGammaAndClampsAreIndependent() throws {
        _ = NSApplication.shared
        var changed: [EngineSession.LabLevelsSettings] = []
        let panel = InkLevelsPanel(labAxis: makeAxis(.a),
                                   settings: .init(),
                                   changed: { changed.append($0) },
                                   apply: { _ in },
                                   cancel: {})
        defer { panel.finish() }

        panel.lowInputField.stringValue = "-64"
        panel.highInputField.stringValue = "64"
        panel.gammaField.stringValue = "2"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.gammaField))

        let first = try XCTUnwrap(changed.last)
        XCTAssertEqual(first.value.lowInput, 64.0 / 255.0, accuracy: 1e-15)
        XCTAssertEqual(first.value.highInput, 192.0 / 255.0, accuracy: 1e-15)
        XCTAssertEqual(first.value.gamma, 2, accuracy: 1e-12)

        panel.clampInputButton.performClick(nil)
        let second = try XCTUnwrap(changed.last)
        XCTAssertTrue(second.clampInput)
        XCTAssertFalse(second.clampOutput)

        panel.clampOutputButton.performClick(nil)
        let third = try XCTUnwrap(changed.last)
        XCTAssertTrue(third.clampInput)
        XCTAssertTrue(third.clampOutput)
        XCTAssertEqual(third.value.gamma, 2, accuracy: 1e-12)

        panel.clampInputButton.performClick(nil)
        let fourth = try XCTUnwrap(changed.last)
        XCTAssertFalse(fourth.clampInput)
        XCTAssertTrue(fourth.clampOutput)

        var lightnessChanges: [EngineSession.LabLevelsSettings] = []
        let lightness = InkLevelsPanel(labAxis: makeAxis(.lightness),
                                       changed: { lightnessChanges.append($0) }, apply: { _ in }, cancel: {})
        defer { lightness.finish() }
        lightness.lowInputField.stringValue = "25"
        lightness.highOutputField.stringValue = "75"
        lightness.controlTextDidChange(.init(name: NSControl.textDidChangeNotification,
                                             object: lightness.lowInputField))
        let lightnessSettings = try XCTUnwrap(lightnessChanges.last)
        XCTAssertEqual(lightnessSettings.value.lowInput, 0.25)
        XCTAssertEqual(lightnessSettings.value.highOutput, 0.75)
        XCTAssertEqual(lightnessSettings.value.gamma, 1)
    }

    func testUntouchedPreciseNormalizedValuesPreservedThroughRoundedDisplayAndApply() throws {
        _ = NSApplication.shared
        var changed: [EngineSession.LabLevelsSettings] = []
        var applied: [EngineSession.LabLevelsSettings] = []
        let settings = EngineSession.LabLevelsSettings(
            value: .init(lowInput: 1e-15, highInput: 0.876543210987,
                         gamma: 1.23456789123, lowOutput: 0.0123456789123, highOutput: 0.9876543210987),
            clampInput: true, clampOutput: false
        )
        let panel = InkLevelsPanel(labAxis: makeAxis(.a),
                                   settings: settings,
                                   changed: { changed.append($0) },
                                   apply: { applied.append($0) },
                                   cancel: {})
        defer { panel.finish() }
        panel.setPreviewState(current: true)

        XCTAssertEqual(panel.lowInputField.stringValue, "-128",
                       "The tiny normalized endpoint is intentionally hidden by physical display rounding")

        panel.applyButton.performClick(nil)
        XCTAssertEqual(try XCTUnwrap(applied.first), settings,
                       "Untouched rounded physical text must retain every exact normalized value")
        XCTAssertTrue(changed.isEmpty)

        // A refused Apply can leave the same panel open for another edit.
        panel.setApplying(false)
        panel.gammaField.stringValue = "2"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.gammaField))
        XCTAssertEqual(changed.count, 1)
        let changedSettings = try XCTUnwrap(changed.last)
        var expected = settings
        expected.value.gamma = 2
        XCTAssertEqual(changedSettings, expected,
                       "Editing gamma must preserve all four untouched endpoints and clamp flags")

        panel.setPreviewState(current: true)
        panel.applyButton.performClick(nil)
        let appliedSettings = try XCTUnwrap(applied.last)
        XCTAssertEqual(appliedSettings, expected)
        XCTAssertEqual(applied.count, 2)
    }

    func testInvalidPhysicalOrGammaDraftDisablesApplyAndLatePreviewCannotApplyOldSettings() {
        _ = NSApplication.shared
        var changed: [EngineSession.LabLevelsSettings] = []
        var applied: [EngineSession.LabLevelsSettings] = []
        let panel = InkLevelsPanel(labAxis: makeAxis(.b),
                                   settings: .init(),
                                   changed: { changed.append($0) },
                                   apply: { applied.append($0) },
                                   cancel: {})
        defer { panel.finish() }
        panel.setPreviewState(current: true)
        XCTAssertTrue(panel.applyButton.isEnabled)

        panel.gammaField.stringValue = "11"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.gammaField))
        panel.setPreviewState(current: true)
        panel.applyButton.performClick(nil)
        XCTAssertTrue(changed.isEmpty)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertFalse(panel.applyButton.isEnabled)

        panel.gammaField.stringValue = "2"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.gammaField))
        XCTAssertEqual(changed.last?.value.gamma, 2)
        XCTAssertFalse(panel.applyButton.isEnabled, "Valid correction requires a current preview before Apply")
        panel.setPreviewState(current: true)
        XCTAssertTrue(panel.applyButton.isEnabled)
        panel.applyButton.performClick(nil)
        XCTAssertEqual(applied.last?.value.gamma, 2)

        let aPanel = InkLevelsPanel(labAxis: makeAxis(.a),
                                    settings: .init(),
                                    changed: { _ in },
                                    apply: { _ in XCTFail("Invalid physical draft must not apply") },
                                    cancel: {})
        defer { aPanel.finish() }
        aPanel.setPreviewState(current: true)
        aPanel.lowInputField.stringValue = "-129"
        aPanel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: aPanel.lowInputField))
        aPanel.setPreviewState(current: true)
        XCTAssertFalse(aPanel.applyButton.isEnabled)
        aPanel.applyButton.performClick(nil)
    }

    func testCancelIsOnceOnlyAndProgrammaticFinishDoesNotCancel() {
        _ = NSApplication.shared
        var canceled = 0
        let panel = InkLevelsPanel(labAxis: makeAxis(.lightness),
                                   settings: .init(),
                                   changed: { _ in },
                                   apply: { _ in },
                                   cancel: { canceled += 1 })
        panel.cancel()
        panel.cancel()
        panel.finish()
        XCTAssertEqual(canceled, 1)

        let finished = InkLevelsPanel(labAxis: makeAxis(.a),
                                      settings: .init(),
                                      changed: { _ in },
                                      apply: { _ in },
                                      cancel: { canceled += 1 })
        finished.finish()
        finished.cancel()
        XCTAssertEqual(canceled, 1)
    }
}
