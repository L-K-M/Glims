import XCTest
@testable import GlimsKit

final class InkEditTests: XCTestCase {
    func testInkAmountUsesPaperToInkIntensityAndIndependentOpacity() throws {
        let paper = try InkFillValidation.settings(amount: "0", opacity: "100").get()
        XCTAssertEqual(paper.intensity, 1)
        XCTAssertEqual(paper.opacity, 1)
        let ink = try InkFillValidation.settings(amount: "100", opacity: "0").get()
        XCTAssertEqual(ink.intensity, 0)
        XCTAssertEqual(ink.opacity, 0)
        let tint = try InkFillValidation.settings(amount: "25", opacity: "37.5").get()
        XCTAssertEqual(tint.intensity, 0.75)
        XCTAssertEqual(tint.opacity, 0.375)
        XCTAssertEqual(tint.operation, .fill)
    }

    func testInvalidDraftsAreRejectedWithoutClampingOrAcceptingPrefixes() {
        for text in ["", " ", " 50", "50 ", "5 0", "50%", "50junk", "NaN", "nan", "inf", "-inf",
                     "1e999", "-0.01", "100.01"] {
            if case .success = InkFillValidation.settings(amount: text, opacity: "100") {
                XCTFail("Invalid ink amount accepted: \(text)")
            }
            if case .success = InkFillValidation.settings(amount: "50", opacity: text) {
                XCTFail("Invalid opacity accepted: \(text)")
            }
        }
    }

    func testCanonicalOperationParametersRefuseDormantInvalidValues() {
        XCTAssertTrue(EngineSession.InkEdit.clear.isValid)
        XCTAssertEqual(EngineSession.InkEdit.clear.intensity, 1)
        XCTAssertTrue(EngineSession.InkEdit.invert.isValid)
        XCTAssertEqual(EngineSession.InkEdit.invert.intensity, 0)
        for settings in [
            EngineSession.InkEdit(operation: .clear, intensity: 0, opacity: 1),
            .init(operation: .clear, intensity: 1, opacity: 0.5),
            .init(operation: .invert, intensity: 1, opacity: 1),
            .init(operation: .invert, intensity: 0, opacity: 0),
            .init(operation: .fill, intensity: .nan, opacity: 1),
            .init(operation: .fill, intensity: 0.5, opacity: .infinity),
            .init(operation: .fill, intensity: -0.1, opacity: 1),
            .init(operation: .fill, intensity: 1, opacity: 1.1)
        ] { XCTAssertFalse(settings.isValid) }
    }
}
