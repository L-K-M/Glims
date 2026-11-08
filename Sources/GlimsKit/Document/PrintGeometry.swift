import Foundation

/// Page geometry for printing: how many pixels the print snapshot gets,
/// where the image lands in the imageable area, and how tall a band a
/// single engine render call may cover.
enum PrintGeometry {
    /// The resolution the snapshot aims for.
    static let defaultDPI = 300.0
    /// No rendered edge exceeds this, whatever the paper size.
    static let maximumDimension = 8192
    /// Total snapshot pixels stay under this (about 128 MB of RGBA):
    /// on larger paper the effective resolution drops instead of the
    /// allocation growing without bound.
    static let maximumPixels = 32_000_000
    /// One engine render call covers at most this many pixels; larger
    /// snapshots are asked for in bands so other work gets engine turns.
    static let maximumStripePixels = 1_000_000

    /// The snapshot's pixel size: the image fitted into the imageable
    /// area at `dpi`, then shrunk uniformly until the caps hold. The
    /// image's aspect ratio is kept exactly.
    static func snapshotSize(imagePixels: CGSize, imageablePoints: CGSize,
                             dpi: Double = defaultDPI,
                             maximumDimension: Int = Self.maximumDimension,
                             maximumPixels: Int = Self.maximumPixels) -> CGSize {
        guard imagePixels.width >= 1, imagePixels.height >= 1,
              imageablePoints.width > 0, imageablePoints.height > 0 else {
            return CGSize(width: 1, height: 1)
        }
        // Output pixels per image pixel: fit to the page (72 points per
        // inch), then ask for `dpi` pixels per printed inch.
        var scale = min(imageablePoints.width / imagePixels.width,
                        imageablePoints.height / imagePixels.height) * dpi / 72
        scale = min(scale,
                    Double(maximumDimension) / imagePixels.width,
                    Double(maximumDimension) / imagePixels.height,
                    (Double(maximumPixels) / (imagePixels.width * imagePixels.height)).squareRoot())
        return CGSize(width: max(1, Int(imagePixels.width * scale)),
                      height: max(1, Int(imagePixels.height * scale)))
    }

    /// The rect the image occupies inside an imageable area: the largest
    /// aspect-preserving fit, centered on the paper.
    static func placement(imageSize: CGSize, in imageable: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, !imageable.isEmpty else { return .zero }
        let scale = min(imageable.width / imageSize.width, imageable.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let origin = CGPoint(x: imageable.midX - size.width / 2,
                             y: imageable.midY - size.height / 2)
        return CGRect(origin: origin, size: size)
    }

    /// Rows per render band for a snapshot `width` pixels wide, bounded
    /// so a single engine call stays short even on a large page.
    static func stripeHeight(forWidth width: Int) -> Int {
        max(1, min(1024, maximumStripePixels / max(1, width)))
    }
}
