import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class InkLevelsPanelTests: XCTestCase {
    func testResetRetriesFailedPreviewWithUnchangedSettings() {
        _ = NSApplication.shared
        var calls = 0
        var panel: InkLevelsPanel!
        let request = InkLevelsPixelPreview.Request(token: 1, settings: .init(),
            imageSize: CGSize(width: 100, height: 100), destination: .srgbFallback,
            proof: nil, viewport: CGRect(x: 0, y: 0, width: 100, height: 100), displayScale: 1)
        let preview = InkLevelsPixelPreview(render: { _, reply in
            calls += 1
            reply(.failure(ImageDocument.DocumentError.busy))
        }, changed: {}, failed: { panel.setPreviewState(current: false, error: $0.localizedDescription) })
        panel = InkLevelsPanel(inkName: "Cyan", changed: { _ in preview.update(request, retryFailure: true) },
                               apply: { _ in XCTFail("A failed preview cannot Apply") }, cancel: {})
        defer { panel.finish() }
        preview.update(request)
        XCTAssertEqual(calls, 1)
        panel.resetButton.performClick(nil)
        XCTAssertEqual(calls, 2, "Explicit Reset must retry even when its settings are unchanged")
        XCTAssertFalse(panel.applyButton.isEnabled)
        for _ in 0..<10 { preview.update(request) }
        XCTAssertEqual(calls, 2, "Normal redraws must not retry a failed render")
    }

    func testStatusChangesDoNotMoveTheControls() throws {
        _ = NSApplication.shared
        let panel = InkLevelsPanel(inkName: "Cyan", changed: { _ in }, apply: { _ in }, cancel: {})
        defer { panel.finish() }
        let window = try XCTUnwrap(panel.window)
        let size = window.frame.size
        panel.setPreviewState(current: true)
        XCTAssertEqual(window.frame.size, size)
        panel.setPreviewState(current: false, error: "The image changed after this preview began. Close Levels and try again.")
        XCTAssertEqual(window.frame.size, size)
    }

    func testInvalidDraftCannotApplyOldPreviewAndValidCorrectionCan() {
        _ = NSApplication.shared
        var changes: [EngineSession.InkLevelsSettings] = []
        var applied: [EngineSession.InkLevelsSettings] = []
        let panel = InkLevelsPanel(inkName: "Cyan", changed: { changes.append($0) },
                                   apply: { applied.append($0) }, cancel: {})
        defer { panel.finish() }
        panel.setPreviewState(current: true)
        panel.gammaField.stringValue = "2bad"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.gammaField))
        panel.setPreviewState(current: true) // A late reply cannot validate the draft.
        panel.applyButton.performClick(nil)
        XCTAssertTrue(applied.isEmpty)
        XCTAssertTrue(changes.isEmpty)
        XCTAssertFalse(panel.applyButton.isEnabled)
        panel.gammaField.stringValue = "2"
        panel.controlTextDidChange(.init(name: NSControl.textDidChangeNotification, object: panel.gammaField))
        XCTAssertEqual(changes.last?.value.gamma, 2)
        XCTAssertFalse(panel.applyButton.isEnabled)
        panel.setPreviewState(current: true)
        panel.applyButton.performClick(nil)
        XCTAssertEqual(applied.last?.value.gamma, 2)
        panel.applyButton.performClick(nil)
        XCTAssertEqual(applied.count, 1)
    }

    func testUnchangedDisplayRetainsExactSettingsAndRefusedApplyCanRetry() {
        _ = NSApplication.shared
        let precise = 0.123456789123
        var applied: [EngineSession.InkLevelsSettings] = []
        let settings = EngineSession.InkLevelsSettings(value: .init(lowInput: precise))
        let panel = InkLevelsPanel(inkName: "Cyan", settings: settings, changed: { _ in },
                                   apply: { applied.append($0) }, cancel: {})
        defer { panel.finish() }
        panel.setPreviewState(current: true)
        panel.applyButton.performClick(nil)
        XCTAssertEqual(applied.first?.value.lowInput, precise)
        panel.setApplying(false)
        panel.setPreviewState(current: true)
        panel.applyButton.performClick(nil)
        XCTAssertEqual(applied.count, 2)
    }

    func testCancelIsOnceOnlyAndProgrammaticFinishDoesNotCancel() {
        _ = NSApplication.shared
        var canceled = 0
        let panel = InkLevelsPanel(inkName: "Cyan", changed: { _ in }, apply: { _ in }, cancel: { canceled += 1 })
        panel.cancel()
        panel.cancel()
        panel.finish()
        XCTAssertEqual(canceled, 1)
        let finished = InkLevelsPanel(inkName: "Magenta", changed: { _ in }, apply: { _ in }, cancel: { canceled += 1 })
        finished.finish()
        finished.cancel()
        XCTAssertEqual(canceled, 1)
    }
}
