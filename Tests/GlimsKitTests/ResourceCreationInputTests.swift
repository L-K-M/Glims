import XCTest
import CGlimsEngine
@testable import GlimsKit

/// Pure input-validation tests for resource creation
/// (EngineSession.validateResourceCreation, the pre-RPC gate of
/// resource_create_pixels, facade slot 129): the UTF-8 byte limit of
/// the label with multi-byte characters, control-character and NUL
/// rejection, the dimension and exact-byte-count rules with overflow
/// safety, and the per-kind brush-spacing constraints.
final class ResourceCreationInputTests: XCTestCase {
    private func validBrush() throws {
        try EngineSession.validateResourceCreation(kind: .brush, name: "Clipboard brush",
                                                   width: 2, height: 2, byteCount: 16,
                                                   brushSpacing: 10)
    }

    private func invalidStatus(of error: Error) -> Int32? {
        (error as? EngineSession.EngineError)?.status
    }

    // MARK: Name: UTF-8 byte limit

    func testNameAt255BytesIsAccepted() throws {
        XCTAssertNoThrow(try EngineSession.validateResourceCreation(
            kind: .brush, name: String(repeating: "a", count: 255),
            width: 1, height: 1, byteCount: 4, brushSpacing: 1))
    }

    func testNameAt256BytesIsRejected() {
        XCTAssertThrowsError(try EngineSession.validateResourceCreation(
            kind: .brush, name: String(repeating: "a", count: 256),
            width: 1, height: 1, byteCount: 4, brushSpacing: 1)) { error in
            XCTAssertEqual(invalidStatus(of: error), Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue))
        }
    }

    func testMultiByteNameCountsUTF8BytesNotCharacters() throws {
        // "é" is 2 UTF-8 bytes: 127 of them fit in 254 bytes, 128 do not.
        XCTAssertNoThrow(try EngineSession.validateResourceCreation(
            kind: .pattern, name: String(repeating: "é", count: 127),
            width: 1, height: 1, byteCount: 4, brushSpacing: 0))
        XCTAssertThrowsError(try EngineSession.validateResourceCreation(
            kind: .pattern, name: String(repeating: "é", count: 128),
            width: 1, height: 1, byteCount: 4, brushSpacing: 0))
        // "山" is 3 UTF-8 bytes: 85 of them are exactly 255 bytes.
        XCTAssertNoThrow(try EngineSession.validateResourceCreation(
            kind: .pattern, name: String(repeating: "山", count: 85),
            width: 1, height: 1, byteCount: 4, brushSpacing: 0))
        XCTAssertThrowsError(try EngineSession.validateResourceCreation(
            kind: .pattern, name: String(repeating: "山", count: 86),
            width: 1, height: 1, byteCount: 4, brushSpacing: 0))
    }

    // MARK: Name: control characters, NUL, empty

    func testEmptyNameIsRejected() {
        XCTAssertThrowsError(try EngineSession.validateResourceCreation(
            kind: .brush, name: "", width: 1, height: 1, byteCount: 4, brushSpacing: 1))
    }

    func testControlCharactersAreRejected() {
        // C0/C1 controls and DEL are all Unicode category Cc, which is
        // exactly what the native side rejects (g_unichar_iscntrl).
        for name in ["a\nb", "a\tb", "a\rb", "\u{01}", "\u{1F}", "\u{7F}", "\u{85}", "a\u{0B}b"] {
            XCTAssertThrowsError(try EngineSession.validateResourceCreation(
                kind: .brush, name: name, width: 1, height: 1, byteCount: 4, brushSpacing: 1),
                "control name must be rejected") { error in
                XCTAssertEqual(invalidStatus(of: error), Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue))
            }
        }
    }

    func testEmbeddedNULIsRejected() {
        XCTAssertThrowsError(try EngineSession.validateResourceCreation(
            kind: .brush, name: "abc\0def", width: 1, height: 1, byteCount: 4, brushSpacing: 1)) { error in
            XCTAssertEqual(invalidStatus(of: error), Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue))
        }
    }

    func testOrdinaryUnicodeNameIsAccepted() throws {
        // Spaces and U+2028 (a line separator, category Zl, not a
        // control) are ordinary text, not Cc controls.
        XCTAssertNoThrow(try EngineSession.validateResourceCreation(
            kind: .pattern, name: "Pinsel 山 é A1", width: 1, height: 1, byteCount: 4, brushSpacing: 0))
        XCTAssertNoThrow(try EngineSession.validateResourceCreation(
            kind: .pattern, name: "a\u{2028}b", width: 1, height: 1, byteCount: 4, brushSpacing: 0))
    }

    // MARK: Dimensions and exact byte count

    func testDimensionsBoundsAreEnforced() {
        for (width, height) in [(0, 1), (-1, 1), (1, 0), (1, -3), (10_001, 1), (1, 10_001)] {
            XCTAssertThrowsError(try EngineSession.validateResourceCreation(
                kind: .brush, name: "b", width: width, height: height,
                byteCount: max(width, 0) * max(height, 0) * 4, brushSpacing: 1))
        }
        XCTAssertNoThrow(try EngineSession.validateResourceCreation(
            kind: .brush, name: "b", width: 1, height: 1, byteCount: 4, brushSpacing: 1))
        XCTAssertNoThrow(try EngineSession.validateResourceCreation(
            kind: .brush, name: "b", width: 10_000, height: 10_000,
            byteCount: 400_000_000, brushSpacing: 1000))
    }

    func testByteCountMustEqualWidthTimesHeightTimesFourExactly() {
        XCTAssertNoThrow(try EngineSession.validateResourceCreation(
            kind: .brush, name: "b", width: 2, height: 3, byteCount: 24, brushSpacing: 1))
        XCTAssertThrowsError(try EngineSession.validateResourceCreation(
            kind: .brush, name: "b", width: 2, height: 3, byteCount: 23, brushSpacing: 1))
        XCTAssertThrowsError(try EngineSession.validateResourceCreation(
            kind: .brush, name: "b", width: 2, height: 3, byteCount: 25, brushSpacing: 1))
        XCTAssertThrowsError(try EngineSession.validateResourceCreation(
            kind: .brush, name: "b", width: 10_000, height: 10_000,
            byteCount: 400_000_001, brushSpacing: 1))
    }

    // MARK: Kind and spacing constraints

    func testGradientKindIsUnsupportedNotInvalid() {
        XCTAssertThrowsError(try EngineSession.validateResourceCreation(
            kind: .gradient, name: "g", width: 1, height: 1, byteCount: 4, brushSpacing: 0)) { error in
            XCTAssertEqual(invalidStatus(of: error), Int32(GLIMS_STATUS_UNSUPPORTED.rawValue))
        }
    }

    func testBrushSpacingRange() {
        XCTAssertThrowsError(try EngineSession.validateResourceCreation(
            kind: .brush, name: "b", width: 1, height: 1, byteCount: 4, brushSpacing: 0))
        XCTAssertThrowsError(try EngineSession.validateResourceCreation(
            kind: .brush, name: "b", width: 1, height: 1, byteCount: 4, brushSpacing: 1001))
        XCTAssertNoThrow(try EngineSession.validateResourceCreation(
            kind: .brush, name: "b", width: 1, height: 1, byteCount: 4, brushSpacing: 1))
        XCTAssertNoThrow(try EngineSession.validateResourceCreation(
            kind: .brush, name: "b", width: 1, height: 1, byteCount: 4, brushSpacing: 1000))
    }

    func testPatternTakesZeroSpacingOnly() {
        XCTAssertNoThrow(try EngineSession.validateResourceCreation(
            kind: .pattern, name: "p", width: 1, height: 1, byteCount: 4, brushSpacing: 0))
        XCTAssertThrowsError(try EngineSession.validateResourceCreation(
            kind: .pattern, name: "p", width: 1, height: 1, byteCount: 4, brushSpacing: 1))
    }

    func testValidRequestsPass() throws {
        try validBrush()
        XCTAssertNoThrow(try EngineSession.validateResourceCreation(
            kind: .pattern, name: "Clipboard pattern", width: 64, height: 32,
            byteCount: 64 * 32 * 4, brushSpacing: 0))
    }
}
