import AppKit
import RigiUI

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
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func newImageSettings(_ component: EngineSession.ColorComponent) throws -> NewImageSettings {
            let panel = NewImagePanel()
            defer { panel.close() }
            panel.showWindow(nil)
            panel.window?.makeKeyAndOrderFront(nil)
            guard let content = panel.window?.contentView else { throw NSError(domain: "MultichannelSmoke", code: 4) }
            let views = descendants(content)
            guard let mode = views.first(where: { $0.accessibilityLabel() == "Image mode" }) as? NSPopUpButton,
                  let precision = views.first(where: { $0.accessibilityLabel() == "Precision" }) as? NSPopUpButton,
                  let width = views.first(where: { $0.accessibilityLabel() == "Width in pixels" }) as? NSTextField,
                  let height = views.first(where: { $0.accessibilityLabel() == "Height in pixels" }) as? NSTextField,
                  let channels = views.first(where: { $0.accessibilityLabel() == "Ink channels" }) as? NSTextField,
                  let create = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Create" })
            else { throw NSError(domain: "MultichannelSmoke", code: 5) }
            expect(!precision.isEnabled && !channels.isEnabled, "RGB New Image leaves ink controls inactive")
            mode.selectItem(withTitle: "Multichannel")
            _ = mode.sendAction(mode.action, to: mode.target)
            expect(precision.isEnabled && channels.isEnabled, "choosing Multichannel enables precision and ink count")
            precision.selectItem(at: NewImageSettings.multichannelComponents.firstIndex(of: component)!)
            width.stringValue = "32"; height.stringValue = "24"; channels.stringValue = "0"
            panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: channels))
            expect(!create.isEnabled, "New Image refuses zero ink channels")
            channels.stringValue = "4"
            panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: channels))
            expect(create.isEnabled, "New Image accepts valid ink settings")
            if component == .u8, let path = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"],
               let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.layoutSubtreeIfNeeded(); content.cacheDisplay(in: content.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: path).appendingPathComponent("multichannel-new-image.png"))
            }
            var result: NewImageSettings?
            panel.onCreate = { result = $0 }
            create.performClick(nil)
            guard let result else { throw NSError(domain: "MultichannelSmoke", code: 6) }
            expect(result.kind == .multichannel && result.component == component && result.channelCount == 4,
                   "Create sends the selected ink mode and precision")
            return result
        }
        let state = ToolState.shared, oldTool = ToolState.shared.current
        let oldForeground = state.foreground, oldBrush = state.brush(for: .pencil)
        defer { state.update(.pencil) { $0 = oldBrush }; state.foreground = oldForeground; state.select(oldTool) }
        state.select(.pencil); state.foreground = .black
        state.update(.pencil) { $0.size = 7; $0.opacity = 1; $0.hardness = 1; $0.pressureSize = false }
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let settings = try newImageSettings(component)
            let image = try session.newMultichannelImage(width: settings.width, height: settings.height,
                                                        component: settings.component, channelCount: settings.channelCount)
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
            let tools = ToolsPaletteController(); _ = tools.view; tools.retarget(to: document)
            defer { tools.retarget(to: nil) }
            let grid = descendants(tools.view).compactMap { $0 as? ClassicToolGrid }.first
            expect(grid?.slots.map { $0.tools.map(\.id) } == ToolID.paletteSlots.map { $0.map(\.rawValue) },
                   "ink mode preserves every tool slot and group")
            expect(grid?.slots.flatMap(\.tools).allSatisfy { item in
                guard let tool = ToolID(rawValue: item.id) else { return false }
                return item.isEnabled == tool.isAvailable(in: .multichannel)
            } == true, "actual tool grid disables unavailable operations")
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
            func visibleCanvasPixel(x: Int, y: Int) -> [UInt8]? {
                let canvas = controller.canvas
                guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
                canvas.cacheDisplay(in: canvas.bounds, to: rep)
                let factor = Double(rep.pixelsWide) / Double(canvas.bounds.width)
                // colorAt returns NSCalibratedRGB on this AppKit even when
                // the captured bitmap is tagged sRGB. Convert the tagged
                // CGImage directly, avoiding that generic-RGB reinterpretation.
                guard let image = rep.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: nil, width: image.width, height: image.height,
                        bitsPerComponent: 8, bytesPerRow: image.width * 4, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                let px = Int((Double(x) + 0.5) * canvas.scale * factor)
                let py = Int((Double(y) + 0.5) * canvas.scale * factor)
                guard px >= 0, py >= 0, px < image.width, py < image.height,
                      let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
                return Array(UnsafeBufferPointer(start: bytes + (py * image.width + px) * 4, count: 4))
            }
            let displayed = wait {
                guard let cyan = visibleCanvasPixel(x: 8, y: 8), let magenta = visibleCanvasPixel(x: 23, y: 8) else { return false }
                return cyan[0] < 38 && cyan[1] > 217 && cyan[2] > 217 && cyan[3] == 255 &&
                    magenta[0] > 217 && magenta[1] < 38 && magenta[2] > 217 && magenta[3] == 255
            }
            expect(displayed, "the actual canvas displays both painted inks")
            if !displayed {
                print("CANVAS bounds=\(controller.canvas.bounds) scale=\(controller.canvas.scale) cyan=\(String(describing: visibleCanvasPixel(x: 8, y: 8))) magenta=\(String(describing: visibleCanvasPixel(x: 23, y: 8)))")
            }
            if component == .u8, let path = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"],
               let view = controller.window?.contentView,
               let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: path).appendingPathComponent("multichannel-window.png"))
                let canvas = controller.canvas
                if let canvasRep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
                    canvas.cacheDisplay(in: canvas.bounds, to: canvasRep)
                    try canvasRep.representation(using: .png, properties: [:])?.write(to:
                        URL(fileURLWithPath: path).appendingPathComponent("multichannel-canvas.png"))
                }
            }
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
