import AppKit

/// A local curve draft. Only completed user edits are sent to the owning panel.
@MainActor
final class CurvesGraphView: NSView {
    var state = EngineSession.CurveState() {
        didSet {
            if !updatingLocally { clearGesture() }
            clampSelection()
            updateAccessibility()
            needsDisplay = true
        }
    }
    var selectedPoint: Int? {
        get { selection }
        set {
            selection = newValue
            clampSelection()
            updateAccessibility()
            needsDisplay = true
        }
    }
    var isInteracting: Bool { baseline != nil }
    var defaultPointKind: EngineSession.CurvePointKind = .smooth
    var onBeginEdit: (() -> Bool)?
    var onStateEdit: ((EngineSession.CurveKind, [EngineSession.CurvePoint], [Double]) -> Void)?
    var onSelectionChanged: ((Int?) -> Void)?
    var onEndInteraction: ((Int?) -> Void)?

    private var selection: Int?
    private var updatingLocally = false
    private var baseline: EngineSession.CurveState?
    private var baselineSelection: Int?
    private var dragPoint: Int?
    private var lastSample: (index: Int, value: Double)?
    private var dragged = false
    private var plot: NSRect { bounds.insetBy(dx: 12, dy: 12) }

    override var acceptsFirstResponder: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureAccessibility()
    }
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureAccessibility()
    }
    private func configureAccessibility() {
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Curves graph")
        setAccessibilityHelp("Click to select or add a point. Drag to edit. Arrow keys move the selected point; Shift moves farther. Delete removes it. Escape cancels a drag.")
        updateAccessibility()
    }
    private func updateAccessibility() {
        let selected = selection.map { "; selected point \($0 + 1)" } ?? ""
        setAccessibilityValue("\(state.kind == .smooth ? "Smooth" : "Freehand") curve, \(state.points.count) points, 256 samples\(selected)")
    }
    private func clampSelection() {
        if let index = selection, !state.points.indices.contains(index) { selection = nil }
    }
    private func selectByUser(_ index: Int?) {
        let old = selection
        selectedPoint = index
        if old != selection { onSelectionChanged?(selection) }
    }
    private func clearGesture() {
        baseline = nil
        baselineSelection = nil
        dragPoint = nil
        lastSample = nil
        dragged = false
    }
    private func replaceLocally(_ value: EngineSession.CurveState) {
        updatingLocally = true
        state = value
        updatingLocally = false
    }
    private func cancelGesture() {
        guard let original = baseline else { return }
        let originalSelection = baselineSelection
        clearGesture()
        replaceLocally(original)
        selectByUser(originalSelection)
        onEndInteraction?(selection)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { cancelGesture() }
    }
    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }
    override func resignFirstResponder() -> Bool {
        cancelGesture()
        needsDisplay = true
        return super.resignFirstResponder()
    }

    private func normalized(_ event: NSEvent, requireInside: Bool = false) -> NSPoint? {
        let rect = plot
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        guard p.x.isFinite, p.y.isFinite, !requireInside || rect.contains(p) else { return nil }
        return NSPoint(x: min(1, max(0, (p.x - rect.minX) / rect.width)),
                       y: min(1, max(0, (p.y - rect.minY) / rect.height)))
    }
    private func position(_ x: Double, _ y: Double) -> NSPoint {
        NSPoint(x: plot.minX + x * plot.width, y: plot.minY + y * plot.height)
    }
    private func nearestPoint(_ p: NSPoint) -> Int? {
        var result: Int?
        var best = 8.0 * 8.0
        for (index, point) in state.points.enumerated() {
            let dx = (point.x - p.x) * plot.width
            let dy = (point.y - p.y) * plot.height
            let distance = dx * dx + dy * dy
            if distance <= best { best = distance; result = index }
        }
        return result
    }
    override func mouseDown(with event: NSEvent) {
        guard normalized(event, requireInside: true) != nil,
              onBeginEdit?() ?? true,
              state.isValid,
              let p = normalized(event, requireInside: true) else { return }
        window?.makeFirstResponder(self)
        baseline = state
        baselineSelection = selection
        if state.kind == .free {
            selectByUser(nil)
            paintSample(at: p)
        } else if event.clickCount < 2, let index = nearestPoint(p) {
            selectByUser(index)
            dragPoint = index
        } else if state.points.count < 65_536 {
            var next = state
            // Insert after equal inputs, retaining the native stable ordering.
            let index = next.points.firstIndex { $0.x > p.x } ?? next.points.count
            next.points.insert(.init(x: p.x, y: p.y, kind: defaultPointKind), at: index)
            next.identity = false
            replaceLocally(next)
            // The parent still owns the pre-insertion state until MouseUp.
            selectedPoint = index
            dragPoint = index
        }
    }
    override func mouseDragged(with event: NSEvent) {
        guard baseline != nil, let p = normalized(event) else { return }
        dragged = true
        if state.kind == .free { paintSample(at: p) } else { movePoint(to: p) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let original = baseline else { return }
        if let p = normalized(event), state.kind == .free || dragged {
            if state.kind == .free { paintSample(at: p) } else { movePoint(to: p) }
        }
        let edited = state
        let editedSelection = selection
        clearGesture()
        if edited != original {
            onStateEdit?(edited.kind, edited.points, edited.samples)
            // Publish the new state before its newly added point index.
            if edited.kind == .smooth { selectedPoint = editedSelection; onSelectionChanged?(selection) }
        }
        // A native reply may have arrived while the local gesture owned the
        // graph, including a click that did not edit or a cancelled gesture.
        onEndInteraction?(selection)
    }
    private func movePoint(to p: NSPoint) {
        guard let index = dragPoint, state.points.indices.contains(index) else { return }
        var next = state
        let low = index > 0 ? next.points[index - 1].x : 0
        let high = index + 1 < next.points.count ? next.points[index + 1].x : 1
        next.points[index].x = min(high, max(low, p.x))
        next.points[index].y = p.y
        if next.points != state.points { next.identity = false; replaceLocally(next) }
    }
    private func paintSample(at p: NSPoint) {
        guard state.samples.count == 256 else { return }
        let index = min(255, max(0, Int((p.x * 255).rounded())))
        var next = state
        if let previous = lastSample, previous.index != index {
            for i in min(previous.index, index)...max(previous.index, index) {
                let fraction = Double(i - previous.index) / Double(index - previous.index)
                next.samples[i] = min(1, max(0, previous.value + (p.y - previous.value) * fraction))
            }
        } else { next.samples[index] = p.y }
        lastSample = (index, Double(p.y))
        if next.samples != state.samples { next.identity = false; replaceLocally(next) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, baseline != nil { cancelGesture(); return }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.intersection([.command, .control, .option]).isEmpty,
              [UInt16(51), 117, 123, 124, 125, 126].contains(event.keyCode),
              state.kind == .smooth, selection != nil else { super.keyDown(with: event); return }
        guard onBeginEdit?() ?? true else { return }
        // Keyboard edits own the same begin/end lifetime as a pointer gesture,
        // including a no-op at a bound. Panels use End to release draft gates.
        defer { onEndInteraction?(selection) }
        cancelGesture()
        guard state.isValid, let index = selection, state.points.indices.contains(index) else { return }
        var next = state
        if event.keyCode == 51 || event.keyCode == 117 {
            next.points.remove(at: index)
            next.identity = false
            replaceLocally(next)
            selectedPoint = next.points.isEmpty ? nil : min(index, next.points.count - 1)
        } else {
            let step = (modifiers.contains(.shift) ? 10.0 : 1.0) / 255.0
            let low = index > 0 ? next.points[index - 1].x : 0
            let high = index + 1 < next.points.count ? next.points[index + 1].x : 1
            switch event.keyCode {
            case 123: next.points[index].x = max(low, next.points[index].x - step)
            case 124: next.points[index].x = min(high, next.points[index].x + step)
            case 125: next.points[index].y = max(0, next.points[index].y - step)
            default: next.points[index].y = min(1, next.points[index].y + step)
            }
            guard next.points != state.points else { return }
            next.identity = false
            replaceLocally(next)
        }
        let editedSelection = selection
        onStateEdit?(next.kind, next.points, next.samples)
        selectedPoint = editedSelection
        onSelectionChanged?(selection)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        let rect = plot
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: rect).addClip()
        let grid = NSBezierPath()
        for i in 0...4 {
            let fraction = Double(i) / 4
            grid.move(to: position(fraction, 0)); grid.line(to: position(fraction, 1))
            grid.move(to: position(0, fraction)); grid.line(to: position(1, fraction))
        }
        NSColor.separatorColor.setStroke(); grid.lineWidth = 0.5; grid.stroke()
        let diagonal = NSBezierPath()
        diagonal.move(to: position(0, 0)); diagonal.line(to: position(1, 1))
        NSColor.tertiaryLabelColor.setStroke(); diagonal.stroke()
        if state.samples.count == 256, state.samples.allSatisfy({ $0.isFinite }) {
            let line = NSBezierPath()
            for (index, sample) in state.samples.enumerated() {
                let p = position(Double(index) / 255, sample)
                if index == 0 { line.move(to: p) } else { line.line(to: p) }
            }
            NSColor.labelColor.setStroke(); line.lineWidth = 1.5; line.stroke()
        }
        if state.kind == .smooth {
            for index in state.points.indices.prefix(4096) { drawPoint(index) }
            if let index = selection, index >= 4096 { drawPoint(index) }
        }
        NSGraphicsContext.restoreGraphicsState()
        (window?.firstResponder === self ? NSColor.keyboardFocusIndicatorColor : NSColor.separatorColor).setStroke()
        let border = NSBezierPath(rect: rect)
        border.lineWidth = window?.firstResponder === self ? 2 : 1
        border.stroke()
    }
    private func drawPoint(_ index: Int) {
        guard state.points.indices.contains(index), state.points[index].isValid else { return }
        let point = state.points[index]
        let p = position(point.x, point.y)
        let shape: NSBezierPath
        if point.kind == .corner {
            shape = NSBezierPath()
            shape.move(to: NSPoint(x: p.x, y: p.y + 4))
            shape.line(to: NSPoint(x: p.x + 4, y: p.y))
            shape.line(to: NSPoint(x: p.x, y: p.y - 4))
            shape.line(to: NSPoint(x: p.x - 4, y: p.y)); shape.close()
        } else { shape = NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)) }
        (selection == index ? NSColor.controlAccentColor : NSColor.controlBackgroundColor).setFill()
        shape.fill(); NSColor.labelColor.setStroke(); shape.stroke()
    }
}
