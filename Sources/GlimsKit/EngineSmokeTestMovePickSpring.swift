import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseMovePickSpring(_ session: EngineSession, documents: DocumentList) throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            check(value, "Move Pick and Spring: \(message)")
        }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "MovePickSpring", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(12)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }

        let state = ToolState.shared
        let priorTool = state.current, priorMode = state.moveTargetMode
        state.select(shortcut: ToolID.move.shortcut, cycle: false)
        let priorMoveChoice = state.current
        let image = try session.newImage(width: 96, height: 64)
        var owner: DocumentWindowController?
        var holds: [MovePickSpringHold] = []
        defer {
            for hold in holds { hold.release.signal() }
            if let owner {
                owner.window?.close()
                documents.items.removeAll { $0 === owner.imageDocument }
            } else {
                try? session.closeImage(image)
            }
            expect(wait { (try? session.info(image)) == nil && (owner?.imageDocument.pendingWork ?? 0) == 0 },
                   "native image and accepted work close")
            expect(owner?.window?.isVisible != true && owner?.window?.attachedSheet == nil,
                   "the owned window and dialogs are gone")
            expect(holds.allSatisfy { !$0.expired }, "queue holds end by explicit signal")
            state.setMoveTargetMode(priorMode)
            state.select(priorMoveChoice)
            state.select(priorTool)
            print("     move-pick-spring checks: \(checks)")
        }

        guard let bottom = try session.layers(image).first?.id else {
            throw NSError(domain: "MovePickSpring", code: 6, userInfo: [NSLocalizedDescriptionKey: "Missing fixture base layer"])
        }
        let payload = ClipboardImage(width: 12, height: 12,
            pixels: Data((0..<144).flatMap { _ in [UInt8(199), 21, 103, 255] }), origin: CGPoint(x: 24, y: 24))
        let top = try session.pastePixels(image, pixels: payload, at: payload.origin)
        try session.selectLayer(bottom, image: image)
        let originalBounds = CGRect(x: 24, y: 24, width: 12, height: 12)
        try require(try session.layers(image).first(where: { $0.id == top })?.bounds == originalBounds,
                    "literal pasted layer origin changed")
        let document = try ImageDocument(session: session, image: image, name: "Move Pick and Spring")
        let controller = DocumentWindowController(document: document)
        owner = controller
        documents.items.append(document)
        controller.showWindow(nil)
        guard let window = controller.window else {
            throw NSError(domain: "MovePickSpring", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing document window"])
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let canvas = controller.canvas
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeMain()
        try require(window.makeFirstResponder(canvas), "canvas must own first responder")
        try require(wait { window.isKeyWindow && document.pendingWork == 0 }, "document focus/work did not settle")
        canvas.snapTo = SnapToViewState()

        func key(_ type: NSEvent.EventType, at time: Double, flags: NSEvent.ModifierFlags = []) throws {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                timestamp: time, windowNumber: window.windowNumber, context: nil, characters: "v",
                charactersIgnoringModifiers: "v", isARepeat: false, keyCode: 9) else {
                throw NSError(domain: "MovePickSpring", code: 3)
            }
            if type == .keyDown { canvas.keyDown(with: event) }
            else { canvas.keyUp(with: event) }
        }
        func pointer(_ type: NSEvent.EventType, at point: CGPoint, time: Double,
                     flags: NSEvent.ModifierFlags = []) throws {
            guard let event = NSEvent.mouseEvent(with: type,
                location: canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil),
                modifierFlags: flags, timestamp: time, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw NSError(domain: "MovePickSpring", code: 4)
            }
            if type == .leftMouseDown { canvas.mouseDown(with: event) }
            else { canvas.mouseUp(with: event) }
        }
        func releaseOption() throws {
            guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [],
                timestamp: 1.5, windowNumber: window.windowNumber, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 58) else {
                throw NSError(domain: "MovePickSpring", code: 5)
            }
            canvas.flagsChanged(with: event)
        }
        func blockQuery() throws -> MovePickSpringHold {
            let hold = MovePickSpringHold()
            holds.append(hold)
            document.inputQueue.async { hold.block() }
            try require(wait { hold.didStart }, "input queue hold did not start")
            return hold
        }

        state.setMoveTargetMode(.pickLayerOrGuide)
        state.select(.move) // Remember the V group choice before switching away.
        state.select(.paintbrush)
        let start = CGPoint(x: 26, y: 26), end = CGPoint(x: 33, y: 30)
        let originalUndo = try session.undoInfo(image).undoCount
        let moveHold = try blockQuery()
        try key(.keyDown, at: 1)
        expect(state.current == .move, "V selects Move for the captured press")
        try pointer(.leftMouseDown, at: start, time: 1.1)
        expect(document.pendingWork == 1, "a real opacity query is counted while its input queue is blocked")
        try pointer(.leftMouseUp, at: end, time: 1.2, flags: .option)
        try key(.keyUp, at: 1.4, flags: .option)
        expect(state.current == .move && canvas.tools.hasPendingInteraction,
               "release waits for the captured Pick before restoring the earlier tool")
        expect(controller.statusBar.message.hasPrefix("Drag a layer or guide."),
               "the buffered release keeps the captured Move hint")
        moveHold.release.signal()
        try require(wait { document.pendingWork == 0 && !canvas.tools.hasPendingInteraction },
                    "buffered Pick did not drain")
        expect(state.current == .paintbrush, "drain restores the previous tool exactly once")
        expect(controller.statusBar.message.hasPrefix("Option-click or drag to sample"),
               "the idle brush hint reconciles the live modifier after Pick")
        try releaseOption()
        expect(controller.statusBar.message.hasPrefix("Drag to apply brush."),
               "stationary Option release clears the sampling hint")
        expect(try session.selectedLayers(image) == [top] &&
               session.layers(image).first(where: { $0.id == top })?.bounds == originalBounds.offsetBy(dx: 7, dy: 4) &&
               session.undoInfo(image).undoCount == originalUndo + 1,
               "the buffered Pick selects and translates only the native hit with one Undo")

        document.undo()
        try require(wait { document.pendingWork == 0 }, "native Undo did not drain")
        document.selectLayer(bottom)
        try require(wait { document.pendingWork == 0 && document.activeLayer == bottom }, "fixture target reset did not drain")
        let undoBeforeFocus = try session.undoInfo(image)
        let pixelsBeforeFocus = try session.copyPixels(image, merged: true).pixels
        let focusHold = try blockQuery()
        try key(.keyDown, at: 2)
        try pointer(.leftMouseDown, at: start, time: 2.1)
        try pointer(.leftMouseUp, at: end, time: 2.2, flags: .option)
        try key(.keyUp, at: 2.4, flags: .option)
        expect(document.pendingWork == 1 && canvas.tools.hasPendingInteraction && state.current == .move,
               "focus control begins from a real deferred Pick")
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 100, height: 24))
        window.contentView?.addSubview(field)
        try require(window.makeFirstResponder(field) && window.firstResponder !== canvas, "field did not take canvas focus")
        defer { field.removeFromSuperview() }
        expect(!canvas.tools.hasPendingInteraction && state.current == .paintbrush,
               "focus loss retires the captured gesture and restores the spring tool")
        expect(controller.statusBar.message.hasPrefix("Drag to apply brush."),
               "focus loss clears the physical Option hint")
        focusHold.release.signal()
        try require(wait { document.pendingWork == 0 }, "cancelled query did not drain")
        try pointer(.leftMouseUp, at: end, time: 2.5)
        expect(try session.selectedLayers(image) == [bottom] && session.undoInfo(image) == undoBeforeFocus &&
               session.copyPixels(image, merged: true).pixels == pixelsBeforeFocus,
               "late query and late mouse-up leave target, Undo and pixels intact")
    }
}

private final class MovePickSpringHold: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var started = false
    private var timedOut = false
    var didStart: Bool {
        if !started { started = ready.wait(timeout: .now()) == .success }
        return started
    }
    var expired: Bool { lock.lock(); defer { lock.unlock() }; return timedOut }
    func block() {
        ready.signal()
        if release.wait(timeout: .now() + 25) != .success {
            lock.lock(); timedOut = true; lock.unlock()
        }
    }
}
