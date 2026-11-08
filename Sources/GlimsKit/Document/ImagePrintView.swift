import AppKit

/// An image rendered once for printing: premultiplied sRGB pixels sized
/// for the page. Immutable — the document may keep changing after it is
/// made, and the printed page still shows the state Print was chosen at.
struct PrintSnapshot {
    /// The composite, row 0 at the top, premultiplied over transparent.
    let image: CGImage
    /// The rendered pixel dimensions (`image`'s size).
    let pixelSize: CGSize
    /// Output pixels rendered per image pixel.
    let scale: Double
}

enum PrintSnapshotError: LocalizedError {
    case bitmapUnavailable
    var errorDescription: String? { "The page image could not be assembled." }
}

extension PrintSnapshot {
    /// Renders `pixelSize` of the composite in horizontal bands, so a
    /// single engine call never covers a whole large page. `scale` maps
    /// image pixels to output pixels. Runs on the caller's queue.
    static func render(session: EngineSession, image: Int32, scale: Double,
                       pixelSize: CGSize) throws -> PrintSnapshot {
        let width = max(1, Int(pixelSize.width.rounded()))
        let height = max(1, Int(pixelSize.height.rounded()))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: space,
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue)
        else { throw PrintSnapshotError.bitmapUnavailable }
        var row = 0
        let stripe = PrintGeometry.stripeHeight(forWidth: width)
        while row < height {
            let band = min(stripe, height - row)
            let rendered = try session.render(image, scale: scale,
                                              area: CGRect(x: 0, y: row, width: width, height: band))
            // The bitmap context is y-up: the top band sits at its bottom.
            context.draw(rendered, in: CGRect(x: 0, y: height - row - band,
                                              width: width, height: band))
            row += band
        }
        guard let composite = context.makeImage() else { throw PrintSnapshotError.bitmapUnavailable }
        return PrintSnapshot(image: composite, pixelSize: CGSize(width: width, height: height), scale: scale)
    }
}

/// One printed page: the immutable snapshot fitted into the print job's
/// imageable area over white paper, so transparent pixels print as
/// paper. The standard panel's preview, the PDF facilities and the
/// printer all draw this same view. It touches nothing but the
/// snapshot, so the printing thread can draw it safely.
final class ImagePrintView: NSView {
    let snapshot: PrintSnapshot
    /// Where the image lands, in bounds coordinates, aspect preserved.
    let imageRect: CGRect

    init(snapshot: PrintSnapshot, printInfo: NSPrintInfo, title: String) {
        self.snapshot = snapshot
        let imageable = printInfo.imageablePageBounds
        // The view is exactly the imageable area; printing places a
        // bounds-filling rect on the sheet's printable rect itself.
        imageRect = PrintGeometry.placement(imageSize: snapshot.pixelSize,
                                            in: CGRect(origin: .zero, size: imageable.size))
        super.init(frame: NSRect(origin: imageable.origin, size: imageable.size))
        setAccessibilityRole(.image)
        setAccessibilityLabel("\(title), printed page")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Always one page: the view is exactly the imageable area.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect { bounds }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(snapshot.image, in: imageRect)
    }
}
