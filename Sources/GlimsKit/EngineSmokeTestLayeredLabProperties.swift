import AppKit
import RigiUI

extension EngineSmokeTest {
    static func exerciseLayeredLabProperties(session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        guard let path = ProcessInfo.processInfo.environment["GLIMS_LAYERED_LAB_FIXTURE"],
              !path.isEmpty else {
            throw NSError(domain: "LayeredLabSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing layered Lab fixture path"])
        }
        let image = try session.openImage(path: path)
        var document: ImageDocument?
        var controller: DocumentWindowController?
        let palette = LayersPaletteController()
        let paletteWindow = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 260, height: 300),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        paletteWindow.isReleasedWhenClosed = false
        defer {
            palette.retarget(to: nil)
            paletteWindow.orderOut(nil)
            paletteWindow.close()
            if let window = controller?.window, let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                sheet.orderOut(nil)
            }
            if let controller, !controller.closeStarted { controller.closeDiscardingChanges() }
            if let document {
                if controller == nil && !document.isClosing { document.closeImageWhenDrained() }
                let deadline = Date().addingTimeInterval(15)
                while (try? session.info(image)) != nil && Date() < deadline {
                    EngineSmokeTestHost.pumpEvents(for: 0.02)
                }
                check((try? session.info(image)) == nil, "layered Lab document closes")
                documents.items.removeAll { $0 === document }
            } else {
                try? session.closeImage(image)
            }
        }
        let opened = try ImageDocument(session: session, image: image, name: "Layered Lab",
                                       openedFrom: URL(fileURLWithPath: path))
        document = opened
        documents.items.append(opened)
        let windowController = DocumentWindowController(document: opened, exportDirectory: work)
        controller = windowController
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        paletteWindow.contentView = palette.view
        palette.retarget(to: opened)
        paletteWindow.orderFront(nil)
        EngineSmokeTestHost.pumpEvents(for: 0.2)
        check(windowController.window?.title.contains("Limited editing") == true,
              "document window identifies limited editing")
        let selectAll = NSMenuItem(title: "Select All", action: #selector(DocumentWindowController.selectAll(_:)), keyEquivalent: "")
        check(windowController.validateMenuItem(selectAll) == opened.storage.allowsLabSelections,
              "Select All follows the layered Lab selection capability")
        let saveCopy = NSMenuItem(title: "Save a Copy", action: #selector(DocumentWindowController.saveDocumentCopy(_:)), keyEquivalent: "")
        check(windowController.validateMenuItem(saveCopy), "Save a Copy stays available")
        check(opened.storage.layout == .layeredLab && opened.storage.allowsLayerProperties,
              "document recognizes limited layered Lab editing")
        check(!opened.acceptsEdits && opened.acceptsLayerSelection,
              "layer selection remains available while editing is disabled")
        check(opened.acceptsLayerProperties, "layer properties are available")
        check(opened.colorInfo.mode == .lab && opened.labAxes == nil && opened.channels.isEmpty,
              "document does not expose private Lab planes as channels")
        check(opened.layers.count == 2, "document shows two logical layers")
        check(opened.toolIsAvailable(.paintbrush) == opened.storage.allowsLabLayerBrush && opened.toolIsAvailable(.zoom),
              "Brush follows its layered Lab capability while zoom remains available")
        let originalTool = ToolState.shared.current
        defer { ToolState.shared.select(originalTool) }
        let toolPalette = ToolsPaletteController()
        _ = toolPalette.view
        let flatImage = try session.newLabImage(width: 4, height: 4, component: .u8)
        let flatDocument: ImageDocument
        do { flatDocument = try ImageDocument(session: session, image: flatImage, name: "Flat Lab") }
        catch { try? session.closeImage(flatImage); throw error }
        defer {
            toolPalette.retarget(to: nil)
            flatDocument.closeImageWhenDrained()
            let deadline = Date().addingTimeInterval(15)
            while (try? session.info(flatImage)) != nil && Date() < deadline {
                EngineSmokeTestHost.pumpEvents(for: 0.02)
            }
            check((try? session.info(flatImage)) == nil, "flat Lab palette fixture closes")
        }
        toolPalette.retarget(to: flatDocument)
        toolPalette.retarget(to: opened)
        if let grid = toolPalette.view.subviews.compactMap({ $0 as? ClassicToolGrid }).first {
            let enabled = grid.slots.flatMap(\.tools).first { $0.id == ToolID.rectangleSelect.rawValue }?.isEnabled
            check(enabled == opened.storage.allowsLabSelections,
                  "Tools palette updates selection availability when switching between Lab layouts")
            let brushEnabled = grid.slots.flatMap(\.tools).first { $0.id == ToolID.paintbrush.rawValue }?.isEnabled
            check(brushEnabled == opened.storage.allowsLabLayerBrush,
                  "Tools palette updates Brush availability for the layered Lab layout")
        } else { check(false, "Tools palette contains its tool grid") }
        func drain(_ step: String) {
            let deadline = Date().addingTimeInterval(15)
            while opened.pendingWork > 0 && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
            check(opened.pendingWork == 0, "engine work finishes after \(step)")
        }
        if opened.storage.allowsLabSelections {
            check(opened.toolIsAvailable(.rectangleSelect) && opened.toolIsAvailable(.ellipseSelect) &&
                  opened.toolIsAvailable(.lasso), "layered Lab selection tools are available")
            windowController.selectAll(nil)
            drain("Select All")
            check(opened.selectionBounds == CGRect(x: 0, y: 0, width: 4, height: 4),
                  "Select All changes the layered Lab root mask")
            let undo = EngineUndoManager(document: opened)
            check(undo.canUndo, "layered Lab selection offers Undo")
            undo.undo(); drain("selection Undo")
            check(opened.selectionBounds == nil, "Undo restores the empty selection")
            let state = ToolState.shared
            let oldTool = state.current, oldOptions = state.selectOptions
            defer { state.selectOptions = oldOptions; state.select(oldTool) }
            state.selectOptions = EngineSession.SelectOptions()
            state.select(.rectangleSelect)
            if let window = windowController.window {
                let canvas = windowController.canvas
                func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
                    NSEvent.mouseEvent(with: type,
                        location: canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                if let down = mouse(.leftMouseDown, CGPoint(x: 1, y: 1)),
                   let drag = mouse(.leftMouseDragged, CGPoint(x: 3, y: 3)),
                   let up = mouse(.leftMouseUp, CGPoint(x: 3, y: 3)) {
                    canvas.mouseDown(with: down); canvas.mouseDragged(with: drag); canvas.mouseUp(with: up)
                    drain("rectangle selection gesture")
                    check(opened.selectionBounds == CGRect(x: 1, y: 1, width: 2, height: 2),
                          "canvas rectangle gesture edits the layered Lab selection")
                    undo.undo(); drain("rectangle selection Undo")
                    check(opened.selectionBounds == nil, "Undo removes the canvas selection")
                } else { check(false, "canvas selection events can be created") }
            } else { check(false, "layered Lab window exists for selection gesture") }
            try opened.startRecording()
            check(!windowController.validateMenuItem(selectAll), "layered Lab selection is disabled while recording")
            windowController.selectAll(nil); drain("selection refusal during recording")
            check(opened.selectionBounds == nil && opened.recorder.records.isEmpty,
                  "a direct selection action during recording changes neither mask nor recording")
            try opened.stopRecording()
        } else {
            check(!opened.toolIsAvailable(.rectangleSelect), "older engines keep layered Lab selection disabled")
        }
        let fillMenu = NSMenuItem(title: "Fill", action: #selector(DocumentWindowController.fill(_:)), keyEquivalent: "")
        check(windowController.validateMenuItem(fillMenu) == opened.storage.allowsLabLayerColorFill,
              "Fill menu follows the layered Lab color capability")
        if opened.storage.allowsLabLayerColorFill, let window = windowController.window,
           let originalRoot = opened.selectedLayerIDs.first {
            let oldForeground = ToolState.shared.foreground
            defer { ToolState.shared.foreground = oldForeground }
            ToolState.shared.foreground = .red
            let beforeRecording = pixel(session, image, x: 1, y: 1)
            let previousError = opened.onError
            var recordingErrors: [String] = []
            opened.onError = { recordingErrors.append($0) }
            try opened.startRecording()
            check(!windowController.validateMenuItem(fillMenu), "Lab Fill is disabled while recording")
            windowController.fill(nil)
            EngineSmokeTestHost.pumpEvents(for: 0.1); drain("Lab Fill refusal during recording")
            check(!recordingErrors.isEmpty && window.attachedSheet == nil &&
                  pixel(session, image, x: 1, y: 1) == beforeRecording && opened.recorder.records.isEmpty,
                  "Lab Fill during recording changes nothing and opens no sheet")
            try opened.stopRecording()
            opened.onError = previousError
            func waitForSheet() -> NSWindow? {
                let deadline = Date().addingTimeInterval(15)
                while window.attachedSheet == nil && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                return window.attachedSheet
            }
            opened.select(.rectangle(CGRect(x: 1, y: 1, width: 2, height: 2)), options: .init())
            drain("fill selection")
            let insideBefore = pixel(session, image, x: 1, y: 1)
            let outsideBefore = pixel(session, image, x: 0, y: 0)
            windowController.fill(nil)
            if let sheet = waitForSheet() {
                check(true, "captured Lab layer Fill sheet opens")
                window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                EngineSmokeTestHost.pumpEvents(for: 0.1); drain("Lab color fill")
                let insideAfter = pixel(session, image, x: 1, y: 1)
                check(insideAfter?.count == 4 && (insideAfter?[0] ?? 0) > 245 &&
                      (insideAfter?[1] ?? 255) < 20 && (insideAfter?[2] ?? 255) < 20 &&
                      pixel(session, image, x: 0, y: 0) == outsideBefore,
                      "foreground Fill changes only selected pixels to red")
                let undo = EngineUndoManager(document: opened)
                check(undo.canUndo, "Lab color fill offers Undo")
                undo.undo(); drain("Lab color fill Undo")
                check(pixel(session, image, x: 1, y: 1) == insideBefore, "Undo restores pixels before Lab color fill")
                undo.redo(); drain("Lab color fill Redo")
                check(pixel(session, image, x: 1, y: 1) == insideAfter, "Redo restores the Lab color fill")
                undo.undo(); drain("restore pixels after Lab color fill")
                undo.undo(); drain("restore selection after Lab color fill")
                check(opened.selectionBounds == nil, "fill fixture restores its empty selection")
            } else { check(false, "captured Lab layer Fill sheet opens") }
            let beforeCancel = pixel(session, image, x: 1, y: 1)
            windowController.fill(nil)
            if let sheet = waitForSheet() {
                window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                EngineSmokeTestHost.pumpEvents(for: 0.1); drain("cancel Lab Fill")
                check(pixel(session, image, x: 1, y: 1) == beforeCancel, "Cancel leaves Lab pixels unchanged")
            } else { check(false, "Lab Fill sheet opens for cancellation") }
            if let other = opened.layers.first(where: { $0.id != originalRoot }) {
                var errors: [String] = []
                let oldError = opened.onError
                opened.onError = { errors.append($0) }
                windowController.fill(nil)
                if let sheet = waitForSheet() {
                    opened.selectLayer(other.id); drain("retarget while Fill is open")
                    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    EngineSmokeTestHost.pumpEvents(for: 0.1); drain("refuse retargeted Lab Fill")
                    check(!errors.isEmpty && pixel(session, image, x: 1, y: 1) == beforeCancel,
                          "Fill refuses a layer changed while its sheet was open")
                    opened.selectLayer(originalRoot); drain("restore captured layer")
                } else { check(false, "Lab Fill sheet opens for retarget test") }
                opened.onError = oldError
            }
        }
        if opened.storage.allowsLabLayerBrush, let window = windowController.window {
            let state = ToolState.shared
            let oldTool = state.current, oldForeground = state.foreground, oldBrush = state.brush(for: .paintbrush)
            defer { state.foreground = oldForeground; state.update(.paintbrush) { $0 = oldBrush }; state.select(oldTool) }
            state.foreground = .red
            state.update(.paintbrush) { $0.size = 4; $0.opacity = 1; $0.hardness = 1; $0.resource = nil }
            state.select(.paintbrush)
            let options = ToolOptionsPaletteController()
            _ = options.view
            options.retarget(to: flatDocument); options.retarget(to: opened)
            defer { options.retarget(to: nil) }
            func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            let optionViews = descendants(options.view)
            let optionText = optionViews.compactMap { ($0 as? NSTextField)?.stringValue }
            let pressure = optionViews.compactMap { $0 as? NSButton }.first { $0.title == "Pen pressure sets size" }
            check(optionText.contains(where: { $0.contains("foreground color") }) &&
                  !optionText.contains(where: { $0.contains("Select one Lab channel") }) && pressure?.isEnabled == false,
                  "layered Brush options show foreground color and fixed pressure behavior")
            let oldError = opened.onError
            var errors: [String] = []
            opened.onError = { errors.append($0) }
            defer { opened.onError = oldError }
            let oldProjection = opened.onProjectionChange
            var brushDamage: [CGRect] = []
            opened.onProjectionChange = { rect in brushDamage.append(rect); oldProjection?(rect) }
            defer { opened.onProjectionChange = oldProjection }
            let before = pixel(session, image, x: 1, y: 1)
            try opened.startRecording()
            opened.beginStroke(at: .init(x: 1.5, y: 1.5), brush: state.brush(for: .paintbrush))
            check(!opened.strokeIsActive && !errors.isEmpty && opened.recorder.records.isEmpty,
                  "layered Lab Brush refuses recording without starting a gesture")
            try opened.stopRecording(); errors.removeAll()
            opened.select(.rectangle(CGRect(x: 1, y: 1, width: 2, height: 2)), options: .init())
            drain("brush selection")
            let outside = pixel(session, image, x: 0, y: 0)
            let canvas = windowController.canvas
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type,
                    location: canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let down = mouse(.leftMouseDown, CGPoint(x: 1.5, y: 1.5)),
               let drag = mouse(.leftMouseDragged, CGPoint(x: 2.5, y: 1.5)),
               let up = mouse(.leftMouseUp, CGPoint(x: 2.5, y: 1.5)) {
                brushDamage.removeAll()
                canvas.mouseDown(with: down); canvas.mouseDragged(with: drag); canvas.mouseUp(with: up)
                drain("layered Lab canvas Brush gesture")
                let painted = pixel(session, image, x: 1, y: 1)
                if !errors.isEmpty || painted == before || pixel(session, image, x: 0, y: 0) != outside {
                    print("BRUSH_DIAGNOSTIC errors=\(errors) before=\(String(describing: before)) painted=\(String(describing: painted)) outside=\(String(describing: outside)) outsideAfter=\(String(describing: pixel(session, image, x: 0, y: 0)))")
                }
                check(errors.isEmpty && painted != before && pixel(session, image, x: 0, y: 0) == outside,
                      "canvas Brush paints selected pixels and preserves outside pixels")
                check(brushDamage.contains(where: { $0.contains(CGPoint(x: 1, y: 1)) }),
                      "canvas receives brush damage for the painted pixel")
                let undo = EngineUndoManager(document: opened)
                check(undo.canUndo, "layered Lab Brush offers Undo")
                undo.undo(); drain("layered Lab Brush Undo")
                check(pixel(session, image, x: 1, y: 1) == before, "Undo restores the canvas Brush stroke")
                undo.redo(); drain("layered Lab Brush Redo")
                check(pixel(session, image, x: 1, y: 1) == painted, "Redo restores the canvas Brush stroke")
                undo.undo(); drain("restore canvas Brush pixels")
                undo.undo(); drain("restore canvas Brush selection")
            } else { check(false, "layered Lab Brush events can be created") }
            if let down = mouse(.leftMouseDown, CGPoint(x: 1.5, y: 1.5)),
               let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53) {
                let undoBefore = try? session.undoInfo(image)
                canvas.mouseDown(with: down); drain("begin canvas Brush cancellation")
                if !opened.labBrushStrokeIsActive || pixel(session, image, x: 1, y: 1) == before {
                    print("BRUSH_CANCEL_DIAGNOSTIC active=\(opened.labBrushStrokeIsActive) errors=\(errors) before=\(String(describing: before)) after=\(String(describing: pixel(session, image, x: 1, y: 1)))")
                }
                check(opened.labBrushStrokeIsActive && pixel(session, image, x: 1, y: 1) != before,
                      "cancellation fixture begins a visible Brush stroke")
                brushDamage.removeAll()
                window.makeFirstResponder(canvas); canvas.keyDown(with: escape)
                drain("cancel canvas Brush with Escape")
                let undoAfter = try? session.undoInfo(image)
                check(undoBefore != nil && undoAfter != nil && !opened.strokeIsActive && pixel(session, image, x: 1, y: 1) == before &&
                      undoBefore?.undoCount == undoAfter?.undoCount && undoBefore?.redoCount == undoAfter?.redoCount,
                      "Escape restores the canvas Brush pixels and history")
                check(brushDamage.contains(where: { $0.contains(CGPoint(x: 1, y: 1)) }),
                      "Escape invalidates the restored canvas pixels")
                let rapidUndo = try? session.undoInfo(image)
                let entered = DispatchSemaphore(value: 0)
                let release = DispatchSemaphore(value: 0)
                opened.inputQueue.async { entered.signal(); _ = release.wait(timeout: .now() + 20) }
                let held = entered.wait(timeout: .now() + 3) == .success
                canvas.mouseDown(with: down)
                let accepted = opened.labBrushStrokeIsActive
                canvas.keyDown(with: escape)
                release.signal()
                drain("cancel queued canvas Brush immediately")
                let rapidAfter = try? session.undoInfo(image)
                check(held && accepted && rapidUndo != nil && rapidAfter != nil && !opened.strokeIsActive &&
                      pixel(session, image, x: 1, y: 1) == before && rapidUndo == rapidAfter,
                      "immediate Escape cancels a queued Brush begin without a history change")
            } else { check(false, "canvas Brush cancellation events can be created") }
        }
        func outline(in view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            return view.subviews.lazy.compactMap { outline(in: $0) }.first
        }
        if let other = opened.layers.first(where: { !opened.selectedLayerIDs.contains($0.id) }),
           let list = outline(in: palette.view),
           let row = (0..<list.numberOfRows).first(where: { index in
               guard let node = list.item(atRow: index) as? LayerTree.Node else { return false }
               return node.layer.id == other.id
           }), let item = list.item(atRow: row) {
            check(palette.outlineView(list, shouldSelectItem: item), "palette permits a logical layer pick")
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let deadline = Date().addingTimeInterval(15)
            while opened.pendingWork > 0 && Date() < deadline {
                EngineSmokeTestHost.pumpEvents(for: 0.02)
            }
            check(opened.selectedLayerIDs == [other.id] && (try? session.selectedLayers(image)) == [other.id],
                  "logical layer selection reaches the engine")
        } else {
            check(false, "fixture has a second selectable layer")
        }
        if let list = outline(in: palette.view), let first = opened.layers.first,
           let index = (0..<list.numberOfRows).first(where: { index in
               (list.item(atRow: index) as? LayerTree.Node)?.layer.id == first.id
           }), let row = list.view(atColumn: 0, row: index, makeIfNecessary: true) as? LayerRowView {
            check(row.checkbox.isEnabled, "logical layer visibility control is enabled")
            let initiallyVisible = first.isVisible
            row.checkbox.performClick(nil)
            drain("visibility edit")
            check(opened.layers.first(where: { $0.id == first.id })?.isVisible == !initiallyVisible,
                  "visibility control changes the captured logical layer")
            let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "")
            check(windowController.window?.validateMenuItem(undo) == true, "window Undo is available after the layer edit")
            check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                  "window responder handles Undo")
            drain("visibility Undo")
            check(opened.layers.first(where: { $0.id == first.id })?.isVisible == initiallyVisible,
                  "Undo restores logical visibility")
            let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "")
            check(windowController.window?.validateMenuItem(redo) == true, "window Redo is available after Undo")
            check(windowController.window?.tryToPerform(Selector(("redo:")), with: redo) == true,
                  "window responder handles Redo")
            drain("visibility Redo")
            check(opened.layers.first(where: { $0.id == first.id })?.isVisible == !initiallyVisible,
                  "Redo reapplies logical visibility")
            check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                  "window responder handles a second Undo")
            drain("second visibility Undo")
            check(opened.layers.first(where: { $0.id == first.id })?.isVisible == initiallyVisible,
                  "second Undo restores logical visibility")
        } else {
            check(false, "logical layer visibility control exists")
        }
        if let list = outline(in: palette.view), let first = opened.layers.first,
           let index = (0..<list.numberOfRows).first(where: { index in
               (list.item(atRow: index) as? LayerTree.Node)?.layer.id == first.id
           }), let row = list.view(atColumn: 0, row: index, makeIfNecessary: true) as? LayerRowView {
            if opened.storage.allowsLayerRename {
                check(row.nameField.isEditable, "logical layer name is editable when advertised")
                let originalName = first.name
                row.nameField.stringValue = "Retouched Lab"
                row.finishNameEditing()
                drain("layer rename")
                check(opened.layers.first(where: { $0.id == first.id })?.name == "Retouched Lab",
                      "palette rename reaches the logical layer")
                let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "")
                let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "")
                check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                      "window handles rename Undo")
                drain("rename Undo")
                check(opened.layers.first(where: { $0.id == first.id })?.name == originalName,
                      "Undo restores logical layer name")
                check(windowController.window?.tryToPerform(Selector(("redo:")), with: redo) == true,
                      "window handles rename Redo")
                drain("rename Redo")
                check(opened.layers.first(where: { $0.id == first.id })?.name == "Retouched Lab",
                      "Redo restores logical layer name")
                check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                      "window restores original layer name")
                drain("restore layer name")
                check(opened.layers.first(where: { $0.id == first.id })?.name == originalName,
                      "final Undo restores the original layer name")
            } else {
                check(!row.nameField.isEditable, "logical layer name stays disabled on older engines")
                var rejected = false
                opened.changeLayer(first.id, .init(name: "Must not change")) { result in
                    if case .failure = result { rejected = true }
                }
                drain("legacy rename refusal")
                check(rejected && opened.layers.first(where: { $0.id == first.id })?.name == first.name,
                      "older engine refuses rename without changing the layer")
            }
        } else {
            check(false, "logical layer name control exists")
        }
        // This standalone palette is not registered with PaletteCenter, so
        // mirror the normal retarget/reload after the selection and undo.
        palette.reload()
        EngineSmokeTestHost.pumpEvents(for: 0.05)
        func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, as: type) }
        }
        let duplicateMenu = NSMenuItem(title: "Duplicate Layer", action: #selector(DocumentWindowController.duplicateLayer(_:)), keyEquivalent: "")
        let duplicateButton = descendants(palette.view, as: NSButton.self).first { $0.accessibilityLabel() == "Duplicate Layers" }
        if opened.storage.allowsLayerDuplicate {
            check(windowController.validateMenuItem(duplicateMenu), "Layer menu enables logical duplication")
            check(duplicateButton?.isEnabled == true, "palette enables logical duplication")
            let originalIDs = opened.layers.map(\.id)
            duplicateButton?.performClick(nil)
            drain("logical layer duplicate")
            let copiedIDs = Set(opened.layers.map(\.id)).subtracting(originalIDs)
            check(opened.layers.count == originalIDs.count + 1 && Set(originalIDs).isSubset(of: Set(opened.layers.map(\.id))),
                  "palette duplicates one logical layer")
            check(copiedIDs.count == 1 && Set(opened.selectedLayerIDs) == copiedIDs,
                  "the palette follows the newly duplicated logical layer")
            let undo = EngineUndoManager(document: opened)
            check(undo.canUndo, "logical duplication offers Undo")
            undo.undo()
            drain("logical duplication Undo")
            check(opened.layers.map(\.id) == originalIDs, "Undo restores the original logical layers")
            check(undo.canRedo, "logical duplication offers Redo")
            undo.redo()
            drain("logical duplication Redo")
            check(opened.layers.count == originalIDs.count + 1 && Set(originalIDs).isSubset(of: Set(opened.layers.map(\.id))) &&
                  Set(opened.selectedLayerIDs) == copiedIDs, "Redo restores and selects the logical copy")
            undo.undo()
            drain("restore original layers")
            check(opened.layers.map(\.id) == originalIDs, "final Undo restores the original layer tree")
        } else {
            check(!windowController.validateMenuItem(duplicateMenu) && duplicateButton?.isEnabled == false,
                  "older engines keep logical duplication disabled")
        }
        palette.reload()
        let newMenu = NSMenuItem(title: "New Layer", action: #selector(DocumentWindowController.newLayer(_:)), keyEquivalent: "")
        let newButton = descendants(palette.view, as: NSButton.self).first { $0.accessibilityLabel() == "New Layer" }
        if opened.storage.allowsLayerCreate {
            check(windowController.validateMenuItem(newMenu), "Layer menu enables logical layer creation")
            check(newButton?.isEnabled == true, "palette enables logical layer creation")
            let originalIDs = opened.layers.map(\.id)
            newButton?.performClick(nil)
            drain("new logical layer")
            check(opened.layers.count == 3 && Set(originalIDs).isSubset(of: Set(opened.layers.map(\.id))),
                  "palette creates one logical layer")
            let undo = EngineUndoManager(document: opened)
            check(undo.canUndo, "logical layer creation offers Undo")
            undo.undo()
            drain("new layer Undo")
            check(opened.layers.map(\.id) == originalIDs, "Undo restores the original layer tree")
            check(undo.canRedo, "logical layer creation offers Redo")
            undo.redo()
            drain("new layer Redo")
            check(opened.layers.count == 3, "Redo restores the new logical layer")
            undo.undo()
            drain("restore original layers after creation")
            check(opened.layers.map(\.id) == originalIDs, "final Undo removes the new logical layer")
        } else {
            check(!windowController.validateMenuItem(newMenu) && newButton?.isEnabled == false,
                  "older engines keep logical layer creation disabled")
        }
        palette.reload()
        let deleteMenu = NSMenuItem(title: "Delete Layer", action: #selector(DocumentWindowController.deleteLayer(_:)), keyEquivalent: "")
        let deleteButton = descendants(palette.view, as: NSButton.self).first { $0.accessibilityLabel() == "Delete Layers" }
        if opened.storage.allowsLayerDelete {
            check(windowController.validateMenuItem(deleteMenu), "Layer menu enables logical layer deletion")
            check(deleteButton?.isEnabled == true, "palette enables logical layer deletion")
            let originalIDs = opened.layers.map(\.id)
            deleteButton?.performClick(nil)
            drain("delete logical layer")
            check(opened.layers.count == 1 && Set(opened.layers.map(\.id)).isSubset(of: Set(originalIDs)),
                  "palette deletes one logical layer")
            let undo = EngineUndoManager(document: opened)
            check(undo.canUndo, "logical deletion offers Undo")
            undo.undo()
            drain("logical deletion Undo")
            check(opened.layers.map(\.id) == originalIDs, "Undo restores both logical layers")
            check(undo.canRedo, "logical deletion offers Redo")
            undo.redo()
            drain("logical deletion Redo")
            check(opened.layers.count == 1, "Redo removes the same logical layer")
            undo.undo()
            drain("restore original layers after deletion")
            check(opened.layers.map(\.id) == originalIDs, "final Undo restores both logical layers")
        } else {
            check(!windowController.validateMenuItem(deleteMenu) && deleteButton?.isEnabled == false,
                  "older engines keep logical deletion disabled")
        }
        palette.reload()
        let backward = NSMenuItem(title: "Send Backward", action: #selector(DocumentWindowController.sendLayerBackward(_:)), keyEquivalent: "")
        let forward = NSMenuItem(title: "Bring Forward", action: #selector(DocumentWindowController.bringLayerForward(_:)), keyEquivalent: "")
        if opened.storage.allowsLayerReorder, let selected = opened.selectedLayerIDs.first {
            let originalIDs = opened.layers.map(\.id)
            let movingDown = originalIDs.first == selected
            let item = movingDown ? backward : forward
            check(windowController.validateMenuItem(item), "Layer menu enables logical reorder")
            if movingDown { windowController.sendLayerBackward(item) }
            else { windowController.bringLayerForward(item) }
            drain("logical reorder")
            check(opened.layers.map(\.id) == Array(originalIDs.reversed()) && opened.selectedLayerIDs == [selected],
                  "reorder changes logical order while retaining selection")
            let undo = EngineUndoManager(document: opened)
            check(undo.canUndo, "logical reorder offers Undo")
            undo.undo()
            drain("logical reorder Undo")
            check(opened.layers.map(\.id) == originalIDs, "Undo restores logical layer order")
            check(undo.canRedo, "logical reorder offers Redo")
            undo.redo()
            drain("logical reorder Redo")
            check(opened.layers.map(\.id) == Array(originalIDs.reversed()), "Redo restores logical layer order")
            undo.undo()
            drain("restore original layer order")
            check(opened.layers.map(\.id) == originalIDs, "final Undo restores original layer order")
        } else {
            check(!windowController.validateMenuItem(backward) && !windowController.validateMenuItem(forward),
                  "older engines keep logical reordering disabled")
        }
        palette.reload()
        var editedOpacity = -1.0 // No valid layer opacity can satisfy the saved-copy check until an edit runs.
        if let target = opened.activeLayer,
           let opacity = descendants(palette.view, as: ClassicValueSlider.self).first(where: { $0.accessibilityTitle == "Layer opacity" }),
           let field = descendants(opacity, as: NSTextField.self).first(where: { $0.isEditable }),
           let originalOpacity = opened.layers.first(where: { $0.id == target })?.opacity {
            check(opacity.isEnabled, "logical layer opacity control is enabled")
            editedOpacity = abs(originalOpacity - 0.5) < 0.0001 ? 0.75 : 0.5
            field.stringValue = editedOpacity == 0.5 ? "50" : "75"
            check(field.sendAction(field.action, to: field.target), "opacity field action is delivered")
            drain("opacity edit")
            check(abs((opened.layers.first(where: { $0.id == target })?.opacity ?? -1) - editedOpacity) < 0.0001,
                  "opacity field changes the captured logical layer")
            let manager = EngineUndoManager(document: opened)
            check(manager.canUndo, "Undo is available after the opacity edit")
            manager.undo()
            drain("opacity Undo")
            check(abs((opened.layers.first(where: { $0.id == target })?.opacity ?? -1) - originalOpacity) < 0.0001,
                  "Undo restores logical layer opacity")
            check(manager.canRedo, "Redo is available after opacity Undo")
            manager.redo()
            drain("opacity Redo")
            check(abs((opened.layers.first(where: { $0.id == target })?.opacity ?? -1) - editedOpacity) < 0.0001,
                  "Redo reapplies logical layer opacity")
        } else {
            check(false, "logical layer opacity field exists")
        }
        let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 1, height: 1))
        check(rendered.width == 1 && rendered.height == 1, "layered Lab canvas renders")
        let copy = work.appendingPathComponent("layered-copy.xcf")
        var copyFinished = false
        var copyError: Error?
        opened.saveCopy(to: copy) { error in copyError = error; copyFinished = true }
        let saveDeadline = Date().addingTimeInterval(30)
        while !copyFinished && Date() < saveDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
        guard copyFinished, copyError == nil else {
            throw copyError ?? NSError(domain: "LayeredLabSmoke", code: 2,
                                       userInfo: [NSLocalizedDescriptionKey: "Save copy did not finish"])
        }
        check(true, "document saves an XCF copy")
        let reopened = try session.openImage(path: copy.path)
        defer { try? session.closeImage(reopened) }
        check(try session.imageStorage(reopened).layout == .layeredLab,
              "saved XCF copy reopens as layered Lab")
        check(try session.layers(reopened).contains(where: { abs($0.opacity - editedOpacity) < 0.0001 }),
              "saved XCF copy retains the edited opacity")
    }
}
