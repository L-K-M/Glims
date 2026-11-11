import XCTest
@testable import GlimsKit

final class RecorderAffineGeometryTests: XCTestCase {
    typealias Affine = RecorderFileCommand.Affine
    typealias Rect = RecorderFileCommand.Rect
    private let bounds = Rect(x: 0, y: 0, width: 16, height: 12)

    func testRejectsHugeTranslationDespiteSmallFiniteExtent() {
        let affine = Affine(a: 1, b: 0, c: 0, d: 1, tx: 1e12, ty: 0)
        XCTAssertNil(affine.outputBounds(for: bounds))
    }

    func testBoundsLimitIncludesOutwardIntegerRounding() {
        let affine = Affine(a: 1, b: 0, c: 0, d: 1, tx: 0.25, ty: 0)
        XCTAssertNil(affine.outputBounds(for: Rect(x: 0, y: 0, width: 524288, height: 12)))
    }

    func testLiteralTurnAndTranslationHaveExpectedOutputBounds() {
        let affine = Affine(a: 0, b: 1, c: -1, d: 0, tx: 20, ty: -5)
        XCTAssertEqual(affine.outputBounds(for: bounds), Rect(x: 8, y: -5, width: 12, height: 16))
    }

    func testOutputUsesFreshBoundLayerGeometryNotItsSavedDescription() {
        let affine = Affine(a: 2, b: 0, c: 0, d: 2, tx: 1, ty: 1)
        XCTAssertEqual(affine.outputBounds(for: bounds), Rect(x: 1, y: 1, width: 32, height: 24))
        XCTAssertNil(affine.outputBounds(for: Rect(x: 0, y: 0, width: 300000, height: 12)))
    }
    func testRejectsNonFiniteAndDegenerateGeometryBeforeComputingBounds() {
        for affine in [Affine(a: 1e308, b: 0, c: 0, d: 1e308, tx: 0, ty: 0),
                       Affine(a: 1e308, b: 0, c: 0, d: 1e-308, tx: 0, ty: 0),
                       Affine(a: 1, b: 1, c: 1, d: 1, tx: 0, ty: 0),
                       Affine(a: 1, b: 0, c: 0, d: 1, tx: .nan, ty: 0)] {
            XCTAssertNil(affine.outputBounds(for: bounds))
        }
        let move = Affine(a: 1, b: 0, c: 0, d: 1, tx: 1, ty: 1)
        XCTAssertNil(move.outputBounds(for: Rect(x: .nan, y: 0, width: 1, height: 1)))
        XCTAssertNil(move.outputBounds(for: Rect(x: 0, y: 0, width: 0, height: 1)))
    }

}
