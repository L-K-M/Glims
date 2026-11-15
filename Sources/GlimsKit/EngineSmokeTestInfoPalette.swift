import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseInfoPalette(_ session: EngineSession, documents: DocumentList) throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            check(value, "info palette: \(message)")
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            return condition()
        }
        func labels(_ root: NSView) -> [String] {
            ((root as? NSTextField).map { [$0.stringValue] } ?? []) + root.subviews.flatMap(labels)
        }
        let bytes: [UInt8] = [255, 0, 0, 255, 0, 255, 0, 255,
                              0, 0, 255, 128, 255, 255, 255, 255]
        let pixels = ClipboardImage(width: 2, height: 2, pixels: Data(bytes), origin: .zero)
        let image = try session.newImage(pixels: pixels)
        let document = try ImageDocument(session: session, image: image, name: "Info Fixture")
        let otherImage = try session.newImage(pixels: pixels)
        let otherDocument = try ImageDocument(session: session, image: otherImage, name: "Other Info Fixture")
        documents.items += [document, otherDocument]
        let owner = DocumentWindowController(document: document)
        let palette = InfoPaletteController()
        let host = NSPanel(contentRect: NSRect(origin: .zero, size: InfoPaletteController.definition.contentSize),
                           styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        let originalPointer = CGEvent(source: nil)?.location
        host.contentViewController = palette
        host.setContentSize(InfoPaletteController.definition.contentSize)
        palette.retarget(to: document)
        owner.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        owner.window?.makeKeyAndOrderFront(nil)
        owner.window?.makeMain()
        host.orderFront(nil)
        host.contentView?.layoutSubtreeIfNeeded()
        defer {
            palette.retarget(to: nil)
            host.orderOut(nil); host.close()
            owner.previewPanel?.cancel()
            owner.window?.orderOut(nil)
            var stopped = false
            owner.canvas.stopRendering { stopped = true }
            _ = wait { stopped }
            if !owner.closeStarted { owner.window?.close() }
            otherDocument.closeImageWhenDrained()
            _ = wait { document.pendingWork == 0 && otherDocument.pendingWork == 0 &&
                (try? session.info(image)) == nil && (try? session.info(otherImage)) == nil }
            documents.items.removeAll { $0 === document || $0 === otherDocument }
            if let originalPointer { CGWarpMouseCursorPosition(originalPointer) }
            print("     info-palette checks: \(checks)")
        }
        guard let window = owner.window else { return expect(false, "fixture has a document window") }
        expect(wait { window.isMainWindow }, "the fixture document is the main window")
        expect(window.acceptsMouseMovedEvents, "the document window admits pointer movement")
        expect(owner.canvas.trackingAreas.contains { $0.options.contains(.mouseMoved) && $0.options.contains(.inVisibleRect) },
               "the canvas installs a visible-region movement tracking area")
        let beforeColor = ToolState.shared.foreground
        let beforeUndo = try session.undoInfo(image)
        owner.zoom(to: 800)
        EngineSmokeTestHost.pumpEvents(for: 0.05)
        func placePointer(x: Double, y: Double) -> CGPoint {
            let point = CGPoint(x: x * owner.canvas.scale, y: y * owner.canvas.scale)
            let location = owner.canvas.convert(point, to: nil)
            let screenPoint = window.convertPoint(toScreen: location)
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
            CGWarpMouseCursorPosition(CGPoint(x: screenPoint.x, y: primaryTop - screenPoint.y))
            EngineSmokeTestHost.pumpEvents(for: 0.05)
            return location
        }
        let location = placePointer(x: 1.5, y: 0.5)
        NotificationCenter.default.post(name: .glimsCanvasPointerChanged, object: document)
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: location, modifierFlags: [], timestamp: 0,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                          clickCount: 0, pressure: 0) {
            owner.canvas.mouseMoved(with: event)
            expect(wait { labels(palette.view).contains("X: 1    Y: 0") }, "a real canvas event shows its image coordinates")
            expect(wait { labels(palette.view).contains { $0.hasPrefix("sRGB: R ") } },
                   "the visible palette samples the composite asynchronously")
            expect(labels(palette.view).contains("sRGB: R 0.0%  G 100.0%  B 0.0%"),
                   "the sampled RGB values match the green fixture pixel")
        } else { expect(false, "a pointer event can be constructed") }
        let dispatchPoint = placePointer(x: 0.5, y: 0.5)
        NotificationCenter.default.post(name: .glimsCanvasPointerChanged, object: document)
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: dispatchPoint,
                                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 2, clickCount: 0, pressure: 0) {
            NSApp.sendEvent(event)
            expect(wait { labels(palette.view).contains("X: 0    Y: 0") },
                   "AppKit dispatches a movement event to the canvas")
        } else { expect(false, "a dispatchable pointer event can be constructed") }
        expect(owner.setViewRotation(degrees: 45), "the fixture can rotate its view")
        let rotatedPoint = placePointer(x: 0.5, y: 1.5)
        NotificationCenter.default.post(name: .glimsCanvasPointerChanged, object: document)
        if let event = NSEvent.mouseEvent(with: .mouseMoved, location: rotatedPoint,
                                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 1, clickCount: 0, pressure: 0) {
            owner.canvas.mouseMoved(with: event)
            expect(wait { labels(palette.view).contains("X: 0    Y: 1") },
                   "pointer coordinates follow the rotated canvas")
            expect(wait { labels(palette.view).contains("Alpha: 50.2%") },
                   "the readout retains the sampled composite alpha")
        } else { expect(false, "a rotated pointer event can be constructed") }
        let afterUndo = try session.undoInfo(image)
        expect(ToolState.shared.foreground == beforeColor && afterUndo == beforeUndo,
               "hover does not change the tool color or image history")
        NotificationCenter.default.post(name: .glimsCanvasPointerChanged, object: document,
                                        userInfo: ["position": InfoPointerSampling.Position(x: 1, y: 0)])
        palette.retarget(to: otherDocument)
        EngineSmokeTestHost.pumpEvents(for: 0.15)
        expect(labels(palette.view).contains("X: —    Y: —") && labels(palette.view).contains("sRGB: —"),
               "retargeting discards the previous document's pending sample")
        palette.retarget(to: document)
        NotificationCenter.default.post(name: .glimsCanvasPointerChanged, object: document)
        expect(labels(palette.view).contains("X: —    Y: —"), "leaving clears the pointer readout")
        NotificationCenter.default.post(name: .glimsCanvasPointerChanged, object: document,
                                        userInfo: ["position": InfoPointerSampling.Position(x: 0, y: 0)])
        host.orderOut(nil)
        _ = wait { !host.isVisible }
        EngineSmokeTestHost.pumpEvents(for: 0.15)
        expect(labels(palette.view).contains("X: —    Y: —"),
               "hiding the palette clears the pointer and cancels pending display")
        expect(NSApp.mainMenu?.item(withTitle: "Window")?.submenu?.item(withTitle: "Info")?.action == #selector(AppController.showInfo(_:)),
               "the Window menu can show Info")
    }
}
