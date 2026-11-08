import AppKit
import XCTest
@testable import GlimsKit

/// Print geometry, the File menu's printing items and the printed
/// page's own drawing — all without an engine.
@MainActor
final class PrintingTests: XCTestCase {
    /// A premultiplied sRGB CGImage from RGBA bytes.
    private func image(_ pixels: [UInt8], width: Int, height: Int) -> CGImage {
        CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: CGDataProvider(data: NSData(bytes: pixels, length: pixels.count))!,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    private func configuredPrintInfo() -> NSPrintInfo {
        let info = NSPrintInfo()
        info.paperSize = CGSize(width: 612, height: 792)
        return info
    }

    /// US Letter with half-inch margins is 540×720 pt; a 2:1 image fits
    /// to width and gets 300 dpi worth of pixels.
    func testSnapshotSizeFitsThePageAt300dpi() {
        let size = PrintGeometry.snapshotSize(imagePixels: CGSize(width: 1000, height: 500),
                                              imageablePoints: CGSize(width: 540, height: 720))
        XCTAssertEqual(size, CGSize(width: 2250, height: 1125))
    }

    /// The fit uses the tighter side; a tall image fits to height.
    func testSnapshotSizeFitsByTheTighterSide() {
        let size = PrintGeometry.snapshotSize(imagePixels: CGSize(width: 200, height: 1000),
                                              imageablePoints: CGSize(width: 540, height: 720))
        XCTAssertEqual(size.height, 3000)
        XCTAssertEqual(size.width, 600)
    }

    /// On oversized paper the pixel caps bind instead: dimension and
    /// total pixels stay inside them, the aspect survives.
    func testSnapshotSizeCapsPixelsInsteadOfAllocating() {
        let size = PrintGeometry.snapshotSize(imagePixels: CGSize(width: 40_000, height: 20_000),
                                              imageablePoints: CGSize(width: 40_000, height: 20_000),
                                              maximumDimension: 4000, maximumPixels: 6_000_000)
        XCTAssertLessThanOrEqual(size.width, 4000)
        XCTAssertLessThanOrEqual(size.height, 4000)
        XCTAssertLessThanOrEqual(size.width * size.height, 6_000_000)
        XCTAssertEqual(size.width / size.height, 2, accuracy: 0.01)
    }

    /// Degenerate inputs still produce a renderable size.
    func testSnapshotSizeNeverReturnsZero() {
        XCTAssertEqual(PrintGeometry.snapshotSize(imagePixels: CGSize(width: 0, height: 0),
                                                  imageablePoints: CGSize(width: 540, height: 720)),
                       CGSize(width: 1, height: 1))
        XCTAssertEqual(PrintGeometry.snapshotSize(imagePixels: CGSize(width: 10, height: 10),
                                                  imageablePoints: .zero),
                       CGSize(width: 1, height: 1))
    }

    /// Placement is the largest aspect-preserving fit, centered in the
    /// imageable area.
    func testPlacementCentersTheImage() {
        let placed = PrintGeometry.placement(imageSize: CGSize(width: 200, height: 100),
                                             in: CGRect(x: 10, y: 20, width: 300, height: 300))
        XCTAssertEqual(placed.size, CGSize(width: 300, height: 150))
        XCTAssertEqual(placed.midX, 160)
        XCTAssertEqual(placed.midY, 170)
    }

    /// Render bands stay under the per-call pixel bound.
    func testStripeHeightBoundsEachEngineCall() {
        XCTAssertEqual(PrintGeometry.stripeHeight(forWidth: 100), 1024)
        XCTAssertEqual(PrintGeometry.stripeHeight(forWidth: 5000), 200)
        XCTAssertEqual(PrintGeometry.stripeHeight(forWidth: 5_000_000), 1)
    }

    /// The File menu carries both commands on the document controller's
    /// own selectors — no standard names like printDocument:, which
    /// AppKit's responder routing would answer somewhere else (the
    /// showHelp: interception lesson).
    func testFileMenuOffersPrintingOnUniqueSelectors() throws {
        let file = try XCTUnwrap(MainMenu.make().items.first { $0.title == "File" }?.submenu)
        let setup = try XCTUnwrap(file.items.first { $0.title == "Page Setup…" })
        let print = try XCTUnwrap(file.items.first { $0.title == "Print…" })
        XCTAssertEqual(setup.action, #selector(DocumentWindowController.runGlimsPageSetup(_:)))
        XCTAssertEqual(setup.keyEquivalent, "P", "Page Setup keeps Shift-Command-P")
        XCTAssertEqual(print.action, #selector(DocumentWindowController.printGlimsImage(_:)))
        XCTAssertEqual(print.keyEquivalent, "p", "Print keeps Command-P")
        for action in [setup.action!, print.action!] {
            XCTAssertFalse(NSApplication.shared.responds(to: action),
                           "\(action) must not collide with a standard responder")
        }
    }

    /// The print view is exactly the imageable area on one page, and its
    /// own drawing puts the snapshot over white paper — margins and
    /// transparent pixels alike — with the image centered.
    func testPrintViewDrawsSnapshotOverWhitePaper() throws {
        // 4×1 pixels: red opaque, green opaque, transparent, transparent.
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0]
        let snapshot = PrintSnapshot(image: image(pixels, width: 4, height: 1),
                                     pixelSize: CGSize(width: 40, height: 10), scale: 4)
        let info = configuredPrintInfo()
        let view = ImagePrintView(snapshot: snapshot, printInfo: info, title: "Doc")
        XCTAssertEqual(view.frame.size, info.imageablePageBounds.size)
        var range = NSRange()
        XCTAssertTrue(view.knowsPageRange(&range))
        XCTAssertEqual(range, NSRange(location: 1, length: 1))
        XCTAssertEqual(view.rectForPage(1), view.bounds)

        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let factor = Double(rep.pixelsWide) / view.bounds.width
        func color(atX x: Double, y: Double) -> NSColor? {
            rep.colorAt(x: Int(x * factor), y: Int(y * factor))?.usingColorSpace(.sRGB)
        }
        // A point past the image rect stays paper white.
        let margin = try XCTUnwrap(color(atX: 2, y: 2))
        XCTAssertEqual(margin.redComponent, 1, accuracy: 0.01)
        // Centered in the view: the first pixel's center prints red, a
        // transparent pixel's center prints as white paper.
        let imageRect = view.imageRect
        XCTAssertGreaterThan(imageRect.width, 100)
        let red = try XCTUnwrap(color(atX: imageRect.minX + imageRect.width * 0.125,
                                      y: imageRect.midY))
        XCTAssertEqual(red.redComponent, 1, accuracy: 0.05)
        XCTAssertLessThan(red.greenComponent, 0.2)
        let paper = try XCTUnwrap(color(atX: imageRect.minX + imageRect.width * 0.875,
                                        y: imageRect.midY))
        XCTAssertEqual(paper.redComponent, 1, accuracy: 0.05)
    }
}
