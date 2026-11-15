import AppKit

@MainActor
extension EngineSmokeTest {
    /// Actual canvas and Recorder palette actions, with an older-adapter refusal case.
    static func exerciseRecorderSpongeUI(_ session: EngineSession, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "Recorder Sponge canvas: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "RecorderSpongeUI", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }
        func drain(_ document: ImageDocument) throws {
            try require(wait { document.pendingWork == 0 && document.recorder.pendingCount == 0 &&
                               !document.strokeIsActive && !EngineActivity.shared.isBusy }, "work did not drain")
        }
        let state = ToolState.shared
        let oldTool = state.current, oldForeground = state.foreground
        let oldDesaturate = state.brush(for: .spongeDesaturate), oldSaturate = state.brush(for: .spongeSaturate)
        defer {
            state.update(.spongeDesaturate) { $0 = oldDesaturate }
            state.update(.spongeSaturate) { $0 = oldSaturate }
            state.foreground = oldForeground
            state.select(oldTool)
        }
        let width = 40, height = 24
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            let rgba: [UInt8] = x < 20 ? [210, 60, 60, 255] : [160, 120, 120, 255]
            bytes[i..<i + 4] = rgba[0...3]
        } }
        let opaque = ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "recorder-sponge-opaque-ui"
        let image: Int32
        if opaque {
            // A normal new image starts with an opaque Background layer.
            // Give it a muted color so each Sponge direction has work to do.
            image = try session.newImage(width: width, height: height)
            do {
                try session.fill(image: image, at: .zero, mode: .selection,
                                 color: NSColor(srgbRed: 0.65, green: 0.4, blue: 0.4, alpha: 1))
            } catch {
                try? session.closeImage(image)
                throw error
            }
        } else {
            image = try session.newImage(pixels: .init(width: width, height: height, pixels: Data(bytes), origin: .zero))
        }
        let document = try ImageDocument(session: session, image: image, name: "Sponge Recorder")
        documents.items.append(document)
        let owner = DocumentWindowController(document: document)
        owner.showWindow(nil)
        owner.window?.makeKeyAndOrderFront(nil)
        owner.zoom(to: 600)
        let controls = RecorderPaletteController()
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: RecorderPaletteController.definition.contentSize),
                            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.contentViewController = controls
        controls.retarget(to: document)
        panel.orderFront(nil)
        defer {
            controls.retarget(to: nil)
            panel.orderOut(nil); panel.close()
            owner.window?.orderOut(nil)
            var stopped = false
            owner.canvas.stopRendering { stopped = true }
            expect(wait { stopped }, "canvas renderer stops")
            owner.window?.close()
            var closed = false
            document.closeImageWhenDrained { closed = true }
            expect(wait { closed && (try? session.info(image)) == nil }, "owned image closes")
            documents.items.removeAll { $0 === document }
        }
        try drain(document)
        NSApp.activate(ignoringOtherApps: true)
        owner.window?.makeMain(); owner.window?.makeKeyAndOrderFront(nil)
        try require(wait { NSApp.isActive && NSApp.mainWindow === owner.window }, "document window is not main")
        func command(_ action: RecorderPaletteAction) throws {
            controls.retarget(to: document)
            guard let item = controls.paletteMenu?.items.first(where: { $0.tag == action.rawValue }),
                  let selector = item.action else { throw NSError(domain: "RecorderSpongeUI", code: 2) }
            try require(controls.validateMenuItem(item) && NSApp.sendAction(selector, to: item.target, from: item),
                        "Recorder palette action was refused")
        }
        func pixels() throws -> Data { try session.copyPixels(image, merged: true).pixels }
        func pointer(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, time: TimeInterval) throws {
            guard let window = owner.window,
                  let event = NSEvent.mouseEvent(with: type,
                    location: owner.canvas.convert(CGPoint(x: x * owner.canvas.scale, y: y * owner.canvas.scale), to: nil),
                    modifierFlags: [], timestamp: time, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1), event.subtype != .tabletPoint else {
                throw NSError(domain: "RecorderSpongeUI", code: 3)
            }
            switch type {
            case .leftMouseDown: owner.canvas.mouseDown(with: event)
            case .leftMouseDragged: owner.canvas.mouseDragged(with: event)
            default: owner.canvas.mouseUp(with: event)
            }
        }
        let supported = ProcessInfo.processInfo.environment["GLIMS_EXPECT_SPONGE_CAPTURE"] == "1"
        let cases: [(ToolID, EngineSession.Brush.Tool, CGFloat)] = [
            (.spongeDesaturate, .spongeDesaturate, 7), (.spongeSaturate, .spongeSaturate, 27)
        ]
        for (tool, expectedTool, x) in cases {
            state.update(tool) { $0.size = 10; $0.opacity = 1; $0.hardness = 1; $0.pressureSize = false; $0.resource = nil }
            state.select(tool)
            let before = try pixels()
            try command(.record)
            expect(document.recorder.isRecording, "palette starts recording \(tool)")
            try pointer(.leftMouseDown, x: x, y: 9, time: 1)
            try pointer(.leftMouseDragged, x: x + 3, y: 10, time: 1.1)
            try pointer(.leftMouseUp, x: x + 5, y: 11, time: 1.2)
            try drain(document)
            try command(.stop)
            let after = try pixels()
            expect(before != after, "live \(tool) stroke changes the canvas")
            try require(document.recorder.records.count == 1, "stroke did not settle into one row")
            if supported {
                guard case .success(.completeStroke(let stroke)) = document.recorder.records[0].resolution else {
                    throw NSError(domain: "RecorderSpongeUI", code: 4,
                                  userInfo: [NSLocalizedDescriptionKey: "Sponge capture did not produce a stroke"])
                }
                expect(stroke.settings.brush.tool == expectedTool, "capture retains \(tool) direction")
                let metadata = document.recorderFileMetadata
                let file = try RecorderFileCodec.snapshot(document.recorder, recordingID: metadata.recordingID,
                    name: metadata.name, origin: metadata.origin, descriptions: document.recorderDescriptions,
                    bindings: document.recorderBindingDescriptions)
                let encoded = try RecorderFileCodec.encode(file)
                let json = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
                let decoded = try RecorderFileCodec.decode(encoded)
                expect(json?["version"] as? Int == 20 && decoded == file,
                       "Sponge file version and full recording round-trip")
                document.undo(); try drain(document)
                expect(try pixels() == before, "Undo restores pixels before \(tool)")
                try document.startReplay()
                try require(wait { document.replayStatus == .finished(total: 1) && document.pendingWork == 0 &&
                                   !EngineActivity.shared.isBusy }, "Sponge replay did not finish")
                expect(try pixels() == after, "replay of \(tool) restores the captured pixels")
            } else {
                guard case .failure = document.recorder.records[0].resolution else {
                    throw NSError(domain: "RecorderSpongeUI", code: 5,
                                  userInfo: [NSLocalizedDescriptionKey: "Older engine must report unsupported capture"])
                }
                expect(document.recorder.replayRefusal != nil, "older engine refuses incomplete Sponge recording")
                document.undo(); try drain(document)
                expect(try pixels() == before, "older-engine live stroke still undoes")
            }
        }
    }
}
