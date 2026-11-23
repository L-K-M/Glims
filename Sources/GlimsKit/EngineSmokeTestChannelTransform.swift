import AppKit

@MainActor
extension EngineSmokeTest {
    /// Quick Mask > Free Transform > Quick Mask, and Free Transform on a
    /// saved selection: the Transform tool works on the one active channel,
    /// through real canvas events.
    static func exerciseChannelTransform(_ session: EngineSession, documents: DocumentList) throws {
        guard session.supportsChannelTransform else {
            print("     channel transform: this engine cannot transform channels; skipped")
            return
        }
        let image = try session.newImage(width: 120, height: 80)
        let document = try ImageDocument(session: session, image: image, name: "Channel Transform")
        var errors: [String] = []
        document.onError = { errors.append($0) }
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        let toolBefore = ToolState.shared.current
        // Nearest Neighbor keeps the scaled coverage's box exact; a
        // smoothing method spreads partial coverage past its edges.
        let interpolationBefore = ToolState.shared.transformInterpolation
        ToolState.shared.transformInterpolation = .none
        defer {
            ToolState.shared.transformInterpolation = interpolationBefore
            ToolState.shared.select(toolBefore)
            controller.window?.orderOut(nil)
            document.closeImageWhenDrained()
            documents.items.removeAll { $0 === document }
        }
        guard let window = controller.window else {
            check(false, "channel transform: the document has a window")
            return
        }
        func drain(_ what: String) {
            let deadline = Date().addingTimeInterval(15)
            while (document.pendingWork > 0 || EngineActivity.shared.isBusy) && Date() < deadline { spin(0.02) }
            check(document.pendingWork == 0, "channel transform: \(what) drains")
        }
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            let scale = controller.canvas.scale
            guard let event = NSEvent.mouseEvent(
                with: type, location: controller.canvas.convert(CGPoint(x: point.x * scale, y: point.y * scale), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: controller.canvas.mouseDown(with: event)
            case .leftMouseDragged: controller.canvas.mouseDragged(with: event)
            default: controller.canvas.mouseUp(with: event)
            }
        }
        func drag(from start: CGPoint, by offset: CGSize) {
            send(.leftMouseDown, start)
            send(.leftMouseDragged, CGPoint(x: start.x + offset.width / 2, y: start.y + offset.height / 2))
            send(.leftMouseDragged, CGPoint(x: start.x + offset.width, y: start.y + offset.height))
            send(.leftMouseUp, CGPoint(x: start.x + offset.width, y: start.y + offset.height))
        }
        func pressReturn() {
            guard let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: window.windowNumber, context: nil, characters: "\r",
                                               charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
                check(false, "channel transform: a Return key event can be made")
                return
            }
            controller.canvas.keyDown(with: enter)
        }
        func box() -> CGRect? { document.activeDrawable.flatMap { document.channelBoxes[$0] } }
        let tools = controller.canvas.tools
        let rectangle = CGRect(x: 20, y: 10, width: 30, height: 20)
        let moved = rectangle.offsetBy(dx: 20, dy: 10)

        // Quick Mask over a rectangle: the Transform tool takes its channel.
        try session.select(.rectangle(rectangle), image: image, options: .init(antialias: false))
        try document.reload()
        document.setQuickMask(true)
        drain("Quick Mask on")
        check(document.quickMaskState?.enabled == true && document.isChannelTargetActive && box() == rectangle,
              "channel transform: Quick Mask's channel is the target, boxed by the rectangle")
        ToolState.shared.select(.transform)
        check(tools.transformModeSelectionAllowed && tools.transformPreview?.targetsChannel == true
                && tools.transformPreview?.original == rectangle,
              "channel transform: the Transform tool offers the channel's box")
        let steps = document.undoInfo.undoCount
        drag(from: CGPoint(x: rectangle.midX, y: rectangle.midY), by: CGSize(width: 20, height: 10))
        check(tools.transformIsApplicable && tools.transformSession?.targetsChannel == true,
              "channel transform: dragging inside the box moves it, waiting for Return")
        pressReturn()
        drain("the channel transform")
        check(box() == moved && document.undoInfo.undoCount == steps + 1 && tools.transformSession == nil,
              "channel transform: Return moves the mask's coverage as one undo step")
        document.setQuickMask(false)
        drain("Quick Mask off")
        check(try session.selectionBounds(image: image) == moved,
              "channel transform: turning Quick Mask off leaves the moved selection")

        // A saved selection transforms the same way, with a scale this time.
        document.saveSelectionToChannel(name: "Saved")
        drain("Save Selection")
        guard let saved = document.channels.first(where: { $0.name == "Saved" })?.id else {
            check(false, "channel transform: the selection was saved as a channel")
            return
        }
        document.selectChannel(saved)
        drain("selecting the saved channel")
        check(document.activeDrawable == saved && box() == moved,
              "channel transform: a saved selection is the target, boxed by its coverage")
        let before = document.undoInfo.undoCount
        drag(from: CGPoint(x: moved.maxX, y: moved.maxY), by: CGSize(width: 30, height: 20))
        pressReturn()
        drain("the saved channel's transform")
        check(box() == CGRect(x: moved.minX, y: moved.minY, width: moved.width + 30, height: moved.height + 20)
                && document.undoInfo.undoCount == before + 1,
              "channel transform: dragging a corner scales the saved channel's coverage "
              + "(\(String(describing: box())))")
        document.undo()
        drain("Undo")
        check(box() == moved, "channel transform: Undo restores the saved channel")

        // Two selected channels are no single target; the refusal says so.
        document.saveSelectionToChannel(name: "Second")
        drain("saving a second channel")
        guard let second = document.channels.first(where: { $0.name == "Second" })?.id else {
            check(false, "channel transform: the second channel was saved")
            return
        }
        document.selectChannelItems([saved, second])
        drain("selecting both channels")
        tools.transformDocumentStateDidChange()
        let undoBeforePair = document.undoInfo.undoCount
        send(.leftMouseDown, CGPoint(x: moved.midX, y: moved.midY))
        send(.leftMouseUp, CGPoint(x: moved.midX, y: moved.midY))
        check(document.hasMultipleSelectedChannels && tools.transformSession == nil
                && document.undoInfo.undoCount == undoBeforePair
                && controller.statusBar.message == "Select only one channel to transform.",
              "channel transform: two selected channels refuse with a reason (\(controller.statusBar.message))")
        document.selectChannel(saved)
        drain("selecting the saved channel again")

        // While recording, the Recorder keeps a failed row that names it.
        try document.startRecording()
        drag(from: CGPoint(x: moved.midX, y: moved.midY), by: CGSize(width: -10, height: 0))
        pressReturn()
        drain("a recorded channel transform")
        let rows = document.recorder.records.map { record -> String in
            if case .failure(let reason) = record.resolution { return reason }
            return "not a failed row"
        }
        check(rows == ["Recorder does not yet save Transform Channel."],
              "channel transform: a recording keeps one failed row for it (\(rows))")
        try document.stopRecording()

        // A channel that covers nothing has no box to transform.
        try session.selectItems([], kind: .channel, image: image)
        try session.select(.none, image: image)
        try document.reload()
        document.setQuickMask(true)
        drain("Quick Mask over no selection")
        tools.transformDocumentStateDidChange()
        send(.leftMouseDown, CGPoint(x: 60, y: 40))
        send(.leftMouseUp, CGPoint(x: 60, y: 40))
        check(tools.transformSession == nil && controller.statusBar.message.hasPrefix("The channel covers nothing"),
              "channel transform: an empty Quick Mask refuses with a reason")
        check(errors.isEmpty, "channel transform: no errors (\(errors))")
    }
}
