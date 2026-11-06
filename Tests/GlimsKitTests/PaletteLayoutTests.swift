import RigiUI
import XCTest
@testable import GlimsKit

/// The first-launch palette arrangement (docs/design.md, section 2): Tools
/// at the top left with Tool Options docked under it, Layers and Paths as
/// tabs of one group at the right.
@MainActor
final class PaletteLayoutTests: XCTestCase {
    func testToolOptionsHangsUnderToolsAndLayersAndPathsShareATabGroupAtTheRight() {
        let tools = ToolsPaletteController.definition.kind
        let options = ToolOptionsPaletteController.definition.kind
        let layers = LayersPaletteController.definition.kind
        let paths = PathsPaletteController.definition.kind

        XCTAssertEqual(AppController.defaultPaletteLayout, [
            PaletteGroupDefault([tools], placement: .topLeading),
            PaletteGroupDefault([options], placement: .docked(below: tools)),
            PaletteGroupDefault([layers, paths], placement: .topTrailing),
        ])
    }
}
