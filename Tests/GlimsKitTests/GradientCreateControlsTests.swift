import XCTest
import AppKit
@testable import GlimsKit

/// Pure tests for the Gradient… controls' rules: the whole-draft
/// validation through `EngineSession.validateGradientCreation` (the same
/// gate facade slot 138 applies before its RPC), the NSColor-to-plain-RGBA
/// endpoint conversion, the cached document gate, the field-acceptance
/// rule and the reused phase machine, plus the menu wiring. No engine and
/// no windows.
final class GradientCreateControlsTests: XCTestCase {
    private typealias Validation = GradientCreateValidation
    private typealias Phases = ResourceSelectionFormValidation
    private typealias Phase = ResourceSelectionFormValidation.Phase
    private typealias RGBA = EngineSession.RGBAColor

    private let left = RGBA(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.9)
    private let right = RGBA(red: 0.75, green: 0.25, blue: 0.5, alpha: 0.1)

    private func rejection(_ result: Result<Validation.Draft, Validation.Rejection>) -> String? {
        if case .failure(let rejection) = result { return rejection.message }
        return nil
    }

    // MARK: Whole-draft validation

    func testValidDraftPassesUnchanged() {
        for name in ["a", "New Gradient", "Copy of 山 é", "A  B"] {
            guard case .success(let draft) = Validation.validate(name: name, left: left, right: right) else {
                return XCTFail("'\(name)' must be accepted")
            }
            XCTAssertEqual(draft.name, name, "the name passes through exactly as typed")
            XCTAssertEqual(draft.left, left)
            XCTAssertEqual(draft.right, right)
        }
    }

    func testEdgeWhitespaceNamesAreRefusedNeverTrimmed() {
        let message = "This resource format cannot preserve spaces at the start or end of its name."
        for name in [" x", "x ", " x "] {
            XCTAssertEqual(rejection(Validation.validate(name: name, left: left, right: right)), message,
                           "'\(name)' must be refused as .ggr edge whitespace")
        }
    }

    func testNameContractBytesNULAndControls() {
        XCTAssertNil(rejection(Validation.validate(name: String(repeating: "a", count: 255),
                                                   left: left, right: right)))
        XCTAssertNotNil(rejection(Validation.validate(name: String(repeating: "a", count: 256),
                                                      left: left, right: right)))
        // Multibyte names count UTF-8 bytes: "山" is 3 bytes, 85 fit in 255.
        XCTAssertNil(rejection(Validation.validate(name: String(repeating: "山", count: 85),
                                                   left: left, right: right)))
        XCTAssertNotNil(rejection(Validation.validate(name: String(repeating: "山", count: 86),
                                                      left: left, right: right)))
        XCTAssertNotNil(rejection(Validation.validate(name: "", left: left, right: right)))
        XCTAssertNotNil(rejection(Validation.validate(name: "abc\0def", left: left, right: right)))
        for name in ["a\nb", "a\tb", "\u{01}", "\u{7F}", "\u{85}", "\tx", "x\n", "x\r", "\u{0B}x", "x\u{0C}"] {
            XCTAssertNotNil(rejection(Validation.validate(name: name, left: left, right: right)),
                            "'\(name)' must be refused as a control character")
        }
    }

    func testEndpointComponentsMustBeFiniteAndInsideZeroOne() {
        for (label, bad) in [("red", RGBA(red: -0.01, green: 0, blue: 0, alpha: 1)),
                             ("green", RGBA(red: 0, green: 1.01, blue: 0, alpha: 1)),
                             ("blue", RGBA(red: 0, green: 0, blue: .infinity, alpha: 1)),
                             ("alpha", RGBA(red: 0, green: 0, blue: 0, alpha: .nan))] {
            let leftMessage = rejection(Validation.validate(name: "n", left: bad, right: right))
            XCTAssertTrue(leftMessage?.contains("left endpoint's \(label)") == true,
                          "the left \(label) refusal names the component (\(leftMessage ?? ""))")
            let rightMessage = rejection(Validation.validate(name: "n", left: left, right: bad))
            XCTAssertTrue(rightMessage?.contains("right endpoint's \(label)") == true,
                          "the right \(label) refusal names the component (\(rightMessage ?? ""))")
        }
        // Alpha is a first-class component: 0 and 1 both pass.
        XCTAssertNil(rejection(Validation.validate(
            name: "n", left: RGBA(red: 0, green: 0, blue: 0, alpha: 0),
            right: RGBA(red: 1, green: 1, blue: 1, alpha: 1))))
    }

    // MARK: Endpoint conversion (main thread, plain data out)

    func testEndpointConversionKeepsSRGBComponentsAndAlpha() {
        guard case .success(let value) = Validation.endpoint(
            NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 0.9), label: "left") else {
            return XCTFail("an sRGB color converts")
        }
        XCTAssertEqual(value, RGBA(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.9))
    }

    func testEndpointConversionExpandsGrayscaleToSRGB() {
        guard case .success(let value) = Validation.endpoint(
            NSColor(white: 0.5, alpha: 0.25), label: "right") else {
            return XCTFail("a grayscale color converts")
        }
        XCTAssertEqual(value.red, value.green)
        XCTAssertEqual(value.green, value.blue)
        XCTAssertEqual(value.alpha, 0.25)
    }

    // MARK: Cached gate

    private func gate(_ engineActivity: String? = nil, _ plugInLabel: String? = nil,
                      _ isClosing: Bool = false, _ isSavingForClose: Bool = false,
                      _ isTransferringClipboard: Bool = false, _ previewOpen: Bool = false) -> String? {
        Validation.gate(engineActivity: engineActivity, plugInLabel: plugInLabel, isClosing: isClosing,
                        isSavingForClose: isSavingForClose, isTransferringClipboard: isTransferringClipboard,
                        previewOpen: previewOpen)
    }

    func testGateIsNilWhenNothingIsCached() {
        XCTAssertNil(gate())
    }

    func testGateKeysOnCachedStateOnly() {
        // The gate takes no selection, target, floating or file-state
        // input at all: the gradient catalog is global and the write
        // takes no image.
        XCTAssertTrue(gate("Filling")?.contains("Filling… Wait for it to finish") == true)
        XCTAssertTrue(gate(nil, "Gaussian Blur")?.contains("Finish or cancel") == true)
        XCTAssertTrue(gate(nil, nil, true)?.isEmpty == false)
        XCTAssertTrue(gate(nil, nil, false, true)?.isEmpty == false)
        XCTAssertTrue(gate(nil, nil, false, false, true)?.isEmpty == false)
        XCTAssertTrue(gate(nil, nil, false, false, false, true)?.contains("filter preview") == true)
        XCTAssertNil(gate(nil, nil, false, false, false, false))
    }

    // MARK: Phase machine and field acceptance

    func testAcceptedWriteGatesFieldsAndBothButtons() {
        XCTAssertTrue(Validation.acceptsInput(.editing))
        XCTAssertFalse(Validation.acceptsInput(.accepting))
        XCTAssertFalse(Validation.acceptsInput(.closed))
        XCTAssertEqual(Phases.applyTransition(.editing, locallyValid: true), Phase.accepting)
        XCTAssertEqual(Phases.applyTransition(.accepting, locallyValid: true), Phase.accepting,
                       "a reentrant Create cannot start a second write")
        XCTAssertEqual(Phases.completionTransition(.accepting, success: true), Phase.closed)
        XCTAssertEqual(Phases.completionTransition(.accepting, success: false), Phase.editing,
                       "a native failure returns to editing with the draft preserved")
        XCTAssertEqual(Phases.completionTransition(.editing, success: true), Phase.editing,
                       "a stale completion is ignored")
        XCTAssertTrue(Phases.cancelAllowed(.editing))
        XCTAssertFalse(Phases.cancelAllowed(.accepting),
                       "Cancel is gated while an accepted write is active")
        XCTAssertFalse(Phases.cancelAllowed(.closed))
    }

    // MARK: Menu wiring

    @MainActor
    func testEditMenuListsGradientWithoutShortcut() {
        let menu = MainMenu.make()
        let edit = menu.items.first { $0.title == "Edit" }?.submenu
        let create = edit?.items.first { $0.title == "Create Resource" }?.submenu
        let gradient = create?.items.first { $0.title == "Gradient…" }
        XCTAssertEqual(gradient?.action, #selector(DocumentWindowController.createGradient(_:)))
        XCTAssertEqual(gradient?.keyEquivalent, "", "the Gradient… item carries no shortcut")
    }
}
