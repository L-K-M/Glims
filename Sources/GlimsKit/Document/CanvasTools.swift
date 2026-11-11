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

    /// A request survives pointer release while its counted read/selection
    /// acknowledgment is pending. It never retains an NSEvent or another
    /// window's mutable current target.
    @MainActor
    private final class PickedMove {
        enum Phase: Equatable { case query, selection, move, anchor }
        weak var window: NSWindow?
        let document: ImageDocument
        let expected: EngineSession.FloatingState
        let floatingBounds: CGRect?
        let start: CGPoint
        var revision: ImageDocument.MoveTargetRevision
        var latest: CGPoint
        var released = false
        var cancelled = false
        var phase = Phase.query
        var row: EngineSession.Layer?
        var ownership: ImageDocument.MoveSelectionOwnership?
        var proposed: CGRect?
        var plan = CanvasSnapPlanner.Result.none

        init(window: NSWindow, document: ImageDocument, start: CGPoint) {
            self.window = window; self.document = document; self.start = start; self.latest = start
            expected = document.floatingState
            floatingBounds = document.layers.first(where: { $0.id == document.floatingState.floating })?.bounds
            revision = document.moveTargetRevision
        }
    }
    private var pickedMove: PickedMove?
    private var pickedMoveWasRequested = false

    /// A selection gesture with an active float. Release may arrive before
    /// the counted opacity read returns.
    @MainActor
    private final class FloatingShape {
        enum Hit {
            case pending, shape
            case move(EngineSession.Layer)
        }

        enum RegionAction {
            case anchor
            case selectColor(EngineSession.SelectOptions)
        }

        struct Release {
            let point: CGPoint
            let elapsed: TimeInterval
            let flags: NSEvent.ModifierFlags
            let options: EngineSession.SelectOptions
        }

        weak var window: NSWindow?
        let document: ImageDocument
        let expected: EngineSession.FloatingState
        let revision: ImageDocument.MoveTargetRevision
        let tool: ToolID
        let start: CGPoint
        let pressedAt: TimeInterval
        let clickInterval: TimeInterval
        let operation: EngineSession.SelectOperation
        let regionAction: RegionAction?
        var hit: Hit
        var latest: CGPoint
        var lassoPoints: [CGPoint]
        var receivedDrag = false
        var release: Release?
        var preview: (rect: CGRect, plan: CanvasSnapPlanner.Result)?

        init(window: NSWindow, document: ImageDocument, tool: ToolID, start: CGPoint,
             pressedAt: TimeInterval, clickInterval: TimeInterval, operation: EngineSession.SelectOperation,
             checkOpacity: Bool, regionOptions: EngineSession.SelectOptions?) {
            self.window = window
            self.document = document
            self.tool = tool
            self.start = start
            self.pressedAt = pressedAt
            self.clickInterval = clickInterval
            self.operation = operation
            regionAction = regionOptions.map { checkOpacity ? RegionAction.anchor : .selectColor($0) }
            expected = document.floatingState
            revision = document.moveTargetRevision
            latest = start
            lassoPoints = tool == .lasso ? [start] : []
            hit = checkOpacity ? .pending : .shape
        }
    }
    private var floatingShape: FloatingShape?

    /// The tool for the current drag; Space and Command switch tools
    /// temporarily meanwhile.
    private var dragTool: ToolID?
    private var tabletStrokeCapture: TabletStrokeInput.Capture?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var dragOperation = EngineSession.SelectOperation.replace
    private var selectionDragFlags: NSEvent.ModifierFlags = []

    /// The same image-space bounds drive the rubber band and its commit.
    var selectionDragRect: CGRect? {
        if let request = floatingShape {
            guard case .shape = request.hit else { return nil }
        }
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
    private var springLetters = SpringToolLettersState()
    private var selectingSpringTool = false
    private var observedSelectionRevision = ToolState.shared.selectionRevision
    private var observedMoveTargetMode = ToolState.shared.moveTargetMode
    private var hintFlags: NSEvent.ModifierFlags = []
    private var toolObserver: UUID?
    private var hintEventsStopped = false
    /// The crop rectangle waiting for Return (image pixels).
    private(set) var pendingCrop: CGRect?
    /// The Transform tool's pending transform, waiting for Return.
    private(set) var transformSession: LayerTransformSession?
    private var transformDrag: LayerTransformSession.Drag?
    private var transformMode: LayerTransformSession.Mode = .scaleRotate
    private(set) var transformCommitIsPending = false
    private var colorPickGeneration: UInt64 = 0
    private var textPickGeneration: UInt64 = 0
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
    /// Requests owned consent before restoring retained rasterized text.
    /// Consent restores only; a fresh click starts an editing gesture.
    var onTextNeedsRestore: ((_ layer: Int32, _ stateVersion: Int) -> Void)?
    /// View-only refreshes never use onStatus, which clears error latches.
    var onHintChange: ((ToolHintPolicy.Refresh) -> Void)?

    var hint: String {
        // An idle hint has modifier state, not a tablet device event. The
        // accepted drag already captures any matching hardware eraser tool.
        let acceptedTool = dragTool ?? (pickedMove != nil ? .move : nil)
        let tool = acceptedTool ?? keyboard.pointerTool(current: ToolState.shared.current, flags: hintFlags)
        var flags = hintFlags
        if keyboard.optionIsDown(flags: hintFlags) { flags.insert(.option) }
        if tool == .transform {
            if transformCommitIsPending { return "Applying the transform…" }
            if transformSession?.isIdentity != false {
                switch transformPreview?.mode ?? transformMode {
                case .scaleRotate: break
                case .skew: return "Drag an edge handle along its edge to skew; drag inside to move."
                case .distort: return "Drag a corner independently, or an edge to move both corners."
                case .perspective: return "Drag a corner horizontally or vertically; the first movement fixes the direction."
                }
            }
        }
        let phase: ToolHintPolicy.Phase
        if acceptedTool != nil { phase = .dragging }
        else if tool == .text, textEditor != nil { phase = .textEditing }
        else if tool == .crop, let crop = pendingCrop { phase = .cropReady(width: Int(crop.width), height: Int(crop.height)) }
        else if tool == .transform, transformSession?.isIdentity == false { phase = .transformReady }
        else { phase = .idle }
        return ToolHintPolicy.hint(tool: tool, phase: phase, flags: flags)
    }

    private func hintChanged(_ reason: ToolHintPolicy.Refresh) {
        if !hintEventsStopped { onHintChange?(reason) }
    }

    /// Physical modifiers can lose their release event when focus leaves.
    /// This changes presentation/held keys only, never accepted native work.
    func resetHintModifiers() {
        keyboard = CanvasKeyboardState()
        hintFlags = []
        hintChanged(.context)
    }

    func stopHintEvents() {
        resetHintModifiers()
        hintEventsStopped = true
        if let toolObserver { ToolState.shared.removeObserver(toolObserver) }
        toolObserver = nil
    }

    func hintModifiersChanged(_ flags: NSEvent.ModifierFlags) {
        hintFlags = flags
        keyboard.modifiersChanged(flags)
        hintChanged(.context)
    }
    /// Asks the window to zoom one step in or out, keeping `point` (image
    /// pixels) in view.
    var onZoom: ((_ zoomIn: Bool, _ point: CGPoint) -> Void)?
    /// Fires after the transform session or its validity changes, so the
    /// options' numeric rows can refresh.
    var onTransformSessionChange: (() -> Void)?
    private(set) var transformGeneration: UInt64 = 0

    /// Pointer gestures commit on release; crop and transform previews
    /// commit on Return. A background file operation must wait for these
    /// edits rather than blocking their eventual commit.
    var hasPendingInteraction: Bool {
        dragTool != nil || pickedMove != nil || floatingShape != nil || pendingCrop != nil || textEditor != nil
            || transformSession.map { !$0.isIdentity } == true
    }

    init(canvas: EngineCanvasView) {
        self.canvas = canvas
        // The Transform tool's box shows as soon as the tool is picked, and
        // an unapplied transform goes away when another tool is.
        toolObserver = ToolState.shared.observe { [weak self] in
            guard let self else { return }
            let state = ToolState.shared
            let changed = self.observedSelectionRevision != state.selectionRevision
            let modeChanged = self.observedMoveTargetMode != state.moveTargetMode
            self.observedSelectionRevision = state.selectionRevision
            self.observedMoveTargetMode = state.moveTargetMode
            // The Move options can change without selecting a tool again.
            if modeChanged {
                self.canvas.guideDrag.cancel()
                self.cancelMoveSnap()
                self.cancelFloatingMove()
                self.hintChanged(.context)
            }
            guard changed else { self.canvas.needsDisplay = true; return }
            // A spring selection affects the next press, never an accepted
            // drag/compound preview whose tool and settings were captured.
            if self.selectingSpringTool && (self.hasPendingInteraction || self.canvas.guideDrag.isActive) {
                self.canvas.needsDisplay = true
                return
            }
            if ToolState.shared.current != .transform, self.transformSession != nil {
                self.cancelTransform(message: nil)
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
            self.cancelFloatingShape()
            self.canvas.needsDisplay = true
            self.hintChanged(.context)
        }
    }

    deinit {
        // Fallback for a canvas discarded without its normal renderer close.
        // Do not retain the controller while crossing to the main actor.
        if let token = toolObserver {
            Task { @MainActor in ToolState.shared.removeObserver(token) }
        }
    }

    /// Space is the temporary hand, Command moves the layer, then a matching
    /// hardware eraser may override the user's selected tool for this press.
    private func pointerTool(for event: NSEvent) -> ToolID {
        let tool = TabletEraserProximity.shared.effectiveTool(selected: ToolState.shared.current, event: event)
        return keyboard.pointerTool(current: tool, flags: event.modifierFlags)
    }

    // MARK: Pointer

    func mouseDown(with event: NSEvent) {
        // An accepted paint gesture owns its tool, target and input format
        // until End. A second press cannot replace those captured choices.
        guard !document.strokeIsActive else { return }
        tabletStrokeCapture = nil
        cancelPickedMove()
        pickedMoveWasRequested = false
        cancelFloatingShape()
        hintFlags = event.modifierFlags
        hintChanged(.context)
        defer { hintChanged(.afterAction) }
        let point = canvas.imagePoint(for: event)
        let tool = pointerTool(for: event)
        let optionDown = keyboard.optionIsDown(flags: event.modifierFlags)
        guard document.acceptsEdits || [.hand, .zoom, .eyedropper].contains(tool) else {
            onStatus?("Finish the current operation before editing the image.")
            return
        }
        dragTool = tool
        springLetters.pointerBegan(using: tool, selectionRevision: ToolState.shared.selectionRevision)
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
            tabletStrokeCapture = TabletEraserProximity.shared.strokeCapture(for: event)
            let brush = ToolState.shared.brush(for: tool)
            if let capture = tabletStrokeCapture {
                guard let sample = canvas.tabletStrokePoint(for: event, capture: capture) else {
                    tabletStrokeCapture = nil; dragTool = nil
                    onStatus?("That tablet sample is outside the supported range."); return
                }
                document.beginTabletStroke(at: sample, brush: brush)
            } else {
                guard let point = canvas.strokePoint(for: event) else {
                    dragTool = nil; onStatus?("That pointer sample is invalid."); return
                }
                document.beginStroke(at: point, brush: brush)
            }
            return
        }

        switch tool {
        case .rectangleSelect, .ellipseSelect, .lasso:
            dragStart = point
            dragCurrent = point
            lassoPoints = [point]
            dragOperation = Self.operation(for: event.modifierFlags)
            selectionDragFlags = event.modifierFlags
            if document.floatingState.isActive {
                beginFloatingShape(tool, at: point, event: event)
            }
        case .magicWand, .selectByColor:
            var options = ToolState.shared.selectOptions
            options.operation = Self.operation(for: event.modifierFlags)
            options.contiguous = tool == .magicWand
            if document.floatingState.isActive {
                beginFloatingShape(tool, at: point, event: event, regionOptions: options)
            } else {
                document.selectColor(at: point, options: options)
            }
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
            // Text entry owns subsequent letters. Do this before the overlay
            // takes first responder so focus cleanup cannot restore another
            // tool and prematurely finish the editor being created.
            springLetters.promote()
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
            if ToolState.shared.current == .move,
               ToolState.shared.moveTargetMode == .pickLayerOrGuide,
               !keyboard.commandHeld, !event.modifierFlags.contains(.command) {
                beginPickedMove(at: point)
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
        hintFlags = event.modifierFlags
        defer { hintChanged(.afterAction) }
        // A guide drag owns the gesture: view-only ghost, no native call.
        if canvas.guideDrag.mouseDragged(with: event) { return }
        if let request = floatingShape {
            guard request.release == nil else { return }
            request.receivedDrag = true
            request.latest = canvas.imagePoint(for: event)
            if request.tool == .lasso || request.regionAction != nil {
                guard request.latest.x.isFinite, request.latest.y.isFinite else { return cancelFloatingShape() }
            }
            if request.tool == .lasso {
                _ = Self.recordLassoPoint(request.latest, in: &request.lassoPoints)
            }
            dragCurrent = request.latest
            selectionDragFlags = event.modifierFlags
            updateFloatingShapePreview(request)
            return
        }
        if pickedMoveWasRequested {
            if let request = pickedMove, !request.released {
                request.latest = canvas.imagePoint(for: event)
                updatePickedMove(request)
            }
            return
        }
        guard let tool = dragTool else { return }
        let point = canvas.imagePoint(for: event)

        if tool.paintTool != nil {
            if let capture = tabletStrokeCapture {
                if let point = canvas.tabletStrokePoint(for: event, capture: capture) { document.continueTabletStroke([point]) }
            } else if let point = canvas.strokePoint(for: event) { document.continueStroke([point]) }
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
            if Self.recordLassoPoint(point, in: &lassoPoints) {
                canvas.needsDisplay = true
            }
        case .transform:
            guard var drag = transformDrag else { return }
            transformDragCurrent = point
            transformSession?.update(&drag, to: point, constrained: event.modifierFlags.contains(.shift))
            transformDrag = drag
            canvas.needsDisplay = true
            transformSessionDidChange()
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
        hintFlags = event.modifierFlags
        defer {
            dragTool = nil
            tabletStrokeCapture = nil
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
            finishSpringInteractionIfReady()
            hintChanged(.afterAction)
        }
        // An intentional release of a guide drag commits exactly one
        // addGuide/moveGuide/removeGuide action.
        if canvas.guideDrag.mouseUp(with: event) { return }
        if let request = floatingShape {
            guard request.release == nil else { return }
            let point = canvas.imagePoint(for: event)
            let elapsed = event.timestamp - request.pressedAt
            guard point.x.isFinite, point.y.isFinite, elapsed.isFinite, elapsed >= 0 else {
                return cancelFloatingShape()
            }
            var options = ToolState.shared.selectOptions
            options.operation = request.operation
            request.latest = point
            request.release = .init(point: point, elapsed: elapsed, flags: event.modifierFlags, options: options)
            updateFloatingShapePreview(request)
            finishFloatingShape(request)
            return
        }
        if pickedMoveWasRequested {
            if let request = pickedMove {
                request.latest = canvas.imagePoint(for: event)
                request.released = true
                updatePickedMove(request)
                finishPickedMove(request)
            }
            return
        }
        guard let tool = dragTool else { return }

        if tool.paintTool != nil {
            // Invalid release coordinates/axes still finish accepted work.
            defer { document.endStroke() }
            if let capture = tabletStrokeCapture {
                if let point = canvas.tabletStrokePoint(for: event, capture: capture) { document.continueTabletStroke([point]) }
            } else if let point = canvas.strokePoint(for: event) { document.continueStroke([point]) }
            return
        }
        var options = ToolState.shared.selectOptions
        options.operation = dragOperation
        let end = canvas.imagePoint(for: event)
        switch tool {
        case .path:
            pathTool.mouseUp()
        case .transform:
            if var drag = transformDrag {
                transformSession?.update(&drag, to: end, constrained: event.modifierFlags.contains(.shift))
            }
            transformDrag = nil
            transformSessionDidChange()
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
        cancelPickedMove()
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
        cancelPickedMove()
        guard let gesture = floatingMove, !gesture.cancelled else { return }
        gesture.cancelled = true
        gesture.plan = .none
        canvas.needsDisplay = true
    }

    // MARK: Native opacity-picked Move

    private func pickedMoveOwnerIsLive(_ request: PickedMove) -> Bool {
        // Explicit tool selections cancel in the ToolState observer. A
        // temporary Spring selection leaves the captured Move owner intact.
        guard !request.cancelled, pickedMove === request,
              let window = request.window, canvas.window === window,
              canvas.document === request.document, !request.document.isClosing,
              request.document.acceptsEdits,
              request.document.floatingState == request.expected,
              ToolState.shared.moveTargetMode == .pickLayerOrGuide else { return false }
        if let bounds = request.floatingBounds {
            guard request.document.layers.first(where: { $0.id == request.expected.floating })?.bounds == bounds else { return false }
        }
        return true
    }

    private func beginPickedMove(at point: CGPoint) {
        pickedMoveWasRequested = true
        moveSnap = nil; moveSnapWasRequested = false
        floatingMove = nil; floatingMoveWasRequested = false
        guard let window = canvas.window else { return }
        let request = PickedMove(window: window, document: document, start: point)
        pickedMove = request
        document.readMoveHit(at: point, expected: request.expected) { [weak self, request] result in
            guard let self, !request.cancelled, self.pickedMove === request else { return }
            guard self.pickedMoveOwnerIsLive(request),
                  request.document.moveTargetRevision == request.revision,
                  request.document.pendingWork == 0 else { return self.cancelPickedMove() }
            switch result {
            case .failure(let error):
                self.onStatus?(error.localizedDescription)
                self.cancelPickedMove()
            case .success(nil): self.cancelPickedMove()
            case .success(let row?):
                request.row = row
                if request.expected.isActive {
                    request.phase = row.id == request.expected.floating ? .move : .anchor
                    self.updatePickedMove(request)
                    self.finishPickedMove(request)
                } else {
                    request.phase = .selection
                    request.document.selectMoveHit(row, expected: request.expected, revision: request.revision) { [weak self, request] selection in
                        switch selection {
                        case .failure(let error):
                            guard let self, self.pickedMove === request else { return }
                            self.onStatus?(error.localizedDescription)
                            self.cancelPickedMove()
                        case .success(let owned):
                            request.ownership = owned
                            guard let self else {
                                request.document.restoreMoveSelection(owned)
                                return
                            }
                            guard self.pickedMoveOwnerIsLive(request), request.document.ownsMoveSelection(owned) else {
                                if self.pickedMove === request { self.cancelPickedMove() }
                                else { request.document.restoreMoveSelection(owned) }
                                return
                            }
                            request.revision = request.document.moveTargetRevision
                            request.phase = .move
                            self.updatePickedMove(request)
                            self.finishPickedMove(request)
                        }
                    }
                }
            }
        }
    }

    private func updatePickedMove(_ request: PickedMove) {
        guard request.phase == .move, let row = request.row else { return }
        guard pickedMoveOwnerIsLive(request), request.document.moveTargetRevision == request.revision,
              request.document.layers.contains(where: { $0.id == row.id && $0.bounds == row.bounds }),
              request.ownership.map(request.document.ownsMoveSelection) ?? request.expected.isActive else {
            return cancelPickedMove()
        }
        guard let preview = pickedMovePreview(row, from: request.start, to: request.latest) else {
            onStatus?("That move is outside the supported layer coordinates.")
            return cancelPickedMove()
        }
        request.proposed = preview.rect
        request.plan = preview.plan
        canvas.needsDisplay = true
    }

    private func pickedMovePreview(_ row: EngineSession.Layer, from start: CGPoint, to point: CGPoint)
        -> (rect: CGRect, plan: CanvasSnapPlanner.Result)? {
        let raw = row.bounds.offsetBy(dx: point.x - start.x, dy: point.y - start.y)
        guard Self.isUsableRect(raw) else { return nil }
        let plan: CanvasSnapPlanner.Result
        if canvas.snapTo.isEmpty || point == start { plan = .none }
        else {
            plan = CanvasSnapPlanner.plan(input: SnapTargetCache.plannerInput(
                movingRect: raw,
                imageSize: CGSize(width: Double(document.info.width), height: Double(document.info.height)),
                guides: document.guides, grid: document.grid, layers: document.layers, moving: row.id),
                config: .init(targets: canvas.snapTo.targets), canvasScale: canvas.scale)
        }
        let preview = SnapTargetCache.pixelMove(bounds: row.bounds,
            proposed: raw.offsetBy(dx: plan.dx, dy: plan.dy), plan: plan)
        let offset = CGSize(width: preview.rect.minX - row.bounds.minX,
                            height: preview.rect.minY - row.bounds.minY)
        guard Self.isUsableRect(preview.rect),
              PickedMoveGeometry.canTranslate(row, in: document.layers, by: offset) else { return nil }
        return preview
    }

    private func finishPickedMove(_ request: PickedMove) {
        guard request.released, request.phase == .move || request.phase == .anchor else { return }
        guard pickedMoveOwnerIsLive(request), request.document.moveTargetRevision == request.revision else {
            return cancelPickedMove()
        }
        let ownership = request.ownership
        request.ownership = nil
        pickedMove = nil // Consume before a document callback can re-enter.
        defer { finishTrackedPointerInteraction() }
        if request.phase == .anchor {
            request.document.anchorPickedFloating(request.expected)
        } else if let row = request.row, let proposed = request.proposed {
            let offset = CGSize(width: proposed.minX - row.bounds.minX, height: proposed.minY - row.bounds.minY)
            request.document.movePickedLayer(row, expected: request.expected, ownership: ownership, by: offset)
        }
    }

    func cancelPickedMove() {
        guard let request = pickedMove else { return }
        request.cancelled = true
        pickedMove = nil
        request.proposed = nil; request.plan = .none
        defer { finishTrackedPointerInteraction() }
        if let owned = request.ownership {
            request.ownership = nil
            request.document.restoreMoveSelection(owned)
        }
    }

    private func finishTrackedPointerInteraction() {
        dragTool = nil
        dragStart = nil; dragCurrent = nil
        selectionDragFlags = []
        canvas.needsDisplay = true
        finishSpringInteractionIfReady()
        hintChanged(.afterAction)
    }

    // MARK: Selection gestures with an active float

    private func beginFloatingShape(_ tool: ToolID, at point: CGPoint, event: NSEvent,
                                    regionOptions: EngineSession.SelectOptions? = nil) {
        let interval = NSEvent.doubleClickInterval
        guard let window = canvas.window, !document.targetCommandIsPending, !document.strokeIsActive,
              point.x.isFinite, point.y.isFinite, event.timestamp.isFinite, interval.isFinite, interval > 0 else {
            finishTrackedPointerInteraction()
            return
        }
        let checkOpacity = event.modifierFlags.intersection([.shift, .option]).isEmpty
        let request = FloatingShape(window: window, document: document, tool: tool, start: point,
            pressedAt: event.timestamp, clickInterval: interval, operation: regionOptions?.operation ?? dragOperation,
            checkOpacity: checkOpacity, regionOptions: regionOptions)
        floatingShape = request
        guard checkOpacity else { return }

        document.readMoveHit(at: point, expected: request.expected, requireUnlockedFloatingHit: true) { [weak self, request] result in
            guard let self, self.floatingShape === request else { return }
            guard self.floatingShapeIsLive(request) else { return self.cancelFloatingShape() }
            switch result {
            case .failure(let error):
                self.cancelFloatingShape()
                self.onStatus?(error.localizedDescription)
            case .success(let row):
                if let row, row.id == request.expected.floating { request.hit = .move(row) }
                else { request.hit = .shape }
                self.updateFloatingShapePreview(request)
                self.finishFloatingShape(request)
            }
        }
    }

    private func floatingShapeIsLive(_ request: FloatingShape) -> Bool {
        floatingShape === request && request.window != nil && canvas.window === request.window
            && document === request.document && document.acceptsEdits && !document.strokeIsActive
            && !document.targetCommandIsPending && document.floatingState == request.expected
            && document.moveTargetRevision == request.revision
    }

    private func updateFloatingShapePreview(_ request: FloatingShape) {
        guard floatingShapeIsLive(request) else { return cancelFloatingShape() }
        if case .move(let row) = request.hit {
            guard let preview = pickedMovePreview(row, from: request.start, to: request.latest) else {
                cancelFloatingShape()
                onStatus?("That move is outside the supported layer coordinates.")
                return
            }
            request.preview = preview
        }
        canvas.needsDisplay = true
    }

    private func finishFloatingShape(_ request: FloatingShape) {
        guard let release = request.release else { return }
        if case .pending = request.hit { return }
        // Preview validation can already have retired this request.
        guard floatingShape === request else { return }
        guard floatingShapeIsLive(request) else { return cancelFloatingShape() }
        floatingShape = nil
        defer { finishTrackedPointerInteraction() }

        switch request.hit {
        case .pending: return
        case .move(let row):
            guard release.point != request.start, let preview = request.preview else { return }
            let offset = CGSize(width: preview.rect.minX - row.bounds.minX,
                                height: preview.rect.minY - row.bounds.minY)
            request.document.movePickedLayer(row, expected: request.expected, ownership: nil, by: offset,
                                           requireUnlockedPixels: true)
        case .shape:
            if let action = request.regionAction {
                // GIMP 3.2.8 (7addd2b7) resolves Region's press action on any
                // noncancel release. Only SELECT uses the selection combiner.
                switch action {
                case .anchor:
                    request.document.anchorPickedFloating(request.expected)
                case .selectColor(let options):
                    request.document.selectFloatingColor(at: request.start, options: options, expected: request.expected)
                }
                return
            }
            // Lasso confirms both a short click and a long stationary press.
            // Delivered motion disqualifies either, even at the press point.
            if !request.receivedDrag, release.point == request.start,
               request.tool == .lasso || release.elapsed <= request.clickInterval {
                request.document.anchorPickedFloating(request.expected, selectingWith: request.operation)
                return
            }
            if request.tool == .lasso {
                guard request.lassoPoints.count >= 3 else { return }
                request.document.selectFloatingShape(.polygon(request.lassoPoints), options: release.options,
                                                     expected: request.expected)
                return
            }
            guard let rect = SelectionDragGeometry.rect(start: request.start, end: release.point,
                constrained: release.flags.contains(.shift), fromCenter: release.flags.contains(.option)),
                rect.width >= 1, rect.height >= 1 else { return }
            let shape: EngineSession.SelectShape = request.tool == .ellipseSelect ? .ellipse(rect) : .rectangle(rect)
            request.document.selectFloatingShape(shape, options: release.options, expected: request.expected)
        }
    }

    func cancelFloatingShape() {
        guard floatingShape != nil else { return }
        floatingShape = nil
        finishTrackedPointerInteraction()
    }

    private static func recordLassoPoint(_ point: CGPoint, in points: inout [CGPoint]) -> Bool {
        guard let last = points.last, hypot(point.x - last.x, point.y - last.y) >= 1 else { return false }
        points.append(point)
        return true
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
        colorPickGeneration &+= 1
        guard point.x >= 0, point.y >= 0, point.x < Double(document.info.width),
              point.y < Double(document.info.height) else { return }
        if EngineActivity.shared.isRenderingTransformPreview {
            let generation = colorPickGeneration
            let revision = ToolState.shared.selectionRevision
            let foreground = ToolState.shared.foreground
            EngineActivity.shared.whenReadyForSynchronousRead { [weak self] in
                guard let self, !self.document.isClosing,
                      self.colorPickGeneration == generation,
                      ToolState.shared.selectionRevision == revision,
                      ToolState.shared.foreground == foreground else { return }
                self.pickColor(at: point)
            }
            return
        }
        do {
            let sample = try document.session.sampleColor(document.image,
                x: Int(floor(point.x)), y: Int(floor(point.y)))
            // Editing colors use bounded sRGB and opaque alpha. Keep the
            // native fraction; clipping is separate from display quantization.
            let components = sample.alpha > 0 ? [sample.red, sample.green, sample.blue] : [0, 0, 0]
            let bounded = components.map { min(1, max(0, $0)) }
            ToolState.shared.foreground = NSColor(srgbRed: bounded[0], green: bounded[1], blue: bounded[2], alpha: 1)
            ToolState.shared.notifyChange()
            if components != bounded {
                onStatus?("The sampled color is outside sRGB; the tool color is clipped to 0–1.")
            }
        } catch {
            onStatus?("Could not sample the image color: \(error)")
        }
    }

    // MARK: Keys

    private static let returnKeys: Set<Int> = [36, 76]      // Return, keypad Enter
    private static let escapeKey = 53
    private static let tabKey = 48
    /// Temporary-tool modifiers, tool shortcuts, Space for the hand, digits,
    /// brackets and arrows. Returns false for keys it does not handle.
    func keyDown(with event: NSEvent) -> Bool {
        hintFlags = event.modifierFlags
        defer { hintChanged(.afterAction) }
        let keyCode = Int(event.keyCode)
        if keyCode == Self.escapeKey {
            colorPickGeneration &+= 1
            textPickGeneration &+= 1
        }
        // Field editors and the on-canvas text overlay own ordinary typing,
        // including Space, digits and the color/Quick Mask letters.
        if textEditor != nil || canvas.window?.firstResponder is NSTextView { return false }

        if keyCode == Self.escapeKey,
           floatingShape != nil || dragTool == .rectangleSelect || dragTool == .ellipseSelect || dragTool == .lasso {
            cancelFloatingShape()
            dragTool = nil; dragStart = nil; dragCurrent = nil
            selectionDragFlags = []; lassoPoints = []
            canvas.needsDisplay = true
            onStatus?("Selection cancelled.")
            cancelSpringTools()
            return true
        }

        // Command and Option are temporary-tool modifiers; track their held
        // state before the plain-key guard below rejects their flags.
        if CanvasKeyboardPolicy.isTemporaryModifierKey(keyCode: keyCode) {
            keyboard.keyDown(keyCode)
            hintChanged(.context)
            return true
        }

        guard CanvasKeyboardPolicy.allowsPlainKey(event.modifierFlags),
              let key = event.charactersIgnoringModifiers else { return false }
        if transformSession != nil, Self.returnKeys.contains(keyCode) {
            applyTransform()
            return true
        }
        if transformSession != nil, keyCode == Self.escapeKey {
            guard !transformCommitIsPending else { return true }
            cancelTransform(message: "Transform cancelled.")
            cancelSpringTools()
            return true
        }
        if (moveSnap != nil || floatingMove != nil || pickedMove != nil), keyCode == Self.escapeKey {
            // Escape cancels the snapping or floating move: preview and
            // indicators clear and the release commits nothing.
            cancelMoveSnap()
            cancelFloatingMove()
            onStatus?("Move cancelled.")
            cancelSpringTools()
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
            finishSpringInteractionIfReady()
            return true
        }
        if pendingCrop != nil, keyCode == Self.escapeKey {
            pendingCrop = nil
            canvas.needsDisplay = true
            onStatus?("Crop cancelled.")
            cancelSpringTools()
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
        case "f":
            if !event.isARepeat {
                (canvas.window?.windowController as? DocumentWindowController)?.cycleScreenMode(nil)
            }
            return true
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
            hintChanged(.context)
            if !event.isARepeat { NSCursor.openHand.set() }
            return true
        }
        if ToolID.group(forShortcut: key) != nil {
            guard springLetters.canPress(keyCode: keyCode, isRepeat: event.isARepeat) else { return true }
            let state = ToolState.shared
            let previous = state.current, revision = state.selectionRevision
            selectingSpringTool = true
            state.select(shortcut: key, cycle: event.modifierFlags.contains(.shift))
            selectingSpringTool = false
            springLetters.press(keyCode: keyCode, at: event.timestamp, previous: previous,
                                previousRevision: revision, selected: state.current,
                                selectedRevision: state.selectionRevision)
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
        if keyCode == Self.escapeKey { return cancelSpringTools() }
        return false
    }

    func keyUp(with event: NSEvent) -> Bool {
        hintFlags = event.modifierFlags
        let keyCode = Int(event.keyCode)
        if springLetters.isHeld(keyCode: keyCode) {
            restoreSpringTool(springLetters.release(keyCode: keyCode, at: event.timestamp,
                                                    selectionRevision: ToolState.shared.selectionRevision))
            return true
        }
        if CanvasKeyboardPolicy.isTemporaryModifierKey(keyCode: keyCode) {
            keyboard.keyUp(keyCode)
            hintChanged(.context)
            return true
        }
        guard event.charactersIgnoringModifiers == " " else { return false }
        keyboard.keyUp(CanvasKeyboardPolicy.spaceKeyCode)
        hintChanged(.context)
        NSCursor.arrow.set()
        return true
    }

    private func restoreSpringTool(_ tool: ToolID?) {
        guard let tool else { return }
        selectingSpringTool = true
        ToolState.shared.select(tool)
        selectingSpringTool = false
    }

    private func finishSpringInteractionIfReady() {
        // Crop and Transform are compound gestures: Return/Cancel, rather
        // than mouse-up, finishes the accepted preview.
        // A released Pick keeps ownership until its counted work resolves.
        guard dragTool == nil, pickedMove == nil, floatingShape == nil, pendingCrop == nil,
              transformSession?.isIdentity != false, textEditor == nil,
              !canvas.guideDrag.isActive else { return }
        restoreSpringTool(springLetters.pointerEnded(selectionRevision: ToolState.shared.selectionRevision))
    }

    /// Focus, window close and Escape abandon held shortcut ownership. Existing
    /// accepted spring paint is ended; local previews cancel without a native move or
    /// an implicit floating anchor. A promoted text editor has no held owner.
    @discardableResult
    func cancelSpringTools() -> Bool {
        colorPickGeneration &+= 1
        textPickGeneration &+= 1
        keyboard = CanvasKeyboardState()
        let ownsInteraction = springLetters.ownsInteraction
        let prior = springLetters.cancel(selectionRevision: ToolState.shared.selectionRevision)
        // A newer explicit selection owns the tool, but the accepted spring
        // gesture still needs its own teardown. Ordinary gestures stay intact.
        if ownsInteraction {
            canvas.guideDrag.cancel()
            cancelMoveSnap(); cancelFloatingMove()
            cancelFloatingShape()
            if dragTool?.paintTool != nil, document.strokeIsActive { document.endStroke() }
            tabletStrokeCapture = nil
            dragTool = nil; dragStart = nil; dragCurrent = nil
            lassoPoints = []; handOrigin = nil; gradientCapture = nil
            selectionDragFlags = []; pendingCrop = nil
            cancelTransform(message: nil)
            canvas.needsDisplay = true
        }
        restoreSpringTool(prior)
        return ownsInteraction || prior != nil
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
        guard dragTool == .transform, var drag = transformDrag else { return }
        transformSession?.update(&drag, to: transformDragCurrent ?? drag.start,
                                 constrained: flags.contains(.shift))
        transformDrag = drag
        canvas.needsDisplay = true
        transformSessionDidChange()
    }

    /// The rubber band or lasso path of a selection being drawn, in view
    /// coordinates (the canvas is flipped).
    func drawOverlay(scale: Double) {
        if dragTool != nil, let preview = floatingShape?.preview {
            let bounds = preview.rect
            let outline = NSBezierPath(rect: NSRect(x: bounds.minX * scale, y: bounds.minY * scale,
                                                    width: bounds.width * scale, height: bounds.height * scale))
            drawSnapIndicators(scale: scale)
            EngineCanvasView.strokeMarchingAnts(outline, phase: 0)
            return
        }
        let path: NSBezierPath
        switch dragTool {
        case .rectangleSelect?, .ellipseSelect?, .lasso?:
            if dragTool == .lasso {
                if let request = floatingShape, case .pending = request.hit { return }
                let points = floatingShape?.lassoPoints ?? lassoPoints
                guard points.count > 1 else { return }
                path = NSBezierPath()
                path.move(to: NSPoint(x: points[0].x * scale, y: points[0].y * scale))
                points.dropFirst().forEach { path.line(to: NSPoint(x: $0.x * scale, y: $0.y * scale)) }
            } else {
                guard let bounds = selectionDragRect else { return }
                let rect = NSRect(x: bounds.minX * scale, y: bounds.minY * scale,
                                  width: bounds.width * scale, height: bounds.height * scale)
                path = dragTool == .ellipseSelect ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
            }
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
            if pickedMoveWasRequested {
                guard let request = pickedMove, !request.cancelled,
                      request.phase == .move, let proposed = request.proposed else { return }
                bounds = proposed
            } else if let gesture = floatingMove {
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
        if let preview = floatingShape?.preview {
            activePlan = preview.plan
        } else if let request = pickedMove, !request.cancelled, request.phase == .move {
            activePlan = request.plan
        } else if let gesture = floatingMove, !gesture.cancelled {
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
        textPickGeneration &+= 1
        if EngineActivity.shared.isRenderingTransformPreview {
            let generation = textPickGeneration
            let revision = ToolState.shared.selectionRevision
            let state = document.stateVersion
            let targetRevision = document.moveTargetRevision
            EngineActivity.shared.whenReadyForSynchronousRead { [weak self] in
                guard let self, !self.document.isClosing, self.document.stateVersion == state,
                      self.document.moveTargetRevision == targetRevision,
                      self.textPickGeneration == generation,
                      ToolState.shared.selectionRevision == revision, self.textEditor == nil else { return }
                self.beginTextEditing(at: point)
            }
            return
        }
        let hit = document.layers.first { layer in
            guard layer.isVisible, layer.bounds.contains(point) else { return false }
            if layer.kind == .text { return true }
            guard let source = document.layerSources[layer.id] else { return false }
            return source.kind == .text && source.isRasterized && source.hasSource
        }
        if let hit, let source = document.layerSources[hit.id], source.kind == .text,
           source.isRasterized, source.hasSource {
            if let request = onTextNeedsRestore {
                request(hit.id, document.stateVersion)
            } else {
                onStatus?("Use Layer > Restore Layer Source before editing this text.")
            }
            return
        }
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
        guard !transformCommitIsPending else {
            onStatus?("Applying the transform…")
            dragTool = nil
            return
        }
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
            transformGeneration &+= 1
            transformSession = LayerTransformSession(layer: layer.id, bounds: layer.bounds)
            transformSession?.setMode(transformMode)
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
        transformSessionDidChange()
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
        var session = LayerTransformSession(layer: layer.id, bounds: layer.bounds)
        session.setMode(transformMode)
        return session
    }

    /// The session the numeric fields show and edit: the pending one while
    /// it still describes its layer, otherwise the selected layer's fresh
    /// box — the same source the overlay draws.
    var transformPreview: LayerTransformSession? {
        transformSession.flatMap { isCurrent($0) ? $0 : nil } ?? currentLayerSession()
    }

    /// Whether a pointer drag owns the preview; a numeric commit meanwhile
    /// would be overwritten by the drag's next update.
    var transformDragInProgress: Bool { transformDrag != nil }

    /// Whether Apply has a pending non-identity transform to commit.
    var transformIsApplicable: Bool {
        transformNumericEditsAllowed && transformSession.map { !$0.isIdentity && isCurrent($0) } == true
    }

    var transformNumericEditsAllowed: Bool {
        ToolState.shared.current == .transform && transformModeSelectionAllowed
    }

    var transformModeSelectionAllowed: Bool {
        guard document.acceptsEdits, !transformCommitIsPending,
              !document.filterPreviewIsOpen, EngineActivity.shared.label == nil,
              !document.strokeIsActive, !document.hasMultipleSelectedLayers, !document.targetCommandIsPending,
              !document.isMaskTargetActive, !document.isChannelTargetActive,
              !document.floatingState.isActive,
              let layer = transformPreview?.layer else { return false }
        let locks = document.layerLocks[layer]?.effective ?? []
        return !locks.contains(.pixels) && !locks.contains(.position) && transformDrag == nil
    }

    /// Modes change handle behavior while retaining the pending mapping.
    @discardableResult
    func setTransformMode(_ mode: LayerTransformSession.Mode) -> Bool {
        guard transformNumericEditsAllowed else { return false }
        var session = transformPreview
        guard session != nil else { return false }
        session?.setMode(mode)
        transformMode = mode
        transformSession = session
        canvas.needsDisplay = true
        transformSessionDidChange()
        return true
    }

    /// Applies one numeric box edit from the options' fields. The pending
    /// session continues when it still describes the captured target;
    /// otherwise a new one starts from the selected layer — but only when
    /// that layer is `expectedLayer` with `expectedOriginal` bounds, so a
    /// field commit delayed past a document, layer or session change
    /// cannot edit a different target. Refuses without changing anything
    /// while a pointer drag owns the preview, while the document refuses
    /// edits, or when the composed geometry is invalid; the field keeps
    /// its draft then.
    @discardableResult
    func setTransformGeometry(origin: CGPoint, width: Double, height: Double, degrees: Double,
                              expectedLayer: Int32, expectedOriginal: CGRect) -> Bool {
        guard transformNumericEditsAllowed else { return false }
        var session = transformSession.flatMap { isCurrent($0) ? $0 : nil } ?? currentLayerSession()
        guard session?.layer == expectedLayer, session?.original == expectedOriginal,
              session?.setGeometry(origin: origin, width: width, height: height,
                                   degrees: degrees) == true else { return false }
        transformSession = session
        canvas.needsDisplay = true
        transformSessionDidChange()
        return true
    }

    /// Applies the pending preview through the document's native transform
    /// — one undo step — exactly as a canvas Return does.
    func applyPendingTransform() {
        guard transformNumericEditsAllowed else { return }
        applyTransform()
    }

    /// Discards the pending preview without touching the image, as Escape
    /// on the canvas does.
    func cancelPendingTransform() {
        guard !transformCommitIsPending else { return }
        cancelTransform(message: "Transform cancelled.")
    }

    /// Re-evaluates the preview after document state changed (selected
    /// layer, bounds, target, pending work) and tells the options to
    /// refresh their unfocused fields and readiness.
    func transformDocumentStateDidChange() {
        canvas.invalidateTransformPixelPreview()
        transformSessionDidChange()
    }

    private func transformSessionDidChange() {
        canvas.refreshTransformPixelPreview()
        onTransformSessionChange?()
    }

    private func applyTransform() {
        guard !transformCommitIsPending, let session = transformSession,
              !session.isIdentity else { return }
        guard isCurrent(session) else {
            cancelTransform(message: "The layer changed, so the transform was not applied.")
            return
        }
        guard transformNumericEditsAllowed else { return }
        transformCommitIsPending = true
        transformDrag = nil
        transformDragCurrent = nil
        let generation = transformGeneration
        onStatus?("Applying the transform…")
        transformSessionDidChange()
        document.transformLayer(session.layer, matrix: session.projectiveMatrix,
                                expectedBounds: session.original,
                                interpolation: ToolState.shared.transformInterpolation) { [weak self] result in
            guard let self else { return }
            self.transformCommitIsPending = false
            // Tool changes and close may have discarded the preview while
            // accepted work drained. They must never receive an old session.
            if self.transformGeneration == generation {
                if case .success = result {
                    self.cancelTransform(message: "Transformed.")
                } else {
                    // Keep a valid preview for retry; native stale-bound
                    // refusals will expose a fresh box after reconciliation.
                    if !self.isCurrent(session) { self.cancelTransform(message: nil) }
                    if case .failure(let error) = result {
                        self.onStatus?(error.localizedDescription)
                    }
                }
            }
            self.canvas.needsDisplay = true
            self.transformSessionDidChange()
            self.finishSpringInteractionIfReady()
        }
    }

    private func cancelTransform(message: String?) {
        transformGeneration &+= 1
        transformSession = nil
        transformDrag = nil
        canvas.needsDisplay = true
        transformSessionDidChange()
        if let message { onStatus?(message) }
    }

    /// The box the layer will fill, with a rule-of-thirds grid, handles at
    /// the corners and edges, and its center.
    private func drawTransform(scale: Double) {
        // Before the first press, the selected layer's own box shows where
        // the handles are.
        guard ToolState.shared.current == .transform, let session = transformPreview
        else { return }
        let toView = { (point: CGPoint) in NSPoint(x: point.x * scale, y: point.y * scale) }
        let corners = session.imageCorners.map(toView)

        let outline = NSBezierPath()
        outline.move(to: corners[0])
        corners.dropFirst().forEach { outline.line(to: $0) }
        outline.close()
        EngineCanvasView.strokeMarchingAnts(outline, phase: 0)

        let grid = NSBezierPath()
        for segment in session.gridSegments {
            grid.move(to: toView(segment.start))
            grid.line(to: toView(segment.end))
        }
        NSColor(calibratedWhite: 1, alpha: 0.6).setStroke()
        grid.lineWidth = 1
        grid.stroke()

        var handles: [CGPoint] = []
        if session.mode != .skew { handles += session.corners }
        if session.mode != .perspective { handles += session.edgeMiddles }
        // After a warp, Scale/Rotate acts on its independent affine frame.
        if session.mode == .scaleRotate && session.frameCorners != session.imageCorners {
            let frame = NSBezierPath()
            let points = session.frameCorners.map(toView)
            frame.move(to: points[0])
            points.dropFirst().forEach { frame.line(to: $0) }
            frame.close()
            NSColor(calibratedWhite: 1, alpha: 0.5).setStroke()
            frame.lineWidth = 1
            frame.stroke()
        }
        for point in handles.map(toView) {
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
