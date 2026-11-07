import AppKit
import Darwin
import RigiUI

/// `--engine-smoke-test`: drives a document end to end through the same code
/// the interface uses, with the engine named by `GLIMS_ENGINE_LIBRARY` and
/// throwaway directories, then measures how a plug-in-heavy workload affects
/// the main thread (phase 0 go criterion 6). Prints one line per check and
/// returns 0 only if all pass.
@MainActor
enum EngineSmokeTest {
    /// Criterion 6: a plug-in call never stalls the interface longer than this.
    static let maximumMainThreadStallMilliseconds = 100.0
    nonisolated static let pluginCalls = 100

    private static var failures = 0

    private static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "ok  " : "FAIL") \(message)")
        fflush(stdout)
        if !condition { failures += 1 }
    }

    private nonisolated static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }

    /// Lets queued main-queue work (engine events) run.
    private static func spin(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private struct NoWindow: Error {}

    private static func XCTUnwrapWindow(_ controller: DocumentWindowController) throws -> NSWindow {
        guard let window = controller.window else { throw NoWindow() }
        return window
    }

    /// How bright the canvas draws `point` (image pixels at the canvas's
    /// zoom), from the view's own drawing.
    private static func canvasBrightness(_ canvas: EngineCanvasView, at point: CGPoint) -> Double? {
        let viewPoint = CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale)
        guard canvas.bounds.contains(viewPoint),
              let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let factor = Double(rep.pixelsWide) / Double(canvas.bounds.width)
        // The canvas is flipped, like the bitmap's rows: no y flip.
        return (rep.colorAt(x: Int(viewPoint.x * factor), y: Int(viewPoint.y * factor))?
            .usingColorSpace(.genericGray)?.whiteComponent).map(Double.init)
    }

    private static func pixel(_ session: EngineSession, _ image: Int32, x: Int, y: Int) -> [UInt8]? {
        guard let rendered = try? session.render(image, scale: 1, area: CGRect(x: x, y: y, width: 1, height: 1)),
              let data = rendered.dataProvider?.data as Data? else { return nil }
        return Array(data.prefix(4))
    }

    static func run() -> Int32 {
        guard let path = EngineLibrary.configuredPath() else {
            print("FAIL no engine library; set \(EngineLibrary.environmentVariable)")
            return 2
        }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("glims-engine-smoke-\(ProcessInfo.processInfo.processIdentifier)")
        try? FileManager.default.removeItem(at: work)
        defer { try? FileManager.default.removeItem(at: work) }

        // A reference, so engine events delivered while the checks run can read it.
        let documents = DocumentList()
        let session: EngineSession
        let start = DispatchTime.now()
        do {
            session = try EngineSession.start(api: EngineLibrary.load(path: path),
                                              userDirectory: work.appendingPathComponent("user"),
                                              cacheDirectory: work.appendingPathComponent("cache"),
                                              onEvent: { event in
                                                  if case .progress(let progress) = event {
                                                      documents.progressEvents.append(progress)
                                                  }
                                                  documents.items.forEach { $0.handle(event) }
                                              })
        } catch {
            print("FAIL engine start: \(error)")
            return 1
        }
        print("     engine \(session.version) started in \(Int(milliseconds(since: start))) ms")
        defer { session.stop() }

        do {
            try exerciseDocument(session, work: work, documents: documents)
            try exerciseFileSafety(session, work: work, documents: documents)
            try exerciseClipboard(session, documents: documents)
            try exerciseTools(session, documents: documents)
            try exerciseEditing(session, documents: documents)
            try exercisePaths(session, documents: documents)
            try exercisePaletteControls(session, documents: documents)
            try exercisePlugInCommands(session, documents: documents)
            try measurePluginStalls(session, work: work)
        } catch {
            check(false, "unexpected engine error: \(error)")
        }

        print(failures == 0 ? "PASSED" : "FAILED: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }

    /// Saving/closing must use the same asynchronous queues and sheets as
    /// real input. In particular a compile-only file-state test cannot prove
    /// that the last stroke reached the file or Cancel preserved the image.
    private static func exerciseFileSafety(_ session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        let image = try session.newImage(width: 64, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "File Safety")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let window = try XCTUnwrapWindow(controller)
        let directory = work.appendingPathComponent("file-safety")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let native = directory.appendingPathComponent("drawing.xcf")
        let exported = work.appendingPathComponent("file-safety.png")

        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin() }
        }
        var paintPosition = 15.0
        func paint() {
            paintPosition += 5
            document.beginStroke(at: .init(x: paintPosition, y: 20, pressure: 1))
            document.endStroke()
        }
        paint()
        var saved = false
        document.save(to: native) { error in
            if error == nil { document.noteSaved(to: native); saved = true }
        }
        wait { saved && document.pendingWork == 0 }
        check(saved && document.fileState.nativeURL == native && !document.hasUnsavedChanges,
              "saving queued input sets the native file and clears unsaved changes")
        let reopened = try session.openImage(path: native.path)
        check((pixel(session, reopened, x: 20, y: 20)?[0] ?? 255) < 128,
              "the saved XCF includes the last queued stroke")
        try session.closeImage(reopened)
        for suffix in ["xcf.gz", "xcf.bz2"] {
            let compressed = work.appendingPathComponent("compressed." + suffix)
            try session.save(image, to: compressed.path)
            let compressedImage = try session.openImage(path: compressed.path)
            check((try session.info(compressedImage)).width == 64 &&
                    DocumentFileState(openedFrom: compressed).saveRoute == .write(compressed),
                  "compressed \(suffix) saves, reopens and remains a native document")
            try session.closeImage(compressedImage)
        }

        paint()
        var exportedOK = false
        document.export(to: exported) { exportedOK = $0 == nil }
        wait { exportedOK && document.pendingWork == 0 }
        check(exportedOK && document.hasUnsavedChanges && document.fileState.nativeURL == native,
              "export preserves native identity and unsaved changes")
        controller.saveDocument(nil)
        wait { document.pendingWork == 0 }
        check(!document.hasUnsavedChanges && window.representedURL == native,
              "plain Save writes the current XCF without a save panel")

        let previousTool = ToolState.shared.current
        let previousText = ToolState.shared.textSettings
        ToolState.shared.textSettings.font = ToolState.pickableFontNames(try session.fonts()).first ?? "Sans-serif"
        ToolState.shared.textSettings.size = 12
        ToolState.shared.select(.text)
        if let press = NSEvent.mouseEvent(with: .leftMouseDown,
                                          location: controller.canvas.convert(CGPoint(x: 4, y: 4), to: nil),
                                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            controller.canvas.mouseDown(with: press)
            controller.canvas.tools.textEditor?.insertText("Saved text", replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.saveDocument(nil)
            wait { document.pendingWork == 0 }
            let savedImage = try session.openImage(path: native.path)
            let savedLayers = try session.layers(savedImage)
            check(controller.canvas.tools.textEditor == nil && savedLayers.contains(where: { $0.kind == .text }),
                  "Save commits text still being edited into the XCF")
            try session.closeImage(savedImage)
            controller.canvas.mouseDown(with: press)
            controller.canvas.tools.textEditor?.string = ""
            controller.saveDocument(nil)
            wait { document.pendingWork == 0 }
            let withoutText = try session.openImage(path: native.path)
            check(!(try session.layers(withoutText)).contains(where: { $0.kind == .text }),
                  "Save preserves deletion of all text in the active editor")
            try session.closeImage(withoutText)
        } else {
            check(false, "text editing can be started before Save")
        }
        ToolState.shared.textSettings = previousText
        ToolState.shared.select(previousTool)
        if let background = document.layers.last?.id { document.selectLayer(background) }
        paint()
        document.inputQueue.sync {}
        spin()
        var closeResult: Bool?
        controller.requestClose { closeResult = $0 }
        if let sheet = window.attachedSheet { NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertSecondButtonReturn.rawValue) }
        wait { closeResult != nil }
        check(closeResult == false && window.isVisible && !document.isClosing,
              "Cancel in the close prompt leaves the edited image open")

        // A native file's parent can disappear between saves. Save on close
        // must report failure and keep the edited image available.
        try FileManager.default.removeItem(at: directory)
        closeResult = nil
        controller.requestClose { closeResult = $0 }
        if let sheet = window.attachedSheet { NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        wait { closeResult != nil }
        check(closeResult == false && window.isVisible && document.hasUnsavedChanges,
              "a failed Save on close keeps the document and its dirty state")

        check(!document.isSavingForClose && document.acceptsEdits &&
                !controller.statusBar.message.hasPrefix("64 × 64 px"),
              "a failed close-save restores editing and keeps its error visible")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        controller.saveDocument(nil)
        wait { document.pendingWork == 0 }
        paint()
        document.inputQueue.sync {}
        spin()
        var attemptedEdit = false
        var rejectedEdit = false
        let stateChange = document.onStateChange
        document.onStateChange = {
            stateChange?()
            guard document.isSavingForClose, !attemptedEdit else { return }
            attemptedEdit = true
            let pending = document.pendingWork
            document.moveActiveLayer(by: CGSize(width: 10, height: 0))
            document.beginStroke(at: .init(x: 60, y: 60, pressure: 1))
            rejectedEdit = document.pendingWork == pending && !document.strokeIsActive
        }
        closeResult = nil
        controller.requestClose { closeResult = $0 }
        if let sheet = window.attachedSheet {
            NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        }
        wait { closeResult != nil }
        check(closeResult == true && attemptedEdit && rejectedEdit,
              "Save on close refuses later edits until the written image closes")
        check((try? session.info(image)) == nil, "the saved-and-closed image is destroyed after its work")
        documents.items.removeAll { $0 === document }

        let discardImage = try session.newImage(width: 64, height: 64)
        let discarded = try ImageDocument(session: session, image: discardImage, name: "Discard Stroke")
        documents.items.append(discarded)
        let discardController = DocumentWindowController(document: discarded)
        discardController.showWindow(nil)
        // The pointer may still be down when Close is invoked by a key.
        discarded.beginStroke(at: .init(x: 48, y: 20, pressure: 1))
        closeResult = nil
        discardController.requestClose { closeResult = $0 }
        if let sheet = discardController.window?.attachedSheet {
            NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue)
        }
        wait { closeResult != nil }
        check(closeResult == true && discarded.pendingWork == 0 && discarded.isClosing && !discarded.strokeIsActive,
              "Don't Save drains input and rendering before reporting the image closed")
        check((try? session.info(discardImage)) == nil, "the discarded image is destroyed after its queued work")
        var closedSaveFailed = false
        discarded.save(to: native) { closedSaveFailed = $0 != nil }
        check(closedSaveFailed, "a save requested after close reports an error through its completion")
        documents.items.removeAll { $0 === discarded }
    }

    private static func exerciseClipboard(_ session: EngineSession, documents: DocumentList) throws {
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let image = try session.newImage(width: 64, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Clipboard Source")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let source = ClipboardImage(width: 2, height: 2,
                                    pixels: Data([255, 0, 0, 255, 0, 255, 0, 128,
                                                  0, 0, 255, 255, 0, 0, 0, 0]),
                                    origin: CGPoint(x: 8, y: 10))
        try source.write(to: board)
        func waitForWork(_ item: ImageDocument) {
            let deadline = Date().addingTimeInterval(10)
            while item.pendingWork > 0 && Date() < deadline { spin() }
            spin()
        }
        controller.pasteImage(.originalPosition, from: board)
        waitForWork(document)
        check(document.layers.count == 2 && document.layers.first?.bounds == CGRect(x: 8, y: 10, width: 2, height: 2)
                && document.activeLayer == document.layers.first?.id,
              "Paste in Place creates and selects a layer at the clipboard's original position")
        var options = EngineSession.SelectOptions()
        options.antialias = false
        document.select(.rectangle(CGRect(x: 8, y: 10, width: 1, height: 1)), options: options)
        waitForWork(document)
        let undoBeforeCopy = document.undoInfo.undoCount
        controller.copyImage(.layer, to: board)
        // Text and path tools have synchronous metadata reads on this
        // queue. A clipboard worker must never wait for the main queue.
        _ = document.textLayer(document.activeLayer ?? 0)
        waitForWork(document)
        let copied = try ClipboardImage.read(from: board)
        check(copied.width == 1 && copied.height == 1 && copied.origin == CGPoint(x: 8, y: 10)
                && Array(copied.pixels) == [255, 0, 0, 255] && document.undoInfo.undoCount == undoBeforeCopy,
              "Copy writes selection pixels and origin to the system clipboard without an undo step")
        controller.copyImage(.cutLayer, to: board)
        waitForWork(document)
        let cut = try ClipboardImage.read(from: board)
        let cleared = try session.copyPixels(image, merged: false)
        check(Array(cut.pixels) == [255, 0, 0, 255] && cleared.pixels.last == 0
                && document.undoInfo.undoCount == undoBeforeCopy + 1,
              "Cut keeps the copied pixels and clears the selection as one undo step")
        document.undo()
        waitForWork(document)
        check((try session.copyPixels(image, merged: false)).pixels.last == 255,
              "Undo Cut restores the selected pixels")

        let targetImage = try session.newImage(width: 64, height: 64)
        let target = try ImageDocument(session: session, image: targetImage, name: "Clipboard Target")
        documents.items.append(target)
        let targetController = DocumentWindowController(document: target)
        targetController.showWindow(nil)
        targetController.pasteImage(.originalPosition, from: board)
        waitForWork(target)
        check(target.layers.count == 2 && target.undoInfo.undoCount == 1 &&
                (pixel(session, targetImage, x: 8, y: 10)?[0] ?? 0) == 255 &&
                (pixel(session, targetImage, x: 8, y: 10)?[1] ?? 255) == 0,
              "clipboard pixels paste into another document as an undoable independent layer")
        controller.window?.close()
        targetController.window?.close()
        let deadline = Date().addingTimeInterval(10)
        while ((try? session.info(image)) != nil || (try? session.info(targetImage)) != nil) && Date() < deadline { spin() }
        documents.items.removeAll { $0 === document || $0 === target }
    }

    private static func exerciseDocument(_ session: EngineSession, work: URL,
                                         documents: DocumentList) throws {
        let image = try session.newImage(width: 2400, height: 1600)
        let document = try ImageDocument(session: session, image: image, name: "Smoke")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.window?.orderFront(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        // Do not prime the cache here: the real window must request its
        // first tiles itself after AppKit has laid out the scroll view.
        controller.window?.displayIfNeeded()
        let firstDrawDeadline = Date().addingTimeInterval(5)
        while controller.canvas.renderedTileCount == 0 && Date() < firstDrawDeadline { spin() }
        check(controller.canvas.renderedTileCount > 0, "first draw schedules canvas tiles without a zoom command")
        let tilesRendered = try controller.canvas.renderVisibleTilesNow()
        check(controller.canvas.renderedTileCount > 0, "canvas has visible tiles (\(tilesRendered) rendered synchronously)")
        check(controller.window?.title.hasPrefix("Smoke @ 100% (RGB, ") == true, "document title: \(controller.window?.title ?? "")")

        // A stroke through the same path mouse and tablet events take.
        document.beginStroke(at: .init(x: 100, y: 100, pressure: 1))
        document.continueStroke((1...20).map { .init(x: 100 + Double($0) * 20, y: 100, pressure: 1, timeMilliseconds: UInt32($0 * 8)) })
        document.endStroke()
        document.inputQueue.sync {}
        spin()
        try document.reload()
        check(document.undoInfo.undoCount == 1, "a stroke through the canvas input path adds one undo step")
        let painted = pixel(session, image, x: 300, y: 100)
        check((painted?[0] ?? 255) < 64, "the stroke is painted (red \(painted?[0] ?? 255) at 300,100)")

        // The Layers palette rows.
        let rows = document.layers.map(LayersPaletteController.title(for:))
        check(rows == ["● Background"], "Layers palette rows: \(rows)")

        // The Gaussian Blur dialog: preview, then OK.
        guard let blur = GaussianBlurPanel(document: document) else {
            check(false, "Gaussian Blur dialog opens a filter session")
            return
        }
        blur.apply(radius: 6)
        document.inputQueue.sync {}
        check(document.undoInfo.undoCount == 1, "the blur preview adds no undo step")
        blur.commit()
        document.inputQueue.sync {}
        spin()
        try document.reload()
        check(document.undoInfo.undoCount == 2 && document.layers.first?.filterCount == 1,
              "OK commits one non-destructive filter as one undo step")

        // Edit ▸ Undo and Redo send undo: and redo: up the responder chain,
        // where the document window answers them (NSWindow handles both).
        let undoItem = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let window = try XCTUnwrapWindow(controller)
        let expectedTitle = "Undo \(document.undoInfo.nextUndo)"
        check(window.validateMenuItem(undoItem) && !document.undoInfo.nextUndo.isEmpty && undoItem.title == expectedTitle,
              "Edit ▸ Undo is enabled and names the step (\(undoItem.title))")
        window.tryToPerform(Selector(("undo:")), with: undoItem)
        document.inputQueue.sync {}
        spin()
        try document.reload()
        check(document.undoInfo.undoCount == 1 && document.undoInfo.redoCount == 1, "Edit ▸ Undo through the document window")
        window.tryToPerform(Selector(("redo:")), with: nil)
        document.inputQueue.sync {}
        try document.reload()
        check(document.undoInfo.undoCount == 2, "Edit ▸ Redo through the document window")

        // Render cost of the visible area at several zooms (this machine).
        for percent in [25, 50, 100, 200] {
            controller.zoom(to: percent)
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            let begin = DispatchTime.now()
            let count = try controller.canvas.renderVisibleTilesNow()
            print("     canvas render at \(percent)%: \(count) tiles in \(String(format: "%.1f", milliseconds(since: begin))) ms")
        }
        controller.window?.orderOut(nil)
    }

    /// The tools: shortcuts, a pencil stroke with the tool's settings, a
    /// selection that reaches the canvas as marching ants and confines the
    /// next stroke, and the Select menu through the document window.
    private static func exerciseTools(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 400, height: 300)
        let document = try ImageDocument(session: session, image: image, name: "Tools")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        let state = ToolState.shared

        state.select(.paintbrush)
        state.select(shortcut: "b", cycle: true)
        check(state.current == .pencil, "Shift-B cycles the brush group to the pencil (\(state.current.name))")
        state.select(shortcut: "m", cycle: false)
        check(state.current == .rectangleSelect, "M picks the marquee group (\(state.current.name))")
        check(ToolsPaletteController().view.subviews.contains { ($0 as? ClassicToolGrid)?.slots.count == ToolID.paletteSlots.count },
              "the Tools palette shows \(ToolID.paletteSlots.count) tool cells")
        state.select(.pencil)
        check(ToolOptionsPaletteController().view.subviews.count >= 4, "Tool Options shows the pencil's settings")

        state.foreground = .black
        document.beginStroke(at: .init(x: 20, y: 50, pressure: 1), brush: state.brush(for: .pencil))
        document.continueStroke([.init(x: 380, y: 50, pressure: 1, timeMilliseconds: 50)])
        document.endStroke()
        document.inputQueue.sync {}
        spin()
        check((pixel(session, image, x: 200, y: 50)?[0] ?? 255) < 64, "a pencil stroke with the tool's settings paints")

        document.select(.rectangle(CGRect(x: 100, y: 100, width: 100, height: 80)),
                        options: EngineSession.SelectOptions())
        document.inputQueue.sync {}
        spin()
        check(document.selectionOutline.count >= 4 && controller.canvas.selectionOutline == document.selectionOutline,
              "a rectangle selection reaches the canvas as marching ants (\(controller.canvas.selectionOutline.count) edges)")

        document.beginStroke(at: .init(x: 20, y: 140, pressure: 1), brush: state.brush(for: .pencil))
        document.continueStroke([.init(x: 380, y: 140, pressure: 1, timeMilliseconds: 50)])
        document.endStroke()
        document.inputQueue.sync {}
        spin()
        check((pixel(session, image, x: 150, y: 140)?[0] ?? 255) < 64 && pixel(session, image, x: 300, y: 140)?[0] == 255,
              "the next stroke stays inside the selection")

        controller.selectNone(nil)
        document.inputQueue.sync {}
        spin()
        check(document.selectionOutline.isEmpty && controller.canvas.selectionOutline.isEmpty,
              "Select ▸ Deselect through the window clears the ants")
        controller.selectAll(nil)
        document.inputQueue.sync {}
        spin()
        check(try session.selectionBounds(image: image) == CGRect(x: 0, y: 0, width: 400, height: 300),
              "Select ▸ All selects the whole image")
        controller.window?.orderOut(nil)
    }

    /// The Layer menu, the paint bucket and gradient, layer moves, and a
    /// crop that resizes the canvas, through the document as the menus and
    /// tools drive them.
    private static func exerciseEditing(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 300, height: 200)
        let document = try ImageDocument(session: session, image: image, name: "Editing")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        func settle() {
            document.inputQueue.sync {}
            spin()
        }

        controller.newLayer(nil)
        settle()
        check(document.layers.count == 2 && document.activeLayer == document.layers.first?.id,
              "Layer ▸ New Layer adds a layer and selects it")
        document.fill(at: .zero, mode: .selection, color: .red, threshold: 0, sampleMerged: false)
        settle()
        check(pixel(session, image, x: 150, y: 100)?.prefix(3) == [255, 0, 0], "the paint bucket fills the new layer")

        guard let layer = document.activeLayer else { return }
        var accepted = 0
        for mode in DocumentWindowController.blendModes {
            if (try? session.changeLayer(layer, image: image, EngineSession.LayerChange(mode: mode))) != nil { accepted += 1 }
        }
        check(accepted == DocumentWindowController.blendModes.count,
              "the engine knows every blend mode the Layer Properties menu offers (\(accepted) of \(DocumentWindowController.blendModes.count))")
        try session.changeLayer(layer, image: image, EngineSession.LayerChange(mode: "normal"))

        document.moveActiveLayer(by: CGSize(width: 20, height: 10))
        settle()
        check(document.layers.first?.bounds.origin == CGPoint(x: 20, y: 10), "the Move tool's drag moves the layer")

        // The Transform tool: drag the bottom-right corner halfway in, apply.
        if let moved = document.layers.first {
            var transform = LayerTransformSession(layer: moved.id, bounds: moved.bounds)
            let corner = transform.corners[2]
            let target = CGPoint(x: moved.bounds.midX, y: moved.bounds.midY)
            transform.update(transform.beginDrag(.corner(2), at: corner), to: target, constrained: false)
            let undoBefore = document.undoInfo.undoCount
            document.transformLayer(moved.id, matrix: transform.matrix, interpolation: .cubic)
            settle()
            let bounds = document.layers.first?.bounds ?? .zero
            check(bounds.origin == moved.bounds.origin
                    && abs(bounds.width - moved.bounds.width / 2) <= 1 && abs(bounds.height - moved.bounds.height / 2) <= 1,
                  "the Transform tool scales the layer from its fixed corner (\(bounds))")
            check(document.undoInfo.undoCount == undoBefore + 1, "the transform is one undo step")
            document.undo()
            settle()
            check(document.layers.first?.bounds == moved.bounds, "undo restores the layer's size")
        }

        // What a transformed lone layer no longer covers is transparent:
        // the canvas shows checks there, not the gray around the image.
        let lone = try ImageDocument(session: session, image: session.newImage(width: 64, height: 64), name: "Checks")
        documents.items.append(lone)
        let loneController = DocumentWindowController(document: lone)
        if let only = lone.layers.first {
            var shrink = LayerTransformSession(layer: only.id, bounds: only.bounds)
            shrink.update(shrink.beginDrag(.corner(2), at: shrink.corners[2]), to: CGPoint(x: 32, y: 32), constrained: false)
            lone.transformLayer(only.id, matrix: shrink.matrix, interpolation: .none)
            lone.inputQueue.sync {}
            spin()
            _ = try loneController.canvas.renderVisibleTilesNow()
            let shade = canvasBrightness(loneController.canvas, at: CGPoint(x: 60, y: 60))
            check(lone.layers.first.map { $0.bounds.width <= 33 } == true && shade.map { $0 >= 0.75 } == true,
                  "the canvas shows checks where a transformed layer left transparency (\(shade.map { String(format: "%.2f", $0) } ?? "nil"))")
        }

        // The Text tool's engine side: fonts, a new text layer, editing it.
        let fonts = (try? session.fonts()) ?? []
        check(!fonts.isEmpty, "the engine lists \(fonts.count) fonts")
        var textSettings = EngineSession.TextSettings()
        textSettings.font = fonts.contains("Sans-serif") ? "Sans-serif" : (fonts.first ?? "Sans-serif")
        textSettings.size = 24
        let layersBefore = document.layers.count
        document.addText("Glims", settings: textSettings, at: CGPoint(x: 12, y: 14))
        settle()
        let added = document.layers.first
        check(document.layers.count == layersBefore + 1 && added?.kind == .text
                && added?.bounds.origin == CGPoint(x: 12, y: 14) && document.activeLayer == added?.id,
              "the Text tool adds a text layer where it was clicked and selects it")
        if let added, let read = document.textLayer(added.id) {
            check(read.text == "Glims" && read.settings.font == textSettings.font && abs(read.settings.size - 24) < 0.01,
                  "the text layer reads back its text and look")
            document.updateText(added.id, text: "Glims text", settings: nil)
            settle()
            check(document.textLayer(added.id)?.text == "Glims text"
                    && (document.layers.first?.bounds.width ?? 0) > added.bounds.width,
                  "editing the text changes the layer")
            document.undo()
            document.undo()
            settle()
            check(document.layers.count == layersBefore, "undo removes the text again")
        } else {
            check(false, "the text layer reads back")
        }

        // The Text tool through the canvas: a click opens the editor with
        // the keyboard focus, typing goes into it, Escape applies it.
        let canvas = controller.canvas
        let previousTool = ToolState.shared.current
        ToolState.shared.select(.text)
        ToolState.shared.textSettings = textSettings
        let click = CGPoint(x: 40, y: 30)
        if let window = controller.window,
           let press = NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.convert(click, to: nil),
                                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            canvas.mouseDown(with: press)
            let editor = canvas.tools.textEditor
            check(editor != nil && window.firstResponder === editor,
                  "a Text tool click opens the editor with the keyboard focus")
            editor?.insertText("Hi", replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.zoom(to: 200)
            check(editor?.frame.origin == CGPoint(x: click.x * 2, y: click.y * 2),
                  "the text editor follows the canvas zoom (\(editor?.frame.origin ?? .zero))")
            controller.zoom(to: ZoomLadder.actualPixels)
            editor?.cancelOperation(nil)
            settle()
            let typed = document.layers.first
            check(canvas.tools.textEditor == nil && window.firstResponder === canvas
                    && typed?.kind == .text && typed?.bounds.origin == click
                    && typed.flatMap { document.textLayer($0.id)?.text } == "Hi",
                  "Escape applies the typed text as a text layer at the click")
            if typed?.kind == .text { document.undo() }
            settle()
        } else {
            check(false, "a Text tool click reaches the canvas")
        }
        ToolState.shared.select(previousTool)

        if let background = document.layers.last?.id { document.selectLayer(background) }
        document.gradient(from: CGPoint(x: 0, y: 5), to: CGPoint(x: 300, y: 5), shape: .linear,
                          fromColor: .black, toColor: .white)
        settle()
        check((pixel(session, image, x: 10, y: 5)?[0] ?? 255) < 60, "the gradient tool draws on the selected background")

        controller.mergeDown(nil)
        settle()
        controller.flattenImage(nil)
        settle()
        check(document.layers.count == 1, "Merge Down and Flatten Image leave one layer")

        document.select(.rectangle(CGRect(x: 50, y: 50, width: 100, height: 60)), options: EngineSession.SelectOptions())
        settle()
        controller.cropToSelection(nil)
        settle()
        check(document.info.width == 100 && document.info.height == 60 && controller.canvas.frame.size == CGSize(width: 100, height: 60),
              "Crop to Selection resizes the image and the canvas (\(document.info.width) × \(document.info.height))")
        document.undo()
        settle()
        check(document.info.width == 300 && controller.canvas.frame.width == 300, "undo restores the size and the canvas")

        controller.rotateImage90(nil)
        settle()
        check(document.info.width == 200 && document.info.height == 300 && controller.canvas.frame.size == CGSize(width: 200, height: 300),
              "Image ▸ Rotate ▸ 90° Clockwise swaps the size and the canvas follows")
        document.scale(toWidth: 100, height: 150)
        settle()
        check(document.info.width == 100 && controller.canvas.frame.width == 100, "Image Size scales the image and the canvas")
        document.resizeCanvas(width: 140, height: 190, offset: CGPoint(x: 20, y: 20), fill: .blue)
        settle()
        check(document.info.width == 140 && pixel(session, image, x: 2, y: 2)?.prefix(3) == [0, 0, 255],
              "Canvas Size grows the canvas with the background color")
        controller.flipLayerHorizontally(nil)
        settle()
        check(document.undoInfo.nextUndo.isEmpty == false, "Layer ▸ Transform ▸ Flip Horizontal is an undo step (\(document.undoInfo.nextUndo))")
        controller.window?.orderOut(nil)
    }

    /// The plug-in menus and a plug-in command run through a document
    /// window, without a dialog (with last values), as Filter ▸ Last Filter
    /// runs one.
    /// The Rigi controls the palettes and status bar use: a typed zoom, the
    /// palettes' button bars and menus, and Tool Options' value sliders.
    private static func exercisePaletteControls(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 120, height: 80)
        let document = try ImageDocument(session: session, image: image, name: "Controls")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        func settle() {
            document.inputQueue.sync {}
            spin()
        }

        controller.statusBar.onZoomTo?(250)
        check(controller.canvas.zoomPercent == 250, "a zoom typed into the status bar applies")
        controller.statusBar.onZoomTo?(100_000)
        check(controller.canvas.zoomPercent == ZoomLadder.steps.last, "a typed zoom stays within the ladder")
        controller.zoom(to: ZoomLadder.actualPixels)

        let layers = LayersPaletteController()
        layers.retarget(to: document)
        let layerBar = descendant(of: layers.view, as: ClassicPaletteButtonBar.self)
        check(layerBar?.isEnabled(item: "new") == true && layerBar?.isEnabled(item: "delete") == true,
              "the Layers palette's button bar offers New and Delete")
        layerBar.flatMap { buttons(in: $0).first { $0.toolTip == "New Layer" } }?.performClick(nil)
        settle()
        check(document.layers.count == 2, "its New button adds a layer")
        let duplicate = layers.paletteMenu?.items.first { $0.title == "Duplicate Layer" }
        check(duplicate.map { $0.target === layers && layers.validateMenuItem($0) } == true,
              "the Layers palette's menu runs the layer commands itself, enabled for the shown document")
        if let duplicate, let action = duplicate.action {
            NSApp.sendAction(action, to: duplicate.target, from: duplicate)
            settle()
            check(document.layers.count == 3, "its Duplicate Layer duplicates the layer")
        }

        let paths = PathsPaletteController()
        paths.retarget(to: document)
        let pathBar = descendant(of: paths.view, as: ClassicPaletteButtonBar.self)
        check(pathBar?.isEnabled(item: "new") == true && pathBar?.isEnabled(item: "stroke") == false,
              "the Paths palette's bar enables only New without a path")
        let strokeItem = paths.paletteMenu?.items.first { $0.title == "Stroke Path" }
        check(strokeItem.map { paths.validateMenuItem($0) } == false, "its menu disables Stroke Path without a path")

        // A pending transform whose layer an undo moved is not applied with
        // the old box: Return refuses it.
        if let window = controller.window {
            func send(_ type: NSEvent.EventType, _ point: CGPoint) {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: controller.canvas.convert(point, to: nil), modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: 1) else { return }
                switch type {
                case .leftMouseDown: controller.canvas.mouseDown(with: event)
                case .leftMouseDragged: controller.canvas.mouseDragged(with: event)
                default: controller.canvas.mouseUp(with: event)
                }
            }
            document.moveActiveLayer(by: CGSize(width: 10, height: 5))
            settle()
            let toolBefore = ToolState.shared.current
            ToolState.shared.select(.transform)
            send(.leftMouseDown, CGPoint(x: 60, y: 40))
            send(.leftMouseDragged, CGPoint(x: 70, y: 40))
            send(.leftMouseUp, CGPoint(x: 70, y: 40))
            document.undo()
            settle()
            let undone = document.layers.first { $0.id == document.activeLayer }?.bounds
            let steps = document.undoInfo.undoCount
            if let enter = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) {
                controller.canvas.keyDown(with: enter)
            }
            settle()
            check(document.undoInfo.undoCount == steps
                    && document.layers.first { $0.id == document.activeLayer }?.bounds == undone,
                  "a transform whose layer an undo changed is not applied")
            ToolState.shared.select(toolBefore)
        }

        let previousTool = ToolState.shared.current
        ToolState.shared.select(.paintbrush)
        let options = ToolOptionsPaletteController()
        check(descendant(of: options.view, as: ClassicValueSlider.self) != nil,
              "Tool Options shows value sliders for a painting tool")
        ToolState.shared.select(previousTool)
    }

    private static func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
    }

    private static func descendant<View: NSView>(of view: NSView, as type: View.Type) -> View? {
        if let match = view as? View { return match }
        for child in view.subviews {
            if let match = descendant(of: child, as: type) { return match }
        }
        return nil
    }

    /// The Path tool driven through the canvas, then the Paths palette's
    /// commands and the engine's undo of path edits.
    private static func exercisePaths(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 200, height: 120)
        let document = try ImageDocument(session: session, image: image, name: "Paths")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        let canvas = controller.canvas
        func settle() {
            document.inputQueue.sync {}
            spin()
        }
        guard let window = controller.window else { return check(false, "the Paths document has a window") }
        func event(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: canvas.convert(CGPoint(x: point.x * canvas.scale,
                                                                             y: point.y * canvas.scale), to: nil),
                               modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                               context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        func drag(_ points: [CGPoint], flags: NSEvent.ModifierFlags = []) {
            guard let first = points.first, let last = points.last,
                  let down = event(.leftMouseDown, at: first, flags: flags),
                  let up = event(.leftMouseUp, at: last, flags: flags) else { return }
            canvas.mouseDown(with: down)
            for point in points.dropFirst() {
                if let moved = event(.leftMouseDragged, at: point, flags: flags) { canvas.mouseDragged(with: moved) }
            }
            canvas.mouseUp(with: up)
            settle()
        }

        let previousTool = ToolState.shared.current
        defer { ToolState.shared.select(previousTool) }
        ToolState.shared.select(.path)

        drag([CGPoint(x: 20, y: 20)])
        check(document.paths.count == 1 && document.activePath == document.paths.first?.id,
              "the Path tool's first click adds a path and makes it active")
        drag([CGPoint(x: 100, y: 20)])
        drag([CGPoint(x: 100, y: 90), CGPoint(x: 110, y: 90), CGPoint(x: 120, y: 90)])
        drag([CGPoint(x: 20, y: 90)])
        drag([CGPoint(x: 20, y: 20)])
        let undoBefore = document.undoInfo.undoCount
        let closed = document.activePath.flatMap { try? session.path($0, image: image) }
        check(closed?.subpaths.count == 1 && closed?.subpaths.first?.isClosed == true
                && closed?.subpaths.first?.anchors.count == 4,
              "clicks add corners and clicking the first anchor closes the subpath "
                + "(\(closed?.subpaths.first?.anchors.count ?? 0) anchors)")
        check(closed?.subpaths.first?.anchors[2].handleOut == CGPoint(x: 120, y: 90),
              "a drag pulls out the new anchor's handles")

        document.undo()
        settle()
        let reopened = document.activePath.flatMap { document.pathShapes[$0] }
        check(document.undoInfo.undoCount == undoBefore - 1 && reopened?.subpaths.first?.isClosed == false,
              "undo takes back the closing click, one edit at a time")
        document.redo()
        settle()

        guard let path = document.activePath else { return check(false, "the path stays active") }
        let paths = PathsPaletteController()
        paths.retarget(to: document)
        check((paths.view.subviews.first as? NSScrollView)?.documentView.map { ($0 as? NSTableView)?.numberOfRows == 1 } == true,
              "the Paths palette lists the path")

        paths.run(.toSelection)
        settle()
        let bounds = try session.selectionBounds(image: image)
        check(bounds.map { abs($0.minX - 20) <= 1 && abs($0.minY - 20) <= 1 && $0.maxX >= 100 } == true,
              "To Selection selects the path's area (\(bounds.map { "\($0)" } ?? "none"))")
        try session.select(.none, image: image)

        ToolState.shared.foreground = .black
        ToolState.shared.pathLineWidth = 4
        paths.run(.stroke)
        settle()
        check((pixel(session, image, x: 60, y: 20)?[0] ?? 255) < 64 && (pixel(session, image, x: 60, y: 50)?[0] ?? 0) > 200,
              "Stroke draws the path on the layer in the foreground color")

        document.renamePath(path, to: "Outline")
        settle()
        check(document.paths.first?.name == "Outline", "a path can be renamed")

        // An undo that lands while an anchor is held wins over the drag.
        drag([CGPoint(x: 100, y: 20), CGPoint(x: 110, y: 20)])
        let moved = document.pathShapes[path]
        if let down = event(.leftMouseDown, at: CGPoint(x: 110, y: 20)),
           let dragged = event(.leftMouseDragged, at: CGPoint(x: 140, y: 40)),
           let up = event(.leftMouseUp, at: CGPoint(x: 140, y: 40)) {
            canvas.mouseDown(with: down)
            canvas.mouseDragged(with: dragged)
            document.undo()
            settle()
            let undone = document.pathShapes[path]
            canvas.mouseUp(with: up)
            settle()
            check(undone != moved && document.pathShapes[path] == undone,
                  "an undo during a drag is not overwritten when the drag ends")
            document.redo()
            settle()
        }

        // Delete while an anchor is held does nothing; the drag goes on.
        if let down = event(.leftMouseDown, at: CGPoint(x: 110, y: 20)),
           let up = event(.leftMouseUp, at: CGPoint(x: 110, y: 20)),
           let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: "\u{7F}",
                                         charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51) {
            let anchors = document.pathShapes[path]?.anchorCount
            canvas.mouseDown(with: down)
            canvas.keyDown(with: delete)
            canvas.mouseUp(with: up)
            settle()
            check(anchors == 4 && document.pathShapes[path]?.anchorCount == anchors,
                  "Delete during a drag leaves the anchors alone")
        }

        // Clicking the start of an open subpath only picks it up; the next
        // anchor then extends it from that end.
        func key(_ code: UInt16) {
            if let press = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: "\r",
                                            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: code) {
                canvas.keyDown(with: press)
            }
        }
        key(36)
        if let down = event(.leftMouseDown, at: CGPoint(x: 150, y: 100), flags: .shift),
           let up = event(.leftMouseUp, at: CGPoint(x: 150, y: 100), flags: .shift) {
            canvas.mouseDown(with: down)
            canvas.mouseUp(with: up)
            settle()
        }
        drag([CGPoint(x: 180, y: 100)])
        key(36)
        let stepsBefore = document.undoInfo.undoCount
        drag([CGPoint(x: 150, y: 100)])
        check(document.undoInfo.undoCount == stepsBefore, "clicking a subpath's start anchor is not an edit")
        drag([CGPoint(x: 150, y: 60)])
        let extended = document.pathShapes[path]?.subpaths.last
        check(extended?.anchors.count == 3 && extended?.anchors.first?.point == CGPoint(x: 180, y: 100)
                && extended?.anchors.last?.point == CGPoint(x: 150, y: 60),
              "the next anchor extends the subpath from its start")
        key(36)
        document.undo()
        document.undo()
        document.undo()
        settle()

        // A rename in progress survives a reload of the palette's list.
        let renaming = PathsPaletteController()
        renaming.retarget(to: document)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300), styleMask: [.titled],
                            backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = renaming.view
        host.contentView?.layoutSubtreeIfNeeded()
        let nameField = descendant(of: renaming.view, as: NSTableView.self)?
            .view(atColumn: 0, row: 0, makeIfNecessary: true)
            .flatMap { descendant(of: $0, as: NSTextField.self) }
        let nameBefore = document.paths.first?.name
        if let nameField, host.makeFirstResponder(nameField), let editor = nameField.currentEditor() {
            editor.string = "Half"
            renaming.reload()
            spin()
            check(nameField.currentEditor() != nil && document.paths.first?.name == nameBefore,
                  "a rename being typed survives a reload and commits nothing yet")
            host.makeFirstResponder(nil)
            settle()
            check(document.paths.first?.name == "Half", "ending the rename commits it")
            document.undo()
            settle()
        } else {
            check(false, "the Paths palette's name field can be edited")
        }

        // A path that goes away while its name is being typed: the list
        // catches up when the rename ends, and a click on a stale row is
        // ignored rather than indexing past the paths.
        let spare = document.addPath(VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: 5, y: 5))])]))
        settle()
        renaming.reload()
        let table = descendant(of: renaming.view, as: NSTableView.self)
        let spareRow = document.paths.firstIndex { $0.id == spare } ?? 0
        let lastRow = (table?.numberOfRows ?? 1) - 1
        let spareField = table?.view(atColumn: 0, row: spareRow, makeIfNecessary: true)
            .flatMap { descendant(of: $0, as: NSTextField.self) }
        if let spare, let spareField, host.makeFirstResponder(spareField) {
            spareField.currentEditor()?.string = "Gone soon"
            document.deletePath(spare)
            settle()
            renaming.reload()
            host.makeFirstResponder(nil)
            spin()
            check(table?.numberOfRows == document.paths.count,
                  "the list catches up after a rename whose path went away (\(table?.numberOfRows ?? -1) rows)")
            table?.selectRowIndexes(IndexSet(integer: lastRow), byExtendingSelection: false)
            check(true, "a click on a row past the paths does not crash")
        } else {
            check(false, "a second path's name field can be edited")
        }

        // Selecting a path while a plug-in runs is refused, and the list
        // keeps showing the path that stays active.
        let other = document.addPath(VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: 9, y: 9))])]))
        settle()
        if let other {
            document.selectPath(path)
            settle()
            renaming.reload()
            let running = EngineSession.Procedure(name: "smoke-busy", label: "Busy", menuPath: "", blurb: "",
                                                  isSensitive: true)
            PlugInCommands.willRun(running, on: document)
            if let row = document.paths.firstIndex(where: { $0.id == other }) {
                table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
            spin()
            let shown = (table?.selectedRow).flatMap { document.paths.indices.contains($0) ? document.paths[$0].id : nil }
            check(document.activePath == path && shown == path,
                  "a path picked while a plug-in runs is refused and the list shows the active one")
            PlugInCommands.didRun(running, outcome: nil)
            document.deletePath(other)
            settle()
        }
        host.close()

        if let down = event(.leftMouseDown, at: CGPoint(x: 20, y: 90)),
           let up = event(.leftMouseUp, at: CGPoint(x: 20, y: 90)) {
            canvas.mouseDown(with: down)
            canvas.mouseUp(with: up)
        }
        if let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                         windowNumber: window.windowNumber, context: nil, characters: "\u{7F}",
                                         charactersIgnoringModifiers: "\u{7F}", isARepeat: false, keyCode: 51) {
            canvas.keyDown(with: delete)
        }
        settle()
        check(document.pathShapes[path]?.subpaths.first?.anchors.count == 3, "Delete removes the selected anchor")

        paths.run(.delete)
        settle()
        check(document.paths.isEmpty && document.activePath == nil, "the palette deletes the path")
    }

    private static func exercisePlugInCommands(_ session: EngineSession, documents: DocumentList) throws {
        let mainMenu = MainMenu.make()
        NSApp.mainMenu = mainMenu
        let procedures = try session.procedures()
        PlugInMenus.install(procedures, in: mainMenu)

        func submenu(_ path: [String]) -> NSMenu? {
            path.reduce(mainMenu as NSMenu?) { menu, title in menu?.item(withTitle: title)?.submenu }
        }
        let pattern = submenu(["Filter", "Render", "Pattern"])?.items.map(\.title) ?? []
        check(pattern.contains("Checkerboard (legacy)…"),
              "Filter ▸ Render ▸ Pattern lists the engine's plug-ins (\(pattern.joined(separator: ", ")))")
        let blur = submenu(["Filter", "Blur"])?.items.map(\.title) ?? []
        check(blur.first == "Gaussian Blur…" && blur.count > 1,
              "Filter ▸ Blur keeps the native Gaussian Blur and adds plug-ins (\(blur.count) items)")
        check(submenu(["Image", "Adjust"])?.items.isEmpty == false, "GIMP's Colors plug-ins appear under Image ▸ Adjust")
        let categories = submenu(["Filter"])?.items.filter { $0.submenu != nil && $0.title != MainMenu.recentlyUsedTitle }.map(\.title) ?? []
        check(categories.count > 5 && categories == categories.sorted { $0.localizedStandardCompare($1) == .orderedAscending },
              "Filter categories are alphabetical (\(categories.prefix(4).joined(separator: ", "))…)")

        guard let checkerboard = procedures.first(where: { $0.name == "plug-in-checkerboard" }) else {
            check(false, "the engine offers plug-in-checkerboard")
            return
        }
        let image = try session.newImage(width: 640, height: 480)
        let document = try ImageDocument(session: session, image: image, name: "Plug-ins")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        var messages: [String] = []
        document.onError = { messages.append($0) }
        check(document.canRun(checkerboard), "the command is available for an RGB layer")

        let progressBefore = documents.progressEvents.count
        controller.run(checkerboard, mode: .withLastValues)
        check(PlugInCommands.isRunning, "the command runs in the background")
        document.undo()
        check(messages.last?.hasPrefix("Finish or cancel") == true,
              "edits are refused while it runs (\(messages.last ?? "no message"))")
        let deadline = Date().addingTimeInterval(30)
        while PlugInCommands.isRunning && Date() < deadline { spin(0.02) }
        spin()
        check(!PlugInCommands.isRunning && document.undoInfo.undoCount == 1,
              "the command finished as one undo step (\(document.undoInfo.undoCount))")
        check(!controller.statusBar.isShowingProgress, "the status bar's progress goes away when it ends")
        let first = pixel(session, image, x: 5, y: 5), second = pixel(session, image, x: 15, y: 5)
        check(first != nil && first != second, "the image changed (\(first ?? []) vs \(second ?? []))")
        check(documents.progressEvents.count > progressBefore && documents.progressEvents.last == .some(nil),
              "progress events reached the app and ended (\(documents.progressEvents.count - progressBefore))")
        check(PlugInCommands.last?.name == checkerboard.name &&
              submenu(["Filter", MainMenu.recentlyUsedTitle])?.items.first?.title == checkerboard.label,
              "Last Filter and Recently Used remember the command")
        controller.window?.orderOut(nil)
    }

    /// Runs `pluginCalls` synchronous plug-in calls (PNG exports) on a
    /// background queue while a 10 ms main-thread timer measures its own
    /// lateness and makes a synchronous engine call each tick, as an
    /// interface redrawing during a long operation would.
    private static func measurePluginStalls(_ session: EngineSession, work: URL) throws {
        let image = try session.newImage(width: 256, height: 256)
        let exports = work.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: exports, withIntermediateDirectories: true)

        var done = false
        var exportError: Error?
        var lastTick = DispatchTime.now()
        var maxLateness = 0.0
        var maxRenderCall = 0.0
        var ticks = 0
        let interval = 0.010

        // Scheduled on the main run loop, so it fires on the main thread.
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            let now = DispatchTime.now()
            maxLateness = max(maxLateness, Double(now.uptimeNanoseconds - lastTick.uptimeNanoseconds) / 1e6 - interval * 1000)
            let begin = DispatchTime.now()
            _ = try? session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 64, height: 64))
            maxRenderCall = max(maxRenderCall, milliseconds(since: begin))
            ticks += 1
            lastTick = DispatchTime.now()
        }
        RunLoop.main.add(timer, forMode: .common)

        let begin = DispatchTime.now()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                for index in 0..<pluginCalls {
                    try session.export(image, to: exports.appendingPathComponent("\(index).png").path)
                }
            } catch {
                exportError = error
            }
            DispatchQueue.main.async { done = true }
        }
        while !done { spin(0.02) }
        timer.invalidate()
        let total = milliseconds(since: begin)

        check(exportError == nil, "\(pluginCalls) synchronous plug-in calls (PNG exports) succeed\(exportError.map { ": \($0)" } ?? "")")
        print("     \(pluginCalls) plug-in calls took \(Int(total)) ms (\(String(format: "%.1f", total / Double(pluginCalls))) ms each); \(ticks) main-thread ticks")
        check(maxLateness < maximumMainThreadStallMilliseconds,
              "main thread never stalled ≥ \(Int(maximumMainThreadStallMilliseconds)) ms during plug-in calls (worst \(String(format: "%.1f", maxLateness)) ms)")
        check(maxRenderCall < maximumMainThreadStallMilliseconds,
              "engine calls from the main thread stay responsive during plug-in calls (worst \(String(format: "%.1f", maxRenderCall)) ms)")
    }
}

@MainActor
private final class DocumentList {
    var items: [ImageDocument] = []
    var progressEvents: [EngineSession.Progress?] = []
}
