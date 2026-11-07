import CoreGraphics
import XCTest
@testable import GlimsKit

/// Deterministic tests of the canvas geometry: zoom percents count device
/// pixels, view points divide by the backing factor, odd image sizes round
/// up in device pixels, and a backing change keeps the image pixel under
/// the viewport centre within the scrollable range.
final class CanvasGeometryTests: XCTestCase {
    private static let accuracy = 1e-9

    // MARK: Zoom, point and device mapping at 1x and 2x

    func testRenderScaleIsThePercentAloneWhateverTheBacking() {
        XCTAssertEqual(CanvasGeometry.renderScale(zoomPercent: 100), 1, accuracy: Self.accuracy)
        XCTAssertEqual(CanvasGeometry.renderScale(zoomPercent: 200), 2, accuracy: Self.accuracy)
        XCTAssertEqual(CanvasGeometry.renderScale(zoomPercent: 33), 0.33, accuracy: Self.accuracy)
    }

    func testPointScaleDividesTheRenderScaleByTheBackingFactor() {
        XCTAssertEqual(CanvasGeometry.pointScale(zoomPercent: 100, backingFactor: 1), 1, accuracy: Self.accuracy)
        XCTAssertEqual(CanvasGeometry.pointScale(zoomPercent: 100, backingFactor: 2), 0.5, accuracy: Self.accuracy)
        XCTAssertEqual(CanvasGeometry.pointScale(zoomPercent: 200, backingFactor: 2), 1, accuracy: Self.accuracy)
        XCTAssertEqual(CanvasGeometry.pointScale(zoomPercent: 33, backingFactor: 2), 0.165, accuracy: Self.accuracy)
    }

    func testViewPointsMapToImagePixelsAtOneAndTwoX() {
        let view = CGPoint(x: 30, y: 40)
        XCTAssertEqual(CanvasGeometry.imagePoint(viewPoint: view, zoomPercent: 100, backingFactor: 1),
                       CGPoint(x: 30, y: 40))
        // 2x at 100%: one point spans two image pixels.
        XCTAssertEqual(CanvasGeometry.imagePoint(viewPoint: view, zoomPercent: 100, backingFactor: 2),
                       CGPoint(x: 60, y: 80))
        // 2x at 200%: two device pixels per image pixel cancel the backing.
        XCTAssertEqual(CanvasGeometry.imagePoint(viewPoint: view, zoomPercent: 200, backingFactor: 2),
                       CGPoint(x: 30, y: 40))
    }

    func testImageAndViewPointsRoundTripAtAnyZoomAndBacking() {
        for zoom in [5, 33, 100, 150, 3200] {
            for backing in [1.0, 2.0] {
                let image = CGPoint(x: 123.5, y: 87.25)
                let scale = CanvasGeometry.pointScale(zoomPercent: zoom, backingFactor: backing)
                let back = CanvasGeometry.imagePoint(viewPoint: CGPoint(x: image.x * scale, y: image.y * scale),
                                                     zoomPercent: zoom, backingFactor: backing)
                XCTAssertEqual(back.x, image.x, accuracy: Self.accuracy, "zoom \(zoom) at \(backing)x")
                XCTAssertEqual(back.y, image.y, accuracy: Self.accuracy, "zoom \(zoom) at \(backing)x")
            }
        }
    }

    func testViewRectsMapDeviceRectsIntoPoints() {
        XCTAssertEqual(CanvasGeometry.viewRect(renderRect: CGRect(x: 256, y: 256, width: 44, height: 244),
                                               backingFactor: 2),
                       CGRect(x: 128, y: 128, width: 22, height: 122))
        XCTAssertEqual(CanvasGeometry.viewRect(renderRect: CGRect(x: 0, y: 0, width: 256, height: 256),
                                               backingFactor: 1),
                       CGRect(x: 0, y: 0, width: 256, height: 256))
    }

    // MARK: Odd image dimensions

    func testOddImageSizesRoundUpInDevicePixelsAndKeepFractionalPoints() {
        let size = CGSize(width: 3, height: 5)
        XCTAssertEqual(CanvasGeometry.renderedImageSize(imageSize: size, zoomPercent: 100),
                       CGSize(width: 3, height: 5))
        XCTAssertEqual(CanvasGeometry.renderedImageSize(imageSize: size, zoomPercent: 200),
                       CGSize(width: 6, height: 10))
        // 3 × 0.33 = 0.99 and 5 × 0.33 = 1.65 device pixels: rounded up so
        // the last partial pixel still renders.
        XCTAssertEqual(CanvasGeometry.renderedImageSize(imageSize: size, zoomPercent: 33),
                       CGSize(width: 1, height: 2))
        XCTAssertEqual(CanvasGeometry.viewSize(imageSize: size, zoomPercent: 100, backingFactor: 1),
                       CGSize(width: 3, height: 5))
        // A 2x screen shows the same pixels at half the points, exactly.
        XCTAssertEqual(CanvasGeometry.viewSize(imageSize: size, zoomPercent: 100, backingFactor: 2),
                       CGSize(width: 1.5, height: 2.5))
        XCTAssertEqual(CanvasGeometry.viewSize(imageSize: size, zoomPercent: 33, backingFactor: 2),
                       CGSize(width: 0.5, height: 1))
    }

    func testTileRectsClipToTheRenderedImage() {
        let rendered = CGSize(width: 300, height: 500)
        XCTAssertEqual(CanvasGeometry.tileRect(column: 0, row: 0, tileSize: 256, renderedImageSize: rendered),
                       CGRect(x: 0, y: 0, width: 256, height: 256))
        XCTAssertEqual(CanvasGeometry.tileRect(column: 1, row: 0, tileSize: 256, renderedImageSize: rendered),
                       CGRect(x: 256, y: 0, width: 44, height: 256))
        XCTAssertEqual(CanvasGeometry.tileRect(column: 0, row: 1, tileSize: 256, renderedImageSize: rendered),
                       CGRect(x: 0, y: 256, width: 256, height: 244))
        XCTAssertEqual(CanvasGeometry.tileRect(column: 1, row: 1, tileSize: 256, renderedImageSize: rendered),
                       CGRect(x: 256, y: 256, width: 44, height: 244))
        // Past the image: no tile at all.
        XCTAssertTrue(CanvasGeometry.tileRect(column: 2, row: 1, tileSize: 256, renderedImageSize: rendered).isNull)
        XCTAssertTrue(CanvasGeometry.tileRect(column: 1, row: 2, tileSize: 256, renderedImageSize: rendered).isNull)
        // A 3 × 5 image is one tile, edge to edge.
        XCTAssertEqual(CanvasGeometry.tileRect(column: 0, row: 0, tileSize: 256,
                                               renderedImageSize: CGSize(width: 3, height: 5)),
                       CGRect(x: 0, y: 0, width: 3, height: 5))
    }

    // MARK: Centre math across backing changes

    func testImageCenterReadsTheImagePixelUnderTheViewportCentre() {
        XCTAssertEqual(CanvasGeometry.imageCenter(scrollOffset: CGPoint(x: 300, y: 200),
                                                  viewportSize: CGSize(width: 400, height: 300),
                                                  zoomPercent: 100, backingFactor: 1),
                       CGPoint(x: 500, y: 350))
        // 2x: the same points span twice the image pixels.
        XCTAssertEqual(CanvasGeometry.imageCenter(scrollOffset: CGPoint(x: 300, y: 200),
                                                  viewportSize: CGSize(width: 400, height: 300),
                                                  zoomPercent: 100, backingFactor: 2),
                       CGPoint(x: 1000, y: 700))
    }

    func testScrollOffsetPutsTheCentrePixelBackUnderTheCentre() {
        let viewport = CGSize(width: 400, height: 300)
        // A 1500 × 1100 image at 100% on a 2x screen is 750 × 550 points.
        let center = CGPoint(x: 500, y: 350)
        let offset = CanvasGeometry.scrollOffset(preservingImageCenter: center, viewportSize: viewport,
                                                 canvasSize: CGSize(width: 750, height: 550),
                                                 zoomPercent: 100, backingFactor: 2)
        XCTAssertEqual(offset, CGPoint(x: 50, y: 25))
        // Round trip: the same pixel sits at the centre again.
        XCTAssertEqual(CanvasGeometry.imageCenter(scrollOffset: offset, viewportSize: viewport,
                                                  zoomPercent: 100, backingFactor: 2),
                       center)
    }

    func testScrollOffsetPreservesTheCentreAcrossABackingChange() {
        let viewport = CGSize(width: 400, height: 300)
        let oldCenter = CanvasGeometry.imageCenter(scrollOffset: CGPoint(x: 300, y: 200),
                                                   viewportSize: viewport,
                                                   zoomPercent: 100, backingFactor: 1)
        // The window moves to a 2x screen keeping the zoom percent: the
        // canvas halves in points (1500 × 1100 image → 750 × 550).
        let offset = CanvasGeometry.scrollOffset(preservingImageCenter: oldCenter, viewportSize: viewport,
                                                 canvasSize: CGSize(width: 750, height: 550),
                                                 zoomPercent: 100, backingFactor: 2)
        XCTAssertEqual(oldCenter, CGPoint(x: 500, y: 350))
        XCTAssertEqual(offset, CGPoint(x: 50, y: 25))
    }

    func testScrollOffsetClampsToTheScrollableRange() {
        let viewport = CGSize(width: 400, height: 300)
        // A 250 × 250 point canvas is smaller than the viewport: pinned at zero.
        XCTAssertEqual(CanvasGeometry.scrollOffset(preservingImageCenter: CGPoint(x: 200, y: 200),
                                                   viewportSize: viewport,
                                                   canvasSize: CGSize(width: 250, height: 250),
                                                   zoomPercent: 100, backingFactor: 2),
                       .zero)
        // Centres outside the canvas clamp to its edges, never past them.
        XCTAssertEqual(CanvasGeometry.scrollOffset(preservingImageCenter: CGPoint(x: 5000, y: -50),
                                                   viewportSize: viewport,
                                                   canvasSize: CGSize(width: 750, height: 550),
                                                   zoomPercent: 100, backingFactor: 2),
                       CGPoint(x: 350, y: 0))
    }
}
