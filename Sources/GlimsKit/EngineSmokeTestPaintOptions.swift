import AppKit

/// Tool Options' blend mode, spacing and fade through real canvas strokes:
/// each changes the pixels as the engine paints them, and a recording keeps
/// a Paintbrush option stroke as a successful row that replays elsewhere.
extension EngineSmokeTest {
    static func exercisePaintOptions(_ session: EngineSession, documents: DocumentList) throws {
        guard session.supportsPaintOptions else {
            print("     paint options: this engine cannot paint with them; skipped")
            return
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let image = try session.newImage(width: 160, height: 100)
        let document = try ImageDocument(session: session, image: image, name: "Paint Options")
        var errors: [String] = []
        document.onError = { errors.append($0) }
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let state = ToolState.shared
        let oldTool = state.current, oldForeground = state.foreground
        let oldPencil = state.brush(for: .pencil), oldPaintbrush = state.brush(for: .paintbrush)
        defer {
            state.update(.pencil) { $0 = oldPencil }
            state.update(.paintbrush) { $0 = oldPaintbrush }
            state.select(oldTool); state.foreground = oldForeground
            controller.window?.orderOut(nil)
            var stopped = false; controller.canvas.stopRendering { stopped = true }; wait { stopped }
            var closed = false; document.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === document }
        }
        guard let window = controller.window else { return check(false, "paint options: the window exists") }
        window.contentView?.layoutSubtreeIfNeeded()
        let canvas = controller.canvas

        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 }; spin(0.03)
        }
        func gesture(_ points: [CGPoint]) {
            guard let first = points.first, let last = points.last else { return }
            let steps = [(NSEvent.EventType.leftMouseDown, first)]
                + points.dropFirst().map { (NSEvent.EventType.leftMouseDragged, $0) }
                + [(NSEvent.EventType.leftMouseUp, last)]
            for (type, point) in steps {
                let location = canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil)
                guard let event = NSEvent.mouseEvent(
                    with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    return check(false, "paint options: events construct")
                }
                switch type {
                case .leftMouseDown: canvas.mouseDown(with: event)
                case .leftMouseDragged: canvas.mouseDragged(with: event)
                default: canvas.mouseUp(with: event)
                }
            }
            settle()
        }
        func line(_ y: Double, from x0: Double, to x1: Double) -> [CGPoint] {
            (0...24).map { CGPoint(x: x0 + (x1 - x0) * Double($0) / 24, y: y) }
        }
        func red(_ x: Int, _ y: Int) -> Int { Int(pixel(session, image, x: x, y: y)?.first ?? 128) }

        // A Paintbrush stroke with a mode and a fade is a successful row
        // and replays the same pixels on a new identical image.
        state.select(.paintbrush)
        state.foreground = .black
        state.update(.paintbrush) {
            $0.clearPaintOptions(); $0.size = 4; $0.opacity = 1; $0.pressureSize = false
            $0.paintMode = "multiply"; $0.fade = .init(steps: 24, target: .transparent)
        }
        try document.startRecording()
        gesture(line(75, from: 10, to: 150))
        try document.stopRecording()
        guard document.recorder.records.count == 1,
              case .success(.completeStroke(let stroke)) = document.recorder.records[0].resolution else {
            return check(false, "paint options: a recorded Multiply fade stroke settles as one successful row")
        }
        check(stroke.settings.paintMode == "multiply" && stroke.settings.fade == .init(steps: 24, target: .transparent),
              "paint options: the row keeps the Multiply mode and the fade")
        let recorded = try session.copyPixels(image, merged: true).pixels
        let metadata = document.recorderFileMetadata
        let file = try RecorderFileCodec.snapshot(document.recorder, recordingID: metadata.recordingID,
            name: metadata.name, origin: metadata.origin, descriptions: document.recorderDescriptions,
            bindings: document.recorderBindingDescriptions)
        let copy = try session.newImage(width: 160, height: 100)
        let replay = try ImageDocument(session: session, image: copy, name: "Paint Options Replay")
        replay.onError = { errors.append($0) }
        documents.items.append(replay)
        defer {
            var closed = false; replay.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === replay }
        }
        guard let symbol = file.symbols.first?.id, let copyLayer = try session.layers(copy).first?.id else {
            return check(false, "paint options: the replay target offers its layer")
        }
        wait { replay.pendingWork == 0 }
        var installed: Result<Void, Error>?
        replay.installRecording(try RecorderFileSemanticBridge.prepare(file),
            checkpoint: try replay.recorderInstallCheckpoint(),
            choices: [symbol: .layer(copyLayer)]) { installed = $0 }
        wait { installed != nil && replay.pendingWork == 0 }
        _ = try installed?.get()
        try replay.startReplay()
        wait { replay.replayStatus == .finished(total: 1) && replay.pendingWork == 0 && !EngineActivity.shared.isBusy }
        check(try replay.replayStatus == .finished(total: 1) && (try session.copyPixels(copy, merged: true).pixels) == recorded,
              "paint options: replay on an identical image reproduces the recorded pixels")

        // The Mode menu lists every paint mode and sets the tool's brush.
        state.select(.pencil)
        state.foreground = .black
        state.update(.pencil) { $0.clearPaintOptions(); $0.size = 4; $0.opacity = 1; $0.resource = nil; $0.pressureSize = false }
        let options = ToolOptionsPaletteController()
        let mode = descendant(of: options.view, as: NSPopUpButton.self) { $0.identifier?.rawValue == "paint-mode" }
        check(mode?.numberOfItems == EngineSession.PaintModes.all.count && mode?.titleOfSelectedItem == "Normal",
              "paint options: Tool Options offers the paint modes, Normal first (\(mode?.numberOfItems ?? 0))")
        if let mode, let index = EngineSession.PaintModes.all.firstIndex(of: "lighten-only") {
            mode.selectItem(at: index)
            mode.sendAction(mode.action, to: mode.target)
        }
        check(state.brush(for: .pencil).paintMode == "lighten-only", "paint options: choosing Lighten Only sets the Pencil's mode")

        // Black in Lighten Only leaves white alone; in Normal it paints.
        let steps = try session.undoInfo(image).undoCount
        gesture(line(20, from: 10, to: 150))
        check(try red(80, 20) > 250 && (try session.undoInfo(image).undoCount) == steps + 1,
              "paint options: a Lighten Only black stroke leaves white unchanged as one step (\(red(80, 20)))")
        state.update(.pencil) { $0.paintMode = EngineSession.PaintModes.normal }
        gesture(line(30, from: 10, to: 150))
        check(red(80, 30) < 8, "paint options: the same stroke in Normal paints black (\(red(80, 30)))")

        // 400% spacing leaves gaps between the dabs.
        state.update(.pencil) { $0.spacing = 4 }
        gesture(line(45, from: 10, to: 150))
        let painted = (10...150).filter { red($0, 45) < 128 }.count
        check(painted > 15 && painted < 70, "paint options: 400% spacing paints separate dabs (\(painted) of 141 columns)")

        // A fade over 40 one-pixel dabs reaches nothing.
        state.update(.pencil) { $0.spacing = 0.25; $0.fade = .init(steps: 40, target: .transparent) }
        gesture(line(60, from: 10, to: 150))
        check(red(12, 60) < 40 && red(100, 60) > 250,
              "paint options: a faded stroke starts black and ends unpainted (\(red(12, 60)), \(red(100, 60)))")

        check(errors.isEmpty, "paint options: no errors (\(errors))")
    }
}
