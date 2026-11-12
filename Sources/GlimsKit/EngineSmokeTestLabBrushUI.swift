import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    static func exerciseLabBrushUI(session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "lab-brush-ui: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "LabBrushUISmoke", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ ready: () -> Bool, _ message: String) throws {
            let deadline = Date().addingTimeInterval(20)
            while !ready() && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            EngineSmokeTestHost.pumpEvents()
            try require(ready(), message)
        }
        func drain(_ document: ImageDocument) throws {
            try wait({ document.pendingWork == 0 && !document.targetCommandIsPending
                       && !EngineActivity.shared.isBusy }, "Document work drains")
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func control<T: NSView>(_ type: T.Type, label: String, in root: NSView) throws -> T {
            let found = descendants(root).compactMap { $0 as? T }.filter { $0.accessibilityLabel() == label }
            try require(found.count == 1, "One actual control has AX label '\(label)'")
            return found[0]
        }
        func visible(_ view: NSView, in root: NSView) -> Bool {
            !view.isHiddenOrHasHiddenAncestor && view.window?.isVisible == true
                && view.bounds.width > 1 && view.bounds.height > 1
                && view.visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(view.bounds)
                && root.bounds.insetBy(dx: -0.5, dy: -0.5).contains(view.convert(view.bounds, to: root))
        }
        func render(_ image: Int32, area: CGRect = CGRect(x: 0, y: 0, width: 32, height: 24)) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: area)
            guard let data = rendered.dataProvider?.data as Data? else {
                throw NSError(domain: "LabBrushUISmoke", code: 2)
            }
            return data
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        func artifact(_ window: NSWindow, _ name: String) throws {
            guard let directory = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"] else { return }
            do {
                try require(!directory.isEmpty, "Artifact directory is nonempty")
                // Capture the actual window surface, including Rigi's opaque
                // palette chrome behind the transparent Options scroll view.
                guard let view = window.contentView?.superview else {
                    throw NSError(domain: "LabBrushUISmoke", code: 15)
                }
                view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
                guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                    throw NSError(domain: "LabBrushUISmoke", code: 3)
                }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let png = bitmap.representation(using: .png, properties: [:]), !png.isEmpty else {
                    throw NSError(domain: "LabBrushUISmoke", code: 4)
                }
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent(name), options: .atomic)
                expect(true, "saved actual AppKit artifact \(name)")
            } catch { expect(false, "artifact \(name): \(error)"); throw error }
        }

        try require(session.supportsLabBrush, "UI fixture requires the complete Lab Brush capability")
        let state = ToolState.shared, oldTool = ToolState.shared.current
        let oldBrush = state.brush(for: .paintbrush), oldForeground = state.foreground
        let oldMenu = NSApp.mainMenu, menu = MainMenu.make(), app = AppController()
        let options = ToolOptionsPaletteController(), tools = ToolsPaletteController()
        let optionsSize = ToolOptionsPaletteController.definition.contentSize
        let optionsWindow = ClassicPaletteWindow(contentSize: NSSize(width: optionsSize.width + 2,
            height: optionsSize.height + PaletteChromeView.titleBarHeight + 1))
        let optionsChrome = PaletteChromeView(title: ToolOptionsPaletteController.definition.title)
        var controllers: [DocumentWindowController] = [], looseImages: [Int32] = [], errors: [String] = []
        defer {
            optionsWindow.makeFirstResponder(nil)
            options.retarget(to: nil); tools.retarget(to: nil)
            optionsWindow.orderOut(nil); optionsWindow.close()
            for controller in controllers {
                let document = controller.imageDocument
                if document.labBrushStrokeIsActive { document.cancelLabBrushStroke() }
                else if document.strokeIsActive { document.endStroke() }
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .abort); sheet.orderOut(nil)
                }
                if !controller.closeStarted { controller.closeDiscardingChanges() }
            }
            do { try wait({ controllers.allSatisfy { $0.imageDocument.pendingWork == 0 && gone($0.imageDocument.image) }
                            && !EngineActivity.shared.isBusy }, "Owned Lab Brush windows and images close") }
            catch { expect(false, "cleanup drains owned work: \(error)") }
            expect(controllers.allSatisfy { $0.window?.attachedSheet == nil }, "cleanup leaves no owned sheets")
            documents.items.removeAll { candidate in controllers.contains { $0.imageDocument === candidate } }
            for image in looseImages {
                do { try session.closeImage(image) } catch { expect(false, "loose image cleanup: \(error)") }
            }
            expect(errors.isEmpty, "no unexpected document or cleanup errors")
            state.update(.paintbrush) { $0 = oldBrush }
            state.foreground = oldForeground
            state.select(oldTool)
            NSApp.mainMenu = oldMenu
        }
        // update changes in-session values only; no brush identity or user defaults are written.
        state.update(.paintbrush) { $0 = EngineSession.Brush(); $0.size = 8; $0.hardness = 1; $0.pressureSize = true }
        state.foreground = .magenta
        state.select(.paintbrush)
        NSApp.mainMenu = menu
        optionsWindow.isReleasedWhenClosed = false
        optionsChrome.embedContent(options.view)
        optionsWindow.contentView = optionsChrome
        _ = tools.view

        func attach(_ image: Int32, name: String) throws -> DocumentWindowController {
            looseImages.append(image)
            let document = try ImageDocument(session: session, image: image, name: name)
            let controller = DocumentWindowController(document: document, exportDirectory: work)
            controllers.append(controller); documents.items.append(document)
            looseImages.removeAll { $0 == image }
            document.onError = { errors.append($0) }
            controller.showWindow(nil); controller.zoom(to: 400)
            controller.window?.makeKeyAndOrderFront(nil)
            try drain(document)
            return controller
        }
        func target(_ controller: DocumentWindowController) throws {
            guard let window = controller.window else { throw NSError(domain: "LabBrushUISmoke", code: 16) }
            optionsWindow.makeFirstResponder(nil)
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.makeMain()
            // The hosted test has no AppController document registry. Its real
            // menu validator must resolve this actual AppKit main window;
            // otherwise the no-document permissive fallback hides RGB errors.
            do {
                try wait({ NSApp.isActive && NSApp.mainWindow === window
                           && app.frontDocument === controller.imageDocument },
                         "Actual tool-menu target is the intended main document")
            } catch {
                print("     Lab Brush menu focus: active=\(NSApp.isActive), "
                    + "main=\(NSApp.mainWindow?.windowNumber ?? -1), expected=\(window.windowNumber), "
                    + "frontImage=\(app.frontDocument?.image ?? 0), expectedImage=\(controller.imageDocument.image)")
                throw error
            }
            options.retarget(to: controller.imageDocument); tools.retarget(to: controller.imageDocument)
            optionsWindow.orderFront(nil)
            EngineSmokeTestHost.pumpEvents()
            options.view.layoutSubtreeIfNeeded()
            try require(NSApp.mainWindow === window && app.frontDocument === controller.imageDocument,
                        "Showing the nonactivating palette preserves the actual menu target")
        }
        func field(_ document: ImageDocument) throws -> NSTextField {
            guard let axis = document.selectedLabAxis else { throw NSError(domain: "LabBrushUISmoke", code: 5) }
            return try control(NSTextField.self, label: "Lab brush \(axis.role.title) physical value", in: options.view)
        }
        func draft(_ field: NSTextField, _ text: String) throws {
            optionsWindow.makeKeyAndOrderFront(nil)
            try require(optionsWindow.makeFirstResponder(field), "Actual physical-value field accepts focus")
            field.selectText(nil)
            try wait({ field.currentEditor() is NSTextView }, "Actual physical-value field editor exists")
            (field.currentEditor() as? NSTextView)?.string = text
            field.stringValue = text
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
            options.view.layoutSubtreeIfNeeded()
        }
        func pressure() throws -> NSButton {
            let found = descendants(options.view).compactMap { $0 as? NSButton }.filter { $0.title == "Pen pressure sets size" }
            try require(found.count == 1, "Actual pressure control exists")
            return found[0]
        }
        func mouse(_ controller: DocumentWindowController, _ type: NSEvent.EventType, _ point: CGPoint) throws {
            let canvas = controller.canvas
            guard let window = canvas.window else { throw NSError(domain: "LabBrushUISmoke", code: 6) }
            let location = canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                throw NSError(domain: "LabBrushUISmoke", code: 7)
            }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: throw NSError(domain: "LabBrushUISmoke", code: 8)
            }
        }
        func escape(_ controller: DocumentWindowController) throws {
            guard let window = controller.window,
                  let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53) else { throw NSError(domain: "LabBrushUISmoke", code: 9) }
            window.makeFirstResponder(controller.canvas)
            controller.canvas.keyDown(with: event)
        }
        let start = CGPoint(x: 16.5, y: 12.5), finish = CGPoint(x: 20.5, y: 12.5)
        func stroke(_ controller: DocumentWindowController) throws {
            try mouse(controller, .leftMouseDown, start)
            try mouse(controller, .leftMouseDragged, finish)
            try mouse(controller, .leftMouseUp, finish)
            try drain(controller.imageDocument)
        }
        func pick(_ role: EngineSession.LabAxisRole, _ controller: DocumentWindowController) throws {
            let document = controller.imageDocument
            guard let axis = document.labAxes?.axes.first(where: { $0.role == role }) else {
                throw NSError(domain: "LabBrushUISmoke", code: 10)
            }
            optionsWindow.makeFirstResponder(nil)
            try require(document.selectLabAxis(axis), "Lab axis selection is admitted")
            try drain(document); try target(controller)
            try require(document.selectedLabAxis?.uuid == axis.uuid, "Typed axis selection reaches the document")
        }
        func toolMenu(_ tool: ToolID) throws -> NSMenuItem {
            func find(_ menu: NSMenu) -> NSMenuItem? {
                for item in menu.items {
                    if item.action == #selector(AppController.selectToolFromMenu(_:)) && item.tag == ToolMenuCatalog.tag(for: tool) { return item }
                    if let child = item.submenu, let found = find(child) { return found }
                }
                return nil
            }
            guard let item = find(menu) else { throw NSError(domain: "LabBrushUISmoke", code: 11) }
            return item
        }

        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let tag = component == .u8 ? "u8" : component == .u16 ? "u16" : "float"
            let controller = try attach(session.newLabImage(width: 32, height: 24, component: component), name: "Lab Brush \(tag)")
            let document = controller.imageDocument, image = document.image
            try target(controller); try pick(.lightness, controller)
            let original = try render(image), originalHistory = document.undoInfo
            let originalCenter = try render(image, area: CGRect(x: 16, y: 12, width: 1, height: 1))
            let originalCorner = try render(image, area: CGRect(x: 0, y: 0, width: 1, height: 1))
            let value = try field(document)
            let message = try control(NSTextField.self, label: "Lab brush value validation", in: options.view)
            expect(visible(value, in: options.view) && visible(message, in: options.view), "\(tag): value and range message fit the initial palette")
            expect(try !pressure().isEnabled && pressure().state == .off && state.brush(for: .paintbrush).pressureSize,
                   "\(tag): Lab disables pressure without changing the ordinary brush preference")
            for title in ["Size", "Opacity", "Hardness"] {
                _ = try control(NSTextField.self, label: "\(title) value", in: options.view)
            }
            expect(try app.validateMenuItem(toolMenu(.paintbrush)) && !app.validateMenuItem(toolMenu(.pencil))
                   && app.validateMenuItem(toolMenu(.hand)) && app.validateMenuItem(toolMenu(.zoom)),
                   "\(tag): actual tool menus allow Brush/Hand/Zoom and refuse Pencil")
            if component == .u8 { try artifact(optionsWindow, "lab-brush-options-u8.png") }

            try draft(value, "not a number")
            expect(message.textColor == .systemRed && !message.stringValue.isEmpty && visible(message, in: options.view),
                   "\(tag): invalid physical draft displays a visible error")
            if component == .u8 { try artifact(optionsWindow, "lab-brush-invalid-u8.png") }
            let errorsBefore = errors.count
            try stroke(controller)
            expect(Array(errors.dropFirst(errorsBefore)) == [message.stringValue]
                   && !document.strokeIsActive && !document.labBrushStrokeIsActive,
                   "\(tag): invalid draft refuses the actual pointer gesture")
            errors.removeSubrange(errorsBefore..<errors.count)
            expect(try render(image) == original && document.undoInfo == originalHistory,
                   "\(tag): refused gesture changes no pixels or Undo/Redo history")
            try draft(value, "101")
            guard let lightness = document.selectedLabAxis else { throw NSError(domain: "LabBrushUISmoke", code: 13) }
            expect((try? document.labBrushValue(for: lightness).get()) == (component == .float ? 101 : nil),
                   "\(tag): L* nominal upper bound is enforced only for integer storage")
            try draft(value, "0")
            try stroke(controller)
            let painted = try render(image)
            let paintedCenter = try render(image, area: CGRect(x: 16, y: 12, width: 1, height: 1))
            expect(painted != original && paintedCenter != originalCenter,
                   "\(tag): actual L*=0 gesture changes the center despite magenta foreground")
            expect(try render(image, area: CGRect(x: 0, y: 0, width: 1, height: 1)) == originalCorner,
                   "\(tag): local brush leaves the corner untouched")
            expect(document.undoInfo.undoCount == originalHistory.undoCount + 1, "\(tag): accepted pointer gesture creates one Undo")
            document.undo(); try drain(document)
            expect(try render(image) == original, "\(tag): Undo restores exact displayed pixels")
            document.redo(); try drain(document)
            expect(try render(image) == painted, "\(tag): Redo restores exact displayed stroke")
            document.undo(); try drain(document)

            // No event-loop turn between press and Escape tests the queued path;
            // the second case waits for a visible native dab before cancelling.
            for active in [false, true] {
                let before = try render(image), history = document.undoInfo
                try mouse(controller, .leftMouseDown, start)
                try require(document.labBrushStrokeIsActive, "Lab pointer press was accepted before Escape")
                if active {
                    try drain(document)
                    expect(try render(image) != before, "\(tag): active cancellation starts from an actually painted preview")
                }
                try escape(controller); try mouse(controller, .leftMouseUp, finish)
                try drain(document)
                expect(try render(image) == before && document.undoInfo == history
                       && !document.strokeIsActive && !document.labBrushStrokeIsActive,
                       "\(tag): \(active ? "active" : "queued") Escape restores exact pixels/history, including late mouse-up")
            }

            try draft(value, "25")
            try pick(.a, controller)
            let chroma = try field(document)
            guard let aAxis = document.selectedLabAxis else { throw NSError(domain: "LabBrushUISmoke", code: 14) }
            try draft(chroma, "-160")
            expect((try? document.labBrushValue(for: aAxis).get()) == (component == .float ? -160 : nil),
                   "\(tag): physical negative extended chroma is accepted only for Float")
            try draft(chroma, "128")
            expect((try? document.labBrushValue(for: aAxis).get()) == (component == .float ? 128 : nil),
                   "\(tag): integer chroma upper bound is 127")
            try draft(chroma, "-20")
            try pick(.lightness, controller)
            expect(try field(document).stringValue == "25", "\(tag): switching axes restores that axis's independent draft")
            chroma.stringValue = "77"
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: chroma)
            let returnedLightnessDraft = try field(document).stringValue
            expect(document.labBrushDraft(for: aAxis) == "-20" && returnedLightnessDraft == "25",
                   "\(tag): late detached-axis field notification changes neither draft")

            let other = try attach(session.newLabImage(width: 32, height: 24, component: component), name: "Lab Brush peer \(tag)")
            let peer = other.imageDocument
            let oldField = try field(document)
            try target(other); try pick(.lightness, other)
            expect(try field(peer).stringValue == "50", "\(tag): a different document starts with its own physical draft")
            try draft(field(peer), "65")
            oldField.stringValue = "88"
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: oldField)
            let peerDraft = try field(peer).stringValue
            expect(document.labBrushDraft(for: lightness) == "25" && peerDraft == "65",
                   "\(tag): late old-document notification cannot change either document's draft")
            try target(controller)
            expect(try field(document).stringValue == "25", "\(tag): returning to the original document restores its exact draft")

            // Compare with another real pointer gesture whose value stays zero.
            // This is a capture oracle, independent of native Lab quantization.
            try draft(field(document), "0")
            try mouse(controller, .leftMouseDown, start)
            try require(document.labBrushStrokeIsActive, "Capture comparison accepts the first gesture")
            try draft(field(document), "90")
            try mouse(controller, .leftMouseDragged, finish); try mouse(controller, .leftMouseUp, finish)
            try drain(document)
            let captured = try render(image)
            try target(other); try draft(field(peer), "0"); try stroke(other)
            expect(try render(peer.image) == captured && captured != original,
                   "\(tag): editing the physical value after press cannot alter the captured stroke")
            try target(controller)
            expect(try field(document).stringValue == "90", "\(tag): accepted stroke retains the later draft for the next gesture")

            let url = work.appendingPathComponent("lab-brush-ui-\(tag).xcf")
            var saved = false, saveError: Error?
            document.save(to: url) { saveError = $0; saved = true }
            try wait({ saved }, "Painted Lab XCF Save completes"); try drain(document)
            if let saveError { throw saveError }
            // Match DocumentWindowController's successful Save adoption. The
            // document service alone writes bytes without taking file identity.
            document.noteSaved(to: url)
            let reopened = try session.openImage(path: url.path); looseImages.append(reopened)
            let axesBefore = try session.labAxes(image), axesAfter = try session.labAxes(reopened)
            expect(try render(reopened) == captured && axesAfter.component == component
                   && axesBefore.axes.map(\.uuid) == axesAfter.axes.map(\.uuid),
                   "\(tag): painted XCF reopens with exact display, precision and durable axis UUIDs")
            expect(!document.hasUnsavedChanges && document.fileState.nativeURL == url,
                   "\(tag): successful XCF Save adopts its destination and clears the painted document's dirty state")
        }

        let rgbPixels = ClipboardImage(width: 32, height: 24,
            pixels: Data(repeating: 255, count: 32 * 24 * 4), origin: .zero)
        let rgb = try attach(session.newImage(pixels: rgbPixels), name: "RGB after Lab Brush")
        try target(rgb)
        expect(try pressure().isEnabled && pressure().state == .on,
               "RGB retarget restores enabled pressure and the original preference")
        try pressure().performClick(nil)
        expect(!state.brush(for: .paintbrush).pressureSize, "actual RGB pressure checkbox updates ordinary brush settings")
        try pressure().performClick(nil)
        expect(descendants(options.view).allSatisfy { $0.accessibilityLabel() != "Lab brush Lightness (L*) physical value" },
               "RGB retarget removes the Lab-only physical-value editor")
        let brushMenu = try toolMenu(.paintbrush), pencilMenu = try toolMenu(.pencil)
        expect(app.validateMenuItem(brushMenu) && app.validateMenuItem(pencilMenu), "actual RGB menus restore Brush and Pencil")
        app.selectToolFromMenu(pencilMenu)
        expect(state.current == .pencil, "actual RGB tool menu action selects Pencil")
        app.selectToolFromMenu(brushMenu)
        guard let grid = descendants(tools.view).compactMap({ $0 as? ClassicToolGrid }).first else {
            throw NSError(domain: "LabBrushUISmoke", code: 12)
        }
        expect(grid.slots.flatMap(\.tools).contains { $0.id == ToolID.pencil.rawValue && $0.isEnabled },
               "actual RGB Tools grid restores Pencil availability")
        let beforeRGB = try render(rgb.imageDocument.image), historyRGB = rgb.imageDocument.undoInfo.undoCount
        try stroke(rgb)
        expect(try render(rgb.imageDocument.image) != beforeRGB && rgb.imageDocument.undoInfo.undoCount == historyRGB + 1,
               "ordinary RGB pointer painting still changes pixels with one Undo after Lab retarget")
        rgb.imageDocument.undo(); try drain(rgb.imageDocument)
        expect(try render(rgb.imageDocument.image) == beforeRGB, "ordinary RGB pointer Undo restores exact pixels")
    }
}
