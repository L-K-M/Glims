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
    /// The print info the job was created with. The operation copies it,
    /// and the panel can change that copy — paper, orientation or
    /// printer — so the imageable area the job finally prints may not
    /// be the one this view was built with.
    private let printInfo: NSPrintInfo
    /// Where the image lands, in bounds coordinates, aspect preserved.
    private(set) var imageRect: CGRect

    init(snapshot: PrintSnapshot, printInfo: NSPrintInfo, title: String) {
        self.snapshot = snapshot
        self.printInfo = printInfo
        self.imageRect = .zero
        super.init(frame: .zero)
        refit()
        setAccessibilityRole(.image)
        setAccessibilityLabel("\(title), printed page")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Fits the frame and image rect to the imageable area the job
    /// currently uses: the running operation's own print info wins once
    /// the job starts, so a paper, orientation or printer change made
    /// in the panel is honored. A no-op when nothing changed; without an
    /// operation the print info the view was built with stands.
    private func refit() {
        let imageable = (NSPrintOperation.current?.printInfo ?? printInfo).imageablePageBounds
        frame = NSRect(origin: imageable.origin, size: imageable.size)
        imageRect = PrintGeometry.placement(imageSize: snapshot.pixelSize,
                                            in: CGRect(origin: .zero, size: imageable.size))
    }

    /// Always one page: the view is exactly the imageable area.
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        refit()
        range.pointee = NSRange(location: 1, length: 1)
        return true
    }

    override func rectForPage(_ page: Int) -> NSRect {
        refit()
        return bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        refit()
        NSColor.white.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .high
        context.draw(snapshot.image, in: imageRect)
    }
}
