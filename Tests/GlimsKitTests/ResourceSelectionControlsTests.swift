import AppKit
import XCTest
@testable import GlimsKit

/// Pure input/menu tests for Edit ▸ Create Resource ▸ Brush/Pattern from
/// Selection…: the name byte/control rules, the spacing rules per kind,
/// cached selection admission (no selection, soft actual selection bounds,
/// oversized), the cached menu gate (busy/closing/saving/preview/plug-in)
/// and the sheet's phase machine (busy gating, closing, pending admission).
final class ResourceSelectionControlsTests: XCTestCase {
    private typealias Validation = ResourceSelectionFormValidation

    private func rejection(_ result: Result<String, Validation.Rejection>) -> String? {
        if case .failure(let rejection) = result { return rejection.message }
        return nil
    }

    // MARK: Name

    func testValidNamesAreAccepted() {
        for name in ["a", "Brush from Selection", "山 山", String(repeating: "a", count: 255)] {
            guard case .success = Validation.validateName(name) else {
                return XCTFail("'\(name.prefix(20))' must be accepted")
            }
        }
    }

    func testEmptyNulAndControlNamesAreRejected() {
        XCTAssertNotNil(rejection(Validation.validateName("")))
        XCTAssertNotNil(rejection(Validation.validateName("abc\0def")))
        for name in ["a\nb", "a\tb", "\u{01}", "\u{7F}", "\u{85}"] {
            XCTAssertNotNil(rejection(Validation.validateName(name)), "control name must be rejected")
        }
    }

    func testNameByteLimitCountsUTF8() {
        // "é" is 2 UTF-8 bytes: 127 fit in 254, 128 (256 bytes) do not.
        guard case .success = Validation.validateName(String(repeating: "é", count: 127)) else {
            return XCTFail("254 bytes must pass")
        }
        XCTAssertNotNil(rejection(Validation.validateName(String(repeating: "é", count: 128))))
        XCTAssertNotNil(rejection(Validation.validateName(String(repeating: "a", count: 256))))
    }

    // MARK: Spacing

    func testBrushSpacingBounds() {
        guard case .success(let low) = Validation.validateSpacing("1", kind: .brush),
              case .success(let high) = Validation.validateSpacing("1000", kind: .brush) else {
            return XCTFail("1 and 1000 must pass")
        }
        XCTAssertEqual(low, 1)
        XCTAssertEqual(high, 1000)
        for text in ["0", "1001", "-1", "12.5", "", " 12", "1e3", "abc"] {
            if case .success = Validation.validateSpacing(text, kind: .brush) {
                XCTFail("brush spacing '\(text)' must be rejected")
            }
        }
    }

    func testPatternTakesNoSpacingAndGradientIsUnsupported() {
        guard case .success(let value) = Validation.validateSpacing("", kind: .pattern) else {
            return XCTFail("a pattern always validates")
        }
        XCTAssertEqual(value, 0, "patterns take brush spacing 0")
        if case .success = Validation.validateSpacing("5", kind: .gradient) {
            XCTFail("gradients cannot be created from pixels")
        }
    }

    // MARK: Selection admission

    func testNoSelectionIsRefused() {
        guard case .failure(let rejection) = Validation.admission(bounds: nil) else {
            return XCTFail("nil bounds must be refused")
        }
        XCTAssertTrue(rejection.message.contains("no selection"))
        if case .success = Validation.admission(bounds: .zero) {
            XCTFail("an empty bound must be refused")
        }
    }

    func testSoftActualSelectionBoundsAreAdmitted() {
        // A soft selection below the ants threshold still has root-mask
        // bounds; admission reads bounds, never the outline.
        guard case .success(let bounds) = Validation.admission(bounds: CGRect(x: 4, y: 4, width: 8, height: 8)) else {
            return XCTFail("an 8x8 bound must pass")
        }
        XCTAssertEqual(bounds.width, 8)
    }

    func testOversizedSelectionIsRefusedBeforeAllocation() {
        if case .success = Validation.admission(bounds: CGRect(x: 0, y: 0, width: 10_001, height: 8)) {
            XCTFail("10001 px per side must be refused")
        }
        if case .success = Validation.admission(bounds: CGRect(x: 0, y: 0, width: 8, height: 20_000)) {
            XCTFail("20000 px per side must be refused")
        }
        guard case .success = Validation.admission(bounds: CGRect(x: 0, y: 0, width: 10_000, height: 10_000)) else {
            return XCTFail("exactly 10000 px per side is within the cap")
        }
        XCTAssertNotNil(Validation.oversizedReason(CGRect(x: 0, y: 0, width: 10_001, height: 1)))
        XCTAssertNil(Validation.oversizedReason(CGRect(x: 0, y: 0, width: 10_000, height: 1)))
    }

    // MARK: Cached menu gate

    private func gate(activity: String? = nil, plugIn: String? = nil, closing: Bool = false,
                      saving: Bool = false, clipboard: Bool = false, preview: Bool = false,
                      bounds: CGRect? = CGRect(x: 0, y: 0, width: 8, height: 8)) -> String? {
        Validation.menuRefusal(engineActivity: activity, plugInLabel: plugIn, isClosing: closing,
                               isSavingForClose: saving, isTransferringClipboard: clipboard,
                               previewOpen: preview, selectionBounds: bounds, kind: .brush)
    }

    func testMenuGateReasons() {
        XCTAssertEqual(gate(activity: "Saving"), "Saving… Wait for it to finish before creating a brush.")
        XCTAssertTrue(gate(plugIn: "Gaussian Blur")?.contains("Finish or cancel") == true)
        XCTAssertEqual(gate(closing: true), ImageDocument.DocumentError.closed.localizedDescription)
        XCTAssertEqual(gate(saving: true), ImageDocument.DocumentError.busy.localizedDescription)
        XCTAssertEqual(gate(clipboard: true), ImageDocument.DocumentError.busy.localizedDescription)
        XCTAssertTrue(gate(preview: true)?.contains("filter preview") == true)
        XCTAssertTrue(gate(bounds: nil)?.contains("no selection") == true)
        XCTAssertTrue(gate(bounds: CGRect(x: 0, y: 0, width: 10_001, height: 1))?.contains("10000") == true)
        XCTAssertNil(gate(), "all clear admits")
    }

    // MARK: Sheet phase machine

    func testSheetPhaseTransitions() {
        typealias Phase = Validation.Phase
        XCTAssertEqual(Validation.applyTransition(.editing, locallyValid: true), .accepting)
        XCTAssertEqual(Validation.applyTransition(.editing, locallyValid: false), .editing)
        XCTAssertEqual(Validation.applyTransition(.accepting, locallyValid: true), .accepting,
                       "a reentrant Apply cannot start a second write")
        XCTAssertEqual(Validation.completionTransition(.accepting, success: true), .closed)
        XCTAssertEqual(Validation.completionTransition(.accepting, success: false), .editing,
                       "a failure returns to editing with the draft preserved")
        XCTAssertEqual(Validation.completionTransition(.editing, success: true), .editing,
                       "a stale completion is ignored")
        XCTAssertTrue(Validation.cancelAllowed(.editing))
        XCTAssertFalse(Validation.cancelAllowed(.accepting), "Cancel is gated while an accepted write is active")
        XCTAssertFalse(Validation.cancelAllowed(.closed))
    }

    // MARK: Menu structure

    @MainActor
    func testEditMenuListsCreateResourceWithoutShortcuts() {
        let menu = MainMenu.make()
        let edit = menu.items.first { $0.title == "Edit" }?.submenu
        let create = edit?.items.first { $0.title == "Create Resource" }?.submenu
        let brush = create?.items.first { $0.title == "Brush from Selection…" }
        let pattern = create?.items.first { $0.title == "Pattern from Selection…" }
        XCTAssertEqual(brush?.action, #selector(DocumentWindowController.createBrushFromSelection(_:)))
        XCTAssertEqual(pattern?.action, #selector(DocumentWindowController.createPatternFromSelection(_:)))
        XCTAssertEqual(brush?.keyEquivalent, "")
        XCTAssertEqual(pattern?.keyEquivalent, "")
    }
}
