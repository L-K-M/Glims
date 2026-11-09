import XCTest
import CGlimsEngine
@testable import GlimsKit

/// Pure input-validation tests for gradient creation
/// (EngineSession.validateGradientCreation, the pre-RPC gate of
/// EngineSession.createGradient, facade slot 138): the shared label
/// contract (validateResourceName) plus the .ggr ASCII edge-whitespace
/// refusal, and both endpoints with every component (alpha included)
/// finite and inside 0...1. These tests cover the validation half without
/// an engine; no EngineRuntime is started.
final class GradientCreationInputTests: XCTestCase {
    private typealias RGBA = EngineSession.RGBAColor

    private let validLeft = RGBA(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.9)
    private let validRight = RGBA(red: 0.75, green: 0.25, blue: 0.5, alpha: 0.1)

    private func invalidStatus(of error: Error) -> Int32? {
        (error as? EngineSession.EngineError)?.status
    }

    private func assertInvalid(_ name: String, _ left: RGBA, _ right: RGBA,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EngineSession.validateGradientCreation(name: name, left: left, right: right),
                             file: file, line: line) { error in
            XCTAssertEqual(invalidStatus(of: error), Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                           file: file, line: line)
        }
    }

    // MARK: name contract

    func testValidNameAndEndpointsAreAccepted() {
        XCTAssertNoThrow(try EngineSession.validateGradientCreation(
            name: "glims-facade-grad-a", left: validLeft, right: validRight))
    }

    func testNameAt255BytesIsAcceptedAnd256Rejected() {
        XCTAssertNoThrow(try EngineSession.validateGradientCreation(
            name: String(repeating: "a", count: 255), left: validLeft, right: validRight))
        assertInvalid(String(repeating: "a", count: 256), validLeft, validRight)
    }

    func testMultiByteNameCountsUTF8BytesNotCharacters() {
        // "é" is 2 UTF-8 bytes: 127 fit, 128 do not. "山" is 3: 85 fit.
        XCTAssertNoThrow(try EngineSession.validateGradientCreation(
            name: String(repeating: "é", count: 127), left: validLeft, right: validRight))
        assertInvalid(String(repeating: "é", count: 128), validLeft, validRight)
        XCTAssertNoThrow(try EngineSession.validateGradientCreation(
            name: String(repeating: "山", count: 85), left: validLeft, right: validRight))
        assertInvalid(String(repeating: "山", count: 86), validLeft, validRight)
    }

    func testEmptyNULAndControlNamesAreRejected() {
        assertInvalid("", validLeft, validRight)
        assertInvalid("abc\0def", validLeft, validRight)
        for name in ["a\nb", "a\tb", "\u{01}", "\u{7F}", "\u{85}"] {
            assertInvalid(name, validLeft, validRight)
        }
    }

    // MARK: GGR ASCII edge whitespace (never silently trimmed)

    func testLeadingAndTrailingASCIISpaceAreRejected() {
        assertInvalid(" x", validLeft, validRight)
        assertInvalid("x ", validLeft, validRight)
        assertInvalid("  ", validLeft, validRight)
    }

    func testInteriorSpaceIsAccepted() {
        // Only the EDGES are refused; an interior space is ordinary text
        // and the native loader keeps it.
        XCTAssertNoThrow(try EngineSession.validateGradientCreation(
            name: "a b", left: validLeft, right: validRight))
    }

    func testNonASCIIEdgeWhitespaceIsAccepted() {
        // U+00A0 is not ASCII whitespace (g_ascii_isspace looks at bytes,
        // and its first/last UTF-8 bytes are >= 0x80) and not a Cc
        // control, so the native edge rule accepts it.
        XCTAssertNoThrow(try EngineSession.validateGradientCreation(
            name: "\u{00A0}x", left: validLeft, right: validRight))
        XCTAssertNoThrow(try EngineSession.validateGradientCreation(
            name: "x\u{00A0}", left: validLeft, right: validRight))
    }

    // MARK: endpoints — finite 0...1 including alpha, no clamping

    func testBoundaryZeroAndOneAreAcceptedForEveryComponent() {
        let zero = RGBA(red: 0, green: 0, blue: 0, alpha: 0)
        let one = RGBA(red: 1, green: 1, blue: 1, alpha: 1)
        XCTAssertNoThrow(try EngineSession.validateGradientCreation(name: "ok", left: zero, right: one))
    }

    func testNaNAndInfinityAreRejectedOnEitherEndpoint() {
        for value in [Double.nan, .infinity, -.infinity] {
            var bad = validLeft
            bad.red = value
            assertInvalid("glims-nan", bad, validRight)
            var badRight = validRight
            badRight.alpha = value
            assertInvalid("glims-nan", validLeft, badRight)
        }
    }

    func testOutOfRangeComponentsAreRejectedIncludingAlphaAndRight() {
        var cases: [(RGBA, RGBA, String)] = []
        var bad = validLeft; bad.green = -0.1; cases.append((bad, validRight, "left.green -0.1"))
        bad = validRight; bad.blue = 1.1; cases.append((validLeft, bad, "right.blue 1.1"))
        bad = validLeft; bad.alpha = -0.0001; cases.append((bad, validRight, "left.alpha negative"))
        bad = validRight; bad.alpha = 1.0001; cases.append((validLeft, bad, "right.alpha > 1"))
        bad = validLeft; bad.red = -Double.leastNonzeroMagnitude
        cases.append((bad, validRight, "left.red least-negative"))
        for (left, right, _) in cases {
            assertInvalid("glims-range", left, right)
        }
    }

    func testValidFractionalValuesPassUnchanged() throws {
        // Validation must not clamp or normalize: the exact fractional
        // values that pass are the ones the native call receives.
        let left = RGBA(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4)
        let right = RGBA(red: 0.9, green: 0.8, blue: 0.7, alpha: 0.6)
        XCTAssertNoThrow(try EngineSession.validateGradientCreation(name: "frac", left: left, right: right))
        XCTAssertEqual(left, RGBA(red: 0.1, green: 0.2, blue: 0.3, alpha: 0.4))
        XCTAssertEqual(right, RGBA(red: 0.9, green: 0.8, blue: 0.7, alpha: 0.6))
    }

    func testRGBAColorIsAnOwnedEquatableSendableValue() {
        let a = RGBA(red: 0.25, green: 0.5, blue: 0.75, alpha: 0.9)
        var b = a
        XCTAssertEqual(a, b)
        b.alpha = 0.1
        XCTAssertNotEqual(a, b)
        XCTAssertTrue(MemoryLayout<RGBA>.size == 4 * MemoryLayout<Double>.size)
    }
}
