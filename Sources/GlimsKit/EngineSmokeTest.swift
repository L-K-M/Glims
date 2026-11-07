import AppKit
import CGlimsEngine
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
            try exerciseFileAdmission(session, work: work, documents: documents)
            try exerciseRecovery(session, work: work, documents: documents)
            try exerciseClipboard(session, documents: documents)
            try exercisePreviewLifetimes(session, work: work, documents: documents)
            try exerciseDisplayDensity(session, documents: documents)
            try exerciseTools(session, documents: documents)
            try exerciseEditing(session, documents: documents)
            try exerciseLayerTree(session, documents: documents)
            try exercisePreferences(session, documents: documents)
            try exercisePaths(session, documents: documents)
            try exercisePaletteControls(session, documents: documents)
            try exercisePendingEditScope(session, documents: documents)
            try exerciseHistoryAndSnapshots(session, work: work, documents: documents)
            try exercisePlugInCommands(session, documents: documents)
            try exerciseNativeFilterForms(session, work: work, documents: documents)
            try measurePluginStalls(session, work: work)
        } catch {
            check(false, "unexpected engine error: \(error)")
        }

        print(failures == 0 ? "PASSED" : "FAILED: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }

    /// A file plug-in holds the engine across all documents. Its admission
    /// must drain accepted input and refuse later edits before the call starts.
    private static func exerciseFileAdmission(_ session: EngineSession, work: URL,
                                               documents: DocumentList) throws {
        let a = try ImageDocument(session: session, image: session.newImage(width: 64, height: 64), name: "Writing")
        let b = try ImageDocument(session: session, image: session.newImage(width: 64, height: 64), name: "Painting")
        let closing = try ImageDocument(session: session, image: session.newImage(width: 16, height: 16), name: "Close during write")
        documents.items += [a, b, closing]
        let controller = DocumentWindowController(document: b)
        let closingController = DocumentWindowController(document: closing)
        closingController.showWindow(nil)
        defer {
            a.onWillChangeLayers = nil
            documents.items.removeAll { $0 === a || $0 === b || $0 === closing }
            a.closeImageWhenDrained()
            b.closeImageWhenDrained()
            closing.closeImageWhenDrained()
        }
        var errors: [String] = []
        b.onError = { errors.append($0) }
        var committedField = false
        var nestedActivityFinished = false
        a.onWillChangeLayers = {
            guard !committedField else { return }
            committedField = true
            // A field/text delegate flushes its accepted value at admission.
            a.beginStroke(at: .init(x: 24, y: 24, pressure: 1))
            a.endStroke()
            EngineActivity.shared.performWhenReady(label: "Queued field action", work: {}) {
                nestedActivityFinished = true
            }
        }
        b.inputQueue.async { usleep(200_000) }
        let brush = EngineSession.Brush(size: 10, opacity: 1, red: 0, green: 0, blue: 0, pressureSize: false)
        b.beginStroke(at: .init(x: 12, y: 12, pressure: 1), brush: brush)
        var finished = false
        var writeError: Error?
        let started = DispatchTime.now()
        a.export(to: work.appendingPathComponent("admission.png")) { error in
            writeError = error
            finished = true
        }
        check(milliseconds(since: started) < 100, "file admission returns without waiting for accepted input")
        check(!a.acceptsEdits && !b.acceptsEdits, "a pending file write gates edits in every document")
        b.beginStroke(at: .init(x: 44, y: 44, pressure: 1), brush: brush)
        check(!b.strokeIsActive, "a later pointer stroke is refused before it becomes active")
        if b.strokeIsActive { b.endStroke() }
        check(!errors.isEmpty, "the refused edit explains the pending file operation")
        let editing = NSMenuItem(title: "Group", action: #selector(DocumentWindowController.newLayerGroup(_:)), keyEquivalent: "")
        let navigation = NSMenuItem(title: "Fit", action: #selector(DocumentWindowController.fitImage(_:)), keyEquivalent: "")
        check(!controller.validateMenuItem(editing) && controller.validateMenuItem(navigation),
              "file activity disables edits while canvas navigation remains available")
        var closed: Bool?
        closingController.requestClose { closed = $0 }
        check(closed == nil && !closing.isClosing, "another document waits for file activity before closing")
        let deadline = Date().addingTimeInterval(8)
        while (!finished || closed == nil) && Date() < deadline { spin(0.01) }
        check(finished && writeError == nil, "the file operation completes after accepted input drains")
        spin()
        check(pixel(session, b.image, x: 12, y: 12)?.first == 0,
              "input accepted in another document before the write is preserved")
        check(pixel(session, b.image, x: 44, y: 44)?.first == 255,
              "the refused stroke made no pixel change")
        check(a.acceptsEdits && b.acceptsEdits, "all documents resume editing after the write")
        check(nestedActivityFinished, "a delegate can queue another activity without reentrant admission")
        while (a.pendingWork > 0 || b.pendingWork > 0) && Date() < deadline { spin(0.01) }
        let written = try session.openImage(path: work.appendingPathComponent("admission.png").path)
        check(pixel(session, written, x: 24, y: 24)?.first == 0,
              "the file includes edits flushed by a field delegate during admission")
        try session.closeImage(written)
        check(closed == true && (try? session.info(closing.image)) == nil,
              "the deferred close destroys its image after the file operation")

        controller.gaussianBlur(nil)
        while b.pendingWork > 0 && Date() < deadline { spin(0.01) }
        check(controller.previewPanel != nil, "a second document can hold a preview before the write")
        b.inputQueue.async { usleep(100_000) }
        finished = false
        a.export(to: work.appendingPathComponent("admission-preview.png")) { error in
            writeError = error
            finished = true
        }
        controller.cancelOperation(nil)
        while (!finished || b.pendingWork > 0 || b.filterPreviewIsOpen) && Date() < deadline { spin(0.01) }
        check(finished && writeError == nil && !b.filterPreviewIsOpen && controller.previewPanel == nil,
              "preview cancellation in another document waits safely for the file operation")
    }

    /// A recovery pass writes a real native copy through the same
    /// engine-wide admission as the interface, then commits it into the
    /// private store — without touching the document's file identity,
    /// dirty state or undo history. Closing the document while a write
    /// is counted as its work removes the record, so no recovery copy
    /// survives a successful close.
    private static func exerciseRecovery(_ session: EngineSession, work: URL,
                                         documents: DocumentList) throws {
        let image = try session.newImage(width: 64, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Recovery")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let window = try XCTUnwrapWindow(controller)

        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin() }
        }
        func paint(_ x: Double) {
            document.beginStroke(at: .init(x: x, y: 20, pressure: 1))
            document.endStroke()
            document.inputQueue.sync {}
            spin()
        }

        let native = work.appendingPathComponent("recovery-source.xcf")
        var saved = false
        document.save(to: native) { error in
            if error == nil { document.noteSaved(to: native); saved = true }
        }
        wait { saved && document.pendingWork == 0 }
        check(saved && document.fileState.nativeURL == native && !document.hasUnsavedChanges,
              "the document saves natively before recovery begins")

        let store = RecoveryStore(base: work.appendingPathComponent("recovery-store"))
        try store.prepare()
        var tickFire: (@MainActor () -> Void)?
        let scheduler = RecoveryScheduler(store: store) { _, fire in tickFire = fire; return {} }
        controller.onClose = { closed in scheduler.untrack(closed.imageDocument) }
        scheduler.track(document, isReady: { [weak controller] in
            controller?.isReadyForRecoveryCopy ?? false
        })
        scheduler.start()

        paint(20)
        let revision = document.history?.revision
        let undoSteps = document.undoInfo.undoCount
        check(document.hasUnsavedChanges && revision != nil, "a new edit makes the document dirty")

        tickFire?()
        wait { store.record(for: document.recoveryID) != nil && scheduler.copying == nil
                && document.pendingWork == 0 }
        let record = store.record(for: document.recoveryID)
        check(record?.documentID == document.recoveryID && record?.nativeURL == native
                && record?.importedSourceURL == nil && record?.revision == revision
                && record?.name == "recovery-source.xcf",
              "a recovery pass commits a manifest naming the native file and revision")
        let copy = store.copyURL(for: document.recoveryID)
        if let copyImage = try? session.openImage(path: copy.path) {
            check((pixel(session, copyImage, x: 20, y: 20)?[0] ?? 255) < 128,
                  "the recovery copy holds the painted pixels")
            try session.closeImage(copyImage)
        } else {
            check(false, "the recovery copy reopens as an XCF")
        }
        let copyMode = (try? FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions]) as? Int
        check(copyMode == 0o600, "the committed recovery copy is private")
        check(document.fileState.nativeURL == native && document.hasUnsavedChanges
                && document.undoInfo.undoCount == undoSteps && document.history?.revision == revision,
              "the recovery copy preserves file identity, dirty state and undo history")

        let firstDate = record?.date
        tickFire?()
        wait { scheduler.copying == nil && document.pendingWork == 0 }
        check(store.record(for: document.recoveryID)?.date == firstDate,
              "an unchanged revision is not copied again")

        // A close asked for while the write is counted as document work
        // finishes only after it; the store then holds no record.
        paint(40)
        document.inputQueue.async { usleep(400_000) }
        tickFire?()
        check(document.pendingWork > 0, "the recovery write counts as document work")
        var closed: Bool?
        controller.requestClose { closed = $0 }
        let deadline = Date().addingTimeInterval(10)
        while closed == nil && Date() < deadline {
            spin(0.02)
            if let sheet = window.attachedSheet {
                NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue)
            }
        }
        check(closed == true, "a close asked for during the recovery write finishes after it")
        check(store.record(for: document.recoveryID) == nil && !store.copyExists(for: document.recoveryID),
              "a successful close removes the document's recovery record")
        check((try? session.info(image)) == nil, "the closed image is destroyed")
        documents.items.removeAll { $0 === document }
        scheduler.stop()
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
        let copyURL = work.appendingPathComponent("native-copy.xcf")
        var copied = false
        document.saveCopy(to: copyURL) { copied = $0 == nil }
        wait { copied && document.pendingWork == 0 }
        check(copied && document.hasUnsavedChanges && document.fileState.nativeURL == native,
              "Save a Copy includes queued input without changing native identity or dirty state")
        let copiedImage = try session.openImage(path: copyURL.path)
        check((pixel(session, copiedImage, x: 28, y: 20)?[0] ?? 255) < 128,
              "the native copy contains the queued stroke")
        try session.closeImage(copiedImage)
        var exportedOK = false
        document.export(to: exported) { exportedOK = $0 == nil }
        wait { exportedOK && document.pendingWork == 0 }
        check(exportedOK && document.hasUnsavedChanges && document.fileState.nativeURL == native,
              "export preserves native identity and unsaved changes")
        paint()
        controller.repeatExport(nil)
        wait { document.pendingWork == 0 }
        let repeated = try session.openImage(path: exported.path)
        check(document.fileState.lastExportURL == exported && document.hasUnsavedChanges &&
                (pixel(session, repeated, x: 33, y: 20)?[0] ?? 255) < 128,
              "Export Again writes new edits to the last export without clearing native unsaved changes")
        try session.closeImage(repeated)
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
                                          location: controller.canvas.convert(CGPoint(x: 4 * controller.canvas.scale,
                                                                                       y: 4 * controller.canvas.scale), to: nil),
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
        let fromClipboard = try session.newImage(pixels: source)
        let clipboardInfo = try session.info(fromClipboard)
        let clipboardRows = try session.layers(fromClipboard)
        let clipboardUndo = try session.undoInfo(fromClipboard)
        check(clipboardInfo.width == 2 && clipboardInfo.height == 2 && clipboardInfo.isDirty &&
                clipboardRows.count == 1 && clipboardRows.first?.bounds.origin == .zero &&
                clipboardUndo.undoCount == 0,
              "Paste as New creates an unsaved image at its clipboard size with no white background or synthetic history")
        try session.closeImage(fromClipboard)
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

    private static func exercisePreviewLifetimes(_ session: EngineSession, work: URL,
                                                 documents: DocumentList) throws {
        let image = try session.newImage(width: 32, height: 32)
        let native = work.appendingPathComponent("preview-lifetime.xcf")
        try session.save(image, to: native.path)
        let document = try ImageDocument(session: session, image: image, name: "Preview Lifetime", openedFrom: native)
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        guard let layer = document.activeLayer,
              let blurFilter = try? session.beginFilter(image: image, drawable: layer,
                                                        operation: GaussianBlurPanel.operation) else { throw NoWindow() }
        let blur = GaussianBlurPanel(document: document, filter: blurFilter)
        document.inputQueue.sync {}
        spin()
        document.copyPixels(.merged, background: .white, consume: { _ in }, completion: { _ in })
        check(document.isTransferringClipboard, "preview cancellation is exercised during a clipboard transfer")
        var finished = false
        blur.onFinish = { finished = true }
        blur.commit()
        check(!finished, "a refused filter commit leaves its preview available for cancellation")
        blur.cancel()
        check(!document.hasUnsavedChanges, "canceling a preview does not mark a clean document dirty")
        let deadline = Date().addingTimeInterval(10)
        while document.pendingWork > 0 && Date() < deadline { spin() }
        check((try? session.save(image, to: native.path)) != nil,
              "cancel during Copy releases the preview so the image remains savable")
        controller.gaussianBlur(nil)
        document.inputQueue.sync {}
        spin()
        var closed: Bool?
        controller.requestClose { closed = $0 }
        while closed == nil && controller.window?.attachedSheet == nil && Date() < deadline { spin() }
        check(closed == true && controller.window?.attachedSheet == nil,
              "closing a clean image cancels its preview without an unsaved-changes prompt")
        if let sheet = controller.window?.attachedSheet {
            NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue)
        }
        while (try? session.info(image)) != nil && Date() < deadline { spin() }
        documents.items.removeAll { $0 === document }
    }

    private final class DensityWindow: NSWindow {
        var simulatedBackingFactor: CGFloat = 1
        override var backingScaleFactor: CGFloat { simulatedBackingFactor }
    }

    /// Exercise the actual canvas hooks and event conversion, independently
    /// of the physical screen attached to the test machine.
    private static func exerciseDisplayDensity(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 1600, height: 1200)
        let document = try ImageDocument(session: session, image: image, name: "Display Density")
        documents.items.append(document)
        let window = DensityWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let canvas = EngineCanvasView(document: document)
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scroll.contentView = CanvasClipView()
        scroll.documentView = canvas
        window.contentView = scroll
        window.contentView?.layoutSubtreeIfNeeded()
        scroll.contentView.scroll(to: CGPoint(x: 300, y: 200))
        let viewport = scroll.contentView.bounds
        let oldCenter = CGPoint(x: viewport.midX / canvas.scale, y: viewport.midY / canvas.scale)
        window.simulatedBackingFactor = 2
        canvas.viewDidChangeBackingProperties()
        let movedViewport = scroll.contentView.bounds
        let movedCenter = CGPoint(x: movedViewport.midX / canvas.scale, y: movedViewport.midY / canvas.scale)
        check(canvas.zoomPercent == 100 && canvas.scale == 0.5 && canvas.frame.size == CGSize(width: 800, height: 600),
              "Actual Pixels uses one device pixel per image pixel in a simulated 2x window")
        check(hypot(movedCenter.x - oldCenter.x, movedCenter.y - oldCenter.y) < 0.01,
              "a backing-density change preserves the image pixel under the viewport center")
        let point = CGPoint(x: 25, y: 30)
        if let event = NSEvent.mouseEvent(with: .leftMouseDown, location: canvas.convert(point, to: nil),
                                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            check(canvas.imagePoint(for: event) == CGPoint(x: 50, y: 60),
                  "pointer input in a 2x window maps view points to image pixels")
        } else { check(false, "a simulated-density pointer event can be constructed") }
        try canvas.renderVisibleTilesNow()
        check(canvas.renderedTileCount > 0, "the density-adjusted viewport renders engine tiles")
        window.simulatedBackingFactor = 1
        canvas.viewDidChangeBackingProperties()
        let returned = scroll.contentView.bounds
        check(canvas.scale == 1 && canvas.frame.size == CGSize(width: 1600, height: 1200) &&
                hypot(returned.midX - oldCenter.x, returned.midY - oldCenter.y) < 0.01,
              "moving back to 1x preserves zoom and the same image center")
        window.close()
        var closed = false
        canvas.stopRendering { document.closeImageWhenDrained { closed = true } }
        let deadline = Date().addingTimeInterval(10)
        while !closed && Date() < deadline { spin() }
        check(closed, "density changes still allow safe render teardown")
        documents.items.removeAll { $0 === document }
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
        guard let blurLayer = document.activeLayer,
              let blurFilter = try? session.beginFilter(image: image, drawable: blurLayer,
                                                        operation: GaussianBlurPanel.operation) else {
            check(false, "Gaussian Blur dialog opens a filter session")
            return
        }
        let blur = GaussianBlurPanel(document: document, filter: blurFilter)
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

    /// Groups, tree moves and locks through the same document APIs the
    /// Layers palette and the Layer menu use: group creation, selection
    /// and nesting, an undoable reparent, lock toggles and the paint/move
    /// refusals they cause, a queued creation losing to a later user
    /// pick, and the filter preview gating layer changes.
    private static func exercisePreferences(_ session: EngineSession, documents: DocumentList) throws {
        let suite = "ch.lkmc.Glims.smoke.preferences.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = EditorPreferences(defaults: defaults)
        let image = try session.newImage(width: 32, height: 24)
        let document = try ImageDocument(session: session, image: image, name: "Preferences")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document, preferences: preferences)
        controller.showWindow(nil)
        let before = pixel(session, image, x: 8, y: 8)
        preferences.surround = .dark
        let scroll = controller.window?.contentView.flatMap { descendant(of: $0, as: NSScrollView.self) }
        check(controller.canvas.surroundColor == EditorPreferences.Surround.dark.color &&
                scroll?.backgroundColor == EditorPreferences.Surround.dark.color,
              "changing canvas surround updates an already-open document and its viewport")
        preferences.reset()
        check(controller.canvas.surroundColor == EditorPreferences.Surround.medium.color &&
                scroll?.backgroundColor == EditorPreferences.Surround.medium.color,
              "restoring preferences updates existing canvas surrounds")
        check(pixel(session, image, x: 8, y: 8) == before &&
                !document.hasUnsavedChanges && document.undoInfo.undoCount == 0,
              "display preferences leave image pixels and undo history unchanged")
        controller.window?.orderOut(nil)
    }

    private static func exerciseLayerTree(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 64, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Layers")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        func settle() {
            document.inputQueue.sync {}
            spin()
        }

        // Layer ▸ New Layer Group lands above the active layer and is selected.
        controller.newLayerGroup(nil)
        settle()
        guard let group = document.layers.first(where: { $0.kind == .group }) else {
            check(false, "Layer ▸ New Layer Group inserts a group")
            controller.window?.orderOut(nil)
            return
        }
        check(document.layers.count == 2 && document.activeLayer == group.id,
              "Layer ▸ New Layer Group inserts a group and selects it")

        // A group row is a valid selection target for metadata and filters.
        guard let background = document.layers.last?.id else { return }
        document.selectLayer(background)
        settle()
        document.selectLayer(group.id)
        settle()
        check(document.activeLayer == group.id, "a group can be the selected item")

        // ...but it cannot be painted on.
        document.beginStroke(at: .init(x: 8, y: 8, pressure: 1))
        check(!document.strokeIsActive && controller.statusBar.message.contains("cannot be painted"),
              "painting on a group is refused before the engine is asked")
        document.endStroke()

        // A new layer with a group active lands inside it; dropping it to
        // the top level reparents it, undoably.
        controller.newLayer(nil)
        settle()
        guard let moved = document.layers.first(where: { $0.kind == .pixel && $0.parent == group.id }) else {
            check(false, "Layer ▸ New Layer with a group active adds the layer inside it")
            controller.window?.orderOut(nil)
            return
        }
        check(moved.depth == 1, "Layer ▸ New Layer with a group active adds the layer inside it")
        document.moveLayer(moved.id, toParent: 0, atIndex: 0)
        settle()
        check(document.layers.first(where: { $0.id == moved.id })?.parent == 0
                && document.layers.first(where: { $0.id == moved.id })?.depth == 0,
              "dropping a layer to the top level reparents it")
        document.undo()
        settle()
        check(document.layers.first(where: { $0.id == moved.id })?.parent == group.id,
              "undo restores the layer's parent")
        document.redo()
        settle()
        check(document.layers.first(where: { $0.id == moved.id })?.parent == 0,
              "redo repeats the reparent")
        document.moveLayer(moved.id, toParent: group.id, atIndex: 0)
        settle()
        check(document.layers.first(where: { $0.id == moved.id })?.parent == group.id
                && document.layers.first(where: { $0.id == moved.id })?.depth == 1,
              "a layer drops back into the group")

        let layerPalette = LayersPaletteController()
        _ = layerPalette.view
        layerPalette.retarget(to: document)
        if let outline = descendant(of: layerPalette.view, as: NSOutlineView.self),
           let groupNode = (0..<outline.numberOfRows).compactMap({ outline.item(atRow: $0) as? LayerTree.Node })
                .first(where: { $0.id == group.id }) {
            outline.expandItem(groupNode)
            outline.collapseItem(groupNode)
            check(!outline.isItemExpanded(groupNode), "a user can collapse the selected layer's group")
            layerPalette.retarget(to: document)
            let refreshed = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? LayerTree.Node }
                .first { $0.id == group.id }
            check(refreshed.map { !outline.isItemExpanded($0) } == true,
                  "retargeting the unchanged document preserves a collapsed selected group")
        } else {
            check(false, "the layer outline exposes the created group")
        }

        // A group created while a group is active nests inside it; a
        // group cannot be dropped into its own subtree.
        document.selectLayer(group.id)
        settle()
        controller.newLayerGroup(nil)
        settle()
        let inner = document.layers.first(where: { $0.kind == .group && $0.id != group.id })
        check(inner?.parent == group.id && inner?.depth == 1,
              "a group created with a group active becomes its first child")
        if let inner {
            document.moveLayer(group.id, toParent: inner.id, atIndex: 0)
            settle()
            check(controller.statusBar.message.contains("cannot be moved")
                    && document.layers.first(where: { $0.id == group.id })?.parent == 0,
                  "dropping a group into its own subtree is refused with an actionable message")

            // Moving a layer into `inner` makes it an expandable nested
            // group: group > inner > moved. AppKit keeps a child's
            // expansion under a collapsed parent; the reload a retarget
            // runs must keep it too.
            document.moveLayer(moved.id, toParent: inner.id, atIndex: 0)
            settle()
            layerPalette.retarget(to: document)
            if let outline = descendant(of: layerPalette.view, as: NSOutlineView.self) {
                func rowNode(_ id: Int32) -> LayerTree.Node? {
                    (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? LayerTree.Node }
                        .first { $0.id == id }
                }
                if let outerNode = rowNode(group.id) {
                    outline.expandItem(outerNode)
                    if let innerNode = rowNode(inner.id) {
                        outline.expandItem(innerNode)
                        outline.collapseItem(outerNode)
                        outline.expandItem(outerNode)
                        check(rowNode(inner.id).map { outline.isItemExpanded($0) } == true,
                              "collapsing a parent keeps a nested group's expansion")
                        outline.collapseItem(outerNode)
                        layerPalette.retarget(to: document)
                        if let outerAgain = rowNode(group.id) {
                            outline.expandItem(outerAgain)
                            check(rowNode(inner.id).map { outline.isItemExpanded($0) } == true,
                                  "a reload preserves a group's expansion inside a collapsed parent")
                        } else {
                            check(false, "the collapsed parent is still in the outline")
                        }
                    } else {
                        check(false, "the outline shows the moved layer inside the nested group")
                    }
                } else {
                    check(false, "the outline shows the outer group")
                }
            } else {
                check(false, "the layer palette has an outline")
            }
        }

        // Layer ▸ Lock items toggle the item's own locks; the engine and
        // the interface refuse editing through them.
        document.selectLayer(moved.id)
        settle()
        let lockPixels = NSMenuItem(title: "Lock Pixels", action: nil, keyEquivalent: "")
        lockPixels.tag = Int(EngineSession.LayerLocks.pixels.rawValue)
        controller.toggleLayerLock(lockPixels)
        settle()
        check(document.layerLocks[moved.id]?.local == [.pixels]
                && document.layerLocks[moved.id]?.effective.contains(.pixels) == true,
              "Layer ▸ Lock ▸ Lock Pixels sets the layer's own lock")
        document.beginStroke(at: .init(x: 8, y: 8, pressure: 1))
        document.continueStroke([.init(x: 9, y: 8, pressure: 1)])
        document.endStroke()
        settle()
        check(controller.statusBar.message.contains("Unlock")
                && (pixel(session, image, x: 8, y: 8)?[0] ?? 255) > 200,
              "a pixel lock refuses the stroke with an actionable message")

        let lockPosition = NSMenuItem(title: "Lock Position", action: nil, keyEquivalent: "")
        lockPosition.tag = Int(EngineSession.LayerLocks.position.rawValue)
        controller.toggleLayerLock(lockPosition)
        settle()
        document.moveActiveLayer(by: CGSize(width: 6, height: 6))
        settle()
        check(controller.statusBar.message.contains("Unlock"),
              "a position lock refuses the Move tool's drag")
        document.setLayerLocks(moved.id, [.pixels, .position], to: false)
        settle()
        check(document.layerLocks[moved.id]?.local.isEmpty == true,
              "unlocking clears the layer's own locks")
        document.beginStroke(at: .init(x: 8, y: 8, pressure: 1))
        document.continueStroke([.init(x: 9, y: 8, pressure: 1)])
        document.endStroke()
        settle()
        check((pixel(session, image, x: 8, y: 8)?[0] ?? 255) < 64, "unlocked, the stroke paints")

        // A queued layer creation must not override a pick the user made
        // while it was queued.
        document.inputQueue.async { Thread.sleep(forTimeInterval: 0.4) }
        let countBeforeNew = document.layers.count
        document.layerCommand(.new)
        document.selectLayer(background)
        settle()
        check(document.layers.count == countBeforeNew + 1 && document.activeLayer == background,
              "a late new-layer completion keeps the user's selection")

        var textSettings = EngineSession.TextSettings()
        let fonts = (try? session.fonts()) ?? []
        textSettings.font = fonts.contains("Sans-serif") ? "Sans-serif" : (fonts.first ?? "Sans-serif")
        document.inputQueue.async { Thread.sleep(forTimeInterval: 0.4) }
        document.addText("Late", settings: textSettings, at: CGPoint(x: 6, y: 30))
        document.selectLayer(background)
        settle()
        check(document.layers.contains(where: { $0.kind == .text }) && document.activeLayer == background,
              "a late text-layer creation keeps the user's selection")
        if let text = document.layers.first(where: { $0.kind == .text })?.id {
            document.selectLayer(text)
            settle()
            document.layerCommand(.delete)
            settle()
        }

        // The blur preview gates every layer command until it finishes.
        if let pixelLayer = document.layers.first(where: { $0.kind == .pixel })?.id {
            document.selectLayer(pixelLayer)
            settle()
        }
        controller.gaussianBlur(nil)
        settle()
        check(document.filterPreviewIsOpen, "the blur preview marks the document previewing")
        let countBeforeRefused = document.layers.count
        document.createGroup()
        settle()
        check(document.layers.count == countBeforeRefused
                && controller.statusBar.message.contains("preview"),
              "a filter preview refuses New Layer Group with an actionable message")
        if let other = document.layers.first(where: { $0.id != document.activeLayer })?.id {
            let active = document.activeLayer
            document.selectLayer(other)
            check(document.activeLayer == active && controller.statusBar.message.contains("preview"),
                  "a filter preview refuses layer picks")
        }
        controller.cancelOperation(nil)
        settle()
        check(!document.filterPreviewIsOpen, "canceling the preview reopens layer commands")

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
           let press = NSEvent.mouseEvent(with: .leftMouseDown,
                                          location: canvas.convert(CGPoint(x: click.x * canvas.scale, y: click.y * canvas.scale), to: nil),
                                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            canvas.mouseDown(with: press)
            let editor = canvas.tools.textEditor
            check(editor != nil && window.firstResponder === editor,
                  "a Text tool click opens the editor with the keyboard focus")
            editor?.insertText("Hi", replacementRange: NSRange(location: NSNotFound, length: 0))
            controller.zoom(to: 200)
            check(editor?.frame.origin == CGPoint(x: click.x * canvas.scale, y: click.y * canvas.scale),
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
        check(document.info.width == 100 && document.info.height == 60 &&
                controller.canvas.frame.size == CGSize(width: 100 * canvas.scale, height: 60 * canvas.scale),
              "Crop to Selection resizes the image and the canvas (\(document.info.width) × \(document.info.height))")
        document.undo()
        settle()
        check(document.info.width == 300 && controller.canvas.frame.width == 300 * canvas.scale, "undo restores the size and the canvas")

        controller.rotateImage90(nil)
        settle()
        check(document.info.width == 200 && document.info.height == 300 &&
                controller.canvas.frame.size == CGSize(width: 200 * canvas.scale, height: 300 * canvas.scale),
              "Image ▸ Rotate ▸ 90° Clockwise swaps the size and the canvas follows")
        document.scale(toWidth: 100, height: 150)
        settle()
        check(document.info.width == 100 && controller.canvas.frame.width == 100 * canvas.scale, "Image Size scales the image and the canvas")
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
                    with: type, location: controller.canvas.convert(CGPoint(x: point.x * controller.canvas.scale,
                                                                            y: point.y * controller.canvas.scale), to: nil), modifierFlags: [],
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

    /// Two documents side by side: a routine layer command on one must
    /// finish only its own pending edits. A field in each document's
    /// window and a rename in a Layers palette aimed at each document
    /// hold real field editors; the other document's keep typing.
    private static func exercisePendingEditScope(_ session: EngineSession, documents: DocumentList) throws {
        let documentA = try ImageDocument(session: session, image: session.newImage(width: 32, height: 32), name: "A")
        documents.items.append(documentA)
        let controllerA = DocumentWindowController(document: documentA)
        controllerA.showWindow(nil)
        let windowA = try XCTUnwrapWindow(controllerA)
        let documentB = try ImageDocument(session: session, image: session.newImage(width: 32, height: 32), name: "B")
        documents.items.append(documentB)
        let controllerB = DocumentWindowController(document: documentB)
        controllerB.showWindow(nil)
        let windowB = try XCTUnwrapWindow(controllerB)
        func settle() {
            documentA.inputQueue.sync {}
            documentB.inputQueue.sync {}
            spin()
        }

        // A second layer makes the pick a real change of the active one.
        controllerA.newLayer(nil)
        settle()
        guard let active = documentA.layers.first, let other = documentA.layers.last,
              active.id != other.id else {
            check(false, "document A has two layers to pick between")
            return
        }

        // Editable fields own each document window's field editor.
        let fieldA = NSTextField(string: "100")
        fieldA.isEditable = true
        fieldA.frame = NSRect(x: 0, y: 0, width: 80, height: 18)
        windowA.contentView?.addSubview(fieldA)
        let fieldB = NSTextField(string: "200")
        fieldB.isEditable = true
        fieldB.frame = NSRect(x: 0, y: 0, width: 80, height: 18)
        windowB.contentView?.addSubview(fieldB)

        // Each Layers palette aims at its document from its own window,
        // as the floating panels host them.
        func layersInWindow(_ document: ImageDocument) -> (LayersPaletteController, NSWindow) {
            let palette = LayersPaletteController()
            palette.retarget(to: document)
            let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 300),
                                styleMask: [.titled], backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.contentView = palette.view
            host.contentView?.layoutSubtreeIfNeeded()
            return (palette, host)
        }
        let (paletteA, hostA) = layersInWindow(documentA)
        let (paletteB, hostB) = layersInWindow(documentB)
        func renameRow(_ palette: LayersPaletteController, _ name: String) -> NSTextField? {
            guard let outline = descendant(of: palette.view, as: NSOutlineView.self),
                  let row = outline.view(atColumn: 0, row: 0, makeIfNecessary: true) as? LayerRowView
            else { return nil }
            row.startEditingName()
            row.nameField.currentEditor()?.string = name
            return row.nameField
        }
        let nameFieldA = renameRow(paletteA, "Renamed A")
        let nameFieldB = renameRow(paletteB, "Renamed B")

        windowA.makeFirstResponder(fieldA)
        fieldA.currentEditor()?.string = "150"
        windowB.makeFirstResponder(fieldB)
        fieldB.currentEditor()?.string = "250"

        // A canvas text draft and a stroke are mid-edit on document A too.
        var textSettings = EngineSession.TextSettings()
        textSettings.font = ((try? session.fonts()) ?? []).first ?? "Sans-serif"
        textSettings.size = 18
        let previousTool = ToolState.shared.current
        ToolState.shared.select(.text)
        ToolState.shared.textSettings = textSettings
        if let press = NSEvent.mouseEvent(with: .leftMouseDown,
                                          location: controllerA.canvas.convert(CGPoint(x: 6, y: 6), to: nil),
                                          modifierFlags: [], timestamp: 0, windowNumber: windowA.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            controllerA.canvas.mouseDown(with: press)
        }
        controllerA.canvas.tools.textEditor?.insertText("Draft", replacementRange: NSRange(location: NSNotFound, length: 0))
        documentA.beginStroke(at: .init(x: 2, y: 2, pressure: 1))
        check(controllerA.canvas.tools.textEditor != nil && documentA.strokeIsActive,
              "document A holds a text draft and a stroke while edits are pending")

        let nameBeforeB = documentB.layers.first?.name
        documentA.selectLayer(other.id)
        settle()

        check(fieldA.currentEditor() == nil && fieldA.stringValue == "150",
              "a layer pick commits the field edit in its own window")
        check(nameFieldA?.currentEditor() == nil && documentA.layers.contains { $0.name == "Renamed A" },
              "a layer pick commits a rename in a palette aimed at its document")
        check(controllerA.canvas.tools.textEditor == nil,
              "a layer pick finishes its document's canvas text edit")
        check(!documentA.strokeIsActive, "a layer pick ends its document's stroke")
        check(fieldB.currentEditor() != nil,
              "a layer pick leaves the other document's field editor running")
        check(nameFieldB?.currentEditor() != nil && documentB.layers.first?.name == nameBeforeB,
              "a layer pick leaves a palette aimed at the other document renaming")

        ToolState.shared.select(previousTool)
        windowB.makeFirstResponder(nil)
        hostB.makeFirstResponder(nil)
        hostA.close()
        hostB.close()
        windowA.orderOut(nil)
        windowB.orderOut(nil)
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

    /// The History palette and image snapshots: exact states backward and
    /// forward, a no-op pick of the current state, a stale pick refused
    /// after a new edit, queued stroke and text edits in a snapshot, a
    /// closing source and a Quit coordinating with snapshot work, and the
    /// copy's file identity and undo independence.
    private static func exerciseHistoryAndSnapshots(_ session: EngineSession, work: URL,
                                                    documents: DocumentList) throws {
        let image = try session.newImage(width: 64, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "History")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        var messages: [String] = []
        let reportError = document.onError
        document.onError = { reportError?($0); messages.append($0) }
        func settle() {
            document.inputQueue.sync {}
            spin()
        }
        func wait(_ condition: @escaping () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin() }
        }

        check(document.history?.rows.count == 1 && document.history?.currentPosition == 0
                && document.history?.rows.first?.name.isEmpty == false,
              "a new document lists its earliest history state")
        document.fill(at: .zero, mode: .selection, color: .red, threshold: 0, sampleMerged: false)
        document.beginStroke(at: .init(x: 8, y: 8, pressure: 1))
        document.continueStroke([.init(x: 24, y: 24, pressure: 1)])
        document.endStroke()
        settle()
        guard let filled = document.history, filled.rows.count == 3, filled.currentPosition == 2 else {
            check(false, "a fill and a stroke list three history states (\(document.history?.rows.count ?? -1))")
            return
        }
        check(true, "a fill and a stroke list three history states")

        // Backward and forward through the palette's own pick path; the
        // pixels show the states are the exact ones, not approximations.
        let palette = HistoryPaletteController()
        palette.retarget(to: document)
        let table = descendant(of: palette.view, as: NSTableView.self)
        let bar = descendant(of: palette.view, as: ClassicPaletteButtonBar.self)
        check(table?.numberOfRows == 3, "the History palette lists the states")
        check(bar?.isEnabled(item: "snapshot") == false,
              "the Snapshot button waits for something to adopt the copy")
        /// A registered palette reloads on every document state change;
        /// this freestanding one does the same after a pick settles.
        func pickRow(_ row: Int) {
            table?.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            settle()
            palette.reload()
        }
        pickRow(0)
        check(document.history?.currentPosition == 0 && (pixel(session, image, x: 2, y: 2)?[1] ?? 0) > 200
                && (pixel(session, image, x: 12, y: 12)?[0] ?? 0) > 200,
              "picking the earliest row undoes the fill and the stroke")
        check(table?.numberOfRows == 3, "undone future states stay listed")
        pickRow(2)
        check(document.history?.currentPosition == 2 && (pixel(session, image, x: 2, y: 2)?[1] ?? 255) == 0
                && (pixel(session, image, x: 12, y: 12)?[0] ?? 255) < 64,
              "picking an undone row redoes to it")

        // Picking the current state is a no-op: no new revision, same spot.
        let beforeNoOp = document.history
        document.moveToHistoryState(beforeNoOp?.currentPosition ?? -1, revision: beforeNoOp?.revision ?? 0)
        settle()
        check(document.history?.revision == beforeNoOp?.revision
                && document.history?.currentPosition == beforeNoOp?.currentPosition,
              "picking the current state changes nothing")

        // A pick whose revision went stale is refused, keeps the state and
        // reports why; after the reload a fresh pick goes through.
        document.fill(at: .zero, mode: .selection, color: .green, threshold: 0, sampleMerged: false)
        settle()
        check(document.history?.currentPosition == 3 && document.history?.revision != beforeNoOp?.revision,
              "a new edit advances the history revision")
        document.moveToHistoryState(0, revision: beforeNoOp?.revision ?? 0)
        settle()
        check(messages.contains { $0.contains("history changed") } && document.history?.currentPosition == 3,
              "a stale pick is refused with its reason and the state stays")
        // The palette's own stale row, rendered before that edit landed.
        document.fill(at: .zero, mode: .selection, color: .blue, threshold: 0, sampleMerged: false)
        settle()
        pickRow(0)
        check(messages.last == HistoryPaletteController.staleMessage && document.history?.currentPosition == 4,
              "a stale palette row reports why and does not move the state")
        check(table?.numberOfRows == 5, "the refusal reloads the palette")
        pickRow(0)
        check(document.history?.currentPosition == 0 && (pixel(session, image, x: 2, y: 2)?[1] ?? 0) > 200,
              "selecting again after the reload moves to the state")

        // Snapshot controls disable while the engine cannot duplicate.
        document.filterPreviewIsOpen = true
        palette.reload()
        check(bar?.isEnabled(item: "snapshot") == false,
              "the Snapshot button is disabled during a filter preview")
        document.filterPreviewIsOpen = false
        palette.reload()

        // A snapshot queued behind a stroke contains it; the source's
        // history is untouched.
        document.beginStroke(at: .init(x: 40, y: 40, pressure: 1))
        document.continueStroke([.init(x: 50, y: 50, pressure: 1)])
        document.endStroke()
        var copyID: Int32 = 0
        var copyDone = false
        document.snapshot { result in
            copyID = (try? result.get()) ?? 0
            copyDone = true
        }
        wait { copyDone }
        check(copyID != 0, "the queued snapshot produced an image")
        check((pixel(session, copyID, x: 45, y: 45)?[0] ?? 255) < 64,
              "the snapshot contains the just-finished stroke")
        check((try? session.undoInfo(copyID))?.undoCount == 0 && (try? session.info(copyID))?.isDirty == true,
              "the snapshot is unsaved with an empty history")
        try session.closeImage(copyID)
        settle()
        check(document.history?.currentPosition == 1 && document.undoInfo.undoCount == 1,
              "the snapshot left the source's pixels and history alone")

        // Text still being typed is committed through the document's hook
        // before the copy; the result opens as a new document bound to its
        // source, whoever is front document then.
        let app = AppController()
        document.snapshotHandler = { [weak app] document in app?.snapshot(document) }
        let previousTool = ToolState.shared.current
        let previousText = ToolState.shared.textSettings
        ToolState.shared.textSettings.font = ToolState.pickableFontNames(try session.fonts()).first ?? "Sans-serif"
        ToolState.shared.textSettings.size = 12
        ToolState.shared.select(.text)
        if let window = controller.window,
           let press = NSEvent.mouseEvent(with: .leftMouseDown,
                                          location: controller.canvas.convert(CGPoint(x: 4, y: 4), to: nil),
                                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            controller.canvas.mouseDown(with: press)
            controller.canvas.tools.textEditor?.insertText("Snap", replacementRange: NSRange(location: NSNotFound, length: 0))
            document.newSnapshot()
            wait { app.frontDocument != nil }
            let snapshotDoc = app.frontDocument
            // The real app routes engine events to its documents; the
            // smoke test's list stands in for that.
            if let snapshotDoc { documents.items.append(snapshotDoc) }
            check(controller.canvas.tools.textEditor == nil, "the snapshot committed the pending text first")
            check(snapshotDoc != nil && snapshotDoc !== document
                    && snapshotDoc?.layers.contains { $0.kind == .text } == true,
                  "the snapshot opens as a new document containing the typed text")
            check(snapshotDoc?.name == "History snapshot" && snapshotDoc?.fileState.nativeURL == nil
                    && snapshotDoc?.fileState.importedSourceURL == nil && snapshotDoc?.hasUnsavedChanges == true,
                  "the snapshot is a fresh unsaved document without the source's file")
            check(snapshotDoc?.undoInfo.undoCount == 0 && snapshotDoc?.history?.rows.count == 1,
                  "the snapshot's own history starts empty")
            // Editing the copy does not reach the source (a fill needs a
            // pixel layer: the copy's text layer is still selected).
            let sourceSteps = document.undoInfo.undoCount
            if let background = snapshotDoc?.layers.last?.id { snapshotDoc?.selectLayer(background) }
            snapshotDoc?.fill(at: .zero, mode: .selection, color: .black, threshold: 0, sampleMerged: false)
            snapshotDoc?.inputQueue.sync {}
            spin()
            check(snapshotDoc?.undoInfo.undoCount == 1 && document.undoInfo.undoCount == sourceSteps
                    && document.layers.contains { $0.kind == .text },
                  "editing the snapshot leaves the source untouched")
            snapshotDoc?.undo()
            snapshotDoc?.inputQueue.sync {}
            spin()
            check(snapshotDoc?.undoInfo.undoCount == 0 && document.undoInfo.undoCount == sourceSteps,
                  "the snapshot's own undo works on it alone")
            NSApp.windows
                .first { ($0.windowController as? DocumentWindowController)?.imageDocument === snapshotDoc }?
                .orderOut(nil)
            PaletteCenter.shared.closeAll()
            // The first real document open loads the engine's fonts in the
            // background; drain it so it cannot straddle later checks.
            snapshotDoc?.longQueue.sync {}
            spin()
        } else {
            check(false, "text editing can be started before a snapshot")
        }
        ToolState.shared.textSettings = previousText
        ToolState.shared.select(previousTool)

        // A snapshot of a saved document keeps none of its file identity.
        let filedImage = try session.newImage(width: 32, height: 32)
        let native = work.appendingPathComponent("snapshot-source.xcf")
        try session.save(filedImage, to: native.path)
        let filed = try ImageDocument(session: session, image: filedImage, name: "Filed", openedFrom: native)
        documents.items.append(filed)
        var filedResult: Result<Int32, Error>?
        filed.snapshot { filedResult = $0 }
        wait { filedResult != nil }
        if let copyImage = try? filedResult?.get() {
            let copy = try ImageDocument(session: session, image: copyImage, name: "Filed snapshot")
            check(copy.fileState.nativeURL == nil && copy.fileState.importedSourceURL == nil
                    && copy.fileState.saveRoute == .askForFile && copy.hasUnsavedChanges,
                  "a snapshot of a saved document keeps no file identity")
            try session.closeImage(copyImage)
        } else {
            check(false, "the filed document's snapshot produced an image")
        }
        documents.items.removeAll { $0 === filed }

        // A closing source holds its engine image until the snapshot ran.
        let closingImage = try session.newImage(width: 32, height: 32)
        let closing = try ImageDocument(session: session, image: closingImage, name: "Closing")
        documents.items.append(closing)
        let closingController = DocumentWindowController(document: closing)
        closingController.showWindow(nil)
        var closingResult: Result<Int32, Error>?
        closing.snapshot { closingResult = $0 }
        var sourceClosed: Bool?
        closingController.requestClose { sourceClosed = $0 }
        if let sheet = closingController.window?.attachedSheet {
            NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue)
        }
        wait { sourceClosed != nil && closingResult != nil }
        check(sourceClosed == true && (try? closingResult?.get()) != nil,
              "a queued snapshot runs before its closing source frees the image")
        if let orphan = try? closingResult?.get() { try session.closeImage(orphan) }
        documents.items.removeAll { $0 === closing }

        // The whole transaction is a file operation: Quit waits for it and
        // a copy finishing during Quit is closed, not opened.
        let quittingApp = AppController()
        let quittingImage = try session.newImage(width: 32, height: 32)
        let quitting = try ImageDocument(session: session, image: quittingImage, name: "Quit")
        documents.items.append(quitting)
        check(quittingApp.applicationShouldTerminate(NSApp) == .terminateNow,
              "Quit proceeds while nothing is pending")
        quittingApp.snapshot(quitting)
        check(quittingApp.applicationShouldTerminate(NSApp) == .terminateLater,
              "a pending snapshot makes Quit wait")
        wait { quittingApp.applicationShouldTerminate(NSApp) == .terminateNow }
        check(quittingApp.frontDocument == nil,
              "a snapshot finishing during Quit is closed, not opened")
        documents.items.removeAll { $0 === quitting }

        document.snapshotHandler = nil
        controller.window?.orderOut(nil)
        documents.items.removeAll { $0 === document }
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

    /// The native-filter catalog, its Filter ▸ Native menu and the
    /// generic form: typed preview writes for the supported kinds, a
    /// refused value keeping the preview alive, cancel/apply semantics,
    /// the edit/layer/save gates and a clean close without an orphaned
    /// session.
    private static func exerciseNativeFilterForms(_ session: EngineSession, work: URL,
                                                  documents: DocumentList) throws {
        let operations = try session.filterOperations()
        check(operations.count > 40, "the catalog lists the engine's operations (\(operations.count))")
        let gaussian = operations.first { $0.name == GaussianBlurPanel.operation }
        check(gaussian?.support == .supported, "Gaussian Blur is a supported native operation")
        let displace = operations.first { $0.name == "gegl:displace" }
        check(displace?.support == .needsAuxInput, "Displace is flagged as needing a second input")
        let curves = operations.first { $0.name == "gimp:curves" }
        check(curves?.support == .needsConfig, "Curves is flagged as needing a dedicated editor")
        let median = operations.first { $0.name == "gegl:median-blur" }
        let overlay = operations.first { $0.name == "gegl:color-overlay" }
        check(median?.support == .supported && overlay?.support == .supported,
              "Median Blur and Color Overlay are supported native operations")

        // The catalog merges into the Filter categories next to the
        // dedicated Gaussian command and the plug-in items.
        let mainMenu = MainMenu.make()
        NSApp.mainMenu = mainMenu
        PlugInMenus.install(try session.procedures(), in: mainMenu)
        NativeFilterMenus.install(operations, in: mainMenu)
        func submenu(_ path: [String]) -> NSMenu? {
            path.reduce(mainMenu as NSMenu?) { menu, title in menu?.item(withTitle: title)?.submenu }
        }
        func nativeItem(_ name: String) -> NSMenuItem? {
            for category in submenu(["Filter"])?.items ?? [] {
                if let found = category.submenu?.items.first(where: {
                    ($0.representedObject as? NativeFilterCommand)?.operation.name == name
                }) { return found }
            }
            return nil
        }
        check(submenu(["Filter"])?.item(withTitle: "Native") == nil,
              "the catalog merges into the Filter categories without a Native submenu")
        let blurItems = submenu(["Filter", "Blur"])?.items.map(\.title) ?? []
        check(blurItems.first == "Gaussian Blur…" && blurItems.contains("Median Blur…"),
              "Filter ▸ Blur keeps the dedicated command and gains the catalog's operations (\(blurItems))")
        check(nativeItem("gegl:gaussian-blur") == nil, "the catalog's own Gaussian Blur stays out")
        check(nativeItem("gegl:displace")?.title == "Displace (needs a second layer as its source)"
                && nativeItem("gimp:curves")?.title == "Curves (needs a dedicated editor)",
              "inapplicable operations stay listed with their reason")
        check(submenu(["Filter", "Render", "Pattern"])?.items.isEmpty == false,
              "the plug-in categories are intact after the native install")

        let image = try session.newImage(width: 64, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Native Forms")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        document.beginStroke(at: .init(x: 8, y: 32, pressure: 1))
        document.continueStroke([.init(x: 56, y: 32, pressure: 1, timeMilliseconds: 40)])
        document.endStroke()
        document.inputQueue.sync {}
        spin()
        let painted = pixel(session, image, x: 8, y: 30)

        func wait() {
            let deadline = Date().addingTimeInterval(10)
            while document.pendingWork > 0 && Date() < deadline { spin(0.02) }
            spin()
        }
        func open(_ operation: EngineSession.FilterOperation) -> NativeFilterPanel? {
            controller.openNativeFilter(operation)
            let deadline = Date().addingTimeInterval(10)
            while controller.previewPanel == nil && Date() < deadline { spin(0.02) }
            return controller.previewPanel as? NativeFilterPanel
        }

        // Menu validation: supported operations enable, the others don't.
        if let item = nativeItem("gegl:median-blur") {
            check(controller.validateMenuItem(item), "a supported operation's menu item is enabled")
        } else { check(false, "Median Blur has a menu item") }
        if let item = nativeItem("gegl:displace") {
            check(!controller.validateMenuItem(item), "an auxiliary-input operation stays disabled")
        } else { check(false, "Displace has a menu item") }

        // The generic form on the same operation the dedicated panel
        // covers: number, bool and enum roundtrips through typed writes.
        guard let gaussianOp = gaussian, let panel = open(gaussianOp), let filter = panel.filter else {
            check(false, "the generic Gaussian form opens")
            return
        }
        check(document.filterPreviewIsOpen, "the form marks the preview open")
        panel.window?.contentView?.layoutSubtreeIfNeeded()
        let settingsGrid = panel.window?.contentView.flatMap { descendant(of: $0, as: NSGridView.self) }
        check(settingsGrid.map { $0.frame.width > 0 && $0.frame.height > 0 && !$0.visibleRect.isEmpty } == true,
              "the settings grid occupies visible space in the real panel")
        let visibleNumber = panel.window?.contentView.flatMap { descendant(of: $0, as: FilterNumberRow.self) }
        check(visibleNumber.map { $0.field.visibleRect.width >= 40 && $0.field.visibleRect.height >= 16 } == true,
              "a filter's editable number field is actually visible")
        panel.setProperty("std-dev-x", .number(20))
        panel.setProperty("std-dev-y", .number(20))
        wait()
        check((try? session.filterProperty(filter, "std-dev-x")) == .number(20)
                && (try? session.filterProperty(filter, "std-dev-y")) == .number(20),
              "the typed number write round-trips through the session")
        let blurred = pixel(session, image, x: 8, y: 30)
        check(blurred != nil && blurred != painted, "the number preview changes pixels (\(painted ?? []) → \(blurred ?? []))")

        // A programmatic NaN write rides the same request path: whatever
        // the engine answers must land — a NaN request never equals
        // itself, so value-equality staleness would drop its answer.
        panel.setProperty("std-dev-x", .number(.nan))
        wait()
        if case .number(let stored) = try? session.filterProperty(filter, "std-dev-x"), stored == 20 {
            check(panel.lastError?.isEmpty == false,
                  "a refused NaN write keeps the form's error visible")
        } else {
            check(controller.previewPanel === panel && document.filterPreviewIsOpen,
                  "a NaN write the engine accepts leaves the form alive")
        }
        panel.setProperty("std-dev-x", .number(20))
        wait()
        check((try? session.filterProperty(filter, "std-dev-x")) == .number(20),
              "the form keeps taking writes after a NaN one")

        let choices = (try? session.filterEnumChoices("gegl:gaussian-blur", property: "filter")) ?? []
        check(choices.count >= 2 && choices.contains(where: { !$0.label.isEmpty }),
              "the enum property lists its choices with labels (\(choices.map(\.nick)))")
        if let nick = choices.first(where: { $0.nick == "fir" })?.nick ?? choices.last?.nick {
            panel.setProperty("filter", .enumeration(nick))
            wait()
            check((try? session.filterProperty(filter, "filter")) == .enumeration(nick),
                  "the typed enum write round-trips by nick (\(nick))")
        }
        let clipDefault = (try? session.filterProperty(filter, "clip-extent")) == .boolean(false)
        panel.setProperty("clip-extent", .boolean(!clipDefault))
        wait()
        check((try? session.filterProperty(filter, "clip-extent")) == .boolean(!clipDefault),
              "the typed bool write round-trips")

        // Cancel restores the layer and leaves no session or history.
        let undoBeforeCancel = document.undoInfo.undoCount
        controller.cancelOperation(nil)
        wait()
        check(controller.previewPanel == nil && !document.filterPreviewIsOpen,
              "Escape cancels the form")
        check(document.undoInfo.undoCount == undoBeforeCancel,
              "cancel adds no undo step")
        check(pixel(session, image, x: 8, y: 30) == painted, "cancel restores the layer's pixels")
        check((try? session.filterProperty(filter, "std-dev-x")) == nil,
              "the aborted session is gone")

        // Apply commits once: one undo step, named after the operation.
        guard let again = open(gaussianOp) else {
            check(false, "the generic form reopens for Apply")
            return
        }
        again.setProperty("std-dev-x", .number(10))
        again.setProperty("std-dev-y", .number(10))
        wait()
        let undoBeforeApply = document.undoInfo.undoCount
        again.commit()
        let applyDeadline = Date().addingTimeInterval(10)
        while controller.previewPanel != nil && Date() < applyDeadline { spin(0.02) }
        wait()
        check(document.undoInfo.undoCount == undoBeforeApply + 1,
              "Apply adds exactly one undo step")
        check(document.undoInfo.nextUndo.contains("Gaussian Blur"),
              "the undo step names the operation (\(document.undoInfo.nextUndo))")

        // Median Blur: an integer write, then a refused one that must
        // keep the preview available and leave the error visible.
        guard let medianOp = median, let medianPanel = open(medianOp), let medianFilter = medianPanel.filter else {
            check(false, "the Median Blur form opens")
            return
        }
        medianPanel.setProperty("radius", .integer(12))
        wait()
        check((try? session.filterProperty(medianFilter, "radius")) == .integer(12),
              "the typed integer write round-trips")
        medianPanel.setProperty("radius", .integer(.max))
        wait()
        check(medianPanel.lastError != nil && controller.previewPanel === medianPanel,
              "a refused value keeps the form open with its error visible (\(medianPanel.lastError ?? "no error"))")
        medianPanel.setProperty("radius", .integer(6))
        wait()
        check((try? session.filterProperty(medianFilter, "radius")) == .integer(6),
              "the preview still accepts writes after a refused one")

        // While the form previews, layer changes, edits and file writes
        // are gated with a reason; pan/zoom stay free.
        document.selectLayer(document.activeLayer ?? 0)
        check(controller.statusBar.message.contains("preview"), "a layer pick is refused with a reason")
        document.createGroup()
        check(controller.statusBar.message.contains("preview"), "a layer change is refused with a reason")
        controller.saveDocument(nil)
        check(controller.statusBar.message.contains("saving or exporting") && document.fileState.nativeURL == nil,
              "Save is refused while the preview is open")
        controller.zoom(to: 200)
        check(controller.canvas.zoomPercent == 200, "zoom stays usable during the preview")

        // A refused commit (a clipboard transfer owns the document) keeps
        // the form; cancellation still works.
        document.copyPixels(.merged, background: .white, consume: { _ in }, completion: { _ in })
        check(document.isTransferringClipboard, "a clipboard transfer runs during the preview")
        medianPanel.commit()
        spin(0.2)
        check(controller.previewPanel === medianPanel && medianPanel.lastError != nil,
              "a refused Apply keeps the form and reports the error")
        medianPanel.cancel()
        wait()
        check(controller.previewPanel == nil && !document.filterPreviewIsOpen,
              "Cancel still ends the preview after a refused Apply")
        check((try? session.filterProperty(medianFilter, "radius")) == nil,
              "the cancelled session is gone")

        // Color Overlay: an sRGBA color write and readback.
        guard let overlayOp = overlay, let colorPanel = open(overlayOp), let colorFilter = colorPanel.filter else {
            check(false, "the Color Overlay form opens")
            return
        }
        colorPanel.setProperty("value", .color(NSColor(srgbRed: 1, green: 0.25, blue: 0.5, alpha: 1)))
        wait()
        if case .color(let color) = try? session.filterProperty(colorFilter, "value"),
           let srgb = color.usingColorSpace(.sRGB) {
            check(abs(srgb.redComponent - 1) < 0.01 && abs(srgb.greenComponent - 0.25) < 0.01
                    && abs(srgb.blueComponent - 0.5) < 0.01,
                  "the typed color write round-trips (\(srgb.redComponent),\(srgb.greenComponent),\(srgb.blueComponent))")
        } else { check(false, "the color property reads back") }
        let covered = pixel(session, image, x: 40, y: 40)
        check((covered?[0] ?? 0) > 200 && (covered?[1] ?? 255) < 160,
              "the color preview changes pixels (\(covered ?? []))")
        colorPanel.cancel()
        wait()
        check((try? session.filterProperty(colorFilter, "value")) == nil,
              "the cancelled color session is gone")

        // Value Invert has no editable properties: the form shows a note
        // instead of a settings grid, and the preview still commits and
        // cancels like any other — no empty grid, no immediate apply.
        let invert = operations.first { $0.name == "gegl:value-invert" }
        check(invert?.support == .supported, "Value Invert is a supported native operation")
        let preInvert = pixel(session, image, x: 8, y: 30)
        guard let invertOp = invert, let invertPanel = open(invertOp) else {
            check(false, "the no-settings form opens")
            return
        }
        invertPanel.window?.contentView?.layoutSubtreeIfNeeded()
        let noteGrid = invertPanel.window?.contentView.flatMap { descendant(of: $0, as: NSGridView.self) }
        check(noteGrid?.cell(atColumnIndex: 0, rowIndex: 0).contentView?.visibleRect.isEmpty == false,
              "the no-settings explanation is visible in its panel")
        let undoBeforeInvert = document.undoInfo.undoCount
        check(pixel(session, image, x: 8, y: 30) != preInvert,
              "the no-settings preview changes pixels")
        invertPanel.cancel()
        wait()
        check(pixel(session, image, x: 8, y: 30) == preInvert
                && document.undoInfo.undoCount == undoBeforeInvert
                && !document.filterPreviewIsOpen,
              "cancel on a no-settings form restores pixels and leaves no history")
        guard let invertAgain = open(invertOp) else {
            check(false, "the no-settings form reopens")
            return
        }
        invertAgain.commit()
        let invertDeadline = Date().addingTimeInterval(10)
        while controller.previewPanel != nil && Date() < invertDeadline { spin(0.02) }
        wait()
        try? document.reload()
        check(document.undoInfo.undoCount == undoBeforeInvert + 1
                && document.undoInfo.nextUndo.contains("Invert"),
              "Apply on a no-settings form adds one named undo step (\(document.undoInfo.nextUndo))")
        check(pixel(session, image, x: 8, y: 30) != preInvert,
              "the committed no-settings filter changed the layer")

        if let convolution = operations.first(where: { $0.name == "gegl:convolution-matrix" }),
           let tall = open(convolution), let content = tall.window?.contentView,
           let scroll = descendant(of: content, as: NSScrollView.self),
           let grid = descendant(of: content, as: NSGridView.self),
           let first = grid.cell(atColumnIndex: 1, rowIndex: 0).contentView,
           let last = grid.cell(atColumnIndex: 1, rowIndex: grid.numberOfRows - 1).contentView {
            content.layoutSubtreeIfNeeded()
            check(scroll.hasVerticalScroller && grid.frame.height > scroll.contentSize.height
                    && !first.visibleRect.isEmpty,
                  "a tall form initially shows its first setting in a bounded scroll view")
            last.scrollToVisible(last.bounds)
            check(!last.visibleRect.isEmpty, "the last setting of a tall form can scroll into view")
            tall.cancel()
            wait()
        } else { check(false, "the tall Convolution Matrix form opens") }

        // A begin must queue behind pending input: a blocked job stands
        // in for a committed stroke still on its way to the engine. The
        // open returns at once; session and panel land only after the
        // input has drained. Median Blur's properties are warm in the
        // catalog, so nothing but the input can delay the start.
        let beforePending = pixel(session, image, x: 8, y: 30)
        let gate = DispatchSemaphore(value: 0)
        document.inputQueue.async { gate.wait() }
        // Released from a background queue after a beat: a synchronous
        // begin would stall measurably here, a queued one returns at once.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { gate.signal() }
        let openStart = DispatchTime.now()
        controller.openNativeFilter(medianOp)
        let openMilliseconds = milliseconds(since: openStart)
        check(controller.previewPanel == nil && document.filterPreviewIsOpen,
              "a filter open behind pending input returns before its panel exists")
        check(openMilliseconds < 500,
              "the open does not wait on the input queue (\(Int(openMilliseconds)) ms)")
        // Escape cancels the pending start before its session is used.
        controller.cancelOperation(nil)
        check(controller.previewPanel == nil && !document.filterPreviewIsOpen,
              "Escape cancels a pending filter start")
        let undoBeforePending = document.undoInfo.undoCount
        wait()
        check(document.undoInfo.undoCount == undoBeforePending && controller.previewPanel == nil,
              "a cancelled pending start leaves no session, panel or undo step")
        check(pixel(session, image, x: 8, y: 30) == beforePending, "…and changes no pixels")

        // A document close during a pending start drains the counted
        // begin and the image takes the begun session with it.
        let pendingImage = try session.newImage(width: 16, height: 16)
        let pendingNative = work.appendingPathComponent("pending-start.xcf")
        try session.save(pendingImage, to: pendingNative.path)
        let pendingDocument = try ImageDocument(session: session, image: pendingImage,
                                                name: "Pending", openedFrom: pendingNative)
        documents.items.append(pendingDocument)
        let pendingController = DocumentWindowController(document: pendingDocument)
        pendingController.showWindow(nil)
        let pendingGate = DispatchSemaphore(value: 0)
        pendingDocument.inputQueue.async { pendingGate.wait() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { pendingGate.signal() }
        let pendingStart = DispatchTime.now()
        pendingController.openNativeFilter(medianOp)
        check(pendingController.previewPanel == nil && milliseconds(since: pendingStart) < 500,
              "a pending start on a clean image returns promptly too")
        var pendingClosed: Bool?
        pendingController.requestClose { pendingClosed = $0 }
        check(pendingClosed == nil, "the close waits for the pending begin")
        let pendingDeadline = Date().addingTimeInterval(10)
        while pendingClosed == nil && Date() < pendingDeadline { spin(0.02) }
        check(pendingClosed == true && !pendingDocument.hasUnsavedChanges,
              "closing during a pending start asks nothing and finishes")
        let destroyDeadline = Date().addingTimeInterval(10)
        while (try? session.info(pendingImage)) != nil && Date() < destroyDeadline { spin(0.02) }
        check((try? session.info(pendingImage)) == nil,
              "the image is destroyed and the begun session goes with it")
        documents.items.removeAll { $0 === pendingDocument }

        // A clean close cancels the open preview and leaves no session
        // behind: the image's own close path is the drain.
        let cleanImage = try session.newImage(width: 16, height: 16)
        let native = work.appendingPathComponent("native-clean.xcf")
        try session.save(cleanImage, to: native.path)
        let cleanDocument = try ImageDocument(session: session, image: cleanImage,
                                              name: "Clean", openedFrom: native)
        documents.items.append(cleanDocument)
        let cleanController = DocumentWindowController(document: cleanDocument)
        cleanController.showWindow(nil)
        cleanController.openNativeFilter(overlayOp)
        let cleanDeadline = Date().addingTimeInterval(10)
        while cleanController.previewPanel == nil && Date() < cleanDeadline { spin(0.02) }
        let cleanFilter = cleanController.previewPanel?.filter
        var closed: Bool?
        cleanController.requestClose { closed = $0 }
        while closed == nil && cleanController.window?.attachedSheet == nil && Date() < cleanDeadline { spin(0.02) }
        check(closed == true && cleanController.window?.attachedSheet == nil,
              "closing a clean image cancels the generic preview without prompting")
        if let sheet = cleanController.window?.attachedSheet {
            NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue)
        }
        while (try? session.info(cleanImage)) != nil && Date() < cleanDeadline { spin(0.02) }
        check((try? session.filterProperty(cleanFilter ?? 0, "value")) == nil,
              "the closed image's filter session is gone")
        documents.items.removeAll { $0 === cleanDocument }
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
