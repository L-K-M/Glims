import AppKit

/// View ▸ Show Rulers' cached per-window state. Pure view state: toggling
/// changes only what the scroll view's ruler slots draw — never a native
/// call, image pixels, the file's dirty state, history, selection, export
/// or print. Defaults to on, like the guides overlay.
struct RulerViewState {
    var showsRulers = true
    var menuState: NSControl.StateValue { showsRulers ? .on : .off }
    mutating func toggle() { showsRulers.toggle() }
}

/// The menu-validation contract for View ▸ Show Rulers, kept pure so tests
/// pin the semantics: the checkmark reads only the cached per-window state
/// and the item stays enabled wherever navigation is. `engineIsBusy` is an
/// explicit input that must never change the result — a display-only
/// toggle remains usable while the engine is busy.
enum RulerMenuLogic {
    static func validate(showsRulers: Bool, isClosing: Bool,
                         engineIsBusy: Bool) -> (enabled: Bool, state: NSControl.StateValue) {
        _ = engineIsBusy
        return (enabled: !isClosing, state: showsRulers ? .on : .off)
    }
}

/// One pixel ruler in an NSScrollView ruler slot, drawing ticks and numeric
/// labels in image pixels aligned with the image origin inside the canvas.
///
/// The ruler reads the canvas's live geometry at draw time and maps image
/// coordinates through `NSView.convert(_:from:)` from the canvas — never
/// by assuming a vertical direction — so scroll, zoom, backing scale, image
/// extent and any flip come out right. Drawing is display-only: it touches
/// the cached image size and the view scale, never the engine. Printing
/// draws an immutable PrintSnapshot, not this scroll view, so rulers cannot
/// leak into printed output.
@MainActor
final class PixelRulerView: NSRulerView {
    /// The rule area's thickness in points; the scroll view reserves this
    /// in its native ruler slot, which is what moves the viewport when the
    /// rulers toggle.
    static let ruleThicknessValue: CGFloat = 20
    static let majorTickLength: CGFloat = 9
    static let minorTickLength: CGFloat = 4
    static let labelFont = NSFont.systemFont(ofSize: 9)

    /// The canvas whose image the ruler measures. Weak on purpose: the
    /// window controller owns both, and a closing window must not leave a
    /// dangling geometry source behind.
    weak var canvas: EngineCanvasView?

    override init(scrollView: NSScrollView?, orientation: NSRulerView.Orientation) {
        super.init(scrollView: scrollView, orientation: orientation)
        ruleThickness = Self.ruleThicknessValue
        reservedThicknessForMarkers = 0
        measurementUnits = .points
        originOffset = 0
        setAccessibilityLabel(orientation == .horizontalRuler ? "Horizontal ruler" : "Vertical ruler")
        setAccessibilityHelp(orientation == .horizontalRuler
            ? "Drag down into the image to create a horizontal guide at that position. Press Escape while dragging to cancel."
            : "Drag right into the image to create a vertical guide at that position. Press Escape while dragging to cancel.")
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The guide a drag from this ruler creates: the matching orientation
    /// (the horizontal ruler yields horizontal guides).
    var guideOrientation: EngineSession.GuideOrientation {
        orientation == .horizontalRuler ? .horizontal : .vertical
    }

    // MARK: Guide dragging

    /// The ruler takes the keyboard while a guide drag runs, so Escape can
    /// cancel it.
    override var acceptsFirstResponder: Bool { true }

    /// A press on the ruler begins a new-guide drag into the canvas — only
    /// while the rulers are visible and the document can take metadata
    /// edits; every other press is left to the default handling. The
    /// gesture itself lives on the canvas (per window), view-only until
    /// the release commits it.
    override func mouseDown(with event: NSEvent) {
        guard let canvas, !isHidden, let scrollView, scrollView.rulersVisible else { return }
        window?.makeFirstResponder(self)
        _ = canvas.guideDrag.beginFromRuler(orientation: guideOrientation, event: event, ruler: self)
    }

    override func mouseDragged(with event: NSEvent) {
        _ = canvas?.guideDrag.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let canvas, canvas.guideDrag.mouseUp(with: event) {
            window?.makeFirstResponder(canvas)
        }
    }

    override func keyDown(with event: NSEvent) {
        if canvas?.guideDrag.keyDown(with: event) == true { return }
        super.keyDown(with: event)
    }

    /// The image's extent along this ruler's axis, in pixels, from the
    /// document's cached info — no engine call.
    private var imageExtent: Double {
        guard let canvas else { return 0 }
        return orientation == .horizontalRuler
            ? Double(canvas.document.info.width) : Double(canvas.document.info.height)
    }

    /// The tick plan for the current scroll, zoom, backing scale and image
    /// extent. The visible range is derived by converting the ruler's own
    /// corners into canvas coordinates (scroll- and flip-safe) and then
    /// through the canvas's existing image-point mapping.
    private var rulerSpace: NSView? {
        guard let canvas else { return nil }
        return canvas.superview as? CanvasRotationView ?? canvas
    }

    func currentPlan() -> PixelRulerPlan.Plan? {
        guard let canvas, let space = rulerSpace else { return nil }
        let scale = canvas.scale
        var start = Double.infinity
        var end = -Double.infinity
        for corner in [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                       CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY)] {
            let point = space.convert(corner, from: self)
            let position = orientation == .horizontalRuler ? point.x / scale : point.y / scale
            start = min(start, position); end = max(end, position)
        }
        guard start.isFinite, end.isFinite else { return nil }
        // Like the native pixel rulers, measure the projected display
        // bounds; ruler widgets and guide orientation do not swap.
        let extent: Double
        if let rotation = space as? CanvasRotationView, rotation.rotationDegrees != 0 {
            extent = Double(orientation == .horizontalRuler ? space.bounds.width / scale : space.bounds.height / scale)
        } else { extent = imageExtent }
        return PixelRulerPlan.plan(visibleStart: start, visibleEnd: end,
                                   pointsPerPixel: scale, imageExtent: extent)
    }

    private func axisMapping() -> (origin: Double, perPixel: Double)? {
        guard let canvas, let space = rulerSpace else { return nil }
        let scale = canvas.scale
        guard scale.isFinite, scale > 0 else { return nil }
        let originPoint = convert(CGPoint.zero, from: space)
        let unitPoint = convert(CGPoint(x: scale, y: scale), from: space)
        let origin = orientation == .horizontalRuler ? originPoint.x : originPoint.y
        let perPixel = orientation == .horizontalRuler ? unitPoint.x - originPoint.x : unitPoint.y - originPoint.y
        guard origin.isFinite, perPixel.isFinite else { return nil }
        return (Double(origin), Double(perPixel))
    }

    override func drawHashMarksAndLabels(in dirtyRect: NSRect) {
        // Light chrome, matching the window's light appearance whatever the
        // Mac's own setting (docs/design.md).
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        guard let plan = currentPlan(), let mapping = axisMapping() else { return }
        let backing = Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1)

        let majorPath = NSBezierPath()
        let minorPath = NSBezierPath()
        var labels: [(location: Double, text: String)] = []
        for tick in plan.ticks {
            let raw = mapping.origin + tick.imagePosition * mapping.perPixel
            guard raw.isFinite else { continue }
            let location = PixelRulerGeometry.deviceAligned(raw, backingFactor: backing)
            let length = tick.isMajor ? Self.majorTickLength : Self.minorTickLength
            switch orientation {
            case .horizontalRuler:
                // The horizontal ruler is flipped: maxY is the edge next to
                // the canvas, so ticks hang from it.
                let path = tick.isMajor ? majorPath : minorPath
                path.move(to: CGPoint(x: location, y: bounds.maxY - length))
                path.line(to: CGPoint(x: location, y: bounds.maxY))
            case .verticalRuler:
                let path = tick.isMajor ? majorPath : minorPath
                path.move(to: CGPoint(x: bounds.maxX - length, y: location))
                path.line(to: CGPoint(x: bounds.maxX, y: location))
            @unknown default:
                break
            }
            if let label = tick.label { labels.append((location, label)) }
        }

        NSColor.labelColor.setStroke()
        minorPath.lineWidth = 1
        minorPath.stroke()
        majorPath.lineWidth = 1
        majorPath.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.labelFont,
            .foregroundColor: NSColor.labelColor,
        ]
        for (location, text) in labels {
            let size = (text as NSString).size(withAttributes: attributes)
            switch orientation {
            case .horizontalRuler:
                let rect = NSRect(x: location + 2, y: (bounds.height - size.height) / 2,
                                  width: size.width, height: size.height)
                (text as NSString).draw(in: rect, withAttributes: attributes)
            case .verticalRuler:
                // Rotated to read bottom-up along the vertical ruler.
                NSGraphicsContext.saveGraphicsState()
                if let context = NSGraphicsContext.current?.cgContext {
                    context.translateBy(x: bounds.maxX - size.height - 2, y: location + size.width / 2)
                    context.rotate(by: -CGFloat.pi / 2)
                    (text as NSString).draw(at: .zero, withAttributes: attributes)
                }
                NSGraphicsContext.restoreGraphicsState()
            @unknown default:
                break
            }
        }
    }
}
