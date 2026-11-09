import AppKit
import CoreGraphics

/// View ▸ Show Selection Edges' cached per-window state. Pure view state,
/// ON by default: toggling hides or shows only the marching-ants outline
/// — never the native selection, its cached bounds/admission, the
/// floating-selection behavior or any painting/selection command — and
/// never makes an engine call, pixel, dirty-flag, history, export or
/// print change. Hiding also stops the ants timer through the canvas's
/// existing ticker gate.
struct SelectionEdgesViewState: Equatable {
    var showsSelectionEdges = true
    var menuState: NSControl.StateValue { showsSelectionEdges ? .on : .off }
    mutating func toggle() { showsSelectionEdges.toggle() }
}

/// View ▸ Show Layer Boundary's cached per-window state. Pure view state,
/// OFF by default: toggling changes only the dashed paint-target outline
/// the canvas draws — never image pixels, the file's dirty state, history,
/// selection, export or print.
struct LayerBoundaryViewState: Equatable {
    var showsLayerBoundary = false
    var menuState: NSControl.StateValue { showsLayerBoundary ? .on : .off }
    mutating func toggle() { showsLayerBoundary.toggle() }
}

/// Pure cached geometry behind View ▸ Show Layer Boundary: which rect, in
/// image pixels, the dashed outline shows for the current cached paint
/// target, and how that rect maps to view points. No AppKit state and no
/// engine call, so the rules are unit-testable without an engine.
enum LayerBoundaryGeometry {
    /// The cached paint target the boundary resolves from, mirroring
    /// `ImageDocument`'s private target: an ordinary or floating layer
    /// (a floating selection reports as its floating layer's id), an
    /// editing mask (carrying its owner layer), or a selected channel.
    enum Target: Equatable {
        case layer(Int32)
        case mask(layer: Int32)
        case channel(Int32)
    }

    /// A rect is displayable only with finite origin/extents and a
    /// positive area; anything else (a missing or degenerate cached
    /// bounds) clears the outline rather than showing a stale rect.
    static func isDisplayable(_ rect: CGRect) -> Bool {
        [rect.origin.x, rect.origin.y, rect.size.width, rect.size.height,
         rect.origin.x + rect.size.width, rect.origin.y + rect.size.height].allSatisfy(\.isFinite)
            && rect.size.width > 0 && rect.size.height > 0
    }

    /// The actual cached paint-target bounds in image pixels: an ordinary
    /// layer uses its own absolute bounds, a floating selection the
    /// floating layer's bounds (it is in the cached layer list), an
    /// editing mask the owner layer's bounds, and a channel the image
    /// bounds. Nil when no target is current or its cached bounds are
    /// missing or invalid — never a remembered unrelated layer's rect.
    static func boundaryRect(target: Target?, layers: [EngineSession.Layer],
                             imageSize: CGSize) -> CGRect? {
        guard let target else { return nil }
        switch target {
        case .layer(let id), .mask(let id):
            guard let bounds = layers.first(where: { $0.id == id })?.bounds else { return nil }
            return isDisplayable(bounds) ? bounds : nil
        case .channel:
            let image = CGRect(origin: .zero, size: imageSize)
            return isDisplayable(image) ? image : nil
        }
    }

    /// The boundary rect in view points at the given zoom and backing
    /// factor, through the canvas's own point scale (the view is flipped
    /// like the bitmap, so y is never mirrored).
    static func viewRect(for boundary: CGRect, zoomPercent: Int, backingFactor: Double) -> CGRect {
        let scale = CanvasGeometry.pointScale(zoomPercent: zoomPercent, backingFactor: backingFactor)
        return CGRect(x: boundary.minX * scale, y: boundary.minY * scale,
                      width: boundary.width * scale, height: boundary.height * scale)
    }

    /// Put a one-pixel outline inside device-pixel edges. Integral image
    /// edges otherwise place half the stroke outside the clipped canvas,
    /// and fractional zooms can spread it over two antialiased pixels.
    static func strokeRect(for viewRect: CGRect, backingFactor: Double) -> CGRect? {
        guard isDisplayable(viewRect), backingFactor.isFinite, backingFactor > 0 else { return nil }
        let device = viewRect.applying(CGAffineTransform(scaleX: backingFactor, y: backingFactor))
        guard isDisplayable(device) else { return nil }
        let aligned = device.integral.insetBy(dx: 0.5, dy: 0.5)
        return aligned.applying(CGAffineTransform(scaleX: 1 / backingFactor, y: 1 / backingFactor))
    }

    /// One physical (device) pixel in view points: the outline's line
    /// width and dash unit, so the stroke is exactly 1 physical pixel at
    /// every zoom and backing factor.
    static func deviceLineWidth(zoomPercent: Int, backingFactor: Double) -> Double {
        guard backingFactor.isFinite, backingFactor > 0 else { return 0 }
        return CanvasGeometry.pointScale(zoomPercent: zoomPercent, backingFactor: backingFactor)
            / CanvasGeometry.renderScale(zoomPercent: zoomPercent)
    }
}
