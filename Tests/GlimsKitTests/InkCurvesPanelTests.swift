import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class InkCurvesPanelTests: XCTestCase {
    func testInvalidInputBlocksApplyAndCorrectionPublishesCorrectIndex() {
        _ = NSApplication.shared
        var samples = EngineSession.InkCurvesSettings().samples
        samples[10] = 0.123456789012345
        samples[20] = 0.75
        var changes: [EngineSession.InkCurvesSettings] = []
        var applied: [EngineSession.InkCurvesSettings] = []
        let panel = InkCurvesPanel(inkName: "Cyan",
                                   settings: .init(samples: samples),
                                   changed: { changes.append($0) },
                                   apply: { applied.append($0) },
                                   cancel: {})
        defer { panel.finish() }

        panel.setPreviewState(current: true)
        XCTAssertTrue(panel.applyButton.isEnabled)

        panel.sampleIndexField.stringValue = "10"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.sampleIndexField))
        panel.outputField.stringValue = "2"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.outputField))
        panel.setPreviewState(current: true)

        XCTAssertFalse(panel.applyButton.isEnabled)
        panel.applyButton.performClick(nil)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(changes.isEmpty)

        panel.outputField.stringValue = "0.5"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.outputField))

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].samples[10], 0.5)
        XCTAssertEqual(changes[0].samples[20], 0.75, "Other samples must keep their precise values")

        XCTAssertFalse(panel.applyButton.isEnabled, "A settings change requires a current preview")
        panel.setPreviewState(current: true)
        XCTAssertTrue(panel.applyButton.isEnabled)
        panel.applyButton.performClick(nil)
        XCTAssertEqual(applied.count, 1)
        XCTAssertEqual(applied[0].samples[10], 0.5)
        XCTAssertEqual(applied[0].samples[20], 0.75)
    }

    func testResetPublishesCanonicalIdentity() {
        _ = NSApplication.shared
        var samples = EngineSession.InkCurvesSettings().samples
        samples[1] = 0.9
        var changes: [EngineSession.InkCurvesSettings] = []
        let panel = InkCurvesPanel(inkName: "Magenta",
                                   settings: .init(samples: samples),
                                   changed: { changes.append($0) },
                                   apply: { _ in },
                                   cancel: {})
        defer { panel.finish() }

        panel.resetButton.performClick(nil)

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].samples, EngineSession.InkCurvesSettings().samples)
        XCTAssertFalse(panel.applyButton.isEnabled)
        panel.setPreviewState(current: true)
        XCTAssertTrue(panel.applyButton.isEnabled)
    }

    func testStaleOrErrorPreviewDisablesApply() {
        _ = NSApplication.shared
        let panel = InkCurvesPanel(inkName: "Yellow", changed: { _ in }, apply: { _ in }, cancel: {})
        defer { panel.finish() }

        panel.setPreviewState(current: true)
        XCTAssertTrue(panel.applyButton.isEnabled)

        panel.setPreviewState(current: false)
        XCTAssertFalse(panel.applyButton.isEnabled)

        panel.setPreviewState(current: true)
        XCTAssertTrue(panel.applyButton.isEnabled)

        panel.setPreviewState(current: true, error: "Preview failed")
        XCTAssertFalse(panel.applyButton.isEnabled)

        panel.setPreviewState(current: true, error: nil)
        XCTAssertTrue(panel.applyButton.isEnabled)
    }

    func testApplyingGatesCloseAndApply() {
        _ = NSApplication.shared
        let panel = InkCurvesPanel(inkName: "Black", changed: { _ in }, apply: { _ in }, cancel: {})
        defer { panel.finish() }

        panel.setPreviewState(current: true)
        XCTAssertTrue(panel.applyButton.isEnabled)

        panel.setApplying(true)
        XCTAssertFalse(panel.applyButton.isEnabled)
        XCTAssertFalse(panel.cancelButton.isEnabled)
        XCTAssertFalse(panel.resetButton.isEnabled)
        XCTAssertFalse(panel.sampleIndexField.isEnabled)
        XCTAssertFalse(panel.outputField.isEnabled)
        if let window = panel.window {
            XCTAssertFalse(panel.windowShouldClose(window))
            XCTAssertFalse(window.standardWindowButton(.closeButton)?.isEnabled ?? true)
        }

        panel.setApplying(false)
        panel.setPreviewState(current: true)
        XCTAssertTrue(panel.applyButton.isEnabled)
        XCTAssertTrue(panel.cancelButton.isEnabled)
    }

    func testCancelAndFinishAreExactlyOnce() {
        _ = NSApplication.shared
        var canceled = 0
        let panel = InkCurvesPanel(inkName: "Cyan", changed: { _ in }, apply: { _ in }, cancel: { canceled += 1 })
        panel.cancel()
        panel.cancel()
        panel.finish()
        XCTAssertEqual(canceled, 1)

        let finished = InkCurvesPanel(inkName: "Magenta", changed: { _ in }, apply: { _ in }, cancel: { canceled += 1 })
        finished.finish()
        finished.cancel()
        XCTAssertEqual(canceled, 1)
    }

    func testGraphCallbackPublishesActualSampleArray() {
        _ = NSApplication.shared
        var changes: [EngineSession.InkCurvesSettings] = []
        let panel = InkCurvesPanel(inkName: "Cyan", changed: { changes.append($0) }, apply: { _ in }, cancel: {})
        defer { panel.finish() }

        var expected = EngineSession.InkCurvesSettings().samples
        expected[42] = 0.25
        expected[43] = 0.75

        panel.graph.state = EngineSession.CurveState(kind: .free, points: [], samples: expected)
        _ = panel.graph.onBeginEdit?()
        panel.graph.onStateEdit?(EngineSession.CurveKind.free, [], expected)
        panel.graph.onEndInteraction?(nil)

        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].samples, expected)
        XCTAssertEqual(changes[0].samples[42], 0.25)
        XCTAssertEqual(changes[0].samples[43], 0.75)

        panel.setPreviewState(current: true)
        XCTAssertTrue(panel.applyButton.isEnabled)
    }
    func testChangingOnlySampleIndexPreservesTheWholeCurve() {
        var samples = EngineSession.InkCurvesSettings().samples
        samples[10] = 0.123456789012345
        var changes: [EngineSession.InkCurvesSettings] = []
        var applied: [EngineSession.InkCurvesSettings] = []
        let panel = InkCurvesPanel(inkName: "Cyan", settings: .init(samples: samples),
            changed: { changes.append($0) }, apply: { applied.append($0) }, cancel: {})
        defer { panel.finish() }
        panel.setPreviewState(current: true)
        panel.sampleIndexField.stringValue = "10"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.sampleIndexField))
        XCTAssertTrue(changes.isEmpty, "Browsing a sample must not overwrite it with the previous sample's displayed output")
        XCTAssertEqual(panel.graph.state.samples, samples)
        XCTAssertTrue(panel.applyButton.isEnabled, "An unchanged curve keeps its current preview")
        panel.applyButton.performClick(nil)
        XCTAssertEqual(applied.first?.samples, samples)
    }

    func testHugeFiniteIndexRefusesWithoutIntegerConversionTrap() {
        var changes = 0
        let panel = InkCurvesPanel(inkName: "Cyan", changed: { _ in changes += 1 }, apply: { _ in XCTFail() }, cancel: {})
        defer { panel.finish() }
        for text in ["1e300", "-1e300", "256", "-1", "NaN", "Infinity"] {
            panel.sampleIndexField.stringValue = text
            panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.sampleIndexField))
            panel.setPreviewState(current: true)
            XCTAssertFalse(panel.applyButton.isEnabled)
        }
        XCTAssertEqual(changes, 0)
    }

    func testInvalidNumericEntryPreventsGraphGestureAndStatusDoesNotResizePanel() {
        var changes = 0
        let panel = InkCurvesPanel(inkName: "Cyan", changed: { _ in changes += 1 }, apply: { _ in }, cancel: {})
        defer { panel.finish() }
        let initialFrame = panel.window?.frame
        panel.outputField.stringValue = "invalid"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.outputField))
        XCTAssertEqual(panel.graph.onBeginEdit?(), false)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(panel.window?.frame, initialFrame)
        panel.setPreviewState(current: false, error: "The original selected ink has changed. Cancel and open Curves again.")
        XCTAssertEqual(panel.window?.frame, initialFrame)
    }

}
