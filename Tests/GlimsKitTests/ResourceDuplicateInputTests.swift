import XCTest
import CGlimsEngine
@testable import GlimsKit

/// Pure input-validation tests for saved-resource duplication
/// (EngineSession.validateResourceName, the pre-RPC gate of
/// EngineSession.duplicateResource, facade slot 131): the same label
/// contract resource_create_pixels enforces natively — nonempty UTF-8,
/// no embedded NUL, at most 255 UTF-8 bytes, no Unicode Cc control
/// characters. The duplicate wrapper validates the requested name
/// before any bridge call, and passes the UInt64 handles through
/// unchanged; these tests cover the validation half without an engine.
final class ResourceDuplicateInputTests: XCTestCase {
    private func invalidStatus(of error: Error) -> Int32? {
        (error as? EngineSession.EngineError)?.status
    }

    // MARK: UTF-8 byte limit

    func testNameAt255BytesIsAccepted() {
        XCTAssertNoThrow(try EngineSession.validateResourceName(String(repeating: "a", count: 255)))
    }

    func testNameAt256BytesIsRejected() {
        XCTAssertThrowsError(try EngineSession.validateResourceName(String(repeating: "a", count: 256))) { error in
            XCTAssertEqual(invalidStatus(of: error), Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue))
        }
    }

    func testMultiByteNameCountsUTF8BytesNotCharacters() {
        // "é" is 2 UTF-8 bytes: 127 fit in 254, 128 do not.
        XCTAssertNoThrow(try EngineSession.validateResourceName(String(repeating: "é", count: 127)))
        XCTAssertThrowsError(try EngineSession.validateResourceName(String(repeating: "é", count: 128)))
        // "山" is 3 UTF-8 bytes: 85 of them are exactly 255 bytes.
        XCTAssertNoThrow(try EngineSession.validateResourceName(String(repeating: "山", count: 85)))
        XCTAssertThrowsError(try EngineSession.validateResourceName(String(repeating: "山", count: 86)))
    }

    // MARK: empty, NUL, controls

    func testEmptyNameIsRejected() {
        XCTAssertThrowsError(try EngineSession.validateResourceName("")) { error in
            XCTAssertEqual(invalidStatus(of: error), Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue))
        }
    }

    func testEmbeddedNULIsRejected() {
        XCTAssertThrowsError(try EngineSession.validateResourceName("abc\0def")) { error in
            XCTAssertEqual(invalidStatus(of: error), Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue))
        }
    }

    func testControlCharactersAreRejected() {
        // C0/C1 controls and DEL are all Unicode category Cc, exactly
        // what the native side rejects (g_unichar_iscntrl).
        for name in ["a\nb", "a\tb", "a\rb", "\u{01}", "\u{1F}", "\u{7F}", "\u{85}", "a\u{0B}b"] {
            XCTAssertThrowsError(try EngineSession.validateResourceName(name),
                                 "control name must be rejected") { error in
                XCTAssertEqual(invalidStatus(of: error), Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue))
            }
        }
    }

    func testOrdinaryUnicodeNameIsAccepted() throws {
        // Spaces and U+2028 (category Zl, not a control) are ordinary text.
        XCTAssertNoThrow(try EngineSession.validateResourceName("Copy of 山 é A1"))
        XCTAssertNoThrow(try EngineSession.validateResourceName("a\u{2028}b"))
    }

    // MARK: the shared contract is the create path's contract

    func testCreateValidationUsesTheSameNameRules() {
        // validateResourceCreation must accept exactly what
        // validateResourceName accepts for the label, so the duplicate
        // gate cannot drift from the fixed create gate.
        for name in ["ok", String(repeating: "a", count: 255), "山 é"] {
            XCTAssertNoThrow(try EngineSession.validateResourceName(name))
            XCTAssertNoThrow(try EngineSession.validateResourceCreation(
                kind: .brush, name: name, width: 1, height: 1, byteCount: 4, brushSpacing: 1))
        }
        for name in ["", "a\nb", "abc\0def", String(repeating: "a", count: 256)] {
            XCTAssertThrowsError(try EngineSession.validateResourceName(name))
            XCTAssertThrowsError(try EngineSession.validateResourceCreation(
                kind: .brush, name: name, width: 1, height: 1, byteCount: 4, brushSpacing: 1))
        }
    }
}
