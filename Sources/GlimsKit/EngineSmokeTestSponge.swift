import AppKit

@MainActor
extension EngineSmokeTest {
    /// Sponge tool fixture: real document/canvas/options behavior, no direct engine paint calls.
    static func runSpongeTools(session: EngineSession, documents: DocumentList) throws {
        func expect(_ condition: Bool, _ message: String) { check(condition, "sponge: \(message)") }
        func wait(_ condition: () -> Bool, seconds: TimeInterval = 15) -> Bool {
            let limit = Date().addingTimeInterval(seconds)
            while !condition() && Date() < limit { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }
        func drain(_ document: ImageDocument) {
            expect(wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "accepted canvas work drains")
            spin(0.02)
        }
        func pixel(_ x: Int, _ y: Int) -> [UInt8]? { EngineSmokeTest.pixel(session, image, x: x, y: y) }
        func chroma(_ px: [UInt8]) -> Int { Int(px.prefix(3).max() ?? 0) - Int(px.prefix(3).min() ?? 0) }

        let state = ToolState.shared
        let oldTool = state.current
        let oldForeground = state.foreground
        let oldDesat = state.brush(for: .spongeDesaturate)
        let oldSat = state.brush(for: .spongeSaturate)
        defer {
            state.update(.spongeDesaturate) { $0 = oldDesat }
            state.update(.spongeSaturate) { $0 = oldSat }
            state.foreground = oldForeground
            state.select(oldTool)
        }

        let w = 40, h = 24
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        func paintRect(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int, _ rgba: [UInt8]) {
            for y in y0..<y1 { for x in x0..<x1 { let i = (y * w + x) * 4; bytes[i..<i + 4] = rgba[0...3] } }
        }
        // Independently authored fixture pixels (not derived from sponge output).
        paintRect(0, 0, w, h, [245, 245, 245, 255])             // base
        paintRect(4, 4, 14, 14, [210, 60, 60, 255])             // saturated red for desaturate
        paintRect(18, 4, 28, 14, [160, 120, 120, 255])          // muted red for saturate
        paintRect(4, 15, 14, 21, [128, 128, 128, 255])          // neutral gray stability
        paintRect(18, 15, 28, 21, [60, 190, 70, 140])           // semi-transparent colored, alpha preserved

        let image = try session.newImage(pixels: .init(width: w, height: h, pixels: Data(bytes), origin: .zero))
        let document = try ImageDocument(session: session, image: image, name: "Sponge")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.zoom(to: 600)
        drain(document)
        let options = ToolOptionsPaletteController()
        options.retarget(to: document)
        let optionsWindow = NSWindow(contentRect: NSRect(x: 60, y: 100, width: 330, height: 380),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        optionsWindow.isReleasedWhenClosed = false
        optionsWindow.contentView = options.view
        optionsWindow.orderFront(nil)
        defer {
            options.retarget(to: nil)
            optionsWindow.close()
            controller.window?.orderOut(nil)
            var stopped = false
            controller.canvas.stopRendering { stopped = true }
            expect(wait { stopped }, "owned canvas renderer stops")
            controller.window?.close()
            var closed = false
            document.closeImageWhenDrained { closed = true }
            expect(wait { closed && (try? session.info(image)) == nil }, "owned image closes")
            documents.items.removeAll { $0 === document }
        }
        func pixels() throws -> Data { try session.copyPixels(image, merged: true).pixels }
        func views(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(views) }
        func setOption(_ label: String, _ value: Double) throws {
            optionsWindow.makeFirstResponder(nil)
            guard let field = views(options.view).compactMap({ $0 as? NSTextField }).first(where: {
                $0.isEditable && $0.accessibilityLabel() == label + " value"
            }), let action = field.action else { throw NSError(domain: "SpongeSmoke", code: 3) }
            field.doubleValue = value
            expect(field.sendAction(action, to: field.target), "actual " + label + " field action fires")
            EngineSmokeTestHost.pumpEvents()
        }

        func pointer(_ type: NSEvent.EventType, at p: CGPoint) throws {
            let canvas = controller.canvas
            guard let window = controller.window,
                  let event = NSEvent.mouseEvent(with: type,
                    location: canvas.convert(CGPoint(x: p.x * canvas.scale, y: p.y * canvas.scale), to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
                  event.subtype != .tabletPoint else { throw NSError(domain: "SpongeSmoke", code: 1) }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            default: canvas.mouseUp(with: event)
            }
        }
        func stroke(from a: CGPoint, to b: CGPoint) throws {
            try pointer(.leftMouseDown, at: a)
            for i in 1...6 {
                let t = CGFloat(i) / 6
                try pointer(.leftMouseDragged, at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
            }
            try pointer(.leftMouseUp, at: b)
            drain(document)
        }

        // Select both Sponge tools through menu state and show actual options.
        let owner = AppController()
        let desatItem = NSMenuItem(title: "Sponge Desaturate", action: #selector(AppController.selectToolFromMenu(_:)), keyEquivalent: "")
        desatItem.tag = ToolMenuCatalog.tag(for: .spongeDesaturate)
        desatItem.identifier = MenuShortcutBridge.builtinIdentifier
        let satItem = NSMenuItem(title: "Sponge Saturate", action: #selector(AppController.selectToolFromMenu(_:)), keyEquivalent: "")
        satItem.tag = ToolMenuCatalog.tag(for: .spongeSaturate)
        satItem.identifier = MenuShortcutBridge.builtinIdentifier
        owner.selectToolFromMenu(desatItem)
        expect(state.current == .spongeDesaturate, "menu selects Sponge Desaturate")
        _ = options.view; options.retarget(to: document)
        spin(0.02)
        let hasSpongeHint = views(options.view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("Changes saturation on RGB pixels") }
        expect(hasSpongeHint, "actual options show sponge behavior hint")

        // Desaturate: verify size/opacity reach stroke behavior and direction/alpha.
        state.update(.spongeDesaturate) { $0.pressureSize = false; $0.hardness = 1 }
        try setOption("Size", 14); try setOption("Opacity", 100)
        let redBefore = try XCTPixel(pixel(8, 8), "desaturate source present")
        let allBefore = try pixels()
        let outsideBefore = try XCTPixel(pixel(35, 5), "outside source")
        let undoBefore = document.undoInfo.undoCount
        try stroke(from: CGPoint(x: 6, y: 6), to: CGPoint(x: 12, y: 12))
        let redAfter = try XCTPixel(pixel(8, 8), "desaturate pixel readable")
        let allAfter = try pixels()
        expect(try XCTPixel(pixel(35, 5), "outside after") == outsideBefore, "distant pixels remain unchanged")
        expect(chroma(redAfter) < chroma(redBefore) - 8, "Saturate/Desaturate direction: desaturate lowers chroma")
        expect(redAfter[3] == redBefore[3], "desaturate preserves alpha exactly")
        expect(document.undoInfo.undoCount == undoBefore + 1, "desaturate stroke is one undo step")
        document.undo(); drain(document)
        expect(try pixels() == allBefore, "Undo restores exact pre-desaturate pixels")
        document.redo(); drain(document)
        expect(try pixels() == allAfter, "Redo restores exact desaturated pixels")

        // Neutral gray stability.
        let grayBefore = try XCTPixel(pixel(8, 18), "gray source")
        try stroke(from: CGPoint(x: 6, y: 17), to: CGPoint(x: 12, y: 19))
        let grayAfter = try XCTPixel(pixel(8, 18), "gray after")
        expect(abs(Int(grayAfter[0]) - Int(grayBefore[0])) <= 2 && abs(Int(grayAfter[1]) - Int(grayBefore[1])) <= 2
               && abs(Int(grayAfter[2]) - Int(grayBefore[2])) <= 2 && grayAfter[3] == grayBefore[3],
               "neutral gray remains stable with exact alpha")

        // Saturate: menu/state selection, different size/opacity affect stroke, alpha preserved.
        owner.selectToolFromMenu(satItem)
        expect(state.current == .spongeSaturate, "menu selects Sponge Saturate")
        let mutedBefore = try XCTPixel(pixel(22, 8), "muted source")
        let alphaBefore = try XCTPixel(pixel(22, 18), "alpha source")
        state.update(.spongeSaturate) { $0.pressureSize = false; $0.hardness = 1 }
        try setOption("Size", 2); try setOption("Opacity", 15)
        try stroke(from: CGPoint(x: 22, y: 8), to: CGPoint(x: 22, y: 8))
        let smallWeak = try XCTPixel(pixel(22, 8), "small weak saturate")
        try setOption("Size", 14); try setOption("Opacity", 100)
        try stroke(from: CGPoint(x: 20, y: 6), to: CGPoint(x: 26, y: 12))
        let largeStrong = try XCTPixel(pixel(22, 8), "large strong saturate")
        expect(chroma(smallWeak) >= chroma(mutedBefore) - 1, "saturate does not desaturate muted color")
        expect(chroma(largeStrong) > chroma(smallWeak) + 4, "options size/opacity reach actual stroke behavior")
        expect(largeStrong[3] == mutedBefore[3], "saturate preserves opaque alpha exactly")
        try stroke(from: CGPoint(x: 20, y: 17), to: CGPoint(x: 26, y: 19))
        let alphaAfter = try XCTPixel(pixel(22, 18), "alpha after")
        expect(alphaAfter[3] == alphaBefore[3], "semi-transparent pixel keeps exact alpha")
        expect(chroma(alphaAfter) >= chroma(alphaBefore), "saturate acts on semi-transparent RGB")

        let neutralBefore = try XCTPixel(pixel(8, 18), "neutral before Saturate")
        try stroke(from: CGPoint(x: 6, y: 17), to: CGPoint(x: 12, y: 19))
        expect(try XCTPixel(pixel(8, 18), "neutral after Saturate") == neutralBefore,
               "Saturate never tints neutral gray")
        print("     sponge checks: completed")
    }

    private static func XCTPixel(_ value: [UInt8]?, _ message: String) throws -> [UInt8] {
        guard let value else { throw NSError(domain: "SpongeSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
        return value
    }
}

