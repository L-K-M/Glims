import AppKit
import RigiUI

private struct CmykSmokeProfileCatalogLoader: PsdCmykProfileCatalogLoading {
    let profile: PsdCmykProfile
    func loadCatalog() throws -> [PsdCmykProfileCatalogEntry] {
        [PsdCmykProfileCatalogEntry(profile: profile)]
    }
}

@MainActor
extension EngineSmokeTest {
    static func exerciseCmyk(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "cmyk: \(message)") }
        func wait(_ condition: () -> Bool, timeout: TimeInterval = 15) -> Bool {
            let limit = Date().addingTimeInterval(timeout)
            while !condition() && Date() < limit { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            return condition()
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "CmykSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func drain(_ document: ImageDocument) throws {
            try require(wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy },
                        "Image work did not drain")
            EngineSmokeTestHost.pumpEvents()
        }
        func descendants(of view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(of: $0) } }
        func pixels(_ image: Int32, width: Int = 32, height: Int = 24) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: width, height: height))
            guard let data = rendered.dataProvider?.data as Data? else {
                throw NSError(domain: "CmykSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing rendered pixels"])
            }
            return data
        }
        func pointer(_ controller: DocumentWindowController, type: NSEvent.EventType, x: CGFloat, y: CGFloat,
                     flags: NSEvent.ModifierFlags = []) throws {
            let canvas = controller.canvas
            guard let window = controller.window,
                  let event = NSEvent.mouseEvent(with: type,
                                                 location: canvas.convert(CGPoint(x: x * canvas.scale, y: y * canvas.scale), to: nil),
                                                 modifierFlags: flags,
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            else {
                throw NSError(domain: "CmykSmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not create pointer event"])
            }
            if type == .leftMouseDown { canvas.mouseDown(with: event) } else { canvas.mouseUp(with: event) }
        }

        guard let profileBytes = NSColorSpace.genericCMYK.iccProfileData else {
            throw NSError(domain: "CmykSmoke", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "Generic CMYK profile bytes unavailable"])
        }
        try require(PsdCmykProfile.isValidICCData(profileBytes), "generic CMYK profile bytes unavailable")
        let profile = try PsdCmykProfile(displayName: "CMYK Smoke Source", iccData: profileBytes)
        let loader = CmykSmokeProfileCatalogLoader(profile: profile)

        func newImageSettings(_ component: EngineSession.ColorComponent) throws -> NewImageSettings {
            let panel = NewImagePanel(profileLoader: loader)
            defer { panel.close() }
            panel.showWindow(nil)
            panel.window?.makeKeyAndOrderFront(nil)
            guard let content = panel.window?.contentView else {
                throw NSError(domain: "CmykSmoke", code: 5, userInfo: [NSLocalizedDescriptionKey: "Missing New Image content"])
            }
            let views = descendants(of: content)
            guard let mode = views.first(where: { $0.accessibilityLabel() == "Image mode" }) as? NSPopUpButton,
                  let precision = views.first(where: { $0.accessibilityLabel() == "Precision" }) as? NSPopUpButton,
                  let width = views.first(where: { $0.accessibilityLabel() == "Width in pixels" }) as? NSTextField,
                  let height = views.first(where: { $0.accessibilityLabel() == "Height in pixels" }) as? NSTextField,
                  let channels = views.first(where: { $0.accessibilityLabel() == "Ink channels" }) as? NSTextField,
                  let profilePopup = views.first(where: { $0.accessibilityLabel() == "CMYK source profile" }) as? NSPopUpButton,
                  let create = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Create" })
            else {
                throw NSError(domain: "CmykSmoke", code: 6, userInfo: [NSLocalizedDescriptionKey: "Missing New Image controls"])
            }

            expect(!precision.isEnabled && !channels.isEnabled, "RGB New Image leaves CMYK controls inactive")
            if let cmykIndex = (0..<mode.numberOfItems).first(where: { mode.item(at: $0)?.title == "CMYK" }) {
                mode.selectItem(at: cmykIndex)
                _ = mode.sendAction(mode.action, to: mode.target)
            } else {
                try require(false, "New Image has no CMYK mode")
            }

            let loaded = wait { (0..<profilePopup.numberOfItems).contains { index in
                guard let data = profilePopup.item(at: index)?.representedObject as? Data else { return false }
                return data == profileBytes
            } && profilePopup.isEnabled }
            try require(loaded, "CMYK source profile did not load")
            expect(precision.isEnabled, "choosing CMYK enables precision")
            expect(!channels.isEnabled && channels.stringValue == "4", "CMYK ink count is fixed at 4 and disabled")

            let componentIndex = try requireIndex(NewImageSettings.multichannelComponents.firstIndex(of: component),
                                                  "Missing precision index")
            precision.selectItem(at: componentIndex)

            expect(profilePopup.selectedItem?.title == profile.displayName &&
                   (profilePopup.selectedItem?.representedObject as? Data) == profileBytes,
                   "New Image selects the captured source profile")
            var result: NewImageSettings?
            panel.onCreate = { result = $0 }
            width.stringValue = "0"; height.stringValue = "24"
            panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: width))
            expect(!create.isEnabled, "New Image refuses invalid width")
            _ = create.sendAction(create.action, to: create.target)
            try require(result == nil, "Invalid width reached the Create callback")
            width.stringValue = "32"; height.stringValue = "0"
            panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: height))
            expect(!create.isEnabled, "New Image refuses invalid height")
            _ = create.sendAction(create.action, to: create.target)
            try require(result == nil, "Invalid height reached the Create callback")
            width.stringValue = "32"; height.stringValue = "24"
            panel.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: height))
            let valid = wait { create.isEnabled }
            try require(valid, "New Image did not become valid for CMYK")

            if component == .u8, let path = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"],
               let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) {
                content.layoutSubtreeIfNeeded(); content.cacheDisplay(in: content.bounds, to: rep)
                try rep.representation(using: .png, properties: [:])?.write(to:
                    URL(fileURLWithPath: path).appendingPathComponent("cmyk-new-image.png"))
            }

            create.performClick(nil)
            guard let result else { throw NSError(domain: "CmykSmoke", code: 7, userInfo: [NSLocalizedDescriptionKey: "Create did not produce settings"]) }
            expect(result.kind == .cmyk, "Create reports CMYK kind")
            expect(result.component == component, "Create reports selected precision")
            expect(result.channelCount == 4 && result.width == 32 && result.height == 24, "Create reports CMYK dimensions and channel count")
            expect(result.profileICC == profileBytes, "Create reports exact captured profile bytes")
            return result
        }

        let state = ToolState.shared
        let oldTool = state.current
        let oldForeground = state.foreground
        let oldPencil = state.brush(for: .pencil)
        defer {
            state.update(.pencil) { $0 = oldPencil }
            state.foreground = oldForeground
            state.select(oldTool)
        }

        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let settings = try newImageSettings(component)
            guard let selectedICC = settings.profileICC else {
                throw NSError(domain: "CmykSmoke", code: 9,
                              userInfo: [NSLocalizedDescriptionKey: "CMYK Create omitted the source profile"])
            }
            let image = try session.newCmykImage(width: settings.width, height: settings.height,
                                                component: settings.component, profileICC: selectedICC)
            var controllers: [DocumentWindowController] = []
            var nativeOnly: [Int32] = [image]
            var oldErrorHandlers: [(ImageDocument, ((String) -> Void)?)] = []
            var unexpectedErrors: [String] = []
            defer {
                for controller in controllers {
                    if let window = controller.window, let sheet = window.attachedSheet {
                        window.endSheet(sheet, returnCode: .abort)
                    }
                }
                for controller in controllers where !controller.closeStarted {
                    controller.closeDiscardingChanges()
                }
                let closed = wait({ controllers.allSatisfy { (try? session.info($0.imageDocument.image)) == nil } }, timeout: 20)
                expect(closed && controllers.allSatisfy { $0.imageDocument.pendingWork == 0 },
                       "owned CMYK windows drain and close")
                expect(controllers.allSatisfy { $0.window?.attachedSheet == nil }, "cleanup leaves no owned sheet")
                expect(unexpectedErrors.isEmpty, "CMYK fixture and cleanup produce no unexpected document errors")
                for (document, handler) in oldErrorHandlers { document.onError = handler }
                documents.items.removeAll { candidate in controllers.contains { $0.imageDocument === candidate } }
                nativeOnly.forEach { try? session.closeImage($0) }
            }

            func attach(_ id: Int32, name: String) throws -> DocumentWindowController {
                let document = try ImageDocument(session: session, image: id, name: name)
                let controller = DocumentWindowController(document: document, exportDirectory: work)
                oldErrorHandlers.append((document, document.onError))
                document.onError = { unexpectedErrors.append($0) }
                controllers.append(controller)
                nativeOnly.removeAll { $0 == id }
                documents.items.append(document)
                controller.showWindow(nil)
                controller.window?.makeKeyAndOrderFront(nil)
                controller.zoom(to: 600)
                try drain(document)
                return controller
            }

            let controller = try attach(image, name: "CMYK \(component.title)")
            let document = controller.imageDocument
            expect(document.colorInfo.mode == .cmyk, "document reports CMYK mode")
            expect(document.colorInfo.component == component, "document reports selected CMYK precision")
            expect(document.colorInfo.hasEmbeddedProfile, "CMYK document has embedded profile")
            expect(!document.colorInfo.profileLabel.isEmpty, "CMYK document exposes non-empty profile label")
            expect(document.channels.count == 4 && document.layers.isEmpty, "CMYK document exposes exactly four real channels and no RGB proxy layer")
            try require(document.channels.count == 4, "CMYK document does not have exactly four channels")
            expect(document.activeDrawable == document.channels[0].id, "first CMYK ink is initial painting target")

            let tools = ToolsPaletteController()
            _ = tools.view
            tools.retarget(to: document)
            defer { tools.retarget(to: nil) }
            let grid = descendants(of: tools.view).compactMap { $0 as? ClassicToolGrid }.first
            try require(grid != nil, "Tools grid unavailable for CMYK")
            if let grid {
                expect(grid.slots.map { $0.tools.map(\.id) } == ToolID.paletteSlots.map { $0.map(\.rawValue) },
                       "CMYK preserves every tool slot and group")
                let allMatch = grid.slots.flatMap(\.tools).allSatisfy { item in
                    guard let tool = ToolID(rawValue: item.id) else { return false }
                    return item.isEnabled == tool.isAvailable(in: .cmyk)
                }
                expect(allMatch, "CMYK tool grid matches tool availability")
                let pencilAvailable = grid.slots.flatMap(\.tools).contains { item in
                    guard let tool = ToolID(rawValue: item.id), tool == .pencil else { return false }
                    return item.isEnabled && tool.isAvailable(in: .cmyk)
                }
                expect(pencilAvailable, "Pencil remains available in CMYK")
                let knownUnsupportedDisabled = grid.slots.flatMap(\.tools).contains { item in
                    guard let tool = ToolID(rawValue: item.id), tool == .move else { return false }
                    return !item.isEnabled && !tool.isAvailable(in: .cmyk)
                }
                expect(knownUnsupportedDisabled, "A known unsupported tool is disabled in CMYK")
                if let pencilItem = grid.slots.flatMap(\.tools).first(where: { $0.id == ToolID.pencil.rawValue }) {
                    grid.selectTool(id: pencilItem.id)
                    _ = grid.sendAction(grid.action, to: grid.target)
                }
            }
            expect(state.current == .pencil, "Pencil can be selected through actual CMYK tool grid")

            state.foreground = NSColor(srgbRed: 0.25, green: 0.25, blue: 0.25, alpha: 1)
            state.update(.pencil) { $0.size = 7; $0.opacity = 1; $0.hardness = 1; $0.pressureSize = false }

            let before = try pixels(image)
            let beforePaintedPixel = try requirePixel(session, image, x: 8, y: 8)
            let beforeDistantPixel = try requirePixel(session, image, x: 30, y: 22)
            let undoBeforeStroke = document.undoInfo.undoCount
            let redoBeforeStroke = document.undoInfo.redoCount
            try pointer(controller, type: .leftMouseDown, x: 8.5, y: 8.5)
            try pointer(controller, type: .leftMouseUp, x: 8.5, y: 8.5)
            try drain(document)
            let after = try pixels(image)
            expect(after != before, "CMYK pencil stroke changes rendered output")
            let strokePixel = try requirePixel(session, image, x: 8, y: 8)
            let distantPixel = try requirePixel(session, image, x: 30, y: 22)
            expect(strokePixel != beforePaintedPixel, "painted CMYK pixel changes from its prior value")
            expect(distantPixel == beforeDistantPixel, "distant CMYK pixel remains unchanged")
            expect(document.undoInfo.undoCount == undoBeforeStroke + 1,
                   "canvas stroke contributes exactly one Undo step")

            // Required window responder-chain undo/redo.
            guard let window = controller.window else {
                throw NSError(domain: "CmykSmoke", code: 8, userInfo: [NSLocalizedDescriptionKey: "Missing document window"])
            }
            let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "")
            let undoValid = window.validateMenuItem(undoItem)
            expect(undoValid && !document.undoInfo.nextUndo.isEmpty, "window responder Undo is enabled with a title")
            if !document.undoInfo.nextUndo.isEmpty {
                let expectedUndoTitle = "Undo \(document.undoInfo.nextUndo)"
                expect(undoItem.title == expectedUndoTitle, "Undo menu item names the exact step")
            }
            let undoHandled = window.tryToPerform(Selector(("undo:")), with: undoItem)
            expect(undoHandled, "window responder Undo is handled")
            try drain(document)
            expect(try pixels(image) == before, "window responder Undo restores full render exactly")
            expect(document.undoInfo.undoCount == undoBeforeStroke && document.undoInfo.redoCount == redoBeforeStroke + 1,
                   "window responder Undo restores the history counts")

            let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "")
            let redoValid = window.validateMenuItem(redoItem)
            expect(redoValid && !document.undoInfo.nextRedo.isEmpty &&
                   redoItem.title == "Redo \(document.undoInfo.nextRedo)",
                   "window responder Redo is enabled and names the exact step")
            let redoHandled = window.tryToPerform(Selector(("redo:")), with: redoItem)
            expect(redoHandled, "window responder Redo is handled")
            try drain(document)
            expect(try pixels(image) == after, "window responder Redo restores full render exactly")
            expect(document.undoInfo.undoCount == undoBeforeStroke + 1 && document.undoInfo.redoCount == redoBeforeStroke,
                   "window responder Redo restores the history counts")

            let channelsPalette = ChannelsPaletteController()
            channelsPalette.retarget(to: document)
            defer { channelsPalette.retarget(to: nil) }
            try require(document.channels.count >= 2, "CMYK document lacks second channel")
            let secondID = document.channels[1].id
            channelsPalette.perform(.selectChannel(secondID))
            try drain(document)
            expect(document.activeDrawable == secondID, "palette pick changes actual CMYK ink target")
            let afterFirstPaint = try pixels(image)
            let secondPixelBefore = try requirePixel(session, image, x: 23, y: 8)
            try pointer(controller, type: .leftMouseDown, x: 23.5, y: 8.5)
            try pointer(controller, type: .leftMouseUp, x: 23.5, y: 8.5)
            try drain(document)
            let secondStrokePixel = try requirePixel(session, image, x: 23, y: 8)
            let firstPaintPixelNow = try requirePixel(session, image, x: 8, y: 8)
            expect(secondStrokePixel != secondPixelBefore, "second CMYK ink changes its pixel")
            expect(firstPaintPixelNow == strokePixel, "painting second ink leaves first painted pixel unchanged")
            expect(try pixels(image) != afterFirstPaint, "second CMYK stroke changes rendered output")

            // ChannelForms CMYK ink color safety via actual edit routing.
            guard let targetChannel = document.channels.first(where: { $0.id == secondID }) else {
                throw NSError(domain: "CmykSmoke", code: 10,
                              userInfo: [NSLocalizedDescriptionKey: "Selected CMYK ink disappeared"])
            }
            let renderBeforeEdit = try pixels(image)
            let undoBeforeEdit = document.undoInfo.undoCount
            let renameTo = targetChannel.name == "CMYK Smoke Renamed" ? "CMYK Smoke Renamed 2" : "CMYK Smoke Renamed"

            channelsPalette.perform(.editChannel(targetChannel.id))
            let sheetReady = wait { controller.window?.attachedSheet != nil }
            try require(sheetReady, "CMYK channel attributes did not open its owned sheet")
            if let sheet = controller.window?.attachedSheet {
                defer {
                    if controller.window?.attachedSheet === sheet {
                        controller.window?.endSheet(sheet, returnCode: .abort)
                    }
                }
                guard let content = sheet.contentView else {
                    throw NSError(domain: "CmykSmoke", code: 11,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing channel attributes content"])
                }
                let sheetViews = descendants(of: content)
                guard let colorWell = sheetViews.first(where: { $0.accessibilityLabel() == "Ink color" }) as? NSColorWell,
                      let nameField = sheetViews.first(where: { $0.accessibilityLabel() == "Channel name" }) as? NSTextField,
                      let applyButton = sheetViews.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Apply" }) else {
                    throw NSError(domain: "CmykSmoke", code: 12,
                                  userInfo: [NSLocalizedDescriptionKey: "Missing channel attributes controls"])
                }
                expect(!colorWell.isEnabled, "CMYK ink color well is disabled")
                // Change the disabled view programmatically: Apply must omit arbitrary ink color.
                colorWell.color = NSColor(srgbRed: 0.2, green: 0.6, blue: 0.9, alpha: 1)
                nameField.stringValue = renameTo
                applyButton.performClick(nil)
                try require(wait { controller.window?.attachedSheet == nil }, "Channel Apply left its sheet open")
            }
            try drain(document)
            let renamed = document.channels.first(where: { $0.id == targetChannel.id })
            expect(renamed?.name == renameTo, "CMYK channel rename is accepted")
            expect(renamed?.color == targetChannel.color, "CMYK ink color remains unchanged after arbitrary color assignment attempt")
            expect(try pixels(image) == renderBeforeEdit, "CMYK channel attributes leave full render unchanged")
            expect(document.undoInfo.undoCount == undoBeforeEdit + 1,
                   "distinct CMYK channel rename contributes exactly one Undo step")

            expect(unexpectedErrors.isEmpty, "CMYK fixture produced no unexpected document errors")

            // Optional gated unsupported palette actions (no mutation).
            let pixelsBeforeGated = try pixels(image)
            let undoBeforeGated = document.undoInfo.undoCount
            channelsPalette.perform(.newChannel)
            channelsPalette.perform(.setQuickMask(true))
            channelsPalette.perform(.returnToLayers)
            // Exercise the unavailable temporary tool; the normal tool remains Pencil.
            expect(state.current == .pencil, "Pencil remains selected before temporary Move")
            try pointer(controller, type: .leftMouseDown, x: 8.5, y: 8.5, flags: .command)
            try pointer(controller, type: .leftMouseUp, x: 8.5, y: 8.5, flags: .command)
            try drain(document)
            expect(try pixels(image) == pixelsBeforeGated && document.undoInfo.undoCount == undoBeforeGated,
                   "unsupported/gated CMYK palette and temporary move actions leave pixels and Undo unchanged")

            let saveItem = NSMenuItem(title: "Save", action: #selector(DocumentWindowController.saveDocument(_:)), keyEquivalent: "")
            let exportItem = NSMenuItem(title: "Export", action: #selector(DocumentWindowController.exportDocument(_:)), keyEquivalent: "")
            expect(controller.validateMenuItem(saveItem), "CMYK menu allows XCF Save")
            expect(controller.validateMenuItem(exportItem) == (component == .u8 || component == .u16),
                   "CMYK menu offers PSD for integer inks and gates float export")

            let exportPath = work.appendingPathComponent("native-cmyk-\(component.rawValue).psd")
            let exportBefore = try pixels(image)
            let exportUndo = document.undoInfo.undoCount
            let exportDirty = document.hasUnsavedChanges
            let exportSettings = ExportSettings(format: .psd)
            var exportReturned = false
            var exportFailure: Error?
            if component == .u8, ProcessInfo.processInfo.environment["GLIMS_SMOKE_CMYK_PICKER"] == "1" {
                controller.exportDocument(nil)
                try require(wait { controller.window?.attachedSheet != nil }, "Native CMYK export sheet did not open")
                guard let panel = controller.window?.attachedSheet as? NSSavePanel,
                      let form = panel.accessoryView as? ExportOptionsForm else {
                    throw NSError(domain: "CmykSmoke", code: 10)
                }
                expect(form.settings.permitsNativeCmykPSD && !form.psdColorPopup.isEnabled
                       && form.psdCmykProfilePopup.titleOfSelectedItem == document.colorInfo.profileLabel,
                       "actual CMYK export sheet fixes source inks and profile")
                NSApp.activate(ignoringOtherApps: true)
                panel.makeKeyAndOrderFront(nil)
                FileHandle.standardError.write(Data("Export picker: save only to \(exportPath.path)\n".utf8))
                try require(wait({ controller.window?.attachedSheet == nil && document.pendingWork == 0
                    && document.fileState.lastExportURL != nil }, timeout: 90), "CMYK picker was not accepted")
                exportReturned = true
            } else {
                document.export(to: exportPath, settings: exportSettings) { error in
                    exportFailure = error; exportReturned = true
                }
                expect(EngineActivity.shared.progressDocument === document,
                       "export progress belongs to the document across queued work")
            }
            try drain(document)
            expect(exportReturned && EngineActivity.shared.progressDocument == nil,
                   "completed export releases progress ownership")
            if component == .float {
                expect(exportFailure != nil && !FileManager.default.fileExists(atPath: exportPath.path)
                       && document.fileState.lastExportURL == nil,
                       "float PSD refuses without output or remembered destination")
            } else {
                expect(exportFailure == nil && document.lastExportSettings?.permitsNativeCmykPSD == true,
                       "integer CMYK export remembers its successful native settings")
                let bytes = try Data(contentsOf: exportPath)
                expect(bytes.count > 26 && bytes.starts(with: Data("8BPS".utf8))
                       && bytes[24] == 0 && bytes[25] == 4
                       && bytes[23] == (component == .u8 ? 8 : 16)
                       && bytes.range(of: profileBytes) != nil,
                       "native PSD contains requested integer CMYK depth and exact source ICC")
                try FileManager.default.removeItem(at: exportPath)
                controller.repeatExport(nil)
                try drain(document)
                expect(try Data(contentsOf: exportPath) == bytes,
                       "Repeat Export reproduces exact native PSD without a sheet")
                var incompatible = exportSettings
                incompatible.psdLayout = .merged
                var refused = false
                document.export(to: exportPath, settings: incompatible) { refused = $0 != nil }
                try drain(document)
                expect(refused && (try Data(contentsOf: exportPath)) == bytes
                       && document.lastExportSettings == exportSettings,
                       "incompatible export refuses and preserves prior file and settings")
            }
            expect(try pixels(image) == exportBefore && document.undoInfo.undoCount == exportUndo
                   && document.hasUnsavedChanges == exportDirty,
                   "native export leaves displayed pixels, Undo and dirty state unchanged")

            let savePath = work.appendingPathComponent("cmyk-\(component.rawValue).xcf")
            try drain(document)
            try session.save(image, to: savePath.path)
            let reopened = try session.openImage(path: savePath.path)
            nativeOnly.append(reopened)
            let reopenedController = try attach(reopened, name: "Reopened CMYK \(component.title)")
            let reopenedDoc = reopenedController.imageDocument
            expect(reopenedDoc.colorInfo.mode == .cmyk, "reopened CMYK document preserves mode")
            expect(reopenedDoc.colorInfo.component == component, "reopened CMYK document preserves precision")
            expect(reopenedDoc.channels.count == document.channels.count, "reopened CMYK document preserves channel count")
            expect(reopenedDoc.channels.map(\.name) == document.channels.map(\.name), "reopened CMYK document preserves channel names")
            expect(reopenedDoc.colorInfo.hasEmbeddedProfile, "reopened CMYK document keeps embedded profile")
            expect(reopenedDoc.colorInfo.profileLabel == document.colorInfo.profileLabel,
                   "reopened CMYK document preserves profile label baseline")
            let savedPixels = try pixels(image)
            expect(try pixels(reopened) == savedPixels, "reopened CMYK XCF preserves exact full render bytes")
            expect(unexpectedErrors.isEmpty, "all CMYK document operations complete without unexpected errors")

            if component == .u8, let artifacts = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"] {
                let dir = URL(fileURLWithPath: artifacts)
                if let view = controller.window?.contentView,
                   let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.layoutSubtreeIfNeeded()
                    view.cacheDisplay(in: view.bounds, to: rep)
                    try rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("cmyk-window.png"))
                }
                let canvas = controller.canvas
                if let canvasRep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) {
                    canvas.layoutSubtreeIfNeeded()
                    canvas.cacheDisplay(in: canvas.bounds, to: canvasRep)
                    try canvasRep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("cmyk-canvas.png"))
                }
            }
        }
    }

    private static func requirePixel(_ session: EngineSession, _ image: Int32, x: Int, y: Int) throws -> [UInt8] {
        guard let value = pixel(session, image, x: x, y: y) else {
            throw NSError(domain: "CmykSmoke", code: 20, userInfo: [NSLocalizedDescriptionKey: "Missing pixel \(x),\(y)"])
        }
        return value
    }

    private static func requireIndex(_ index: Int?, _ message: String) throws -> Int {
        guard let index else {
            throw NSError(domain: "CmykSmoke", code: 21, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return index
    }
}
