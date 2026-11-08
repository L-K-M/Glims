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

    /// The engine rejects render scales above 32, so a tiny image must
    /// get a smaller snapshot instead of a refusal: a 64-pixel image
    /// asks for 2048 pixels, and a single pixel for 32.
    func testSnapshotSizeStaysUnderTheRenderScaleCap() {
        let size = PrintGeometry.snapshotSize(imagePixels: CGSize(width: 64, height: 64),
                                              imageablePoints: CGSize(width: 540, height: 720))
        XCTAssertEqual(size, CGSize(width: 2048, height: 2048))
        XCTAssertEqual(PrintGeometry.snapshotSize(imagePixels: CGSize(width: 1, height: 1),
                                                  imageablePoints: CGSize(width: 540, height: 720)),
                       CGSize(width: 32, height: 32))
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

    /// The print panel can change paper, orientation or printer after
    /// the view was built; its imageable area moves with it. The view
    /// must re-fit to the print info the operation finally uses instead
    /// of drawing the geometry frozen at Print time.
    func testPrintViewRefitsToTheOperationsPrintInfo() throws {
        // A 4:1 snapshot fills the imageable width at a quarter of its
        // height; its placement visibly differs between the two paper
        // sizes used here.
        let pixels: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                               0, 0, 255, 255, 255, 0, 255, 255]
        let snapshot = PrintSnapshot(image: image(pixels, width: 4, height: 1),
                                     pixelSize: CGSize(width: 400, height: 100), scale: 1)
        let info = configuredPrintInfo()
        let view = ImagePrintView(snapshot: snapshot, printInfo: info, title: "Doc")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("glims-print-refit-\(ProcessInfo.processInfo.processIdentifier).pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let operation = NSPrintOperation(view: view, printInfo: info)
        // The panel's effect on the operation's own print info.
        operation.printInfo.paperSize = CGSize(width: 396, height: 612)
        operation.printInfo.jobDisposition = .save
        operation.printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        XCTAssertTrue(operation.run())

        let imageable = operation.printInfo.imageablePageBounds
        XCTAssertEqual(view.bounds.size, imageable.size,
                       "the view re-fits to the operation's final imageable area")
        let expected = PrintGeometry.placement(imageSize: snapshot.pixelSize,
                                               in: CGRect(origin: .zero, size: imageable.size))
        XCTAssertEqual(view.imageRect, expected)

        // The rasterized page: the printed image extent has the image
        // rect's size, not the one computed for the earlier print info.
        let extent = try XCTUnwrap(coloredExtent(in: url))
        XCTAssertEqual(extent.width, expected.width, accuracy: 6)
        XCTAssertEqual(extent.height, expected.height, accuracy: 6)
    }

    /// The bounds of non-white pixels in a PDF's first page, in media
    /// coordinates (y up).
    private func coloredExtent(in url: URL) throws -> CGRect? {
        guard let pdf = CGPDFDocument(url as CFURL), let page = pdf.page(at: 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        let scale = 0.5
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let raster = CGContext(data: nil, width: width, height: height,
                                     bitsPerComponent: 8, bytesPerRow: width * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue)
        else { return nil }
        raster.scaleBy(x: scale, y: scale)
        raster.drawPDFPage(page)
        guard let rendered = raster.makeImage(),
              let data = rendered.dataProvider?.data as Data? else { return nil }
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * rendered.bytesPerRow + x * 4
                guard offset + 2 < data.count,
                      data[offset] < 240 || data[offset + 1] < 240 || data[offset + 2] < 240
                else { continue }
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= 0 else { return nil }
        return CGRect(x: Double(minX) / scale, y: Double(height - 1 - maxY) / scale,
                      width: Double(maxX - minX + 1) / scale,
                      height: Double(maxY - minY + 1) / scale)
    }
}
