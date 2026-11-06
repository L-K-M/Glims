import AppKit

/// What the current tool does with pointer and key events on a document's
/// canvas, and what it draws over the image while it works (the selection
/// rubber band or lasso path). The canvas owns one and forwards its events.
@MainActor
final class CanvasToolController {
    private unowned let canvas: EngineCanvasView
    private var document: ImageDocument { canvas.document }

    /// The tool for the current drag; Space switches to the hand meanwhile.
    private var dragTool: ToolID?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var dragOperation = EngineSession.SelectOperation.replace
    private var lassoPoints: [CGPoint] = []
    private var handOrigin: (window: NSPoint, scroll: NSPoint)?
    private var spaceHeld = false
    /// The crop rectangle waiting for Return (image pixels).
    private(set) var pendingCrop: CGRect?
    /// The Transform tool's pending transform, waiting for Return.
    private(set) var transformSession: LayerTransformSession?
    private var transformDrag: LayerTransformSession.Drag?
    /// How near a handle a press grabs it, in view points.
    private static let handleReach: Double = 6
    /// The Text tool's editor while text is being typed.
    private(set) var textEditor: TextEditorOverlay?

    /// Shows a short message in the document's status strip.
    var onStatus: ((String) -> Void)?
    /// Asks the window to zoom one step in or out, keeping `point` (image
    /// pixels) in view.
    var onZoom: ((_ zoomIn: Bool, _ point: CGPoint) -> Void)?

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
            self.canvas.needsDisplay = true
        }
    }

    private var tool: ToolID { spaceHeld ? .hand : ToolState.shared.current }

    // MARK: Pointer

    func mouseDown(with event: NSEvent) {
        let point = canvas.imagePoint(for: event)
        let tool = self.tool
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
            if event.modifierFlags.contains(.option), paintTool == .clone || paintTool == .heal {
                setCloneSource(at: point)
                dragTool = nil
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
        case .move, .gradient, .crop:
            dragStart = point
            dragCurrent = point
            if tool == .crop { pendingCrop = nil }
        case .bucketFill:
            let state = ToolState.shared
            document.fill(at: point, mode: state.fillMode, color: state.foreground,
                          threshold: state.fillThreshold, sampleMerged: state.fillSampleMerged)
        default:
            break
        }
    }

    func mouseDragged(with event: NSEvent) {
        guard let tool = dragTool else { return }
        let point = canvas.imagePoint(for: event)

        if tool.paintTool != nil {
            document.continueStroke([canvas.strokePoint(for: event)])
            return
        }
        switch tool {
        case .rectangleSelect, .ellipseSelect, .move, .gradient, .crop:
            dragCurrent = point
            canvas.needsDisplay = true
        case .lasso:
            if let last = lassoPoints.last, hypot(point.x - last.x, point.y - last.y) >= 1 {
                lassoPoints.append(point)
                canvas.needsDisplay = true
            }
        case .transform:
            guard let drag = transformDrag else { return }
            transformSession?.update(drag, to: point, constrained: event.modifierFlags.contains(.shift))
            canvas.needsDisplay = true
        case .eyedropper:
            pickColor(at: point)
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
            lassoPoints = []
            handOrigin = nil
            canvas.needsDisplay = true
        }
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
        case .transform:
            transformDrag = nil
            if transformSession?.isIdentity == false {
                onStatus?("Return applies the transform; Escape cancels it.")
            }
        case .move:
            guard let start = dragStart else { return }
            document.moveActiveLayer(by: CGSize(width: (end.x - start.x).rounded(), height: (end.y - start.y).rounded()))
        case .gradient:
            guard let start = dragStart, hypot(end.x - start.x, end.y - start.y) >= 1 else { return }
            let state = ToolState.shared
            document.gradient(from: start, to: end, shape: state.gradientShape,
                              fromColor: state.foreground, toColor: state.background)
        case .crop:
            guard let start = dragStart else { return }
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y)).integral
            pendingCrop = rect.width >= 1 && rect.height >= 1 ? rect : nil
            onStatus?(pendingCrop == nil ? "Drag the area to keep."
                                         : "Return crops to \(Int(rect.width)) × \(Int(rect.height)) px; Escape cancels.")
        case .rectangleSelect, .ellipseSelect:
            guard let start = dragStart else { return }
            let end = canvas.imagePoint(for: event)
            let rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y),
                              width: abs(end.x - start.x), height: abs(end.y - start.y))
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
        guard let layer = document.activeLayer else { return }
        ToolState.shared.cloneSource = EngineSession.Brush.Source(drawable: layer, x: point.x, y: point.y)
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
    /// Arrow key codes and the direction each nudges (the canvas is flipped).
    private static let arrowDirections: [Int: CGSize] = [
        123: CGSize(width: -1, height: 0), 124: CGSize(width: 1, height: 0),
        125: CGSize(width: 0, height: 1), 126: CGSize(width: 0, height: -1),
    ]

    /// Tool shortcuts and Space for the hand. Returns false for keys it
    /// does not handle.
    func keyDown(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty, let key = event.charactersIgnoringModifiers else { return false }

        let keyCode = Int(event.keyCode)
        if transformSession != nil, Self.returnKeys.contains(keyCode) {
            applyTransform()
            return true
        }
        if transformSession != nil, keyCode == Self.escapeKey {
            cancelTransform(message: "Transform cancelled.")
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
        if ToolState.shared.current == .move, let direction = Self.arrowDirections[keyCode] {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            document.moveActiveLayer(by: CGSize(width: direction.width * step, height: direction.height * step))
            return true
        }

        switch key.lowercased() {
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
            if !event.isARepeat {
                spaceHeld = true
                NSCursor.openHand.set()
            }
            return true
        }
        if ToolID.group(forShortcut: key) != nil {
            ToolState.shared.select(shortcut: key, cycle: event.modifierFlags.contains(.shift))
            return true
        }
        if (key == "[" || key == "]"), ToolState.shared.current.paintTool != nil {
            let tool = ToolState.shared.current
            ToolState.shared.update(tool) { brush in
                brush.size = max(1, min(500, key == "]" ? brush.size * 1.25 : brush.size / 1.25)).rounded()
            }
            onStatus?("\(tool.name) size \(Int(ToolState.shared.brush(for: tool).size)) px")
            return true
        }
        return false
    }

    func keyUp(with event: NSEvent) -> Bool {
        guard event.charactersIgnoringModifiers == " " else { return false }
        spaceHeld = false
        NSCursor.arrow.set()
        return true
    }

    // MARK: Overlay

    /// The rubber band or lasso path of a selection being drawn, in view
    /// coordinates (the canvas is flipped).
    func drawOverlay(scale: Double) {
        let path: NSBezierPath
        switch dragTool {
        case .rectangleSelect?, .ellipseSelect?:
            guard let start = dragStart, let end = dragCurrent else { return }
            let rect = NSRect(x: min(start.x, end.x) * scale, y: min(start.y, end.y) * scale,
                              width: abs(end.x - start.x) * scale, height: abs(end.y - start.y) * scale)
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
            // The selected layer's outline, following the pointer.
            guard let start = dragStart, let end = dragCurrent,
                  let layer = document.layers.first(where: { $0.id == document.activeLayer }) else { return }
            let bounds = layer.bounds.offsetBy(dx: end.x - start.x, dy: end.y - start.y)
            path = NSBezierPath(rect: NSRect(x: bounds.minX * scale, y: bounds.minY * scale,
                                             width: bounds.width * scale, height: bounds.height * scale))
        default:
            drawPendingCrop(scale: scale)
            drawTransform(scale: scale)
            return
        }
        EngineCanvasView.strokeMarchingAnts(path, phase: 0)
    }

    // MARK: Text tool

    /// Opens the editor: on the topmost visible text layer under `point`,
    /// or for new text with its top-left at `point`.
    private func beginTextEditing(at point: CGPoint) {
        let hit = document.layers.first { $0.kind == .text && $0.isVisible && $0.bounds.contains(point) }
        let editor: TextEditorOverlay
        if let hit, let current = document.textLayer(hit.id) {
            document.selectLayer(hit.id)
            editor = TextEditorOverlay(layer: hit.id, text: current.text, origin: hit.bounds.origin,
                                       settings: current.settings, scale: canvas.scale)
        } else {
            var settings = ToolState.shared.textSettings
            settings.color = ToolState.shared.foreground
            editor = TextEditorOverlay(layer: nil, text: "", origin: point, settings: settings, scale: canvas.scale)
        }
        editor.onFinish = { [weak self] in self?.finishTextEditing() }
        canvas.addSubview(editor)
        canvas.window?.makeFirstResponder(editor)
        textEditor = editor
        onStatus?("Type the text. Escape or a click outside applies it.")
    }

    /// Applies what was typed: new text becomes a text layer, a changed
    /// layer gets its new text, and nothing changes otherwise.
    func finishTextEditing() {
        guard let editor = textEditor else { return }
        textEditor = nil
        let text = editor.string
        editor.removeFromSuperview()
        canvas.window?.makeFirstResponder(canvas)

        if let layer = editor.textLayer {
            guard editor.hasChanges else { return }
            if text.isEmpty {
                onStatus?("Empty text was not applied; delete the layer to remove it.")
                return
            }
            document.updateText(layer, text: text, settings: nil)
        } else if !text.isEmpty {
            var settings = ToolState.shared.textSettings
            settings.color = ToolState.shared.foreground
            document.addText(text, settings: settings, at: editor.origin)
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
        canvas.needsDisplay = true
    }

    private func currentLayerSession() -> LayerTransformSession? {
        guard let layer = document.layers.first(where: { $0.id == document.activeLayer }),
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
              let session = transformSession ?? currentLayerSession() else { return }
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
