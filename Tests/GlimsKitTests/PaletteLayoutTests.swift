import RigiUI
import XCTest
@testable import GlimsKit

/// The first-launch palette arrangement (docs/design.md, section 2): Tools
/// at the top left with Tool Options docked under it, Layers, Paths and
/// History as tabs of one group at the right, Layers its front tab.
@MainActor
final class PaletteLayoutTests: XCTestCase {
    func testToolOptionsHangsUnderToolsAndLayersAndPathsShareATabGroupAtTheRight() {
        let tools = ToolsPaletteController.definition.kind
        let options = ToolOptionsPaletteController.definition.kind
        let layers = LayersPaletteController.definition.kind
        let paths = PathsPaletteController.definition.kind
        let history = HistoryPaletteController.definition.kind

        XCTAssertEqual(AppController.defaultPaletteLayout, [
            PaletteGroupDefault([tools], placement: .topLeading),
            PaletteGroupDefault([options], placement: .docked(below: tools)),
            PaletteGroupDefault([layers, paths, history], placement: .topTrailing),
        ])
    }
}
