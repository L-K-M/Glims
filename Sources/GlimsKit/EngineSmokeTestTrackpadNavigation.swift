import AppKit

/// Synthetic AppKit events exercise the real responder overrides. No
/// event is posted globally and no hardware gesture is claimed here.
private final class TrackpadSmokeEvent: NSEvent {
    private let kind: NSEvent.EventType
    private let owner: Int
    private let point: CGPoint
    private let eventPhase: NSEvent.Phase
    private let delta: Double
    init(kind: NSEvent.EventType, window: Int, point: CGPoint, phase: NSEvent.Phase = [], delta: Double) {
        self.kind = kind; owner = window; self.point = point
        eventPhase = phase; self.delta = delta
        super.init()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var type: NSEvent.EventType { kind }
    override var windowNumber: Int { owner }
    override var locationInWindow: NSPoint { point }
    override var phase: NSEvent.Phase { eventPhase }
    override var magnification: CGFloat { CGFloat(delta) }
    override var rotation: Float { Float(delta) }
}

@MainActor
extension EngineSmokeTest {
    static func exerciseTrackpadNavigation(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 1800, height: 1400)
        let doc = try ImageDocument(session: session, image: image, name: "Trackpad A")
        documents.items.append(doc)
        let controller = DocumentWindowController(document: doc)
        controller.window?.setContentSize(NSSize(width: 540, height: 420))
        controller.showWindow(nil)
        let otherImage = try session.newImage(width: 100, height: 80)
        let other = try ImageDocument(session: session, image: otherImage, name: "Trackpad B")
        documents.items.append(other)
        let otherController = DocumentWindowController(document: other)
        otherController.showWindow(nil)
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func close(_ document: ImageDocument, _ controller: DocumentWindowController) {
            controller.window?.orderOut(nil)
            guard !document.isClosing else { return }
            var stopped = false
            controller.canvas.stopRendering { stopped = true }
            wait { stopped }
            var closed = false
            document.closeImageWhenDrained { closed = true }
            wait { closed }
            documents.items.removeAll { $0 === document }
        }
        defer { close(other, otherController); close(doc, controller) }
        guard let window = controller.window, let otherWindow = otherController.window else {
            return check(false, "trackpad fixtures have real owning windows")
        }
        let before = try session.info(image), undoBefore = try session.undoInfo(image)
        let pixelsBefore = try session.copyPixels(image, merged: true).pixels
        controller.zoom(to: 180)
        controller.setViewRotation(degrees: 30)
        controller.center(on: CGPoint(x: 900, y: 700))
        window.contentView?.layoutSubtreeIfNeeded()
        let clip = controller.scrollView.contentView
        let anchor = clip.convert(CGPoint(x: clip.bounds.midX + 31, y: clip.bounds.midY - 23), to: nil)
        func imagePoint() -> CGPoint {
            controller.canvas.imagePoint(at: controller.canvas.convert(anchor, from: nil))
        }
        func send(_ kind: NSEvent.EventType, _ delta: Double, phase: NSEvent.Phase = [],
                  owner: Int? = nil, point: CGPoint? = nil) {
            let event = TrackpadSmokeEvent(kind: kind, window: owner ?? window.windowNumber,
                                          point: point ?? anchor, phase: phase, delta: delta)
            if kind == .magnify { controller.canvas.magnify(with: event) }
            else { controller.canvas.rotate(with: event) }
        }
        func samePoint(_ a: CGPoint, _ b: CGPoint) -> Bool {
            abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01
        }
        let pinchPoint = imagePoint()
        send(.magnify, 0.25)
        check(controller.canvas.zoomPercent == 225, "a phase-none pinch rebases from the current menu zoom")
        check(samePoint(pinchPoint, imagePoint()), "pinch preserves the image pixel under the pointer on a rotated canvas")
        let rotationPoint = imagePoint()
        send(.rotate, 5)
        check(abs(controller.rotationView.rotationDegrees - 25) < 0.001,
              "a phase-none CCW rotation starts from the current 30-degree menu angle")
        check(samePoint(rotationPoint, imagePoint()), "rotation preserves the image pixel under the pointer")
        controller.setViewRotation(degrees: 100)
        send(.rotate, 10, phase: .changed)
        check(controller.rotationView.rotationDegrees == 90, "an external angle change rebases the next relative event")
        controller.setViewRotation(degrees: 179)
        send(.rotate, -5, phase: .began)
        send(.rotate, 4, phase: .changed)
        check(controller.rotationView.rotationDegrees == -180, "relative rotation stays continuous across the normalized angle boundary")
        send(.rotate, 30, phase: .cancelled)
        check(controller.rotationView.rotationDegrees == -180, "cancelled rotation applies no new delta")
        send(.rotate, 5, phase: .ended)
        check(controller.rotationView.rotationDegrees == 175, "a rotation end applies its final relative delta")
        controller.zoom(to: 100)
        send(.magnify, 0.004, phase: .began)
        check(controller.canvas.zoomPercent == 100, "a fractional pinch retains a sub-percent delta")
        send(.magnify, 0.004, phase: .changed)
        check(controller.canvas.zoomPercent == 101, "a second fractional pinch publishes the rounded accumulated zoom")
        send(.magnify, 0.004, phase: .changed)
        check(controller.canvas.zoomPercent == 101, "a third fraction does not republish a whole percent")
        send(.magnify, 0.5, phase: .cancelled)
        check(controller.canvas.zoomPercent == 101, "cancelled pinch applies no new delta")
        send(.magnify, 1, phase: .ended)
        check(controller.canvas.zoomPercent == 202, "a pinch end uses the last published zoom after cancellation")
        controller.zoom(to: 200)
        send(.magnify, 0.01)
        check(controller.canvas.zoomPercent == 202, "an external zoom change discards an old fractional remainder")
        let stableZoom = controller.canvas.zoomPercent, stableAngle = controller.rotationView.rotationDegrees
        send(.magnify, .nan); send(.magnify, -1); send(.rotate, .infinity)
        send(.magnify, 1, point: CGPoint(x: CGFloat.nan, y: 0))
        check(controller.canvas.zoomPercent == stableZoom && controller.rotationView.rotationDegrees == stableAngle,
              "nonfinite deltas, invalid pinch factors and nonfinite anchors leave the view unchanged")
        send(.magnify, 1, owner: otherWindow.windowNumber)
        send(.rotate, 45, owner: otherWindow.windowNumber)
        check(controller.canvas.zoomPercent == stableZoom && controller.rotationView.rotationDegrees == stableAngle,
              "an event from another window cannot navigate this canvas")
        otherWindow.makeKeyAndOrderFront(nil)
        let otherZoom = otherController.canvas.zoomPercent, otherAngle = otherController.rotationView.rotationDegrees
        send(.magnify, 0.5)
        check(controller.canvas.zoomPercent == 303 && otherController.canvas.zoomPercent == otherZoom
                && otherController.rotationView.rotationDegrees == otherAngle,
              "captured window A navigates while B is frontmost and leaves B unchanged")
        let gate = DispatchSemaphore(value: 0)
        var idle = false
        let admitted = EngineActivity.shared.perform(label: "Trackpad view-only check", work: { gate.wait() }, completion: { idle = true })
        send(.magnify, 0.1)
        send(.rotate, 5)
        gate.signal()
        wait { idle }
        check(admitted && controller.canvas.zoomPercent == 333 && controller.rotationView.rotationDegrees == 170,
              "view navigation remains available during engine-exclusive work")
        check(try session.info(image) == before && session.undoInfo(image) == undoBefore
                && session.copyPixels(image, merged: true).pixels == pixelsBefore,
              "pinch and rotation preserve native pixels, dirty state, dimensions and Undo history")
        let brush = EngineSession.Brush(size: 3, opacity: 1, red: 0, green: 0, blue: 0, pressureSize: false)
        doc.beginStroke(at: .init(x: 20, y: 20, pressure: 1), brush: brush)
        let strokeZoom = controller.canvas.zoomPercent, strokeAngle = controller.rotationView.rotationDegrees
        send(.magnify, 1); send(.rotate, 45)
        check(doc.strokeIsActive && controller.canvas.zoomPercent == strokeZoom
                && controller.rotationView.rotationDegrees == strokeAngle, "an active stroke refuses trackpad navigation")
        doc.endStroke()
        doc.inputQueue.sync {}
        wait { doc.pendingWork == 0 }
        window.orderOut(nil)
        send(.magnify, 1)
        check(controller.canvas.zoomPercent == strokeZoom, "a hidden owning window ignores navigation")
        var closed = false
        controller.canvas.stopRendering {
            doc.closeImageWhenDrained { closed = true }
        }
        wait { closed }
        send(.magnify, 1); send(.rotate, 45)
        check(controller.canvas.zoomPercent == strokeZoom && controller.rotationView.rotationDegrees == strokeAngle,
              "late trackpad events after image close are ignored")
    }
}
