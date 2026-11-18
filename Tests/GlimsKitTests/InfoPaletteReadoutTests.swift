import XCTest
@testable import GlimsKit

/// The Info palette's HSB and selection-size text, Photoshop's readouts.
@MainActor
final class InfoPaletteReadoutTests: XCTestCase {
    func testPrimariesAndNeutrals() {
        XCTAssertEqual(InfoPaletteController.hsbText(red: 1, green: 0, blue: 0), "HSB: H 0°  S 100.0%  B 100.0%")
        XCTAssertEqual(InfoPaletteController.hsbText(red: 0, green: 1, blue: 0), "HSB: H 120°  S 100.0%  B 100.0%")
        XCTAssertEqual(InfoPaletteController.hsbText(red: 0, green: 0, blue: 1), "HSB: H 240°  S 100.0%  B 100.0%")
        XCTAssertEqual(InfoPaletteController.hsbText(red: 0.5, green: 0.5, blue: 0.5), "HSB: H 0°  S 0.0%  B 50.0%")
        XCTAssertEqual(InfoPaletteController.hsbText(red: 0, green: 0, blue: 0), "HSB: H 0°  S 0.0%  B 0.0%")
    }

    func testHueWrapsAndRounds() {
        // Red to magenta: the hue sector before 0 wraps to 330.
        XCTAssertEqual(InfoPaletteController.hsbText(red: 1, green: 0, blue: 0.5), "HSB: H 330°  S 100.0%  B 100.0%")
        XCTAssertEqual(InfoPaletteController.hsbText(red: 0.8, green: 0.4, blue: 0.4), "HSB: H 0°  S 50.0%  B 80.0%")
        // 359.7 degrees rounds to 0, never 360.
        XCTAssertEqual(InfoPaletteController.hsbText(red: 1, green: 0, blue: 0.005), "HSB: H 0°  S 100.0%  B 100.0%")
    }

    func testOutOfRangeAndInvalid() {
        XCTAssertEqual(InfoPaletteController.hsbText(red: 1.2, green: -0.1, blue: 0), "HSB: H 0°  S 100.0%  B 100.0%")
        XCTAssertEqual(InfoPaletteController.hsbText(red: .nan, green: 0, blue: 0), "HSB: —")
    }

    func testSelectionSize() {
        XCTAssertEqual(InfoPaletteController.sizeText(nil), "W: —    H: —")
        XCTAssertEqual(InfoPaletteController.sizeText(CGRect(x: -5, y: 7, width: 40, height: 30)), "W: 40    H: 30")
    }
}
