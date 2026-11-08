import CoreGraphics
import XCTest
@testable import GlimsKit

/// Pure tests for the guides controls: strict position parsing, the
/// per-orientation inclusive range against the cached image size, display
/// order, selection/edit preservation across reloads, the cached Show
/// Guides menu state and the overlay's image-to-view geometry.
final class GuidesControlsTests: XCTestCase {
    private static let accuracy = 1e-9

    private func guide(_ id: Int32, _ orientation: EngineSession.GuideOrientation,
                       _ position: Int32) -> EngineSession.Guide {
        EngineSession.Guide(id: id, orientation: orientation, position: position)
    }

    // MARK: Strict position parsing

    func testParsePositionAcceptsCanonicalDigitsOnly() {
        XCTAssertEqual(GuidesSheetLogic.parsePosition("0"), 0)
        XCTAssertEqual(GuidesSheetLogic.parsePosition("7"), 7)
        XCTAssertEqual(GuidesSheetLogic.parsePosition("24"), 24)
        XCTAssertEqual(GuidesSheetLogic.parsePosition("2147483647"), Int32.max)
    }

    func testParsePositionRejectsAnythingNotACanonicalInteger() {
        for text in ["", " ", " 12", "12 ", "+12", "-1", "1.5", "12px", "abc", "0x10",
                     "007", "1,2", "１２", "2147483648", "99999999999999999999", "\t3"] {
            XCTAssertNil(GuidesSheetLogic.parsePosition(text), "\"\(text)\" must not parse")
        }
    }

    // MARK: Range and orientation semantics

    func testHorizontalGuidesRangeOverTheImageHeight() {
        // A horizontal guide's position is a y coordinate: 0...height.
        XCTAssertEqual(GuidesSheetLogic.extent(orientation: .horizontal, width: 40, height: 24), 24)
        XCTAssertTrue(GuidesSheetLogic.isValid(position: 0, orientation: .horizontal, width: 40, height: 24))
        XCTAssertTrue(GuidesSheetLogic.isValid(position: 24, orientation: .horizontal, width: 40, height: 24))
        XCTAssertFalse(GuidesSheetLogic.isValid(position: 25, orientation: .horizontal, width: 40, height: 24))
        XCTAssertFalse(GuidesSheetLogic.isValid(position: -1, orientation: .horizontal, width: 40, height: 24))
        // The width is not this orientation's extent: 30 fits the width
        // but not the height, so a horizontal guide may not sit there.
        XCTAssertFalse(GuidesSheetLogic.isValid(position: 30, orientation: .horizontal, width: 40, height: 24))
        XCTAssertTrue(GuidesSheetLogic.isValid(position: 30, orientation: .vertical, width: 40, height: 24))
    }

    func testVerticalGuidesRangeOverTheImageWidth() {
        // A vertical guide's position is an x coordinate: 0...width.
        XCTAssertEqual(GuidesSheetLogic.extent(orientation: .vertical, width: 40, height: 24), 40)
        XCTAssertTrue(GuidesSheetLogic.isValid(position: 0, orientation: .vertical, width: 40, height: 24))
        XCTAssertTrue(GuidesSheetLogic.isValid(position: 40, orientation: .vertical, width: 40, height: 24))
        XCTAssertFalse(GuidesSheetLogic.isValid(position: 41, orientation: .vertical, width: 40, height: 24))
    }

    // MARK: Display order and selection preservation

    func testRowsAreListedByOrientationThenPosition() {
        let guides = [guide(4, .vertical, 9), guide(1, .horizontal, 20),
                      guide(2, .horizontal, 5), guide(3, .vertical, 1)]
        XCTAssertEqual(GuidesSheetLogic.sortedGuides(guides).map(\.id), [2, 1, 3, 4])
    }

    func testSelectionIsPreservedByGuideIdentityAcrossAReload() {
        let before = [guide(1, .horizontal, 5), guide(2, .vertical, 9), guide(3, .horizontal, 20)]
        // A new horizontal guide sorts first; the vertical guide sorts last.
        let after = [guide(9, .horizontal, 1)] + before
        XCTAssertEqual(GuidesSheetLogic.index(ofGuide: 3, in: before), 2)
        XCTAssertEqual(GuidesSheetLogic.index(ofGuide: 3, in: GuidesSheetLogic.sortedGuides(after)), 2)
        XCTAssertNil(GuidesSheetLogic.index(ofGuide: 42, in: after))
    }

    func testAReloadNeverRewritesAnActiveFieldEdit() {
        XCTAssertTrue(GuidesSheetLogic.shouldRewritePositionField(isEditing: false))
        XCTAssertFalse(GuidesSheetLogic.shouldRewritePositionField(isEditing: true))
    }

    // MARK: Cached Show Guides menu state

    func testShowGuidesDefaultsToOnAndTogglesAsPureViewState() {
        var state = GuideViewState()
        XCTAssertTrue(state.showsGuides, "Show Guides defaults to checked")
        XCTAssertEqual(state.menuState, .on)
        state.toggle()
        XCTAssertFalse(state.showsGuides)
        XCTAssertEqual(state.menuState, .off)
        state.toggle()
        XCTAssertTrue(state.showsGuides)
        XCTAssertEqual(state.menuState, .on)
    }

    // MARK: Overlay geometry (image pixels to view points)

    func testHorizontalGuideSpansTheImageWidthAtItsY() {
        // 40x24 image at 100% on a 2x screen: 0.5 view points per image pixel.
        let line = CanvasGeometry.guideLineEndpoints(orientation: .horizontal, position: 10,
                                                     imageSize: CGSize(width: 40, height: 24),
                                                     zoomPercent: 100, backingFactor: 2)
        XCTAssertEqual(line?.0, CGPoint(x: 0, y: 5))
        XCTAssertEqual(line?.1, CGPoint(x: 20, y: 5))
    }

    func testVerticalGuideSpansTheImageHeightAtItsX() {
        let line = CanvasGeometry.guideLineEndpoints(orientation: .vertical, position: 40,
                                                     imageSize: CGSize(width: 40, height: 24),
                                                     zoomPercent: 100, backingFactor: 2)
        XCTAssertEqual(line?.0, CGPoint(x: 20, y: 0))
        XCTAssertEqual(line?.1, CGPoint(x: 20, y: 12))
    }

    func testGuideAtTheInclusiveEdgeStillDrawsInsideTheImage() {
        // Position == extent is valid (inclusive range): the line sits on
        // the image boundary and stays inside.
        let horizontal = CanvasGeometry.guideLineEndpoints(orientation: .horizontal, position: 24,
                                                           imageSize: CGSize(width: 40, height: 24),
                                                           zoomPercent: 100, backingFactor: 2)
        XCTAssertEqual(horizontal?.0.y, 12)
        XCTAssertEqual(horizontal?.1.y, 12)
        // Beyond the extent the overlay clips the line away.
        XCTAssertNil(CanvasGeometry.guideLineEndpoints(orientation: .horizontal, position: 25,
                                                       imageSize: CGSize(width: 40, height: 24),
                                                       zoomPercent: 100, backingFactor: 2))
        XCTAssertNil(CanvasGeometry.guideLineEndpoints(orientation: .vertical, position: 41,
                                                       imageSize: CGSize(width: 40, height: 24),
                                                       zoomPercent: 100, backingFactor: 2))
    }

    func testGuideLinesFollowZoomAndBackingLikeAnyOverlay() {
        let size = CGSize(width: 40, height: 24)
        let at100x1 = CanvasGeometry.guideLineEndpoints(orientation: .vertical, position: 8,
                                                         imageSize: size, zoomPercent: 100, backingFactor: 1)
        XCTAssertEqual(at100x1?.0, CGPoint(x: 8, y: 0))
        XCTAssertEqual(at100x1?.1, CGPoint(x: 8, y: 24))
        let at200x2 = CanvasGeometry.guideLineEndpoints(orientation: .vertical, position: 8,
                                                         imageSize: size, zoomPercent: 200, backingFactor: 2)
        XCTAssertEqual(at200x2?.0.x ?? -1, at100x1?.0.x ?? -2, accuracy: Self.accuracy)
        XCTAssertEqual(at200x2?.1.y ?? -1, at100x1?.1.y ?? -2, accuracy: Self.accuracy)
        // viewPoint is the exact inverse of imagePoint used for input.
        let image = CGPoint(x: 8, y: 12)
        let view = CanvasGeometry.viewPoint(imagePoint: image, zoomPercent: 100, backingFactor: 2)
        let back = CanvasGeometry.imagePoint(viewPoint: view, zoomPercent: 100, backingFactor: 2)
        XCTAssertEqual(back.x, image.x, accuracy: Self.accuracy)
        XCTAssertEqual(back.y, image.y, accuracy: Self.accuracy)
    }
}
