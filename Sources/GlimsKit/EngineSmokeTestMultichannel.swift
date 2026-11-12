import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseMultichannel(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "multichannel: \(message)") }
        func wait(_ condition: () -> Bool) -> Bool {
            let limit = Date().addingTimeInterval(15)
            while !condition() && Date() < limit { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "MultichannelSmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func drain(_ document: ImageDocument) throws {
            try require(wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Image work did not drain")
            EngineSmokeTestHost.pumpEvents()
        }
        let state = ToolState.shared, oldTool = ToolState.shared.current
        let oldForeground = state.foreground, oldBrush = state.brush(for: .pencil)
        defer { state.update(.pencil) { $0 = oldBrush }; state.foreground = oldForeground; state.select(oldTool) }
        state.select(.pencil); state.foreground = .black
        state.update(.pencil) { $0.size = 7; $0.opacity = 1; $0.hardness = 1; $0.pressureSize = false }
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let image = try session.newMultichannelImage(width: 32, height: 24, component: component, channelCount: 4)
            var controllers: [DocumentWindowController] = []
            var nativeOnly: [Int32] = [image]
            defer {
                for controller in controllers {
                    if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet, returnCode: .abort) }
                    if !controller.closeStarted { controller.closeDiscardingChanges() }
                }
                expect(wait { controllers.allSatisfy { (try? session.info($0.imageDocument.image)) == nil } }, "owned windows drain and close")
                documents.items.removeAll { candidate in controllers.contains { $0.imageDocument === candidate } }
                nativeOnly.forEach { try? session.closeImage($0) }
            }
            func attach(_ id: Int32, name: String) throws -> DocumentWindowController {
                let document = try ImageDocument(session: session, image: id, name: name)
                let controller = DocumentWindowController(document: document)
                controllers.append(controller); nativeOnly.removeAll { $0 == id }; documents.items.append(document)
                controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil); controller.zoom(to: 600)
                try drain(document)
                return controller
            }
            let controller = try attach(image, name: "Ink \(component.title)"), document = controller.imageDocument
            let palette = ChannelsPaletteController(); palette.retarget(to: document)
            defer { palette.retarget(to: nil) }
            expect(document.colorInfo.mode == .multichannel && document.colorInfo.component == component,
                   "document identifies actual mode and precision")
            expect(document.components?.mode == .multichannel && document.layers.isEmpty && document.channels.count == 4,
                   "document exposes real ink channels and no RGB proxy layer")
            try require(document.channels.count == 4, "Missing ink channels")
            expect(document.activeDrawable == document.channels[0].id, "first ink is the initial painting target")
            func pixels(_ id: Int32) throws -> Data {
                let rendered = try session.render(id, scale: 1, area: CGRect(x: 0, y: 0, width: 32, height: 24))
                guard let data = rendered.dataProvider?.data as Data? else { throw NSError(domain: "MultichannelSmoke", code: 2) }
                return data
            }
            func pointer(_ type: NSEvent.EventType, x: CGFloat, y: CGFloat, flags: NSEvent.ModifierFlags = []) throws {
                let canvas = controller.canvas
                guard let window = controller.window,
                      let event = NSEvent.mouseEvent(with: type,
                        location: canvas.convert(CGPoint(x: x * canvas.scale, y: y * canvas.scale), to: nil),
                        modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                else { throw NSError(domain: "MultichannelSmoke", code: 3) }
                if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
            }
            let before = try pixels(image), undoBefore = document.undoInfo.undoCount
            try pointer(.leftMouseDown, x: 8.5, y: 8.5); try pointer(.leftMouseUp, x: 8.5, y: 8.5)
            try drain(document)
            let after = try pixels(image)
            expect(pixel(session, image, x: 8, y: 8) == [0, 255, 255, 255], "canvas Pencil deposits cyan ink")
            expect(pixel(session, image, x: 30, y: 22) == [255, 255, 255, 255], "distant paper remains unchanged")
            expect(document.undoInfo.undoCount == undoBefore + 1, "canvas stroke contributes one Undo step")
            document.undo(); try drain(document); expect(try pixels(image) == before, "Undo restores the complete display exactly")
            document.redo(); try drain(document); expect(try pixels(image) == after, "Redo restores the complete display exactly")
            palette.perform(.selectChannel(document.channels[1].id)); try drain(document)
            expect(document.activeDrawable == document.channels[1].id, "palette pick changes the actual ink target")
            try pointer(.leftMouseDown, x: 23.5, y: 8.5); try pointer(.leftMouseUp, x: 23.5, y: 8.5)
            try drain(document)
            expect(pixel(session, image, x: 23, y: 8) == [255, 0, 255, 255], "second ink paints magenta independently")
            let finalPixels = try pixels(image), finalUndo = document.undoInfo.undoCount
            palette.perform(.newChannel); palette.perform(.setQuickMask(true)); palette.perform(.returnToLayers)
            try pointer(.leftMouseDown, x: 8.5, y: 8.5, flags: .command)
            try pointer(.leftMouseUp, x: 8.5, y: 8.5, flags: .command)
            try drain(document)
            expect(try pixels(image) == finalPixels && document.undoInfo.undoCount == finalUndo,
                   "unsupported palette and temporary Move actions cannot mutate ink")
            let export = NSMenuItem(title: "Export", action: #selector(DocumentWindowController.exportDocument(_:)), keyEquivalent: "")
            let save = NSMenuItem(title: "Save", action: #selector(DocumentWindowController.saveDocument(_:)), keyEquivalent: "")
            expect(!controller.validateMenuItem(export) && controller.validateMenuItem(save), "menu offers XCF Save and gates unsupported export")
            let path = work.appendingPathComponent("ink-\(component.rawValue).xcf")
            try session.save(image, to: path.path)
            let reopened = try session.openImage(path: path.path); nativeOnly.append(reopened)
            let reopenedController = try attach(reopened, name: "Reopened Ink")
            expect(reopenedController.imageDocument.colorInfo.mode == .multichannel &&
                   reopenedController.imageDocument.colorInfo.component == component &&
                   reopenedController.imageDocument.channels.map(\.name) == document.channels.map(\.name),
                   "reopened document preserves ink model and names")
            expect(try pixels(reopened) == finalPixels, "XCF reopening preserves exact displayed ink values")
        }
    }
}
