import CoreGraphics
import XCTest
@testable import GlimsKit

final class DocumentWindowPlacementTests: XCTestCase {
    func testSmallScreenKeepsDefaultPaletteColumnsClear() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 840)
        let palettes = [CGRect(x: 8, y: 560, width: 64, height: 280),
                        CGRect(x: 8, y: 320, width: 330, height: 240),
                        CGRect(x: 1170, y: 440, width: 262, height: 400)]
        let area = DocumentWindowPlacement.availableFrame(in: screen, avoiding: palettes)
        let frame = DocumentWindowPlacement.frame(size: CGSize(width: 960, height: 708), after: nil, in: area)
        XCTAssertEqual(area, CGRect(x: 344, y: 0, width: 820, height: 840))
        XCTAssertEqual(frame.width, 820)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertTrue(palettes.allSatisfy { !$0.intersects(frame) })
        let oldCentered = CGRect(x: 240, y: 66, width: 960, height: 708)
        XCTAssertTrue(palettes.contains { $0.intersects(oldCentered) }, "the former centering overlaps these palettes")
    }

    func testNegativeOriginScreenAndOutsidePalettes() {
        let screen = CGRect(x: -1600, y: 160, width: 1600, height: 900)
        let area = DocumentWindowPlacement.availableFrame(in: screen,
            avoiding: [CGRect(x: -1610, y: 400, width: 300, height: 700),
                       CGRect(x: 500, y: 500, width: 300, height: 500)])
        XCTAssertEqual(area, CGRect(x: -1304, y: 160, width: 1304, height: 900))
        let frame = DocumentWindowPlacement.frame(size: CGSize(width: 960, height: 708), after: nil, in: area)
        XCTAssertTrue(area.contains(frame))
    }

    func testNoVisiblePalettesRetainsFullScreen() {
        let screen = CGRect(x: 0, y: 20, width: 1920, height: 1000)
        XCTAssertEqual(DocumentWindowPlacement.availableFrame(in: screen, avoiding: []), screen)
        XCTAssertEqual(DocumentWindowPlacement.frame(size: CGSize(width: 960, height: 708), after: nil, in: screen),
                       CGRect(x: 480, y: 166, width: 960, height: 708))
    }

    func testCascadesOnlyWithinAvailableAreaAndWrapsWithoutOverflow() {
        let area = CGRect(x: 340, y: 20, width: 820, height: 840)
        let first = CGRect(x: 350, y: 100, width: 600, height: 500)
        XCTAssertEqual(DocumentWindowPlacement.frame(size: first.size, after: first, in: area),
                       CGRect(x: 372, y: 78, width: 600, height: 500))
        let last = CGRect(x: 560, y: 20, width: 600, height: 500)
        XCTAssertEqual(DocumentWindowPlacement.frame(size: last.size, after: last, in: area),
                       CGRect(x: 362, y: 360, width: 600, height: 500))
        let full = DocumentWindowPlacement.frame(size: CGSize(width: 960, height: 900), after: last, in: area)
        XCTAssertEqual(full, area)
    }

    func testCrowdedWorkspaceKeepsDocumentUsableWithoutMovingPalettes() {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(DocumentWindowPlacement.availableFrame(in: screen, avoiding: [screen]), screen)
    }

    func testPaletteAboveCanvasLeavesWideSpaceBelow() {
        let screen = CGRect(x: 0, y: 0, width: 1000, height: 800)
        XCTAssertEqual(DocumentWindowPlacement.availableFrame(in: screen,
            avoiding: [CGRect(x: 300, y: 650, width: 400, height: 150)]),
                       CGRect(x: 0, y: 0, width: 1000, height: 644))
    }
}
