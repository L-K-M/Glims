import AppKit

/// The Path tool: draws and edits the active path's Bézier subpaths on the
/// canvas. Each press, drag and release is one edit, which the document
/// sends to the engine as one undo step, as GIMP's path tool does.
///
/// - Click adds a corner anchor; drag pulls out a smooth anchor's handles.
/// - New anchors extend the subpath being drawn; Shift-click starts a new
///   one. Clicking its first anchor closes it; Return or Escape ends it.
/// - Drag an anchor or a handle of a selected anchor to move it
///   (Shift: the opposite handle mirrors it); Option-drag an anchor pulls
///   out new handles.
/// - Clicking the end anchor of an open subpath continues that subpath.
/// - Shift-click an existing anchor toggles it in the selected set, without
///   closing, editing or undoing anything. A normal click on a selected
///   anchor keeps the whole set, so a drag moves all selected anchors and
///   their handles together in one edit on release; a click on any other
///   anchor selects only that one.
/// - Delete removes all selected anchors in one edit.
@MainActor
final class PathTool {
    private unowned let canvas: EngineCanvasView
    private var document: ImageDocument { canvas.document }

    /// The shape while the pointer is down, before the edit is sent.
    private var working: VectorPath?
    private var drag: Drag?
    /// The subpath new anchors extend.
    private(set) var extending: Int? {
        didSet { if extending == nil { extendsFromStart = false } }
    }
    /// New anchors go before the subpath's first anchor rather than after its
    /// last. The subpath is reversed when the next anchor is added, so a
    /// click on its start alone changes nothing.
    private var extendsFromStart = false
    /// The anchors whose handles show and Delete removes. Shift-click
    /// toggles membership; a normal click on one of them keeps the set for
    /// a group drag, a click on any other anchor selects only that one.
    private(set) var selectedAnchors: Set<VectorPath.AnchorIndex> = []
    /// The path the state above belongs to.
    private var statePath: Int32?
    /// The active path and its shape when the press began. An undo or
    /// another path's selection during the drag changes them, and then the
    /// drag is dropped rather than written over the change.
    private var dragBase: (path: Int32?, shape: VectorPath)?

    var onStatus: ((String) -> Void)?

    /// How near a press must be to grab an anchor or handle, in view points.
    static let reach: Double = 6
    /// A drag shorter than this (view points) leaves a new anchor a corner.
    static let pullThreshold: Double = 2

    private enum Drag {
        case newAnchor(VectorPath.AnchorIndex)
        /// Moves every anchor in `indices` with its handles by the delta
        /// from `start`. `originals` holds the anchors as the press found
        /// them, so the shape is rebuilt from them on every motion event
        /// and repeated motion cannot drift.
        case moveAnchors(indices: Set<VectorPath.AnchorIndex>, start: CGPoint,
                         originals: [VectorPath.AnchorIndex: VectorPath.Anchor])
        case pullHandles(VectorPath.AnchorIndex)
        case handleIn(VectorPath.AnchorIndex)
        case handleOut(VectorPath.AnchorIndex)
        /// The press closed a subpath; the release sends it.
        case closed
    }

    init(canvas: EngineCanvasView) {
        self.canvas = canvas
    }

    /// The active path's shape, as being edited.
    var shape: VectorPath {
        working ?? document.activePath.flatMap { document.pathShapes[$0] } ?? VectorPath()
    }

    /// Forgets the subpath being drawn and clears the selected set when
    /// another path became active; prunes the selected anchors an undo or
    /// an edit took away.
    private func syncWithDocument() {
        if statePath != document.activePath {
            statePath = document.activePath
            extending = nil
            selectedAnchors = []
        }
        let current = shape
        if let index = extending,
           !current.subpaths.indices.contains(index) || current.subpaths[index].isClosed {
            extending = nil
        }
        selectedAnchors = current.pruned(selectedAnchors)
    }

    // MARK: Pointer

    func mouseDown(at point: CGPoint, flags: NSEvent.ModifierFlags) {
        syncWithDocument()
        // Several selected paths are ambiguous: the click is consumed —
        // no anchor edit, and never an implicit new path or a fall
        // through to the paint tool — until one row is picked.
        if document.hasMultipleSelectedPaths {
            onStatus?(ItemSelectionPolicy.refusal(count: document.selectedPathIDs.count,
                                                  kind: .path, action: "Editing the path") ?? "")
            return
        }
        var path = shape
        dragBase = (document.activePath, path)
        let tolerance = Self.reach / canvas.scale

        switch path.part(at: point, tolerance: tolerance, handlesOf: selectedAnchors) {
        case .anchor(let index)?:
            // Shift-click toggles the anchor in the selected set: it ends
            // the subpath being drawn, but never closes, edits or undoes.
            if flags.contains(.shift) {
                if selectedAnchors.contains(index) {
                    selectedAnchors.remove(index)
                } else {
                    selectedAnchors.insert(index)
                }
                extending = nil
                drag = nil
                break
            }
            let subpath = path.subpaths[index.subpath]
            let last = subpath.anchors.count - 1
            // The anchor the subpath being drawn started from closes it.
            let origin = extendsFromStart ? last : 0
            if extending == index.subpath, !subpath.isClosed, last > 0, index.anchor == origin,
               !flags.contains(.option) {
                path.subpaths[index.subpath].isClosed = true
                extending = nil
                selectedAnchors = [index]
                drag = .closed
                break
            }
            // A click inside a multi-selection keeps the whole set, so the
            // drag moves it as a group; any other click picks one anchor.
            let groupDrag = selectedAnchors.contains(index) && selectedAnchors.count > 1
            if groupDrag {
                // The set stays as it is.
            } else if !subpath.isClosed, index.anchor == last {
                // Picking an end of an open subpath continues it from that end.
                extending = index.subpath
                extendsFromStart = false
            } else if !subpath.isClosed, index.anchor == 0 {
                extending = index.subpath
                extendsFromStart = true
            } else {
                extending = nil
            }
            if flags.contains(.option) || !selectedAnchors.contains(index) {
                selectedAnchors = [index]
            }
            drag = flags.contains(.option) ? .pullHandles(index)
                : .moveAnchors(indices: selectedAnchors, start: point,
                               originals: Dictionary(uniqueKeysWithValues: selectedAnchors
                                   .filter { path.contains($0) }
                                   .map { ($0, path[$0]) }))
        case .handleIn(let index)?:
            drag = .handleIn(index)
        case .handleOut(let index)?:
            drag = .handleOut(index)
        case nil:
            let anchor = VectorPath.Anchor(point)
            let index: VectorPath.AnchorIndex
            if let extending, !flags.contains(.shift) {
                if extendsFromStart {
                    path.reverseSubpath(extending)
                    extendsFromStart = false
                }
                path.subpaths[extending].anchors.append(anchor)
                index = VectorPath.AnchorIndex(subpath: extending, anchor: path.subpaths[extending].anchors.count - 1)
            } else {
                path.subpaths.append(VectorPath.Subpath(anchors: [anchor]))
                index = VectorPath.AnchorIndex(subpath: path.subpaths.count - 1, anchor: 0)
                extending = index.subpath
            }
            selectedAnchors = [index]
            drag = .newAnchor(index)
        }
        working = path
        canvas.needsDisplay = true
    }

    func mouseDragged(to point: CGPoint, flags: NSEvent.ModifierFlags) {
        guard var path = working, let drag else { return }

        switch drag {
        case .newAnchor(let index), .pullHandles(let index):
            let anchor = path[index].point
            if hypot(point.x - anchor.x, point.y - anchor.y) * canvas.scale >= Self.pullThreshold {
                path[index].pullHandles(to: point)
            } else {
                path[index] = VectorPath.Anchor(anchor)
            }
        case .moveAnchors(let indices, let start, let originals):
            // Rebuilt from the press baseline on every event, so repeated
            // motion applies the total delta once, never cumulatively.
            for (index, original) in originals where path.contains(index) {
                path[index] = original
            }
            path.moveAnchors(indices, by: CGSize(width: point.x - start.x, height: point.y - start.y))
        case .handleIn(let index):
            path[index].handleIn = point
            if flags.contains(.shift) { path[index].handleOut = Self.mirror(point, around: path[index].point) }
        case .handleOut(let index):
            path[index].handleOut = point
            if flags.contains(.shift) { path[index].handleIn = Self.mirror(point, around: path[index].point) }
        case .closed:
            return
        }
        working = path
        canvas.needsDisplay = true
    }

    func mouseUp() {
        defer {
            working = nil
            drag = nil
            dragBase = nil
            canvas.needsDisplay = true
        }
        guard let path = working, drag != nil, let base = dragBase else { return }
        let current = document.activePath.flatMap { document.pathShapes[$0] } ?? VectorPath()
        guard document.activePath == base.path, current.isUnchanged(from: base.shape) else {
            onStatus?("The path changed during the drag, so the drag was not applied.")
            return
        }
        commit(path)
    }

    private static func mirror(_ point: CGPoint, around center: CGPoint) -> CGPoint {
        CGPoint(x: 2 * center.x - point.x, y: 2 * center.y - point.y)
    }

    /// Sends the edit; the first anchor of a document without an active
    /// path makes a new path.
    private func commit(_ path: VectorPath) {
        if let id = document.activePath {
            // Compared bit for bit, so an unchanged shape holding a NaN (a
            // damaged file) is not sent back, where the engine refuses it.
            if let current = document.pathShapes[id], path.isUnchanged(from: current) { return }
            document.updatePath(id, to: path)
        } else {
            guard !path.isEmpty, let id = document.addPath(path) else { return }
            statePath = id
            onStatus?("Added a path; the Paths palette lists it.")
        }
    }

    // MARK: Keys

    private static let returnKeys: Set<Int> = [36, 76]
    private static let escapeKey = 53
    private static let deleteKeys: Set<Int> = [51, 117]   // Delete, Forward Delete

    func keyDown(keyCode: Int) -> Bool {
        // While the pointer holds an anchor or handle, keys wait: an edit now
        // would be undone by the drag's own edit on release.
        if drag != nil, Self.deleteKeys.contains(keyCode) || Self.returnKeys.contains(keyCode)
            || keyCode == Self.escapeKey {
            return true
        }
        syncWithDocument()
        // With several paths selected, Delete/Return/Escape/arrows are consumed
        // without editing anything — no anchor removal, no new subpath.
        if document.hasMultipleSelectedPaths,
           Self.deleteKeys.contains(keyCode) || Self.returnKeys.contains(keyCode) || keyCode == Self.escapeKey
            || CanvasKeyboardPolicy.Arrow(keyCode: keyCode) != nil {
            return true
        }
        if Self.returnKeys.contains(keyCode) || keyCode == Self.escapeKey {
            guard extending != nil || !selectedAnchors.isEmpty else { return false }
            extending = nil
            selectedAnchors = []
            canvas.needsDisplay = true
            onStatus?("Click to start another subpath.")
            return true
        }
        if Self.deleteKeys.contains(keyCode), !selectedAnchors.isEmpty {
            var path = shape
            // Subpaths the batch empties drop away, shifting the indices of
            // the ones after them.
            let dropped = Set(selectedAnchors.map(\.subpath)).filter { subpath in
                path.subpaths.indices.contains(subpath)
                    && path.subpaths[subpath].anchors.count == selectedAnchors.filter { $0.subpath == subpath }.count
            }
            if let current = extending {
                let shifted = current - dropped.filter { $0 < current }.count
                extending = dropped.contains(current) || !path.subpaths.indices.contains(shifted)
                    ? nil : shifted
            }
            path.removeAnchors(selectedAnchors)
            selectedAnchors = []
            commit(path)
            canvas.needsDisplay = true
            return true
        }
        return false
    }

    // MARK: Drawing

    /// The color paths draw in on the canvas.
    static let pathColor = NSColor(calibratedRed: 0.1, green: 0.35, blue: 0.95, alpha: 1)

    /// The active path with its anchors, and the selected anchors' handles.
    /// Selected anchors fill with the path color, the others stay white.
    func draw(scale: Double) {
        syncWithDocument()
        let path = shape
        guard !path.isEmpty else { return }
        let outline = NSBezierPath(cgPath: path.cgPath(scale: scale))
        outline.lineWidth = 1.5
        Self.pathColor.setStroke()
        outline.stroke()

        let toView = { (point: CGPoint) in NSPoint(x: point.x * scale, y: point.y * scale) }
        for index in selectedAnchors where path.contains(index) {
            let anchor = path[index]
            for handle in [anchor.handleIn, anchor.handleOut] where handle != anchor.point {
                let line = NSBezierPath()
                line.move(to: toView(anchor.point))
                line.line(to: toView(handle))
                line.lineWidth = 1
                line.stroke()
                let dot = NSBezierPath(ovalIn: NSRect(x: toView(handle).x - 3, y: toView(handle).y - 3, width: 6, height: 6))
                NSColor.white.setFill()
                dot.fill()
                dot.stroke()
            }
        }
        for (s, subpath) in path.subpaths.enumerated() {
            for (a, anchor) in subpath.anchors.enumerated() {
                let center = toView(anchor.point)
                let square = NSRect(x: center.x - 3.5, y: center.y - 3.5, width: 7, height: 7)
                let isSelected = selectedAnchors.contains(VectorPath.AnchorIndex(subpath: s, anchor: a))
                (isSelected ? Self.pathColor : NSColor.white).setFill()
                square.fill()
                Self.pathColor.setStroke()
                NSBezierPath(rect: square.insetBy(dx: 0.5, dy: 0.5)).stroke()
            }
        }
    }
}

extension NSBezierPath {
    /// NSBezierPath(cgPath:) arrived in macOS 14; Glims supports 13.
    convenience init(cgPath: CGPath) {
        self.init()
        cgPath.applyWithBlock { element in
            let points = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: move(to: points[0])
            case .addLineToPoint: line(to: points[0])
            case .addQuadCurveToPoint:
                let start = currentPoint
                let control = points[0], end = points[1]
                curve(to: end,
                      controlPoint1: CGPoint(x: start.x + 2 / 3 * (control.x - start.x),
                                             y: start.y + 2 / 3 * (control.y - start.y)),
                      controlPoint2: CGPoint(x: end.x + 2 / 3 * (control.x - end.x),
                                             y: end.y + 2 / 3 * (control.y - end.y)))
            case .addCurveToPoint: curve(to: points[2], controlPoint1: points[0], controlPoint2: points[1])
            case .closeSubpath: close()
            @unknown default: break
            }
        }
    }
}
