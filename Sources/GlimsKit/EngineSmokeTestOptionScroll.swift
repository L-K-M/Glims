import AppKit

private final class OptionWheelEvent: NSEvent {
    let owner: Int, point: CGPoint, flags: NSEvent.ModifierFlags
    let dx: CGFloat, dy: CGFloat, precise: Bool, touch: NSEvent.Phase, momentum: NSEvent.Phase
    init(window: Int, point: CGPoint, x: CGFloat = 0, y: CGFloat, precise: Bool = false,
         flags: NSEvent.ModifierFlags = .option, phase: NSEvent.Phase = [], momentum: NSEvent.Phase = []) {
        owner = window; self.point = point; dx = x; dy = y; self.precise = precise
        self.flags = flags; touch = phase; self.momentum = momentum
        super.init()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
    override var type: NSEvent.EventType { .scrollWheel }
    override var windowNumber: Int { owner }
    override var locationInWindow: NSPoint { point }
    override var modifierFlags: NSEvent.ModifierFlags { flags }
    override var scrollingDeltaX: CGFloat { dx }
    override var scrollingDeltaY: CGFloat { dy }
    override var hasPreciseScrollingDeltas: Bool { precise }
    override var phase: NSEvent.Phase { touch }
    override var momentumPhase: NSEvent.Phase { momentum }
}

@MainActor
extension EngineSmokeTest {
    static func exerciseOptionScroll(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 1800, height: 1400)
        let doc = try ImageDocument(session: session, image: image, name: "Option scroll")
        documents.items.append(doc)
        let controller = DocumentWindowController(document: doc)
        controller.window?.setContentSize(NSSize(width: 540, height: 420))
        controller.showWindow(nil)
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        defer {
            controller.window?.orderOut(nil)
            var stopped = false
            controller.canvas.stopRendering { stopped = true }; wait { stopped }
            if !doc.isClosing {
                var closed = false
                doc.closeImageWhenDrained { closed = true }; wait { closed }
            }
            documents.items.removeAll { $0 === doc }
        }
        guard let window = controller.window else { return check(false, "Option-scroll has a real window") }
        let native = try session.info(image), undo = try session.undoInfo(image)
        let pixels = try session.copyPixels(image, merged: true).pixels
        controller.zoom(to: 180); controller.setViewRotation(degrees: 30)
        controller.center(on: CGPoint(x: 900, y: 700))
        let clip = controller.scrollView.contentView
        let anchor = clip.convert(CGPoint(x: clip.bounds.midX + 31, y: clip.bounds.midY - 23), to: nil)
        func imagePoint(_ point: CGPoint) -> CGPoint { controller.canvas.imagePoint(at: controller.canvas.convert(point, from: nil)) }
        func send(_ y: CGFloat, x: CGFloat = 0, precise: Bool = false, phase: NSEvent.Phase = [],
                  momentum: NSEvent.Phase = [], point: CGPoint? = nil, owner: Int? = nil) {
            controller.scrollView.scrollWheel(with: OptionWheelEvent(window: owner ?? window.windowNumber,
                point: point ?? anchor, x: x, y: y, precise: precise, phase: phase, momentum: momentum))
        }
        let beforeAnchor = imagePoint(anchor)
        send(8)
        check(controller.canvas.zoomPercent == 360, "coarse Option-scroll applies its relative zoom through the real scroll view")
        check(abs(beforeAnchor.x - imagePoint(anchor).x) < 0.01 && abs(beforeAnchor.y - imagePoint(anchor).y) < 0.01,
              "Option-scroll preserves the pointer's image coordinate while rotated")
        controller.zoom(to: 180); send(240, precise: true)
        check(controller.canvas.zoomPercent == 360, "precise point deltas use the intended independent scale")
        controller.zoom(to: 100)
        send(0.04, phase: .began); send(0, phase: .cancelled); send(0.04)
        check(controller.canvas.zoomPercent == 100, "zero-delta cancellation clears a pending sub-percent wheel fraction")
        send(0, phase: .ended); send(0.04)
        check(controller.canvas.zoomPercent == 100, "zero-delta ending clears a pending fraction")
        send(0.04)
        check(controller.canvas.zoomPercent == 101, "successive wheel fractions accumulate before integer publication")
        controller.zoom(to: 200); send(8)
        check(controller.canvas.zoomPercent == 400, "an external menu zoom rebases the next wheel message")
        controller.zoom(to: 200)
        send(120, precise: true, momentum: .began); send(120, precise: true, momentum: .changed); send(0, precise: true, momentum: .ended)
        check(controller.canvas.zoomPercent == 400, "Option-held momentum uses relative precise deltas and retains fractions")
        send(0, x: -8)
        check(controller.canvas.zoomPercent == 200, "horizontal shifted-wheel deltas zoom when the vertical delta is zero")
        let stable = controller.canvas.zoomPercent
        send(.nan); send(.infinity); send(8, point: CGPoint(x: CGFloat.nan, y: 0)); send(8, owner: window.windowNumber + 12345)
        check(controller.canvas.zoomPercent == stable, "invalid deltas, invalid anchors and another window leave zoom unchanged")
        let command = OptionWheelEvent(window: window.windowNumber, point: anchor, y: 8, flags: [.option, .command])
        let control = OptionWheelEvent(window: window.windowNumber, point: anchor, y: 8, flags: [.option, .control])
        check(!controller.canvas.handleOptionScroll(command) && !controller.canvas.handleOptionScroll(control),
              "Command and Control combinations are handed back to native scrolling")
        controller.zoom(to: 180); controller.center(on: CGPoint(x: 900, y: 700))
        let panBefore = clip.bounds.origin
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 60, wheel2: 0, wheel3: 0),
           let event = NSEvent(cgEvent: cg) {
            controller.scrollView.scrollWheel(with: event)
            wait { clip.bounds.origin != panBefore }
            check(controller.canvas.zoomPercent == 180 && clip.bounds.origin != panBefore,
                  "a real unmodified CG scroll event follows AppKit's normal pan path: delta=\(event.scrollingDeltaY), precise=\(event.hasPreciseScrollingDeltas), window=\(event.windowNumber), before=\(panBefore), after=\(clip.bounds.origin)")
        } else { check(false, "a real native wheel event can be constructed") }
        clip.scroll(to: .zero); controller.scrollView.reflectScrolledClipView(clip)
        let grayPoint = clip.convert(CGPoint(x: clip.bounds.minX + 20, y: clip.bounds.minY + 20), to: nil)
        let inCanvas = controller.canvas.convert(grayPoint, from: nil)
        check(!controller.canvas.bounds.contains(inCanvas), "the gray-gap fixture really lies outside the rotated canvas")
        let hit = clip.hitTest(controller.scrollView.convert(grayPoint, from: nil))
        hit?.scrollWheel(with: OptionWheelEvent(window: window.windowNumber, point: grayPoint, y: 8))
        check(hit != nil && controller.canvas.zoomPercent == 360,
              "Option-scroll bubbles from the gray viewport gap to the owning scroll view")
        let gate = DispatchSemaphore(value: 0); var idle = false
        let admitted = EngineActivity.shared.perform(label: "Option-scroll view check", work: { gate.wait() }, completion: { idle = true })
        send(-8); gate.signal(); wait { idle }
        check(admitted && controller.canvas.zoomPercent == 180, "view-only wheel zoom remains available during engine work")
        check(try session.info(image) == native && session.undoInfo(image) == undo && session.copyPixels(image, merged: true).pixels == pixels,
              "wheel navigation preserves native pixels, dimensions, dirty state and history")
        doc.beginStroke(at: .init(x: 20, y: 20, pressure: 1), brush: .init(size: 3, opacity: 1, pressureSize: false))
        let strokeZoom = controller.canvas.zoomPercent
        let strokePan = clip.bounds.origin
        send(8)
        check(doc.strokeIsActive && controller.canvas.zoomPercent == strokeZoom && clip.bounds.origin == strokePan,
              "an active stroke consumes Option-scroll without zooming or falling through to pan")
        doc.endStroke(); doc.inputQueue.sync {}; wait { doc.pendingWork == 0 }
        window.orderOut(nil); send(8)
        check(controller.canvas.zoomPercent == strokeZoom, "hidden windows ignore modified scrolling")
        var stopped = false; controller.canvas.stopRendering { stopped = true }; wait { stopped }
        var closed = false; doc.closeImageWhenDrained { closed = true }; wait { closed }
        send(8)
        check(closed && controller.canvas.zoomPercent == strokeZoom, "late wheel events after image close are ignored")
    }
}
