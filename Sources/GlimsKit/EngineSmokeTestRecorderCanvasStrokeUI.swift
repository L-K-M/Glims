import AppKit

private struct RecorderCanvasPixels: Equatable {
    let raw: Data
    let merged: Data
}

@MainActor
extension EngineSmokeTest {
    /// Synthesized mouse events use the real canvas entry points in a launched
    /// host. Ordinary V1 calls on an independent image provide the oracle.
    static func exerciseRecorderCanvasStrokeUI(_ session: EngineSession, documents: DocumentList) throws {
        struct Scene { let image: Int32; let layer: Int32 }
        struct Native {
            let pixels: RecorderCanvasPixels
            let undo: EngineSession.UndoInfo
            let history: EngineSession.History
        }
        let state = ToolState.shared
        let oldTool = state.current, oldColor = state.foreground
        let oldPencil = state.brush(for: .pencil), oldEraser = state.brush(for: .eraser)
        var loose: [Int32] = []
        var owned: [ImageDocument] = []
        var windows: [DocumentWindowController] = []
        var palette: RecorderPaletteController?
        var paletteWindow: NSPanel?
        var checks = 0
        var complete = false
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            check(value, "Recorder canvas: \(message)")
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "RecorderCanvasStrokeUI", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }
        func drain(_ document: ImageDocument, settled: Bool = true) throws {
            try require(wait {
                document.pendingWork == 0 && !EngineActivity.shared.isBusy &&
                (!settled || document.recorder.pendingCount == 0)
            }, "Accepted canvas or Recorder work did not drain")
        }
        func views<T: NSView>(_ view: NSView?, _ type: T.Type) -> [T] {
            guard let view else { return [] }
            return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views($0, type) }
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        defer {
            palette?.retarget(to: nil)
            paletteWindow?.orderOut(nil)
            paletteWindow?.close()
            var stoppedAll = true
            for owner in windows {
                owner.window?.orderOut(nil)
                var stopped = false
                owner.canvas.stopRendering { stopped = true }
                if !wait({ stopped }) { stoppedAll = false }
                owner.window?.close()
            }
            owned.forEach { $0.closeImageWhenDrained() }
            expect(stoppedAll && wait { owned.allSatisfy { $0.pendingWork == 0 && gone($0.image) } },
                   "owned windows, renderers and accepted native work drain")
            for image in loose { if !gone(image) { try? session.closeImage(image) } }
            expect(loose.allSatisfy(gone) && paletteWindow?.isVisible != true &&
                   windows.allSatisfy { $0.window?.attachedSheet == nil && $0.window?.isVisible != true },
                   "reference images and the Recorder controls close without owned sheets")
            documents.items.removeAll { candidate in owned.contains { $0 === candidate } }
            state.update(.pencil) { $0 = oldPencil }
            state.update(.eraser) { $0 = oldEraser }
            state.foreground = oldColor
            state.select(oldTool)
            expect(complete, "every canvas and explicit replay scenario completed")
            print("     recorder-canvas-stroke-ui checks: \(checks)")
        }

        var bottom: [UInt8] = [], top: [UInt8] = []
        for y in 0..<29 {
            for x in 0..<47 {
                bottom += [UInt8((x * 11 + y * 7) % 256), UInt8(y * 7), UInt8(x * 5), 255]
                top += [UInt8(x * 5), UInt8((y * 19 + x * 9) % 256), UInt8(y * 8), UInt8(77 + (x + y) % 96)]
            }
        }
        func scene() throws -> Scene {
            let image = try session.newImage(pixels: .init(width: 47, height: 29, pixels: Data(bottom), origin: .zero))
            loose.append(image)
            let layer = try session.pastePixels(image, pixels: .init(width: 47, height: 29, pixels: Data(top), origin: .zero), at: .zero)
            return .init(image: image, layer: layer)
        }
        func document(_ scene: Scene, name: String, show: Bool) throws -> ImageDocument {
            let document = try ImageDocument(session: session, image: scene.image, name: name)
            owned.append(document)
            loose.removeAll { $0 == scene.image }
            documents.items.append(document)
            if show {
                let owner = DocumentWindowController(document: document)
                windows.append(owner)
                owner.showWindow(nil)
                owner.zoom(to: 100)
            }
            try drain(document)
            return document
        }
        func native(_ image: Int32) throws -> Native {
            try .init(pixels: .init(raw: session.copyPixels(image, merged: false).pixels,
                                   merged: session.copyPixels(image, merged: true).pixels),
                      undo: session.undoInfo(image), history: session.history(image))
        }
        func agrees(_ image: Int32, _ expected: Native) throws -> Bool {
            let value = try native(image)
            return value.pixels == expected.pixels && value.undo == expected.undo &&
                value.history.currentPosition == expected.history.currentPosition && value.history.rows == expected.history.rows
        }
        let source = try scene(), other = try scene(), reference = try scene(), destination = try scene()
        let a = try document(source, name: "Canvas Recorder A", show: true)
        let b = try document(other, name: "Canvas Recorder B", show: true)
        let c = try document(destination, name: "Bound canvas replay C", show: false)
        let ownerA = windows[0], ownerB = windows[1]
        var errorsA: [String] = [], errorsC: [String] = []
        a.onError = { errorsA.append($0) }
        c.onError = { errorsC.append($0) }
        let initial = try native(reference.image)
        let bIDs = try session.layers(b.image).map(\.id)
        expect(try Set([source.layer, other.layer, reference.layer, destination.layer]).count == 4 &&
               agrees(a.image, initial) && agrees(b.image, initial) && agrees(c.image, initial) &&
               initial.pixels.raw != initial.pixels.merged, "independent layer IDs start with identical textured RGBA pixels and history")
        NSApp.activate(ignoringOtherApps: true)
        func front(_ owner: DocumentWindowController) throws {
            owner.window?.makeMain()
            owner.window?.makeKeyAndOrderFront(nil)
            try require(wait { NSApp.isActive && NSApp.mainWindow === owner.window && NSApp.keyWindow === owner.window },
                        "The intended canvas owner did not become main/key")
        }
        try front(ownerA)
        let controls = RecorderPaletteController()
        palette = controls
        let host = NSPanel(contentRect: NSRect(origin: .zero, size: RecorderPaletteController.definition.contentSize),
                           styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        paletteWindow = host
        host.isReleasedWhenClosed = false
        host.title = "Canvas Recorder controls"
        host.contentViewController = controls
        controls.retarget(to: a)
        host.orderFront(nil)
        host.contentView?.layoutSubtreeIfNeeded()
        func status() -> String {
            views(host.contentView, NSTextField.self).first { $0.accessibilityLabel() == "Recorder status" }?.stringValue ?? ""
        }
        func paletteCommand(_ action: RecorderPaletteAction) throws {
            controls.retarget(to: a)
            guard let item = controls.paletteMenu?.items.first(where: { $0.tag == action.rawValue }),
                  let selector = item.action else { throw NSError(domain: "RecorderCanvasStrokeUI", code: 2) }
            try require(controls.validateMenuItem(item) && NSApp.sendAction(selector, to: item.target, from: item),
                        "The actual Recorder palette menu action was not admitted")
        }
        try paletteCommand(.record)
        expect(a.recorder.isRecording && a.recorder.records.isEmpty && status().hasPrefix("Recording supported actions."),
               "the real Recorder menu starts A and its visible controls report recording")

        let pencil = EngineSession.Brush(tool: .pencil, size: 8, opacity: 0.73, red: 0.83, green: 0.15, blue: 0.41)
        var eraser = pencil
        eraser.tool = .eraser; eraser.size = 10; eraser.opacity = 0.61
        expect(pencil.pressureSize && eraser.pressureSize && pencil.resource == nil,
               "both gestures retain the ordinary default pressure-size setting and inherited brush")
        let first = EngineSession.StrokePoint(x: 6.5, y: 7.5, pressure: 1, timeMilliseconds: 10_000)
        let pencilPoints: [EngineSession.StrokePoint] = [
            .init(x: 13.5, y: 11.5, pressure: 1, timeMilliseconds: 10_125),
            .init(x: 21.5, y: 16.5, pressure: 1, timeMilliseconds: 10_250),
            .init(x: 27.5, y: 19.5, pressure: 1, timeMilliseconds: 10_375),
        ]
        let eraseFirst = EngineSession.StrokePoint(x: 25.5, y: 13.5, pressure: 1, timeMilliseconds: 11_000)
        let eraserPoints: [EngineSession.StrokePoint] = [
            .init(x: 31.5, y: 18.5, pressure: 1, timeMilliseconds: 11_125),
            .init(x: 35.5, y: 20.5, pressure: 1, timeMilliseconds: 11_250),
            .init(x: 41.5, y: 24.5, pressure: 1, timeMilliseconds: 11_375),
        ]
        func pointer(_ type: NSEvent.EventType, _ sample: EngineSession.StrokePoint) throws {
            let canvas = ownerA.canvas
            guard let window = ownerA.window,
                  let event = NSEvent.mouseEvent(with: type,
                    location: canvas.convert(CGPoint(x: sample.x * canvas.scale, y: sample.y * canvas.scale), to: nil),
                    modifierFlags: [], timestamp: Double(sample.timeMilliseconds) / 1000, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 0.4),
                  event.subtype != .tabletPoint else { throw NSError(domain: "RecorderCanvasStrokeUI", code: 3) }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        func direct(_ brush: EngineSession.Brush, first: EngineSession.StrokePoint, points: [EngineSession.StrokePoint]) throws {
            let stroke = try session.beginStroke(image: reference.image, drawable: reference.layer, brush: brush, first: first)
            do {
                for point in points { try session.continueStroke(stroke, points: [point]) }
            } catch { try? session.endStroke(stroke); throw error }
            try session.endStroke(stroke)
        }
        state.foreground = NSColor(srgbRed: 0.83, green: 0.15, blue: 0.41, alpha: 1)
        state.update(.pencil) { $0 = pencil }; state.select(.pencil)
        try pointer(.leftMouseDown, first); try drain(a, settled: false)
        expect(a.strokeIsActive && a.recorder.records.isEmpty && a.recorder.pendingCount == 1,
               "actual Pencil mouse-down has one reservation and no partial successful command after native drain")
        try pointer(.leftMouseDragged, pencilPoints[0]); try drain(a, settled: false)
        expect(a.strokeIsActive && a.recorder.records.isEmpty && a.recorder.pendingCount == 1,
               "actual Pencil drag still exposes no completed gesture")
        state.update(.pencil) { $0.size = 31; $0.opacity = 0.2 }
        state.foreground = .green
        try front(ownerB)
        expect(NSApp.mainWindow === ownerB.window && NSApp.keyWindow === ownerB.window && a.strokeIsActive,
               "B becomes actual main/key while the accepted ordinary Pencil remains owned by A")
        try pointer(.leftMouseDragged, pencilPoints[1])
        try pointer(.leftMouseUp, pencilPoints[2]); try drain(a)
        try direct(pencil, first: first, points: pencilPoints)
        let afterPencil = try native(reference.image)
        guard a.recorder.records.count == 1,
              case .success(.completeStroke(let capturedPencil)) = a.recorder.records[0].resolution else {
            throw NSError(domain: "RecorderCanvasStrokeUI", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "The default-pressure canvas Pencil did not settle as one supported stroke"])
        }
        expect(try errorsA.isEmpty && agrees(a.image, afterPencil) && afterPencil.pixels != initial.pixels &&
               afterPencil.undo.undoCount == initial.undo.undoCount + 1,
               "the completed A Pencil equals literal ordinary V1 raw/merged pixels and one Undo")
        expect(try capturedPencil.settings.tool == .pencil && capturedPencil.settings.size == 8 &&
               capturedPencil.settings.opacity == 0.73 && capturedPencil.settings.red == 0.83 &&
               capturedPencil.settings.green == 0.15 && capturedPencil.settings.blue == 0.41 &&
               capturedPencil.settings.hardness == nil && capturedPencil.settings.pressureSize && !capturedPencil.settings.antiErase &&
               capturedPencil.trace.first == .init(first) &&
               capturedPencil.trace.batches == pencilPoints.map { [try RecorderStrokeTrace.Point($0)] },
               "Pencil owns exact press settings and every literal mouse sample including release despite changed global controls")
        expect(try agrees(b.image, initial) && session.layers(b.image).map(\.id) == bIDs && b.recorder.records.isEmpty,
               "the accepted A gesture leaves B's native pixels, history, layer IDs and Recorder untouched")

        try front(ownerA)
        state.foreground = NSColor(srgbRed: 0.83, green: 0.15, blue: 0.41, alpha: 1)
        state.update(.eraser) { $0 = eraser }; state.select(.eraser)
        try pointer(.leftMouseDown, eraseFirst); try drain(a, settled: false)
        try pointer(.leftMouseDragged, eraserPoints[0]); try drain(a, settled: false)
        expect(a.strokeIsActive && a.recorder.records.count == 1 && a.recorder.pendingCount == 1,
               "RGBA Eraser down and drag keep the second whole-stroke reservation unresolved")
        try paletteCommand(.stop)
        expect(!a.recorder.isRecording && a.strokeIsActive && a.recorder.records.count == 1 &&
               a.recorder.pendingCount == 1 && status() == "Waiting for accepted commands to finish.",
               "the actual Stop menu and visible status preserve A's accepted Eraser until release")
        try front(ownerB)
        try pointer(.leftMouseDragged, eraserPoints[1])
        try pointer(.leftMouseUp, eraserPoints[2]); try drain(a)
        try direct(eraser, first: eraseFirst, points: eraserPoints)
        let finished = try native(reference.image)
        guard a.recorder.records.count == 2,
              case .success(.completeStroke(let capturedEraser)) = a.recorder.records[1].resolution else {
            throw NSError(domain: "RecorderCanvasStrokeUI", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "The accepted post-Stop canvas Eraser did not settle as one supported stroke"])
        }
        expect(try errorsA.isEmpty && !a.strokeIsActive && !a.recorder.isRecording && a.recorder.pendingCount == 0 &&
               agrees(a.image, finished) && finished.pixels != afterPencil.pixels &&
               finished.undo.undoCount == afterPencil.undo.undoCount + 1,
               "post-Stop Eraser completion matches independent V1 pixels and adds exactly its one Undo")
        expect(try capturedEraser.settings.tool == .eraser && capturedEraser.settings.size == 10 &&
               capturedEraser.settings.opacity == 0.61 && capturedEraser.settings.red == 0.83 &&
               capturedEraser.settings.green == 0.15 && capturedEraser.settings.blue == 0.41 &&
               capturedEraser.settings.hardness == nil && capturedEraser.settings.pressureSize &&
               !capturedEraser.settings.antiErase && capturedEraser.trace.first == .init(eraseFirst) &&
               capturedEraser.trace.batches == eraserPoints.map { [try RecorderStrokeTrace.Point($0)] },
               "Eraser owns the exact default-pressure settings and post-Stop samples with no partial rows")

        let metadata = a.recorderFileMetadata
        let file = try RecorderFileCodec.snapshot(a.recorder, recordingID: metadata.recordingID, name: metadata.name,
            origin: metadata.origin, descriptions: a.recorderDescriptions, bindings: a.recorderBindingDescriptions)
        let prepared = try RecorderFileSemanticBridge.prepare(file)
        guard file.symbols.count == 1, let symbol = file.symbols.first?.id else { throw NSError(domain: "RecorderCanvasStrokeUI", code: 6) }
        var install: Result<Void, Error>?
        var installs = 0, held = 0
        c.installRecording(prepared, checkpoint: try c.recorderInstallCheckpoint(), choices: [symbol: .layer(destination.layer)]) {
            installs += 1; held = c.pendingWork; install = $0
        }
        try drain(c)
        try require(installs == 1 && install != nil, "The explicit destination binding did not complete exactly once")
        try install?.get()
        expect(try held > 0 && c.recorder.records.count == 2 && agrees(c.image, initial) &&
               session.selectedLayers(c.image) == [destination.layer],
               "counted explicit installation binds C's separately seeded layer without native mutation")
        try require(NSApp.mainWindow === ownerB.window, "B must remain front before captured replay")
        try c.startReplay()
        try require(wait { c.replayStatus == .finished(total: 2) && c.pendingWork == 0 }, "The two explicitly bound canvas strokes did not replay")
        expect(try errorsC.isEmpty && agrees(c.image, finished) && session.selectedLayers(c.image) == [destination.layer],
               "separate bound replay while B is front matches both direct V1 strokes and their complete history")
        c.undo(); try drain(c)
        expect(try native(c.image).pixels == afterPencil.pixels && session.undoInfo(c.image).undoCount == afterPencil.undo.undoCount,
               "one Undo removes only the replayed Eraser")
        c.undo(); try drain(c)
        expect(try native(c.image).pixels == initial.pixels && session.undoInfo(c.image).undoCount == initial.undo.undoCount,
               "the second Undo restores both original buffers")
        c.redo(); try drain(c)
        expect(try native(c.image).pixels == afterPencil.pixels, "one Redo restores only the independent Pencil")
        c.redo(); try drain(c)
        expect(try agrees(c.image, finished), "the second Redo restores the independent final pixels and history")
        expect(try agrees(a.image, finished) && agrees(b.image, initial) && a.recorder.records.count == 2 &&
               b.recorder.records.isEmpty && session.selectedLayers(a.image) == [source.layer] &&
               session.layers(b.image).map(\.id) == bIDs,
               "explicit replay and Undo/Redo preserve captured A and front B")
        complete = true
    }
}
