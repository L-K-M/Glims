import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseCanvasRotation(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 120, height: 80)
        let colors: [NSColor] = [.init(srgbRed: 1, green: 0, blue: 0, alpha: 1),
                                 .init(srgbRed: 0, green: 1, blue: 0, alpha: 1),
                                 .init(srgbRed: 0, green: 0, blue: 1, alpha: 1),
                                 .init(srgbRed: 1, green: 1, blue: 0, alpha: 1)]
        let points = [CGPoint(x: 30, y: 20), CGPoint(x: 90, y: 20),
                      CGPoint(x: 30, y: 60), CGPoint(x: 90, y: 60)]
        for i in 0..<4 {
            let rect = CGRect(x: i % 2 * 60, y: i / 2 * 40, width: 60, height: 40)
            try session.select(.rectangle(rect), image: image)
            try session.fill(image: image, at: points[i], mode: .selection, color: colors[i])
        }
        try session.select(.none, image: image)
        let before = try session.copyPixels(image, merged: true).pixels
        let infoBefore = try session.info(image)
        let undoBefore = try session.undoInfo(image)
        let doc = try ImageDocument(session: session, image: image, name: "View rotation")
        documents.items.append(doc)
        let controller = DocumentWindowController(document: doc)
        controller.showWindow(nil)
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        defer {
            controller.window?.orderOut(nil)
            var stopped = false
            controller.canvas.stopRendering { stopped = true }
            wait { stopped }
            var closed = false
            doc.closeImageWhenDrained { closed = true }
            wait { closed }
            documents.items.removeAll { $0 === doc }
            check((try? session.info(image)) == nil, "the rotation fixture drains and closes")
        }
        controller.zoom(to: 100)
        wait { controller.canvas.renderedTileCount > 0 }
        func pictureMatches() -> Bool {
            let host = controller.rotationView
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds), host.bounds.width > 0 else { return false }
            host.cacheDisplay(in: host.bounds, to: rep)
            let factor = CGFloat(rep.pixelsWide) / host.bounds.width
            for i in points.indices {
                let local = CGPoint(x: points[i].x * controller.canvas.scale,
                                    y: points[i].y * controller.canvas.scale)
                let point = host.convert(local, from: controller.canvas)
                guard let color = rep.colorAt(x: Int(point.x * factor), y: Int(point.y * factor))?.usingColorSpace(.sRGB) else { return false }
                // The cached display bitmap is calibrated, so exact sRGB
                // components are not a geometry oracle. Distinguish the
                // four known color regions after display conversion.
                let r = color.redComponent, g = color.greenComponent, b = color.blueComponent
                let matches: Bool
                switch i {
                case 0: matches = r > g + 0.4 && r > b + 0.4
                case 1: matches = g > r + 0.4 && g > b + 0.4
                case 2: matches = b > r + 0.4 && b > g + 0.4
                default: matches = r > b + 0.4 && g > b + 0.4
                }
                if !matches { return false }
            }
            return true
        }
        for angle in [0.0, 90, -45, 180] {
            check(controller.setViewRotation(degrees: angle), "view rotation accepts \(angle) degrees")
            wait { pictureMatches() }
            if !pictureMatches(), let path = ProcessInfo.processInfo.environment["GLIMS_ROTATION_DIAGNOSTICS"] {
                for (name, view) in [("host", controller.rotationView as NSView), ("canvas", controller.canvas as NSView)] {
                    if let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                        view.cacheDisplay(in: view.bounds, to: rep)
                        let file = URL(fileURLWithPath: path).appendingPathComponent("rotation-\(Int(angle))-\(name).png")
                        try? rep.representation(using: .png, properties: [:])?.write(to: file)
                        for point in points {
                            let local = CGPoint(x: point.x * controller.canvas.scale, y: point.y * controller.canvas.scale)
                            let sample = view.convert(local, from: controller.canvas)
                            let factor = CGFloat(rep.pixelsWide) / view.bounds.width
                            print("rotation sample \(angle) \(name) \(point) \(String(describing: rep.colorAt(x: Int(sample.x * factor), y: Int(sample.y * factor)))) native \(String(describing: pixel(session, image, x: Int(point.x), y: Int(point.y))))")
                        }
                    }
                }
            }
            check(pictureMatches(), "all four displayed quadrants follow the rotated view at \(angle)")
            check(controller.scrollView.rulersVisible && controller.horizontalRuler.currentPlan() != nil
                    && controller.verticalRuler.currentPlan() != nil,
                  "both projected pixel rulers remain available while rotated")
            if let window = controller.window {
                let local = CGPoint(x: 21 * controller.canvas.scale, y: 13 * controller.canvas.scale)
                let windowPoint = controller.canvas.convert(local, to: nil)
                if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: windowPoint, modifierFlags: [], timestamp: 0,
                                                  windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                  clickCount: 1, pressure: 1) {
                    let imagePoint = controller.canvas.imagePoint(for: event)
                    check(abs(imagePoint.x - 21) < 0.001 && abs(imagePoint.y - 13) < 0.001,
                          "the real canvas event maps to the intended image pixel at \(angle)")
                } else { check(false, "a rotated canvas event can be constructed") }
            }
            controller.fitImage(nil)
            let viewport = controller.scrollView.contentSize
            check(controller.rotationView.frame.width <= viewport.width + 1
                    && controller.rotationView.frame.height <= viewport.height + 1,
                  "Fit Image contains the rotated bounding box at \(angle)")
            let center = controller.canvasCenter
            controller.zoom(to: 150)
            let after = controller.canvasCenter
            check(abs(center.x - after.x) < 1 && abs(center.y - after.y) < 1,
                  "zoom preserves the image-space center while rotated")
            controller.zoom(to: 100)
        }
        let pixelsAfter = try session.copyPixels(image, merged: true).pixels
        let infoAfter = try session.info(image)
        let undoAfter = try session.undoInfo(image)
        check(pixelsAfter == before && infoAfter == infoBefore && undoAfter == undoBefore,
              "view rotation, ruler projection and navigation preserve native pixels, dirty state and history")
        let unchangedAngle = controller.rotationView.rotationDegrees
        check(!controller.setViewRotation(degrees: .nan) && controller.rotationView.rotationDegrees == unchangedAngle,
              "nonfinite view rotation refuses without changing state")

        let rotateMenu = MainMenu.make().items.first { $0.title == "View" }?.submenu?.items
            .first { $0.title == "Rotate View" }?.submenu
        check(rotateMenu?.items.map(\.action) == [#selector(DocumentWindowController.rotateViewClockwise(_:)),
              #selector(DocumentWindowController.rotateViewCounterclockwise(_:)),
              #selector(DocumentWindowController.setViewAngle(_:)), #selector(DocumentWindowController.resetViewRotation(_:))],
              "View offers clockwise, counterclockwise, custom and reset rotation")
        controller.resetViewRotation(nil)
        controller.rotateViewClockwise(nil)
        check(controller.rotationView.rotationDegrees == 15 && controller.window?.title.contains("View 15°") == true,
              "the menu action rotates clockwise and reports the angle in the window title")
        controller.rotateViewCounterclockwise(nil)
        check(controller.rotationView.rotationDegrees == 0 && controller.window?.title.contains(" · View ") == false,
              "counterclockwise restores the unrotated title")
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? []
                + view.subviews.flatMap { fields($0) }
        }
        controller.setViewAngle(nil)
        if let sheet = controller.window?.attachedSheet,
           let content = sheet.contentView,
           let field = fields(content).first(where: { $0.isEditable }) {
            field.stringValue = "nan"
            controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            wait { controller.window?.attachedSheet == nil }
            spin(0.05)
            check(controller.rotationView.rotationDegrees == 0 && controller.statusBar.message.contains("finite angle"),
                  "the actual angle form refuses nonfinite text with an actionable message")
        } else { check(false, "the angle sheet exposes an editable angle") }
        controller.setViewAngle(nil)
        if let sheet = controller.window?.attachedSheet,
           let content = sheet.contentView,
           let field = fields(content).first(where: { $0.isEditable }) {
            field.stringValue = "22.5"
            controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            wait { controller.rotationView.rotationDegrees == 22.5 }
            check(controller.rotationView.rotationDegrees == 22.5,
                  "the actual angle form applies fractional degrees")
        } else { check(false, "the angle sheet can reopen after invalid input") }

        let state = ToolState.shared
        let oldTool = state.current, oldForeground = state.foreground
        let oldBrush = state.brush(for: .pencil), oldSelection = state.selectOptions
        defer {
            state.foreground = oldForeground
            state.update(.pencil) { $0 = oldBrush }
            state.selectOptions = oldSelection
            state.select(oldTool)
        }
        state.foreground = .black
        state.selectOptions = EngineSession.SelectOptions()
        state.update(.pencil) { $0.size = 9; $0.opacity = 1; $0.pressureSize = false; $0.resource = nil }
        func settle() {
            doc.inputQueue.sync {}
            wait { doc.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin(0.02)
        }
        func gesture(from start: CGPoint, to end: CGPoint) -> Bool {
            guard let window = controller.window else { return false }
            func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type,
                    location: controller.canvas.convert(CGPoint(x: p.x * controller.canvas.scale, y: p.y * controller.canvas.scale), to: nil),
                    modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 0, clickCount: 1, pressure: 1)
            }
            guard let down = event(.leftMouseDown, start), let drag = event(.leftMouseDragged, end),
                  let up = event(.leftMouseUp, end) else { return false }
            controller.canvas.mouseDown(with: down)
            controller.canvas.mouseDragged(with: drag)
            controller.canvas.mouseUp(with: up)
            settle()
            return true
        }
        for angle in [90.0, -45, 180] {
            controller.setViewRotation(degrees: angle)
            state.select(.rectangleSelect)
            let selected = gesture(from: CGPoint(x: 12, y: 14), to: CGPoint(x: 42, y: 38))
            let selection = try session.selectionBounds(image: image)
            check(selected && selection == CGRect(x: 12, y: 14, width: 30, height: 24),
                  "the actual rotated rectangle gesture selects the intended image bounds at \(angle): \(String(describing: selection))")
            doc.select(.none)
            settle()
            let beforePaint = try session.copyPixels(image, merged: true).pixels
            state.select(.pencil)
            let painted = gesture(from: CGPoint(x: 20, y: 20), to: CGPoint(x: 40, y: 20))
            let sample = pixel(session, image, x: 30, y: 20)
            let isBlack = sample.map { $0.count == 4 && $0.prefix(3).allSatisfy { $0 < 26 } } ?? false
            check(painted && isBlack,
                  "the actual rotated pencil gesture paints the intended native pixel at \(angle)")
            doc.undo()
            settle()
            check(try session.copyPixels(image, merged: true).pixels == beforePaint,
                  "one Undo restores the complete rotated stroke at \(angle)")
        }
    }
}
