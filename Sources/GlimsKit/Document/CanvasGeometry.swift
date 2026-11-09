import CoreGraphics

/// Pure geometry for the engine canvas: how a zoom percent maps image
/// pixels to device pixels and view points, where tiles fall in the
/// rendered image, and the scroll offset that keeps an image pixel under
/// the viewport centre when the window's backing factor changes.
///
/// Zoom percents count physical pixels: at 100% one image pixel is one
/// device pixel on any screen. The render scale (device pixels per image
/// pixel) is therefore the percent alone, while view points also divide
/// by the window's backing factor.
enum CanvasGeometry {
    /// Device pixels per image pixel at `zoomPercent`. Backing-independent,
    /// so the same zoom renders the same tiles on every screen.
    static func renderScale(zoomPercent: Int) -> Double {
        Double(zoomPercent) / 100
    }

    /// View points per image pixel at `zoomPercent` on a screen with
    /// `backingFactor` device pixels per point.
    static func pointScale(zoomPercent: Int, backingFactor: Double) -> Double {
        renderScale(zoomPercent: zoomPercent) / backingFactor
    }

    /// The image's size in device pixels at `zoomPercent`, rounded up to
    /// whole pixels so the last pixel row and column render.
    static func renderedImageSize(imageSize: CGSize, zoomPercent: Int) -> CGSize {
        let scale = renderScale(zoomPercent: zoomPercent)
        return CGSize(width: (imageSize.width * scale).rounded(.up),
                      height: (imageSize.height * scale).rounded(.up))
    }

    /// The canvas frame's size in view points.
    static func viewSize(imageSize: CGSize, zoomPercent: Int, backingFactor: Double) -> CGSize {
        let rendered = renderedImageSize(imageSize: imageSize, zoomPercent: zoomPercent)
        return CGSize(width: rendered.width / backingFactor, height: rendered.height / backingFactor)
    }

    /// A tile's rect in device pixels, clipped to the rendered image so
    /// edge tiles end at the image boundary.
    static func tileRect(column: Int, row: Int, tileSize: Int, renderedImageSize: CGSize) -> CGRect {
        let side = Double(tileSize)
        let full = CGRect(x: Double(column) * side, y: Double(row) * side, width: side, height: side)
        return full.intersection(CGRect(origin: .zero, size: renderedImageSize))
    }

    /// The same rect in view points.
    static func viewRect(renderRect: CGRect, backingFactor: Double) -> CGRect {
        CGRect(x: renderRect.minX / backingFactor, y: renderRect.minY / backingFactor,
               width: renderRect.width / backingFactor, height: renderRect.height / backingFactor)
    }

    /// The image pixel under a view point.
    static func imagePoint(viewPoint: CGPoint, zoomPercent: Int, backingFactor: Double) -> CGPoint {
        let scale = pointScale(zoomPercent: zoomPercent, backingFactor: backingFactor)
        // Affine view conversion can return 11.99999999999999 for an
        // exact pixel edge. Preserve genuine subpixel input, but remove
        // numerical noise before native selections expand fractional bounds.
        func stable(_ value: Double) -> Double {
            let integer = value.rounded()
            return abs(value - integer) < 1e-7 ? integer : value
        }
        return CGPoint(x: stable(viewPoint.x / scale), y: stable(viewPoint.y / scale))
    }

    /// The inverse: where an image pixel lands in view points.
    static func viewPoint(imagePoint: CGPoint, zoomPercent: Int, backingFactor: Double) -> CGPoint {
        let scale = pointScale(zoomPercent: zoomPercent, backingFactor: backingFactor)
        return CGPoint(x: imagePoint.x * scale, y: imagePoint.y * scale)
    }

    /// The displayed image's rect in view points, at the origin.
    static func imageViewRect(imageSize: CGSize, zoomPercent: Int, backingFactor: Double) -> CGRect {
        let scale = pointScale(zoomPercent: zoomPercent, backingFactor: backingFactor)
        return CGRect(origin: .zero,
                      size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale))
    }

    /// One guide's line in view coordinates, clipped to the displayed
    /// image: a horizontal guide (position on the y axis) spans the image's
    /// full width at y = position × scale; a vertical one (position on the
    /// x axis) spans the full height at x = position × scale. Nil when the
    /// position lies outside the displayed image.
    static func guideLineEndpoints(orientation: EngineSession.GuideOrientation, position: Int32,
                                   imageSize: CGSize, zoomPercent: Int, backingFactor: Double) -> (CGPoint, CGPoint)? {
        let scale = pointScale(zoomPercent: zoomPercent, backingFactor: backingFactor)
        let image = imageViewRect(imageSize: imageSize, zoomPercent: zoomPercent, backingFactor: backingFactor)
        switch orientation {
        case .horizontal:
            let y = Double(position) * scale
            guard y >= image.minY && y <= image.maxY else { return nil }
            return (CGPoint(x: image.minX, y: y), CGPoint(x: image.maxX, y: y))
        case .vertical:
            let x = Double(position) * scale
            guard x >= image.minX && x <= image.maxX else { return nil }
            return (CGPoint(x: x, y: image.minY), CGPoint(x: x, y: image.maxY))
        }
    }

    /// The image pixel under the viewport centre, given the clip view's
    /// bounds (`scrollOffset` and `viewportSize`, both in view points).
    static func imageCenter(scrollOffset: CGPoint, viewportSize: CGSize,
                            zoomPercent: Int, backingFactor: Double) -> CGPoint {
        let scale = pointScale(zoomPercent: zoomPercent, backingFactor: backingFactor)
        return CGPoint(x: (scrollOffset.x + viewportSize.width / 2) / scale,
                       y: (scrollOffset.y + viewportSize.height / 2) / scale)
    }

    /// The scroll offset that puts `imageCenter` back under the viewport
    /// centre, clamped to what a `canvasSize` document can scroll to.
    static func scrollOffset(preservingImageCenter imageCenter: CGPoint, viewportSize: CGSize,
                             canvasSize: CGSize, zoomPercent: Int, backingFactor: Double) -> CGPoint {
        let scale = pointScale(zoomPercent: zoomPercent, backingFactor: backingFactor)
        return CGPoint(x: clamped(imageCenter.x * scale - viewportSize.width / 2,
                                  extent: canvasSize.width, viewport: viewportSize.width),
                       y: clamped(imageCenter.y * scale - viewportSize.height / 2,
                                  extent: canvasSize.height, viewport: viewportSize.height))
    }

    /// Clamps one axis of a scroll offset: never before the canvas's start,
    /// and never past its end; a canvas shorter than the viewport stays
    /// pinned at zero.
    private static func clamped(_ offset: Double, extent: Double, viewport: Double) -> Double {
        min(max(offset, 0), max(0, extent - viewport))
    }
}
