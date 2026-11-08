import AppKit

/// Pure geometry and hit/rounding rules for dragging guides, kept free of
/// AppKit view state so they are unit-testable without an engine, a window
/// or a document. Everything is image-pixel math: a guide's position is an
/// integer image pixel on its own axis (y for a horizontal guide, x for a
/// vertical one), and the Move tool's hit tolerance is measured in view
/// points so it feels the same at every zoom and backing factor.
enum GuideDragLogic {
    /// How near a guide line a Move-tool press must land to grab it, in
    /// view points — the same unit as the transform handles' reach.
    static let hitTolerancePoints: Double = 8
    /// The Escape key's virtual key code, as the canvas keyboard policy
    /// spells it elsewhere.
    static let escapeKeyCode = 53

    /// The image coordinate on `orientation`'s own axis: y for a
    /// horizontal guide, x for a vertical one.
    static func axisCoordinate(_ orientation: EngineSession.GuideOrientation, of imagePoint: CGPoint) -> Double {
        orientation == .horizontal ? imagePoint.y : imagePoint.x
    }

    /// The image's extent on `orientation`'s axis, in pixels — the same
    /// inclusive 0...extent range the sheet and the native validation use.
    static func extent(_ orientation: EngineSession.GuideOrientation, width: Int, height: Int) -> Double {
        Double(GuidesSheetLogic.extent(orientation: orientation, width: width, height: height))
    }

    /// Whether the raw (fractional) axis coordinate lies inside the image:
    /// 0...extent inclusive. A non-finite coordinate is never inside.
    static func isInsideImage(_ raw: Double, orientation: EngineSession.GuideOrientation,
                              width: Int, height: Int) -> Bool {
        guard raw.isFinite else { return false }
        return raw >= 0 && raw <= extent(orientation, width: width, height: height)
    }

    static func containsImagePoint(_ point: CGPoint, width: Int, height: Int) -> Bool {
        guard point.x.isFinite, point.y.isFinite, width > 0, height > 0 else { return false }
        return point.x >= 0 && point.y >= 0 && point.x <= CGFloat(width) && point.y <= CGFloat(height)
    }

    /// The integer image-pixel position a drop at the raw axis coordinate
    /// commits to: rounded to the nearest pixel and accepted only inside
    /// the inclusive 0...extent range. Nil for a non-finite or absurd raw
    /// value or an out-of-range position — the caller then cancels (new
    /// guide) or removes (existing guide released outside).
    static func commitPosition(_ raw: Double, orientation: EngineSession.GuideOrientation,
                               width: Int, height: Int) -> Int32? {
        guard raw.isFinite else { return nil }
        let rounded = raw.rounded()
        guard let value = Int32(exactly: rounded) else { return nil }
        guard value >= 0, Double(value) <= extent(orientation, width: width, height: height) else { return nil }
        return value
    }

    /// A guide's distance from an image point, in view points: the
    /// perpendicular distance on the guide's axis scaled by the canvas's
    /// point scale. Nil when the scale is damaged.
    static func viewDistance(of guide: EngineSession.Guide, at imagePoint: CGPoint, scale: Double) -> Double? {
        guard scale.isFinite, scale > 0 else { return nil }
        let distance = abs(axisCoordinate(guide.orientation, of: imagePoint) - Double(guide.position)) * scale
        return distance.isFinite ? distance : nil
    }

    /// The visible guide nearest to `imagePoint` within `tolerancePoints`
    /// view points, or nil. Hidden guides (the overlay off) are never hit:
    /// pass `guidesVisible: false` and this returns nil.
    static func hitTest(guides: [EngineSession.Guide], guidesVisible: Bool, at imagePoint: CGPoint,
                        scale: Double, tolerancePoints: Double = hitTolerancePoints) -> EngineSession.Guide? {
        guard guidesVisible, tolerancePoints.isFinite, tolerancePoints >= 0 else { return nil }
        return guides.compactMap { guide -> (EngineSession.Guide, Double)? in
            guard let distance = viewDistance(of: guide, at: imagePoint, scale: scale),
                  distance <= tolerancePoints else { return nil }
            return (guide, distance)
        }.min { $0.1 < $1.1 }?.0
    }

    /// One guide line's endpoints in canvas view coordinates for a
    /// fractional (ghost) position, clipped to the displayed image — the
    /// Double-position twin of `CanvasGeometry.guideLineEndpoints`, built
    /// on the same point-scale and image-rect helpers so zoom, backing
    /// factor and scroll agree with the real overlay. Nil when the
    /// position is outside the displayed image or the geometry is damaged.
    static func lineEndpoints(orientation: EngineSession.GuideOrientation, position: Double,
                              imageSize: CGSize, zoomPercent: Int, backingFactor: Double) -> (CGPoint, CGPoint)? {
        guard position.isFinite else { return nil }
        let scale = CanvasGeometry.pointScale(zoomPercent: zoomPercent, backingFactor: backingFactor)
        guard scale.isFinite, scale > 0 else { return nil }
        let image = CanvasGeometry.imageViewRect(imageSize: imageSize, zoomPercent: zoomPercent,
                                                 backingFactor: backingFactor)
        switch orientation {
        case .horizontal:
            let y = position * scale
            guard y >= image.minY && y <= image.maxY else { return nil }
            return (CGPoint(x: image.minX, y: y), CGPoint(x: image.maxX, y: y))
        case .vertical:
            let x = position * scale
            guard x >= image.minX && x <= image.maxX else { return nil }
            return (CGPoint(x: x, y: image.minY), CGPoint(x: x, y: image.maxY))
        }
    }
}

/// One document window's guide-drag gesture, owned by its canvas. The
/// rulers begin new-guide drags here and the canvas's tool controller
/// begins Move-tool drags of existing guides here, so both gestures share
/// one per-window state — no global controller or binding exists.
///
/// While a gesture is active it is view-only: the ghost line is drawn by
/// the canvas and no native guide call is made per mouse event. Exactly
/// one `ImageDocument.addGuide`/`moveGuide`/`removeGuide` runs on an
/// intentional mouseUp; Escape, a tool change and window close cancel
/// without touching native metadata, pixels or history.
@MainActor
final class GuideDragController {
    private unowned let canvas: EngineCanvasView
    private var document: ImageDocument { canvas.document }

    /// The active gesture, or nil. Internal-readable so the smoke test can
    /// observe the ghost state without any native call.
    private(set) var gesture: Gesture?

    /// One gesture's captured state.
    struct Gesture {
        enum Kind {
            /// A new guide dragged out of a ruler.
            case newFromRuler(EngineSession.GuideOrientation)
            /// An existing guide grabbed by the Move tool.
            case moveExisting(EngineSession.Guide)
        }
        let kind: Kind
        /// The window and document captured at the press: later events
        /// are honored only while the canvas still lives in that window
        /// with that document, so another window or a global front change
        /// cannot redirect the gesture.
        let window: NSWindow
        let document: ImageDocument
        /// The ghost's current position on the guide's axis, in image
        /// pixels (fractional while dragging).
        var position: Double

        var orientation: EngineSession.GuideOrientation {
            switch kind {
            case .newFromRuler(let orientation): return orientation
            case .moveExisting(let guide): return guide.orientation
            }
        }

        var movedGuide: EngineSession.Guide? {
            if case .moveExisting(let guide) = kind { return guide }
            return nil
        }
    }

    init(canvas: EngineCanvasView) {
        self.canvas = canvas
    }

    var isActive: Bool { gesture != nil }

    /// The image-pixel axis coordinate of an event for `orientation`,
    /// mapped through `NSView.convert` from the window and the canvas's
    /// own image-point helper — scroll-, zoom-, backing- and flip-safe.
    /// Nil when the geometry is damaged.
    private func imageAxisPoint(for event: NSEvent, orientation: EngineSession.GuideOrientation) -> Double? {
        let viewPoint = canvas.convert(event.locationInWindow, from: nil)
        let image = canvas.imagePoint(at: viewPoint)
        guard image.x.isFinite, image.y.isFinite else { return nil }
        return GuideDragLogic.axisCoordinate(orientation, of: image)
    }

    /// Whether the active gesture still belongs to its captured window
    /// and document. A late event after the window closed (or a document
    /// that began closing) fails this and is dropped without any action.
    private func stillValid() -> Bool {
        guard let gesture, let window = canvas.window, window === gesture.window,
              canvas.document === gesture.document, !gesture.document.isClosing else { return false }
        return true
    }

    /// Begins a new-guide drag from a pixel ruler. Refused (returning
    /// false, no gesture) while the document cannot take metadata edits —
    /// closing, busy, preview or another modal, all cached state, no
    /// native call — or when the rulers are hidden. Pixel locks do not
    /// refuse guides.
    @discardableResult
    func beginFromRuler(orientation: EngineSession.GuideOrientation, event: NSEvent, ruler: PixelRulerView) -> Bool {
        guard let window = canvas.window, !document.isClosing, document.acceptsEdits,
              ruler.canvas === canvas, ruler.window === window,
              let scrollView = ruler.scrollView, scrollView.rulersVisible else { return false }
        guard let position = imageAxisPoint(for: event, orientation: orientation) else { return false }
        gesture = Gesture(kind: .newFromRuler(orientation), window: window, document: document, position: position)
        canvas.needsDisplay = true
        return true
    }

    /// Begins dragging an existing visible guide under the pointer for the
    /// Move tool. Returns false — leaving ordinary layer-move behavior
    /// untouched — when the guides overlay is hidden or no visible guide
    /// is within the view-point tolerance.
    @discardableResult
    func beginMoveOfGuide(at event: NSEvent) -> Bool {
        guard let window = canvas.window, !document.isClosing, document.acceptsEdits,
              canvas.showsGuides else { return false }
        let viewPoint = canvas.convert(event.locationInWindow, from: nil)
        let image = canvas.imagePoint(at: viewPoint)
        guard let guide = GuideDragLogic.hitTest(guides: document.guides, guidesVisible: canvas.showsGuides,
                                                 at: image, scale: canvas.scale) else { return false }
        gesture = Gesture(kind: .moveExisting(guide), window: window, document: document,
                          position: Double(guide.position))
        canvas.needsDisplay = true
        return true
    }

    /// Tracks the drag: updates the view-only ghost only. Returns true
    /// when a gesture owns the event (whether or not it moved).
    @discardableResult
    func mouseDragged(with event: NSEvent) -> Bool {
        guard var gesture else { return false }
        guard stillValid() else { cancel(); return true }
        guard let raw = imageAxisPoint(for: event, orientation: gesture.orientation) else { return true }
        gesture.position = raw
        self.gesture = gesture
        canvas.needsDisplay = true
        return true
    }

    /// Commits exactly one document action for an intentional release, or
    /// cancels. Returns true when a gesture owned the event.
    @discardableResult
    func mouseUp(with event: NSEvent) -> Bool {
        guard var gesture else { return false }
        guard stillValid() else { cancel(); return true }
        guard let raw = imageAxisPoint(for: event, orientation: gesture.orientation) else { cancel(); return true }
        gesture.position = raw
        let imagePoint = canvas.imagePoint(at: canvas.convert(event.locationInWindow, from: nil))
        let inside = GuideDragLogic.containsImagePoint(imagePoint, width: document.info.width, height: document.info.height)
        commit(gesture, inside: inside)
        self.gesture = nil
        canvas.needsDisplay = true
        return true
    }

    /// The one committed action: a new guide inside the image is added;
    /// a new guide dropped invalid or outside cancels with no action; an
    /// existing guide dropped inside moves (a same-position move keeps
    /// the native no-op, no undo) and one intentionally released outside
    /// the image is removed. Each is a single addGuide/moveGuide/
    /// removeGuide — one undo step when anything changed.
    private func commit(_ gesture: Gesture, inside: Bool) {
        let document = gesture.document
        let width = document.info.width, height = document.info.height
        let orientation = gesture.orientation
        switch gesture.kind {
        case .newFromRuler:
            guard inside, let position = GuideDragLogic.commitPosition(gesture.position, orientation: orientation,
                                                                       width: width, height: height) else { return }
            document.addGuide(orientation, at: position)
        case .moveExisting(let guide):
            if inside {
                guard let position = GuideDragLogic.commitPosition(gesture.position, orientation: orientation,
                                                                   width: width, height: height) else { return }
                document.moveGuide(guide, to: position)
            } else {
                document.removeGuide(guide.id)
            }
        }
    }

    /// Cancels without any native metadata, pixel or history change and
    /// clears the ghost. Safe to call with no gesture and from the window
    /// close path.
    func cancel() {
        guard gesture != nil else { return }
        gesture = nil
        canvas.needsDisplay = true
    }

    /// Escape cancels an active gesture. Returns true when it consumed the
    /// key.
    @discardableResult
    func keyDown(with event: NSEvent) -> Bool {
        guard gesture != nil, Int(event.keyCode) == GuideDragLogic.escapeKeyCode else { return false }
        cancel()
        return true
    }
}
