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

    /// Shows a short message in the document's status strip.
    var onStatus: ((String) -> Void)?
    /// Asks the window to zoom one step in or out, keeping `point` (image
    /// pixels) in view.
    var onZoom: ((_ zoomIn: Bool, _ point: CGPoint) -> Void)?

    init(canvas: EngineCanvasView) {
        self.canvas = canvas
    }

    private var tool: ToolID { spaceHeld ? .hand : ToolState.shared.current }

    // MARK: Pointer

    func mouseDown(with event: NSEvent) {
        let point = canvas.imagePoint(for: event)
        let tool = self.tool
        dragTool = tool

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
        case .rectangleSelect, .ellipseSelect:
            dragCurrent = point
            canvas.needsDisplay = true
        case .lasso:
            if let last = lassoPoints.last, hypot(point.x - last.x, point.y - last.y) >= 1 {
                lassoPoints.append(point)
                canvas.needsDisplay = true
            }
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
        switch tool {
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

    /// Tool shortcuts and Space for the hand. Returns false for keys it
    /// does not handle.
    func keyDown(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option])
        guard flags.isEmpty, let key = event.charactersIgnoringModifiers else { return false }

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
        default:
            return
        }
        EngineCanvasView.strokeMarchingAnts(path, phase: 0)
    }
}
