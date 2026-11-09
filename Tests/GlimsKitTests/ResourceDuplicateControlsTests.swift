import XCTest
@testable import GlimsKit

/// Pure tests for the Duplicate… controls' rules: the shared name contract
/// through `EngineSession.validateResourceName` (the same gate facade slot
/// 131 applies), the captured source value, the cached document gate, the
/// Default-row refusal and the reused phase machine. No engine, no AppKit
/// windows.
final class ResourceDuplicateControlsTests: XCTestCase {
    private typealias Validation = ResourceDuplicateValidation
    private typealias Phase = ResourceSelectionFormValidation.Phase

    private static func source(_ name: String = "Source", kind: EngineSession.ResourceKind = .brush,
                               id: UInt64 = 42) -> Validation.Source {
        Validation.Source(kind: kind, id: id,
                          identity: EngineSession.ResourceIdentity(name: name, collection: nil, isInternal: false))
    }

    private func rejection(_ result: Result<String, Validation.Rejection>) -> String? {
        if case .failure(let rejection) = result { return rejection.message }
        return nil
    }

    // MARK: Name (shared validateResourceName contract, no normalization)

    func testValidNamesPassUnchanged() {
        for name in ["a", "Copy of 山 é", String(repeating: "a", count: 255), "  padded  "] {
            guard case .success(let accepted) = Validation.validateName(name) else {
                return XCTFail("'\(name.prefix(20))' must be accepted")
            }
            XCTAssertEqual(accepted, name, "the name passes through exactly as typed — no trimming")
        }
    }

    func testInvalidNamesAreRejectedThroughTheSharedGate() {
        XCTAssertNotNil(rejection(Validation.validateName("")))
        XCTAssertNotNil(rejection(Validation.validateName("abc\0def")))
        XCTAssertNotNil(rejection(Validation.validateName(String(repeating: "a", count: 256))))
        for name in ["a\nb", "a\tb", "\u{01}", "\u{7F}", "\u{85}"] {
            XCTAssertNotNil(rejection(Validation.validateName(name)), "control name must be rejected")
        }
        // Multibyte names count UTF-8 bytes: "山" is 3 bytes, 85 fit in 255.
        guard case .success = Validation.validateName(String(repeating: "山", count: 85)) else {
            return XCTFail("255 UTF-8 bytes must pass")
        }
        XCTAssertNotNil(rejection(Validation.validateName(String(repeating: "山", count: 86))))
    }

    // MARK: Captured source

    func testSourceIsACapturedValue() {
        let source = Self.source("Original", kind: .pattern, id: 7)
        XCTAssertEqual(source.name, "Original")
        XCTAssertEqual(source.kind, .pattern)
        XCTAssertEqual(source.id, 7)
        XCTAssertEqual(source, Self.source("Original", kind: .pattern, id: 7))
        XCTAssertNotEqual(source, Self.source("Retargeted", kind: .pattern, id: 7),
                          "a different row is a different captured source")
        XCTAssertNotEqual(source, Self.source("Original", kind: .brush, id: 7),
                          "a different kind is a different captured source")
    }

    func testProposedNameIsOnlyADraft() {
        XCTAssertEqual(Validation.proposedName(Self.source("Round")), "Round copy")
        // The proposal may itself be invalid (255-byte source + suffix);
        // validation of the field text is what refuses it, never a rewrite.
        let long = Self.source(String(repeating: "a", count: 255))
        XCTAssertEqual(Validation.proposedName(long), String(repeating: "a", count: 255) + " copy")
        XCTAssertNotNil(rejection(Validation.validateName(Validation.proposedName(long))))
    }

    // MARK: Default-row / no-source refusal

    func testNilSourceIsRefusedWithAClearReasonPerKind() {
        XCTAssertTrue(Validation.sourceRefusal(nil, kind: .brush)?.contains("not a saved resource") == true)
        XCTAssertTrue(Validation.sourceRefusal(nil, kind: .gradient)?.contains("not a saved resource") == true)
        XCTAssertTrue(Validation.sourceRefusal(nil, kind: .pattern)?.contains("Select a saved pattern") == true)
        XCTAssertNil(Validation.sourceRefusal(Self.source(), kind: .brush))
    }

    // MARK: Cached document gate

    private func gate(activity: String? = nil, plugIn: String? = nil, closing: Bool = false,
                      saving: Bool = false, clipboard: Bool = false, preview: Bool = false,
                      kind: EngineSession.ResourceKind = .brush) -> String? {
        Validation.gate(engineActivity: activity, plugInLabel: plugIn, isClosing: closing,
                        isSavingForClose: saving, isTransferringClipboard: clipboard,
                        previewOpen: preview, kind: kind)
    }

    func testGateReasons() {
        XCTAssertEqual(gate(activity: "Saving"), "Saving… Wait for it to finish before duplicating a brush.")
        XCTAssertTrue(gate(plugIn: "Gaussian Blur")?.contains("Finish or cancel") == true)
        XCTAssertEqual(gate(closing: true), ImageDocument.DocumentError.closed.localizedDescription)
        XCTAssertEqual(gate(saving: true), ImageDocument.DocumentError.busy.localizedDescription)
        XCTAssertEqual(gate(clipboard: true), ImageDocument.DocumentError.busy.localizedDescription)
        XCTAssertEqual(gate(preview: true), "Apply or cancel the filter preview first.")
        XCTAssertNil(gate())
        XCTAssertEqual(gate(kind: .gradient), nil)
        XCTAssertTrue(gate(activity: "Saving", kind: .gradient)?.contains("gradient") == true)
    }

    // MARK: Phase machine (reused from ResourceSelectionFormValidation)

    func testPhaseMachineGatesCreateAndCancel() {
        XCTAssertEqual(ResourceSelectionFormValidation.applyTransition(.editing, locallyValid: true), .accepting)
        XCTAssertEqual(ResourceSelectionFormValidation.applyTransition(.accepting, locallyValid: true), .accepting,
                       "a reentrant accept cannot start a second write")
        XCTAssertEqual(ResourceSelectionFormValidation.applyTransition(.editing, locallyValid: false), .editing)
        XCTAssertEqual(ResourceSelectionFormValidation.completionTransition(.accepting, success: true), .closed)
        XCTAssertEqual(ResourceSelectionFormValidation.completionTransition(.accepting, success: false), .editing)
        XCTAssertEqual(ResourceSelectionFormValidation.completionTransition(.editing, success: true), .editing,
                       "a stale completion is ignored")
        XCTAssertTrue(ResourceSelectionFormValidation.cancelAllowed(.editing))
        XCTAssertFalse(ResourceSelectionFormValidation.cancelAllowed(.accepting),
                       "cancel is never faked while an accepted write is active")
        XCTAssertFalse(ResourceSelectionFormValidation.cancelAllowed(.closed))
        XCTAssertEqual(Phase.editing, .editing)
    }
}
