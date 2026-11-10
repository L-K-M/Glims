import AppKit

/// One Move-tool drag with snapping, captured at the press. The whole
/// gesture is local: `proposed` is the view-only preview rect (image
/// coordinates) and `plan` the planner's result whose matched lines the
/// canvas draws as indicators. No engine call happens per drag event; the
/// single commit runs on the release. `cancelled` marks a drag that must
/// not commit (Escape, tool change, close, or a validity failure), keeping
/// the gesture non-nil so a late release is refused rather than retargeted.
@MainActor
final class MoveSnapGesture {
    /// The window and document captured at the press: later events are
    /// honored only while the canvas still lives in that window with that
    /// document, so another window or a global front change cannot
    /// redirect the drag.
    let window: NSWindow
    let document: ImageDocument
    /// The active layer's id and its bounds at the press.
    let layer: Int32
    let bounds: CGRect
    /// The snapped preview rect, in image coordinates.
    var proposed: CGRect
    /// The latest plan; `Result.none` when nothing matched or the drag
    /// was cancelled.
    var plan: CanvasSnapPlanner.Result
    var cancelled = false

    init(window: NSWindow, document: ImageDocument, layer: Int32, bounds: CGRect) {
        self.window = window
        self.document = document
        self.layer = layer
        self.bounds = bounds
        self.proposed = bounds
        self.plan = .none
    }
}

/// One Move-tool drag on an EXISTING floating selection, captured at the
/// press — even when this window's Snap To state is fully off. The
/// gesture keeps the floating selection's identity: the expected
/// `EngineSession.FloatingState` (floating id + attachment target +
/// target kind) and the floating layer's bounds, plus the window and
/// document, all captured at the press. The whole gesture is local:
/// `proposed` is the view-only preview rect (image coordinates, already
/// a whole-pixel translation of `bounds`) and `plan` the planner's
/// result when snapping is on. No engine call happens per drag event;
/// the single commit runs on the release through the captured
/// floating-move command. `cancelled` marks a drag that must not commit
/// (Escape, tool change, close, or a validity failure), keeping the
/// gesture non-nil so a late release is refused rather than retargeted
/// to an ordinary/raw move.
@MainActor
final class FloatingMoveGesture {
    /// The window and document captured at the press: later events are
    /// honored only while the canvas still lives in that window with that
    /// document, so another window or a global front change cannot
    /// redirect the drag.
    let window: NSWindow
    let document: ImageDocument
    /// The floating-selection state expected at the press: the floating
    /// layer's id, its attachment target and the target's kind.
    let expected: EngineSession.FloatingState
    /// The floating layer's bounds at the press.
    let bounds: CGRect
    /// The snapped (or plain whole-pixel) preview rect, in image
    /// coordinates.
    var proposed: CGRect
    /// The latest plan; `Result.none` when nothing matched, snapping is
    /// off, or the drag was cancelled.
    var plan: CanvasSnapPlanner.Result
    var cancelled = false

    init(window: NSWindow, document: ImageDocument, expected: EngineSession.FloatingState, bounds: CGRect) {
        self.window = window
        self.document = document
        self.expected = expected
        self.bounds = bounds
        self.proposed = bounds
        self.plan = .none
    }

    /// The floating layer's id the gesture would move.
    var floating: Int32 { expected.floating }
}

/// What the current tool does with pointer and key events on a document's
/// canvas, and what it draws over the image while it works (the selection
/// rubber band or lasso path). The canvas owns one and forwards its events.
@MainActor
final class CanvasToolController {
    private unowned let canvas: EngineCanvasView
    private var document: ImageDocument { canvas.document }

    /// The tool for the current drag; Space and Command switch tools
    /// temporarily meanwhile.
    private var dragTool: ToolID?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var dragOperation = EngineSession.SelectOperation.replace
    private var selectionDragFlags: NSEvent.ModifierFlags = []

    /// The same image-space bounds drive the rubber band and its commit.
    var selectionDragRect: CGRect? {
        guard dragTool == .rectangleSelect || dragTool == .ellipseSelect,
              let start = dragStart, let end = dragCurrent else { return nil }
        return SelectionDragGeometry.rect(start: start, end: end,
            constrained: selectionDragFlags.contains(.shift),
            fromCenter: selectionDragFlags.contains(.option))
    }
    private var lassoPoints: [CGPoint] = []
    /// The gradient gesture's captured values (identity, settings, colors),
    /// taken once at the press so later UI/tool/color changes cannot
    /// redirect the queued work; only the endpoints track the drag.
    private var gradientCapture: GradientGestureSnapshot?
    private var handOrigin: (window: NSPoint, scroll: NSPoint)?
    /// Held temporary-tool modifiers: Space for the hand, Command for the
    /// move tool, Option for color sampling.
    private var keyboard = CanvasKeyboardState()
    /// The crop rectangle waiting for Return (image pixels).
    private(set) var pendingCrop: CGRect?
    /// The Transform tool's pending transform, waiting for Return.
    private(set) var transformSession: LayerTransformSession?
    private var transformDrag: LayerTransformSession.Drag?
    /// The pointer's last image location during a Transform drag, so a
    /// modifier-only event recomputes the preview from the same point.
    private var transformDragCurrent: CGPoint?
    /// The Move tool's snapping drag, captured at the press when this
    /// window's Snap To state enables any target; nil when snapping is off
    /// (the legacy raw move) or no layer could be captured.
    private(set) var moveSnap: MoveSnapGesture?
    /// Distinguishes snapping off from a refused capture. A refused press
    /// must never fall back to moving whichever layer is active later.
    private var moveSnapWasRequested = false
    /// The Move tool's drag on an existing floating selection, captured
    /// at the press even when snapping is off; nil when no floating
    /// selection was active or the capture was invalid.
    private(set) var floatingMove: FloatingMoveGesture?
    /// Distinguishes "no floating selection at the press" from "a
    /// floating press whose capture was invalid or was cancelled": the
    /// latter must never fall through to an ordinary/raw layer move.
    private var floatingMoveWasRequested = false
    /// How near a handle a press grabs it, in view points.
    private static let handleReach: Double = 6
    /// The Text tool's editor while text is being typed.
    private(set) var textEditor: TextEditorOverlay?
    private struct NewTextContext {
        let document: ImageDocument
        weak var window: NSWindow?
        let expectedFloating: EngineSession.FloatingState
    }
    /// New text owns the state seen when its editor opened, never a float
    /// or document chosen again by a later finish callback.
    private var newTextContext: NewTextContext?
    /// The Path tool's state: the subpath being drawn, the selected anchor.
    private(set) lazy var pathTool: PathTool = {
        let tool = PathTool(canvas: canvas)
        tool.onStatus = { [weak self] message in self?.onStatus?(message) }
        return tool
    }()

    /// Shows a short message in the document's status strip.
    var onStatus: ((String) -> Void)?
    /// Asks the window to zoom one step in or out, keeping `point` (image
    /// pixels) in view.
    var onZoom: ((_ zoomIn: Bool, _ point: CGPoint) -> Void)?

    /// Pointer gestures commit on release; crop and transform previews
    /// commit on Return. A background file operation must wait for these
    /// edits rather than blocking their eventual commit.
    var hasPendingInteraction: Bool {
        dragTool != nil || pendingCrop != nil || textEditor != nil
            || transformSession.map { !$0.isIdentity } == true
    }

    init(canvas: EngineCanvasView) {
        self.canvas = canvas
        // The Transform tool's box shows as soon as the tool is picked, and
        // an unapplied transform goes away when another tool is.
        ToolState.shared.observe { [weak self] in
            guard let self else { return }
            if ToolState.shared.current != .transform, self.transformSession != nil {
                self.cancelTransform(message: "Transform cancelled.")
            }
            if ToolState.shared.current != .text, self.textEditor != nil {
                self.finishTextEditing()
            }
            // A tool change cancels this window's in-progress guide drag
            // (ghost cleared, no native guide action) and any Move snap
            // or floating move (preview cleared, the release then commits
            // nothing).
            self.canvas.guideDrag.cancel()
            self.cancelMoveSnap()
            self.cancelFloatingMove()
            self.canvas.needsDisplay = true
        }
    }

    /// The tool a pointer press uses: Space is the temporary hand, Command
    /// moves the layer, otherwise the current tool.
    private func pointerTool(for flags: NSEvent.ModifierFlags) -> ToolID {
        keyboard.pointerTool(current: ToolState.shared.current, flags: flags)
    }

    // MARK: Pointer

    func mouseDown(with event: NSEvent) {
        let point = canvas.imagePoint(for: event)
        let tool = pointerTool(for: event.modifierFlags)
        let optionDown = keyboard.optionIsDown(flags: event.modifierFlags)
        guard document.acceptsEdits || [.hand, .zoom, .eyedropper].contains(tool) else {
            onStatus?("Finish the current operation before editing the image.")
            return
        }
        dragTool = tool
        if tool != .transform, transformSession != nil {
            // Another tool took over: the unapplied transform goes away.
            cancelTransform(message: nil)
        }
        if textEditor != nil {
            // A click outside the editor finishes it; with the Text tool
            // the click goes on to start the next text.
            finishTextEditing()
            if tool != .text { dragTool = nil; return }
        }

        if let paintTool = tool.paintTool {
            if optionDown {
                if paintTool == .clone || paintTool == .heal {
                    setCloneSource(at: point)
                    dragTool = nil
                } else {
                    // Option with any other paint tool temporarily samples
                    // the foreground color, as the Color Picker does.
                    pickColor(at: point)
                    dragTool = .eyedropper
                }
                return
            }
            if (paintTool == .clone || paintTool == .heal), ToolState.shared.cloneSource == nil {
                onStatus?("Option-click the image to set the \(tool.name.lowercased()) source first.")
                NSSound.beep()
                dragTool = nil
                return
            }
            document.beginStroke(at: canvas.strokePoint(for: event), brush: ToolState.shared.brush(for: tool))
            return
        }

        switch tool {
        case .rectangleSelect, .ellipseSelect, .lasso:
            dragStart = point
            dragCurrent = point
            lassoPoints = [point]
            dragOperation = Self.operation(for: event.modifierFlags)
            selectionDragFlags = event.modifierFlags
        case .magicWand, .selectByColor:
            var options = ToolState.shared.selectOptions
            options.operation = Self.operation(for: event.modifierFlags)
            options.contiguous = tool == .magicWand
            document.selectColor(at: point, options: options)
        case .eyedropper:
            pickColor(at: point)
        case .hand:
            if let clip = canvas.enclosingScrollView?.contentView {
                handOrigin = (event.locationInWindow, clip.bounds.origin)
            }
        case .zoom:
            onZoom?(!event.modifierFlags.contains(.option), point)
        case .transform:
            beginTransformDrag(at: point, clickCount: event.clickCount)
        case .text:
            beginTextEditing(at: point)
            dragTool = nil
        case .path:
            pathTool.mouseDown(at: point, flags: event.modifierFlags)
        case .move:
            dragStart = point
            dragCurrent = point
            // An actual guide hit under the pointer takes the gesture;
            // the ordinary layer move must not start then. The guide hit
            // keeps first priority: a press on a guide never becomes a
            // snapping layer move or a floating move.
            if canvas.guideDrag.beginMoveOfGuide(at: event) {
                dragTool = nil
                return
            }
            if document.floatingState.isActive {
                // An existing floating selection owns the Move gesture:
                // capture its expected state, window, document and bounds
                // at the press even when snapping is off. An invalid
                // capture still consumes the gesture, so the release can
                // never fall through to an ordinary/raw move.
                beginFloatingMove()
            } else {
                floatingMove = nil
                floatingMoveWasRequested = false
                beginMoveSnap()
            }
        case .gradient, .crop:
            dragStart = point
            dragCurrent = point
            if tool == .crop { pendingCrop = nil }
            if tool == .gradient {
                gradientCapture = ToolState.shared.gradientSnapshot(from: point, to: point)
            }
        case .bucketFill:
            let state = ToolState.shared
            document.fill(at: point, mode: state.fillMode, color: state.foreground,
                          threshold: state.fillThreshold, sampleMerged: state.fillSampleMerged)
        default:
            break
        }
    }

    func mouseDragged(with event: NSEvent) {
        // A guide drag owns the gesture: view-only ghost, no native call.
        if canvas.guideDrag.mouseDragged(with: event) { return }
        guard let tool = dragTool else { return }
        let point = canvas.imagePoint(for: event)

        if tool.paintTool != nil {
            document.continueStroke([canvas.strokePoint(for: event)])
            return
        }
        switch tool {
        case .rectangleSelect, .ellipseSelect, .gradient, .crop:
            dragCurrent = point
            selectionDragFlags = event.modifierFlags
            canvas.needsDisplay = true
        case .move:
            dragCurrent = point
            if floatingMove != nil {
                updateFloatingMove(to: point)
            } else {
                updateMoveSnap(to: point)
            }
            canvas.needsDisplay = true
        case .lasso:
            if let last = lassoPoints.last, hypot(point.x - last.x, point.y - last.y) >= 1 {
                lassoPoints.append(point)
                canvas.needsDisplay = true
            }
        case .transform:
            guard let drag = transformDrag else { return }
            transformDragCurrent = point
            transformSession?.update(drag, to: point, constrained: event.modifierFlags.contains(.shift))
            canvas.needsDisplay = true
        case .eyedropper:
            pickColor(at: point)
        case .path:
            pathTool.mouseDragged(to: point, flags: event.modifierFlags)
        case .hand:
            guard let origin = handOrigin, let scroll = canvas.enclosingScrollView else { return }
            let delta = NSPoint(x: event.locationInWindow.x - origin.window.x,
                                y: event.locationInWindow.y - origin.window.y)
            // The canvas is flipped; window y grows upwards.
            scroll.contentView.scroll(to: NSPoint(x: origin.scroll.x - delta.x, y: origin.scroll.y + delta.y))
            scroll.reflectScrolledClipView(scroll.contentView)
        default:
            break
        }
    }

    func mouseUp(with event: NSEvent) {
        defer {
            dragTool = nil
            dragStart = nil
            dragCurrent = nil
            selectionDragFlags = []
            lassoPoints = []
            handOrigin = nil
            gradientCapture = nil
            transformDragCurrent = nil
            moveSnap = nil
            moveSnapWasRequested = false
            floatingMove = nil
            floatingMoveWasRequested = false
            canvas.needsDisplay = true
        }
        // An intentional release of a guide drag commits exactly one
        // addGuide/moveGuide/removeGuide action.
        if canvas.guideDrag.mouseUp(with: event) { return }
        guard let tool = dragTool else { return }

        if tool.paintTool != nil {
            document.continueStroke([canvas.strokePoint(for: event)])
            document.endStroke()
            return
        }
        var options = ToolState.shared.selectOptions
        options.operation = dragOperation
        let end = canvas.imagePoint(for: event)
        switch tool {
        case .path:
            pathTool.mouseUp()
        case .transform:
            if let drag = transformDrag {
                transformSession?.update(drag, to: end, constrained: event.modifierFlags.contains(.shift))
            }
            transformDrag = nil
            if transformSession?.isIdentity == false {
                onStatus?("Return applies the transform; Escape cancels it.")
            }
        case .move:
            guard let start = dragStart else { return }
            if let gesture = floatingMove {
                // A floating drag commits exactly once, on this release,
                // through the captured floating-move command — one native
                // undo step — and only while the capture is still current.
                // A cancelled or stale gesture commits nothing at all.
                guard let delta = FloatingControlsLogic.commitDelta(cancelled: gesture.cancelled,
                        stillValid: floatingMoveStillValid(gesture),
                        bounds: gesture.bounds, proposed: gesture.proposed) else {
                    onStatus?("The floating selection changed, so the move was not applied.")
                    return
                }
                document.moveFloatingSelection(by: delta, completion: { _ in })
                return
            }
            // A refused floating capture (or a cancelled one) never falls
            // through to an ordinary/raw layer move.
            guard !floatingMoveWasRequested else { return }
            if let gesture = moveSnap {
                // A snapping drag commits exactly once, on this release,
                // through the existing counted move — one undo step — and
                // only while the capture is still current. Pending work, a
                // target change or changed captured bounds refuse the
                // commit: no stale geometry is applied, no retarget.
                guard !gesture.cancelled, moveSnapStillValid(gesture) else {
                    onStatus?("The layer changed, so the move was not applied.")
                    return
                }
                let delta = CGSize(width: (gesture.proposed.minX - gesture.bounds.minX).rounded(),
                                   height: (gesture.proposed.minY - gesture.bounds.minY).rounded())
                document.moveActiveLayer(by: delta)
                return
            }
            guard !moveSnapWasRequested else { return }
            document.moveActiveLayer(by: CGSize(width: (end.x - start.x).rounded(), height: (end.y - start.y).rounded()))
        case .gradient:
            guard let start = dragStart, hypot(end.x - start.x, end.y - start.y) >= 1,
                  let capture = gradientCapture else { return }
            // The gesture commits through the counted resource queue with
            // the values captured at the press; only the endpoints move
            // with the drag. The identity resolves on the engine worker
            // inside the queued job — never on main.
            let snapshot = capture.withEndpoints(from: start, to: end)
            document.gradientResource(snapshot.identity, from: snapshot.from, to: snapshot.to,
                                      settings: snapshot.settings)
        case .crop:
            guard let start = dragStart else { return }
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y)).integral
            pendingCrop = rect.width >= 1 && rect.height >= 1 ? rect : nil
            onStatus?(pendingCrop == nil ? "Drag the area to keep."
                                         : "Return crops to \(Int(rect.width)) × \(Int(rect.height)) px; Escape cancels.")
        case .rectangleSelect, .ellipseSelect:
            dragCurrent = end
            selectionDragFlags = event.modifierFlags
            guard let rect = selectionDragRect else { return }
            if rect.width < 1 || rect.height < 1 {
                // A click without a drag deselects, as in classic editors.
                if dragOperation == .replace { document.select(.none) }
                return
            }
            document.select(tool == .ellipseSelect ? .ellipse(rect) : .rectangle(rect), options: options)
        case .lasso:
            if lassoPoints.count >= 3 {
                document.select(.polygon(lassoPoints), options: options)
            } else if dragOperation == .replace {
                document.select(.none)
            }
        default:
            break
        }
    }

    // MARK: Move snapping

    /// Captures the active layer's id and bounds at a Move press, when
    /// this window's Snap To state enables any target. With every entry
    /// off (or no capturable layer) no gesture is captured and the move
    /// keeps the legacy raw behavior.
    private func beginMoveSnap() {
        moveSnap = nil
        moveSnapWasRequested = !canvas.snapTo.isEmpty
        guard moveSnapWasRequested, let window = canvas.window,
              !document.isClosing, document.acceptsEdits,
              let layer = document.activeLayer,
              let captured = document.layers.first(where: { $0.id == layer }),
              Self.isUsableRect(captured.bounds) else { return }
        moveSnap = MoveSnapGesture(window: window, document: document, layer: layer, bounds: captured.bounds)
    }

    /// Whether `gesture` still describes its layer as the document has it,
    /// reading cached state only — no native call. Pending work, a pending
    /// target command, a changed active layer or mask/channel target, moved
    /// captured bounds, a closing document or a detached window all fail.
    private func moveSnapStillValid(_ gesture: MoveSnapGesture) -> Bool {
        let doc = gesture.document
        guard let window = canvas.window, window === gesture.window,
              canvas.document === doc, !doc.isClosing,
              doc.pendingWork == 0, !doc.targetCommandIsPending,
              doc.activeLayer == gesture.layer,
              !doc.isMaskTargetActive, !doc.isChannelTargetActive,
              let layer = doc.layers.first(where: { $0.id == gesture.layer }),
              layer.bounds == gesture.bounds else { return false }
        return true
    }

    /// Re-plans the drag's snap from cached geometry only: the proposed
    /// rect is the captured bounds plus the raw drag delta, the planner
    /// corrects it, and the corrected rect becomes the local preview. A
    /// validity failure cancels the gesture (the release then commits
    /// nothing) instead of planning on stale geometry.
    private func updateMoveSnap(to point: CGPoint) {
        guard var gesture = moveSnap, !gesture.cancelled, let start = dragStart else { return }
        guard moveSnapStillValid(gesture) else {
            gesture.cancelled = true
            gesture.plan = .none
            moveSnap = gesture
            return
        }
        let raw = gesture.bounds.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
        let plan = CanvasSnapPlanner.plan(
            input: SnapTargetCache.plannerInput(
                movingRect: raw,
                imageSize: CGSize(width: Double(gesture.document.info.width),
                                  height: Double(gesture.document.info.height)),
                guides: gesture.document.guides, grid: gesture.document.grid,
                layers: gesture.document.layers, moving: gesture.layer),
            config: CanvasSnapPlanner.Config(targets: canvas.snapTo.targets),
            canvasScale: canvas.scale)
        let preview = SnapTargetCache.pixelMove(bounds: gesture.bounds,
            proposed: raw.offsetBy(dx: plan.dx, dy: plan.dy), plan: plan)
        gesture.plan = preview.plan
        gesture.proposed = preview.rect
        moveSnap = gesture
    }

    /// Cancels the in-progress snap without any mutation: the preview and
    /// indicators clear and the release commits nothing. Safe with no
    /// gesture; called on Escape, tool change and window close.
    func cancelMoveSnap() {
        guard let gesture = moveSnap, !gesture.cancelled else { return }
        gesture.cancelled = true
        gesture.plan = .none
        canvas.needsDisplay = true
    }

    // MARK: Floating-selection move

    /// Captures the active floating selection's expected state and bounds
    /// at a Move press, even when every Snap To entry is off. The capture
    /// always consumes the gesture (`floatingMoveWasRequested`): with an
    /// unusable window, document, state or bounds no gesture is stored
    /// and the release refuses instead of falling back to a raw move.
    private func beginFloatingMove() {
        floatingMove = nil
        floatingMoveWasRequested = true
        let expected = document.floatingState
        guard let window = canvas.window, !document.isClosing, document.acceptsEdits,
              expected.isActive,
              let row = document.layers.first(where: { $0.id == expected.floating }),
              FloatingControlsLogic.usableMoveBounds(row.bounds) else { return }
        floatingMove = FloatingMoveGesture(window: window, document: document,
                                           expected: expected, bounds: row.bounds)
    }

    /// Whether `gesture` still describes the same unresolved floating
    /// selection as the document has it, reading cached state only — no
    /// native call. Pending work, a pending target command, a changed
    /// cached floating state (id, attachment or kind), moved captured
    /// bounds, a closing document or a detached window all fail.
    private func floatingMoveStillValid(_ gesture: FloatingMoveGesture) -> Bool {
        let doc = gesture.document
        guard let window = canvas.window, window === gesture.window,
              canvas.document === doc, !doc.isClosing,
              doc.pendingWork == 0, !doc.targetCommandIsPending,
              doc.floatingState == gesture.expected,
              let row = doc.layers.first(where: { $0.id == gesture.expected.floating }),
              row.bounds == gesture.bounds else { return false }
        return true
    }

    /// Re-plans the floating drag from cached geometry only: the proposed
    /// rect is the captured bounds plus the raw drag delta, the planner
    /// corrects it when any Snap To entry is on (the floating layer's own
    /// family stays excluded from the candidates), and the corrected rect
    /// — always a whole-pixel translation of the captured bounds —
    /// becomes the local view-only preview. A validity failure cancels
    /// the gesture (the release then commits nothing).
    private func updateFloatingMove(to point: CGPoint) {
        guard var gesture = floatingMove, !gesture.cancelled, let start = dragStart else { return }
        guard floatingMoveStillValid(gesture) else {
            gesture.cancelled = true
            gesture.plan = .none
            floatingMove = gesture
            return
        }
        let raw = gesture.bounds.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
        let plan: CanvasSnapPlanner.Result
        if canvas.snapTo.isEmpty {
            plan = .none
        } else {
            plan = CanvasSnapPlanner.plan(
                input: SnapTargetCache.plannerInput(
                    movingRect: raw,
                    imageSize: CGSize(width: Double(gesture.document.info.width),
                                      height: Double(gesture.document.info.height)),
                    guides: gesture.document.guides, grid: gesture.document.grid,
                    layers: gesture.document.layers, moving: gesture.expected.floating),
                config: CanvasSnapPlanner.Config(targets: canvas.snapTo.targets),
                canvasScale: canvas.scale)
        }
        let preview = SnapTargetCache.pixelMove(bounds: gesture.bounds,
            proposed: plan == .none ? raw : raw.offsetBy(dx: plan.dx, dy: plan.dy), plan: plan)
        gesture.plan = preview.plan
        gesture.proposed = preview.rect
        floatingMove = gesture
    }

    /// Cancels the in-progress floating move without any mutation: the
    /// preview and indicators clear and the release commits nothing.
    /// Safe with no gesture; called on Escape, tool change and window
    /// close.
    func cancelFloatingMove() {
        guard let gesture = floatingMove, !gesture.cancelled else { return }
        gesture.cancelled = true
        gesture.plan = .none
        canvas.needsDisplay = true
    }

    /// A rect usable as the captured move geometry.
    private static func isUsableRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.size.width.isFinite && rect.size.height.isFinite
            && rect.maxX.isFinite && rect.maxY.isFinite
            && rect.size.width > 0 && rect.size.height > 0
    }

    /// Shift adds, Option subtracts, both intersect, when the drag starts
    /// (docs/design.md, keyboard model); otherwise the options' mode.
    private static func operation(for flags: NSEvent.ModifierFlags) -> EngineSession.SelectOperation {
        switch (flags.contains(.shift), flags.contains(.option)) {
        case (true, true): return .intersect
        case (true, false): return .add
        case (false, true): return .subtract
        default: return ToolState.shared.selectOptions.operation
        }
    }

    private func setCloneSource(at point: CGPoint) {
        guard let drawable = document.activeDrawable else { return }
        ToolState.shared.cloneSource = EngineSession.Brush.Source(drawable: drawable, x: point.x, y: point.y)
        ToolState.shared.notifyChange()
        onStatus?("Source set at \(Int(point.x)), \(Int(point.y)).")
    }

    private func pickColor(at point: CGPoint) {
        guard point.x >= 0, point.y >= 0, point.x < Double(document.info.width), point.y < Double(document.info.height),
              let pixel = try? document.session.render(document.image, scale: 1,
                                                       area: CGRect(x: floor(point.x), y: floor(point.y), width: 1, height: 1)),
              let data = pixel.dataProvider?.data as Data?, data.count >= 4 else { return }
        let alpha = Double(data[3]) / 255
        let unpremultiply = { (value: UInt8) in alpha > 0 ? min(1, Double(value) / 255 / alpha) : 0 }
        ToolState.shared.foreground = NSColor(srgbRed: unpremultiply(data[0]), green: unpremultiply(data[1]),
                                              blue: unpremultiply(data[2]), alpha: 1)
        ToolState.shared.notifyChange()
    }

    // MARK: Keys

    private static let returnKeys: Set<Int> = [36, 76]      // Return, keypad Enter
    private static let escapeKey = 53
    private static let tabKey = 48
    /// Temporary-tool modifiers, tool shortcuts, Space for the hand, digits,
    /// brackets and arrows. Returns false for keys it does not handle.
    func keyDown(with event: NSEvent) -> Bool {
        let keyCode = Int(event.keyCode)

        if keyCode == Self.escapeKey,
           dragTool == .rectangleSelect || dragTool == .ellipseSelect || dragTool == .lasso {
            dragTool = nil; dragStart = nil; dragCurrent = nil
            selectionDragFlags = []; lassoPoints = []
            canvas.needsDisplay = true
            onStatus?("Selection cancelled.")
            return true
        }

        // Command and Option are temporary-tool modifiers; track their held
        // state before the plain-key guard below rejects their flags.
        if CanvasKeyboardPolicy.isTemporaryModifierKey(keyCode: keyCode) {
            keyboard.keyDown(keyCode)
            return true
        }

        guard CanvasKeyboardPolicy.allowsPlainKey(event.modifierFlags),
              let key = event.charactersIgnoringModifiers else { return false }
        if transformSession != nil, Self.returnKeys.contains(keyCode) {
            applyTransform()
            return true
        }
        if transformSession != nil, keyCode == Self.escapeKey {
            cancelTransform(message: "Transform cancelled.")
            return true
        }
        if (moveSnap != nil || floatingMove != nil), keyCode == Self.escapeKey {
            // Escape cancels the snapping or floating move: preview and
            // indicators clear and the release commits nothing.
            cancelMoveSnap()
            cancelFloatingMove()
            onStatus?("Move cancelled.")
            return true
        }
        // Only while the canvas has focus: a text field keeps Tab for itself.
        if keyCode == Self.tabKey {
            AppController.togglePalettes(keepingTools: event.modifierFlags.contains(.shift))
            return true
        }
        if let rect = pendingCrop, Self.returnKeys.contains(keyCode) {
            document.crop(to: rect)
            pendingCrop = nil
            canvas.needsDisplay = true
            return true
        }
        if pendingCrop != nil, keyCode == Self.escapeKey {
            pendingCrop = nil
            canvas.needsDisplay = true
            onStatus?("Crop cancelled.")
            return true
        }
        if ToolState.shared.current == .path, pathTool.keyDown(keyCode: keyCode) {
            return true
        }
        if let arrow = CanvasKeyboardPolicy.Arrow(keyCode: keyCode) {
            let delta = CanvasKeyboardPolicy.nudge(arrow, shift: event.modifierFlags.contains(.shift))
            if document.floatingState.isActive {
                // Arrow nudges move the unresolved floating selection
                // through the explicit captured-floating command — with
                // the same fresh-state validation on the worker — never
                // through the ordinary layer move (which refuses
                // floating) and never an implicit anchor.
                document.moveFloatingSelection(by: delta, completion: { _ in })
            } else {
                document.moveActiveLayer(by: delta)
            }
            return true
        }

        switch key.lowercased() {
        case "q":
            if !event.isARepeat {
                document.setQuickMask(!(document.quickMaskState?.enabled ?? false))
            }
            return true
        case "x":
            ToolState.shared.swapColors()
            return true
        case "d":
            ToolState.shared.resetColors()
            return true
        default:
            break
        }

        if key == " " {
            keyboard.keyDown(CanvasKeyboardPolicy.spaceKeyCode)
            if !event.isARepeat { NSCursor.openHand.set() }
            return true
        }
        if ToolID.group(forShortcut: key) != nil {
            ToolState.shared.select(shortcut: key, cycle: event.modifierFlags.contains(.shift))
            return true
        }
        if CanvasKeyboardPolicy.isLeftBracket(key) || CanvasKeyboardPolicy.isRightBracket(key) {
            let tool = ToolState.shared.current
            guard tool.paintTool != nil else { return false }
            let increased = CanvasKeyboardPolicy.isRightBracket(key)
            if event.modifierFlags.contains(.shift) {
                let hardness = CanvasKeyboardPolicy.hardness(ToolState.shared.brush(for: tool).hardness,
                                                             increased: increased)
                ToolState.shared.update(tool) { $0.hardness = hardness }
                onStatus?("\(tool.name) hardness \(Int((hardness * 100).rounded()))%")
            } else {
                ToolState.shared.update(tool) { brush in
                    brush.size = max(1, min(PaintToolPresetLimits.maxSize,
                                           increased ? brush.size * 1.25 : brush.size / 1.25)).rounded()
                }
                onStatus?("\(tool.name) size \(Int(ToolState.shared.brush(for: tool).size)) px")
            }
            return true
        }
        if let opacity = CanvasKeyboardPolicy.paintOpacity(for: key),
           CanvasKeyboardPolicy.adjustsBrush(ToolState.shared.current) {
            let tool = ToolState.shared.current
            ToolState.shared.update(tool) { $0.opacity = opacity }
            onStatus?("\(tool.name) opacity \(Int((opacity * 100).rounded()))%")
            return true
        }
        return false
    }

    func keyUp(with event: NSEvent) -> Bool {
        let keyCode = Int(event.keyCode)
        if CanvasKeyboardPolicy.isTemporaryModifierKey(keyCode: keyCode) {
            keyboard.keyUp(keyCode)
            return true
        }
        guard event.charactersIgnoringModifiers == " " else { return false }
        keyboard.keyUp(CanvasKeyboardPolicy.spaceKeyCode)
        NSCursor.arrow.set()
        return true
    }

    // MARK: Overlay

    /// Modifier-only changes redraw a stationary selection without changing
    /// the selection operation captured at the press.
    func selectionModifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard dragTool == .rectangleSelect || dragTool == .ellipseSelect else { return }
        selectionDragFlags = flags
        canvas.needsDisplay = true
    }

    /// Modifier-only changes recompute a stationary Transform preview from
    /// the captured drag and its last pointer location, without a native
    /// call.
    func transformModifiersChanged(_ flags: NSEvent.ModifierFlags) {
        guard dragTool == .transform, let drag = transformDrag else { return }
        transformSession?.update(drag, to: transformDragCurrent ?? drag.start,
                                 constrained: flags.contains(.shift))
        canvas.needsDisplay = true
    }

    /// The rubber band or lasso path of a selection being drawn, in view
    /// coordinates (the canvas is flipped).
    func drawOverlay(scale: Double) {
        let path: NSBezierPath
        switch dragTool {
        case .rectangleSelect?, .ellipseSelect?:
            guard let bounds = selectionDragRect else { return }
            let rect = NSRect(x: bounds.minX * scale, y: bounds.minY * scale,
                              width: bounds.width * scale, height: bounds.height * scale)
            path = dragTool == .ellipseSelect ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
        case .lasso?:
            guard lassoPoints.count > 1 else { return }
            path = NSBezierPath()
            path.move(to: NSPoint(x: lassoPoints[0].x * scale, y: lassoPoints[0].y * scale))
            lassoPoints.dropFirst().forEach { path.line(to: NSPoint(x: $0.x * scale, y: $0.y * scale)) }
        case .crop?:
            guard let start = dragStart, let end = dragCurrent else { return }
            path = NSBezierPath(rect: NSRect(x: min(start.x, end.x) * scale, y: min(start.y, end.y) * scale,
                                             width: abs(end.x - start.x) * scale, height: abs(end.y - start.y) * scale))
        case .gradient?:
            guard let start = dragStart, let end = dragCurrent else { return }
            path = NSBezierPath()
            path.move(to: NSPoint(x: start.x * scale, y: start.y * scale))
            path.line(to: NSPoint(x: end.x * scale, y: end.y * scale))
        case .move?:
            // The moved drawable's outline, following the pointer — the
            // floating selection's captured bounds at the (snapped or
            // plain whole-pixel) preview position while a floating drag is
            // active, the selected layer's bounds while a snapping drag
            // is active.
            let bounds: CGRect
            if let gesture = floatingMove {
                guard !gesture.cancelled else { return }
                bounds = gesture.proposed
            } else if let gesture = moveSnap {
                guard !gesture.cancelled else { return }
                bounds = gesture.proposed
            } else {
                guard !moveSnapWasRequested, !floatingMoveWasRequested,
                      let start = dragStart, let end = dragCurrent,
                      let layer = document.layers.first(where: { $0.id == document.activeLayer }) else { return }
                bounds = layer.bounds.offsetBy(dx: end.x - start.x, dy: end.y - start.y)
            }
            path = NSBezierPath(rect: NSRect(x: bounds.minX * scale, y: bounds.minY * scale,
                                             width: bounds.width * scale, height: bounds.height * scale))
            drawSnapIndicators(scale: scale)
        default:
            drawPendingCrop(scale: scale)
            drawTransform(scale: scale)
            if ToolState.shared.current == .path || dragTool == .path { pathTool.draw(scale: scale) }
            return
        }
        EngineCanvasView.strokeMarchingAnts(path, phase: 0)
    }

    /// The matched snap lines of an active snapping move: one line per
    /// axis match, at the planner's `targetCoordinate`, spanning the
    /// displayed image, clipped to it. View-only — drawn over the cached
    /// tiles, never into them, and invisible to export and print.
    private func drawSnapIndicators(scale: Double) {
        // The active move gesture's plan — a floating drag's or an
        // ordinary snapping drag's, whichever is in progress.
        let activePlan: CanvasSnapPlanner.Result?
        if let gesture = floatingMove, !gesture.cancelled {
            activePlan = gesture.plan
        } else if let gesture = moveSnap, !gesture.cancelled {
            activePlan = gesture.plan
        } else {
            activePlan = nil
        }
        guard let plan = activePlan, plan.x != nil || plan.y != nil else { return }
        let imageSize = CGSize(width: Double(document.info.width), height: Double(document.info.height))
        // The displayed image's rect in view points, through the canvas's
        // own point scale so zoom, scroll and backing agree with the tiles.
        let imageRect = CGRect(x: 0, y: 0, width: imageSize.width * scale, height: imageSize.height * scale)
        let accent = NSColor(calibratedRed: 1, green: 0.25, blue: 0.6, alpha: 1)
        let matches: [(isXAxis: Bool, match: CanvasSnapPlanner.AxisMatch)] = [
            (true, plan.x), (false, plan.y),
        ].compactMap { axis, match in match.map { (axis, $0) } }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: imageRect).addClip()
        for (isXAxis, match) in matches {
            let path = NSBezierPath()
            if isXAxis {
                path.move(to: CGPoint(x: match.targetCoordinate * scale, y: imageRect.minY))
                path.line(to: CGPoint(x: match.targetCoordinate * scale, y: imageRect.maxY))
            } else {
                path.move(to: CGPoint(x: imageRect.minX, y: match.targetCoordinate * scale))
                path.line(to: CGPoint(x: imageRect.maxX, y: match.targetCoordinate * scale))
            }
            path.lineWidth = 3
            NSColor.white.setStroke()
            path.stroke()
            path.lineWidth = 1
            accent.setStroke()
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    // MARK: Text tool

    /// Opens the editor: on the topmost visible text layer under `point`,
    /// or for new text with its top-left at `point`.
    private func beginTextEditing(at point: CGPoint) {
        let hit = document.layers.first { $0.kind == .text && $0.isVisible && $0.bounds.contains(point) }
        let editor: TextEditorOverlay
        let context: NewTextContext?
        if let hit, let current = document.textLayer(hit.id) {
            context = nil
            document.selectLayer(hit.id)
            editor = TextEditorOverlay(layer: hit.id, text: current.text, origin: hit.bounds.origin,
                                       settings: current.settings, scale: canvas.scale)
        } else {
            guard !document.targetCommandIsPending, document.acceptsEdits,
                  let window = canvas.window else {
                onStatus?(ImageDocument.DocumentError.busy.localizedDescription)
                return
            }
            context = NewTextContext(document: document, window: window, expectedFloating: document.floatingState)
            var settings = ToolState.shared.textSettings
            settings.color = ToolState.shared.foreground
            editor = TextEditorOverlay(layer: nil, text: "", origin: point, settings: settings, scale: canvas.scale)
        }
        editor.onFinish = { [weak self, weak editor] in
            guard let self, let editor, self.textEditor === editor else { return }
            self.finishTextEditing()
        }
        newTextContext = context
        textEditor = editor
        canvas.addSubview(editor)
        guard textEditor === editor else { return }
        canvas.window?.makeFirstResponder(editor)
        guard textEditor === editor else { return }
        onStatus?("Type the text. Escape or a click outside applies it.")
    }

    /// Applies what was typed: new text becomes a text layer, a changed
    /// layer gets its new text, and nothing changes otherwise.
    func finishTextEditing() {
        guard let editor = textEditor else { return }
        let context = newTextContext
        textEditor = nil
        newTextContext = nil
        let text = editor.string
        editor.removeFromSuperview()
        if editor.textLayer != nil {
            canvas.window?.makeFirstResponder(canvas)
        } else if let context, let window = context.window,
                  canvas.window === window, !context.document.isClosing {
            window.makeFirstResponder(canvas)
        }

        if let layer = editor.textLayer {
            guard editor.hasChanges else { return }
            if text.isEmpty {
                // Committing an emptied editor removes its text layer as
                // one undoable edit. Saving must not resurrect old text.
                guard document.layers.contains(where: { $0.id == layer }) else { return }
            }
            document.updateText(layer, text: text, settings: nil)
        } else if !text.isEmpty {
            guard let context, let window = context.window, canvas.window === window,
                  document === context.document, !context.document.isClosing else {
                onStatus?("The original image window is no longer available for this text edit.")
                return
            }
            var settings = ToolState.shared.textSettings
            settings.color = ToolState.shared.foreground
            context.document.addText(text, settings: settings, at: editor.origin,
                                     expectedFloating: context.expectedFloating)
        }
    }

    /// The canvas zoom changed while editing.
    func canvasScaleDidChange() {
        textEditor?.setScale(canvas.scale)
    }

    // MARK: Transform tool

    /// Starts or continues the session on the selected layer and grabs the
    /// handle under the pointer. A double-click applies.
    private func beginTransformDrag(at point: CGPoint, clickCount: Int) {
        if document.isMaskTargetActive {
            // The transform session describes the layer's bounds; a mask
            // target cannot be moved or transformed on its own.
            onStatus?("Select the layer to transform; a mask cannot be moved or transformed.")
            dragTool = nil
            return
        }
        if document.isChannelTargetActive {
            onStatus?("Return to Layers before transforming; the current channel cannot be transformed.")
            dragTool = nil
            return
        }
        guard document.activeDrawable != nil else {
            onStatus?("Select a layer to transform after the target change finishes.")
            dragTool = nil
            return
        }
        guard let layer = document.layers.first(where: { $0.id == document.activeLayer }),
              layer.bounds.width > 0, layer.bounds.height > 0 else {
            onStatus?("Select a layer to transform.")
            dragTool = nil
            return
        }
        // A session for another layer, or for bounds an undo has since
        // changed, no longer describes the layer.
        if transformSession?.layer != layer.id || transformSession?.original != layer.bounds {
            transformSession = LayerTransformSession(layer: layer.id, bounds: layer.bounds)
        }
        guard let session = transformSession else { return }

        let handle = session.handle(at: point, tolerance: Self.handleReach / canvas.scale)
        if clickCount == 2, handle == .move {
            applyTransform()
            dragTool = nil
            return
        }
        transformDrag = session.beginDrag(handle, at: point)
        transformDragCurrent = point
        canvas.needsDisplay = true
    }

    /// Whether `session` still describes its layer as the document has it.
    private func isCurrent(_ session: LayerTransformSession) -> Bool {
        document.activeDrawable == session.layer
            && document.layers.first { $0.id == session.layer }?.bounds == session.original
    }

    private func currentLayerSession() -> LayerTransformSession? {
        guard document.activeDrawable == document.activeLayer,
              let layer = document.layers.first(where: { $0.id == document.activeLayer }),
              layer.bounds.width > 0, layer.bounds.height > 0 else { return nil }
        return LayerTransformSession(layer: layer.id, bounds: layer.bounds)
    }

    private func applyTransform() {
        defer {
            transformSession = nil
            transformDrag = nil
            canvas.needsDisplay = true
        }
        guard let session = transformSession, !session.isIdentity else { return }
        // The box describes the layer as it was when the drag began; an
        // undo, or a change from a menu, may have moved or resized it since.
        guard isCurrent(session) else {
            onStatus?("The layer changed, so the transform was not applied.")
            return
        }

        document.transformLayer(session.layer, matrix: session.matrix,
                                interpolation: ToolState.shared.transformInterpolation)
        onStatus?("Transformed.")
    }

    private func cancelTransform(message: String?) {
        transformSession = nil
        transformDrag = nil
        canvas.needsDisplay = true
        if let message { onStatus?(message) }
    }

    /// The box the layer will fill, with a rule-of-thirds grid, handles at
    /// the corners and edges, and its center.
    private func drawTransform(scale: Double) {
        // Before the first press, the selected layer's own box shows where
        // the handles are.
        guard ToolState.shared.current == .transform,
              let session = transformSession.flatMap({ isCurrent($0) ? $0 : nil }) ?? currentLayerSession()
        else { return }
        let toView = { (point: CGPoint) in NSPoint(x: point.x * scale, y: point.y * scale) }
        let corners = session.corners.map(toView)

        let outline = NSBezierPath()
        outline.move(to: corners[0])
        corners.dropFirst().forEach { outline.line(to: $0) }
        outline.close()
        EngineCanvasView.strokeMarchingAnts(outline, phase: 0)

        let grid = NSBezierPath()
        for fraction in [1.0 / 3, 2.0 / 3] {
            grid.move(to: Self.mix(corners[0], corners[1], fraction))
            grid.line(to: Self.mix(corners[3], corners[2], fraction))
            grid.move(to: Self.mix(corners[0], corners[3], fraction))
            grid.line(to: Self.mix(corners[1], corners[2], fraction))
        }
        NSColor(calibratedWhite: 1, alpha: 0.6).setStroke()
        grid.lineWidth = 1
        grid.stroke()

        for point in corners + session.edgeMiddles.map(toView) {
            let square = NSRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7)
            NSColor.white.setFill()
            square.fill()
            NSColor.black.setStroke()
            NSBezierPath(rect: square.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
        let center = toView(session.center)
        let dot = NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6))
        NSColor.white.setFill()
        dot.fill()
        NSColor.black.setStroke()
        dot.stroke()
    }

    private static func mix(_ a: NSPoint, _ b: NSPoint, _ t: Double) -> NSPoint {
        NSPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
    }

    /// The area a pending crop keeps, with everything outside it dimmed.
    private func drawPendingCrop(scale: Double) {
        guard let rect = pendingCrop else { return }
        let keep = NSRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
        let shade = NSBezierPath(rect: canvas.bounds)
        shade.append(NSBezierPath(rect: keep).reversed)
        NSColor(calibratedWhite: 0, alpha: 0.45).setFill()
        shade.fill()
        EngineCanvasView.strokeMarchingAnts(NSBezierPath(rect: keep), phase: 0)
    }
}
