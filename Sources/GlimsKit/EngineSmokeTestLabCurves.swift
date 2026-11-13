import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseLabCurves(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "lab-curves: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            if !value { throw NSError(domain: "LabCurvesSmoke", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool, _ message: String) throws {
            let deadline = Date().addingTimeInterval(30)
            repeat {
                EngineSmokeTestHost.pumpEvents(for: 0.01)
                if condition() {
                    EngineSmokeTestHost.pumpEvents(for: 0.01)
                    if condition() { return }
                }
            } while Date() < deadline
            try require(false, message)
        }
        func drain(_ document: ImageDocument) throws {
            try wait({ document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Owned work drains")
        }
        func render(_ image: Int32) throws -> Data {
            let pixels = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 32, height: 24))
            guard let bytes = pixels.dataProvider?.data as Data? else {
                throw NSError(domain: "LabCurvesSmoke", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "No rendered pixels"])
            }
            return bytes
        }
        func centerPixel(_ image: CGImage) throws -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            let made = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: buffer.baseAddress, width: 1, height: 1,
                                              bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                return true
            }
            try require(made, "Preview pixels can be normalized")
            return bytes
        }
        func menuItem(_ name: String, in menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if (item.representedObject as? NativeFilterCommand)?.operation.name == name { return item }
                if let child = item.submenu, let found = menuItem(name, in: child) { return found }
            }
            return nil
        }
        func ready(_ controller: DocumentWindowController) throws {
            try wait({ controller.labCurvesPanel?.applyButton.isEnabled == true &&
                       controller.canvas.labCurvesPreviewIsCurrent &&
                       controller.imageDocument.pendingWork == 0 && !EngineActivity.shared.isBusy },
                     "Curves panel and latest canvas preview become current")
        }
        func drawHalf(_ panel: InkCurvesPanel) throws {
            guard let window = panel.window else { return try require(false, "Missing Curves window") }
            window.makeKeyAndOrderFront(nil)
            window.contentView?.layoutSubtreeIfNeeded()
            let graph = panel.graph
            let plot = graph.bounds.insetBy(dx: 12, dy: 12)
            try require(plot.width > 10 && plot.height > 10, "Actual graph has usable bounds")
            for (type, x) in [(NSEvent.EventType.leftMouseDown, plot.minX), (.leftMouseDragged, plot.maxX), (.leftMouseUp, plot.maxX)] {
                let point = graph.convert(NSPoint(x: x, y: plot.midY), to: nil)
                guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                    return try require(false, "Cannot construct bounded graph input")
                }
                switch type {
                case .leftMouseDown: graph.mouseDown(with: event)
                case .leftMouseDragged: graph.mouseDragged(with: event)
                default: graph.mouseUp(with: event)
                }
            }
            expect(graph.state.kind == .free && graph.state.samples.allSatisfy { $0 == 0.5 },
                   "a real freehand drag edits all 256 actual samples")
        }
        func capturePanel(_ panel: InkCurvesPanel, name: String = "lab-curves-u8.png") throws {
            guard let folder = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"],
                  let content = panel.window?.contentView?.superview else { return }
            content.layoutSubtreeIfNeeded(); content.displayIfNeeded()
            guard let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
                return try require(false, "No panel capture")
            }
            content.cacheDisplay(in: content.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else {
                return try require(false, "No PNG panel capture")
            }
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name))
        }
        func draft(_ panel: InkCurvesPanel, field: NSTextField, text: String,
                   publish: Bool = true) throws -> NSTextView {
            panel.window?.makeKeyAndOrderFront(nil)
            panel.window?.makeFirstResponder(field)
            field.selectText(nil)
            try wait({ field.currentEditor() is NSTextView }, "Numeric field editor becomes active")
            let editor = field.currentEditor() as! NSTextView
            editor.string = text
            field.stringValue = text
            if publish {
                panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
            }
            return editor
        }
        func geometry(_ panel: InkCurvesPanel) throws {
            guard let window = panel.window, let content = window.contentView else {
                return try require(false, "Missing visible panel")
            }
            content.layoutSubtreeIfNeeded()
            expect(window.isVisible, "actual Curves panel is visible")
            for control in [panel.graph, panel.sampleIndexField, panel.outputField,
                            panel.inputField, panel.modePopup, panel.pointTypePopup,
                            panel.resetButton, panel.applyButton, panel.cancelButton] as [NSView] {
                let rect = control.convert(control.bounds, to: content)
                expect(!control.isHiddenOrHasHiddenAncestor && rect.width > 0 && rect.height > 0 &&
                       rect.minX >= -1 && rect.minY >= -1 && rect.maxX <= content.bounds.maxX + 1 &&
                       rect.maxY <= content.bounds.maxY + 1, "\(control.accessibilityLabel() ?? "control") fits the panel")
            }
        }

        func choose(_ popup: NSPopUpButton, _ index: Int) {
            popup.selectItem(at: index)
            NSApp.sendAction(popup.action!, to: popup.target, from: popup)
        }
        func press(_ panel: InkCurvesPanel, _ code: UInt16) throws {
            guard let window = panel.window else { return try require(false, "Missing Smooth window") }
            window.makeFirstResponder(panel.graph)
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code) else {
                return try require(false, "Missing Smooth key event")
            }
            panel.graph.keyDown(with: event)
        }
        var controllers: [DocumentWindowController] = []
        var nativeOnly: [Int32] = []
        var errors: [String] = []
        defer {
            for controller in controllers {
                controller.labCurvesPanel?.cancel()
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .abort)
                }
                if !controller.closeStarted { controller.closeDiscardingChanges() }
            }
            let owned = controllers.map(\.imageDocument)
            do {
                try wait({ owned.allSatisfy { $0.pendingWork == 0 && (try? session.info($0.image)) == nil }
                           && !EngineActivity.shared.isBusy }, "Owned Lab Curves images close")
            } catch { expect(false, "cleanup: \(error)") }
            for image in nativeOnly {
                do { try session.closeImage(image) } catch { expect(false, "native cleanup: \(error)") }
            }
            expect(controllers.allSatisfy { $0.labCurvesPanel == nil && $0.window?.attachedSheet == nil },
                   "cleanup leaves no owned panel or sheet")
            expect(errors.isEmpty, "no unexpected document errors: \(errors)")
            documents.items.removeAll { candidate in owned.contains { candidate === $0 } }
        }
        try require(session.supportsLabCurveSnapshots, "Producer supports Lab Curves snapshots")
        guard let menu = NSApp.mainMenu else { return try require(false, "Missing app menu") }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations); NativeFilterMenus.install(operations, in: menu)
        guard let operation = NativeFilterCatalog.shared.operation(named: "gimp:curves"),
              let curvesItem = menuItem("gimp:curves", in: menu),
              let ordinaryItem = menuItem("gegl:invert-gamma", in: menu) else {
            return try require(false, "Missing adjustment menu entries")
        }
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            for role in 0..<3 {
                let image = try session.newLabImage(width: 32, height: 24, component: component)
                nativeOnly.append(image)
                var axis = try session.labAxes(image).axes[role]
                try session.channelCommand(.select, channel: axis.id, image: image)
                axis = try session.labAxes(image).axes[role]
                try session.fillLab(image, axis: axis, value: role == 0 ? 25 : -64, opacity: 1)
                let original = try render(image)
                let expectedCopy = try session.newLabImage(width: 32, height: 24, component: component)
                nativeOnly.append(expectedCopy)
                var expectedAxis = try session.labAxes(expectedCopy).axes[role]
                try session.channelCommand(.select, channel: expectedAxis.id, image: expectedCopy)
                expectedAxis = try session.labAxes(expectedCopy).axes[role]
                // Qualified physical Fill is independent of the curve sampler
                // and matches the constant-half curve including integer rounding.
                try session.fillLab(expectedCopy, axis: expectedAxis, value: role == 0 ? 50 : -0.5, opacity: 1)
                let expected = try render(expectedCopy)
                let expectedPixel = try centerPixel(session.render(expectedCopy, scale: 1,
                    area: CGRect(x: 0, y: 0, width: 32, height: 24)))
                try session.closeImage(expectedCopy); nativeOnly.removeAll { $0 == expectedCopy }
                expect(expected != original, "physical Fill oracle differs from source")
                let document = try ImageDocument(session: session, image: image, name: "Lab Curves \(component) axis \(role)")
                let controller = DocumentWindowController(document: document, exportDirectory: work)
                controllers.append(controller); nativeOnly.removeAll { $0 == image }; documents.items.append(document)
                document.onError = { errors.append($0) }
                controller.showWindow(nil); NSApp.activate(ignoringOtherApps: true); controller.window?.makeKeyAndOrderFront(nil)
                try drain(document)
                let undo = document.undoInfo.undoCount
                expect(controller.validateMenuItem(curvesItem), "actual Lab Curves command is enabled")
                expect(!controller.validateMenuItem(ordinaryItem), "unqualified Lab adjustment remains disabled")
                controller.openNativeFilter(operation); try ready(controller)
                let panel = controller.labCurvesPanel!
                expect(panel.window?.title == "Lab Curves", "panel names the physical Lab adjustment")
                expect(!controller.validateMenuItem(curvesItem), "another adjustment cannot open over preview")
                try drawHalf(panel); try ready(controller)
                if let preview = controller.canvas.labCurvesPreviewImage {
                    expect(try centerPixel(preview) == expectedPixel, "canvas preview matches independent physical Fill oracle")
                } else { expect(false, "current Lab Curves has actual preview pixels") }
                expect(try render(image) == original && document.undoInfo.undoCount == undo,
                       "preview leaves source and history unchanged")
                expect(try session.labAxes(image).axes[role].uuid == axis.uuid, "preview preserves captured axis identity")
                try geometry(panel)
                if component == .u8 {
                    try capturePanel(panel, name: "lab-curves-axis-\(role).png")
                    let invalid = role == 0 ? "100.1" : "127.1"
                    let editor = try draft(panel, field: panel.outputField, text: invalid, publish: false)
                    expect(panel.control(panel.outputField, textView: editor, doCommandBy: NSSelectorFromString("insertNewline:")),
                           "Return checks the live physical numeric draft")
                    try drain(document)
                    expect(controller.labCurvesPanel === panel && !panel.applyButton.isEnabled,
                           "out-of-range physical draft cannot Apply stale preview")
                    expect(try render(image) == original && document.undoInfo.undoCount == undo,
                           "invalid physical draft preserves source and history")
                    panel.resetButton.performClick(nil); try ready(controller)
                    try drawHalf(panel); try ready(controller)
                }
                panel.cancelButton.performClick(nil); try drain(document)
                expect(controller.labCurvesPanel == nil && controller.canvas.labCurvesPreviewImage == nil,
                       "Cancel removes physical Lab panel and preview")
                expect(try render(image) == original && document.undoInfo.undoCount == undo,
                       "Cancel leaves original pixels and history")
                controller.openNativeFilter(operation); try ready(controller)
                let applyPanel = controller.labCurvesPanel!
                try drawHalf(applyPanel); try ready(controller)
                applyPanel.applyButton.performClick(nil)
                try wait({ controller.labCurvesPanel == nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy },
                         "Apply finishes and disposes snapshot")
                expect(try render(image) == expected && document.undoInfo.undoCount == undo + 1,
                       "Apply matches independent Fill and creates one Undo")
                document.undo(); try drain(document)
                expect(try render(image) == original, "Undo restores source pixels")
                document.redo(); try drain(document)
                expect(try render(image) == expected, "Redo restores applied pixels")
                controller.closeDiscardingChanges()
                try wait({ document.pendingWork == 0 && (try? session.info(image)) == nil }, "Completed Lab document closes")
            }
        }
        // Admission and teardown races use the real ordered document queue.
        for kind in 0..<4 {
            let image = try session.newLabImage(width: 32, height: 24, component: .u8)
            nativeOnly.append(image)
            let axis = try session.labAxes(image).axes[0]
            let original = try render(image)
            let document = try ImageDocument(session: session, image: image, name: "Lab preview cleanup \(kind)")
            let controller = DocumentWindowController(document: document, exportDirectory: work)
            controllers.append(controller); nativeOnly.removeAll { $0 == image }; documents.items.append(document)
            document.onError = { errors.append($0) }
            controller.showWindow(nil); controller.window?.makeKeyAndOrderFront(nil)
            try drain(document)
            controller.openNativeFilter(operation)
            if kind >= 2 {
                try ready(controller)
                try drawHalf(controller.labCurvesPanel!)
            }
            if kind % 2 == 0 {
                controller.cancelOperation(nil)
                try drain(document)
                expect(controller.labCurvesPanel == nil && controller.canvas.labCurvesPreviewImage == nil && document.acceptsEdits,
                       "Cancel during pending begin/render clears preview ownership and re-enables editing")
                expect(try render(image) == original, "late canceled work leaves source pixels unchanged")
                let token = try session.beginLabCurvesSnapshot(image, axis: axis)
                try session.endLabCurvesSnapshot(image, token: token)
                expect(token != 0, "cancelled UI token is released before another native snapshot begins")
            }
            controller.closeDiscardingChanges()
            try wait({ document.pendingWork == 0 && (try? session.info(image)) == nil && !EngineActivity.shared.isBusy },
                     "Close drains pending begin/render and destroys native image")
            expect(controller.labCurvesPanel == nil && controller.window?.isVisible == false,
                   "close during begin/render leaves no Lab panel or document window")
        }
    }
}
