import XCTest
@testable import GlimsKit

final class LineToolTests: XCTestCase {
    func testLineToolHasItsOwnPaletteCellAndPhotoshopShortcut() {
        XCTAssertEqual(ToolID.group(forShortcut: "N"), [.line])
        XCTAssertEqual(ToolID.line.name, "Line")
        XCTAssertNil(ToolID.line.paintTool)
        XCTAssertFalse(ToolID.line.isSelectionTool)
        XCTAssertTrue(ToolID.paletteSlots.contains([.line]))
    }

    func testLineToolIsLimitedToOrdinaryColorModes() {
        XCTAssertTrue(ToolID.line.isAvailable(in: .rgb))
        XCTAssertFalse(ToolID.line.isAvailable(in: .lab))
        XCTAssertFalse(ToolID.line.isAvailable(in: .cmyk))
        XCTAssertFalse(ToolID.line.isAvailable(in: .multichannel))
    }

    func testDefaultsAreWithinTheEngineRangesAndMatchTheFacadeBits() {
        let settings = EngineSession.LineDrawSettings()
        typealias Line = EngineSession.LineDrawSettings
        XCTAssertTrue(Line.widthRange.contains(settings.width))
        XCTAssertTrue(Line.arrowWidthRange.contains(settings.arrowWidth))
        XCTAssertTrue(Line.arrowLengthRange.contains(settings.arrowLength))
        XCTAssertTrue(Line.arrowConcavityRange.contains(settings.arrowConcavity))
        XCTAssertEqual(settings.arrowheads, [])
        XCTAssertEqual(Line.Arrowheads.start.rawValue, 1)
        XCTAssertEqual(Line.Arrowheads.end.rawValue, 2)
    }

    func testDraggingHintNamesTheShiftConstraint() {
        XCTAssertEqual(ToolHintPolicy.hint(tool: .line, phase: .dragging, flags: .shift),
                       "Constrained line. Release to draw it.")
    }
}
