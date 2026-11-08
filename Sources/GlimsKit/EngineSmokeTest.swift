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

    static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "ok  " : "FAIL") \(message)")
        fflush(stdout)
        if !condition { failures += 1 }
    }

    private nonisolated static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }

    /// Lets queued main-queue work (engine events) run.
    static func spin(_ seconds: TimeInterval = 0.05) {
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

    static func pixel(_ session: EngineSession, _ image: Int32, x: Int, y: Int) -> [UInt8]? {
        guard let rendered = try? session.render(image, scale: 1, area: CGRect(x: x, y: y, width: 1, height: 1)),
              let data = rendered.dataProvider?.data as Data? else { return nil }
        return Array(data.prefix(4))
    }

    /// One RGBA pixel of a rendered CGImage (row 0 at the top).
    private static func argb(_ image: CGImage, x: Int, y: Int) -> [UInt8]? {
        guard x >= 0, y >= 0, x < image.width, y < image.height,
              let data = image.dataProvider?.data as Data? else { return nil }
        let offset = y * image.bytesPerRow + x * 4
        guard offset + 3 < data.count else { return nil }
        return Array(data[offset...offset + 3])
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

        // Only the focused linked-close case needs its slow-loader plug-in
        // in place before the engine's first plug-in query.
        if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "linked-close",
           !installLinkedCloseSlowLoader(work: work) {
            return 2
        }

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
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "file-safety" {
                try exerciseFileSafety(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (file safety)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "linked-close" {
                try exerciseLinkedClose(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (linked-close)" : "FAILED: \(failures) failure(s)")

                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "indexed-wrapper" {
                try exerciseIndexedWrapper(session)
                print(failures == 0 ? "PASSED (indexed wrapper)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "layer-source" {
                try exerciseLayerSourceCache(session, documents: documents)
                print(failures == 0 ? "PASSED (layer source)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "native-guides" {
                try exerciseGuideCache(session, documents: documents)
                print(failures == 0 ? "PASSED (native guides)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "brush-chooser" {
                try exerciseBrushChooserPresentation(session, documents: documents)
                print(failures == 0 ? "PASSED (brush chooser)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "resource-gradient" {
                try exerciseResourceGradient(session, documents: documents)
                print(failures == 0 ? "PASSED (resource-gradient)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "pattern-chooser" {
                try exercisePatternChooser(session, documents: documents)
                print(failures == 0 ? "PASSED (pattern chooser)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "brush-resource" {
                try exerciseSelectedBrushStrokes(session, documents: documents)
                print(failures == 0 ? "PASSED (brush-resource)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "pattern-fill" {
                try exercisePatternFill(session, documents: documents)
                print(failures == 0 ? "PASSED (pattern-fill)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "gradient-chooser" {
                try exerciseGradientChooser(session, documents: documents)
                print(failures == 0 ? "PASSED (gradient chooser)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "vector-style" {
                try exerciseVectorStyleForm(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (vector style)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "guides-controls" {
                try exerciseGuidesControls(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (guides controls)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "layer-source-controls" {
                try exerciseLayerSourceControls(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (layer source controls)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }

            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "plugin-responsiveness" {
                try measurePluginStalls(session, work: work)
                print(failures == 0 ? "PASSED (plugin responsiveness)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "history-isolation" {
                try exercisePendingEditScope(session, documents: documents)
                try exerciseHistoryAndSnapshots(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (history isolation)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "stroke-selection-controls" {
                try exerciseStrokeSelectionControls(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (stroke-selection-controls)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "grid-controls" {
                try exerciseGridControls(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (grid controls)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "pixel-rulers" {
                try exercisePixelRulers(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (pixel rulers)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }



            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "canvas-overlays" {
                try exerciseCanvasOverlays(session, documents: documents)
                print(failures == 0 ? "PASSED (canvas overlays)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "indexed-controls" {
                try exerciseIndexedControls(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (indexed controls)" : "FAILED: \(failures) failure(s)")

                return failures == 0 ? 0 : 1
            }

            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "path-anchors" {
                try exercisePathAnchors(session, documents: documents)
                print(failures == 0 ? "PASSED (path anchors)" : "FAILED: \(failures) failure(s)")

                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "floating-controls" {
                try exerciseFloatingControls(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (floating controls)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "layer-multiselection-controls" {
                try exerciseLayerMultiselectionControls(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (layer-multiselection-controls)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "guide-dragging" {
                try exerciseGuideDragging(session, work: work, documents: documents)
                print(failures == 0 ? "PASSED (guide dragging)" : "FAILED: \(failures) failure(s)")
                return failures == 0 ? 0 : 1
            }
            if let selected = ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] {
                check(false, "unknown engine smoke case: \(selected)")

                return 1
            }
            try exerciseDocument(session, work: work, documents: documents)
            try exerciseFileSafety(session, work: work, documents: documents)
            try exerciseFileAdmission(session, work: work, documents: documents)
            try exerciseRevert(session, work: work, documents: documents)
            try exerciseFileImports(session, work: work, documents: documents)
            try exerciseFillForm(session, documents: documents)
            try exerciseColorConversions(session, work: work, documents: documents)
            try exerciseColorProfiles(session, work: work, documents: documents)
            try exercisePrinting(session, work: work, documents: documents)
            try exerciseRecovery(session, work: work, documents: documents)
            try exerciseRecoveryInterface(session, work: work, documents: documents)
            try exerciseClipboard(session, documents: documents)
            try exerciseClipboardReentrantClose(session, documents: documents)
            try exercisePreviewLifetimes(session, work: work, documents: documents)
            try exerciseDisplayDensity(session, documents: documents)
            try exerciseTools(session, documents: documents)
            try exerciseEditing(session, documents: documents)
            try exerciseLayerTree(session, documents: documents)
            try exerciseLayerMasks(session, documents: documents)
            try exerciseEffectBindings(session)
            try exerciseChannelBindings(session, work: work)
            try exerciseChannelTargets(session, documents: documents)
            try exerciseTargetCommands(session, documents: documents)
            try exerciseTargetHistory(session, documents: documents)
            try exercisePreferences(session, documents: documents)
            try exercisePaths(session, documents: documents)
            try exercisePathAnchors(session, documents: documents)
            try exercisePathFillAndVector(session, work: work, documents: documents)
            try exerciseVectorStyleForm(session, work: work, documents: documents)
            try exercisePaletteControls(session, documents: documents)
            try exerciseGuidesControls(session, work: work, documents: documents)
            try exerciseGridControls(session, work: work, documents: documents)
            try exercisePixelRulers(session, work: work, documents: documents)
            try exerciseGuideDragging(session, work: work, documents: documents)
            try exerciseFloatingControls(session, work: work, documents: documents)
            try exerciseLayerMultiselectionControls(session, work: work, documents: documents)

            try exerciseStrokeSelectionControls(session, work: work, documents: documents)


            try exerciseIndexedControls(session, work: work, documents: documents)

            try exerciseCanvasOverlays(session, documents: documents)
            try exercisePendingEditScope(session, documents: documents)
            try exerciseHistoryAndSnapshots(session, work: work, documents: documents)
            try exercisePlugInCommands(session, documents: documents)
            try exerciseNativeFilterForms(session, work: work, documents: documents)
            try exerciseFilterStackInterface(session, work: work, documents: documents)
            try measurePluginStalls(session, work: work)
            try exerciseResourceCatalog(session)
            try exerciseGuideCache(session, documents: documents)
            try exerciseLayerSourceCache(session, documents: documents)
            try exerciseLayerSourceControls(session, work: work, documents: documents)

            try exerciseIndexedWrapper(session)
            try exerciseResourceGradient(session, documents: documents)
            try exerciseResourceThumbnails(session)
            try exerciseSelectedBrushStrokes(session, documents: documents)
            try exerciseBrushChooserSelection(session, documents: documents)
            try exerciseBrushChooserPresentation(session, documents: documents)

            try exercisePatternFill(session, documents: documents)
            try exercisePatternChooser(session, documents: documents)
            try exerciseGradientChooser(session, documents: documents)
        } catch {
            check(false, "unexpected engine error: \(error)")
        }

        print(failures == 0 ? "PASSED" : "FAILED: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }

    /// Exercises every channel/component facade binding against real
    /// engine state before the palette starts depending on it.
    private static func exerciseChannelBindings(_ session: EngineSession, work: URL) throws {
        let image = try session.newImage(width: 48, height: 32)
        defer { try? session.closeImage(image) }
        let components = try session.components(image)
        let rgb: EngineSession.Components = [.red, .green, .blue]
        check(components.mode == .rgb && components.supported.isSuperset(of: rgb)
                && components.active.isSuperset(of: rgb) && components.visible.isSuperset(of: rgb),
              "Swift component reads preserve the RGB model and separate active/visible bits")
        let undoBeforeComponents = try session.undoInfo(image)
        try session.setComponents(image, activeMask: [.blue], activeValues: [],
                                   visibleMask: [.red], visibleValues: [])
        let changed = try session.components(image)
        check(!changed.active.contains(.blue) && changed.active.contains(.red)
                && !changed.visible.contains(.red) && changed.visible.contains(.blue),
              "Swift component writes change only the requested edit and visibility bits")
        check(try session.undoInfo(image) == undoBeforeComponents,
              "component display and edit toggles add no undo step")
        try session.setComponents(image, activeMask: components.supported, activeValues: components.active,
                                   visibleMask: components.supported, visibleValues: components.visible)

        let area = CGRect(x: 4, y: 5, width: 8, height: 6)
        try session.select(.rectangle(area), image: image)
        let saved = try session.channelFromSelection(image, name: "Coverage α")
        var rows = try session.channels(image)
        check(rows.count == 1 && rows.first?.id == saved && rows.first?.name == "Coverage α"
                && rows.first?.isSelected == true && rows.first?.isVisible == false
                && rows.first?.isQuickMask == false,
              "saving a selection through Swift returns the selected hidden channel and UTF-8 name")
        try session.changeChannel(saved, image: image, .init(name: "Saved α", isVisible: true,
                                   opacity: 0.4, color: NSColor.green.withAlphaComponent(0.8)))
        rows = try session.channels(image)
        let row = rows.first
        let color = row?.color.usingColorSpace(.sRGB)
        check(row?.name == "Saved α" && row?.isVisible == true
                && abs((row?.opacity ?? 0) - 0.4) < 0.000001
                && abs((color?.alphaComponent ?? 0) - 0.4) < 0.000001
                && (color?.greenComponent ?? 0) > 0.99,
              "channel attributes preserve color, name, visibility and explicit opacity precedence")
        try session.changeChannel(saved, image: image, .init(isVisible: false))
        try session.channelCommand(.select, channel: 0, image: image)
        check(try session.channels(image).allSatisfy { !$0.isSelected },
              "channel zero returns the native target to layers")
        try session.select(.none, image: image)
        try session.channelToSelection(saved, image: image, operation: .replace)
        check(try session.selectionBounds(image: image) == area,
              "the Swift channel-to-selection binding restores exact selection bounds")
        let duplicate = try session.channelCommand(.duplicate, channel: saved, image: image)
        let duplicatedRows = try session.channels(image)
        check(duplicate != nil && duplicate != saved
                && duplicatedRows.first(where: { $0.id == duplicate })?.isSelected == true,
              "channel Duplicate returns and selects its new native channel")
        if let duplicate { try session.channelCommand(.delete, channel: duplicate, image: image) }
        check(try session.channels(image).count == 1, "channel Delete removes only its chosen channel")
        try session.channelCommand(.select, channel: 0, image: image)
        try session.setQuickMask(image, enabled: true)
        let quick = try session.quickMask(image)
        let quickRows = try session.channels(image)
        check(quick.enabled && quick.channel != 0
                && quickRows.contains { $0.id == quick.channel && $0.isQuickMask && $0.isSelected },
              "Quick Mask exposes its selected native drawable through Swift")
        check(try session.selectionBounds(image: image) == nil,
              "enabling Quick Mask moves the selection into the channel")
        try session.setQuickMask(image, enabled: false)
        let disabled = try session.quickMask(image)
        let restoredBounds = try session.selectionBounds(image: image)
        check(!disabled.enabled && disabled.channel == 0
                && restoredBounds == area,
              "disabling Quick Mask restores the original selection without changing it")

        let file = work.appendingPathComponent("swift-channels.xcf")
        try session.save(image, to: file.path)
        let reopened = try session.openImage(path: file.path)
        defer { try? session.closeImage(reopened) }
        let restored = try session.channels(reopened)
        check(restored.count == 1 && restored.first?.name == "Saved α"
                && abs((restored.first?.opacity ?? 0) - 0.4) < 0.000001,
              "saved channel names and overlay opacity survive an XCF round trip through Swift")
        if let id = restored.first?.id {
            try session.select(.none, image: reopened)
            try session.channelToSelection(id, image: reopened, operation: .replace)
            check(try session.selectionBounds(image: reopened) == area,
                  "saved channel pixels survive the Swift XCF round trip")
        }
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

    /// File ▸ Open as Layers… and Place as Link Layer…: a saved native
    /// image takes a chosen file's layers — or a genuine link layer on
    /// engines that have them — through the same exclusive admission a
    /// file write gets. Covers accepted input draining across documents,
    /// the busy refusals, file identity, the single undo step, failure
    /// recovery, a close during the load and the older-engine answer.
    private static func exerciseFileImports(_ session: EngineSession, work: URL,
                                            documents: DocumentList) throws {
        let directory = work.appendingPathComponent("file-imports")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let brush = EngineSession.Brush(size: 8, opacity: 1, red: 0, green: 0, blue: 0, pressureSize: false)
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func succeeded(_ result: Result<ImageDocument.ImportOutcome, Error>?,
                       as expected: ImageDocument.ImportOutcome) -> Bool {
            guard case .success(let outcome) = result else { return false }
            return outcome == expected
        }

        // The sources: a three-layer XCF and a small PNG to place.
        let sourceImage = try session.newImage(width: 48, height: 48)
        _ = try session.layerCommand(.new, image: sourceImage)
        _ = try session.layerCommand(.new, image: sourceImage)
        let sourceXCF = directory.appendingPathComponent("source.xcf")
        try session.save(sourceImage, to: sourceXCF.path)
        try session.closeImage(sourceImage)
        let linkPNG = directory.appendingPathComponent("link.png")
        let linkSource = try session.newImage(width: 24, height: 24)
        try session.select(.all, image: linkSource)
        try session.fill(image: linkSource, at: .zero, mode: .selection, color: .red)
        try session.export(linkSource, to: linkPNG.path)
        try session.closeImage(linkSource)

        let image = try session.newImage(width: 64, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Imports")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        defer {
            document.onWillChangeLayers = nil
            document.onError = nil
            documents.items.removeAll { $0 === document }
            document.closeImageWhenDrained()
        }
        var errors: [String] = []
        document.onError = { errors.append($0) }
        func thumbPixel(_ drawable: Int32, _ x: Int, _ y: Int) -> [UInt8]? {
            guard let cg = try? session.drawableThumbnail(drawable, image: image, maxSize: 32),
                  let data = cg.dataProvider?.data as Data? else { return nil }
            let offset = (y * cg.width + x) * 4
            guard offset + 4 <= data.count else { return nil }
            return Array(data[offset..<offset + 4])
        }
        func luminance(_ rgba: [UInt8]?) -> Int {
            guard let rgba else { return -1 }
            return (Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2])) / 3
        }

        // The import target starts as a clean saved native image whose
        // file bytes the imports must leave alone.
        let native = directory.appendingPathComponent("drawing.xcf")
        var saved = false
        document.save(to: native) { error in
            if error == nil { document.noteSaved(to: native); saved = true }
        }
        wait { saved && document.pendingWork == 0 }
        check(saved && document.fileState.nativeURL == native && !document.hasUnsavedChanges,
              "the import target starts as a clean saved native image")
        let nativeBytes = try Data(contentsOf: native)
        let nativeName = document.name
        let oldActive = document.activeLayer
        let oldUndo = document.undoInfo.undoCount
        var expectedLayers = document.layers.count

        // A stroke queued before the choice drains first; a field-style
        // delegate edit flushed during admission lands too. Both sit left
        // of the centered 48 px import, so the composite still shows them.
        document.inputQueue.async { usleep(150_000) }
        document.beginStroke(at: .init(x: 5, y: 30, pressure: 1), brush: brush)
        document.continueStroke([.init(x: 7, y: 30, pressure: 1)])
        document.endStroke()
        var flushedDuringAdmission = false
        document.onWillChangeLayers = {
            guard !flushedDuringAdmission else { return }
            flushedDuringAdmission = true
            document.beginStroke(at: .init(x: 5, y: 45, pressure: 1), brush: brush)
            document.continueStroke([.init(x: 7, y: 45, pressure: 1)])
            document.endStroke()
        }
        var outcome: Result<ImageDocument.ImportOutcome, Error>?
        document.openLayers(from: sourceXCF) { outcome = $0 }
        document.onWillChangeLayers = nil
        check(flushedDuringAdmission, "admission flushes an in-flight field edit before the load")
        check(EngineActivity.shared.isBusy, "an import holds the engine-wide busy gate")
        check(!document.acceptsEdits, "a pending import refuses edits in its document")
        document.beginStroke(at: .init(x: 60, y: 60, pressure: 1), brush: brush)
        check(!document.strokeIsActive, "a stroke behind a pending import is refused")
        if document.strokeIsActive { document.endStroke() }
        check(errors.contains { $0.contains("Wait") },
              "the refused edit explains the pending import (\(errors.last ?? "none"))")
        var second: Result<ImageDocument.ImportOutcome, Error>?
        document.openLayers(from: sourceXCF) { second = $0 }
        guard case .failure = second else {
            check(false, "a second import behind the gate is refused")
            return
        }
        wait { outcome != nil && document.pendingWork == 0 }
        check(succeeded(outcome, as: .openedLayers), "Open as Layers completes (\(outcome as Any))")
        spin()
        check(document.layers.count == expectedLayers + 3,
              "Open as Layers adds every layer of the source file")
        expectedLayers += 3
        check(document.activeLayer != oldActive
                && document.activeLayer == document.layers.first(where: \.isSelected)?.id,
              "the engine's imported selection becomes the active target through reload")
        check(document.undoInfo.undoCount > oldUndo, "the import is undoable")
        check(document.fileState.nativeURL == native && document.name == nativeName,
              "the import keeps native file identity and name")
        check(try Data(contentsOf: native) == nativeBytes,
              "the import does not rewrite the native file")
        check(document.hasUnsavedChanges, "the import marks the image unsaved")
        check((pixel(session, image, x: 6, y: 30)?[0] ?? 255) < 128
                && (pixel(session, image, x: 6, y: 45)?[0] ?? 255) < 128,
              "queued and admission-flushed strokes survive the import")

        // The imported stack is the new target: a stroke lands on it, not
        // on the layer that was active before the load.
        if let active = document.activeLayer, active != oldActive {
            document.beginStroke(at: .init(x: 42, y: 50, pressure: 1), brush: brush)
            document.continueStroke((43...46).map { .init(x: Double($0), y: 50, pressure: 1) })
            document.endStroke()
            wait { document.pendingWork == 0 }
            check(luminance(thumbPixel(active, 22, 25)) < 64,
                  "a stroke after the import paints the new active layer")
        } else {
            check(false, "the import leaves the imported layer active")
        }

        // The stroke is its own undo step; the next undo removes the
        // whole imported stack at once — the import is a single step.
        document.undo()
        wait { document.pendingWork == 0 }
        check(document.layers.count == expectedLayers && document.undoInfo.redoCount == 1,
              "the stroke is its own undo step")
        document.undo()
        wait { document.pendingWork == 0 }
        check(document.layers.count == expectedLayers - 3 && document.undoInfo.redoCount == 2,
              "one undo removes the whole imported stack as a single step")
        document.redo()
        document.redo()
        wait { document.pendingWork == 0 }
        check(document.layers.count == expectedLayers,
              "redo restores the import and the stroke")

        // A load that fails leaves the image editable and intact.
        var failed: Result<ImageDocument.ImportOutcome, Error>?
        document.openLayers(from: directory.appendingPathComponent("missing.xcf")) { failed = $0 }
        wait { failed != nil && document.pendingWork == 0 }
        guard case .failure(let loadError) = failed else {
            check(false, "a missing file fails the import (\(failed as Any))")
            return
        }
        check(!String(describing: loadError).isEmpty,
              "the failure carries the engine's native error message")
        check(document.layers.count == expectedLayers,
              "a failed import inserts nothing")
        check(document.acceptsEdits, "the document edits again after a failed import")
        document.beginStroke(at: .init(x: 30, y: 16, pressure: 1), brush: brush)
        document.endStroke()
        wait { document.pendingWork == 0 }
        check((pixel(session, image, x: 30, y: 16)?[0] ?? 255) < 128,
              "edits work again after the failed import")

        // A native import establishes a new target even when the prior
        // known pick failed after its mask disappeared from the queue.
        let healingImage = try session.newImage(width: 64, height: 64)
        let healing = try ImageDocument(session: session, image: healingImage, name: "Import target recovery")
        documents.items.append(healing)
        defer {
            documents.items.removeAll { $0 === healing }
            healing.closeImageWhenDrained()
        }
        guard let healingLayer = healing.activeLayer else { throw NoWindow() }
        healing.onError = { _ in }
        healing.addMask(healingLayer, source: .white, edit: false)
        wait { healing.pendingWork == 0 }
        healing.run { session, image in
            try session.applyLayerMask(healingLayer, image: image, mode: .discard)
        }
        healing.editMask(healingLayer)
        wait { healing.pendingWork == 0 }
        check(healing.activeDrawable == nil, "the import recovery starts with a refused stale mask target")
        var healingFailure: Result<ImageDocument.ImportOutcome, Error>?
        healing.openLayers(from: directory.appendingPathComponent("missing-again.xcf")) { healingFailure = $0 }
        wait { healingFailure != nil && healing.pendingWork == 0 }
        check(healing.activeDrawable == nil, "a failed import does not reopen the rejected paint target")
        var healed: Result<ImageDocument.ImportOutcome, Error>?
        healing.openLayers(from: sourceXCF) { healed = $0 }
        wait { healed != nil && healing.pendingWork == 0 }
        check(succeeded(healed, as: .openedLayers), "a valid import succeeds after the refused target")
        check(healing.activeDrawable != nil && healing.activeDrawable == healing.activeLayer,
              "successful import adopts its new drawable after a refused target pick")
        healing.fill(at: .zero, mode: .selection, color: .black, threshold: 0, sampleMerged: false)
        wait { healing.pendingWork == 0 }
        check((pixel(session, healingImage, x: 20, y: 20)?[0] ?? 255) < 64,
              "pixel edits reach the newly imported layer without another target pick")

        // Input accepted in another document before the choice drains
        // ahead of the load; edits there refuse behind the same gate.
        let otherImage = try session.newImage(width: 32, height: 32)
        let other = try ImageDocument(session: session, image: otherImage, name: "Other")
        documents.items.append(other)
        defer {
            documents.items.removeAll { $0 === other }
            other.closeImageWhenDrained()
        }
        other.inputQueue.async { usleep(200_000) }
        other.beginStroke(at: .init(x: 10, y: 10, pressure: 1), brush: brush)
        other.endStroke()
        var drained: Result<ImageDocument.ImportOutcome, Error>?
        document.openLayers(from: sourceXCF) { drained = $0 }
        other.beginStroke(at: .init(x: 20, y: 20, pressure: 1), brush: brush)
        check(!other.strokeIsActive, "another document's edits refuse behind the gate too")
        if other.strokeIsActive { other.endStroke() }
        wait { drained != nil && document.pendingWork == 0 }
        check(succeeded(drained, as: .openedLayers), "the drained import completes (\(drained as Any))")
        expectedLayers += 3
        spin()
        check(document.layers.count == expectedLayers,
              "the second import adds its layers on top")
        check((pixel(session, otherImage, x: 10, y: 10)?[0] ?? 255) < 128,
              "input accepted in another document before the import is preserved")
        check((pixel(session, otherImage, x: 20, y: 20)?[0] ?? 255) > 200,
              "the refused stroke in the other document made no pixel change")

        // A close while the load is queued waits for it, then destroys
        // the image; the import's completion still lands.
        let closingImage = try session.newImage(width: 32, height: 32)
        let closing = try ImageDocument(session: session, image: closingImage, name: "Closing Import")
        documents.items.append(closing)
        let closingController = DocumentWindowController(document: closing)
        closingController.showWindow(nil)
        defer {
            documents.items.removeAll { $0 === closing }
            closing.closeImageWhenDrained()
        }
        document.inputQueue.async { usleep(400_000) }
        var closingOutcome: Result<ImageDocument.ImportOutcome, Error>?
        closing.openLayers(from: sourceXCF) { closingOutcome = $0 }
        check(EngineActivity.shared.isBusy, "the closing document's import takes the gate")
        var closed: Bool?
        closingController.requestClose { closed = $0 }
        check(closed == nil && !closing.isClosing, "close waits while the import is queued")
        wait { closingOutcome != nil && closing.pendingWork == 0 && !EngineActivity.shared.isBusy }
        let sheetDeadline = Date().addingTimeInterval(5)
        while closingController.window?.attachedSheet == nil && Date() < sheetDeadline { spin(0.05) }
        if let sheet = closingController.window?.attachedSheet {
            NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue)
        }
        wait { closed != nil }
        check(closed == true && (try? session.info(closingImage)) == nil,
              "the deferred close destroys the image after its import lands")
        check(succeeded(closingOutcome, as: .openedLayers),
              "the closing document's import still reports its outcome")

        // Place: a genuine link layer where the engine has them (3.2+),
        // a clean unsupported answer elsewhere — never a raster fallback.
        let placeItem = NSMenuItem(title: "Place", action: #selector(DocumentWindowController.placeLinkFromFile(_:)),
                                   keyEquivalent: "")
        check(controller.validateMenuItem(placeItem) == (session.supportsLinkLayers != false),
              "the Place menu follows the engine's verified link-layer support")
        let beforePlace = document.layers.count
        let beforePlaceUndo = document.undoInfo.undoCount
        var placed: Result<ImageDocument.ImportOutcome, Error>?
        document.placeLink(from: linkPNG) { placed = $0 }
        wait { placed != nil && document.pendingWork == 0 }
        switch placed {
        case .success(.placedLink):
            check(document.layers.count == beforePlace + 1 && document.layers.contains { $0.kind == .link },
                  "Place adds one genuine link layer")
            let selectedLink = document.layers.first { $0.isSelected && $0.kind == .link }
            check(selectedLink?.id == document.activeLayer && selectedLink != nil,
                  "the placed link is the active target through reload")
            check(document.undoInfo.undoCount == beforePlaceUndo + 1, "Place is one undo step")
            let placedXCF = directory.appendingPathComponent("placed.xcf")
            var copySaved = false
            document.saveCopy(to: placedXCF) { copySaved = $0 == nil }
            wait { copySaved && document.pendingWork == 0 }
            check(copySaved, "the placed image saves a copy")
            let reopened = try session.openImage(path: placedXCF.path)
            let reopenedLayers = try session.layers(reopened)
            check(reopenedLayers.contains { $0.kind == .link },
                  "the saved copy keeps the link layer")
            let blueSource = try session.newImage(width: 24, height: 24)
            try session.select(.all, image: blueSource)
            try session.fill(image: blueSource, at: .zero, mode: .selection, color: .blue)
            try session.export(blueSource, to: linkPNG.path)
            try session.closeImage(blueSource)
            var updated = false
            let updateDeadline = Date().addingTimeInterval(10)
            while Date() < updateDeadline {
                spin(0.1)
                if let p = pixel(session, reopened, x: 32, y: 32), p[2] > 200 && p[0] < 60 {
                    updated = true
                    break
                }
            }
            check(updated, "the link layer rereads its changed source file")
            try session.closeImage(reopened)
        case .failure(let error):
            let status = (error as? EngineSession.EngineError)?.status
            check(status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue)
                    || EngineSession.supportsLinkLayers(version: session.version) != true,
                  "Place on an engine without link layers reports unsupported (\(error))")
            check(document.layers.count == beforePlace && !document.layers.contains { $0.kind == .link },
                  "an unsupported Place inserts nothing")
            check(document.acceptsEdits, "the document edits again after unsupported Place")
        default:
            check(false, "Place reports placed, cancelled or failed (\(placed as Any))")
        }
    }

    /// The Edit Fill sheet, including independent controls when two
    /// documents have sheets open and a refusal after opening the sheet.
    private static func exerciseFillForm(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func views<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            return (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, as: type) }
        }
        let first = try ImageDocument(session: session, image: session.newImage(width: 16, height: 16), name: "Fill A")
        let second = try ImageDocument(session: session, image: session.newImage(width: 16, height: 16), name: "Fill B")
        documents.items += [first, second]
        let a = DocumentWindowController(document: first)
        let b = DocumentWindowController(document: second)
        a.showWindow(nil)
        b.showWindow(nil)
        var errors: [String] = []
        first.onError = { errors.append($0) }
        second.onError = { errors.append($0) }
        let foreground = ToolState.shared.foreground
        let background = ToolState.shared.background
        ToolState.shared.foreground = .red
        ToolState.shared.background = .green
        defer {
            ToolState.shared.foreground = foreground
            ToolState.shared.background = background
            for (controller, document) in [(a, first), (b, second)] {
                if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
                controller.window?.close()
                document.onError = nil
                documents.items.removeAll { $0 === document }
                document.closeImageWhenDrained()
            }
        }
        func finish(_ controller: DocumentWindowController, _ response: NSApplication.ModalResponse) {
            if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet, returnCode: response) }
            spin(0.1)
        }
        func opacityField(_ sheet: NSWindow?) -> NSTextField? {
            // The embedded pattern picker's hidden search field is an
            // editable text field too; identify the opacity field by its
            // accessibility label, not by position.
            views(sheet?.contentView, as: NSTextField.self)
                .first { $0.isEditable && $0.accessibilityLabel() == "Fill opacity, percent" }
        }

        let undoBefore = first.undoInfo.undoCount
        a.fill(nil)
        let firstSheet = a.window?.attachedSheet
        b.fill(nil)
        let secondSheet = b.window?.attachedSheet
        check(firstSheet != nil && secondSheet != nil, "two documents can open independent Fill sheets")
        finish(a, .alertSecondButtonReturn)
        let slider = views(secondSheet?.contentView, as: NSSlider.self).first
        slider?.doubleValue = 25
        if let slider, let action = slider.action { NSApp.sendAction(action, to: slider.target, from: slider) }
        check(opacityField(secondSheet)?.stringValue == "25",
              "closing one Fill sheet preserves the other sheet's slider binding")
        finish(b, .alertSecondButtonReturn)
        check(first.undoInfo.undoCount == undoBefore && first.pendingWork == 0 && second.pendingWork == 0,
              "cancelling Fill changes neither document nor its undo history")

        try session.select(.rectangle(CGRect(x: 4, y: 4, width: 8, height: 8)), image: first.image, options: .init())
        try first.reload()
        let beforeFill = first.undoInfo.undoCount
        a.fill(nil)
        let sheet = a.window?.attachedSheet
        opacityField(sheet)?.stringValue = "50"
        finish(a, .alertFirstButtonReturn)
        wait { first.pendingWork == 0 }
        let inside = pixel(session, first.image, x: 6, y: 6) ?? []
        let outside = pixel(session, first.image, x: 1, y: 1) ?? []
        check(inside.count == 4 && inside[0] > 240 && (175...200).contains(Int(inside[1]))
                && outside.count == 4 && outside.prefix(3).allSatisfy { $0 == 255 },
              "Fill uses the foreground at 50 percent only inside the selection (\(inside), \(outside))")
        check(first.undoInfo.undoCount == beforeFill + 1, "Fill is one undo step")
        first.undo()
        wait { first.pendingWork == 0 }
        check(pixel(session, first.image, x: 6, y: 6)?.prefix(3).allSatisfy { $0 == 255 } == true,
              "undo restores the area before Fill")

        b.fill(nil)
        let customSheet = b.window?.attachedSheet
        let choice = views(customSheet?.contentView, as: NSPopUpButton.self).first
        choice?.selectItem(at: 4)
        if let choice, let action = choice.action { NSApp.sendAction(action, to: choice.target, from: choice) }
        let well = views(customSheet?.contentView, as: NSColorWell.self).first
        check(well?.isEnabled == true, "choosing Custom enables the Fill color well")
        well?.color = .blue
        finish(b, .alertFirstButtonReturn)
        wait { second.pendingWork == 0 }
        let custom = pixel(session, second.image, x: 8, y: 8) ?? []
        check(custom.count == 4 && custom[0] < 20 && custom[2] > 240,
              "Custom Fill uses its chosen color across the whole layer without a selection (\(custom))")

        b.fill(nil)
        let backgroundSheet = b.window?.attachedSheet
        views(backgroundSheet?.contentView, as: NSPopUpButton.self).first?.selectItem(at: 1)
        finish(b, .alertFirstButtonReturn)
        wait { second.pendingWork == 0 }
        let green = pixel(session, second.image, x: 8, y: 8) ?? []
        check(green.count == 4 && green[0] < 20 && green[1] > 240 && green[2] < 20,
              "Background Fill uses the background color independently of the foreground")

        a.fill(nil)
        let invalidSheet = a.window?.attachedSheet
        opacityField(invalidSheet)?.stringValue = "50percent-junk"
        let invalidErrorsBefore = errors.count, invalidUndoBefore = first.undoInfo.undoCount
        finish(a, .alertFirstButtonReturn)
        check(errors.count > invalidErrorsBefore && first.pendingWork == 0
                && first.undoInfo.undoCount == invalidUndoBefore,
              "Fill refuses a malformed opacity without editing or adding undo")

        a.fill(nil)
        let errorsBefore = errors.count
        let gate = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Other work", work: { gate.wait() }, completion: {})
        finish(a, .alertFirstButtonReturn)
        check(held && errors.count > errorsBefore && first.pendingWork == 0,
              "Fill reports a busy engine acquired after its sheet opened")
        gate.signal()
        wait { !EngineActivity.shared.isBusy }

        a.fill(nil)
        let nativeErrorsBefore = errors.count
        if let layer = first.activeLayer {
            try session.setLayerLocks(layer, image: first.image, mask: .pixels, values: .pixels)
            finish(a, .alertFirstButtonReturn)
            wait { first.pendingWork == 0 }
            spin()
            check(errors.count > nativeErrorsBefore
                    && pixel(session, first.image, x: 6, y: 6)?.prefix(3).allSatisfy { $0 == 255 } == true,
                  "Fill reports a native locked-target refusal and preserves its pixels")
            try session.setLayerLocks(layer, image: first.image, mask: .pixels, values: [])
        } else {
            check(false, "the Fill refusal fixture has an active layer")
        }
    }

    /// Image ▸ Mode and Image ▸ Precision…: the cached color state
    /// behind the title, the checkmarks and the form's seeding; the
    /// conversions through counted exclusive admission; and the rules
    /// they share with file work — accepted input drains first, busy
    /// refuses, close waits, and event refreshes defer instead of
    /// stalling the main thread on the running conversion.
    private static func exerciseColorConversions(_ session: EngineSession, work: URL,
                                                 documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func ok(_ result: Result<Void, Error>?) -> Bool {
            if case .success? = result { return true }
            return false
        }
        func failed(_ result: Result<Void, Error>?) -> Bool {
            if case .failure? = result { return true }
            return false
        }
        let directory = work.appendingPathComponent("color")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A red image gives the mode conversion pixels to judge.
        let image = try session.newImage(width: 32, height: 24)
        try session.select(.all, image: image)
        try session.fill(image: image, at: .zero, mode: .selection, color: .red)
        let document = try ImageDocument(session: session, image: image, name: "Color")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        defer {
            documents.items.removeAll { $0 === document }
            document.closeImageWhenDrained()
            controller.window?.close()
        }

        check(document.colorInfo.mode == .rgb && document.colorInfo.component == .u8
                && document.colorInfo.trc == .nonlinear
                && !document.colorInfo.hasEmbeddedProfile
                && !document.colorInfo.profileLabel.isEmpty,
              "a fresh document caches RGB u8 non-linear state and the builtin profile")
        check(controller.window?.title == "• Color @ 100% (RGB, \(document.info.precision))",
              "the title reports the cached mode and precision")

        // The Mode items check the cached mode — RGB here — and
        // validate without asking the engine.
        let modeRGB = NSMenuItem(title: "RGB", action: #selector(DocumentWindowController.convertImageMode(_:)),
                                 keyEquivalent: "")
        modeRGB.tag = Int(EngineSession.ColorMode.rgb.rawValue)
        let modeGray = NSMenuItem(title: "Grayscale", action: #selector(DocumentWindowController.convertImageMode(_:)),
                                  keyEquivalent: "")
        modeGray.tag = Int(EngineSession.ColorMode.grayscale.rawValue)
        check(controller.validateMenuItem(modeRGB) && controller.validateMenuItem(modeGray)
                && modeRGB.state == .on && modeGray.state == .off,
              "the Mode items check the cached RGB state")

        // RGB to grayscale through the counted exclusive admission:
        // one undo step, the title and the checkmarks follow the cache.
        var undoBefore = document.undoInfo.undoCount
        var modeResult: Result<Void, Error>?
        document.convertMode(to: .grayscale) { modeResult = $0 }
        wait { modeResult != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(ok(modeResult), "the mode conversion succeeds (\(modeResult as Any))")
        check(document.colorInfo.mode == .grayscale && document.components?.mode == .grayscale,
              "the reload reports the image grayscale")
        check(document.undoInfo.undoCount == undoBefore + 1, "the conversion is one undo step")
        check(document.hasUnsavedChanges, "the converted image is dirty")
        check(controller.window?.title == "• Color @ 100% (Grayscale, \(document.info.precision))",
              "the title follows the conversion")
        _ = controller.validateMenuItem(modeRGB)
        _ = controller.validateMenuItem(modeGray)
        check(modeRGB.state == .off && modeGray.state == .on,
              "the checkmarks follow the cached mode")
        if let converted = pixel(session, image, x: 8, y: 8) {
            check(converted[0] == converted[1] && converted[1] == converted[2],
                  "the red pixel renders as one channel of gray")
        }

        // Back through the menu action itself; the checkmarks move.
        undoBefore = document.undoInfo.undoCount
        controller.convertImageMode(modeRGB)
        wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(document.colorInfo.mode == .rgb, "the menu action converts back to RGB")
        check(document.undoInfo.undoCount == undoBefore + 1, "the menu conversion is one undo step")
        _ = controller.validateMenuItem(modeRGB)
        _ = controller.validateMenuItem(modeGray)
        check(modeRGB.state == .on && modeGray.state == .off, "the checkmark is back on RGB")

        // The Precision form seeds the current values; Cancel queues
        // nothing, and OK on the seeded values is the no-op.
        controller.imagePrecision(nil)
        var sheet = controller.window?.attachedSheet
        check(sheet != nil, "the precision form opens as a sheet")
        var popups: [NSPopUpButton] = []
        if let contentView = sheet?.contentView {
            func findPopups(_ view: NSView) {
                for sub in view.subviews {
                    if let popup = sub as? NSPopUpButton { popups.append(popup) }
                    findPopups(sub)
                }
            }
            findPopups(contentView)
        }
        check(popups.count == 2, "the form has component and curve popups")
        check(popups.first?.titleOfSelectedItem == EngineSession.ColorComponent.u8.title
                && popups.last?.titleOfSelectedItem == EngineSession.ColorTRC.nonlinear.title,
              "the form seeds the image's current precision")
        undoBefore = document.undoInfo.undoCount
        if let sheet {
            NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertSecondButtonReturn.rawValue)
        }
        spin()
        check(document.undoInfo.undoCount == undoBefore && document.pendingWork == 0,
              "Cancel queues nothing and changes nothing")

        controller.imagePrecision(nil)
        sheet = controller.window?.attachedSheet
        if let sheet {
            NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        }
        spin()
        check(document.undoInfo.undoCount == undoBefore && document.colorInfo.component == .u8,
              "OK on the seeded values is the no-op the facade promises")

        // The sheet can stay open while another document takes the
        // engine. Convert must report its refusal instead of vanishing.
        let originalError = document.onError
        var precisionError: String?
        document.onError = { message in precisionError = message; originalError?(message) }
        defer { document.onError = originalError }
        controller.imagePrecision(nil)
        sheet = controller.window?.attachedSheet
        let activityGate = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Other document work", work: {
            activityGate.wait()
        }, completion: {})
        if let sheet {
            controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        }
        wait { precisionError != nil }
        check(held && precisionError != nil && document.colorInfo.component == .u8,
              "Precision reports Convert refused while another document holds the engine")
        activityGate.signal()
        wait { !EngineActivity.shared.isBusy }

        // A native refusal must also reach the form's caller when it
        // was not already known by the frontend's cached edit gates.
        precisionError = nil
        do {
            let preview = try session.beginFilter(image: image, drawable: document.activeDrawable ?? 0,
                                                   operation: "gegl:gaussian-blur")
            defer { try? session.abortFilter(preview) }
            controller.imagePrecision(nil)
            sheet = controller.window?.attachedSheet
            if let sheet, let content = sheet.contentView,
               let component = descendant(of: content, as: NSPopUpButton.self) {
                component.selectItem(withTitle: EngineSession.ColorComponent.u16.title)
                controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
            }
            wait { precisionError != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            check(precisionError != nil && document.colorInfo.component == .u8,
                  "Precision reports an engine-side conversion refusal without changing the image")
        }
        document.onError = originalError

        // Picking 16-bit float linear in the form runs one conversion.
        controller.imagePrecision(nil)
        sheet = controller.window?.attachedSheet
        popups = []
        if let sheet, let contentView = sheet.contentView {
            func findPopups(_ view: NSView) {
                for sub in view.subviews {
                    if let popup = sub as? NSPopUpButton { popups.append(popup) }
                    findPopups(sub)
                }
            }
            findPopups(contentView)
            popups.first?.selectItem(withTitle: EngineSession.ColorComponent.half.title)
            popups.last?.selectItem(withTitle: EngineSession.ColorTRC.linear.title)
            NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
        }
        wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(document.colorInfo.component == .half && document.colorInfo.trc == .linear,
              "the form's choice converts to 16-bit float linear")
        check(document.undoInfo.undoCount == undoBefore + 1, "the precision conversion is one undo step")
        check(controller.window?.title == "• Color @ 100% (RGB, \(document.info.precision))",
              "the title shows the new precision")

        // Undo and redo carry the color state; the title follows both.
        document.undo()
        wait { document.pendingWork == 0 }
        spin()
        check(document.colorInfo.component == .u8 && document.colorInfo.trc == .nonlinear,
              "undo restores the earlier precision")
        check(controller.window?.title == "• Color @ 100% (RGB, \(document.info.precision))",
              "the title follows undo")
        document.redo()
        wait { document.pendingWork == 0 }
        spin()
        check(document.colorInfo.component == .half && document.colorInfo.trc == .linear,
              "redo restores the converted precision")

        // Saved state keeps the conversion; the conversion keeps the
        // file identity.
        let xcf = directory.appendingPathComponent("color.xcf")
        var saved = false
        document.save(to: xcf) { error in
            if error == nil { document.noteSaved(to: xcf) }
            saved = error == nil
        }
        wait { saved && document.pendingWork == 0 }
        check(saved && document.fileState.nativeURL == xcf, "the converted image saves")
        let nativeName = document.name
        var modeAgain: Result<Void, Error>?
        document.convertMode(to: .grayscale) { modeAgain = $0 }
        wait { modeAgain != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        check(ok(modeAgain) && document.fileState.nativeURL == xcf && document.name == nativeName,
              "the conversion keeps the file identity")
        let reopened = try session.openImage(path: xcf.path)
        let reopenedDocument = try ImageDocument(session: session, image: reopened, name: "Color")
        documents.items.append(reopenedDocument)
        defer {
            documents.items.removeAll { $0 === reopenedDocument }
            reopenedDocument.closeImageWhenDrained()
        }
        check(reopenedDocument.colorInfo.mode == .rgb
                && reopenedDocument.colorInfo.component == .half
                && reopenedDocument.colorInfo.trc == .linear,
              "the saved XCF keeps the converted precision")
        let reopenedController = DocumentWindowController(document: reopenedDocument)
        reopenedController.showWindow(nil)
        defer { reopenedController.window?.close() }
        check(reopenedController.window?.title == "Color @ 100% (RGB, \(reopenedDocument.info.precision))",
              "a reopened document titles from its own state")

        // Asking for the mode the image already has is a no-op: no
        // queued work, no undo step.
        undoBefore = reopenedDocument.undoInfo.undoCount
        var noopResult: Result<Void, Error>?
        reopenedDocument.convertMode(to: .rgb) { noopResult = $0 }
        spin()
        check(ok(noopResult) && reopenedDocument.undoInfo.undoCount == undoBefore
                && reopenedDocument.pendingWork == 0,
              "converting to the current mode changes nothing")

        // A filter preview owns the image; conversions refuse while it
        // is open rather than queue behind it.
        controller.gaussianBlur(nil)
        wait { controller.previewPanel != nil }
        var refused: Result<Void, Error>?
        document.convertMode(to: .rgb) { refused = $0 }
        check(failed(refused), "a conversion refuses while a preview is open (\(refused as Any))")
        check(document.colorInfo.mode == .grayscale,
              "the refused conversion changed nothing")
        controller.cancelOperation(nil)
        wait { !document.filterPreviewIsOpen }

        // Input another document accepted first drains ahead of the
        // conversion; edits there refuse behind the same gate.
        let otherImage = try session.newImage(width: 16, height: 16)
        let other = try ImageDocument(session: session, image: otherImage, name: "Other")
        documents.items.append(other)
        defer {
            documents.items.removeAll { $0 === other }
            other.closeImageWhenDrained()
        }
        other.inputQueue.async { usleep(200_000) }
        other.beginStroke(at: .init(x: 8, y: 8, pressure: 1))
        other.endStroke()
        var drained: Result<Void, Error>?
        document.convertMode(to: .rgb) { drained = $0 }
        other.beginStroke(at: .init(x: 4, y: 4, pressure: 1))
        check(!other.strokeIsActive, "the other document's edits refuse behind the conversion gate")
        if other.strokeIsActive { other.endStroke() }
        wait { drained != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        check(ok(drained) && document.colorInfo.mode == .rgb,
              "the conversion completes behind the other document's input")
        check((pixel(session, otherImage, x: 8, y: 8)?[0] ?? 255) < 128,
              "the accepted stroke in the other document survived the drain")

        // Use a raw facade conversion, without the document command's
        // completion reload. Only the deferred events can refresh the
        // cache; several event kinds must survive the same busy period.
        let refreshGate = DispatchSemaphore(value: 0)
        let rawConversionReady = DispatchSemaphore(value: 0)
        var rawConversion: Result<Void, Error>?
        let refreshActivity = EngineActivity.shared.perform(label: "Color event refresh", work: {
            rawConversion = Result { try session.convertMode(image, to: .grayscale) }
            rawConversionReady.signal()
            refreshGate.wait()
        }, completion: {})
        wait { rawConversionReady.wait(timeout: .now()) == .success }
        let version = document.stateVersion
        let oldSelectionChange = document.onSelectionChange
        let oldSizeChange = document.onSizeChange
        var selectionRefreshes = 0, sizeRefreshes = 0
        document.onSelectionChange = { selectionRefreshes += 1; oldSelectionChange?() }
        document.onSizeChange = { sizeRefreshes += 1; oldSizeChange?() }
        document.handle(.undoChanged(image: image))
        document.handle(.selectionChanged(image: image))
        document.handle(.sizeChanged(image: image))
        document.handle(.undoChanged(image: image))
        spin(0.1)
        check(refreshActivity && ok(rawConversion) && document.stateVersion == version
                && document.colorInfo.mode == .rgb && selectionRefreshes == 0 && sizeRefreshes == 0,
              "state, selection and size events defer every engine read while busy")
        refreshGate.signal()
        wait { !EngineActivity.shared.isBusy }
        spin()
        check(document.stateVersion == version + 1 && selectionRefreshes == 1 && sizeRefreshes == 1,
              "one deferred refresh preserves all event kinds without a command completion reload")
        check(document.colorInfo.mode == .grayscale, "the deferred refresh reads fresh state")
        document.onSelectionChange = oldSelectionChange
        document.onSizeChange = oldSizeChange

        // A close while the conversion is queued waits for it, then
        // destroys the image; the completion still lands.
        let closingImage = try session.newImage(width: 16, height: 16)
        let closing = try ImageDocument(session: session, image: closingImage, name: "Closing Color")
        documents.items.append(closing)
        let closingController = DocumentWindowController(document: closing)
        closingController.showWindow(nil)
        defer {
            documents.items.removeAll { $0 === closing }
            closing.closeImageWhenDrained()
            closingController.window?.close()
        }
        closing.inputQueue.async { usleep(400_000) }
        var closingOutcome: Result<Void, Error>?
        closing.convertMode(to: .grayscale) { closingOutcome = $0 }
        check(EngineActivity.shared.isBusy, "the closing document's conversion takes the gate")
        var closed: Bool?
        closingController.requestClose { closed = $0 }
        check(closed == nil && !closing.isClosing, "close waits while the conversion is queued")
        wait { closingOutcome != nil && closing.pendingWork == 0 && !EngineActivity.shared.isBusy }
        let sheetDeadline = Date().addingTimeInterval(5)
        while closingController.window?.attachedSheet == nil && Date() < sheetDeadline { spin(0.05) }
        if let attached = closingController.window?.attachedSheet {
            NSApp.endSheet(attached, returnCode: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue)
        }
        wait { closed != nil }
        check(closed == true && (try? session.info(closingImage)) == nil,
              "the deferred close destroys the image after its conversion lands")
        check(ok(closingOutcome), "the closing document's conversion still reports success")
    }

    /// Image ▸ Color Profile ▸ Assign…/Convert…: typed assignment and
    /// conversion through counted exclusive admission on the generated
    /// ICC fixtures, the shared form's seeding/Cancel/Apply/error paths,
    /// the indexed guard, undo, XCF persistence, file identity and
    /// per-sheet document capture. Needs an engine with ICC support.
    private static func exerciseColorProfiles(_ session: EngineSession, work: URL,
                                              documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func ok(_ result: Result<Void, Error>?) -> Bool {
            if case .success? = result { return true }
            return false
        }
        func failed(_ result: Result<Void, Error>?) -> Bool {
            if case .failure? = result { return true }
            return false
        }
        func views<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            return (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, as: type) }
        }
        // The conformance fixtures make-fixtures.sh generated with the engine.
        let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Engine/tests/fixtures")
        let rgbICC = fixtures.appendingPathComponent("linear-rgb.icc").path
        let grayICC = fixtures.appendingPathComponent("gray.icc").path
        let indexedPNG = fixtures.appendingPathComponent("indexed.png").path
        let missingICC = work.appendingPathComponent("missing-profile.icc").path
        check(FileManager.default.fileExists(atPath: rgbICC)
                && FileManager.default.fileExists(atPath: grayICC)
                && FileManager.default.fileExists(atPath: indexedPNG),
              "the generated ICC fixtures exist")

        let directory = work.appendingPathComponent("profiles")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // A midtone image gives assignment and conversion pixels to judge.
        let image = try session.newImage(width: 32, height: 24)
        try session.select(.all, image: image)
        try session.fill(image: image, at: .zero, mode: .selection,
                         color: NSColor(srgbRed: 0.5, green: 0.25, blue: 0.75, alpha: 1))
        let document = try ImageDocument(session: session, image: image, name: "Profiles")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        var errors: [String] = []
        document.onError = { errors.append($0) }
        defer {
            documents.items.removeAll { $0 === document }
            document.onError = nil
            document.closeImageWhenDrained()
            controller.window?.close()
        }

        check(!document.colorInfo.hasEmbeddedProfile && !document.colorInfo.profileLabel.isEmpty,
              "a fresh document caches the builtin profile, not an embedded one")
        let assignItem = NSMenuItem(title: "Assign…",
                                    action: #selector(DocumentWindowController.assignColorProfile(_:)),
                                    keyEquivalent: "")
        let convertItem = NSMenuItem(title: "Convert…",
                                     action: #selector(DocumentWindowController.convertColorProfile(_:)),
                                     keyEquivalent: "")
        check(controller.validateMenuItem(assignItem) && controller.validateMenuItem(convertItem),
              "Assign and Convert validate on an RGB document")

        // Typed assignment: one undo step, the fixture embeds, and the
        // unchanged component values are reinterpreted.
        let before = pixel(session, image, x: 8, y: 8) ?? []
        var undoBefore = document.undoInfo.undoCount
        var assignResult: Result<Void, Error>?
        document.assignProfile(path: rgbICC) { assignResult = $0 }
        wait { assignResult != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(ok(assignResult), "typed assignment embeds the ICC profile (\(assignResult as Any))")
        check(document.colorInfo.hasEmbeddedProfile
                && document.colorInfo.profileLabel == "Glims Linear RGB Fixture",
              "the reload reports the embedded fixture profile")
        check(document.undoInfo.undoCount == undoBefore + 1, "assignment is one undo step")
        let assigned = pixel(session, image, x: 8, y: 8) ?? []
        check(before.count == 4 && assigned.count == 4 && assigned[0] > before[0] + 30,
              "assignment reinterprets the unchanged component values (\(before) -> \(assigned))")

        document.undo()
        wait { document.pendingWork == 0 }
        spin()
        check(!document.colorInfo.hasEmbeddedProfile, "undo assignment restores the builtin profile")
        document.redo()
        wait { document.pendingWork == 0 }
        spin()
        check(document.colorInfo.hasEmbeddedProfile
                && document.colorInfo.profileLabel == "Glims Linear RGB Fixture",
              "redo assignment restores the embedded profile")

        // Typed conversion to the builtin: one undo step, appearance kept.
        undoBefore = document.undoInfo.undoCount
        let beforeConvert = pixel(session, image, x: 8, y: 8) ?? []
        var convertResult: Result<Void, Error>?
        document.convertProfile(path: nil, intent: .relativeColorimetric,
                                blackPointCompensation: true) { convertResult = $0 }
        wait { convertResult != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(ok(convertResult), "typed conversion to the builtin profile succeeds (\(convertResult as Any))")
        check(!document.colorInfo.hasEmbeddedProfile, "conversion lands on the builtin profile")
        check(document.undoInfo.undoCount == undoBefore + 1, "conversion is one undo step")
        let afterConvert = pixel(session, image, x: 8, y: 8) ?? []
        check(beforeConvert.count == 4 && afterConvert.count == 4
                && zip(beforeConvert, afterConvert).allSatisfy { abs(Int($0) - Int($1)) <= 2 },
              "conversion preserves appearance (\(beforeConvert) -> \(afterConvert))")
        document.undo()
        wait { document.pendingWork == 0 }
        spin()
        check(document.colorInfo.hasEmbeddedProfile, "undo conversion restores the embedded source profile")

        // XCF persistence and file identity.
        let xcf = directory.appendingPathComponent("profile.xcf")
        var saved = false
        document.save(to: xcf) { error in
            if error == nil { document.noteSaved(to: xcf) }
            saved = error == nil
        }
        wait { saved && document.pendingWork == 0 }
        check(saved && document.fileState.nativeURL == xcf, "the assigned document saves")
        let nativeName = document.name
        var noopResult: Result<Void, Error>?
        document.assignProfile(path: rgbICC) { noopResult = $0 }
        wait { noopResult != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        check(ok(noopResult) && document.fileState.nativeURL == xcf && document.name == nativeName
                && document.undoInfo.undoCount == undoBefore,
              "assigning the equal profile is a no-op that keeps the file identity")
        let reopenedImage = try session.openImage(path: xcf.path)
        let reopened = try ImageDocument(session: session, image: reopenedImage, name: "Profiles")
        documents.items.append(reopened)
        defer {
            documents.items.removeAll { $0 === reopened }
            reopened.closeImageWhenDrained()
        }
        check(reopened.colorInfo.hasEmbeddedProfile
                && reopened.colorInfo.profileLabel == "Glims Linear RGB Fixture",
              "the assigned profile survives XCF save and reopen")

        // The Assign form seeds the cached profile and offers the two
        // sources; Cancel queues nothing.
        controller.assignColorProfile(nil)
        var sheet = controller.window?.attachedSheet
        check(sheet != nil, "the Assign form opens as a sheet")
        let seededLabels = views(sheet?.contentView, as: NSTextField.self).map(\.stringValue)
        check(seededLabels.contains { $0.contains("Glims Linear RGB Fixture") },
              "the form seeds the cached profile label")
        let assignPopups = views(sheet?.contentView, as: NSPopUpButton.self)
        check(assignPopups.count == 1
                && assignPopups.first?.itemTitles == ["Built-in profile", "ICC file…"]
                && assignPopups.first?.indexOfSelectedItem == 0,
              "the Assign form offers builtin and ICC file, seeded on builtin")
        undoBefore = document.undoInfo.undoCount
        if let sheet { NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertSecondButtonReturn.rawValue) }
        spin()
        check(document.undoInfo.undoCount == undoBefore && document.pendingWork == 0,
              "Cancel queues nothing and changes nothing")

        // Apply with an incompatible ICC file: the native refusal is
        // reported, nothing mutates.
        controller.assignColorProfile(nil)
        sheet = controller.window?.attachedSheet
        if let content = sheet?.contentView {
            let popup = views(content, as: NSPopUpButton.self).first
            popup?.selectItem(at: 1)
            if let popup, let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
            let field = views(content, as: NSTextField.self).first { $0.isEditable }
            check(field?.isEnabled == true, "choosing ICC file enables the path field")
            field?.stringValue = grayICC
        }
        undoBefore = document.undoInfo.undoCount
        let errorsBefore = errors.count
        if let sheet { NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(errors.count > errorsBefore && document.undoInfo.undoCount == undoBefore
                && document.colorInfo.profileLabel == "Glims Linear RGB Fixture",
              "Apply reports a native refusal (gray profile on RGB) without mutating")

        // Apply discarding the embedded profile via the builtin source,
        // then assigning the fixture back through the form.
        controller.assignColorProfile(nil)
        sheet = controller.window?.attachedSheet
        undoBefore = document.undoInfo.undoCount
        if let sheet { NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(!document.colorInfo.hasEmbeddedProfile && document.undoInfo.undoCount == undoBefore + 1,
              "Apply on the builtin source discards the embedded profile as one undo step")
        controller.assignColorProfile(nil)
        sheet = controller.window?.attachedSheet
        if let content = sheet?.contentView {
            let popup = views(content, as: NSPopUpButton.self).first
            popup?.selectItem(at: 1)
            if let popup, let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
            views(content, as: NSTextField.self).first { $0.isEditable }?.stringValue = rgbICC
        }
        if let sheet { NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(document.colorInfo.hasEmbeddedProfile
                && document.colorInfo.profileLabel == "Glims Linear RGB Fixture"
                && document.undoInfo.undoCount == undoBefore + 2,
              "Apply with the ICC file assigns the chosen profile as one undo step")

        // The Convert form seeds the intent choices and BPC; Cancel
        // queues nothing.
        controller.convertColorProfile(nil)
        sheet = controller.window?.attachedSheet
        let convertPopups = views(sheet?.contentView, as: NSPopUpButton.self)
        check(convertPopups.count == 2, "the Convert form has source and intent popups")
        check(convertPopups.last?.itemTitles == EngineSession.ProfileIntent.conversionChoices.map(\.title)
                && convertPopups.last?.titleOfSelectedItem == "Perceptual",
              "the intent popup offers the four facade intents, seeded on Perceptual")
        let bpc = views(sheet?.contentView, as: NSButton.self).first { $0.title == "Black point compensation" }
        check(bpc?.state == .on, "black point compensation is offered and on")
        undoBefore = document.undoInfo.undoCount
        if let sheet { NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertSecondButtonReturn.rawValue) }
        spin()
        check(document.undoInfo.undoCount == undoBefore && document.pendingWork == 0,
              "Convert Cancel queues nothing")

        // Apply with a missing ICC file: the engine's error is reported,
        // nothing mutates.
        controller.convertColorProfile(nil)
        sheet = controller.window?.attachedSheet
        if let content = sheet?.contentView {
            let popup = views(content, as: NSPopUpButton.self).first
            popup?.selectItem(at: 1)
            if let popup, let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
            views(content, as: NSTextField.self).first { $0.isEditable }?.stringValue = missingICC
        }
        undoBefore = document.undoInfo.undoCount
        let missingErrorsBefore = errors.count
        if let sheet { NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(errors.count > missingErrorsBefore && document.undoInfo.undoCount == undoBefore
                && document.colorInfo.hasEmbeddedProfile,
              "Convert Apply reports a missing ICC file without mutating")

        // A relative path is refused by the form's own validation before
        // anything queues.
        controller.convertColorProfile(nil)
        sheet = controller.window?.attachedSheet
        if let content = sheet?.contentView {
            let popup = views(content, as: NSPopUpButton.self).first
            popup?.selectItem(at: 1)
            if let popup, let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
            views(content, as: NSTextField.self).first { $0.isEditable }?.stringValue = "relative.icc"
        }
        let relativeErrorsBefore = errors.count
        if let sheet { NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        spin()
        check(errors.count > relativeErrorsBefore && document.undoInfo.undoCount == undoBefore
                && document.pendingWork == 0,
              "a relative ICC path is refused by the form without queueing")

        // Apply a real conversion through the form: to the builtin with
        // the chosen intent and BPC, one undo step.
        controller.convertColorProfile(nil)
        sheet = controller.window?.attachedSheet
        if let content = sheet?.contentView {
            views(content, as: NSPopUpButton.self).last?.selectItem(withTitle: "Saturation")
        }
        if let sheet { NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue) }
        wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(!document.colorInfo.hasEmbeddedProfile && document.undoInfo.undoCount == undoBefore + 1,
              "Convert Apply to the builtin converts as one undo step")

        // The sheet can stay open while another document holds the
        // engine; Apply then reports busy instead of vanishing.
        controller.convertColorProfile(nil)
        sheet = controller.window?.attachedSheet
        let gate = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Other work", work: { gate.wait() }, completion: {})
        let busyErrorsBefore = errors.count
        if let sheet { controller.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        wait { errors.count > busyErrorsBefore }
        check(held && document.pendingWork == 0 && !document.colorInfo.hasEmbeddedProfile,
              "Convert Apply reports a busy engine acquired after its sheet opened")
        gate.signal()
        wait { !EngineActivity.shared.isBusy }

        // Indexed: Convert is disabled in the menu and refused by the
        // document guard; Assign stays allowed for a compatible RGB
        // profile.
        let indexedImage = try session.openImage(path: indexedPNG)
        let indexed = try ImageDocument(session: session, image: indexedImage, name: "Indexed")
        documents.items.append(indexed)
        let indexedController = DocumentWindowController(document: indexed)
        indexedController.showWindow(nil)
        defer {
            documents.items.removeAll { $0 === indexed }
            indexed.closeImageWhenDrained()
            indexedController.window?.close()
        }
        check(indexed.colorInfo.mode == .indexed, "the indexed fixture opens indexed")
        let indexedConvertItem = NSMenuItem(title: "Convert…",
                                            action: #selector(DocumentWindowController.convertColorProfile(_:)),
                                            keyEquivalent: "")
        let indexedAssignItem = NSMenuItem(title: "Assign…",
                                           action: #selector(DocumentWindowController.assignColorProfile(_:)),
                                           keyEquivalent: "")
        check(!indexedController.validateMenuItem(indexedConvertItem)
                && indexedController.validateMenuItem(indexedAssignItem),
              "Convert is disabled for an indexed image while Assign stays enabled")
        var indexedAssign: Result<Void, Error>?
        indexed.assignProfile(path: rgbICC) { indexedAssign = $0 }
        wait { indexedAssign != nil && indexed.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(ok(indexedAssign) && indexed.colorInfo.hasEmbeddedProfile
                && indexed.colorInfo.profileLabel == "Glims Linear RGB Fixture",
              "an indexed image accepts a compatible RGB profile assignment")
        let indexedUndo = indexed.undoInfo.undoCount
        var indexedConvert: Result<Void, Error>?
        indexed.convertProfile(path: nil, intent: .perceptual, blackPointCompensation: true) { indexedConvert = $0 }
        spin()
        check(failed(indexedConvert) && indexed.undoInfo.undoCount == indexedUndo && indexed.pendingWork == 0,
              "the document guard refuses indexed conversion without queueing (\(indexedConvert as Any))")
        check(indexed.colorInfo.profileLabel == "Glims Linear RGB Fixture",
              "the refused conversion leaves the assigned profile unchanged")

        // Two documents' sheets keep their own captured document:
        // cancelling one does not disturb the other's bindings.
        let secondImage = try session.newImage(width: 16, height: 16)
        let second = try ImageDocument(session: session, image: secondImage, name: "Profiles B")
        documents.items.append(second)
        let secondController = DocumentWindowController(document: second)
        secondController.showWindow(nil)
        defer {
            documents.items.removeAll { $0 === second }
            second.closeImageWhenDrained()
            secondController.window?.close()
        }
        controller.assignColorProfile(nil)
        let firstSheet = controller.window?.attachedSheet
        secondController.assignColorProfile(nil)
        let secondSheet = secondController.window?.attachedSheet
        check(firstSheet != nil && secondSheet != nil, "two documents can open independent profile sheets")
        if let firstSheet { controller.window?.endSheet(firstSheet, returnCode: .alertSecondButtonReturn) }
        spin()
        var secondField: NSTextField?
        if let content = secondSheet?.contentView {
            let popup = views(content, as: NSPopUpButton.self).first
            popup?.selectItem(at: 1)
            if let popup, let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
            secondField = views(content, as: NSTextField.self).first { $0.isEditable }
            check(secondField?.isEnabled == true, "closing one sheet preserves the other sheet's source binding")
            secondField?.stringValue = rgbICC
        }
        let secondUndo = second.undoInfo.undoCount
        if let secondSheet { secondController.window?.endSheet(secondSheet, returnCode: .alertFirstButtonReturn) }
        wait { second.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(second.colorInfo.hasEmbeddedProfile
                && second.colorInfo.profileLabel == "Glims Linear RGB Fixture"
                && second.undoInfo.undoCount == secondUndo + 1,
              "the surviving sheet applies to its own captured document")

        // The typed facade must reject NUL before withCString can select
        // the valid file prefix instead of the path the caller supplied.
        for convert in [false, true] {
            var refused = false
            do {
                if convert {
                    try session.convertProfile(secondImage, path: rgbICC + "\0.other.icc",
                                               intent: .perceptual, blackPointCompensation: true)
                } else {
                    try session.assignProfile(secondImage, path: rgbICC + "\0.other.icc")
                }
            } catch { refused = true }
            check(refused && (try? session.undoInfo(secondImage).undoCount) == second.undoInfo.undoCount,
                  "typed \(convert ? "conversion" : "assignment") refuses a NUL path without mutation")
        }

        // Native profile conversion rasterizes structured layers. The
        // ordinary document operation must refuse it without mutation;
        // only an accepted, separate confirmation may use the explicit
        // rasterizing entry point. Both stages capture this document.
        let textImage = try session.newImage(width: 96, height: 64)
        var textSettings = EngineSession.TextSettings()
        textSettings.size = 24
        let textID = try session.addTextLayer(image: textImage, text: "Editable",
                                             settings: textSettings, at: CGPoint(x: 3, y: 3))
        try session.assignProfile(textImage, path: rgbICC)
        let textDocument = try ImageDocument(session: session, image: textImage, name: "Profile consent")
        documents.items.append(textDocument)
        let textController = DocumentWindowController(document: textDocument)
        textController.showWindow(nil)
        let textWindow = try XCTUnwrapWindow(textController)
        var consentErrors: [String] = []
        textDocument.onError = { consentErrors.append($0) }
        defer {
            if let sheet = textWindow.attachedSheet { textWindow.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
            documents.items.removeAll { $0 === textDocument }
            textDocument.closeImageWhenDrained()
            textWindow.close()
        }
        func editableText() -> Bool {
            textDocument.layers.contains { $0.id == textID && $0.kind == .text }
                && (try? session.textLayer(image: textImage, layer: textID).text) == "Editable"
        }
        func openRasterizeConfirmation() -> NSWindow? {
            textController.convertColorProfile(nil)
            guard let form = textWindow.attachedSheet else { return nil }
            textWindow.endSheet(form, returnCode: .alertFirstButtonReturn)
            wait {
                textWindow.attachedSheet.map {
                    views($0.contentView, as: NSTextField.self).contains { $0.stringValue == "Rasterize editable layers?" }
                } == true && textDocument.pendingWork == 0 && !EngineActivity.shared.isBusy
            }
            return textWindow.attachedSheet
        }
        let textUndo = textDocument.undoInfo.undoCount
        var confirmation = openRasterizeConfirmation()
        check(confirmation != nil && editableText() && textDocument.undoInfo.undoCount == textUndo
                && textDocument.colorInfo.hasEmbeddedProfile,
              "conversion asks before rasterizing editable text and changes nothing")
        if let confirmation { textWindow.endSheet(confirmation, returnCode: .alertSecondButtonReturn) }
        spin()
        check(editableText() && textDocument.undoInfo.undoCount == textUndo
                && textDocument.pendingWork == 0 && !EngineActivity.shared.isBusy,
              "cancelling profile rasterization preserves text, profile and history")

        confirmation = openRasterizeConfirmation()
        if let confirmation { textWindow.endSheet(confirmation, returnCode: .alertFirstButtonReturn) }
        wait { textDocument.pendingWork == 0 && !EngineActivity.shared.isBusy && textWindow.attachedSheet == nil }
        spin()
        check(textDocument.layers.contains { $0.id == textID && $0.kind == .pixel }
                && !textDocument.colorInfo.hasEmbeddedProfile && textDocument.undoInfo.undoCount == textUndo + 1,
              "Rasterize and Convert applies the captured destination as one undo step")
        textDocument.undo()
        wait { textDocument.pendingWork == 0 }
        spin()
        check(editableText() && textDocument.colorInfo.hasEmbeddedProfile
                && textDocument.undoInfo.undoCount == textUndo,
              "undo profile conversion restores the original editable text and profile")

        confirmation = openRasterizeConfirmation()
        let consentGate = DispatchSemaphore(value: 0)
        let heldForConsent = EngineActivity.shared.perform(label: "Other profile work", work: { consentGate.wait() }, completion: {})
        let consentErrorsBefore = consentErrors.count
        if let confirmation { textWindow.endSheet(confirmation, returnCode: .alertFirstButtonReturn) }
        wait { consentErrors.count > consentErrorsBefore }
        check(heldForConsent && editableText() && textDocument.undoInfo.undoCount == textUndo
                && textDocument.pendingWork == 0,
              "rasterization approval rechecks the engine gate before changing text")
        consentGate.signal()
        wait { !EngineActivity.shared.isBusy }

        textDocument.inputQueue.async { usleep(400_000) }
        textController.convertColorProfile(nil)
        if let form = textWindow.attachedSheet { textWindow.endSheet(form, returnCode: .alertFirstButtonReturn) }
        wait { textDocument.pendingWork > 0 }
        check(textDocument.pendingWork > 0, "profile conversion is counted while accepted input drains")
        var textClosed = false
        textDocument.closeImageWhenDrained { textClosed = true }
        wait { textClosed && textDocument.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(textClosed && (try? session.info(textImage)) == nil && textWindow.attachedSheet == nil,
              "closing a queued conversion suppresses a late rasterization confirmation and destroys the image")
    }

    /// File ▸ Print… and Page Setup…: a committed composite rendered in
    /// bounded stripes behind accepted input, the operation's lifecycle,
    /// and the same close safety file work gets. The panel is replaced
    /// by AppKit's own PDF write — the same view, print info and page
    /// layout — so no sheet or printer is involved.
    private static func exercisePrinting(_ session: EngineSession, work: URL,
                                         documents: DocumentList) throws {
        let image = try session.newImage(width: 120, height: 80)
        let document = try ImageDocument(session: session, image: image, name: "Print")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        let window = try XCTUnwrapWindow(controller)
        defer {
            controller.window?.close()
            documents.items.removeAll { $0 === document }
            document.closeImageWhenDrained()
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }

        // US Letter paper; the imageable rect is the printer's, margins
        // included, well inside the sheet.
        document.printInfo.paperSize = CGSize(width: 612, height: 792)
        let imageable = document.printInfo.imageablePageBounds
        check(imageable.minX > 0 && imageable.minY > 0 && imageable.width > 400
                && imageable.maxX <= 612 && imageable.maxY <= 792,
              "the document's print info reports the imageable area")

        // Menu wiring: unique selectors; a generic printDocument: would
        // route nowhere here (the showHelp: interception lesson).
        let fileMenu = MainMenu.make().items.first { $0.title == "File" }?.submenu
        let printItem = fileMenu?.items.first { $0.title == "Print…" }
        let setupItem = fileMenu?.items.first { $0.title == "Page Setup…" }
        check(printItem?.action == #selector(DocumentWindowController.printGlimsImage(_:))
                && printItem?.keyEquivalent == "p"
                && setupItem?.action == #selector(DocumentWindowController.runGlimsPageSetup(_:)),
              "File offers Page Setup… and Print… on the document's own selectors")

        // Page Setup changes the per-document print info alone.
        let undoBeforeSetup = document.undoInfo
        let fileStateBefore = document.fileState
        controller.pageSetupRunner = { info, _, finish in
            let changed = (info.copy() as? NSPrintInfo) ?? info
            changed.orientation = .landscape
            finish(changed)
        }
        controller.runGlimsPageSetup(nil)
        wait { document.printInfo.orientation == .landscape }
        check(document.printInfo.orientation == .landscape,
              "Page Setup stores the sheet's print info on this document")
        check(document.undoInfo == undoBeforeSetup && document.fileState == fileStateBefore,
              "Page Setup adds no undo step and keeps file identity")
        document.printInfo.orientation = .portrait

        // Cancel preserves the document's settings even if the sheet
        // edited the object it was given before the user backed out.
        controller.pageSetupRunner = { info, _, finish in
            info.orientation = .landscape
            finish(nil)
        }
        controller.runGlimsPageSetup(nil)
        check(document.printInfo.orientation == .portrait,
              "a cancelled Page Setup cannot rewrite the document's print info")

        // The print sheet is replaced by AppKit's own PDF write — the
        // same view, print info and pagination, no panel and no printer.
        let pdfURL = work.appendingPathComponent("printed.pdf")
        var runnerCalls = 0
        var runnerFinished = false
        controller.printJobRunner = { view, info, _, finish in
            runnerCalls += 1
            let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds,
                                                          toPath: pdfURL.path, printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            finish(operation.run())
            runnerFinished = true
        }

        // Edits accepted but still queued must land in the printed
        // page: a stroke queues behind a slow input job and Print is
        // chosen before the stroke reaches the engine.
        document.inputQueue.async { usleep(300_000) }
        document.beginStroke(at: .init(x: 20, y: 20, pressure: 1),
                             brush: EngineSession.Brush(size: 12, opacity: 1, red: 0, green: 0,
                                                        blue: 0, pressureSize: false))
        document.endStroke()
        let printStart = DispatchTime.now()
        check(printItem?.action.map({ window.tryToPerform($0, with: printItem) }) == true
                && controller.printJobIsOpen,
              "Print… routes through the window's responder chain to the document")
        check(milliseconds(since: printStart) < 100,
              "Print returns at once; the snapshot renders off the main thread")
        check(document.pendingWork > 0, "the snapshot render counts like a file write")
        check(!(printItem.flatMap { controller.validateMenuItem($0) } ?? true),
              "a second Print is refused while a job is open")
        controller.printGlimsImage(nil)
        wait { runnerFinished }
        check(runnerCalls == 1, "the duplicate Print started no other job")
        check(!controller.printJobIsOpen, "a finished run releases the operation and its snapshot")
        check(printItem.map { controller.validateMenuItem($0) } == true,
              "Print is offered again once the job released")

        // The written PDF: one page the size of the printed view; the
        // image is centered in it over white paper, stroke included.
        guard let pdf = CGPDFDocument(pdfURL as CFURL), let page = pdf.page(at: 1) else {
            check(false, "the print PDF is written")
            return
        }
        check(pdf.numberOfPages == 1, "the image fits on exactly one page")
        let box = page.getBoxRect(.mediaBox)
        check(abs(box.width - imageable.width) < 1 && abs(box.height - imageable.height) < 1,
              "the printed page is the imageable area")
        let rasterScale = 0.25
        let rw = Int(box.width * rasterScale), rh = Int(box.height * rasterScale)
        let raster = CGContext(data: nil, width: rw, height: rh, bitsPerComponent: 8,
                               bytesPerRow: rw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue)
        raster?.scaleBy(x: rasterScale, y: rasterScale)
        raster?.drawPDFPage(page)
        guard let pagePixels = raster?.makeImage() else {
            check(false, "the printed page rasterizes")
            return
        }
        // CGImage row 0 is the page's top; media point (x, y) reads
        // raster (x*s, rh - 1 - y*s) in the y-up page.
        func rasterSample(mediaX: Double, mediaY: Double) -> [UInt8]? {
            argb(pagePixels, x: Int(mediaX * rasterScale),
                 y: rh - 1 - Int(mediaY * rasterScale))
        }
        // The image is centered: 120×80 px fitted to the page gives
        // fit = width/120; its bottom edge sits at (pageH - h)/2.
        let fit = box.width / 120, imageH = 80 * fit
        let imageBottom = (box.height - imageH) / 2
        // The queued stroke at image (20,20) lands inside the image,
        // measured from the image's top edge down.
        let stroke = rasterSample(mediaX: 20 * fit, mediaY: imageBottom + imageH - 20 * fit)
        check((stroke?.first ?? 255) < 150, "the queued stroke reached the printed page")
        check((rasterSample(mediaX: box.width / 2, mediaY: imageBottom / 2)?.first ?? 0) > 240,
              "outside the image prints white, not canvas checks")
        check((rasterSample(mediaX: 100 * fit, mediaY: imageBottom + 62 * fit)?.first ?? 0) > 200,
              "the image's own background prints white")

        // The snapshot is the same composite the canvas draws.
        var snapshotDone = false
        var snapshot: PrintSnapshot?
        document.preparePrintSnapshot(imageablePoints: CGSize(width: 57.6, height: 38.4)) { result in
            snapshot = try? result.get()
            snapshotDone = true
        }
        wait { snapshotDone }
        if let snapshot {
            let snapPixel = argb(snapshot.image, x: 40, y: 40)
            let live = (try? session.render(image, scale: snapshot.scale,
                                            area: CGRect(x: 40, y: 40, width: 1, height: 1)))
                .flatMap { argb($0, x: 0, y: 0) }
            check(snapPixel != nil && snapPixel == live,
                  "snapshot pixels equal the committed composite")
            check((snapPixel?.first ?? 255) < 150, "the queued stroke is in the snapshot")
        } else { check(false, "the snapshot renders") }

        // Alpha: the transparent half of an imported image stays
        // transparent in the snapshot, so paper shows through.
        var transparentPixels: [UInt8] = []
        for _ in 0..<4 {
            transparentPixels += [255, 0, 0, 255, 255, 0, 0, 255, 0, 0, 0, 0, 0, 0, 0, 0]
        }
        let transparentImage = try session.newImage(pixels: ClipboardImage(
            width: 4, height: 4, pixels: Data(transparentPixels), origin: .zero))
        let transparent = try ImageDocument(session: session, image: transparentImage, name: "Transparent")
        documents.items.append(transparent)
        var alphaDone = false
        var alphaSnapshot: PrintSnapshot?
        transparent.preparePrintSnapshot(imageablePoints: CGSize(width: 9.6, height: 9.6)) { result in
            alphaSnapshot = try? result.get()
            alphaDone = true
        }
        wait { alphaDone }
        if let alphaSnapshot {
            check(argb(alphaSnapshot.image, x: 5, y: 20)?[3] == 255
                    && argb(alphaSnapshot.image, x: 35, y: 20)?[3] == 0,
                  "the snapshot keeps composite alpha for white paper")
        } else { check(false, "the transparent snapshot renders") }
        transparent.closeImageWhenDrained()
        documents.items.removeAll { $0 === transparent }

        // Identity: a second run changes neither history nor file
        // state; the stroke's own step was the only new one.
        document.inputQueue.sync {}
        spin()
        let undoAfterEdits = document.undoInfo
        let fileStateAfterEdits = document.fileState
        runnerFinished = false
        controller.printGlimsImage(nil)
        wait { runnerFinished }
        check(runnerCalls == 2 && document.undoInfo == undoAfterEdits
                && document.fileState == fileStateAfterEdits,
              "printing adds no undo step and keeps identity and dirty state")

        // A busy engine refuses the job instead of queueing a phantom.
        var exportDone = false
        document.export(to: work.appendingPathComponent("while-printing.png")) { _ in exportDone = true }
        controller.printGlimsImage(nil)
        wait { !controller.printJobIsOpen }
        check(runnerCalls == 2 && !controller.statusBar.message.isEmpty,
              "Print while the engine is busy is refused with a reason")
        wait { exportDone }

        // Cancelling releases the job like a finished run.
        controller.printJobRunner = { _, _, _, finish in
            runnerCalls += 1
            finish(false)
        }
        controller.printGlimsImage(nil)
        wait { runnerCalls == 3 }
        check(!controller.printJobIsOpen, "a cancelled run releases the job")
        check(controller.statusBar.message != "Preparing to print…",
              "a cancelled run restores the document status")

        // A close while the snapshot still renders drops the job; the
        // deferred close proceeds and the image is destroyed on time.
        let closingImage = try session.newImage(width: 32, height: 32)
        let closing = try ImageDocument(session: session, image: closingImage, name: "Close While Printing")
        documents.items.append(closing)
        let closingController = DocumentWindowController(document: closing)
        closingController.showWindow(nil)
        closingController.printJobRunner = { _, _, _, _ in
            check(false, "no panel opens over a closing window")
        }
        closing.inputQueue.async { usleep(300_000) }
        closingController.printGlimsImage(nil)
        check(closingController.printJobIsOpen, "the print job is still in flight")
        var closed: Bool?
        closingController.requestClose { closed = $0 }
        wait { closed != nil || closingController.window?.attachedSheet != nil }
        if let sheet = closingController.window?.attachedSheet {
            NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue)
        }
        wait { closed != nil }
        check(closed == true && !closingController.printJobIsOpen,
              "close during the render drops the job and finishes")
        wait { (try? session.info(closingImage)) == nil }
        check((try? session.info(closingImage)) == nil, "the image is destroyed after its queued work")
        documents.items.removeAll { $0 === closing }

        // A plain ⌘W during the render must behave like a requested
        // close: the job drops before any sheet attaches, and the dirty
        // prompt still asks. Don't Save then closes on time.
        let plainImage = try session.newImage(width: 32, height: 32)
        let plain = try ImageDocument(session: session, image: plainImage, name: "Plain Close")
        documents.items.append(plain)
        let plainController = DocumentWindowController(document: plain)
        plainController.showWindow(nil)
        let plainWindow = try XCTUnwrapWindow(plainController)
        var plainRunnerCalls = 0
        plainController.printJobRunner = { _, _, _, _ in plainRunnerCalls += 1 }
        plain.beginStroke(at: .init(x: 8, y: 8, pressure: 1))
        plain.endStroke()
        wait { plain.fileState.hasUnsavedChanges }
        var plainClosed = false
        plainController.onClose = { _ in plainClosed = true }
        plain.inputQueue.async { usleep(300_000) }
        plainController.printGlimsImage(nil)
        check(plainController.printJobIsOpen, "the close-during-render print job is in flight")
        plainWindow.performClose(nil)
        wait { plainWindow.attachedSheet != nil || plainClosed }
        check(plainRunnerCalls == 0 && !plainClosed,
              "a plain close during the render drops the job before the save prompt")
        if let sheet = plainWindow.attachedSheet {
            NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue)
        }
        wait { plainClosed }
        check(plainClosed && !plainController.printJobIsOpen,
              "Don't Save finishes the close the dropped job deferred")
        wait { (try? session.info(plainImage)) == nil }
        check((try? session.info(plainImage)) == nil,
              "the image is destroyed after the dropped job drains")
        documents.items.removeAll { $0 === plain }

        // Tiny images print too: the engine refuses render scales above
        // 32, so the snapshot asks for fewer pixels instead of failing.
        var redPixels: [UInt8] = []
        for _ in 0..<64 { redPixels += [255, 0, 0, 255] }
        let tinyImage = try session.newImage(pixels: ClipboardImage(
            width: 8, height: 8, pixels: Data(redPixels), origin: .zero))
        let tiny = try ImageDocument(session: session, image: tinyImage, name: "Tiny")
        documents.items.append(tiny)
        let tinyController = DocumentWindowController(document: tiny)
        tinyController.showWindow(nil)
        let tinyPDF = work.appendingPathComponent("tiny.pdf")
        var tinyRunnerFinished = false
        var tinyView: ImagePrintView?
        tinyController.printJobRunner = { view, info, _, finish in
            tinyView = view
            let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds,
                                                          toPath: tinyPDF.path, printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            finish(operation.run())
            tinyRunnerFinished = true
        }
        tinyController.printGlimsImage(nil)
        wait { tinyRunnerFinished }
        check(tinyView?.snapshot.pixelSize == CGSize(width: 256, height: 256),
              "an 8-pixel image prints at the engine's render limit")
        if let pdf = CGPDFDocument(tinyPDF as CFURL), let page = pdf.page(at: 1),
           let rect = tinyView?.imageRect, !rect.isEmpty {
            let box = page.getBoxRect(.mediaBox)
            let rScale = 0.25
            let rw = Int(box.width * rScale), rh = Int(box.height * rScale)
            let raster = CGContext(data: nil, width: rw, height: rh, bitsPerComponent: 8,
                                   bytesPerRow: rw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue)
            raster?.scaleBy(x: rScale, y: rScale)
            raster?.drawPDFPage(page)
            let printed = raster?.makeImage()
            let center = printed.flatMap { argb($0, x: Int(rect.midX * rScale), y: rh - 1 - Int(rect.midY * rScale)) }
            check((center?.first ?? 0) > 200 && (center?[1] ?? 255) < 60,
                  "the tiny image's pixels reach the fitted page")
        } else { check(false, "the tiny image's PDF is written") }
        tiny.closeImageWhenDrained()
        documents.items.removeAll { $0 === tiny }

        // A rotate accepted but still queued decides the printed
        // geometry: the snapshot sizes itself from the dimensions the
        // engine reports after the drain, not those at Print time.
        // Split red/blue so a wrong region shows in the pixels.
        var splitPixels: [UInt8] = []
        for _ in 0..<80 {
            for x in 0..<120 {
                splitPixels += x < 60 ? [255, 0, 0, 255] : [0, 0, 255, 255]
            }
        }
        let splitImage = try session.newImage(pixels: ClipboardImage(
            width: 120, height: 80, pixels: Data(splitPixels), origin: .zero))
        let split = try ImageDocument(session: session, image: splitImage, name: "Split")
        documents.items.append(split)
        let splitController = DocumentWindowController(document: split)
        splitController.showWindow(nil)
        let splitPDF = work.appendingPathComponent("split.pdf")
        var splitRunnerFinished = false
        var splitView: ImagePrintView?
        splitController.printJobRunner = { view, info, _, finish in
            splitView = view
            let operation = NSPrintOperation.pdfOperation(with: view, inside: view.bounds,
                                                          toPath: splitPDF.path, printInfo: info)
            operation.showsPrintPanel = false
            operation.showsProgressPanel = false
            finish(operation.run())
            splitRunnerFinished = true
        }
        split.inputQueue.async { usleep(300_000) }
        split.transformImage(.rotate90)
        splitController.printGlimsImage(nil)
        wait { splitRunnerFinished }
        let splitSize = splitView?.snapshot.pixelSize
        check(splitSize.map { $0.height > $0.width && abs($0.height - $0.width * 1.5) < 4 } ?? false,
              "a queued rotation sizes the snapshot to the rotated image")
        if let pdf = CGPDFDocument(splitPDF as CFURL), let page = pdf.page(at: 1),
           let rect = splitView?.imageRect, !rect.isEmpty {
            let box = page.getBoxRect(.mediaBox)
            let rScale = 0.25
            let rw = Int(box.width * rScale), rh = Int(box.height * rScale)
            let raster = CGContext(data: nil, width: rw, height: rh, bitsPerComponent: 8,
                                   bytesPerRow: rw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).rawValue)
            raster?.scaleBy(x: rScale, y: rScale)
            raster?.drawPDFPage(page)
            if let printed = raster?.makeImage() {
                func splitSample(mediaX: Double, mediaY: Double) -> [UInt8]? {
                    argb(printed, x: Int(mediaX * rScale), y: rh - 1 - Int(mediaY * rScale))
                }
                let top = splitSample(mediaX: rect.midX, mediaY: rect.maxY - rect.height * 0.25)
                let bottom = splitSample(mediaX: rect.midX, mediaY: rect.minY + rect.height * 0.25)
                check((top?.first ?? 0) > 200 && (top?[2] ?? 255) < 60,
                      "the rotated image's red half prints on top")
                check((bottom?[2] ?? 0) > 200 && (bottom?.first ?? 255) < 60,
                      "the rotated image's blue half prints on the bottom")
                check((splitSample(mediaX: 6, mediaY: rect.midY)?.first ?? 0) > 240,
                      "paper shows outside the rotated image")
            } else { check(false, "the rotated print rasterizes") }
        } else { check(false, "the rotated print PDF is written with a fitted image") }
        split.closeImageWhenDrained()
        documents.items.removeAll { $0 === split }
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

        let previousTool = ToolState.shared.current
        ToolState.shared.select(.rectangleSelect)
        func pointer(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type,
                location: controller.canvas.convert(CGPoint(x: point.x * controller.canvas.scale,
                                                             y: point.y * controller.canvas.scale), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        if let down = pointer(.leftMouseDown, CGPoint(x: 8, y: 8)),
           let dragged = pointer(.leftMouseDragged, CGPoint(x: 40, y: 40)),
           let up = pointer(.leftMouseUp, CGPoint(x: 40, y: 40)) {
            controller.canvas.mouseDown(with: down)
            controller.canvas.mouseDragged(with: dragged)
            check(!controller.isReadyForRecoveryCopy,
                  "recovery waits for an accepted selection gesture to finish")
            controller.canvas.mouseUp(with: up)
            document.inputQueue.sync {}
            spin()
            check(controller.isReadyForRecoveryCopy,
                  "a finished selection gesture permits recovery again")
            document.select(.none)
            document.inputQueue.sync {}
            spin()
            ToolState.shared.select(.crop)
            controller.canvas.mouseDown(with: down)
            controller.canvas.mouseDragged(with: dragged)
            controller.canvas.mouseUp(with: up)
            check(!controller.isReadyForRecoveryCopy,
                  "recovery waits for a crop preview awaiting Return")
            if let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53) {
                _ = controller.canvas.tools.keyDown(with: escape)
            }
            check(controller.isReadyForRecoveryCopy,
                  "cancelling a crop preview permits recovery again")
        } else {
            check(false, "the recovery gesture readiness check receives pointer events")
        }
        ToolState.shared.select(previousTool)

        paint(20)
        let revision = document.history?.revision
        let undoSteps = document.undoInfo.undoCount
        check(document.hasUnsavedChanges && revision != nil, "a new edit makes the document dirty")

        let second = try ImageDocument(session: session, image: session.newImage(width: 32, height: 32), name: "Recovery 2")
        documents.items.append(second)
        let secondController = DocumentWindowController(document: second)
        scheduler.track(second, isReady: { [weak secondController] in
            secondController?.isReadyForRecoveryCopy ?? false
        })
        second.beginStroke(at: .init(x: 12, y: 12, pressure: 1))
        second.endStroke()
        second.inputQueue.sync {}
        spin()
        defer {
            scheduler.untrack(second)
            secondController.window?.orderOut(nil)
            documents.items.removeAll { $0 === second }
            second.closeImageWhenDrained()
        }

        tickFire?()
        wait { store.record(for: document.recoveryID) != nil && scheduler.copying == nil
                && document.pendingWork == 0 && second.pendingWork == 0 }
        check(store.record(for: second.recoveryID) != nil,
              "one recovery pass copies both dirty documents through real engine admission")
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

    /// The recovery interface end to end: a dead run's real committed
    /// records are listed by the panel, a selected one opens as an
    /// unsaved recovered document through counted engine admission, the
    /// prior record stays until that document explicitly closes, and a
    /// recovery finishing during Quit is cleaned up instead of opened.
    private static func exerciseRecoveryInterface(_ session: EngineSession, work: URL,
                                                  documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin() }
        }

        // A document with real pixels saved natively: the "crashed" run's
        // copies are committed through the store's own atomic path.
        let sourceImage = try session.newImage(width: 64, height: 64)
        let source = try ImageDocument(session: session, image: sourceImage, name: "Crash Source")
        documents.items.append(source)
        source.beginStroke(at: .init(x: 16, y: 16, pressure: 1))
        source.endStroke()
        source.inputQueue.sync {}
        spin()
        let native = work.appendingPathComponent("original.xcf")
        try session.save(sourceImage, to: native.path)
        source.noteSaved(to: native)
        let nativeBytes = try Data(contentsOf: native)
        let sourceLayers = source.layers.count
        defer {
            documents.items.removeAll { $0 === source }
            source.closeImageWhenDrained()
        }

        let storeBase = work.appendingPathComponent("recovery-ui-store")
        let priorStore = RecoveryStore(base: storeBase, runID: UUID(), ownerPID: Int32.max - 1234,
                                       processIsAlive: { _ in false })
        try priorStore.prepare()
        func commitPrior(_ id: UUID, _ name: String, imported: URL? = nil,
                         native nativeURL: URL? = nil, revision: UInt64 = 1) throws {
            let temp = priorStore.temporaryCopyURL(for: id)
            try session.saveCopy(sourceImage, to: temp.path)
            _ = try priorStore.commitCopy(at: temp, for: id, metadata: .init(
                name: name, nativeURL: nativeURL, importedSourceURL: imported, revision: revision))
        }
        let firstID = UUID(), otherID = UUID(), quitID = UUID(), badID = UUID()
        try commitPrior(firstID, "original.xcf", native: native, revision: 7)
        let ghost = work.appendingPathComponent("ghost.png")
        try Data("png".utf8).write(to: ghost)
        try commitPrior(otherID, "other.xcf", imported: ghost, revision: 2)
        try commitPrior(quitID, "quit.xcf")
        let badTemp = priorStore.temporaryCopyURL(for: badID)
        try Data("not an xcf".utf8).write(to: badTemp)
        _ = try priorStore.commitCopy(at: badTemp, for: badID, metadata: .init(
            name: "bad.xcf", nativeURL: nil, importedSourceURL: nil, revision: 1))

        // A foreign run whose owner is this live process is never offered.
        let liveRunID = UUID()
        let liveDir = storeBase.appendingPathComponent(liveRunID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        try JSONEncoder().encode(RecoveryStore.Run(runID: liveRunID,
                                                 pid: ProcessInfo.processInfo.processIdentifier,
                                                 started: Date()))
            .write(to: liveDir.appendingPathComponent(RecoveryStore.runFilename))
        try Data("live".utf8).write(to: liveDir.appendingPathComponent("\(UUID().uuidString).xcf"))

        let store = RecoveryStore(base: storeBase, runID: UUID(),
                                  processIsAlive: { $0 == ProcessInfo.processInfo.processIdentifier })
        try store.prepare()
        let app = AppController()
        app.recoveryStore = store
        let found = store.discoverRecoverableDocuments()
        check(found.count == 4 && !found.contains { $0.runID == liveRunID },
              "dead runs' committed records are discoverable; live runs' are not")
        guard let candidate = found.first(where: { $0.documentID == firstID }) else { return }

        app.recoverDocuments(nil)
        let panel = app.recoveryPanel
        check(panel != nil && panel?.window?.canBecomeMain == false && panel?.records.count == 4,
              "the recovery panel lists prior records without taking main")

        // A repeated click while the recovery is counted cannot
        // duplicate it.
        app.recover([candidate], using: session)
        check(!app.inFlightRecoveries.isEmpty, "the recovery is counted in flight")
        app.recover([candidate], using: session)
        wait { app.inFlightRecoveries.isEmpty }
        let recovered = app.documents.last?.imageDocument
        if let recovered { documents.items.append(recovered) }
        check(app.documents.count == 1 && recovered?.name == "original.xcf recovered",
              "the record opens once as 'name recovered'")
        check(recovered?.hasUnsavedChanges == true && recovered?.fileState.nativeURL == nil
                && recovered?.fileState.importedSourceURL == nil
                && recovered?.fileState.saveRoute == .askForFile,
              "the recovered document is unsaved with no file identity, so Save asks a destination")
        check(recovered?.undoInfo.undoCount == 0,
              "the recovered image carries fresh undo")
        if let image = recovered?.image {
            check((pixel(session, image, x: 16, y: 16)?[0] ?? 255) < 128
                    && recovered?.layers.count == sourceLayers,
                  "the recovered document holds the same pixels and layers")
        }
        check((try? Data(contentsOf: native)) == nativeBytes,
              "the original file is never opened or overwritten")
        check(!NSDocumentController.shared.recentDocumentURLs.contains {
            $0.path.hasPrefix(storeBase.path)
        }, "recovery copies are never marked recent")
        check(store.discoverRecoverableDocuments().contains { $0.documentID == firstID },
              "a recovered record is kept while its document is open")

        app.recover([candidate], using: session)
        wait { app.inFlightRecoveries.isEmpty }
        check(app.documents.count == 1,
              "recovering an already-open record brings its window forward")
        app.discardSelected([candidate])
        check(store.discoverRecoverableDocuments().contains { $0.documentID == firstID }
                && app.lastRecoveryFailure != nil,
              "a record open as a recovered document refuses discard visibly")

        // Only an explicit close (Save or Don't Save) retires the prior
        // record and deletes its copy.
        let recoveredController = app.documents.last
        var recoveredClosed: Bool?
        recoveredController?.requestClose { recoveredClosed = $0 }
        let closeDeadline = Date().addingTimeInterval(10)
        while recoveredClosed == nil && Date() < closeDeadline {
            spin(0.02)
            if let sheet = recoveredController?.window?.attachedSheet {
                NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertThirdButtonReturn.rawValue)
            }
        }
        wait { app.documents.isEmpty }
        check(recoveredClosed == true
                && !store.discoverRecoverableDocuments().contains { $0.documentID == firstID }
                && !FileManager.default.fileExists(atPath: candidate.copyURL.path),
              "an explicit close retires the prior record and deletes its copy")
        if let recovered { documents.items.removeAll { $0 === recovered } }
        recovered?.longQueue.sync {}
        PaletteCenter.shared.closeAll()

        // A failed open keeps the record and reports it; a stale row and
        // a live run refuse without deleting anything.
        guard let bad = store.discoverRecoverableDocuments().first(where: { $0.documentID == badID }) else { return }
        app.recover([bad], using: session)
        wait { app.inFlightRecoveries.isEmpty }
        check(app.documents.isEmpty && app.lastRecoveryFailure?.contains("bad.xcf") == true,
              "a failed recovery shows an error and opens nothing")
        check(store.discoverRecoverableDocuments().contains { $0.documentID == badID },
              "a failed recovery keeps the record available")

        guard let other = store.discoverRecoverableDocuments().first(where: { $0.documentID == otherID }),
              let quitCandidate = store.discoverRecoverableDocuments().first(where: { $0.documentID == quitID })
        else { return }
        var stale = quitCandidate
        stale.name = "changed.xcf"
        app.recover([stale], using: session)
        wait { app.inFlightRecoveries.isEmpty }
        check(app.documents.isEmpty && app.lastRecoveryFailure?.contains("no longer available") == true,
              "a stale record refuses visibly instead of opening")
        check(store.discoverRecoverableDocuments().contains { $0.documentID == quitID },
              "a refused record stays on disk")

        app.discardSelected([other])
        check(!store.discoverRecoverableDocuments().contains { $0.documentID == otherID }
                && !FileManager.default.fileExists(atPath: other.copyURL.path),
              "Discard deletes the prior record and its copy")
        check((try? String(contentsOf: ghost, encoding: .utf8)) == "png",
              "an informational source URL is never a deletion target")

        let liveCandidate = RecoveryStore.RecoveredDocument(
            runID: liveRunID, documentID: UUID(), name: "live.xcf",
            nativeURL: nil, importedSourceURL: nil,
            copyURL: liveDir.appendingPathComponent("planted.xcf"),
            date: Date(), revision: 1)
        app.discardSelected([liveCandidate])
        check(app.lastRecoveryFailure != nil && FileManager.default.fileExists(atPath: liveDir.path),
              "a live run's folder is never deleted")

        // Quit ordering: an in-flight recovery holds Quit; a recovery
        // that finishes during Quit is closed again, not opened, and its
        // record survives for the next launch.
        check(app.applicationShouldTerminate(NSApp) == .terminateNow,
              "with nothing open and nothing in flight, Quit proceeds")
        app.recover([quitCandidate], using: session)
        check(app.applicationShouldTerminate(NSApp) == .terminateLater,
              "an in-flight recovery holds Quit")
        wait { app.inFlightRecoveries.isEmpty }
        wait { app.applicationShouldTerminate(NSApp) == .terminateNow }
        check(app.documents.isEmpty,
              "a recovery finished during Quit is cleaned up, not opened")
        check(store.discoverRecoverableDocuments().contains { $0.documentID == quitID },
              "the record survives a recovery interrupted by Quit")
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
            guard let target = document.layers.first(where: { $0.kind == .text }),
                  let deletePress = NSEvent.mouseEvent(with: .leftMouseDown,
                    location: controller.canvas.convert(CGPoint(x: target.bounds.midX * controller.canvas.scale,
                                                                y: target.bounds.midY * controller.canvas.scale), to: nil),
                    modifierFlags: [], timestamp: 1, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1) else {
                return check(false, "the saved text has a fresh canvas click target")
            }
            controller.canvas.mouseDown(with: deletePress)
            check(controller.canvas.tools.textEditor?.textLayer == target.id
                    && controller.canvas.tools.textEditor?.string == "Saved text",
                  "a fresh click reopens the saved text before deleting its content")
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

    /// File ▸ Revert…: the confirm sheet, the file-admission reload and
    /// the window replacement on success — plus every refusal path:
    /// Cancel, an unreadable source, an untitled image and a direct
    /// close while the file loads. Adoption needs the app's document
    /// list, so this drives a real AppController.
    private static func exerciseRevert(_ session: EngineSession, work: URL,
                                       documents: DocumentList) throws {
        let app = AppController()
        let directory = work.appendingPathComponent("revert")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let native = directory.appendingPathComponent("keep.xcf")
        var tracked: [ImageDocument] = []
        defer {
            documents.items.removeAll { item in tracked.contains { $0 === item } }
        }

        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin() }
        }
        func track(_ document: ImageDocument) {
            tracked.append(document)
            documents.items.append(document)
            app.open(document)
        }
        func confirm(_ response: NSApplication.ModalResponse, on owner: DocumentWindowController) {
            wait { owner.window?.attachedSheet != nil }
            if let sheet = owner.window?.attachedSheet {
                NSApp.endSheet(sheet, returnCode: response.rawValue)
            }
        }
        let revertItem = NSMenuItem(title: "", action: #selector(DocumentWindowController.revertDocument(_:)), keyEquivalent: "")

        // The saved source: a 64×64 XCF with one stroke near the top.
        let setup = try session.newImage(width: 64, height: 64)
        if let layer = try session.layers(setup).first?.id {
            let stroke = try session.beginStroke(image: setup, drawable: layer,
                                                 brush: .init(), first: .init(x: 10, y: 10, pressure: 1))
            try session.endStroke(stroke)
        }
        try session.save(setup, to: native.path)
        try session.closeImage(setup)
        let savedBytes = try Data(contentsOf: native)

        let image = try session.openImage(path: native.path)
        let document = try ImageDocument(session: session, image: image,
                                         name: native.lastPathComponent, openedFrom: native)
        track(document)
        guard let controller = app.documents.last else { throw NoWindow() }
        controller.zoom(to: 150)
        let window = try XCTUnwrapWindow(controller)
        let frame = window.frame

        // A second document exercises the drain: its accepted stroke
        // must land before the reload, and it stays untouched itself.
        let otherImage = try session.newImage(width: 64, height: 64)
        let other = try ImageDocument(session: session, image: otherImage, name: "Untitled")
        track(other)
        guard let otherController = app.documents.last else { throw NoWindow() }
        check(!otherController.validateMenuItem(revertItem),
              "an untitled document cannot revert")
        otherController.revertDocument(nil)
        spin(0.15)
        check(otherController.window?.attachedSheet == nil,
              "Revert asks nothing when the document has no source")

        document.beginStroke(at: .init(x: 50, y: 50, pressure: 1))
        document.endStroke()
        wait { document.pendingWork == 0 && document.hasUnsavedChanges }
        check(controller.validateMenuItem(revertItem) && revertItem.title == "Revert to Saved…",
              "Revert is offered on a saved file as Revert to Saved…")
        controller.revertDocument(nil)
        confirm(.alertSecondButtonReturn, on: controller)
        spin(0.2)
        check(app.documents.contains(where: { $0 === controller }) && app.documents.count == 2 && !controller.revertIsPending
                && document.hasUnsavedChanges && !document.isClosing
                && (pixel(session, image, x: 50, y: 50)?[0] ?? 255) < 128,
              "a cancelled Revert preserves the edits, image and window")
        check((try? Data(contentsOf: native)) == savedBytes, "a cancelled Revert never touches the source")

        // Accepted input in the other document drains before the load.
        other.beginStroke(at: .init(x: 30, y: 30, pressure: 1))
        other.endStroke()
        controller.revertDocument(nil)
        confirm(.alertFirstButtonReturn, on: controller)
        wait { !app.documents.contains(where: { $0 === controller }) }
        guard let first = app.documents.last else { throw NoWindow() }
        documents.items.removeAll { $0 === document }
        tracked.append(first.imageDocument)
        documents.items.append(first.imageDocument)
        check(first !== controller && first.imageDocument !== document
                && first.imageDocument.image != image
                && first.imageDocument.fileState.nativeURL == native
                && !first.imageDocument.hasUnsavedChanges
                && first.imageDocument.undoInfo.undoCount == 0,
              "a confirmed Revert adopts a clean fresh-history reload of the saved file")
        wait { (try? session.info(image)) == nil && !window.isVisible }
        check(controller.closeStarted && (try? session.info(image)) == nil && !window.isVisible,
              "the discarded document closes without a save prompt and its image is destroyed")
        check(first.window.map { abs($0.frame.minX - frame.minX) < 1 && abs($0.frame.minY - frame.minY) < 1
                && $0.frame.size == frame.size } == true
                && first.canvas.zoomPercent == 150,
              "the replacement window keeps the old frame and zoom")
        check((pixel(session, first.imageDocument.image, x: 10, y: 10)?[0] ?? 255) < 128
                && (pixel(session, first.imageDocument.image, x: 50, y: 50)?[0] ?? 0) > 127,
              "the reverted image has the saved stroke and none of the discarded edits")
        check((try? Data(contentsOf: native)) == savedBytes, "a confirmed Revert never writes to the source")
        wait { other.pendingWork == 0 }
        check((pixel(session, otherImage, x: 30, y: 30)?[0] ?? 255) < 128
                && other.image == otherImage && app.documents.contains(where: { $0 === otherController }),
              "input accepted in another document drains before the load; the document is untouched")

        // A source rewritten on disk loads its new bytes.
        let rewritten = try session.newImage(width: 32, height: 48)
        try session.save(rewritten, to: native.path)
        try session.closeImage(rewritten)
        first.revertDocument(nil)
        confirm(.alertFirstButtonReturn, on: first)
        wait { !app.documents.contains(where: { $0 === first }) }
        guard let second = app.documents.last else { throw NoWindow() }
        documents.items.removeAll { $0 === first.imageDocument }
        tracked.append(second.imageDocument)
        documents.items.append(second.imageDocument)
        check(second !== first && second.imageDocument.info.width == 32
                && second.imageDocument.info.height == 48
                && second.imageDocument.fileState.nativeURL == native,
              "Revert reloads the source's new bytes after an external rewrite")

        // An unreadable source keeps the whole document usable.
        second.imageDocument.beginStroke(at: .init(x: 5, y: 5, pressure: 1))
        second.imageDocument.endStroke()
        wait { second.imageDocument.pendingWork == 0 && second.imageDocument.hasUnsavedChanges }
        try FileManager.default.removeItem(at: native)
        second.revertDocument(nil)
        confirm(.alertFirstButtonReturn, on: second)
        wait { !second.revertIsPending }
        check(app.documents.last === second && !second.imageDocument.isClosing
                && second.imageDocument.hasUnsavedChanges
                && second.window?.isVisible == true
                && (try? session.info(second.imageDocument.image)) != nil,
              "a failed Revert keeps the original image, window and unsaved changes")
        check(!second.statusBar.message.hasPrefix("32 × 48"),
              "a failed Revert reports its error instead of restoring the status line")

        // An imported original re-imports and keeps imported identity.
        let png = directory.appendingPathComponent("imported.png")
        let foreign = try session.newImage(width: 24, height: 24)
        try session.export(foreign, to: png.path)
        try session.closeImage(foreign)
        let imported = try ImageDocument(session: session, image: session.openImage(path: png.path),
                                         name: png.lastPathComponent, openedFrom: png)
        track(imported)
        guard let importedController = app.documents.last else { throw NoWindow() }
        check(importedController.validateMenuItem(revertItem) && revertItem.title == "Revert…",
              "an imported document is offered Revert…")
        importedController.revertDocument(nil)
        confirm(.alertFirstButtonReturn, on: importedController)
        wait { !app.documents.contains(where: { $0 === importedController }) }
        guard let reimported = app.documents.last else { throw NoWindow() }
        documents.items.removeAll { $0 === imported }
        tracked.append(reimported.imageDocument)
        documents.items.append(reimported.imageDocument)
        check(reimported.imageDocument.fileState.nativeURL == nil
                && reimported.imageDocument.fileState.importedSourceURL == png
                && reimported.imageDocument.hasUnsavedChanges,
              "a re-import keeps the imported identity and unsaved state")

        // A direct close during the load follows file admission: the
        // close waits for the engine, wins, and the loaded image is
        // destroyed unadopted.
        let closingFile = directory.appendingPathComponent("closing.xcf")
        let setup2 = try session.newImage(width: 32, height: 32)
        try session.save(setup2, to: closingFile.path)
        try session.closeImage(setup2)
        let closingImage = try session.openImage(path: closingFile.path)
        let closingDoc = try ImageDocument(session: session, image: closingImage,
                                           name: closingFile.lastPathComponent, openedFrom: closingFile)
        track(closingDoc)
        guard let closingController = app.documents.last else { throw NoWindow() }
        let countBefore = app.documents.count
        closingDoc.inputQueue.async { usleep(400_000) }
        closingController.revertDocument(nil)
        confirm(.alertFirstButtonReturn, on: closingController)
        wait { closingController.revertIsPending }
        check(closingController.revertIsPending, "a confirmed Revert marks its pending load")
        var closedDuringLoad: Bool?
        closingController.requestClose { closedDuringLoad = $0 }
        wait { closedDuringLoad != nil }
        check(closedDuringLoad == true, "a close during the Revert load completes")
        wait { (try? session.info(closingImage)) == nil
                && !app.documents.contains(where: { $0 === closingController }) }
        check(app.documents.count == countBefore - 1,
              "the closing document leaves and no duplicate window is adopted for it")
        check(FileManager.default.fileExists(atPath: closingFile.path),
              "the source file survives a close during the load")

        let survivors = app.documents
        survivors.forEach { $0.closeDiscardingChanges() }
        wait { app.documents.isEmpty }
        check(app.documents.isEmpty, "all documents close cleanly after the revert checks")
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
        document.layerCommand(.fitToImage)
        waitForWork(document)
        check(document.layers.first?.bounds == CGRect(x: 0, y: 0, width: 64, height: 64),
              "Layer to Image Size grows the pasted layer to the canvas, keeping its pixels")
        document.layerCommand(.trimToContent)
        waitForWork(document)
        check(document.layers.first?.bounds == CGRect(x: 8, y: 10, width: 2, height: 2),
              "Trim Layer to Content crops it back to its content at the same spot")
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

    private static func exerciseEffectBindings(_ session: EngineSession) throws {
        let image = try session.newImage(width: 32, height: 32)
        defer { try? session.closeImage(image) }
        guard let layer = try session.layers(image).first?.id else { throw NoWindow() }
        let initial = try session.effects(on: layer, image: image)
        check(initial.isEmpty, "a new drawable has no committed effects")
        let preview = try session.beginFilter(image: image, drawable: layer, operation: "gegl:value-invert")
        check(try session.effects(on: layer, image: image).isEmpty,
              "a live preview is not mistaken for a committed effect id")
        try session.commitFilter(preview)
        guard let invert = try session.effects(on: layer, image: image).first else { throw NoWindow() }
        check(invert.operation == "gegl:value-invert" && invert.isEnabled && invert.opacity == 1,
              "the committed effect reads back its operation, enabled state and opacity")
        check((pixel(session, image, x: 10, y: 10)?[0] ?? 255) < 20,
              "the committed invert changes white image pixels to black")
        try session.changeEffect(invert.id, on: layer, image: image,
                                 .init(name: "Negative", isEnabled: false, opacity: 0.5))
        let disabled = try session.effects(on: layer, image: image).first
        check(disabled?.name == "Negative" && disabled?.isEnabled == false && disabled?.opacity == 0.5,
              "one effect change marshals all requested properties")
        check((pixel(session, image, x: 10, y: 10)?[0] ?? 0) > 230,
              "disabling the effect restores the drawable's white output")
        try session.undo(image)
        check(try session.effects(on: layer, image: image).first == invert,
              "one Undo restores the effect's complete property state")
        check((pixel(session, image, x: 10, y: 10)?[0] ?? 255) < 20,
              "property Undo restores the effect's pixels")
        try session.redo(image)
        check(try session.effects(on: layer, image: image).first == disabled,
              "property Redo restores the changed metadata")
        try session.changeEffect(invert.id, on: layer, image: image, .init(isEnabled: true, opacity: 1))
        let secondPreview = try session.beginFilter(image: image, drawable: layer, operation: "gegl:value-invert")
        try session.commitFilter(secondPreview)
        let pair = try session.effects(on: layer, image: image)
        guard pair.count == 2, let top = pair.first else { throw NoWindow() }
        check(top.id != invert.id && pair.last?.id == invert.id,
              "the effect list preserves the native top-first order and distinct ids")
        try session.effectCommand(.toBottom, effect: top.id, on: layer, image: image)
        check(try session.effects(on: layer, image: image).last?.id == top.id,
              "To Bottom reorders the named committed effect")
        try session.effectCommand(.raise, effect: top.id, on: layer, image: image)
        check(try session.effects(on: layer, image: image).first?.id == top.id,
              "Raise moves the effect toward the top")
        try session.effectCommand(.remove, effect: top.id, on: layer, image: image)
        check(try session.effects(on: layer, image: image).map(\.id) == [invert.id],
              "Remove drops only the named effect")
        let beforeMerge = pixel(session, image, x: 10, y: 10)
        try session.effectCommand(.merge, effect: invert.id, on: layer, image: image)
        check(try session.effects(on: layer, image: image).isEmpty,
              "Merge removes the baked effect from the committed stack")
        check(pixel(session, image, x: 10, y: 10) == beforeMerge,
              "Merge keeps the actual composited pixels unchanged")
        try session.undo(image)
        check(try session.effects(on: layer, image: image).first?.id == invert.id,
              "merge Undo restores the same effect identity")
        do {
            try session.changeEffect(top.id, on: layer, image: image, .init(isEnabled: false))
            check(false, "a removed effect id is refused")
        } catch {
            check(true, "a removed effect id is refused without touching the remaining effect")
        }
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

    /// Layer masks end to end through the document: the mask thumbnail
    /// pick and its queued ordering, mask painting, disabled and shown
    /// masks, Copy/Clear targeting, mask-to-selection, apply and undo,
    /// group masks, filter preview on a mask, and the refusals for edits
    /// a mask cannot take.
    /// A layer pick must leave a channel even when that layer was already
    /// selected natively. Otherwise implicit fills still edit the channel.
    private static func exerciseClipboardReentrantClose(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 8, height: 8)
        let document = try ImageDocument(session: session, image: image, name: "Cut Close")
        documents.items.append(document)
        defer {
            documents.items.removeAll { $0 === document }
            if !document.isClosing { document.closeImageWhenDrained() }
        }
        var closed = false, completed = false
        var failure: Error?
        document.copyPixels(.cutLayer, background: .white, consume: { _ in
            // The consumer may synchronously close its document. The
            // deferred Clear must still complete the clipboard transaction.
            document.closeImageWhenDrained { closed = true }
        }, completion: { error in completed = true; failure = error })
        let deadline = Date().addingTimeInterval(3)
        while (!closed || !completed) && Date() < deadline { spin(0.02) }
        check(completed && failure?.localizedDescription == ImageDocument.DocumentError.closed.localizedDescription,
              "closing inside Cut's consumer completes the transaction with a closed-image error")
        check(closed && document.pendingWork == 0 && !document.isTransferringClipboard,
              "a reentrant Cut close clears its transfer gate and drains the image")
    }

    private static func exerciseChannelTargets(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 64, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Channel Targets")
        documents.items.append(document)
        defer {
            documents.items.removeAll { $0 === document }
            document.closeImageWhenDrained()
        }
        var errors: [String] = []
        document.onError = { errors.append($0) }
        func settle() { document.inputQueue.sync {}; spin() }
        func sample(_ drawable: Int32, _ x: Int, _ y: Int) -> [UInt8]? {
            guard let cg = try? session.drawableThumbnail(drawable, image: image, maxSize: 64),
                  let data = cg.dataProvider?.data as Data? else { return nil }
            let offset = (y * cg.width + x) * 4
            guard offset + 4 <= data.count else { return nil }
            return Array(data[offset..<offset + 4])
        }
        guard let layer = document.activeLayer else { return }
        try session.select(.rectangle(CGRect(x: 20, y: 20, width: 24, height: 24)),
                           image: image, options: .init())
        let channel = try session.channelFromSelection(image, name: "Saved area")
        try session.select(.none, image: image)
        try document.reload()
        check(document.activeDrawable == channel,
              "the document reports the native selected channel as its paint target")
        document.selectLayer(layer)
        document.fill(at: .zero, mode: .selection, color: .red, threshold: 0, sampleMerged: false)
        settle()
        check((try session.channels(image)).allSatisfy { !$0.isSelected },
              "picking the already-selected layer explicitly leaves the saved channel")
        check(sample(layer, 8, 8).map { $0[0] > 230 && $0[1] < 30 && $0[2] < 30 } == true,
              "a fill after returning from a channel paints the layer")
        check(sample(channel, 8, 8).map { $0[0] < 20 } == true,
              "returning to the layer preserves the saved channel pixels")

        document.selectChannel(channel)
        check(document.activeDrawable == channel && document.activeChannel == channel && !document.isMaskTargetActive,
              "a channel pick immediately mirrors its own drawable rather than a layer mask")
        document.fill(at: .zero, mode: .selection, color: .white, threshold: 0, sampleMerged: false)
        settle()
        check(sample(channel, 8, 8).map { $0[0] > 230 } == true
                && sample(layer, 8, 8).map { $0[1] < 30 } == true,
              "a queued fill paints the saved channel and preserves the red layer")
        document.addMask(layer, source: .white, edit: true)
        settle()
        guard let mask = document.maskStates[layer]?.mask else {
            check(false, "Add Mask creates an edit target while a channel is selected")
            return
        }
        let channelsAfterMask = try session.channels(image)
        check(document.activeDrawable == mask && document.isMaskTargetActive
                && document.activeChannel == nil && channelsAfterMask.allSatisfy { !$0.isSelected },
              "adding an editing mask leaves the saved channel")
        document.selectChannel(channel)
        document.editMask(layer)
        document.fill(at: .zero, mode: .selection, color: .black, threshold: 0, sampleMerged: false)
        settle()
        check(sample(mask, 8, 8).map { $0[0] < 20 } == true
                && sample(channel, 8, 8).map { $0[0] > 230 } == true,
              "a channel-to-mask pick routes the immediately queued fill to the mask")

        let gate = DispatchSemaphore(value: 0)
        document.inputQueue.async { gate.wait() }
        document.selectChannel(channel)
        document.selectLayer(layer)
        document.selectChannel(channel)
        try document.reload()
        check(document.activeDrawable == channel && document.channels.first(where: { $0.id == channel })?.isSelected == true,
              "a reload preserves the newest queued channel pick")
        document.fill(at: .zero, mode: .selection, color: .black, threshold: 0, sampleMerged: false)
        gate.signal()
        settle()
        check(document.activeChannel == channel && sample(channel, 8, 8).map { $0[0] < 20 } == true,
              "rapid channel/layer/channel picks finish on the last target")
        let positionBefore = try session.layers(image).first { $0.id == layer }?.bounds
        document.moveActiveLayer(by: CGSize(width: 8, height: 3))
        document.transformActiveLayer(.flipHorizontal)
        settle()
        check((try session.layers(image).first { $0.id == layer }?.bounds) == positionBefore
                && errors.contains(where: { $0.contains("Return to Layers") }),
              "channel-target move and transform refuse without changing the remembered layer")

        // Delete after the cached row was read, before the pick lands.
        document.run { session, image in
            _ = try session.channelCommand(.delete, channel: channel, image: image)
        }
        document.selectChannel(channel)
        document.fill(at: .zero, mode: .selection, color: .white, threshold: 0, sampleMerged: false)
        settle()
        check(document.activeDrawable == nil && errors.contains(where: { $0.contains("target") }),
              "a removed-channel pick refuses queued pixel edits rather than falling back")
        document.setComponentVisible(.blue, to: false)
        document.setComponentVisible(.blue, to: true)
        settle()
        check(document.activeDrawable == nil,
              "display-only component toggles cannot reopen a refused paint target")
        document.saveSelectionToChannel(name: "Recovered target")
        check(document.activeDrawable == nil, "creating a channel gates drawable capture until its id is known")
        settle()
        guard let recovered = document.activeChannel else {
            check(false, "a successful new channel recovers a refused paint target")
            return
        }
        document.fill(at: .zero, mode: .selection, color: .white, threshold: 0, sampleMerged: false)
        settle()
        check(sample(recovered, 8, 8).map { $0[0] > 230 } == true
                && sample(layer, 8, 8).map { $0[1] < 30 } == true,
              "the recovered target receives paint while the layer stays intact")
        document.changeChannel(recovered, .init(isVisible: true))
        document.changeChannel(recovered, .init(isVisible: false))
        try document.reload()
        check(document.channels.first(where: { $0.id == recovered })?.isVisible == false,
              "a reload keeps the latest queued channel visibility choice")
        settle()
        check((try session.channels(image)).first(where: { $0.id == recovered })?.isVisible == false,
              "rapid channel visibility toggles finish at the latest value")

        document.setComponentActive(.red, to: false)
        document.setComponentActive(.red, to: true)
        try document.reload()
        check(document.components?.active.contains(.red) == true,
              "component editing mirrors the last queued toggle through reloads")
        settle()
        let componentsAfterPick = try session.components(image)
        check(document.activeChannel == nil && componentsAfterPick.active.contains(.red),
              "changing editable components returns painting from channels to layers")
        document.selectLayer(layer)
        settle()
        // Mask display is not a layer-pixel edit; leave its black pixels
        // intact while checking that only the red component changes.
        document.setComponentActive(.green, to: false)
        document.setComponentActive(.blue, to: false)
        settle()
        document.fill(at: .zero, mode: .selection, color: .cyan, threshold: 0, sampleMerged: false)
        settle()
        check(sample(layer, 8, 8).map { $0[0] < 30 && $0[1] < 30 && $0[2] < 30 } == true,
              "a component-limited fill changes red without writing green or blue")
        document.setComponentActive([.green, .blue], to: true)
        settle()

        let quickGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { quickGate.wait() }
        document.setQuickMask(true)
        check(document.quickMaskState?.enabled == true && document.activeDrawable == nil,
              "Quick Mask mirrors its toggle while the new target id is pending")
        document.selectLayer(layer)
        quickGate.signal()
        settle()
        check(document.quickMaskState?.enabled == true && document.activeDrawable == layer,
              "a later known layer pick wins a queued Quick Mask creation")
        document.setQuickMask(false)
        settle()
        document.setQuickMask(true)
        document.setQuickMask(false)
        try document.reload()
        check(document.quickMaskState?.enabled == false,
              "rapid Quick Mask toggles mirror the final off choice")
        settle()
        check(!(try session.quickMask(image)).enabled && document.quickMaskState?.enabled == false,
              "rapid Quick Mask toggles finish with no live mask channel")
        document.setQuickMask(true)
        settle()
        guard let quickChannel = document.activeChannel else {
            check(false, "Quick Mask becomes the document's channel paint target")
            return
        }
        document.fill(at: .zero, mode: .selection, color: .white, threshold: 0, sampleMerged: false)
        settle()
        check(document.activeDrawable == quickChannel && sample(quickChannel, 8, 8).map { $0[0] > 230 } == true,
              "painting on Quick Mask changes its channel pixels")
        document.setQuickMask(false)
        settle()
        let bounds = try session.selectionBounds(image: image)
        check(bounds == CGRect(x: 0, y: 0, width: 64, height: 64),
              "turning off a painted Quick Mask converts it into the selection")

        let palette = ChannelsPaletteController()
        palette.retarget(to: document)
        guard let channelView = palette.view as? ChannelsPaletteView else {
            check(false, "the registered Channels controller presents its interactive view")
            return
        }
        channelView.onAction?(.selectChannel(recovered))
        settle()
        palette.reload()
        check(document.activeChannel == recovered && channelView.snapshot.activeChannel == recovered,
              "the palette's bound channel action updates the engine and target ring snapshot")
        channelView.onAction?(.setChannelVisible(recovered, true))
        settle()
        palette.reload()
        check((try session.channels(image)).first { $0.id == recovered }?.isVisible == true,
              "the palette's Eye action changes the real channel overlay")
        channelView.onAction?(.returnToLayers)
        settle()
        palette.reload()
        check(document.activeDrawable == layer && channelView.snapshot.activeChannel == nil,
              "the palette's Return to Layers action restores the layer target")
        channelView.onAction?(.setChannelVisible(recovered, false))
        settle()

        let windowController = DocumentWindowController(document: document)
        defer { windowController.window?.orderOut(nil) }
        func qEvent(repeatKey: Bool = false, flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: windowController.window?.windowNumber ?? 0, context: nil,
                characters: "q", charactersIgnoringModifiers: "q", isARepeat: repeatKey, keyCode: 12)
        }
        if let key = qEvent() {
            check(windowController.canvas.tools.keyDown(with: key), "the focused canvas accepts Q for Quick Mask")
            settle()
            check(document.quickMaskState?.enabled == true, "Q enables the real Quick Mask")
        } else { check(false, "a Q key event can be created") }
        if let key = qEvent(repeatKey: true) {
            _ = windowController.canvas.tools.keyDown(with: key)
            settle()
            check(document.quickMaskState?.enabled == true, "holding Q does not repeatedly toggle Quick Mask")
        }
        if let key = qEvent(flags: [.command]) {
            check(!windowController.canvas.tools.keyDown(with: key), "Command-Q stays available to the app's Quit command")
        }
        if let key = qEvent() { _ = windowController.canvas.tools.keyDown(with: key) }
        settle()
        check(document.quickMaskState?.enabled == false, "pressing Q again turns Quick Mask off")

        let thumbnailGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { thumbnailGate.wait() }
        try document.reload()
        palette.retarget(to: document)
        check(document.pendingWork > 0, "the Channels palette counts thumbnail reads toward close")
        palette.retarget(to: nil)
        var closed = false
        document.closeImageWhenDrained { closed = true }
        thumbnailGate.signal()
        let closeDeadline = Date().addingTimeInterval(3)
        while !closed && Date() < closeDeadline { spin(0.02) }
        check(closed && document.pendingWork == 0 && (try? session.info(image)) == nil,
              "retargeting cancels stale channel thumbnails and close drains their queued reads")
    }

    private static func exerciseLayerMasks(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 64, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Masks")
        documents.items.append(document)
        defer {
            document.onWillChangeLayers = nil
            documents.items.removeAll { $0 === document }
            document.closeImageWhenDrained()
        }
        let controller = DocumentWindowController(document: document)
        var errors: [String] = []
        let previousError = document.onError
        document.onError = { message in errors.append(message); previousError?(message) }
        func settle() {
            document.inputQueue.sync {}
            spin()
        }
        /// One pixel of the rendered composite at image coordinates.
        func composite(_ x: Int, _ y: Int) -> [UInt8]? { pixel(session, image, x: x, y: y) }
        /// One pixel of `drawable`'s bounded thumbnail; thumbnails come
        /// back at half size for this 64 px image.
        func thumbPixel(_ drawable: Int32, _ x: Int, _ y: Int) -> [UInt8]? {
            guard let cg = try? session.drawableThumbnail(drawable, image: image, maxSize: 32),
                  let data = cg.dataProvider?.data as Data? else { return nil }
            let offset = (y * cg.width + x) * 4
            guard offset + 4 <= data.count else { return nil }
            return Array(data[offset..<offset + 4])
        }
        func luminance(_ rgba: [UInt8]?) -> Int {
            guard let rgba else { return -1 }
            return (Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2])) / 3
        }
        let black = EngineSession.Brush(size: 8, opacity: 1, red: 0, green: 0, blue: 0, pressureSize: false)
        guard let layer = document.activeLayer else {
            check(false, "a new image has a layer to mask")
            return
        }

        if let window = controller.window {
            controller.showWindow(nil)
            AddMaskForm.present(for: document, on: window)
            spin()
            if let sheet = window.attachedSheet, let content = sheet.contentView {
                let source = descendant(of: content, as: NSPopUpButton.self)
                check((source?.visibleRect.width ?? 0) > 20 && (source?.visibleRect.height ?? 0) > 10,
                      "the Add Mask sheet shows its source picker")
                window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                spin()
            } else { check(false, "Add Mask opens a cancellable sheet") }
        }

        // A dark mark on the layer the mask tests must not lose.
        document.beginStroke(at: .init(x: 10, y: 10, pressure: 1), brush: black)
        document.continueStroke((11...20).map { .init(x: Double($0), y: 10, pressure: 1) })
        document.endStroke()
        settle()
        check(luminance(composite(15, 10)) < 64, "the layer carries a dark mark before masking")

        // Add Mask: white source with Edit Mask Immediately, as the form
        // offers; the mask becomes the active drawable.
        document.addMask(layer, source: .white, edit: true)
        settle()
        guard let mask = document.maskStates[layer], mask.mask != 0, mask.editing else {
            check(false, "Add Mask with Edit Mask Immediately creates an editing mask")
            return
        }
        check(document.activeDrawable == mask.mask && document.isMaskTargetActive,
              "the mask pick makes the mask the active drawable")
        check(document.layers.first(where: { $0.id == layer })?.hasMask == true,
              "the layer reports its mask")

        // Painting on the mask: black over a white mask hides the layer
        // there while the layer's own pixels stay untouched.
        document.beginStroke(at: .init(x: 38, y: 38, pressure: 1), brush: black)
        document.continueStroke((39...46).map { .init(x: Double($0), y: 38, pressure: 1) })
        document.endStroke()
        settle()
        check(luminance(thumbPixel(mask.mask, 21, 19)) < 64,
              "the stroke landed on the mask (dark at the thumbnail)")
        check((composite(42, 38)?[3] ?? 255) < 64,
              "the composite is masked out where the mask is black")
        check(luminance(composite(15, 10)) < 64,
              "the layer's dark mark still shows through the white mask")

        // Copy while the mask is the target copies the mask: its black
        // patch reads dark where the layer's dark mark reads light.
        if let copied = try? session.copyPixels(image, merged: false) {
            func copyPixel(_ x: Int, _ y: Int) -> Int {
                let bx = x - Int(copied.origin.x), by = y - Int(copied.origin.y)
                guard bx >= 0, by >= 0, bx < copied.width, by < copied.height else { return -1 }
                let offset = (by * copied.width + bx) * 4
                guard offset + 3 < copied.pixels.count else { return -1 }
                let px = copied.pixels
                return (Int(px[offset]) + Int(px[offset + 1]) + Int(px[offset + 2])) / 3
            }
            check(copyPixel(42, 38) >= 0 && copyPixel(15, 10) >= 0
                    && copyPixel(42, 38) < copyPixel(15, 10),
                  "Copy targeted the mask (patch \(copyPixel(42, 38)) vs mark \(copyPixel(15, 10)))")
        } else {
            check(false, "Copy while mask editing reads the mask")
        }

        // A disabled mask stops affecting the composite but keeps its
        // pixels; re-enabling restores the masked view.
        document.toggleMaskEnabled()
        settle()
        check((composite(42, 38)?[3] ?? 0) > 200 && luminance(composite(42, 38)) > 200,
              "a disabled mask shows the layer unchanged")
        check(luminance(thumbPixel(mask.mask, 21, 19)) < 64,
              "the disabled mask kept its painted pixels")
        document.toggleMaskEnabled()
        settle()
        check((composite(42, 38)?[3] ?? 255) < 64, "re-enabling restores the masked composite")

        // View Mask (the Option-click flag): the canvas shows the mask's
        // gray levels instead of the composite.
        document.toggleMaskShowing(layer)
        settle()
        check(document.maskStates[layer]?.showing == true, "Show Mask sets the flag")
        check(luminance(composite(15, 10)) > 200 && (composite(15, 10)?[3] ?? 0) > 200,
              "View Mask shows the white mask where the layer is dark")
        check(luminance(composite(42, 38)) < 64, "View Mask shows the black mask patch")
        document.toggleMaskShowing(layer)
        settle()
        check(luminance(composite(15, 10)) < 64, "hiding the mask restores the composite")

        // Multi-layer View Mask: natively the shown mask composites in
        // the layer's own slot, so a layer above still covers it — it
        // is not an isolation view that hides the rest of the stack.
        controller.newLayer(nil)
        settle()
        guard let top = document.activeLayer, top != layer else {
            check(false, "a second layer exists above the masked layer")
            return
        }
        document.fill(at: .zero, mode: .selection, color: .red, threshold: 0, sampleMerged: false)
        settle()
        document.toggleMaskShowing(layer)
        settle()
        check(document.maskStates[layer]?.showing == true
                && (composite(15, 10)?[0] ?? 0) > 200
                && (composite(15, 10)?[1] ?? 0) < 64,
              "View Mask stays in the layer's slot; the layer above composites over it")
        document.toggleMaskShowing(layer)
        settle()
        document.layerCommand(.delete)
        settle()
        document.editMask(layer)
        settle()
        check(document.isMaskTargetActive,
              "the mask target is restored for the remaining checks")

        // Clear while the mask is the target hits the mask: the layer's
        // dark mark survives, the mask's patch does not.
        _ = document.run { session, img in try session.clearPixels(img, background: .white) }
        settle()
        check(luminance(composite(15, 10)) < 64,
              "Clear targeted the mask; the layer's pixels are intact")
        check((composite(42, 38)?[3] ?? 0) > 200, "the cleared mask shows the layer again")

        // A fill queued right behind the mask pick lands on the mask:
        // the pick's engine-side flag is already set when the fill runs.
        document.fill(at: .zero, mode: .selection, color: .black, threshold: 0, sampleMerged: false)
        settle()
        check(luminance(thumbPixel(mask.mask, 10, 10)) < 64,
              "a fill queued after the mask pick lands on the mask")
        check((composite(30, 30)?[3] ?? 255) < 64,
              "the mask fill hid the layer composite-wide")

        // Mask to Selection: a black mask selects nothing; paint a white
        // patch back and the selection follows it.
        document.maskToSelection(.replace)
        settle()
        check((try? session.selectionBounds(image: image)) == nil
                || (try? session.selectionBounds(image: image))?.isEmpty == true,
              "an empty (black) mask gives an empty selection")
        document.beginStroke(at: .init(x: 20, y: 50, pressure: 1), brush: EngineSession.Brush(size: 8, opacity: 1, red: 1, green: 1, blue: 1, pressureSize: false))
        document.continueStroke((21...28).map { .init(x: Double($0), y: 50, pressure: 1) })
        document.endStroke()
        settle()
        document.maskToSelection(.replace)
        settle()
        if let bounds = try? session.selectionBounds(image: image) {
            check(bounds.width < 40 && bounds.height < 40 && bounds.contains(CGPoint(x: 24, y: 50)),
                  "Mask to Selection outlines the mask's white patch (\(bounds))")
        } else {
            check(false, "Mask to Selection on a white patch selects it")
        }
        document.select(.none)
        settle()

        // Refusals while the mask is the target: moves, transforms and
        // path strokes have no mask backend and must not touch pixels.
        let markBefore = luminance(composite(15, 10))
        document.moveActiveLayer(by: CGSize(width: 4, height: 4))
        document.transformLayer(layer, matrix: CGAffineTransform(scaleX: 2, y: 2),
                                interpolation: .linear)
        document.strokePath(1, settings: EngineSession.LineSettings())
        settle()
        check(errors.contains { $0.contains("mask") },
              "move, transform and path stroke refuse on a mask target (\(errors.suffix(3))")
        check(luminance(composite(15, 10)) == markBefore,
              "the refused edits left the layer's pixels alone")

        // Apply bakes the mask into the layer: only the white patch
        // survives, and the mask is gone.
        document.applyMask()
        settle()
        check(document.maskStates[layer] == nil
                && document.layers.first(where: { $0.id == layer })?.hasMask == false,
              "Apply Mask removes the mask")
        check((composite(24, 50)?[3] ?? 0) > 200 && (composite(30, 30)?[3] ?? 255) < 64,
              "Apply Mask bakes the mask into the layer's alpha")

        // Undo and redo cover the apply.
        document.undo()
        settle()
        check(document.maskStates[layer]?.mask != 0
                && document.layers.first(where: { $0.id == layer })?.hasMask == true,
              "undo restores the mask")
        document.redo()
        settle()
        check(document.maskStates[layer] == nil, "redo re-applies the mask removal")

        // Delete discards a mask without baking it.
        document.addMask(layer, source: .black, edit: false)
        settle()
        check(document.maskStates[layer]?.mask != 0, "a second mask can be added")
        document.deleteMask()
        settle()
        check(document.maskStates[layer] == nil
                && document.layers.first(where: { $0.id == layer })?.hasMask == false,
              "Delete Mask removes the mask")

        // A group mask is editable: the group itself still refuses paint.
        controller.newLayerGroup(nil)
        settle()
        guard let group = document.layers.first(where: { $0.kind == .group }) else {
            check(false, "a group exists for the group-mask checks")
            return
        }
        document.moveLayer(layer, toParent: group.id, atIndex: 0)
        settle()
        document.addMask(group.id, source: .white, edit: true)
        settle()
        guard let groupMask = document.maskStates[group.id], groupMask.editing else {
            check(false, "a group can carry an editing mask")
            return
        }
        check(document.activeDrawable == groupMask.mask,
              "the group's mask is the active drawable while editing")
        document.beginStroke(at: .init(x: 30, y: 30, pressure: 1), brush: black)
        document.endStroke()
        settle()
        check(luminance(thumbPixel(groupMask.mask, 15, 15)) < 64,
              "painting lands on the group's mask")
        document.selectLayer(layer)
        settle()
        check(!document.isMaskTargetActive, "picking the layer leaves mask editing")

        // A stale EDITING flag on one layer cannot hijack another's
        // target: editing layer A's mask then picking layer B clears it.
        document.addMask(layer, source: .white, edit: true)
        settle()
        check(document.maskStates[layer]?.editing == true,
              "Add Mask with edit starts mask editing on the nested layer")
        document.selectLayer(group.id)
        settle()
        check(document.activeLayer == group.id && !document.isMaskTargetActive
                && document.maskStates[layer]?.editing == false,
              "picking another layer clears the previous mask's edit target")
        document.editMask(layer)
        settle()
        check(document.maskStates[layer]?.editing == true && document.isMaskTargetActive,
              "the mask thumbnail pick restores the mask target")

        // Let the first pick complete while the second remains queued.
        // Its old result must not redirect input accepted for the newer pick.
        let targetGate = DispatchSemaphore(value: 0)
        document.editMask(layer)
        document.inputQueue.async { targetGate.wait() }
        document.selectLayer(layer)
        spin(0.1)
        check(document.activeDrawable == layer,
              "an older mask-pick completion preserves the newer layer target")
        targetGate.signal()
        settle()
        let reloadGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { reloadGate.wait() }
        document.editMask(layer)
        try document.reload()
        check(document.activeDrawable == document.maskStates[layer]?.mask,
              "a reload preserves an accepted mask pick still waiting on the input queue")
        reloadGate.signal()
        settle()

        let savedTool = ToolState.shared.current
        let savedSource = ToolState.shared.cloneSource
        ToolState.shared.select(.clone)
        if let window = controller.window,
           let sourceClick = NSEvent.mouseEvent(with: .leftMouseDown,
                location: controller.canvas.convert(CGPoint(x: 12 * controller.canvas.scale,
                                                             y: 12 * controller.canvas.scale), to: nil),
                modifierFlags: [.option], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            controller.canvas.mouseDown(with: sourceClick)
            check(ToolState.shared.cloneSource?.drawable == document.activeDrawable,
                  "Option-click Clone samples the selected mask instead of its layer")
        } else { check(false, "the mask clone-source check receives a pointer event") }
        ToolState.shared.cloneSource = savedSource
        ToolState.shared.select(savedTool)

        // A filter preview begins on the mask drawable.
        var preview: Result<ImageDocument.FilterPreviewStart, Error>?
        document.beginFilterPreview(operation: GaussianBlurPanel.operation, properties: []) {
            preview = $0
        }
        settle()
        if case .success(let start) = preview {
            document.finishFilter(start.filter, commit: false) { _ in }
            settle()
            check(true, "a filter preview begins on the mask drawable")
        } else {
            check(false, "a filter preview begins on the mask drawable: \(String(describing: preview))")
        }

        document.select(.none)
        settle()
        let layerBeforeFailedPick = try session.drawableThumbnail(layer, image: image, maxSize: 32)?
            .dataProvider?.data as Data?
        document.run { session, image in
            try session.applyLayerMask(layer, image: image, mode: .discard)
        }
        document.editMask(layer)
        document.fill(at: .zero, mode: .selection, color: .magenta, threshold: 0, sampleMerged: false)
        settle()
        let layerAfterFailedPick = try session.drawableThumbnail(layer, image: image, maxSize: 32)?
            .dataProvider?.data as Data?
        check(layerBeforeFailedPick != nil && layerBeforeFailedPick == layerAfterFailedPick,
              "a queued mask pick that becomes invalid refuses the following fill instead of painting its layer")
        check(document.activeDrawable == nil,
              "a failed mask pick asks for a fresh target instead of silently falling back to the layer")
        document.selectLayer(layer)
        settle()
        check(document.activeDrawable == layer, "picking a layer recovers from a refused mask target")

        // The refused target also heals through a fresh creation: the
        // engine selects the layer it makes, and the completion lifts
        // the rejection — no pick needed. Re-arm the failed pick first.
        document.addMask(layer, source: .white, edit: false)
        settle()
        check(document.maskStates[layer]?.mask != 0,
              "the layer carries a mask again for the refused-pick recovery checks")
        document.run { session, image in
            try session.applyLayerMask(layer, image: image, mode: .discard)
        }
        document.editMask(layer)
        settle()
        check(document.activeDrawable == nil,
              "a second queued mask pick that becomes invalid refuses the target too")
        // A command that fails while the target is refused must not
        // reopen it: the merge has nothing below it inside the group.
        document.layerCommand(.mergeDown)
        settle()
        document.fill(at: .zero, mode: .selection, color: .magenta, threshold: 0, sampleMerged: false)
        settle()
        check(document.activeDrawable == nil && errors.contains { $0.contains("merge") },
              "a failed target command does not reopen the refused target "
                + "(drawable \(document.activeDrawable ?? -1), errors \(errors.suffix(3)))")
        document.layerCommand(.new)
        settle()
        guard let recovered = document.activeLayer, recovered != layer else {
            check(false, "a layer creation lands after the refused pick")
            return
        }
        check(document.activeDrawable == recovered,
              "a successful creation recovers the refused target without another pick")
        document.fill(at: .zero, mode: .selection, color: .black, threshold: 0, sampleMerged: false)
        document.beginStroke(at: .init(x: 56, y: 56, pressure: 1), brush: black)
        document.continueStroke([.init(x: 58, y: 56, pressure: 1)])
        document.endStroke()
        settle()
        check(luminance(thumbPixel(recovered, 28, 28)) < 64 && (thumbPixel(recovered, 28, 28)?[3] ?? 0) > 200,
              "fills and strokes reach the recovered target "
                + "(new layer pixel \(thumbPixel(recovered, 28, 28) ?? []))")

        let thumbnailGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { thumbnailGate.wait() }
        let palette = LayersPaletteController()
        _ = palette.view
        palette.retarget(to: document)
        if let outline = descendant(of: palette.view, as: NSOutlineView.self),
           let item = outline.item(atRow: 0) {
            _ = palette.outlineView(outline, viewFor: nil, item: item)
            check(document.pendingWork > 0,
                  "thumbnail reads count as document work until the image is safe to close")
        } else { check(false, "the thumbnail lifetime check has a layer row") }
        palette.retarget(to: nil)
        thumbnailGate.signal()
        settle()

        controller.window?.orderOut(nil)
    }

    /// A command whose result becomes or replaces the paint target — a new
    /// or duplicated layer, a pasted or text layer, an editing mask —
    /// learns its drawable id only when its queued job finishes. Edits
    /// accepted meanwhile must be refused instead of capturing the
    /// drawable the command is about to replace, and a completion must
    /// never enqueue another native select that could land inside a
    /// clipboard cut's read/clear pair.
    private static func exerciseTargetCommands(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 64, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Target Commands")
        documents.items.append(document)
        defer {
            document.onWillChangeLayers = nil
            documents.items.removeAll { $0 === document }
            document.closeImageWhenDrained()
        }
        var errors: [String] = []
        document.onError = { errors.append($0) }
        func settle() {
            document.inputQueue.sync {}
            spin()
        }
        func composite(_ x: Int, _ y: Int) -> [UInt8]? { pixel(session, image, x: x, y: y) }
        func thumbPixel(_ drawable: Int32, _ x: Int, _ y: Int) -> [UInt8]? {
            guard let cg = try? session.drawableThumbnail(drawable, image: image, maxSize: 32),
                  let data = cg.dataProvider?.data as Data? else { return nil }
            let offset = (y * cg.width + x) * 4
            guard offset + 4 <= data.count else { return nil }
            return Array(data[offset..<offset + 4])
        }
        func luminance(_ rgba: [UInt8]?) -> Int {
            guard let rgba else { return -1 }
            return (Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2])) / 3
        }
        let black = EngineSession.Brush(size: 8, opacity: 1, red: 0, green: 0, blue: 0, pressureSize: false)
        guard let layer = document.activeLayer else {
            check(false, "a new image has a layer for the target-command checks")
            return
        }

        // A mask added with Edit Mask Immediately replaces the paint
        // target with a drawable whose id is unknown until the job lands.
        // A stroke or fill accepted meanwhile is refused rather than
        // painted on the layer the mask is about to cover.
        let maskGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { maskGate.wait() }
        document.addMask(layer, source: .white, edit: true)
        document.beginStroke(at: .init(x: 40, y: 40, pressure: 1), brush: black)
        document.continueStroke((41...46).map { .init(x: Double($0), y: 40, pressure: 1) })
        document.endStroke()
        document.fill(at: .zero, mode: .selection, color: .black, threshold: 0, sampleMerged: false)
        maskGate.signal()
        settle()
        check(luminance(composite(43, 40)) > 200 && (composite(43, 40)?[3] ?? 0) > 200,
              "edits accepted behind a queued mask creation are refused "
                + "(composite \(composite(43, 40) ?? []))")
        check(errors.contains { $0.contains("Wait") },
              "the refused edits explain the pending target change (\(errors.last ?? "none"))")
        guard let mask = document.maskStates[layer], mask.mask != 0, mask.editing else {
            check(false, "the queued mask creation completes as the edit target")
            return
        }
        check(document.activeDrawable == mask.mask,
              "the mask becomes the active drawable once the creation lands")
        document.beginStroke(at: .init(x: 40, y: 40, pressure: 1), brush: black)
        document.continueStroke((41...46).map { .init(x: Double($0), y: 40, pressure: 1) })
        document.endStroke()
        settle()
        check(luminance(thumbPixel(mask.mask, 21, 20)) < 64,
              "a stroke accepted after the mask lands paints the mask")

        // The same unknown-target window exists for a queued layer
        // creation; an explicit stroke and an implicit fill must not
        // disagree about the target.
        let newGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { newGate.wait() }
        let countBeforeNew = document.layers.count
        document.layerCommand(.new)
        document.beginStroke(at: .init(x: 20, y: 20, pressure: 1), brush: black)
        document.continueStroke((21...24).map { .init(x: Double($0), y: 20, pressure: 1) })
        document.endStroke()
        document.fill(at: .zero, mode: .selection, color: .black, threshold: 0, sampleMerged: false)
        newGate.signal()
        settle()
        check(document.layers.count == countBeforeNew + 1 && document.activeLayer == document.layers.first?.id,
              "the queued layer creation still lands and becomes the active layer")
        if let created = document.layers.first, created.id != layer {
            check((thumbPixel(created.id, 11, 10)?[3] ?? 255) == 0,
                  "a fill accepted behind a queued layer creation is refused "
                    + "(new layer pixel \(thumbPixel(created.id, 11, 10) ?? []))")
        }
        check(luminance(thumbPixel(mask.mask, 11, 10)) > 200,
              "a stroke accepted behind a queued layer creation is refused "
                + "(mask pixel \(thumbPixel(mask.mask, 11, 10) ?? []))")

        // A known pick accepted behind the queued creation resolves the
        // target optimistically: input after it follows the pick in queue
        // order, and the pick still wins over the creation's completion.
        document.selectLayer(layer)
        settle()
        let pickGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { pickGate.wait() }
        document.layerCommand(.new)
        document.selectLayer(layer)
        document.beginStroke(at: .init(x: 56, y: 56, pressure: 1), brush: black)
        document.continueStroke((57...58).map { .init(x: Double($0), y: 56, pressure: 1) })
        document.endStroke()
        pickGate.signal()
        settle()
        check(document.activeLayer == layer && luminance(composite(57, 56)) < 64,
              "a pick accepted behind a queued creation wins and the queued stroke follows it")

        // A pick of a layer that does not exist must not reopen the gate.
        let invalidGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { invalidGate.wait() }
        document.layerCommand(.new)
        document.selectLayer(999_999)
        document.beginStroke(at: .init(x: 8, y: 8, pressure: 1), brush: black)
        document.continueStroke([.init(x: 9, y: 8, pressure: 1)])
        document.endStroke()
        invalidGate.signal()
        settle()
        check(luminance(composite(8, 8)) > 200 && (composite(8, 8)?[3] ?? 0) > 200,
              "an invalid pick does not reopen the unknown-target gate "
                + "(composite \(composite(8, 8) ?? []))")

        // Cut while a duplicate of a mask-editing layer is queued. The
        // engine's duplicate selects the copy's mask; a completion that
        // enqueued another native select could land between the cut's
        // pixel read and its deferred clear and clear the layer instead.
        let cutImage = try session.newImage(width: 64, height: 64)
        let cutDocument = try ImageDocument(session: session, image: cutImage, name: "Cut Completion")
        documents.items.append(cutDocument)
        defer {
            cutDocument.onWillChangeLayers = nil
            documents.items.removeAll { $0 === cutDocument }
            cutDocument.closeImageWhenDrained()
        }
        guard let cutLayer = cutDocument.activeLayer else {
            check(false, "the cut document has a layer")
            return
        }
        func cutThumb(_ drawable: Int32, _ x: Int, _ y: Int) -> [UInt8]? {
            guard let cg = try? session.drawableThumbnail(drawable, image: cutImage, maxSize: 32),
                  let data = cg.dataProvider?.data as Data? else { return nil }
            let offset = (y * cg.width + x) * 4
            guard offset + 4 <= data.count else { return nil }
            return Array(data[offset..<offset + 4])
        }
        func boardPixel(_ copied: ClipboardImage, _ x: Int, _ y: Int) -> Int {
            let bx = x - Int(copied.origin.x), by = y - Int(copied.origin.y)
            guard bx >= 0, by >= 0, bx < copied.width, by < copied.height else { return -1 }
            let offset = (by * copied.width + bx) * 4
            guard offset + 3 < copied.pixels.count else { return -1 }
            let px = copied.pixels
            return (Int(px[offset]) + Int(px[offset + 1]) + Int(px[offset + 2])) / 3
        }
        cutDocument.addMask(cutLayer, source: .white, edit: true)
        cutDocument.inputQueue.sync {}
        spin()
        guard cutDocument.maskStates[cutLayer]?.editing == true else {
            check(false, "the cut document's mask is editing before the race")
            return
        }
        cutDocument.beginStroke(at: .init(x: 40, y: 40, pressure: 1), brush: black)
        cutDocument.continueStroke((41...46).map { .init(x: Double($0), y: 40, pressure: 1) })
        cutDocument.endStroke()
        cutDocument.inputQueue.sync {}
        spin()
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        cutDocument.layerCommand(.duplicate)
        var cutError: Error?
        cutDocument.copyPixels(.cutLayer, background: .cyan, consume: { encoded in
            // Hold the transaction open until anything the duplicate's
            // completion queued has reached the engine; the deferred
            // clear is enqueued only after this returns.
            cutDocument.inputQueue.sync {}
            try encoded.write(to: board)
        }, completion: { cutError = $0 })
        let cutDeadline = Date().addingTimeInterval(10)
        while cutDocument.pendingWork > 0 && Date() < cutDeadline { spin() }
        cutDocument.inputQueue.sync {}
        spin()
        check(cutError == nil, "the cut transaction completes")
        guard let duplicate = cutDocument.layers.first(where: { $0.id != cutLayer }),
              let duplicateMask = cutDocument.maskStates[duplicate.id] else {
            check(false, "the duplicate and its mask exist after the race")
            return
        }
        check((try? session.layerMask(duplicate.id, image: cutImage))?.editing == true
                && (try? session.layerMask(cutLayer, image: cutImage))?.editing == true,
              "the completion cannot change native mask editing after the duplicate selected its mask "
                + "(duplicate \((try? session.layerMask(duplicate.id, image: cutImage))?.editing == true), "
                + "source \((try? session.layerMask(cutLayer, image: cutImage))?.editing == true))")
        if let cutPixels = try? ClipboardImage.read(from: board) {
            check(boardPixel(cutPixels, 43, 40) < 64,
                  "the cut copied the duplicate mask's pixels (read \(boardPixel(cutPixels, 43, 40)))")
        } else {
            check(false, "the cut wrote its copied mask to the clipboard")
        }
        check(luminance(cutThumb(duplicate.id, 21, 20)) > 200,
              "the deferred cut clear left the duplicate's layer pixels alone "
                + "(layer pixel \(cutThumb(duplicate.id, 21, 20) ?? []))")
        check(luminance(cutThumb(duplicateMask.mask, 21, 20)) > 100,
              "the deferred cut clear hit the duplicate's mask "
                + "(mask pixel \(cutThumb(duplicateMask.mask, 21, 20) ?? []))")
        check(cutDocument.activeDrawable == duplicateMask.mask,
              "the adopted target after the race is the duplicate's mask")
    }

    /// Undo, redo and an emptied text layer replace the paint target like
    /// a creation does, and the current-target layer commands must name
    /// the layer the engine selects when they run — not the one the
    /// interface captured while earlier commands were still queued.
    private static func exerciseTargetHistory(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 64, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Target History")
        documents.items.append(document)
        defer {
            document.onWillChangeLayers = nil
            documents.items.removeAll { $0 === document }
            document.closeImageWhenDrained()
        }
        var errors: [String] = []
        document.onError = { errors.append($0) }
        func settle() {
            document.inputQueue.sync {}
            spin()
        }
        func composite(_ x: Int, _ y: Int) -> [UInt8]? { pixel(session, image, x: x, y: y) }
        func thumbPixel(_ drawable: Int32, _ x: Int, _ y: Int) -> [UInt8]? {
            guard let cg = try? session.drawableThumbnail(drawable, image: image, maxSize: 32),
                  let data = cg.dataProvider?.data as Data? else { return nil }
            let offset = (y * cg.width + x) * 4
            guard offset + 4 <= data.count else { return nil }
            return Array(data[offset..<offset + 4])
        }
        func luminance(_ rgba: [UInt8]?) -> Int {
            guard let rgba else { return -1 }
            return (Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2])) / 3
        }
        let black = EngineSession.Brush(size: 8, opacity: 1, red: 0, green: 0, blue: 0, pressureSize: false)
        guard let layer = document.activeLayer else {
            check(false, "a new image has a layer for the target-history checks")
            return
        }

        // Undoing a creation moves the native selection back before the
        // interface knows; a fill accepted meanwhile is refused rather
        // than painted on the layer underneath.
        document.layerCommand(.new)
        settle()
        let undoGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { undoGate.wait() }
        document.undo()
        document.fill(at: .zero, mode: .selection, color: .black, threshold: 0, sampleMerged: false)
        undoGate.signal()
        settle()
        check(luminance(composite(4, 4)) > 200 && (composite(4, 4)?[3] ?? 0) > 200,
              "a fill accepted behind an undo is refused "
                + "(composite \(composite(4, 4) ?? []))")
        check(errors.contains { $0.contains("Wait") },
              "the refused fill explains the pending undo (\(errors.last ?? "none"))")

        // Redoing the creation replaces the target the same way: the
        // fill would land on the recreated layer the user could not see.
        let redoGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { redoGate.wait() }
        document.redo()
        document.fill(at: .zero, mode: .selection, color: .red, threshold: 0, sampleMerged: false)
        redoGate.signal()
        settle()
        check(luminance(composite(4, 4)) > 200 && (composite(4, 4)?[1] ?? 0) > 200,
              "a fill accepted behind a redo is refused "
                + "(composite \(composite(4, 4) ?? []))")

        // Undoing a mask addition drops the editing mask: the implicit
        // target reverts to the layer while the interface still reports
        // the mask.
        document.addMask(layer, source: .white, edit: true)
        settle()
        guard document.maskStates[layer]?.editing == true else {
            check(false, "the mask is editing before the undo check")
            return
        }
        let maskUndoGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { maskUndoGate.wait() }
        document.undo()
        document.fill(at: .zero, mode: .selection, color: .black, threshold: 0, sampleMerged: false)
        maskUndoGate.signal()
        settle()
        check(luminance(thumbPixel(layer, 4, 4)) > 200,
              "a fill accepted behind an undone mask addition is refused "
                + "(layer pixel \(thumbPixel(layer, 4, 4) ?? []))")

        // A Delete queued behind a creation must act on what the engine
        // selects then — the created layer — not on the id the interface
        // last saw selected. The redo's recreated layer goes first.
        document.selectLayer(layer)
        settle()
        if let extra = document.layers.first(where: { $0.id != layer })?.id {
            document.selectLayer(extra)
            settle()
            document.layerCommand(.delete)
            settle()
        }
        check(document.layers.map(\.id) == [layer],
              "the queue checks start from the original layer")
        document.beginStroke(at: .init(x: 30, y: 30, pressure: 1), brush: black)
        document.continueStroke([.init(x: 34, y: 30, pressure: 1)])
        document.endStroke()
        settle()
        check(luminance(composite(31, 30)) < 64 && (composite(31, 30)?[3] ?? 0) > 200,
              "the original layer carries a mark before the queue checks")
        let delGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { delGate.wait() }
        document.layerCommand(.new)
        document.layerCommand(.delete)
        delGate.signal()
        settle()
        check(document.layers.count == 1 && document.layers.first?.id == layer,
              "a delete queued behind a creation removes the created layer, not the original "
                + "(layers \(document.layers.map(\.id)), selected \(document.activeLayer ?? -1))")
        check(luminance(composite(31, 30)) < 64 && (composite(31, 30)?[3] ?? 0) > 200,
              "the original layer and its pixels survive the queued delete "
                + "(composite \(composite(31, 30) ?? []))")

        // A Duplicate queued behind a creation likewise copies the layer
        // the queue produced, so the original is not duplicated in its
        // place.
        let dupGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { dupGate.wait() }
        document.layerCommand(.new)
        document.layerCommand(.duplicate)
        dupGate.signal()
        settle()
        check(document.layers.count == 3 && document.layers.last?.id == layer,
              "the queued new and duplicate leave the original layer at the bottom "
                + "(layers \(document.layers.map(\.id)), selected \(document.activeLayer ?? -1))")
        if document.layers.count == 3 {
            let middle = document.layers[1].id
            check((thumbPixel(middle, 15, 15)?[3] ?? 255) < 50,
                  "the queued duplicate copies the created layer, not the original "
                    + "(middle pixel \(thumbPixel(middle, 15, 15) ?? []))")
        }

        // A group created behind a creation takes its place from the
        // layers the queue leaves — the created layer on top — not from
        // the selection the interface captured first.
        for extra in document.layers.map(\.id).filter({ $0 != layer }) {
            document.selectLayer(extra)
            settle()
            document.layerCommand(.delete)
            settle()
        }
        document.selectLayer(layer)
        settle()
        let groupGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { groupGate.wait() }
        document.layerCommand(.new)
        document.createGroup()
        groupGate.signal()
        settle()
        check(document.layers.first?.kind == .group,
              "a group queued behind a creation is placed from the post-queue selection "
                + "(layers \(document.layers.map { "\($0.id):\($0.kind)" }), selected \(document.activeLayer ?? -1))")
        document.layerCommand(.delete)
        settle()
        document.layerCommand(.delete)
        settle()
        check(document.layers.count == 1 && document.layers.first?.id == layer,
              "the queue checks return to the original layer "
                + "(layers \(document.layers.map(\.id)))")

        // Emptying a text layer removes it — the same target change the
        // text editor commits — so it queues like one.
        let fonts = (try? session.fonts()) ?? []
        var textSettings = EngineSession.TextSettings()
        textSettings.font = fonts.contains("Sans-serif") ? "Sans-serif" : (fonts.first ?? "Sans-serif")
        document.addText("Empty", settings: textSettings, at: CGPoint(x: 4, y: 40))
        settle()
        guard let textLayer = document.layers.first(where: { $0.kind == .text })?.id else {
            check(false, "a text layer exists for the emptying check")
            return
        }
        let emptyGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { emptyGate.wait() }
        document.updateText(textLayer, text: "", settings: nil)
        document.fill(at: .zero, mode: .selection, color: .black, threshold: 0, sampleMerged: false)
        emptyGate.signal()
        settle()
        check(!document.layers.contains(where: { $0.id == textLayer }),
              "an emptied text layer is removed like the text editor's commit")
        check(luminance(composite(6, 42)) > 200,
              "a fill accepted behind the emptied-text removal is refused "
                + "(composite \(composite(6, 42) ?? []))")

        // The emptied editor reaches that removal through the same flush
        // an outer command runs; both queue in order.
        let controller = DocumentWindowController(document: document)
        defer { controller.window?.orderOut(nil) }
        let canvas = controller.canvas
        let previousTool = ToolState.shared.current
        ToolState.shared.select(.text)
        ToolState.shared.textSettings = textSettings
        document.addText("Gone", settings: textSettings, at: CGPoint(x: 4, y: 50))
        settle()
        guard let goneLayer = document.layers.first(where: { $0.kind == .text })?.id,
              let bounds = document.layers.first(where: { $0.id == goneLayer })?.bounds else {
            check(false, "a second text layer exists for the flush check")
            ToolState.shared.select(previousTool)
            return
        }
        if let window = controller.window,
           let press = NSEvent.mouseEvent(with: .leftMouseDown,
                                          location: canvas.convert(CGPoint(x: bounds.midX * canvas.scale,
                                                                           y: bounds.midY * canvas.scale), to: nil),
                                          modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                          context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
            canvas.mouseDown(with: press)
        }
        let editor = canvas.tools.textEditor
        check(editor?.textLayer == goneLayer, "the Text tool opens the layer about to be emptied")
        editor?.string = ""
        let flushGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { flushGate.wait() }
        document.layerCommand(.new)
        flushGate.signal()
        settle()
        check(!document.layers.contains(where: { $0.id == goneLayer }) && canvas.tools.textEditor == nil,
              "an emptied editor commits its removal through the outer command's flush")
        ToolState.shared.select(previousTool)
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

    static func buttons(in view: NSView) -> [NSButton] {
        ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons)
    }

    static func descendant<View: NSView>(of view: NSView, as type: View.Type,
                                                   matching predicate: (View) -> Bool = { _ in true }) -> View? {
        if let match = view as? View, predicate(match) { return match }
        for child in view.subviews {
            if let match = descendant(of: child, as: type, matching: predicate) { return match }
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
            check(false, "a fill and a stroke list three history states (cached \(document.history?.rows.count ?? -1), native undo \(String(describing: try? session.undoInfo(image))), pending \(document.pendingWork), activity \(EngineActivity.shared.label ?? "none"), errors \(messages))")
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

    /// The Path tool's multi-anchor selection, driven through the canvas:
    /// Shift-click toggles anchors across subpaths without an edit or an
    /// undo, a group drag moves every selected anchor and its handles from
    /// the press baseline in one queued update on release, wandering motion
    /// does not drift, toggling off without a drag mutates nothing, Delete
    /// removes the whole set in one undo step that undo restores exactly,
    /// and an active-path switch clears the set and refuses a stale drag.
    /// Every shape oracle reads the engine (`session.path`), never the
    /// document's cached working state.
    private static func exercisePathAnchors(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 200, height: 120)
        let document = try ImageDocument(session: session, image: image, name: "PathAnchors")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        let canvas = controller.canvas
        func settle() {
            document.inputQueue.sync {}
            spin()
        }
        guard let window = controller.window else { return check(false, "the PathAnchors document has a window") }
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
        func click(_ point: CGPoint, flags: NSEvent.ModifierFlags = []) {
            guard let down = event(.leftMouseDown, at: point, flags: flags),
                  let up = event(.leftMouseUp, at: point, flags: flags) else { return }
            canvas.mouseDown(with: down)
            canvas.mouseUp(with: up)
            settle()
        }
        func key(_ code: UInt16) {
            let characters = code == 51 ? "\u{7F}" : code == 53 ? "\u{1B}" : "\r"
            if let press = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) {
                canvas.keyDown(with: press)
            }
        }
        let pathTool = canvas.tools.pathTool
        func shape(_ path: Int32) -> VectorPath? { try? session.path(path, image: image) }

        let previousTool = ToolState.shared.current
        defer { ToolState.shared.select(previousTool) }
        ToolState.shared.select(.path)

        // Two open subpaths: (20,20)-(100,20) and (20,90)-(100,90).
        drag([CGPoint(x: 20, y: 20)])
        drag([CGPoint(x: 100, y: 20)])
        click(CGPoint(x: 20, y: 90), flags: .shift)
        drag([CGPoint(x: 100, y: 90)])
        key(36)
        guard let path = document.activePath else { return check(false, "the drawn path is active") }
        let a01 = VectorPath.AnchorIndex(subpath: 0, anchor: 1)
        let a10 = VectorPath.AnchorIndex(subpath: 1, anchor: 0)
        let built = shape(path)
        check(built?.subpaths.count == 2
                && built?.subpaths[0].anchors.map(\.point) == [CGPoint(x: 20, y: 20), CGPoint(x: 100, y: 20)]
                && built?.subpaths[1].anchors.map(\.point) == [CGPoint(x: 20, y: 90), CGPoint(x: 100, y: 90)]
                && built?.subpaths.allSatisfy({ !$0.isClosed }) == true,
              "two open subpaths were drawn")
        check(pathTool.selectedAnchors.isEmpty, "Return ended drawing and cleared the selection")

        // Select two anchors across subpaths; the Shift-click neither edits
        // the path nor pushes an undo.
        let undoBase = document.undoInfo.undoCount
        click(CGPoint(x: 100, y: 20))
        check(pathTool.selectedAnchors == [a01], "a normal click selects one anchor")
        click(CGPoint(x: 20, y: 90), flags: .shift)
        check(pathTool.selectedAnchors == [a01, a10], "Shift-click toggles in an anchor of another subpath")
        check(document.undoInfo.undoCount == undoBase && shape(path) == built,
              "Shift-click toggling neither edits the path nor pushes an undo")

        // Option-drag pulls handles on a single-selected anchor.
        let undoHandles = document.undoInfo.undoCount
        drag([CGPoint(x: 100, y: 20), CGPoint(x: 120, y: 25)], flags: .option)
        check(pathTool.selectedAnchors == [a01], "Option-drag selects only the pulled anchor")
        check(shape(path)?.subpaths[0].anchors[1].handleOut == CGPoint(x: 120, y: 25)
                && shape(path)?.subpaths[0].anchors[1].handleIn == CGPoint(x: 80, y: 15),
              "Option-drag pulled the anchor's handles out")
        check(document.undoInfo.undoCount == undoHandles + 1, "pulling handles is one undo step")
        click(CGPoint(x: 20, y: 90), flags: .shift)
        check(pathTool.selectedAnchors == [a01, a10], "Shift-click re-adds the second anchor")

        // A group drag moves all selected anchors and the handles together,
        // as one queued update and one undo on release, computed from the
        // press baseline: the wandering intermediate points must not
        // accumulate.
        let undoDrag = document.undoInfo.undoCount
        drag([CGPoint(x: 100, y: 20), CGPoint(x: 140, y: 60), CGPoint(x: 105, y: 25), CGPoint(x: 130, y: 40)])
        let dragged = shape(path)
        check(dragged?.subpaths[0].anchors[1].point == CGPoint(x: 130, y: 40)
                && dragged?.subpaths[1].anchors[0].point == CGPoint(x: 50, y: 110),
              "the group drag moved both selected anchors by the final delta only")
        check(dragged?.subpaths[0].anchors[1].handleOut == CGPoint(x: 150, y: 45)
                && dragged?.subpaths[0].anchors[1].handleIn == CGPoint(x: 110, y: 35),
              "the selected anchor's handles moved with it")
        check(dragged?.subpaths[0].anchors[0].point == CGPoint(x: 20, y: 20)
                && dragged?.subpaths[1].anchors[1].point == CGPoint(x: 100, y: 90),
              "unselected anchors stayed put")
        check(document.undoInfo.undoCount == undoDrag + 1,
              "the group drag is one queued path update and one undo on release")

        // A drag released back at its press point changes nothing.
        let undoStill = document.undoInfo.undoCount
        drag([CGPoint(x: 130, y: 40), CGPoint(x: 180, y: 90), CGPoint(x: 130, y: 40)])
        check(document.undoInfo.undoCount == undoStill && shape(path) == dragged,
              "a drag released at its press baseline neither drifts nor pushes an undo")

        // Shift-click toggles anchors off without any mutation or undo.
        click(CGPoint(x: 130, y: 40), flags: .shift)
        check(pathTool.selectedAnchors == [a10], "Shift-click toggled the anchor out of the set")
        check(document.undoInfo.undoCount == undoStill && shape(path) == dragged,
              "toggling off without a drag edits nothing and pushes no undo")
        click(CGPoint(x: 50, y: 110), flags: .shift)
        check(pathTool.selectedAnchors.isEmpty, "Shift-click toggled the other anchor off too")

        // Switching the active path clears the selected set.
        click(CGPoint(x: 130, y: 40))
        check(pathTool.selectedAnchors == [a01], "a normal click re-selects the single anchor")
        guard let other = document.addPath(VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: 5, y: 5))])])) else {
            return check(false, "a second path was added")
        }
        settle()
        key(53)
        check(document.activePath == other && pathTool.selectedAnchors.isEmpty,
              "switching the active path clears the selected set")

        // A drag whose path stops being active mid-drag is refused on
        // release rather than written over the switch.
        document.selectPath(path)
        settle()
        click(CGPoint(x: 130, y: 40))
        check(pathTool.selectedAnchors == [a01], "the anchor is selected again on the original path")
        let beforeStale = shape(path)
        if let down = event(.leftMouseDown, at: CGPoint(x: 130, y: 40)),
           let moved = event(.leftMouseDragged, at: CGPoint(x: 160, y: 60)),
           let up = event(.leftMouseUp, at: CGPoint(x: 160, y: 60)) {
            canvas.mouseDown(with: down)
            canvas.mouseDragged(with: moved)
            document.selectPath(other)
            settle()
            canvas.mouseUp(with: up)
            settle()
        }
        check(shape(path) == beforeStale,
              "a drag whose active path switched mid-drag is refused, not applied")

        // Delete removes the whole selected set in one undo step, and undo
        // restores the exact engine shape.
        document.selectPath(path)
        settle()
        click(CGPoint(x: 130, y: 40))
        click(CGPoint(x: 50, y: 110), flags: .shift)
        check(pathTool.selectedAnchors == [a01, a10], "two anchors across subpaths are selected again")
        let beforeDelete = shape(path)
        let undoDelete = document.undoInfo.undoCount
        key(51)
        settle()
        let deleted = shape(path)
        check(deleted?.subpaths.count == 2
                && deleted?.subpaths[0].anchors.map(\.point) == [CGPoint(x: 20, y: 20)]
                && deleted?.subpaths[1].anchors.map(\.point) == [CGPoint(x: 100, y: 90)],
              "Delete removed both selected anchors, one per subpath")
        check(document.undoInfo.undoCount == undoDelete + 1, "the batch delete is one undo step")
        check(pathTool.selectedAnchors.isEmpty, "Delete cleared the selection")
        document.undo()
        settle()
        check(shape(path) == beforeDelete, "undo restores the exact pre-delete engine shape")
        document.redo()
        settle()
        check(shape(path) == deleted, "redo reapplies the batch delete exactly")
    }

    /// Fill Path and To Vector Layer over the appended `path_fill` and
    /// `path_to_vector_layer` facade calls: real pixels and the fill color,
    /// selection clipping, one undo step each, the vector layer's kind and
    /// its re-render after a path edit, the XCF round trip, and the
    /// unsupported (pre-3.2), missing, busy and closed guards.
    private static func exercisePathFillAndVector(_ session: EngineSession, work: URL,
                                                  documents: DocumentList) throws {
        let image = try session.newImage(width: 200, height: 120)
        let document = try ImageDocument(session: session, image: image, name: "PathFillVector")
        documents.items.append(document)
        defer {
            documents.items.removeAll { $0 === document }
            document.closeImageWhenDrained()
        }
        var errors: [String] = []
        document.onError = { errors.append($0) }
        func settle() {
            document.inputQueue.sync {}
            spin()
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func composite(_ x: Int, _ y: Int) -> [UInt8]? { pixel(session, image, x: x, y: y) }
        func luminance(_ rgba: [UInt8]?) -> Int {
            guard let rgba else { return -1 }
            return (Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2])) / 3
        }
        func thumbPixel(_ drawable: Int32, _ x: Int, _ y: Int) -> [UInt8]? {
            guard let cg = try? session.drawableThumbnail(drawable, image: image, maxSize: 32),
                  let data = cg.dataProvider?.data as Data? else { return nil }
            let offset = (y * cg.width + x) * 4
            guard offset + 4 <= data.count else { return nil }
            return Array(data[offset..<offset + 4])
        }
        let rect = VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: 20, y: 20)), .init(CGPoint(x: 100, y: 20)),
                                                         .init(CGPoint(x: 100, y: 90)), .init(CGPoint(x: 20, y: 90))],
                                               isClosed: true)])
        guard let path = document.addPath(rect) else {
            return check(false, "a path can be added for the fill and vector checks")
        }
        settle()
        guard let layer = document.activeLayer else {
            return check(false, "the new image has a layer to fill on")
        }

        // The palette's new commands: menu items, enablement and the
        // honest tooltip for the vector layer's default style.
        let paths = PathsPaletteController()
        paths.retarget(to: document)
        let fillItem = paths.paletteMenu?.items.first { $0.title == "Fill Path" }
        let vectorItem = paths.paletteMenu?.items.first { $0.title == "To Vector Layer" }
        check(fillItem.map { paths.validateMenuItem($0) } == true,
              "the palette menu enables Fill Path with an active path")
        check(vectorItem.map { paths.validateMenuItem($0) } == (document.supportsVectorLayers != false),
              "the palette menu enables To Vector Layer only where the engine has vector layers")
        check(vectorItem?.toolTip?.contains("white fill") == true,
              "To Vector Layer's tooltip states the engine's default white fill, black stroke")

        // Missing ids at the facade: NOT_FOUND, nothing mutated.
        if case .failure(let error) = Result(catching: { try session.fillPath(9999, image: image, drawable: layer,
                                                                             settings: .init(color: .red)) }) {
            check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_NOT_FOUND.rawValue),
                  "path_fill of an unknown path reports NOT_FOUND (\(error))")
        } else {
            check(false, "path_fill of an unknown path must fail")
        }
        if case .failure(let error) = Result(catching: { try session.toVectorLayer(9999, image: image, name: nil) }) {
            check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_NOT_FOUND.rawValue),
                  "path_to_vector_layer of an unknown path reports NOT_FOUND (\(error))")
        } else {
            check(false, "path_to_vector_layer of an unknown path must fail")
        }

        // Busy guard: while a plug-in runs on the document, both commands
        // are refused with an error and change nothing.
        let running = EngineSession.Procedure(name: "smoke-busy", label: "Busy", menuPath: "", blurb: "",
                                              isSensitive: true)
        PlugInCommands.willRun(running, on: document)
        let undoBeforeBusy = document.undoInfo.undoCount
        let busyErrorCount = errors.count
        document.fillPath(path, settings: .init(color: .red))
        document.toVectorLayer(path)
        settle()
        check(errors.count > busyErrorCount && errors.suffix(2).allSatisfy { $0.contains("first") },
              "fill and to-vector refuse while a plug-in runs (\(errors.suffix(2)))")
        check(document.undoInfo.undoCount == undoBeforeBusy && !document.layers.contains { $0.kind == .vector },
              "the refused commands changed nothing")
        PlugInCommands.didRun(running, outcome: nil)

        // Real pixels: the fill color lands inside the path only, as one
        // undo step ordered on the input queue.
        let undoBefore = document.undoInfo.undoCount
        document.fillPath(path, settings: EngineSession.PathFillSettings(color: .red, opacity: 1, antialias: true))
        settle()
        check((composite(60, 50)?[0] ?? 0) > 200 && (composite(60, 50)?[1] ?? 255) < 64,
              "Fill Path fills the path's area in the fill color")
        check((composite(150, 100)?[0] ?? 0) > 200, "the area outside the path is untouched")
        check(document.undoInfo.undoCount == undoBefore + 1, "Fill Path is one undo step")

        // Selection clipping: a fill inside a smaller selection stays
        // inside it; undo takes both fills back, one step each.
        try session.select(.rectangle(CGRect(x: 30, y: 30, width: 20, height: 20)), image: image)
        document.fillPath(path, settings: .init(color: .blue))
        settle()
        check((composite(40, 40)?[2] ?? 0) > 200 && (composite(40, 40)?[0] ?? 255) < 64,
              "the fill lands inside the selection")
        check((composite(80, 80)?[0] ?? 0) > 200 && (composite(80, 80)?[2] ?? 255) < 64,
              "the fill stays clipped to the selection")
        try session.select(.none, image: image)
        // Selection changes also occupy history entries. Return to the
        // captured position, rather than assuming two undos remove fills.
        var traversed = 0
        while document.undoInfo.undoCount > undoBefore && traversed < 8 {
            document.undo()
            settle()
            traversed += 1
        }
        check(document.undoInfo.undoCount == undoBefore &&
                composite(60, 50)?.prefix(3).allSatisfy { $0 > 240 } == true,
              "undo restores the white pixels and selection from before both fills")

        // Commit a value through the real Tool Options control, then use
        // the palette action. This verifies the controls affect pixels.
        let state = ToolState.shared
        let savedTool = state.current, savedColor = state.foreground
        let savedOpacity = state.pathFillOpacity, savedAntialias = state.pathFillAntialias
        defer {
            state.foreground = savedColor
            state.pathFillOpacity = savedOpacity
            state.pathFillAntialias = savedAntialias
            state.select(savedTool)
        }
        state.select(.path)
        state.foreground = .red
        let options = ToolOptionsPaletteController()
        let opacity = options.view.subviews.compactMap { $0 as? ClassicValueSlider }.last
        let field = opacity.flatMap { descendant(of: $0, as: NSTextField.self, matching: { $0.isEditable }) }
        field?.stringValue = "50"
        if let field, let action = field.action { NSApp.sendAction(action, to: field.target, from: field) }
        let antialias = options.view.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Antialias fill" }
        if antialias?.state == .on { antialias?.performClick(nil) }
        check(state.pathFillOpacity == 0.5 && !state.pathFillAntialias,
              "the Path options commit fill opacity and antialias choices")
        if let item = fillItem, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        settle()
        let translucent = composite(60, 50) ?? []
        check(translucent.count == 4 && translucent[0] > 240 && (175...200).contains(Int(translucent[1])),
              "the palette fill uses the options' 50 percent foreground opacity (\(translucent))")
        document.undo()
        settle()
        state.pathFillOpacity = savedOpacity
        state.pathFillAntialias = savedAntialias

        // A saved channel is a distinct drawable; filling it must leave
        // layer pixels unchanged and keep the channel's outside area.
        try session.select(.all, image: image)
        let channel = try session.channelFromSelection(image, name: "Path fill target")
        try session.select(.none, image: image)
        try document.reload()
        document.fillPath(path, settings: .init(color: .black))
        settle()
        check(document.activeDrawable == channel && luminance(thumbPixel(channel, 9, 9)) < 64
                && luminance(thumbPixel(channel, 0, 0)) > 200 && luminance(thumbPixel(layer, 9, 9)) > 200,
              "Fill Path changes the saved channel inside the path and preserves layer pixels")
        document.selectLayer(layer)
        settle()
        document.deleteChannel(channel)
        settle()

        // A group as the target is refused, not silently filled.
        document.createGroup()
        settle()
        guard let group = document.layers.first(where: { $0.kind == .group }) else {
            return check(false, "a group exists for the fill-refusal check")
        }
        document.selectLayer(group.id)
        settle()
        let groupErrorCount = errors.count
        document.fillPath(path, settings: .init(color: .red))
        settle()
        check(errors.count > groupErrorCount && errors.last?.contains("group") == true,
              "filling onto a group is refused with an error (\(errors.last ?? "none"))")
        check((composite(60, 50)?[0] ?? 0) > 200, "the refused group fill changed no pixels")

        // A pixel-locked target is refused the same way.
        document.selectLayer(layer)
        settle()
        document.setLayerLocks(layer, .pixels, to: true)
        settle()
        let lockErrorCount = errors.count
        document.fillPath(path, settings: .init(color: .red))
        settle()
        check(errors.count > lockErrorCount && errors.last?.contains("Unlock") == true,
              "a pixel-locked target refuses the fill with an error (\(errors.last ?? "none"))")
        check((composite(60, 50)?[0] ?? 0) > 200, "the refused locked fill changed no pixels")
        document.setLayerLocks(layer, .pixels, to: false)
        settle()

        // A mask is a supported fill target: the fill lands on the mask.
        document.addMask(layer, source: .white, edit: true)
        settle()
        guard let mask = document.maskStates[layer]?.mask, mask != 0, document.isMaskTargetActive else {
            return check(false, "the mask target is active for the mask-fill check")
        }
        document.fillPath(path, settings: .init(color: .black))
        settle()
        // The mask's thumbnail is scaled to 32 px wide, so (9, 9) is image
        // (60, 50) — inside the path — and (0, 0) is outside it.
        check(luminance(thumbPixel(mask, 9, 9)) < 64, "Fill Path lands on the mask while mask editing is on")
        check(luminance(thumbPixel(mask, 0, 0)) > 200, "the mask fill stays inside the path")
        document.selectLayer(layer)
        settle()
        document.deleteMask()
        settle()
        check(document.maskStates[layer] == nil, "the mask is removed again before the vector checks")

        // To Vector Layer: fill red first so the vector layer's default
        // white fill is visible over the filled area.
        document.fillPath(path, settings: .init(color: .red))
        settle()
        check((composite(60, 50)?[0] ?? 0) > 200, "the path area is red before the conversion")
        let undoBeforeVector = document.undoInfo.undoCount
        let layersBeforeVector = document.layers.count
        document.toVectorLayer(path, name: "Outline vector")
        settle()
        if let vector = document.layers.first(where: { $0.kind == .vector }) {
            check(document.supportsVectorLayers != false, "a vector layer appears only where the engine has them")
            check(document.layers.count == layersBeforeVector + 1, "To Vector Layer adds exactly one layer")
            check(vector.isSelected && document.activeLayer == vector.id,
                  "the new vector layer is selected through the authoritative reload")
            check(vector.name == "Outline vector", "the explicit name survives the native refresh")
            check(document.undoInfo.undoCount == undoBeforeVector + 1, "To Vector Layer is one undo step")
            check(luminance(composite(60, 50)) > 200,
                  "the vector layer renders with the engine's default white fill over the red area")

            // Editing the path re-renders the vector layer: shrink the
            // path and the area it no longer covers shows the red again.
            let smaller = VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: 60, y: 50)), .init(CGPoint(x: 90, y: 50)),
                                                                .init(CGPoint(x: 90, y: 80)), .init(CGPoint(x: 60, y: 80))],
                                                      isClosed: true)])
            document.updatePath(path, to: smaller)
            settle()
            check((composite(30, 30)?[0] ?? 0) > 200 && (composite(30, 30)?[1] ?? 255) < 64,
                  "editing the path after the conversion re-renders the vector layer")
            check(document.layers.contains { $0.kind == .vector && $0.id == vector.id },
                  "the layer stays a genuine vector layer after the path edit")

            // XCF round trip: the vector layer and the path survive save
            // and reopen as structured content, and the document's target
            // reconciles to the vector layer after the save's reload.
            let xcf = work.appendingPathComponent("path-vector.xcf")
            var saved = false
            document.saveCopy(to: xcf) { saved = $0 == nil }
            wait { saved && document.pendingWork == 0 }
            check(saved, "the vector-layer image saves a copy")
            let reopened = try session.openImage(path: xcf.path)
            check(try session.layers(reopened).contains { $0.kind == .vector },
                  "the saved copy keeps the vector layer as structured content")
            check((try? session.paths(reopened))?.isEmpty == false, "the path survives the XCF round trip")
            try session.closeImage(reopened)
            check(document.activeLayer == document.layers.first(where: { $0.kind == .vector })?.id,
                  "the target reconciles to the vector layer after the save reload")
        } else {
            check(document.supportsVectorLayers == false,
                  "To Vector Layer adds nothing only on an engine without vector layers")
            if case .failure(let error) = Result(catching: { try session.toVectorLayer(path, image: image, name: nil) }) {
                check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue),
                      "path_to_vector_layer on a pre-3.2 engine reports UNSUPPORTED (\(error))")
            } else {
                check(false, "path_to_vector_layer on a pre-3.2 engine must not succeed")
            }
            let vectorErrorCount = errors.count
            document.toVectorLayer(path)
            settle()
            check(errors.count > vectorErrorCount && errors.last?.contains("3.2") == true,
                  "the document reports the honest 3.2 requirement (\(errors.last ?? "none"))")
            check(document.acceptsEdits, "the document edits again after the unsupported To Vector Layer")
        }

        // Closed guard: a closing document refuses both commands with the
        // closed error rather than queueing onto a dying image.
        let closingImage = try session.newImage(width: 32, height: 32)
        let closing = try ImageDocument(session: session, image: closingImage, name: "ClosingPaths")
        documents.items.append(closing)
        closing.onError = { errors.append($0) }
        closing.closeImageWhenDrained()
        wait { closing.pendingWork == 0 }
        let closedErrorCount = errors.count
        closing.fillPath(path, settings: .init(color: .red))
        closing.toVectorLayer(path)
        settle()
        check(errors.count > closedErrorCount
                && errors.suffix(2).allSatisfy { $0.contains("already closed") },
              "a closing document refuses fill and to-vector (\(errors.suffix(2)))")
        documents.items.removeAll { $0 === closing }
    }

    /// Layer ▸ Vector Style…: the native style sheet of a genuine vector
    /// layer — the menu gate from cached state only, the off-main read
    /// seeding the sheet, cancel and no-op changing nothing, an
    /// out-of-range width refused, real fill and stroke pixels as one undo
    /// step, the XCF round trip of the style, a busy engine acquired after
    /// the sheet opened, and a captured target deleted while it was up.
    private static func exerciseVectorStyleForm(_ session: EngineSession, work: URL,
                                                documents: DocumentList) throws {
        // Before GIMP 3.2 there is no vector layer to style; the facade's
        // UNSUPPORTED answers are covered by exercisePathFillAndVector.
        guard session.supportsVectorLayers != false else { return }
        let image = try session.newImage(width: 120, height: 80)
        let document = try ImageDocument(session: session, image: image, name: "VectorStyle")
        documents.items.append(document)
        defer {
            documents.items.removeAll { $0 === document }
            document.closeImageWhenDrained()
        }
        var errors: [String] = []
        func settle() { document.inputQueue.sync {}; spin() }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func composite(_ x: Int, _ y: Int) -> [UInt8]? { pixel(session, image, x: x, y: y) }
        func views<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            return (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, as: type) }
        }

        let rect = VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: 20, y: 20)), .init(CGPoint(x: 100, y: 20)),
                                                         .init(CGPoint(x: 100, y: 60)), .init(CGPoint(x: 20, y: 60))],
                                               isClosed: true)])
        guard let path = document.addPath(rect) else {
            return check(false, "a path can be added for the style checks")
        }
        settle()
        document.toVectorLayer(path, name: "Style vector")
        settle()
        guard let vector = document.layers.first(where: { $0.kind == .vector }) else {
            return check(false, "a genuine vector layer exists for the style checks")
        }

        let controller = DocumentWindowController(document: document)
        document.onError = { errors.append($0) }
        controller.showWindow(nil)
        defer {
            if let attached = controller.window?.attachedSheet {
                controller.window?.endSheet(attached, returnCode: .alertSecondButtonReturn)
            }
            controller.window?.close()
        }
        let item = NSMenuItem(title: "Vector Style…",
                              action: #selector(DocumentWindowController.vectorStyle(_:)), keyEquivalent: "")
        func sheet() -> NSWindow? { controller.window?.attachedSheet }
        func finish(_ response: NSApplication.ModalResponse) {
            if let attached = sheet() { controller.window?.endSheet(attached, returnCode: response) }
            spin(0.1)
        }
        func applyButton() -> NSButton? {
            buttons(in: sheet()?.contentView ?? NSView()).first { $0.title == "Apply" }
        }
        func seeded() -> Bool { applyButton()?.isEnabled == true }
        func checkbox(_ label: String) -> NSButton? {
            buttons(in: sheet()?.contentView ?? NSView()).first { $0.accessibilityLabel() == label }
        }
        func well(_ label: String) -> NSColorWell? {
            views(sheet()?.contentView, as: NSColorWell.self).first { $0.accessibilityLabel() == label }
        }
        func field(_ label: String) -> NSTextField? {
            views(sheet()?.contentView, as: NSTextField.self)
                .first { $0.isEditable && $0.accessibilityLabel() == label }
        }
        func popup(_ label: String) -> NSPopUpButton? {
            views(sheet()?.contentView, as: NSPopUpButton.self).first { $0.accessibilityLabel() == label }
        }
        func toggle(_ label: String, to state: NSControl.StateValue) {
            if let button = checkbox(label), button.state != state { button.performClick(nil) }
        }

        // The menu gate reads the cached layer kind only: enabled for the
        // genuine vector layer, disabled for a raster one.
        if let base = document.layers.first(where: { $0.kind == .pixel }) {
            document.selectLayer(base.id)
            settle()
            check(!controller.validateMenuItem(item),
                  "Vector Style… is disabled for a cached non-vector layer")
            document.selectLayer(vector.id)
            settle()
            check(controller.validateMenuItem(item),
                  "Vector Style… is enabled for the cached genuine vector layer")
        }

        // Open and cancel: the read runs off the main thread through the
        // global engine activity and seeds the sheet; Cancel changes
        // nothing.
        let undoBefore = document.undoInfo.undoCount
        let errorsBefore = errors.count
        controller.vectorStyle(nil)
        wait { seeded() }
        check(sheet() != nil && seeded() && !EngineActivity.shared.isBusy
                && field("Stroke width, pixels")?.stringValue.isEmpty == false,
              "the sheet opens and the off-main read seeds its controls")
        finish(.alertSecondButtonReturn)
        wait { document.pendingWork == 0 }
        check(document.undoInfo.undoCount == undoBefore && errors.count == errorsBefore,
              "cancelling the Vector Style sheet changes nothing and reports nothing")

        // No-op: applying the captured style unchanged queues no work and
        // pushes no undo.
        controller.vectorStyle(nil)
        wait { seeded() }
        finish(.alertFirstButtonReturn)
        wait { document.pendingWork == 0 }
        check(document.undoInfo.undoCount == undoBefore && errors.count == errorsBefore,
              "applying the unchanged style is a no-op with no undo and no error")

        // Out-of-range input is refused by the sheet's validation before
        // anything is queued.
        controller.vectorStyle(nil)
        wait { seeded() }
        toggle("Stroke the path", to: .on)
        field("Stroke width, pixels")?.stringValue = "0"
        let invalidErrors = errors.count
        let invalidUndo = document.undoInfo.undoCount
        finish(.alertFirstButtonReturn)
        wait { errors.count > invalidErrors }
        check(errors.count > invalidErrors && document.pendingWork == 0
                && document.undoInfo.undoCount == invalidUndo,
              "an out-of-range width is refused without editing or adding undo")

        // Real pixels: a red fill and a blue 6 px stroke land inside and on
        // the path, as exactly one undo step, and read back through the
        // facade.
        controller.vectorStyle(nil)
        wait { seeded() }
        toggle("Fill the path", to: .on)
        toggle("Stroke the path", to: .on)
        well("Fill color")?.color = .red
        well("Stroke color")?.color = .blue
        field("Stroke width, pixels")?.stringValue = "6"
        field("Miter limit")?.stringValue = "10"
        popup("Stroke cap")?.selectItem(at: 1)
        popup("Stroke join")?.selectItem(at: 1)
        let applyUndo = document.undoInfo.undoCount
        finish(.alertFirstButtonReturn)
        wait { document.pendingWork == 0 }
        settle()
        let center = composite(60, 40) ?? []
        let edge = composite(20, 40) ?? []
        check(center.count == 4 && center[0] > 200 && center[2] < 64,
              "the style's fill color lands inside the path (\(center))")
        check(edge.count == 4 && edge[2] > 150 && edge[0] < 100,
              "the style's stroke color and width land on the path edge (\(edge))")
        check(document.undoInfo.undoCount == applyUndo + 1, "the style change is one undo step")
        if let readBack = try? session.vectorLayerStyle(vector.id, image: image) {
            let fill = VectorStyleFormValidation.colorComponents(readBack.fillColor)
            let stroke = VectorStyleFormValidation.colorComponents(readBack.strokeColor)
            check((fill?.red ?? 0) > 0.9 && (stroke?.blue ?? 0) > 0.9 && readBack.strokeWidth == 6
                    && readBack.strokeCap == .round && readBack.strokeJoin == .round
                    && readBack.strokeMiterLimit == 10,
                  "the applied style reads back through the facade")
        } else {
            check(false, "the applied style reads back through the facade")
        }

        // XCF: the styled vector layer persists its native style.
        let xcf = work.appendingPathComponent("vector-style.xcf")
        var saved = false
        document.saveCopy(to: xcf) { saved = $0 == nil }
        wait { saved && document.pendingWork == 0 }
        check(saved, "the styled vector layer saves a copy")
        let reopened = try session.openImage(path: xcf.path)
        if let reopenedVector = try session.layers(reopened).first(where: { $0.kind == .vector }),
           let style = try? session.vectorLayerStyle(reopenedVector.id, image: reopened) {
            let fill = VectorStyleFormValidation.colorComponents(style.fillColor)
            let stroke = VectorStyleFormValidation.colorComponents(style.strokeColor)
            check((fill?.red ?? 0) > 0.9 && (stroke?.blue ?? 0) > 0.9 && style.strokeWidth == 6,
                  "the XCF round trip persists the native fill and stroke")
        } else {
            check(false, "the reopened vector layer's style reads back")
        }
        try session.closeImage(reopened)

        // Undo restores the engine's default style.
        document.undo()
        wait { document.pendingWork == 0 }
        settle()
        check(composite(60, 40)?.prefix(3).allSatisfy { $0 > 240 } == true,
              "undo restores the default white fill")

        // A busy engine acquired after the sheet opened: Apply reports the
        // busy state and changes nothing.
        controller.vectorStyle(nil)
        wait { seeded() }
        well("Fill color")?.color = .green
        let gate = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Other work", work: { gate.wait() }, completion: {})
        let busyErrors = errors.count
        let busyUndo = document.undoInfo.undoCount
        finish(.alertFirstButtonReturn)
        wait { errors.count > busyErrors }
        check(held && errors.count > busyErrors && document.pendingWork == 0
                && document.undoInfo.undoCount == busyUndo,
              "a busy engine acquired after the sheet opened is reported and changes nothing")
        gate.signal()
        wait { !EngineActivity.shared.isBusy }

        // The captured target deleted while the sheet was up: Apply refuses
        // with the target-changed error instead of touching another layer.
        controller.vectorStyle(nil)
        wait { seeded() }
        document.layerCommand(.delete)
        settle()
        wait { !document.layers.contains { $0.id == vector.id } }
        well("Fill color")?.color = .green
        let targetErrors = errors.count
        let targetUndo = document.undoInfo.undoCount
        finish(.alertFirstButtonReturn)
        wait { errors.count > targetErrors }
        check(errors.count > targetErrors && errors.last?.contains("changed") == true
                && document.undoInfo.undoCount == targetUndo,
              "a captured target deleted while the sheet was up is refused (\(errors.last ?? "none"))")
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

    /// A drop's minimum interface, so the Layers palette's drop
    /// validation and acceptance can be driven without AppKit's
    /// dragging machinery: the type name is the outline's own layer-id
    /// pasteboard contract.
    private final class LayerDragInfo: NSObject, NSDraggingInfo {
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { .move }
        var draggingLocation: NSPoint { .zero }
        var draggedImageLocation: NSPoint { .zero }
        var draggedImage: NSImage? { nil }
        let draggingPasteboard = NSPasteboard.withUniqueName()
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 0 }
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination = false
        var numberOfValidItemsForDrop = 1
        var draggingItems: [NSDraggingItem] = []
        var springLoadingHighlight: NSSpringLoadingHighlight = .none
        func slideDraggedImage(to screenPoint: NSPoint) {}
        func namesPromisedToBeDroppedAtDestination(_ promisedDropLocation: URL) -> [URL] { [] }
        func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions,
                                    for view: NSView?, classes classArray: [AnyClass],
                                    searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                    using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
        func resetSpringLoading() {}
    }

    /// The committed-effect rows of the Layers palette end to end:
    /// real child rows top-first, the eye's pixel change, Properties
    /// with its one-step undo, stack reorder, Remove, the generic form
    /// editing the committed effect seeded with its values, the
    /// preview-cancel and commit-undo semantics of that session, a begin
    /// queued behind pending input draining a close, and a group holding
    /// an effect while layer drops translate past its effect prefix.
    private static func exerciseFilterStackInterface(_ session: EngineSession, work: URL,
                                                     documents: DocumentList) throws {
        NativeFilterCatalog.shared.load(using: session)
        let image = try session.newImage(width: 32, height: 32)
        let document = try ImageDocument(session: session, image: image, name: "Filter Stack")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        func wait() {
            let deadline = Date().addingTimeInterval(10)
            while document.pendingWork > 0 && Date() < deadline { spin(0.02) }
            spin()
        }
        func settle() {
            document.inputQueue.sync {}
            spin()
        }
        guard let layer = document.activeLayer else { throw NoWindow() }

        // A stroke so blur and invert have real edges to work on.
        document.beginStroke(at: .init(x: 4, y: 16, pressure: 1))
        document.continueStroke([.init(x: 28, y: 16, pressure: 1, timeMilliseconds: 40)])
        document.endStroke()
        settle()

        // Three committed effects, bottom to top: a solid red overlay,
        // an invert, and a blur. Overlay under invert is noncommutative:
        // invert(overlay) is cyan, overlay(invert) is red.
        let first = try session.beginFilter(image: image, drawable: layer, operation: "gegl:color-overlay")
        try session.setFilterProperty(first, "value", to: .color(NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)))
        try session.commitFilter(first)
        let second = try session.beginFilter(image: image, drawable: layer, operation: "gegl:invert-linear")
        try session.commitFilter(second)
        let third = try session.beginFilter(image: image, drawable: layer, operation: "gegl:gaussian-blur")
        try session.setFilterProperty(third, "std-dev-x", to: .number(8))
        try session.setFilterProperty(third, "std-dev-y", to: .number(8))
        try session.commitFilter(third)
        settle()
        try document.reload()

        guard let stack = document.layerEffects[layer], stack.count == 3 else {
            check(false, "the document caches the three committed effects")
            controller.window?.orderOut(nil)
            return
        }
        check(stack.map(\.operation) == ["gegl:gaussian-blur", "gegl:invert-linear", "gegl:color-overlay"],
              "the document caches the committed effects top-first")
        let cyan = pixel(session, image, x: 16, y: 4)
        check((cyan?[0] ?? 255) < 60 && (cyan?[1] ?? 0) > 200,
              "blur over invert over overlay renders cyan (\(cyan ?? []))")

        let palette = LayersPaletteController()
        _ = palette.view
        palette.retarget(to: document)
        guard let outline = descendant(of: palette.view, as: NSOutlineView.self) else {
            check(false, "the layer palette has an outline")
            controller.window?.orderOut(nil)
            return
        }
        func layerNode() -> LayerTree.Node? {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? LayerTree.Node }
                .first { $0.id == layer }
        }
        guard let node = layerNode() else {
            check(false, "the outline shows the filtered layer")
            controller.window?.orderOut(nil)
            return
        }
        outline.expandItem(node)
        let rowItems = (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? AnyObject }
        let effectRows = rowItems.compactMap { $0 as? EffectItem }
        check(rowItems.count == 4
                && effectRows.count == 3
                && rowItems[0] === node
                && effectRows[0].effect.id == stack[0].id
                && effectRows[1].effect.id == stack[1].id
                && effectRows[2].effect.id == stack[2].id,
              "the layer's committed effects are its child rows, top-first")
        check(palette.outlineView(outline, pasteboardWriterForItem: effectRows[0]) == nil,
              "an effect row offers no layer drag")

        // A selected effect row picks its parent as the paint target and
        // gives the palette menu a Filter submenu with its commands.
        func selectEffectRow(_ index: Int) -> EffectItem? {
            guard index < outline.numberOfRows,
                  let item = outline.item(atRow: index) as? EffectItem else { return nil }
            outline.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            spin()
            return item
        }
        func paletteFilterItem() -> NSMenuItem? {
            palette.paletteMenu?.items.first { $0.title.hasPrefix("Filter:") }
        }

        guard selectEffectRow(2) != nil else {
            check(false, "the invert's effect row selects")
            controller.window?.orderOut(nil)
            return
        }
        check(document.activeLayer == layer, "selecting the effect row keeps its parent the paint target")
        guard let invertMenu = paletteFilterItem() else {
            check(false, "the palette menu offers the selected effect's commands")
            controller.window?.orderOut(nil)
            return
        }
        if let item = invertMenu.submenu?.items.first(where: { $0.title == "Move to Bottom" }) {
            check(palette.validateMenuItem(item), "Move to Bottom is offered on the middle effect")
            _ = NSApp.sendAction(item.action!, to: item.target, from: item)
            settle()
            try document.reload()
            check(document.layerEffects[layer]?.last?.operation == "gegl:invert-linear",
                  "Move to Bottom reorders the effect stack")
            let reordered = pixel(session, image, x: 16, y: 4)
            check((reordered?[0] ?? 0) > 200 && (reordered?[1] ?? 255) < 60,
                  "reordering the noncommutative pair changes real pixels (red \(reordered ?? []))")
            document.undo()
            settle()
            try document.reload()
            check(document.layerEffects[layer]?.map(\.operation)
                    == ["gegl:gaussian-blur", "gegl:invert-linear", "gegl:color-overlay"],
                  "one undo restores the effect order")
        } else {
            check(false, "the effect submenu offers Move to Bottom")
        }
        palette.retarget(to: document)

        // The eye toggles independent of selection: the overlay's row
        // switch hides it and the pixels follow, twice.
        func effectRow(_ operation: String) -> EffectRowView? {
            let rows = (0..<outline.numberOfRows)
            for row in rows {
                guard let item = outline.item(atRow: row) as? EffectItem,
                      item.effect.operation == operation else { continue }
                return outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? EffectRowView
            }
            return nil
        }
        if let overlayRow = effectRow("gegl:color-overlay") {
            overlayRow.eye.performClick(nil)
            settle()
            try document.reload()
            let hidden = pixel(session, image, x: 16, y: 4)
            check(hidden != cyan && document.layerEffects[layer]?[2].isEnabled == false,
                  "the eye hides the overlay and real pixels change (\(hidden ?? []))")
            palette.retarget(to: document)
            if let again = effectRow("gegl:color-overlay") {
                again.eye.performClick(nil)
                settle()
                try document.reload()
                check(document.layerEffects[layer]?[2].isEnabled == true
                        && pixel(session, image, x: 16, y: 4) == cyan,
                      "the eye restores the overlay")
                again.eye.performClick(nil)
                settle()
                try document.reload()
                check(document.layerEffects[layer]?[2].isEnabled == false,
                      "the eye toggles back off for the parameter checks below")
            } else {
                check(false, "the overlay's row is still there after a reload")
            }
        } else {
            check(false, "the overlay's effect row shows an eye")
        }

        // Properties: name and opacity in one sheet, one undo step back.
        palette.retarget(to: document)
        if let blur = document.layerEffects[layer]?.first {
            let undoBeforeProperties = document.undoInfo.undoCount
            let window = try XCTUnwrapWindow(controller)
            EffectPropertiesForm.present(item: EffectItem(document: document, drawable: layer, effect: blur),
                                         in: document, on: window)
            guard let sheet = window.attachedSheet else {
                check(false, "Properties opens a sheet on the document window")
                controller.window?.orderOut(nil)
                return
            }
            func allTextFields(in view: NSView) -> [NSTextField] {
                view.subviews.flatMap { ($0 as? NSTextField).map { [$0] } ?? allTextFields(in: $0) }
            }
            let fields = sheet.contentView.map { allTextFields(in: $0) } ?? []
            let nameField = fields.first { $0.accessibilityLabel() == "Effect name" }
            let opacityField = fields.first { $0.accessibilityLabel() == "Filter opacity, percent" }
            check(nameField != nil && opacityField != nil, "the properties sheet edits name and opacity")
            nameField?.stringValue = "Soften"
            opacityField?.stringValue = "70"
            NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue)
            settle()
            try document.reload()
            let renamed = document.layerEffects[layer]?.first
            check(renamed?.name == "Soften" && renamed?.opacity == 0.7
                    && document.undoInfo.undoCount == undoBeforeProperties + 1,
                  "Properties applies name and opacity as one undo step")
            document.undo()
            settle()
            try document.reload()
            check(document.layerEffects[layer]?.first?.opacity == 1,
                  "one undo restores the effect's properties")
        } else {
            check(false, "the blur effect is still cached")
        }

        // The catalog must be warm before the row's Edit Parameters can
        // resolve the operation.
        let catalogDeadline = Date().addingTimeInterval(10)
        while NativeFilterCatalog.shared.operation(named: "gegl:gaussian-blur") == nil
                && Date() < catalogDeadline { spin(0.02) }

        // Selecting the blur's row and choosing Edit Parameters opens
        // the generic form on the committed effect, seeded with its
        // current value; a preview write moves pixels, cancel restores.
        palette.retarget(to: document)
        guard selectEffectRow(1) != nil, let blurMenu = paletteFilterItem() else {
            check(false, "the palette menu offers the selected blur's commands")
            controller.window?.orderOut(nil)
            return
        }
        guard let edit = blurMenu.submenu?.items.first(where: { $0.title == "Edit Parameters…" }) else {
            check(false, "the effect submenu offers Edit Parameters")
            controller.window?.orderOut(nil)
            return
        }
        check(palette.validateMenuItem(edit), "Edit Parameters is offered on a supported operation")
        let beforePreview = pixel(session, image, x: 16, y: 16)
        let undoBeforeEdit = document.undoInfo.undoCount
        _ = NSApp.sendAction(edit.action!, to: edit.target, from: edit)
        let openDeadline = Date().addingTimeInterval(10)
        while controller.previewPanel == nil && Date() < openDeadline { spin(0.02) }
        guard let panel = controller.previewPanel as? NativeFilterPanel, let filter = panel.filter else {
            check(false, "Edit Parameters opens the generic form on the committed effect")
            controller.window?.orderOut(nil)
            return
        }
        check(document.filterPreviewIsOpen, "the effect edit marks the preview open")
        check((try? session.filterProperty(filter, "std-dev-x")) == .number(8),
              "the form is seeded with the committed effect's value")
        panel.setProperty("std-dev-x", .number(2))
        panel.setProperty("std-dev-y", .number(2))
        wait()
        let previewed = pixel(session, image, x: 16, y: 16)
        check(previewed != beforePreview, "the preview write changes real pixels (\(previewed ?? []))")
        panel.cancel()
        wait()
        check(controller.previewPanel == nil && !document.filterPreviewIsOpen,
              "cancel closes the effect's form")
        check(pixel(session, image, x: 16, y: 16) == beforePreview,
              "cancel restores the pixels the preview moved")
        check(document.undoInfo.undoCount == undoBeforeEdit
                && document.layerEffects[layer]?.map(\.id) == stack.map(\.id),
              "cancel preserves the effect ids, order and history")

        // The same edit committed: one undo step, same id and stack
        // position, real pixels, and Undo/Redo replay both.
        _ = NSApp.sendAction(edit.action!, to: edit.target, from: edit)
        let reopenDeadline = Date().addingTimeInterval(10)
        while controller.previewPanel == nil && Date() < reopenDeadline { spin(0.02) }
        guard let again = controller.previewPanel as? NativeFilterPanel, let againFilter = again.filter else {
            check(false, "Edit Parameters reopens on the committed effect")
            controller.window?.orderOut(nil)
            return
        }
        again.setProperty("std-dev-x", .number(2))
        again.setProperty("std-dev-y", .number(2))
        wait()
        let committedPixels = pixel(session, image, x: 16, y: 16)
        again.commit()
        let applyDeadline = Date().addingTimeInterval(10)
        while controller.previewPanel != nil && Date() < applyDeadline { spin(0.02) }
        wait()
        try document.reload()
        check(document.undoInfo.undoCount == undoBeforeEdit + 1
                && document.layerEffects[layer]?.first?.id == stack[0].id,
              "the committed edit is one undo step on the same effect id")
        check(pixel(session, image, x: 16, y: 16) == committedPixels,
              "commit keeps the previewed pixels")
        document.undo()
        settle()
        try document.reload()
        check(pixel(session, image, x: 16, y: 16) == beforePreview
                && document.layerEffects[layer]?.map(\.id) == stack.map(\.id),
              "Undo restores the pre-edit pixels and keeps the stack")
        document.redo()
        settle()
        try document.reload()
        check(pixel(session, image, x: 16, y: 16) == committedPixels
                && document.layerEffects[layer]?.first?.id == stack[0].id,
              "Redo replays the parameter edit on the same effect")

        // Remove from the selected row's menu, undone as one step.
        palette.retarget(to: document)
        guard selectEffectRow(3) != nil else {
            check(false, "the overlay's effect row selects for Remove")
            controller.window?.orderOut(nil)
            return
        }
        if let remove = paletteFilterItem()?.submenu?.items.first(where: { $0.title == "Remove" }),
           palette.validateMenuItem(remove) {
            _ = NSApp.sendAction(remove.action!, to: remove.target, from: remove)
            settle()
            try document.reload()
            check(document.layerEffects[layer]?.map(\.id) == [stack[0].id, stack[1].id],
                  "Remove drops only the selected effect row's effect")
            document.undo()
            settle()
            try document.reload()
            check(document.layerEffects[layer]?.map(\.id) == stack.map(\.id),
                  "one undo restores the removed effect")
        } else {
            check(false, "the selected effect's submenu offers Remove")
        }

        // A group can carry an effect too, and its effect prefix refuses
        // drops while the layer index after it still takes them. The
        // drag source is made first: a layer created with the group
        // active would land inside it.
        document.selectLayer(layer)
        settle()
        document.layerCommand(.new)
        settle()
        controller.newLayerGroup(nil)
        settle()
        guard let dropped = document.layers.first(where: { $0.kind == .pixel
                    && $0.parent == 0 && $0.id != layer })?.id,
              let group = document.layers.first(where: { $0.kind == .group }) else {
            check(false, "a new layer and group wait for the drag test")
            controller.window?.orderOut(nil)
            return
        }
        document.moveLayer(layer, toParent: group.id, atIndex: 0)
        settle()
        let groupFilter = try session.beginFilter(image: image, drawable: group.id,
                                                  operation: "gegl:invert-linear")
        try session.commitFilter(groupFilter)
        settle()
        try document.reload()
        check(document.layerEffects[group.id]?.count == 1,
              "a group holds a committed effect non-destructively")
        palette.retarget(to: document)
        guard let groupNode = (0..<outline.numberOfRows)
                .compactMap({ outline.item(atRow: $0) as? LayerTree.Node })
                .first(where: { $0.id == group.id }) else {
            check(false, "the outline shows the filtered group")
            controller.window?.orderOut(nil)
            return
        }
        outline.expandItem(groupNode)
        let drag = LayerDragInfo()
        defer { drag.draggingPasteboard.releaseGlobally() }
        drag.draggingPasteboard.setString("\(dropped)", forType: NSPasteboard.PasteboardType("ch.lkmc.Glims.layerID"))
        check(palette.outlineView(outline, validateDrop: drag, proposedItem: groupNode,
                                  proposedChildIndex: 0) == [],
              "a drop inside the group's effect prefix is refused")
        check(palette.outlineView(outline, validateDrop: drag, proposedItem: groupNode,
                                  proposedChildIndex: 1) == .move,
              "a drop past the prefix maps to the group's first layer slot")
        check(palette.outlineView(outline, acceptDrop: drag, item: groupNode, childIndex: 1),
              "the drop reparents the layer")
        settle()
        check(document.layers.first(where: { $0.id == dropped })?.parent == group.id,
              "the dropped layer lands inside the group below its effects")

        // A begin queued behind pending input drains a close like any
        // other counted job: the image takes the begun session with it.
        let pendingImage = try session.newImage(width: 16, height: 16)
        let pendingNative = work.appendingPathComponent("effect-pending.xcf")
        try session.save(pendingImage, to: pendingNative.path)
        let pendingDocument = try ImageDocument(session: session, image: pendingImage,
                                                name: "Pending Effect", openedFrom: pendingNative)
        documents.items.append(pendingDocument)
        let pendingController = DocumentWindowController(document: pendingDocument)
        pendingController.showWindow(nil)
        let pendingLayer = try session.beginFilter(image: pendingImage,
                                                   drawable: pendingDocument.activeLayer ?? 0,
                                                   operation: "gegl:gaussian-blur")
        try session.commitFilter(pendingLayer)
        try session.save(pendingImage, to: pendingNative.path)
        try pendingDocument.reload()
        guard let pendingDrawable = pendingDocument.layerEffects.keys.first,
              let pendingEffect = pendingDocument.layerEffects[pendingDrawable]?.first else {
            check(false, "the pending document caches its committed effect")
            controller.window?.orderOut(nil)
            return
        }
        let gate = DispatchSemaphore(value: 0)
        pendingDocument.inputQueue.async { gate.wait() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) { gate.signal() }
        let beginStart = DispatchTime.now()
        pendingController.editEffectParameters(pendingEffect.id, on: pendingDrawable,
                                               operationName: "gegl:gaussian-blur")
        check(milliseconds(since: beginStart) < 500,
              "an effect edit queued behind pending input returns promptly")
        var pendingClosed: Bool?
        pendingController.requestClose { pendingClosed = $0 }
        let pendingDeadline = Date().addingTimeInterval(10)
        while pendingClosed == nil && Date() < pendingDeadline { spin(0.02) }
        check(pendingClosed == true, "closing drains the queued effect-edit begin")
        let destroyDeadline = Date().addingTimeInterval(10)
        while (try? session.info(pendingImage)) != nil && Date() < destroyDeadline { spin(0.02) }
        check((try? session.info(pendingImage)) == nil,
              "the image is destroyed and the effect session goes with it")
        documents.items.removeAll { $0 === pendingDocument }

        // A catalog reply can arrive after the window starts closing,
        // before render teardown marks the image itself closing. Both a
        // new filter and an existing effect must refuse that late start.
        if let gaussian = NativeFilterCatalog.shared.operation(named: "gegl:gaussian-blur") {
            for existing in [false, true] {
                let closingImage = try session.newImage(width: 16, height: 16)
                let drawable = try session.layers(closingImage)[0].id
                if existing {
                    let filter = try session.beginFilter(image: closingImage, drawable: drawable,
                                                         operation: gaussian.name)
                    try session.commitFilter(filter)
                }
                let source = work.appendingPathComponent("late-filter-\(existing).xcf")
                try session.save(closingImage, to: source.path)
                let closingDocument = try ImageDocument(session: session, image: closingImage,
                                                         name: source.lastPathComponent, openedFrom: source)
                documents.items.append(closingDocument)
                let closingController = DocumentWindowController(document: closingDocument)
                closingController.showWindow(nil)
                closingController.window?.close()
                check(closingController.closeStarted && !closingDocument.isClosing,
                      "window closing precedes asynchronous render teardown (existing \(existing))")
                if existing, let effect = closingDocument.layerEffects[drawable]?.first {
                    closingController.editEffectParameters(effect.id, on: drawable, operationName: gaussian.name)
                } else {
                    closingController.openNativeFilter(gaussian)
                }
                check(!closingDocument.filterPreviewIsOpen && closingDocument.pendingWork == 0,
                      "a late filter start is refused after window closing (existing \(existing))")
                let deadline = Date().addingTimeInterval(10)
                while (try? session.info(closingImage)) != nil && Date() < deadline { spin(0.02) }
                check(closingController.previewPanel == nil && !closingDocument.filterPreviewIsOpen
                        && (try? session.info(closingImage)) == nil,
                      "closing leaves no late filter panel or live image (existing \(existing))")
                closingController.previewPanel?.cancel()
                documents.items.removeAll { $0 === closingDocument }
            }
        }

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
            let renderMilliseconds = milliseconds(since: begin)
            if renderMilliseconds >= maximumMainThreadStallMilliseconds {
                print("     slow render RPC sample \(ticks): \(String(format: "%.1f", renderMilliseconds)) ms")
            }
            maxRenderCall = max(maxRenderCall, renderMilliseconds)
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

    /// The bounded resource catalog scenario: counts and rows for all
    /// three kinds, one identity/resolve round trip per kind, a wrong
    /// identity and a high-bit handle. Reads only; no resource is applied.
    private static func exerciseSelectedBrushStrokes(_ session: EngineSession, documents: DocumentList) throws {
        let rows = try session.resources(.brush)
        guard let soft = rows.first(where: { $0.displayName == "2. Hardness 025" }),
              let block = rows.first(where: { $0.displayName == "2. Block 01" }) else {
            check(false, "the installed soft round and square brush fixtures exist")
            return
        }
        let softIdentity = try session.resourceIdentifiers(soft.id)
        let blockIdentity = try session.resourceIdentifiers(block.id)
        let image = try session.newImage(width: 96, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Selected brushes")
        documents.items.append(document)
        defer {
            documents.items.removeAll { $0 === document }
            var closed = false
            document.closeImageWhenDrained { closed = true }
            let deadline = Date().addingTimeInterval(10)
            while !closed && Date() < deadline { spin(0.01) }
            check(closed && (try? session.info(image)) == nil,
                  "the selected-brush image closes before engine shutdown")
        }
        guard let layer = document.activeLayer else {
            check(false, "the selected-brush fixture has a paint layer")
            return
        }
        func pixels() throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 96, height: 64))
            return rendered.dataProvider!.data! as Data
        }
        func settle() {
            let deadline = Date().addingTimeInterval(10)
            while document.pendingWork > 0 && Date() < deadline { spin(0.01) }
            spin()
        }
        let first = EngineSession.StrokePoint(x: 4, y: 32, pressure: 1, timeMilliseconds: 0)
        let points = (1...16).map {
            EngineSession.StrokePoint(x: 4 + 88 * Double($0) / 16, y: 32, pressure: 1, timeMilliseconds: UInt32($0 * 8))
        }
        var brush = EngineSession.Brush()
        brush.size = 20
        brush.pressureSize = false
        brush.blue = 1
        let blank = try pixels()
        let undoBefore = document.undoInfo.undoCount

        // The normal document input queue passes the persistent identity
        // to the typed facade. Resolution occurs inside that queued job.
        brush.resource = softIdentity
        document.beginStroke(at: first, brush: brush)
        document.continueStroke(points)
        document.endStroke()
        settle()
        let softPixels = try pixels()
        check(softPixels != blank && document.undoInfo.undoCount == undoBefore + 1,
              "a queued stroke resolves the selected soft brush and paints one undoable edit")
        document.undo()
        settle()
        check(try pixels() == blank, "undo selected-brush painting restores the exact original pixels")

        brush.resource = blockIdentity
        document.beginStroke(at: first, brush: brush)
        document.continueStroke(points)
        document.endStroke()
        settle()
        check(try pixels() != softPixels && document.undoInfo.undoCount == undoBefore + 1,
              "a different persisted brush identity changes the painted shape")
        document.undo()
        settle()

        // A stale identity fails instead of silently switching to the
        // inherited brush. Neither a session nor an undo step is left.
        brush.resource = EngineSession.ResourceIdentity(name: "Glims missing brush", collection: nil, isInternal: false)
        var errors: [String] = []
        document.onError = { errors.append($0) }
        document.beginStroke(at: first, brush: brush)
        document.continueStroke(points)
        document.endStroke()
        settle()
        check(try !errors.isEmpty && pixels() == blank && document.undoInfo.undoCount == undoBefore,
              "a missing selected brush reports failure without painting or adding undo")

        // nil still dispatches the original API. Resolve/select did not
        // replace the default brush inherited by ordinary legacy strokes.
        brush.resource = nil
        let legacy = try session.beginStroke(image: image, drawable: layer, brush: brush, first: first)
        try session.continueStroke(legacy, points: points)
        try session.endStroke(legacy)
        check(try pixels() != blank && session.undoInfo(image).undoCount == undoBefore + 1,
              "clearing the resource choice retains the ordinary default brush path")
    }

    private static func exerciseResourceCatalog(_ session: EngineSession) throws {
        var liveHandle: EngineSession.ResourceID = 0
        for kind in EngineSession.ResourceKind.allCases {
            let rows = try session.resources(kind)
            let second = try session.resources(kind)
            check(!rows.isEmpty && rows.count == second.count && rows.map(\.id) == second.map(\.id),
                  "the engine lists \(rows.count) \(kind) resources, with the count honored and stable")
            check(rows.allSatisfy { $0.kind == kind && !$0.displayName.isEmpty },
                  "every \(kind) row carries its kind and a display name")
            guard let first = rows.first else { continue }
            if liveHandle == 0 { liveHandle = first.id }
            let identity = try session.resourceIdentifiers(first.id)
            check(!identity.name.isEmpty, "a \(kind) handle reports a usable identity")
            let resolved = try session.resolveResource(identity, kind: kind)
            check(resolved == first.id, "the \(kind) identity resolves back to its own handle")
            check(try session.resourceIdentifiers(resolved) == identity,
                  "the resolved \(kind) handle reports the same identity, NULL and empty collections apart")
        }

        do {
            _ = try session.resolveResource(
                EngineSession.ResourceIdentity(name: "Glims No Such Resource", collection: nil, isInternal: false),
                kind: .brush)
            check(false, "a wrong identity fails")
        } catch let error as EngineSession.EngineError {
            check(error.status == Int32(GLIMS_STATUS_NOT_FOUND.rawValue),
                  "a wrong identity fails with NOT_FOUND")
        }

        do {
            _ = try session.resourceIdentifiers((UInt64(1) << 32) | liveHandle)
            check(false, "a high-bit resource id is refused")
        } catch let error as EngineSession.EngineError {
            check(error.status == Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                  "a high-bit resource id is refused without narrowing to a live handle")
        }
        let brushRows = try session.resources(.brush)
        if let row = brushRows.first {
            let identity = try session.resourceIdentifiers(row.id)
            for bad in [
                EngineSession.ResourceIdentity(name: identity.name + "\u{0}suffix",
                                               collection: identity.collection, isInternal: identity.isInternal),
                EngineSession.ResourceIdentity(name: identity.name,
                                               collection: (identity.collection ?? "") + "\u{0}suffix",
                                               isInternal: identity.isInternal)
            ] {
                do {
                    _ = try session.resolveResource(bad, kind: .brush)
                    check(false, "embedded NUL identity text is refused before CString truncation")
                } catch let error as EngineSession.EngineError {
                    check(error.status == Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                          "embedded NUL identity text is refused before CString truncation")
                }
            }
        }

    }

    /// The bounded resource thumbnail scenario: stock brushes, patterns
    /// and gradients render through the Swift wrapper, the built-in FG/BG
    /// gradient proves fresh per-call rendering with explicit colors,
    /// malformed and high-bit handles are refused, and no image, catalog
    /// or global context changes. Renders only; no resource is applied.
    private static func exerciseResourceThumbnails(_ session: EngineSession) throws {
        let catalogBefore = try EngineSession.ResourceKind.allCases.map { try session.resources($0) }
        var liveHandle: EngineSession.ResourceID = 0

        for kind in EngineSession.ResourceKind.allCases {
            let rows = try session.resources(kind)
            guard let first = rows.first else {
                check(false, "the engine lists at least one \(kind) to thumbnail")
                continue
            }
            if liveHandle == 0 { liveHandle = first.id }

            var contentSeen = false
            var alphaSeen = false
            for row in rows.prefix(3) {
                let thumbnail = try session.resourceThumbnail(row.id, maxSize: 32)
                check(thumbnail.width >= 1 && thumbnail.height >= 1
                        && thumbnail.width <= 32 && thumbnail.height <= 32,
                      "\(kind) '\(row.displayName)' thumbnail fits 32 x 32 at its own bounds (\(thumbnail.width) x \(thumbnail.height))")
                check(thumbnail.pixels.count == thumbnail.width * thumbnail.height * 4,
                      "\(kind) '\(row.displayName)' thumbnail buffer is exactly width * height * 4 straight RGBA bytes")
                check(thumbnail.image.width == thumbnail.width && thumbnail.image.height == thumbnail.height
                        && thumbnail.image.bytesPerRow == thumbnail.width * 4,
                      "\(kind) '\(row.displayName)' CGImage keeps the buffer's dimensions and row stride")
                check(argb(thumbnail.image, x: 0, y: 0) == Array(thumbnail.pixels.prefix(4)),
                      "\(kind) '\(row.displayName)' CGImage reads back the buffer's first pixel as RGBA")
                contentSeen = contentSeen || thumbnail.pixels.contains { $0 != 0 }
                alphaSeen = alphaSeen || thumbnail.pixels.enumerated().contains { $0.offset % 4 == 3 && $0.element != 0 }
            }
            check(contentSeen && alphaSeen,
                  "stock \(kind) thumbnails carry native content and alpha coverage")

            if kind == .gradient {
                let strip = try session.resourceThumbnail(first.id, maxSize: 15)
                check(strip.width == 15 && strip.height == 7 && strip.pixels.count == 15 * 7 * 4,
                      "a gradient thumbnail is exactly 15 x 7 at maxSize 15 (\(strip.width) x \(strip.height))")
                let tiny = try session.resourceThumbnail(first.id, maxSize: 1)
                check(tiny.width == 1 && tiny.height == 1 && tiny.pixels.count == 4,
                      "a gradient thumbnail is exactly 1 x 1 (4 bytes) at maxSize 1")
            }

            check(try session.resources(kind) == rows,
                  "\(kind) resource handles are stable across the thumbnail calls")
            let identity = try session.resourceIdentifiers(first.id)
            check(try session.resolveResource(identity, kind: kind) == first.id,
                  "the \(kind) identity still resolves to its own handle after thumbnails")
        }

        // The built-in FG/BG gradient's identity is stable across engine
        // sets; an internal resource's display name is localized and not
        // compared, so resolve by its collection.
        let fgBg = try session.resolveResource(
            EngineSession.ResourceIdentity(name: "FG to BG", collection: "gimp-gradient-fg-bg-rgb", isInternal: true),
            kind: .gradient)
        check(fgBg != 0, "the built-in FG to BG (RGB) gradient resolves by its exact internal identity")

        let midtone = NSColor(srgbRed: 0.5, green: 0.25, blue: 0.75, alpha: 1)
        let mid = try session.resourceThumbnail(fgBg, maxSize: 16, foreground: midtone, background: midtone)
        let firstPixel = Array(mid.pixels.prefix(4))
        check(abs(Int(firstPixel[0]) - 128) <= 1 && abs(Int(firstPixel[1]) - 64) <= 1
                && abs(Int(firstPixel[2]) - 191) <= 1 && firstPixel[3] == 255,
              "explicit thumbnail colors land as sRGB RGBA in R,G,B,A order (\(firstPixel))")
        check(argb(mid.image, x: 0, y: 0) == firstPixel,
              "the thumbnail CGImage exposes the same straight-alpha bytes as the pixel buffer")

        let redBlue = try session.resourceThumbnail(fgBg, maxSize: 32, foreground: .red, background: .blue)
        check(redBlue.width == 32 && redBlue.height == 16
                && redBlue.pixels.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 },
              "an opaque FG/BG gradient thumbnail is exactly 32 x 16 with alpha 255")
        let redBlueAgain = try session.resourceThumbnail(fgBg, maxSize: 32, foreground: .red, background: .blue)
        check(redBlue.pixels == redBlueAgain.pixels,
              "repeated same-color FG/BG gradient thumbnails agree byte for byte")
        let redGreen = try session.resourceThumbnail(fgBg, maxSize: 32, foreground: .red, background: .green)
        let yellowBlue = try session.resourceThumbnail(fgBg, maxSize: 32, foreground: .yellow, background: .blue)
        check(redBlue.pixels != redGreen.pixels,
              "changing only the background re-renders the gradient thumbnail fresh")
        check(redBlue.pixels != yellowBlue.pixels,
              "changing only the foreground re-renders the gradient thumbnail fresh")

        let defaultBefore = try session.resourceThumbnail(fgBg, maxSize: 32)
        check(defaultBefore.pixels != redBlue.pixels,
              "the default black/white colors differ from explicit red/blue")
        let defaultAfter = try session.resourceThumbnail(fgBg, maxSize: 32)
        check(defaultBefore.pixels == defaultAfter.pixels,
              "explicit-color calls leave the engine's default FG/BG untouched (no global context mutation)")

        for bad in [EngineSession.ResourceID(0), .max, (UInt64(1) << 32) | fgBg, 0x8000_0000] {
            do {
                _ = try session.resourceThumbnail(bad, maxSize: 32)
                check(false, "resource id \(bad) is refused")
            } catch let error as EngineSession.EngineError {
                check(error.status == Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                      "malformed/high-bit resource id \(bad) is refused without narrowing to a live handle")
            }
        }
        do {
            _ = try session.resourceThumbnail(0x7FFF_FFFF, maxSize: 32)
            check(false, "an unissued well-shaped resource id reports NOT_FOUND")
        } catch let error as EngineSession.EngineError {
            check(error.status == Int32(GLIMS_STATUS_NOT_FOUND.rawValue),
                  "an unissued well-shaped resource id reports NOT_FOUND")
        }
        for badSize: Int32 in [0, -1, 513] {
            do {
                _ = try session.resourceThumbnail(fgBg, maxSize: badSize)
                check(false, "maxSize \(badSize) is refused")
            } catch let error as EngineSession.EngineError {
                check(error.status == Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                      "maxSize \(badSize) is refused with INVALID_ARGUMENT")
            }
        }

        // An open image's history and pixels, and every catalog, must be
        // untouched by the renders.
        let image = try session.newImage(width: 48, height: 32)
        defer { try? session.closeImage(image) }
        let undoBefore = try session.undoInfo(image)
        let pixelsBefore = try session.copyPixels(image, merged: true).pixels
        _ = try session.resourceThumbnail(fgBg, maxSize: 64, foreground: .red, background: .blue)
        if liveHandle != 0 { _ = try session.resourceThumbnail(liveHandle, maxSize: 64) }
        check(try session.undoInfo(image) == undoBefore,
              "resource thumbnails add no undo step to an open image")
        check(try session.copyPixels(image, merged: true).pixels == pixelsBefore,
              "resource thumbnails do not mutate an open image's pixels")
        check(try EngineSession.ResourceKind.allCases.map { try session.resources($0) } == catalogBefore,
              "resource thumbnails leave every resource catalog unchanged")
    }

    /// The bounded pattern-fill scenario: a stock pattern's persistent
    /// identity is read on a background queue, then the fill is queued
    /// through the document's counted input path — the identity resolves
    /// to a live handle inside the queued work, off the main thread — and
    /// lands as one undo step on the active layer. Malformed handles and
    /// a wrong-kind identity are refused. No chooser UI is involved.
    private static func exercisePatternFill(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 96, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Pattern Fill")
        documents.items.append(document)
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        defer {
            documents.items.removeAll { $0 === document }
            var closed = false
            document.closeImageWhenDrained { closed = true }
            wait { closed }
            check(closed && (try? session.info(image)) == nil,
                  "the pattern-fill image closes before engine shutdown")
        }
        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 }
            spin()
        }

        // The catalog read and the identity both belong off the main thread.
        let identity: EngineSession.ResourceIdentity = try DispatchQueue.global(qos: .userInitiated).sync {
            for row in try session.resources(.pattern) {
                let thumbnail = try session.resourceThumbnail(row.id, maxSize: 512)
                let bytes = [UInt8](thumbnail.pixels)
                // The internal clipboard pattern may be entirely white.
                // Pick a fixture that visibly differs in the tested region.
                for y in 0..<64 {
                    for x in 0..<96 {
                        let offset = ((y % thumbnail.height) * thumbnail.width + (x % thumbnail.width)) * 4
                        if bytes[offset + 3] > 0 && bytes[offset..<offset + 3].contains(where: { $0 < 250 }) {
                            return try session.resourceIdentifiers(row.id)
                        }
                    }
                }
            }
            throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                                             message: "The engine lists no visible pattern fixture.")
        }
        check(!identity.name.isEmpty, "a stock pattern reports a usable identity")

        let undoBefore = document.undoInfo.undoCount
        let pixelsBefore = try session.copyPixels(image, merged: true).pixels
        document.fillPattern(identity, at: CGPoint(x: 8, y: 8), EngineSession.PatternFillSettings())
        settle()
        check(document.pendingWork == 0, "the queued pattern fill drained")
        check(document.undoInfo.undoCount == undoBefore + 1,
              "the queued pattern fill is one undo step (\(undoBefore) -> \(document.undoInfo.undoCount))")
        check(try session.copyPixels(image, merged: true).pixels != pixelsBefore,
              "the pattern fill changed the active layer's pixels")

        document.undo()
        settle()
        check(try session.copyPixels(image, merged: true).pixels == pixelsBefore,
              "undo restores the layer's pixels")

        for bad: EngineSession.ResourceID in [0, .max, (UInt64(1) << 32) | 1, 0x8000_0000] {
            do {
                _ = try session.fillPattern(image: image, pattern: bad, seed: .zero, .init())
                check(false, "pattern handle \(bad) is refused")
            } catch let error as EngineSession.EngineError {
                check(error.status == Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue),
                      "malformed pattern handle \(bad) throws INVALID_ARGUMENT without narrowing")
            }
        }
        do {
            _ = try session.fillPattern(image: image, pattern: 0x7FFF_FFFF, seed: .zero, .init())
            check(false, "an unissued pattern handle reports NOT_FOUND")
        } catch let error as EngineSession.EngineError {
            check(error.status == Int32(GLIMS_STATUS_NOT_FOUND.rawValue),
                  "an unissued well-shaped pattern handle throws NOT_FOUND")
        }
        let brushIdentity: EngineSession.ResourceIdentity = try DispatchQueue.global(qos: .userInitiated).sync {
            guard let first = try session.resources(.brush).first else {
                throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                                                 message: "The engine lists no brush.")
            }
            return try session.resourceIdentifiers(first.id)
        }
        do {
            _ = try session.resolveResource(brushIdentity, kind: .pattern)
            check(false, "a brush identity does not resolve as a pattern")
        } catch let error as EngineSession.EngineError {
            check(error.status == Int32(GLIMS_STATUS_NOT_FOUND.rawValue),
                  "a brush identity is NOT_FOUND as a pattern")
        }
        settle()
        check(document.undoInfo.undoCount == undoBefore, "the refused calls added no undo step")
    }

    /// The Edit ▸ Fill pattern picker's pure model against the live
    /// catalog: the full native list feeds a `PatternChooserModel`
    /// exactly as `PatternFillPicker.load` does (off the main thread,
    /// names plus persistent identities, the persisted identity resolved
    /// fresh), the user pick commits an identity, and the document's
    /// queued `fillPattern` lands it as one undo step. A missing
    /// persisted identity stays a refusal — the model never substitutes
    /// another pattern. Not wired into `run()` yet: this is the compiled
    /// companion to the picker's UI, exercised like the other scenarios
    /// once the sheet flow is part of the smoke drive.
    private static func exercisePatternChooser(_ session: EngineSession,
                                                documents: DocumentList) throws {
        let originalChoice = PatternFillStore.shared.identity
        PatternFillStore.shared.set(nil)
        defer { PatternFillStore.shared.set(originalChoice) }
        let image = try session.newImage(width: 96, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Pattern chooser")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        var errors: [String] = []
        document.onError = { errors.append($0) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        func views<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            return (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, as: type) }
        }
        func finish(_ response: NSApplication.ModalResponse) {
            if let sheet = controller.window?.attachedSheet {
                controller.window?.endSheet(sheet, returnCode: response)
            }
            spin(0.1)
        }
        defer {
            finish(.alertSecondButtonReturn)
            controller.window?.close()
            documents.items.removeAll { $0 === document }
            var closed = false
            document.closeImageWhenDrained { closed = true }
            wait { closed }
            check(closed && (try? session.info(image)) == nil,
                  "the pattern chooser image closes before engine shutdown")
        }
        func open() -> (NSTableView, PatternFillPicker)? {
            controller.fill(nil)
            guard let sheet = controller.window?.attachedSheet,
                  let choice = views(sheet.contentView, as: NSPopUpButton.self).first,
                  choice.numberOfItems == 6 && choice.itemTitle(at: 5) == "Pattern" else {
                check(false, "Fill offers Pattern after its five original sources")
                return nil
            }
            choice.selectItem(at: 5)
            if let action = choice.action { NSApp.sendAction(action, to: choice.target, from: choice) }
            guard let table = views(sheet.contentView, as: NSTableView.self).first,
                  let picker = table.dataSource as? PatternFillPicker else {
                check(false, "Pattern shows its embedded resource table")
                return nil
            }
            wait { table.numberOfRows > 0 && !EngineActivity.shared.isBusy }
            return (table, picker)
        }
        let before = try session.copyPixels(image, merged: true).pixels
        let undoBefore = document.undoInfo.undoCount
        guard let (initialTable, initialPicker) = open() else { return }
        let catalogCount = try DispatchQueue.global(qos: .userInitiated).sync {
            try session.resources(.pattern).count
        }
        check(!initialTable.isHiddenOrHasHiddenAncestor && initialTable.numberOfRows == catalogCount
                && catalogCount > PatternThumbnailQueue.batchSize,
              "the visible Fill sheet lists the entire native pattern catalog")
        let firstCell = initialTable.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView
        wait { firstCell?.imageView?.image != nil && !EngineActivity.shared.isBusy }
        check(firstCell?.textField?.stringValue.isEmpty == false && firstCell?.imageView?.image != nil,
              "actual pattern cells display names and native previews")
        finish(.alertSecondButtonReturn)
        settle()
        check(initialPicker.isClosed && document.undoInfo.undoCount == undoBefore
                && PatternFillStore.shared.identity == nil && errors.isEmpty,
              "cancelling the pattern sheet invalidates its picker without editing or persisting")

        PatternFillStore.shared.set(initialPicker.model.rows.first?.identity)
        guard let (table, picker) = open(), let last = picker.model.rows.last else { return }
        let search = views(controller.window?.attachedSheet?.contentView, as: NSSearchField.self).first
        search?.stringValue = last.name
        if let search { picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search)) }
        guard let row = picker.model.rows(matching: last.name).firstIndex(where: { $0.id == last.id }) else {
            return check(false, "search can find a pattern beyond the first preview batch")
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        picker.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: table))
        wait { picker.model.thumbnail(last.id) != nil && !EngineActivity.shared.isBusy }
        check(picker.model.pendingIdentity() == last.identity && table.numberOfRows < catalogCount,
              "search selects a real pattern beyond the first preview batch")
        let source = views(controller.window?.attachedSheet?.contentView, as: NSPopUpButton.self).first
        for index in [2, 5] {
            source?.selectItem(at: index)
            if let source, let action = source.action { NSApp.sendAction(action, to: source.target, from: source) }
        }
        wait { !EngineActivity.shared.isBusy }
        check(picker.model.pendingIdentity() == last.identity,
              "switching Fill source away and back preserves the newly chosen pattern")
        search?.stringValue = "Glims-no-matching-pattern"
        if let search { picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search)) }
        spin(0.1)
        check(table.numberOfRows == 0 && picker.model.pendingIdentity() == last.identity,
              "filtering the chosen pattern out preserves that explicit choice for Fill")
        views(controller.window?.attachedSheet?.contentView, as: NSTextField.self)
            .first { $0.accessibilityLabel() == "Fill opacity, percent" }?.stringValue = "50"
        finish(.alertFirstButtonReturn)
        settle()
        let after = try session.copyPixels(image, merged: true).pixels
        check(errors.isEmpty && after != before && document.undoInfo.undoCount == undoBefore + 1
                && PatternFillStore.shared.identity == last.identity,
              "the sheet fills with its chosen pattern and opacity as one persisted undoable edit")
        document.undo()
        settle()
        check(try session.copyPixels(image, merged: true).pixels == before,
              "undo restores the pixels before the sheet's pattern fill")

        guard let (restoredTable, restored) = open() else { return }
        check(restoredTable.selectedRow >= 0 && restored.model.pendingIdentity() == last.identity,
              "reopening the sheet restores the persisted pattern selection")
        finish(.alertSecondButtonReturn)
        settle()
        let missing = EngineSession.ResourceIdentity(name: "Glims missing pattern", collection: nil, isInternal: false)
        PatternFillStore.shared.set(missing)
        guard let (_, missingPicker) = open() else { return }
        check(missingPicker.model.missingIdentity == missing,
              "the sheet reports a removed persisted pattern without substituting another")
        let errorCount = errors.count
        finish(.alertFirstButtonReturn)
        settle()
        let afterMissing = try session.copyPixels(image, merged: true).pixels
        check(errors.count == errorCount + 1 && afterMissing == before
                && document.undoInfo.undoCount == undoBefore,
              "Fill with a missing pattern reports refusal and changes no pixels or undo")
    }

    private static func exerciseResourceGradient(_ session: EngineSession,
                                                  documents: DocumentList) throws {
        let image = try session.newImage(width: 120, height: 80)
        let document = try ImageDocument(session: session, image: image, name: "Resource Gradient")
        documents.items.append(document)
        var errors: [String] = []
        document.onError = { errors.append($0) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 }
            spin()
        }
        defer {
            documents.items.removeAll { $0 === document }
            var closed = false
            document.closeImageWhenDrained { closed = true }
            wait { closed }
            check(closed && (try? session.info(image)) == nil,
                  "the resource-gradient image closes before engine shutdown")
        }
        let identity: EngineSession.ResourceIdentity = try DispatchQueue.global(qos: .userInitiated).sync {
            for resource in try session.resources(.gradient) {
                let identity = try session.resourceIdentifiers(resource.id)
                if identity.isInternal && identity.collection == "gimp-gradient-fg-bg-rgb" { return identity }
            }
            throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_NOT_FOUND.rawValue),
                                             message: "The native foreground/background gradient is unavailable.")
        }
        let before = try session.copyPixels(image, merged: true).pixels
        let undoBefore = document.undoInfo.undoCount
        var settings = EngineSession.ResourceGradientSettings()
        let from = CGPoint(x: 0, y: 40), to = CGPoint(x: 100, y: 40)
        document.gradientResource(identity, from: from, to: to, settings: settings)
        settle()
        let middle = pixel(session, image, x: 50, y: 40) ?? []
        check(document.pendingWork == 0 && errors.isEmpty && middle.count == 4
                && (118...138).contains(Int(middle.first ?? 0)),
              "the queued resource gradient resolves its identity and renders a perceptual midpoint")
        check(document.undoInfo.undoCount == undoBefore + 1,
              "the queued resource gradient is one undo step")
        document.undo()
        settle()
        check(try session.copyPixels(image, merged: true).pixels == before,
              "undo restores the pixels before the resource gradient")

        settings.blendSpace = .rgbLinear
        let unsupportedErrors = errors.count
        document.gradientResource(identity, from: from, to: to, settings: settings)
        settle()
        let afterUnsupported = try session.copyPixels(image, merged: true).pixels
        check(errors.count == unsupportedErrors + 1 && document.undoInfo.undoCount == undoBefore
                && afterUnsupported == before,
              "unsupported linear-light resource blending reports refusal without editing")

        settings.blendSpace = .rgbPerceptual
        let missing = EngineSession.ResourceIdentity(name: "Glims Missing Gradient", collection: nil, isInternal: false)
        let missingErrors = errors.count
        document.gradientResource(missing, from: from, to: to, settings: settings)
        settle()
        let afterMissing = try session.copyPixels(image, merged: true).pixels
        check(errors.count == missingErrors + 1 && document.undoInfo.undoCount == undoBefore
                && afterMissing == before,
              "a missing selected gradient reports refusal without a fallback or undo")
    }

    private static func exerciseBrushChooserSelection(_ session: EngineSession, documents: DocumentList) throws {
        let suite = "ch.lkmc.Glims.smoke.brushchooser.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrushSelectionStore(defaults: defaults)
        let state = ToolState.shared
        let previousStore = state.brushStore
        state.brushStore = store
        defer { state.brushStore = previousStore }

        let rows = try session.resources(.brush)
        guard let soft = rows.first(where: { $0.displayName == "2. Hardness 025" }),
              let block = rows.first(where: { $0.displayName == "2. Block 01" }) else {
            check(false, "the soft and block brush fixtures exist for the chooser scenario")
            return
        }
        let softIdentity = try session.resourceIdentifiers(soft.id)
        let blockIdentity = try session.resourceIdentifiers(block.id)

        let image = try session.newImage(width: 96, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Brush chooser")
        documents.items.append(document)
        defer {
            documents.items.removeAll { $0 === document }
            document.closeImageWhenDrained()
        }
        guard let layer = document.activeLayer else {
            check(false, "the chooser fixture has a paint layer")
            return
        }
        func pixels() throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 96, height: 64))
            return rendered.dataProvider!.data! as Data
        }
        func settle() {
            let deadline = Date().addingTimeInterval(10)
            while document.pendingWork > 0 && Date() < deadline { spin(0.01) }
            spin()
        }

        // The chooser captures the tool at open; switching tools while it
        // is open must not retarget the selection.
        state.select(.paintbrush)
        let model = BrushChooserModel(capturedTool: state.current,
                                      currentIdentity: state.brush(for: .paintbrush).resource)
        check(model.capturedTool == .paintbrush, "the chooser captures the current tool at open")
        state.select(.eraser)
        check(model.capturedTool == .paintbrush, "switching tools keeps the captured tool")
        state.select(.paintbrush)

        // Load and choose through the model the panel drives, then apply
        // exactly as the Choose button does.
        model.deliver(generation: model.generation,
                      rows: [BrushRow(id: soft.id, name: soft.displayName, identity: softIdentity),
                             BrushRow(id: block.id, name: block.displayName, identity: blockIdentity)],
                      thumbnails: [:], resolvedCurrent: nil, error: nil)
        model.select(.resource(soft.id))
        state.setBrushResource(model.pendingIdentity(), for: model.capturedTool)
        check(state.brush(for: .paintbrush).resource == softIdentity,
              "the UI choice sets the captured tool's brush identity")
        check(state.brush(for: .eraser).resource == nil, "the selection never retargets another tool")
        check(store.identity(for: .paintbrush) == softIdentity && store.identity(for: .eraser) == nil,
              "only the identity persists per tool, never a session handle")
        check(ToolState(brushStore: store).brush(for: .paintbrush).resource == softIdentity,
              "the persisted identity restores into settings after a restart")

        // A queued stroke paints with the chosen brush; undo restores the
        // exact pixels as one step.
        let first = EngineSession.StrokePoint(x: 4, y: 32, pressure: 1, timeMilliseconds: 0)
        let points = (1...16).map {
            EngineSession.StrokePoint(x: 4 + 88 * Double($0) / 16, y: 32, pressure: 1, timeMilliseconds: UInt32($0 * 8))
        }
        var brush = state.brush(for: .paintbrush)
        brush.size = 20
        brush.pressureSize = false
        brush.blue = 1
        let blank = try pixels()
        let undoBefore = document.undoInfo.undoCount
        document.beginStroke(at: first, brush: brush)
        document.continueStroke(points)
        document.endStroke()
        settle()
        check(try pixels() != blank && document.undoInfo.undoCount == undoBefore + 1,
              "a stroke with the UI-chosen brush paints one undoable edit")
        document.undo()
        settle()
        check(try pixels() == blank, "undo restores the exact original pixels")

        // Cancel preserves the previous selection.
        let cancelled = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: softIdentity)
        cancelled.deliver(generation: cancelled.generation,
                          rows: [BrushRow(id: block.id, name: block.displayName, identity: blockIdentity)],
                          thumbnails: [:], resolvedCurrent: nil, error: nil)
        cancelled.select(.resource(block.id))
        check(cancelled.pendingIdentity() == blockIdentity, "the cancelled chooser would have applied the other brush")
        check(state.brush(for: .paintbrush).resource == softIdentity, "cancel preserves the previous selection")

        // A missing persisted identity is shown and fails loudly: no silent
        // fallback to the default, no paint, no undo step.
        let missing = EngineSession.ResourceIdentity(name: "Glims missing brush", collection: nil, isInternal: false)
        let missingModel = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: missing)
        missingModel.deliver(generation: missingModel.generation, rows: [], thumbnails: [:],
                             resolvedCurrent: nil, error: nil)
        check(missingModel.missingIdentity == missing, "a missing persisted identity is shown, not defaulted")
        state.setBrushResource(missing, for: .paintbrush)
        var errors: [String] = []
        document.onError = { errors.append($0) }
        document.beginStroke(at: first, brush: state.brush(for: .paintbrush))
        document.continueStroke(points)
        document.endStroke()
        settle()
        check(!errors.isEmpty && (try? pixels()) == blank && document.undoInfo.undoCount == undoBefore,
              "a missing brush choice reports failure without painting or adding undo")

        // Reset to the native Default restores the ordinary stroke path.
        state.setBrushResource(nil, for: .paintbrush)
        check(state.brush(for: .paintbrush).resource == nil && store.identity(for: .paintbrush) == nil,
              "reset stores nil, the original native default")
        let legacy = try session.beginStroke(image: image, drawable: layer,
                                             brush: state.brush(for: .paintbrush), first: first)
        try session.continueStroke(legacy, points: points)
        try session.endStroke(legacy)
        check(try pixels() != blank && session.undoInfo(image).undoCount == undoBefore + 1,
              "after reset the default brush path paints again")
    }

    private static func exerciseBrushChooserPresentation(_ session: EngineSession, documents: DocumentList) throws {
        let suite = "ch.lkmc.Glims.smoke.brush-presentation.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let state = ToolState.shared
        let previousStore = state.brushStore
        let previousTool = state.current
        state.brushStore = BrushSelectionStore(defaults: defaults)
        let image = try session.newImage(width: 32, height: 32)
        let document = try ImageDocument(session: session, image: image, name: "Chooser presentation")
        documents.items.append(document)
        defer {
            BrushChooser.shared.close()
            state.brushStore = previousStore
            state.select(previousTool)
            defaults.removePersistentDomain(forName: suite)
            documents.items.removeAll { $0 === document }
            var closed = false
            document.closeImageWhenDrained { closed = true }
            let deadline = Date().addingTimeInterval(10)
            while !closed && Date() < deadline { spin(0.01) }
            check(closed && (try? session.info(image)) == nil,
                  "chooser image-close completion arrives before stopping the engine")
        }
        func views<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            return (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, as: type) }
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        state.select(.paintbrush)
        let options = ToolOptionsPaletteController()
        _ = options.view
        options.retarget(to: document)
        func choiceButton() -> NSButton? {
            views(options.view, as: NSButton.self).first { $0.toolTip == "Choose the Brush brush" }
        }
        let missing = EngineSession.ResourceIdentity(name: "Absent presentation brush", collection: nil, isInternal: false)
        func openMissing() -> NSWindow? {
            state.setBrushResource(missing, for: .paintbrush)
            BrushChooser.shared.open(document: document, tool: .paintbrush)
            wait { choiceButton()?.title.hasPrefix("Missing:") == true && !EngineActivity.shared.isBusy }
            return NSApp.windows.first { $0.title == "Brush Brush" && $0.isVisible }
        }
        var panel = openMissing()
        check(panel != nil && choiceButton()?.title == "Missing: Absent presentation brush",
              "the real chooser reports a missing persisted brush in Tool Options")
        views(options.view, as: NSButton.self).first { $0.title == "Reset" }?.performClick(nil)
        check(state.brush(for: .paintbrush).resource == nil && choiceButton()?.title == "Default"
                && choiceButton()?.image == nil,
              "Reset replaces the Missing label and stale preview with Default")
        BrushChooser.shared.close()
        panel = openMissing()
        let table = views(panel?.contentView, as: NSTableView.self).first
        check((table?.numberOfRows ?? 0) > 1, "the actual chooser loads named catalog rows")
        table?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        views(panel?.contentView, as: NSButton.self).first { $0.title == "Choose" }?.performClick(nil)
        check(state.brush(for: .paintbrush).resource == nil && choiceButton()?.title == "Default"
                && choiceButton()?.image == nil && !BrushChooser.shared.isOpen,
              "choosing Default clears a previous Missing marker and closes the real picker")
        wait { !EngineActivity.shared.isBusy }

        BrushChooser.shared.open(document: document, tool: .paintbrush)
        panel = NSApp.windows.first { $0.title == "Brush Brush" && $0.isVisible }
        let browse = views(panel?.contentView, as: NSTableView.self).first
        wait { (browse?.numberOfRows ?? 0) > BrushThumbnailQueue.batchSize + 1 && !EngineActivity.shared.isBusy }
        if let browse, browse.numberOfRows > BrushThumbnailQueue.batchSize + 1 {
            let last = browse.numberOfRows - 1
            browse.scrollRowToVisible(last)
            panel?.displayIfNeeded()
            _ = browse.view(atColumn: 0, row: last, makeIfNecessary: true)
            wait {
                !EngineActivity.shared.isBusy
                    && (browse.view(atColumn: 0, row: last, makeIfNecessary: true) as? NSTableCellView)?.imageView?.image != nil
            }
            spin()
            check((browse.enclosingScrollView?.contentView.bounds.origin.y ?? 0) > 0,
                  "lazy previews preserve the user's scrolled catalog position")
            let expected = try DispatchQueue.global(qos: .userInitiated).sync {
                guard let last = try session.resources(.brush).last else { throw NoWindow() }
                return try session.resourceIdentifiers(last.id)
            }
            browse.selectRowIndexes(IndexSet(integer: last), byExtendingSelection: false)
            let search = views(panel?.contentView, as: NSSearchField.self).first
            search?.stringValue = "Glims-no-matching-brush"
            if let search, let picker = browse.delegate as? BrushChooserPanel {
                picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
            }
            spin(0.1)
            check(browse.numberOfRows == 1, "filtering can hide the chosen brush while leaving Default visible")
            views(panel?.contentView, as: NSButton.self).first { $0.title == "Choose" }?.performClick(nil)
            check(state.brush(for: .paintbrush).resource == expected && choiceButton()?.image != nil,
                  "filtering out a chosen brush preserves its identity and Tool Options preview")
        } else {
            check(false, "the installed catalog exercises more than one thumbnail batch")
        }
        wait { !EngineActivity.shared.isBusy }
        BrushChooser.shared.open(document: document, tool: .paintbrush)
        panel = NSApp.windows.first { $0.title == "Brush Brush" && $0.isVisible }
        let restored = views(panel?.contentView, as: NSTableView.self).first
        wait { (restored?.numberOfRows ?? 0) > 1 && !EngineActivity.shared.isBusy }
        check((restored?.selectedRow ?? -1) == (restored?.numberOfRows ?? 0) - 1,
              "reopening the brush chooser highlights its persisted selection")
        BrushChooser.shared.close()
        wait { !EngineActivity.shared.isBusy }
        let blank = try session.copyPixels(image, merged: true).pixels
        let undoBefore = document.undoInfo.undoCount
        var selectedBrush = state.brush(for: .paintbrush)
        selectedBrush.size = 16
        selectedBrush.red = 0
        selectedBrush.green = 0
        selectedBrush.blue = 0
        selectedBrush.opacity = 1
        selectedBrush.pressureSize = false
        document.beginStroke(at: .init(x: 4, y: 16, pressure: 1, timeMilliseconds: 0), brush: selectedBrush)
        document.continueStroke([.init(x: 28, y: 16, pressure: 1, timeMilliseconds: 20)])
        document.endStroke()
        wait { document.pendingWork == 0 }
        let painted = try session.copyPixels(image, merged: true).pixels
        check(painted != blank && document.undoInfo.undoCount == undoBefore + 1,
              "the brush chosen in the real panel paints through Tool State and the document queue")
        document.undo()
        wait { document.pendingWork == 0 }
        check(try session.copyPixels(image, merged: true).pixels == blank,
              "undo restores the pixels before chooser-selected painting")
    }

    private static func exerciseIndexedWrapper(_ session: EngineSession) throws {
        let image = try session.newImage(width: 24, height: 16)
        defer { try? session.closeImage(image) }
        let pixels = try session.copyPixels(image, merged: true).pixels
        let before = try session.undoInfo(image).undoCount
        var settings = EngineSession.IndexedSettings()
        settings.palette = .custom
        settings.customColors = [NSColor(patternImage: NSImage(size: NSSize(width: 2, height: 2)))]
        var refusedPattern = false
        do { try session.convertToIndexed(image, settings: settings) }
        catch let error as EngineSession.EngineError {
            refusedPattern = error.status == Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue)
        }
        check(refusedPattern, "an unconvertible pattern color is refused instead of replaced with black")
        check(try session.colorInfo(image).mode == .rgb && session.undoInfo(image).undoCount == before
                && session.copyPixels(image, merged: true).pixels == pixels,
              "a refused custom color leaves mode, pixels and history unchanged")
        // Continue independently after the regression's unexpected success.
        if try session.colorInfo(image).mode == .indexed { try session.undo(image) }
        settings.customColors = [.black, .white]
        let depth = try session.undoInfo(image).undoCount
        try session.convertToIndexed(image, settings: settings)
        check(try session.colorInfo(image).mode == .indexed && session.undoInfo(image).undoCount == depth + 1,
              "the typed custom palette converts as one undo step")
        check(try session.copyPixels(image, merged: true).pixels == pixels,
              "the custom white entry preserves the white image")
        try session.convertToIndexed(image, settings: settings)
        check(try session.undoInfo(image).undoCount == depth + 1, "the typed already-indexed conversion is a no-op")
        try session.undo(image)
        check(try session.colorInfo(image).mode == .rgb && session.copyPixels(image, merged: true).pixels == pixels,
              "undo restores RGB and the original pixels through the typed wrapper")
        let text = try session.addTextLayer(image: image, text: "Index", settings: .init(), at: .zero)
        settings.ditherText = true
        var requiresConsent = false
        do { try session.convertToIndexed(image, settings: settings) }
        catch let error as EngineSession.EngineError { requiresConsent = error.requiresRasterization }
        check(try requiresConsent && session.layers(image).first(where: { $0.id == text })?.kind == .text,
              "the typed preservation refusal identifies rasterization consent without changing text")
        settings.preservation = .allowRasterize
        try session.convertToIndexed(image, settings: settings)
        check(try session.colorInfo(image).mode == .indexed
                && session.layers(image).first(where: { $0.id == text })?.kind == .pixel,
              "explicit typed consent converts and rasterizes the text")
        try session.undo(image)
        check(try session.colorInfo(image).mode == .rgb
                && session.layers(image).first(where: { $0.id == text })?.kind == .text,
              "undo of consented typed conversion restores the editable text")
    }

    /// The guides controls end to end through the actual sheet: Image ▸
    /// Guides… on two documents at once, add/move/remove/undo through the
    /// sheet's own buttons, refused out-of-range and non-integer input with
    /// no mutation, busy disabling, selection and field-edit preservation
    /// across asynchronous reloads, late close, and View ▸ Show Guides
    /// changing only the canvas view bitmap while the engine's image pixels
    /// stay identical.
    private static func exerciseGuidesControls(_ session: EngineSession, work: URL,
                                               documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func views<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            return (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, as: type) }
        }
        func button(_ sheet: NSWindow?, _ label: String) -> NSButton? {
            buttons(in: sheet?.contentView ?? NSView()).first { $0.accessibilityLabel() == label }
        }
        func editableField(_ sheet: NSWindow?, _ label: String) -> NSTextField? {
            views(sheet?.contentView, as: NSTextField.self)
                .first { $0.isEditable && $0.accessibilityLabel() == label }
        }
        func messageField(_ sheet: NSWindow?) -> NSTextField? {
            views(sheet?.contentView, as: NSTextField.self)
                .first { !$0.isEditable && $0.accessibilityLabel() == "Guides message" }
        }
        func popup(_ sheet: NSWindow?, _ label: String) -> NSPopUpButton? {
            views(sheet?.contentView, as: NSPopUpButton.self).first { $0.accessibilityLabel() == label }
        }
        func table(_ sheet: NSWindow?) -> NSTableView? {
            views(sheet?.contentView, as: NSTableView.self).first { $0.accessibilityLabel() == "Guides list" }
        }

        let imageA = try session.newImage(width: 40, height: 24)
        let imageB = try session.newImage(width: 30, height: 30)
        let docA = try ImageDocument(session: session, image: imageA, name: "Guides A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Guides B")
        documents.items += [docA, docB]
        let a = DocumentWindowController(document: docA)
        let b = DocumentWindowController(document: docB)
        a.showWindow(nil)
        b.showWindow(nil)
        defer {
            for (controller, document) in [(a, docA), (b, docB)] {
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
                controller.window?.close()
                documents.items.removeAll { $0 === document }
                document.closeImageWhenDrained()
            }
        }

        // Menu wiring: both items sit on the document's own selectors.
        let mainMenu = MainMenu.make()
        let imageMenu = mainMenu.items.first { $0.title == "Image" }?.submenu
        let viewMenu = mainMenu.items.first { $0.title == "View" }?.submenu
        check(imageMenu?.items.first { $0.title == "Guides…" }?.action
                == #selector(DocumentWindowController.showGuides(_:)),
              "Image offers Guides… on the document's selector")
        check(viewMenu?.items.first { $0.title == "Show Guides" }?.action
                == #selector(DocumentWindowController.toggleShowGuides(_:)),
              "View offers Show Guides on the document's selector")

        // Menu validation reads only cached state: Show Guides checked by
        // default, Guides… enabled while no sheet is attached.
        let showItem = NSMenuItem(title: "Show Guides",
                                  action: #selector(DocumentWindowController.toggleShowGuides(_:)), keyEquivalent: "")
        check(a.validateMenuItem(showItem) && showItem.state == .on,
              "Show Guides validates checked by default")
        let guidesItem = NSMenuItem(title: "Guides…",
                                    action: #selector(DocumentWindowController.showGuides(_:)), keyEquivalent: "")
        check(a.validateMenuItem(guidesItem), "Guides… validates while no sheet is open")

        // Two documents open independent sheets through the actual action.
        a.showGuides(nil)
        b.showGuides(nil)
        let sheetA = a.window?.attachedSheet
        let sheetB = b.window?.attachedSheet
        check(sheetA != nil && sheetB != nil && sheetA !== sheetB && a.guidesSheet !== b.guidesSheet,
              "two documents open independent Guides sheets owned by their windows")
        check(!a.validateMenuItem(guidesItem), "Guides… is disabled while its sheet is open")

        // Add a horizontal guide at y=10 on A through the sheet's controls.
        let undoBefore = docA.undoInfo.undoCount
        popup(sheetA, "Guide orientation")?.selectItem(withTitle: "Horizontal")
        editableField(sheetA, "Guide position in pixels")?.stringValue = "10"
        button(sheetA, "Add guide")?.performClick(nil)
        wait { docA.guides.count == 1 && docA.pendingWork == 0 }
        spin()
        check(docA.guides.count == 1 && docA.guides[0].orientation == .horizontal
                && docA.guides[0].position == 10,
              "Add enqueues one horizontal guide at y=10")
        check(docA.undoInfo.undoCount == undoBefore + 1, "Add is one undo step")
        wait { (table(sheetA)?.numberOfRows ?? 0) == 1 }
        check(table(sheetA)?.numberOfRows == 1,
              "the open sheet reloads the cached guide list through the window's callback")

        // The second document's sheet edits its own document only.
        popup(sheetB, "Guide orientation")?.selectItem(withTitle: "Vertical")
        editableField(sheetB, "Guide position in pixels")?.stringValue = "5"
        button(sheetB, "Add guide")?.performClick(nil)
        wait { docB.guides.count == 1 && docB.pendingWork == 0 }
        spin()
        check(docB.guides.count == 1 && docB.guides[0].orientation == .vertical
                && docB.guides[0].position == 5 && docA.guides.count == 1,
              "the two sheets drive their own documents independently")

        // Write controls disable while the engine is busy (cached state).
        let gate = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Holding the engine", work: { gate.wait() },
                                                 completion: {})
        check(held && button(sheetB, "Add guide")?.isEnabled == false,
              "the sheet's write controls disable while the engine is busy")
        gate.signal()
        wait { !EngineActivity.shared.isBusy }
        spin(0.05)
        check(button(sheetB, "Add guide")?.isEnabled == true,
              "the sheet's write controls re-enable when the engine is idle")

        // Move the selected row to y=20; the guide identity is preserved.
        table(sheetA)?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        spin(0.05)
        let addedID = docA.guides[0].id
        editableField(sheetA, "Guide position in pixels")?.stringValue = "20"
        let undoBeforeMove = docA.undoInfo.undoCount
        button(sheetA, "Move selected guide")?.performClick(nil)
        wait { docA.pendingWork == 0 && docA.guides.first?.position == 20 }
        spin()
        check(docA.guides.count == 1 && docA.guides[0].id == addedID && docA.guides[0].position == 20,
              "Move keeps the guide's identity and orientation and changes only its position")
        check(docA.undoInfo.undoCount == undoBeforeMove + 1, "Move is one undo step")
        check(table(sheetA)?.selectedRow == 0,
              "the selected row survives the asynchronous reload by guide identity")

        sheetA?.endEditing(for: nil)
        docA.undo()
        wait { docA.pendingWork == 0 && docA.guides.first?.position == 10 }
        spin(0.1)
        check(editableField(sheetA, "Guide position in pixels")?.stringValue == "10",
              "undo refreshes the selected guide's idle position field")
        docA.redo()
        wait { docA.pendingWork == 0 && docA.guides.first?.position == 20 }
        spin(0.1)
        check(editableField(sheetA, "Guide position in pixels")?.stringValue == "20",
              "redo refreshes the selected guide's idle position field")

        // Out-of-range and non-integer input: refused visibly, no mutation.
        editableField(sheetA, "Guide position in pixels")?.stringValue = "999"
        let undoBeforeInvalid = docA.undoInfo.undoCount
        button(sheetA, "Add guide")?.performClick(nil)
        wait { docA.pendingWork == 0 }
        check(docA.guides.count == 1 && docA.undoInfo.undoCount == undoBeforeInvalid
                && a.guidesSheet?.lastError != nil && !(messageField(sheetA)?.stringValue ?? "").isEmpty,
              "an out-of-range position is refused in the sheet without mutation or undo")
        editableField(sheetA, "Guide position in pixels")?.stringValue = "12px"
        button(sheetA, "Add guide")?.performClick(nil)
        check(docA.guides.count == 1 && docA.pendingWork == 0
                && !(messageField(sheetA)?.stringValue ?? "").isEmpty,
              "a non-integer position is refused visibly without mutation")
        editableField(sheetA, "Guide position in pixels")?.stringValue = "20"

        // Remove the selected guide, then undo restores it.
        button(sheetA, "Remove selected guide")?.performClick(nil)
        wait { docA.pendingWork == 0 && docA.guides.isEmpty }
        spin()
        check(docA.guides.isEmpty && (table(sheetA)?.numberOfRows ?? 1) == 0,
              "Remove deletes the selected guide and the sheet reloads to empty")
        docA.undo()
        wait { docA.pendingWork == 0 && docA.guides.contains { $0.orientation == .horizontal && $0.position == 20 } }
        spin()
        check(docA.guides.contains { $0.orientation == .horizontal && $0.position == 20 },
              "undo restores the removed guide at its position and orientation")

        // An asynchronous reload never overwrites an active field edit.
        table(sheetA)?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        spin(0.05)
        guard let positionField = editableField(sheetA, "Guide position in pixels") else {
            return check(false, "the sheet's position field is reachable by its accessibility label")
        }
        sheetA?.makeFirstResponder(positionField)
        positionField.stringValue = "7"
        docA.addGuide(.vertical, at: 3)
        wait { docA.pendingWork == 0 && docA.guides.contains { $0.orientation == .vertical } }
        spin(0.1)
        check(editableField(sheetA, "Guide position in pixels")?.stringValue == "7",
              "an asynchronous reload does not overwrite an active field edit")
        sheetA?.endEditing(for: nil)

        // Late close: after the sheet ends, a guides change must not reopen
        // or update it.
        if let sheet = a.window?.attachedSheet {
            a.window?.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        }
        spin(0.1)
        check(a.guidesSheet == nil, "closing the sheet releases the window's reference")
        docA.addGuide(.horizontal, at: 2)
        wait { docA.pendingWork == 0 && docA.guides.contains { $0.position == 2 } }
        spin(0.2)
        check(a.window?.attachedSheet == nil && a.guidesSheet == nil,
              "a late guides change does not reopen or update a closed sheet")

        // View ▸ Show Guides: the overlay is visible in the canvas's own
        // view bitmap; toggling changes only the view, never image pixels
        // or the dirty state.
        let canvas = a.canvas
        try canvas.renderVisibleTilesNow()
        func brightnessNear(_ x: Int, _ y: Int) -> Double? {
            [CGPoint(x: x, y: y), CGPoint(x: x, y: y - 1), CGPoint(x: x, y: y + 1),
             CGPoint(x: x - 1, y: y), CGPoint(x: x + 1, y: y)]
                .compactMap { canvasBrightness(canvas, at: $0) }.min()
        }
        let onGuide = brightnessNear(3, 12)   // the vertical guide at x=3
        let offGuide = canvasBrightness(canvas, at: CGPoint(x: 10, y: 12))
        check(onGuide != nil && offGuide != nil && onGuide! < offGuide! - 0.05,
              "the canvas view bitmap draws the vertical guide line (\(String(describing: onGuide)) vs \(String(describing: offGuide)))")
        let pixelOnGuide = pixel(session, imageA, x: 3, y: 12)
        let dirtyBefore = docA.hasUnsavedChanges
        a.toggleShowGuides(showItem)
        check(showItem.state == .off && !a.guidesViewState.showsGuides,
              "Show Guides toggles the cached per-window flag and the menu state")
        let hiddenGuide = brightnessNear(3, 12)
        check(hiddenGuide != nil && offGuide != nil && abs(hiddenGuide! - offGuide!) < 0.05,
              "with Show Guides off the view bitmap no longer draws the line")
        check(pixel(session, imageA, x: 3, y: 12) == pixelOnGuide && docA.hasUnsavedChanges == dirtyBefore,
              "toggling Show Guides changes neither the engine's image pixels nor the dirty state")
        a.toggleShowGuides(showItem)
        let backOn = brightnessNear(3, 12)
        check(backOn != nil && offGuide != nil && backOn! < offGuide! - 0.05,
              "toggling Show Guides back on redraws the overlay in the view bitmap")
        check(pixel(session, imageA, x: 3, y: 12) == pixelOnGuide,
              "the image pixels on the guide are still identical after both toggles")
    }

    /// Pixel rulers: the scroll view's native ruler slots, the per-window
    /// View ▸ Show Rulers toggle (default on, busy-independent), tick
    /// movement under scroll/zoom checked against an independent geometry
    /// oracle plus a ruler view-bitmap check, display-only isolation of
    /// pixels/dirty/history/selection, and safe close.
    private static func exerciseGridControls(_ session: EngineSession, work: URL,
                                             documents: DocumentList) throws {
        // Recursive view search that recurses into children EVEN WHEN THE
        // ROOT ITSELF MATCHES the type (an NSStackView root must not hide
        // a nested match of the same class).
        func allViews<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            var found: [T] = []
            if let match = root as? T { found.append(match) }
            for child in root.subviews { found += allViews(child, as: type) }
            return found
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func button(_ sheet: NSWindow?, _ label: String) -> NSButton? {
            allViews(sheet?.contentView, as: NSButton.self).first { $0.accessibilityLabel() == label }
        }
        func field(_ sheet: NSWindow?, _ label: String) -> NSTextField? {
            allViews(sheet?.contentView, as: NSTextField.self)
                .first { $0.isEditable && $0.accessibilityLabel() == label }
        }
        func message(_ sheet: NSWindow?) -> NSTextField? {
            allViews(sheet?.contentView, as: NSTextField.self)
                .first { !$0.isEditable && $0.accessibilityLabel() == "Grid message" }
        }
        func popup(_ sheet: NSWindow?, _ label: String) -> NSPopUpButton? {
            allViews(sheet?.contentView, as: NSPopUpButton.self).first { $0.accessibilityLabel() == label }
        }
        func well(_ sheet: NSWindow?, _ label: String) -> NSColorWell? {
            allViews(sheet?.contentView, as: NSColorWell.self).first { $0.accessibilityLabel() == label }
        }

        let imageA = try session.newImage(width: 40, height: 24)
        let imageB = try session.newImage(width: 30, height: 30)
        let docA = try ImageDocument(session: session, image: imageA, name: "Grid A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Grid B")
        documents.items += [docA, docB]
        let a = DocumentWindowController(document: docA)
        let b = DocumentWindowController(document: docB)
        a.showWindow(nil)
        b.showWindow(nil)
        var messages: [String] = []
        let reportError = docA.onError
        docA.onError = { reportError?($0); messages.append($0) }
        defer {
            for (controller, document) in [(a, docA), (b, docB)] {
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
                controller.window?.close()
                documents.items.removeAll { $0 === document }
                var closed = false
                document.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(10)
                while !closed && Date() < deadline { spin(0.01) }
            }
        }

        // Menu wiring: both items sit on the document's own selectors.
        let mainMenu = MainMenu.make()
        let imageMenu = mainMenu.items.first { $0.title == "Image" }?.submenu
        let viewMenu = mainMenu.items.first { $0.title == "View" }?.submenu
        check(imageMenu?.items.first { $0.title == "Configure Grid…" }?.action
                == #selector(DocumentWindowController.configureGrid(_:)),
              "Image offers Configure Grid… on the document's selector")
        check(viewMenu?.items.first { $0.title == "Show Grid" }?.action
                == #selector(DocumentWindowController.toggleShowGrid(_:)),
              "View offers Show Grid on the document's selector")

        // Menu validation reads only cached state: Show Grid unchecked by
        // default and always valid; Configure Grid… enabled while no sheet
        // is attached (image metadata: no channel-target restriction).
        let showGridItem = NSMenuItem(title: "Show Grid",
                                      action: #selector(DocumentWindowController.toggleShowGrid(_:)), keyEquivalent: "")
        let configureItem = NSMenuItem(title: "Configure Grid…",
                                       action: #selector(DocumentWindowController.configureGrid(_:)), keyEquivalent: "")
        check(a.validateMenuItem(showGridItem) && showGridItem.state == .off,
              "Show Grid validates unchecked by default")
        check(a.validateMenuItem(configureItem), "Configure Grid… validates while no sheet is open")

        // Two documents open independent sheets through the actual action.
        a.configureGrid(nil)
        b.configureGrid(nil)
        let sheetA = a.window?.attachedSheet
        let sheetB = b.window?.attachedSheet
        check(sheetA != nil && sheetB != nil && sheetA !== sheetB && a.gridSheet !== b.gridSheet,
              "two documents open independent grid sheets owned by their windows")
        check(!a.validateMenuItem(configureItem), "Configure Grid… is disabled while its sheet is open")

        // The sheet seeds its draft from the cached grid (default 10/10, 0/0, solid).
        check(field(sheetA, "Grid spacing X")?.stringValue == "10.0"
                && field(sheetA, "Grid spacing Y")?.stringValue == "10.0"
                && field(sheetA, "Grid offset X")?.stringValue == "0.0"
                && field(sheetA, "Grid offset Y")?.stringValue == "0.0"
                && popup(sheetA, "Grid style")?.titleOfSelectedItem == "Solid"
                && well(sheetA, "Grid foreground color") != nil && well(sheetA, "Grid background color") != nil,
              "the sheet seeds spacing, offset, style and both color wells from the cached grid")

        // Apply through the sheet's real controls: one queued atomic
        // setGrid, one undo step, pixels untouched, sheet stays open.
        let pixelsBefore = try session.copyPixels(imageA, merged: true).pixels
        let undoBefore = docA.undoInfo.undoCount
        field(sheetA, "Grid spacing X")?.stringValue = "20"
        a.gridSheet?.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification,
                                                       object: field(sheetA, "Grid spacing X")))
        let applyGate = DispatchSemaphore(value: 0)
        docA.inputQueue.async { applyGate.wait() }
        button(sheetA, "Apply grid")?.performClick(nil)
        check(docA.pendingWork > 0 && button(sheetA, "Apply grid")?.isEnabled == false
                && button(sheetA, "Close grid sheet")?.isEnabled == false
                && field(sheetA, "Grid spacing X")?.isEnabled == false,
              "accepted grid work is counted and disables controls until completion")
        let otherWorkGate = DispatchSemaphore(value: 0)
        let otherWorkAccepted = EngineActivity.shared.perform(label: "Grid completion accounting",
                                                               work: { otherWorkGate.wait() }, completion: {})
        applyGate.signal()
        wait { (try? session.grid(imageA).spacingX) == 20 }
        spin()
        check(otherWorkAccepted && EngineActivity.shared.isBusy && docA.pendingWork > 0
                && button(sheetA, "Close grid sheet")?.isEnabled == false,
              "grid completion remains counted while another engine activity defers its callback")
        otherWorkGate.signal()
        wait { !EngineActivity.shared.isBusy && docA.pendingWork == 0 && docA.grid.spacingX == 20 }
        spin()
        check(docA.grid.spacingX == 20 && docA.grid.spacingY == 10
                && docA.undoInfo.undoCount == undoBefore + 1,
              "Apply performs one queued setGrid with one undo step")
        check(try session.copyPixels(imageA, merged: true).pixels == pixelsBefore,
              "the grid change leaves the image pixels untouched")
        check(a.window?.attachedSheet === sheetA && a.gridSheet != nil,
              "Apply keeps the sheet open")
        docA.undo()
        wait { docA.pendingWork == 0 && docA.grid.spacingX == 10 }
        spin()
        check(field(sheetA, "Grid spacing X")?.stringValue == "10.0",
              "Undo after Apply refreshes the idle field in the still-open sheet")
        docA.redo()
        wait { docA.pendingWork == 0 && docA.grid.spacingX == 20 }
        spin()
        check(field(sheetA, "Grid spacing X")?.stringValue == "20.0",
              "Redo refreshes the open grid sheet's committed field")

        // Invalid input: refused visibly in the sheet, no mutation, and
        // the draft is preserved for correcting.
        let undoAfterApply = docA.undoInfo.undoCount
        field(sheetA, "Grid spacing X")?.stringValue = "abc"
        button(sheetA, "Apply grid")?.performClick(nil)
        wait { docA.pendingWork == 0 }
        check(docA.grid.spacingX == 20 && docA.undoInfo.undoCount == undoAfterApply
                && a.gridSheet?.lastError != nil && !(message(sheetA)?.stringValue ?? "").isEmpty
                && field(sheetA, "Grid spacing X")?.stringValue == "abc",
              "an unparsable spacing is refused in the sheet without mutation and the draft is kept")
        field(sheetA, "Grid spacing X")?.stringValue = "0"
        button(sheetA, "Apply grid")?.performClick(nil)
        check(docA.grid.spacingX == 20 && docA.undoInfo.undoCount == undoAfterApply
                && (message(sheetA)?.stringValue ?? "").contains("greater than zero"),
              "a zero spacing is refused visibly without mutation")

        // A native bounds refusal (spacing beyond the engine's maximum)
        // is reported, not clamped; the draft survives.
        field(sheetA, "Grid spacing X")?.stringValue = "1000000000"
        button(sheetA, "Apply grid")?.performClick(nil)
        wait { docA.pendingWork == 0 && !messages.isEmpty }
        spin()
        check(docA.grid.spacingX == 20 && docA.undoInfo.undoCount == undoAfterApply
                && a.gridSheet?.lastError != nil && !(message(sheetA)?.stringValue ?? "").isEmpty
                && field(sheetA, "Grid spacing X")?.stringValue == "1000000000",
              "an over-maximum spacing is refused by the engine and shown in the sheet, draft preserved")

        // Cancel writes nothing and closes the sheet.
        field(sheetA, "Grid spacing X")?.stringValue = "33"
        button(sheetA, "Close grid sheet")?.performClick(nil)
        wait { a.window?.attachedSheet == nil }
        spin()
        check(a.gridSheet == nil && docA.grid.spacingX == 20 && docA.undoInfo.undoCount == undoAfterApply,
              "Cancel closes the sheet without writing anything")

        // A reopened sheet re-seeds from the cache; applying the identical
        // grid is a no-op with no undo.
        a.configureGrid(nil)
        let reopened = a.window?.attachedSheet
        check(field(reopened, "Grid spacing X")?.stringValue == "20.0",
              "a reopened sheet re-seeds its draft from the cached grid")
        button(reopened, "Apply grid")?.performClick(nil)
        wait { docA.pendingWork == 0 }
        spin()
        check(docA.undoInfo.undoCount == undoAfterApply && docA.grid.spacingX == 20,
              "applying the identical grid is a no-op with no undo")
        if let sheet = a.window?.attachedSheet {
            a.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        wait { a.window?.attachedSheet == nil }

        // Undo/Redo refresh the cached grid.
        docA.undo()
        wait { docA.pendingWork == 0 && docA.grid.spacingX == 10 }
        spin()
        check(docA.grid.spacingX == 10, "undo refreshes the cached grid")
        docA.redo()
        wait { docA.pendingWork == 0 && docA.grid.spacingX == 20 }
        spin()
        check(docA.grid.spacingX == 20, "redo refreshes the cached grid")

        // Late close: after the sheet ended, a grid change must not
        // reopen or update it.
        docA.setGrid(EngineSession.Grid(style: .solid, spacingX: 15, spacingY: 10,
                                        offsetX: 0, offsetY: 0,
                                        foreground: .black, background: .white))
        wait { docA.pendingWork == 0 && docA.grid.spacingX == 15 }
        spin()
        check(a.window?.attachedSheet == nil && a.gridSheet == nil,
              "a late grid change does not reopen or update a closed sheet")
        docA.undo()
        wait { docA.pendingWork == 0 && docA.grid.spacingX == 20 }

        // Two-document ownership: A's sheet drives only docA.
        a.configureGrid(nil)
        b.configureGrid(nil)
        let sheetA2 = a.window?.attachedSheet
        field(sheetA2, "Grid spacing X")?.stringValue = "25"
        button(sheetA2, "Apply grid")?.performClick(nil)
        wait { docA.pendingWork == 0 && docA.grid.spacingX == 25 }
        spin()
        check(docA.grid.spacingX == 25 && docB.grid.spacingX == 10 && docB.undoInfo.undoCount == 0,
              "the two sheets drive their own documents independently")

        // Busy: the sheet's Apply gates on cached state, but Show Grid —
        // pure view state — stays available while the engine is busy. The
        // gate is released on every path by the defer.
        do {
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let held = EngineActivity.shared.perform(label: "Holding the engine for grid", work: { gate.wait() },
                                                     completion: {})
            check(held && button(sheetA2, "Apply grid")?.isEnabled == false,
                  "Apply disables while the engine is busy (cached state)")
            check(a.validateMenuItem(showGridItem), "Show Grid stays valid while the engine is busy")
            a.toggleShowGrid(showGridItem)
            check(a.gridViewState.showsGrid && showGridItem.state == .on && a.canvas.showsGrid,
                  "Show Grid toggles while the engine is busy")
            a.toggleShowGrid(showGridItem)
            check(!a.gridViewState.showsGrid && showGridItem.state == .off,
                  "Show Grid toggles back while the engine is busy")
        }
        wait { !EngineActivity.shared.isBusy }
        spin()
        check(button(a.window?.attachedSheet, "Apply grid")?.isEnabled == true,
              "Apply re-enables when the engine is idle again")

        // Set a known grid (solid 10/10, 0/0) through the sheet for the
        // bitmap checks, then close the sheet.
        let sheetA3 = a.window?.attachedSheet
        field(sheetA3, "Grid spacing X")?.stringValue = "10"
        popup(sheetA3, "Grid style")?.selectItem(withTitle: "Solid")
        button(sheetA3, "Apply grid")?.performClick(nil)
        wait { docA.pendingWork == 0 && docA.grid.spacingX == 10 && docA.grid.style == .solid }
        spin()
        if let sheet = a.window?.attachedSheet {
            a.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        wait { a.window?.attachedSheet == nil }
        for (controller, document) in [(a, docA), (b, docB)] where controller.window?.attachedSheet != nil {
            controller.window?.endSheet(controller.window!.attachedSheet!, returnCode: .alertSecondButtonReturn)
        }
        wait { b.window?.attachedSheet == nil }

        // View bitmap: Show Grid draws the cached grid between the image
        // and the other overlays; toggling and re-styling change only the
        // view, never the native pixels, dirty state or history.
        let canvas = a.canvas
        try canvas.renderVisibleTilesNow()
        func bitmap() -> Data? {
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            guard let bytes = rep.bitmapData else { return nil }
            return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
        }
        func brightnessNear(_ x: Int, _ y: Int) -> Double? {
            [CGPoint(x: x, y: y), CGPoint(x: x, y: y - 1), CGPoint(x: x, y: y + 1),
             CGPoint(x: x - 1, y: y), CGPoint(x: x + 1, y: y)]
                .compactMap { canvasBrightness(canvas, at: $0) }.min()
        }
        let pixelOnLine = pixel(session, imageA, x: 10, y: 5)
        let pixelAtIntersection = pixel(session, imageA, x: 10, y: 10)
        let dirtyBefore = docA.hasUnsavedChanges
        let undoBeforeBitmap = docA.undoInfo
        let bitmapOff = bitmap()
        a.toggleShowGrid(showGridItem)
        let bitmapOn = bitmap()
        check(showGridItem.state == .on && canvas.showsGrid
                && bitmapOff != nil && bitmapOn != nil && bitmapOn != bitmapOff,
              "Show Grid changes the canvas view bitmap")
        let onLine = brightnessNear(10, 5)   // on the vertical line x = 10
        let offLine = brightnessNear(5, 5)   // between grid lines
        check(onLine != nil && offLine != nil && onLine! < offLine! - 0.05,
              "the solid grid draws its line in the view bitmap (\(String(describing: onLine)) vs \(String(describing: offLine)))")
        check(!b.gridViewState.showsGrid && !b.canvas.showsGrid,
              "Show Grid is cached per window: the other window stays off")
        check(pixel(session, imageA, x: 10, y: 5) == pixelOnLine
                && pixel(session, imageA, x: 10, y: 10) == pixelAtIntersection
                && docA.hasUnsavedChanges == dirtyBefore && docA.undoInfo == undoBeforeBitmap,
              "toggling Show Grid changes neither the engine pixels nor dirty state or history")
        a.toggleShowGrid(showGridItem)
        check(bitmap() == bitmapOff && showGridItem.state == .off,
              "toggling Show Grid off restores the view bitmap")
        check(pixel(session, imageA, x: 10, y: 5) == pixelOnLine,
              "the image pixels on the grid line are identical after both toggles")

        // Style differences in the view bitmap: Dots darken only the
        // intersections, not the line between them.
        a.configureGrid(nil)
        let sheetA4 = a.window?.attachedSheet
        popup(sheetA4, "Grid style")?.selectItem(withTitle: "Dots")
        button(sheetA4, "Apply grid")?.performClick(nil)
        wait { docA.pendingWork == 0 && docA.grid.style == .dots }
        spin()
        if let sheet = a.window?.attachedSheet {
            a.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        wait { a.window?.attachedSheet == nil }
        a.toggleShowGrid(showGridItem)
        let bitmapDots = bitmap()
        check(bitmapDots != nil && bitmapDots != bitmapOn,
              "the Dots style draws a different view bitmap than Solid")
        let dotsOnLine = brightnessNear(10, 5)
        let dotsAtIntersection = brightnessNear(10, 10)
        check(dotsOnLine != nil && offLine != nil && abs(dotsOnLine! - offLine!) < 0.05,
              "Dots leave the line between intersections untouched")
        check(dotsAtIntersection != nil && offLine != nil && dotsAtIntersection! < offLine! - 0.05,
              "Dots darken the intersections in the view bitmap")
        check(pixel(session, imageA, x: 10, y: 5) == pixelOnLine
                && pixel(session, imageA, x: 10, y: 10) == pixelAtIntersection,
              "re-styling the grid changes no native image pixel")
        a.toggleShowGrid(showGridItem)
    }

    private static func exercisePixelRulers(_ session: EngineSession, work: URL,
                                            documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        // Independent oracle for the nice major spacing: brute-force the
        // smallest whole 1/2/5 * 10^n (n >= 0) reaching the 50-point target
        // at the given point scale — a plain loop, not the planner's path.
        func oracleMajorSpacing(pointsPerPixel: Double) -> Double? {
            let raw = max(1.0, 50.0 / pointsPerPixel)
            guard raw.isFinite else { return nil }
            var best: Double?
            var n = 0
            while n <= 308 {
                let base = pow(10.0, Double(n))
                for multiple in [1.0, 2.0, 5.0] {
                    let candidate = multiple * base
                    if candidate.isFinite && candidate >= raw && (best == nil || candidate < best!) {
                        best = candidate
                    }
                }
                if base >= raw { break }
                n += 1
            }
            return best
        }

        let imageA = try session.newImage(width: 512, height: 320)
        let imageB = try session.newImage(width: 80, height: 50)
        let docA = try ImageDocument(session: session, image: imageA, name: "Rulers A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Rulers B")
        documents.items += [docA, docB]
        let a = DocumentWindowController(document: docA)
        let b = DocumentWindowController(document: docB)
        a.showWindow(nil)
        b.showWindow(nil)
        a.window?.contentView?.layoutSubtreeIfNeeded()
        b.window?.contentView?.layoutSubtreeIfNeeded()
        defer {
            for (controller, document) in [(a, docA), (b, docB)] {
                controller.window?.close()
                documents.items.removeAll { $0 === document }
                document.closeImageWhenDrained()
            }
        }

        let scrollA = a.scrollView
        let scrollB = b.scrollView
        guard let hRuler = scrollA.horizontalRulerView as? PixelRulerView,
              let vRuler = scrollA.verticalRulerView as? PixelRulerView else {
            return check(false, "the scroll view's native ruler slots hold the pixel rulers")
        }
        check(scrollA.horizontalRulerView === a.horizontalRuler
                && scrollA.verticalRulerView === a.verticalRuler,
              "the window's rulers sit in the scroll view's native ruler slots")
        check(!scrollA.contentView.frame.intersects(hRuler.frame)
                && !scrollA.contentView.frame.intersects(vRuler.frame),
              "native ruler rectangles stay outside the editable viewport")
        check(scrollA.hasHorizontalRuler && scrollA.hasVerticalRuler && scrollA.rulersVisible
                && scrollB.rulersVisible,
              "rulers are on by default in both windows")
        check(hRuler.accessibilityLabel() == "Horizontal ruler"
                && vRuler.accessibilityLabel() == "Vertical ruler",
              "the rulers carry meaningful accessibility labels")

        // Menu wiring: View ▸ Show Rulers on the document's own selector.
        let mainMenu = MainMenu.make()
        let viewMenu = mainMenu.items.first { $0.title == "View" }?.submenu
        check(viewMenu?.items.first { $0.title == "Show Rulers" }?.action
                == #selector(DocumentWindowController.toggleShowRulers(_:)),
              "View offers Show Rulers on the document's selector")
        let rulersItem = NSMenuItem(title: "Show Rulers",
                                    action: #selector(DocumentWindowController.toggleShowRulers(_:)),
                                    keyEquivalent: "")
        check(a.validateMenuItem(rulersItem) && rulersItem.state == .on,
              "Show Rulers validates checked by default")

        // Busy-independent toggle: hold the engine and flip anyway; on/off
        // changes the viewport because the rulers occupy the native slots.
        a.window?.contentView?.layoutSubtreeIfNeeded()
        let viewportWithRulers = scrollA.contentView.bounds
        let gate = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Holding the engine", work: { gate.wait() },
                                                 completion: {})
        check(held, "the engine can be held busy")
        check(a.validateMenuItem(rulersItem), "Show Rulers validates while the engine is busy")
        a.toggleShowRulers(rulersItem)
        check(rulersItem.state == .off && !a.rulerViewState.showsRulers && !scrollA.rulersVisible,
              "Show Rulers toggles off while the engine is busy")
        a.window?.contentView?.layoutSubtreeIfNeeded()
        spin(0.05)
        let viewportHidden = scrollA.contentView.bounds
        check(viewportHidden.height > viewportWithRulers.height + 1
                && viewportHidden.width > viewportWithRulers.width + 1,
              "hiding the rulers gives the viewport back the ruler thickness (\(viewportWithRulers) -> \(viewportHidden); ruler frames \(hRuler.frame), \(vRuler.frame); clip \(scrollA.contentView.frame))")
        a.toggleShowRulers(rulersItem)
        check(rulersItem.state == .on && a.rulerViewState.showsRulers && scrollA.rulersVisible,
              "Show Rulers toggles back on while the engine is still busy")
        gate.signal()
        wait { !EngineActivity.shared.isBusy }
        a.window?.contentView?.layoutSubtreeIfNeeded()
        spin(0.05)
        check(abs(scrollA.contentView.bounds.height - viewportWithRulers.height) < 1,
              "showing the rulers takes the thickness back from the viewport")

        // Two windows keep independent state and checkmarks.
        let bItem = NSMenuItem(title: "Show Rulers",
                              action: #selector(DocumentWindowController.toggleShowRulers(_:)),
                              keyEquivalent: "")
        a.toggleShowRulers(rulersItem)
        check(!a.rulerViewState.showsRulers && !scrollA.rulersVisible
                && b.rulerViewState.showsRulers && scrollB.rulersVisible
                && b.validateMenuItem(bItem) && bItem.state == .on,
              "toggling one window leaves the other's ruler state and checkmark alone")
        a.toggleShowRulers(rulersItem)
        check(a.rulerViewState.showsRulers && scrollA.rulersVisible,
              "the first window toggles back on independently")

        // Ticks follow scroll/zoom/origin against the independent oracle.
        let canvas = a.canvas
        let clip = scrollA.contentView
        func layout() {
            a.window?.contentView?.layoutSubtreeIfNeeded()
            spin(0.05)
        }
        func oracleVisibleXRange() -> (Double, Double) {
            let bounds = clip.bounds
            let scale = canvas.scale
            return (bounds.origin.x / scale, (bounds.origin.x + bounds.width) / scale)
        }
        func rulerMapping() -> (origin: Double, perPixel: Double) {
            let o = hRuler.convert(CGPoint.zero, from: canvas)
            let u = hRuler.convert(CGPoint(x: canvas.scale, y: canvas.scale), from: canvas)
            return (o.x, u.x - o.x)
        }
        func checkHorizontalPlan(_ label: String) {
            guard let plan = hRuler.currentPlan() else {
                return check(false, "\(label): the horizontal ruler plans nothing at sane geometry")
            }
            let positions = plan.ticks.map(\.imagePosition)
            check(plan.ticks.count <= PixelRulerPlan.maximumTicks, "\(label): the plan is capped")
            check(positions == positions.sorted(), "\(label): ticks are sorted")
            check(positions.allSatisfy(\.isFinite), "\(label): ticks are finite")
            check(positions.allSatisfy { $0 >= -1e-9 && $0 <= Double(docA.info.width) + 1e-9 },
                  "\(label): ticks stay inside the image extent")
            check(plan.majorSpacing == oracleMajorSpacing(pointsPerPixel: canvas.scale),
                  "\(label): major spacing matches the independent nice-spacing oracle")
            check(plan.ticks.filter(\.isMajor).allSatisfy { tick in
                let m = tick.imagePosition / plan.majorSpacing
                return abs(m - m.rounded()) < 1e-6
            }, "\(label): majors land on whole multiples of the spacing")
            let tickSpacing = plan.minorSpacing ?? plan.majorSpacing
            let range = oracleVisibleXRange()
            let lo = max(range.0, 0), hi = min(range.1, Double(docA.info.width))
            if lo <= hi, let first = positions.first, let last = positions.last {
                check(first <= lo + tickSpacing + 1e-9 && last >= hi - tickSpacing - 1e-9,
                      "\(label): the first and last ticks bracket the visible image range")
            }
        }
        layout()
        checkHorizontalPlan("at rest")

        // The image origin maps through NSView conversion from the canvas:
        // one image pixel is exactly the canvas's point scale on the axis.
        let restMapping = rulerMapping()
        check(abs(restMapping.perPixel - canvas.scale) < 1e-9,
              "one image pixel maps to the canvas's point scale on the ruler axis")

        // Zoom rescales the ticks to the new point scale.
        a.zoom(to: 800)
        layout()
        checkHorizontalPlan("at 800%")

        // Scrolling moves the visible range and the first tick by the
        // scrolled image pixels (oracle: clip bounds over the point scale).
        let before = clip.bounds
        let proposed = NSRect(x: before.origin.x + 13, y: before.origin.y,
                              width: before.width, height: before.height)
        let expectedOriginX = clip.constrainBoundsRect(proposed).origin.x
        let firstTickBefore = hRuler.currentPlan()?.ticks.first?.imagePosition
        let tickSpacingBefore = hRuler.currentPlan().map { $0.minorSpacing ?? $0.majorSpacing } ?? 1
        clip.scroll(to: NSPoint(x: expectedOriginX, y: before.origin.y))
        layout()
        check(expectedOriginX > before.origin.x + 1,
              "the zoomed ruler fixture actually scrolls")
        let stableOffset = clip.bounds.origin
        for _ in 0..<3 { scrollA.tile() }
        check(abs(clip.bounds.origin.x - stableOffset.x) < 1e-6
                && abs(clip.bounds.origin.y - stableOffset.y) < 1e-6,
              "repeated ruler layout preserves the scrolled position")
        let rangeAfterScroll = oracleVisibleXRange()
        check(abs(rangeAfterScroll.0 - expectedOriginX / canvas.scale) < 1e-6,
              "the visible image range follows the actual scroll offset")
        if let t0 = firstTickBefore, let t1 = hRuler.currentPlan()?.ticks.first?.imagePosition {
            let deltaPixels = (expectedOriginX - before.origin.x) / canvas.scale
            check(abs((t1 - t0) - deltaPixels) <= tickSpacingBefore + 1e-6,
                  "scrolling moves the first visible tick by the scrolled image pixels")
        } else {
            check(false, "the first visible tick is present before and after scrolling")
        }

        a.zoom(to: 200)
        layout()
        checkHorizontalPlan("at 200%")
        check(hRuler.currentPlan()?.majorSpacing == oracleMajorSpacing(pointsPerPixel: canvas.scale)
                && abs(canvas.scale - CanvasGeometry.pointScale(zoomPercent: 200,
                                                                backingFactor: Double(a.window?.backingScaleFactor ?? 2))) < 1e-9,
              "zoom rescales the tick spacing to the oracle spacing at the new point scale")

        // The ruler's own view bitmap draws a dark tick where the geometry
        // oracle places a major (bitmap rows match the flipped ruler's y).
        if let plan = hRuler.currentPlan(), let major = plan.ticks.first(where: { $0.isMajor }) {
            func bitmapGray(_ x: Double, _ y: Double) -> Double? {
                guard let rep = hRuler.bitmapImageRepForCachingDisplay(in: hRuler.bounds) else { return nil }
                hRuler.cacheDisplay(in: hRuler.bounds, to: rep)
                let factor = Double(rep.pixelsWide) / Double(hRuler.bounds.width)
                let px = Int(x * factor), py = Int(y * factor)
                guard px >= 0, py >= 0, px < rep.pixelsWide, py < rep.pixelsHigh else { return nil }
                return (rep.colorAt(x: px, y: py)?.usingColorSpace(.genericGray)?.whiteComponent).map(Double.init)
            }
            let map = rulerMapping()
            let backing = Double(a.window?.backingScaleFactor ?? 2)
            let tickX = PixelRulerGeometry.deviceAligned(map.origin + major.imagePosition * map.perPixel,
                                                         backingFactor: backing)
            let midX = tickX + plan.majorSpacing * map.perPixel / 2
            let y = hRuler.bounds.height - 2
            let tickGray = [tickX - 1, tickX, tickX + 1].compactMap { bitmapGray($0, y) }.min()
            let midGray = [midX - 1, midX, midX + 1].compactMap { bitmapGray($0, y) }.min()
            check(tickGray != nil && midGray != nil && tickGray! < midGray! - 0.2,
                  "the ruler's view bitmap draws a tick where the oracle places a major (\(String(describing: tickGray)) vs \(String(describing: midGray)))")
        } else {
            check(false, "a major tick is visible at 200% for the bitmap check")
        }

        // Display-only isolation: toggling, scrolling and zooming change no
        // engine pixels, undo step, dirty flag or selection, and the Guides
        // overlay state is untouched.
        let pxBefore = pixel(session, imageA, x: 7, y: 9)
        let undoBefore = docA.undoInfo.undoCount
        let dirtyBefore = docA.hasUnsavedChanges
        let selectionBefore = docA.selectionOutline
        let guidesBefore = a.guidesViewState.showsGuides
        a.toggleShowRulers(rulersItem)
        a.toggleShowRulers(rulersItem)
        clip.scroll(to: NSPoint(x: 3, y: 2))
        a.zoom(to: 150)
        layout()
        a.zoom(to: 100)
        layout()
        check(pixel(session, imageA, x: 7, y: 9) == pxBefore,
              "ruler toggling, scrolling and zooming leave the engine's pixels unchanged")
        check(docA.undoInfo.undoCount == undoBefore && docA.hasUnsavedChanges == dirtyBefore
                && docA.selectionOutline == selectionBefore,
              "ruler display adds no undo step, dirty flag or selection change")
        check(a.guidesViewState.showsGuides == guidesBefore && canvas.showsGuides == guidesBefore,
              "the Guides overlay state is unaffected by ruler toggles")

        // Close is safe and removes the ruler observations.
        check(a.rulerObserversActive, "the ruler geometry observers are registered while open")
        a.window?.close()
        spin(0.1)
        check(!a.rulerObserversActive, "closing the window removes the ruler observers")
    }

    /// Direct guide gestures with real NSEvents dispatched to the actual
    /// ruler and canvas handlers: ruler drags create the matching
    /// horizontal/vertical guide at the dropped image pixel, the Move tool
    /// grabs a visible guide within its view-point tolerance and an
    /// intentional release outside the image removes it, and Escape, tool
    /// change, window close and engine-busy cancel without any native
    /// mutation. Geometry is checked against an independent
    /// frame-arithmetic oracle and the canvas view bitmap at zoom+scroll;
    /// every commit is exactly one undo step and ghosts/cancels leave the
    /// native render pixels and history untouched.
    private static func exerciseCanvasOverlays(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 48, height: 32)
        guard let layer = try session.layers(image).first?.id else {
            try session.closeImage(image)
            return check(false, "the overlay fixture has a layer")
        }
        try session.moveLayer(layer, image: image, by: CGSize(width: 7, height: 0))
        try session.select(.rectangle(CGRect(x: 12, y: 8, width: 20, height: 16)), image: image)
        let document = try ImageDocument(session: session, image: image, name: "Canvas overlays")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        defer {
            controller.window?.close()
            documents.items.removeAll { $0 === document }
            var closed = false
            document.closeImageWhenDrained { closed = true }
            let deadline = Date().addingTimeInterval(10)
            while !closed && Date() < deadline { spin(0.01) }
            check(closed && (try? session.info(image)) == nil, "the overlay test closes its image")
        }
        document.refreshSelection()
        let canvas = controller.canvas
        try canvas.renderVisibleTilesNow()
        func bitmap() -> Data? {
            guard let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return nil }
            canvas.cacheDisplay(in: canvas.bounds, to: rep)
            guard let bytes = rep.bitmapData else { return nil }
            return Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
        }
        let boundary = NSMenuItem(title: "Show Layer Boundary",
                                  action: #selector(DocumentWindowController.toggleLayerBoundary(_:)), keyEquivalent: "")
        let edges = NSMenuItem(title: "Show Selection Edges",
                               action: #selector(DocumentWindowController.toggleSelectionEdges(_:)), keyEquivalent: "")
        check(controller.validateMenuItem(boundary) && boundary.state == .off
                && controller.validateMenuItem(edges) && edges.state == .on,
              "layer boundaries start hidden and selection edges start visible")
        let view = MainMenu.make().items.first { $0.title == "View" }?.submenu
        check(view?.items.contains { $0.action == boundary.action } == true
                && view?.items.contains { $0.action == edges.action } == true,
              "View wires both overlay controls to document actions")
        let pixels = try session.copyPixels(image, merged: true).pixels
        let selection = try session.selectionBounds(image: image)
        let outline = document.selectionOutline
        let dirty = document.hasUnsavedChanges
        let undo = document.undoInfo
        let withEdges = bitmap()
        controller.toggleSelectionEdges(edges)
        let withoutEdges = bitmap()
        check(withEdges != nil && withoutEdges != nil && withEdges != withoutEdges
                && !canvas.showsSelectionEdges && edges.state == .off,
              "hiding selection edges removes the marching ants from the view bitmap")
        controller.toggleLayerBoundary(boundary)
        let withBoundary = bitmap()
        let otherCanvas = EngineCanvasView(document: document)
        check(!otherCanvas.showsLayerBoundary && otherCanvas.showsSelectionEdges,
              "a separate canvas keeps its default visibility settings")
        check(withBoundary != nil && withBoundary != withoutEdges
                && canvas.showsLayerBoundary && boundary.state == .on,
              "showing the offset layer boundary changes the view bitmap")
        controller.toggleLayerBoundary(boundary)
        check(bitmap() == withoutEdges, "hiding the layer boundary restores the view bitmap")
        controller.toggleSelectionEdges(edges)
        check(canvas.showsSelectionEdges && edges.state == .on && bitmap() != withoutEdges,
              "selection edges can be shown again without changing the selection")
        check(try session.copyPixels(image, merged: true).pixels == pixels
                && session.selectionBounds(image: image) == selection
                && document.selectionOutline == outline && document.hasUnsavedChanges == dirty
                && document.undoInfo == undo,
              "overlay switches preserve pixels, selection, dirty state and history")
        let held = DispatchSemaphore(value: 0)
        let accepted = EngineActivity.shared.perform(label: "Overlay busy check", work: { held.wait() }, completion: {})
        let canToggle = controller.validateMenuItem(boundary) && controller.validateMenuItem(edges)
        controller.toggleLayerBoundary(boundary)
        held.signal()
        let deadline = Date().addingTimeInterval(10)
        while EngineActivity.shared.isBusy && Date() < deadline { spin(0.01) }
        check(accepted && canToggle && canvas.showsLayerBoundary,
              "view-only overlay switches remain available while engine work is busy")
    }

    /// Image ▸ Mode ▸ Indexed… end to end through the actual policy sheet:
    /// the cached menu gates and checkmark (already indexed, busy, preview,
    /// attached sheet, u8-non-linear precision, no groups), the sheet's own
    /// palette/dither controls queried by accessibility label, Generated and
    /// Custom conversions pinned against independent session pixel/mode/undo
    /// oracles, Cancel and invalid custom input changing nothing, Dither
    /// text consent (Back / Cancel mutate nothing, explicit confirm
    /// rasterizes and undo restores), BUSY refusal, the exclusive count and
    /// the global accepted-input drain, two documents keeping their captured
    /// owner across a retarget, and late close safety while accepted work
    /// remains counted and drained.
    private static func exerciseIndexedControls(_ session: EngineSession, work: URL,
                                                documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func ok(_ result: Result<Void, Error>?) -> Bool {
            if case .success? = result { return true }
            return false
        }
        func failed(_ result: Result<Void, Error>?) -> Bool {
            if case .failure? = result { return true }
            return false
        }
        func views<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, as: type) }
        }
        func button(_ root: NSView?, _ label: String) -> NSButton? {
            views(root, as: NSButton.self).first { $0.accessibilityLabel() == label }
        }
        // The form's own action row, scoped so the consent region's Cancel
        // does not shadow it in label queries.
        func formButton(_ root: NSView?, _ label: String) -> NSButton? {
            guard let actions = views(root, as: NSStackView.self)
                .first(where: { $0.accessibilityLabel() == "Indexed actions" }) else { return nil }
            return views(actions, as: NSButton.self).first { $0.accessibilityLabel() == label }
        }
        func popup(_ root: NSView?, _ label: String) -> NSPopUpButton? {
            views(root, as: NSPopUpButton.self).first { $0.accessibilityLabel() == label }
        }
        func field(_ root: NSView?, _ label: String) -> NSTextField? {
            views(root, as: NSTextField.self).first { $0.isEditable && $0.accessibilityLabel() == label }
        }
        func checkbox(_ root: NSView?, _ label: String) -> NSButton? {
            views(root, as: NSButton.self).first { $0.accessibilityLabel() == label }
        }
        func message(_ root: NSView?) -> NSTextField? {
            views(root, as: NSTextField.self)
                .first { !$0.isEditable && $0.accessibilityLabel() == "Indexed conversion message" }
        }
        func customText(_ root: NSView?) -> NSTextView? {
            views(root, as: NSTextView.self).first { $0.accessibilityLabel() == "Custom palette colors" }
        }
        func confirmation(_ root: NSView?) -> NSBox? {
            views(root, as: NSBox.self).first { $0.accessibilityLabel() == "Rasterization confirmation" }
        }
        func select(_ popup: NSPopUpButton?, _ title: String) {
            popup?.selectItem(withTitle: title)
            if let popup, let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
        }
        func openSheet(_ controller: DocumentWindowController) -> NSWindow? {
            controller.convertImageToIndexed(nil)
            return controller.window?.attachedSheet
        }
        func indexedItem() -> NSMenuItem {
            NSMenuItem(title: "Indexed…", action: #selector(DocumentWindowController.convertImageToIndexed(_:)),
                       keyEquivalent: "")
        }
        // Independent session oracles — never mirrors of the cached state.
        func nativeMode(_ image: Int32) -> EngineSession.ColorMode? { try? session.colorInfo(image).mode }
        func nativeUndoCount(_ image: Int32) -> Int { (try? session.undoInfo(image).undoCount) ?? -1 }
        func nativeLayerKind(_ image: Int32, _ id: Int32) -> EngineSession.LayerKind? {
            try? session.layers(image).first(where: { $0.id == id })?.kind
        }

        // A red image gives the conversions pixels to judge.
        let image = try session.newImage(width: 32, height: 24)
        try session.select(.all, image: image)
        try session.fill(image: image, at: .zero, mode: .selection, color: .red)
        let document = try ImageDocument(session: session, image: image, name: "Indexed")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        defer {
            if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
            documents.items.removeAll { $0 === document }
            document.closeImageWhenDrained()
            controller.window?.close()
        }

        // Cached menu gates: enabled and unchecked on an RGB u8 flat image.
        var item = indexedItem()
        check(controller.validateMenuItem(item) && item.state == .off && item.toolTip == nil,
              "Indexed… validates enabled and unchecked on an RGB u8 flat image")

        // A filter preview owns the image: the item is unavailable meanwhile.
        controller.gaussianBlur(nil)
        wait { controller.previewPanel != nil }
        item = indexedItem()
        check(!controller.validateMenuItem(item), "Indexed… is disabled while a filter preview is open")
        controller.cancelOperation(nil)
        wait { !document.filterPreviewIsOpen }

        // The sheet opens through the actual action and disables the item.
        var sheet = openSheet(controller)
        check(sheet != nil && controller.indexedSheet != nil, "Indexed… opens the policy sheet on its window")
        item = indexedItem()
        check(!controller.validateMenuItem(item), "Indexed… is disabled while its sheet is attached")

        // The palette and dither popups carry the form's choices; every
        // control is reachable by its accessibility label.
        let content = sheet?.contentView
        check(popup(content, "Palette")?.itemTitles == ["Generated", "Web", "Monochrome", "Custom"],
              "the Palette popup offers Generated/Web/Monochrome/Custom")
        check(popup(content, "Dithering")?.itemTitles == ["None", "FS", "Reduced Bleeding", "Ordered"],
              "the Dithering popup offers None/FS/Reduced Bleeding/Ordered")
        check(field(content, "Maximum colors") != nil && customText(content) != nil
                && checkbox(content, "Remove unused colors") != nil
                && checkbox(content, "Dither transparency") != nil && checkbox(content, "Dither text") != nil
                && formButton(content, "Convert") != nil && formButton(content, "Cancel") != nil,
              "every form control is reachable by its accessibility label")
        check(checkbox(content, "Remove unused colors")?.isEnabled == false
                && field(content, "Maximum colors")?.isEnabled == true
                && customText(content)?.isEditable == false,
              "Generated enables only the maximum-colors field")
        select(popup(content, "Palette"), "Web")
        check(checkbox(content, "Remove unused colors")?.isEnabled == true
                && field(content, "Maximum colors")?.isEnabled == false,
              "Web enables Remove unused colors and disables the color count")
        select(popup(content, "Palette"), "Custom")
        check(customText(content)?.isEditable == true && checkbox(content, "Remove unused colors")?.isEnabled == true,
              "Custom enables the palette text and Remove unused colors")
        select(popup(content, "Palette"), "Generated")

        // Cancel queues nothing and mutates nothing.
        var undoBefore = document.undoInfo.undoCount
        formButton(content, "Cancel")?.performClick(nil)
        spin()
        check(controller.window?.attachedSheet == nil && controller.indexedSheet == nil,
              "Cancel closes the sheet")
        check(document.undoInfo.undoCount == undoBefore && document.pendingWork == 0
                && document.colorInfo.mode == .rgb,
              "Cancel changes nothing")

        // An invalid custom palette: inline error, no mutation, no close.
        sheet = openSheet(controller)
        let invalidContent = sheet?.contentView
        select(popup(invalidContent, "Palette"), "Custom")
        customText(invalidContent)?.string = "#FFF\n#GGGGGG"
        formButton(invalidContent, "Convert")?.performClick(nil)
        spin()
        check(controller.window?.attachedSheet === sheet,
              "an invalid custom palette keeps the sheet open")
        check(!(message(invalidContent)?.stringValue ?? "").isEmpty,
              "an invalid custom palette shows an inline error")
        check(document.undoInfo.undoCount == undoBefore && document.pendingWork == 0
                && document.colorInfo.mode == .rgb,
              "an invalid custom palette mutates nothing")

        // A valid custom palette (blank line allowed): converts, pins the
        // native mode, pixels and one undo step, then closes the sheet.
        customText(invalidContent)?.string = "#FF0000\n\n#00FF00"
        var depth = try session.undoInfo(image).undoCount
        formButton(invalidContent, "Convert")?.performClick(nil)
        wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(nativeMode(image) == .indexed,
              "the custom conversion makes the engine image indexed (session oracle)")
        check(document.colorInfo.mode == .indexed, "the reload caches the indexed mode")
        check(nativeUndoCount(image) == depth + 1, "the custom conversion is one undo step")
        check(pixel(session, image, x: 8, y: 8) == [255, 0, 0, 255],
              "the red pixel quantizes to the custom #FF0000 entry (\(pixel(session, image, x: 8, y: 8) ?? []))")
        check(controller.window?.attachedSheet == nil && controller.indexedSheet == nil,
              "a successful conversion closes the sheet")
        item = indexedItem()
        check(!controller.validateMenuItem(item) && item.state == .on,
              "the item is checked and disabled once the image is indexed")
        document.undo()
        wait { document.pendingWork == 0 }
        spin()
        check(nativeMode(image) == .rgb
                && pixel(session, image, x: 8, y: 8) == [255, 0, 0, 255],
              "undo restores RGB and the original pixels")
        check(controller.validateMenuItem(indexedItem()) , "the item validates again after undo")

        // Reject malformed numeric text instead of silently parsing a prefix.
        sheet = openSheet(controller)
        let malformedContent = sheet?.contentView
        depth = nativeUndoCount(image)
        field(malformedContent, "Maximum colors")?.stringValue = "12px"
        formButton(malformedContent, "Convert")?.performClick(nil)
        wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(nativeMode(image) == .rgb && nativeUndoCount(image) == depth
                && controller.window?.attachedSheet === sheet
                && !(message(malformedContent)?.stringValue ?? "").isEmpty,
              "a malformed maximum-color count is refused visibly without conversion")
        // Keep subsequent checks independent when this regression fails.
        if nativeMode(image) == .indexed {
            document.undo()
            wait { document.pendingWork == 0 }
            spin()
        } else {
            formButton(malformedContent, "Cancel")?.performClick(nil)
            spin()
        }

        // Generated with a checked maximum color count.
        sheet = openSheet(controller)
        let genContent = sheet?.contentView
        field(genContent, "Maximum colors")?.stringValue = "16"
        depth = try session.undoInfo(image).undoCount
        formButton(genContent, "Convert")?.performClick(nil)
        wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(nativeMode(image) == .indexed
                && nativeUndoCount(image) == depth + 1
                && pixel(session, image, x: 8, y: 8) == [255, 0, 0, 255],
              "the generated conversion pins native mode, pixels and one undo step")
        check(controller.window?.attachedSheet == nil, "the generated conversion closes the sheet")
        document.undo()
        wait { document.pendingWork == 0 }
        spin()
        check(nativeMode(image) == .rgb, "undo restores RGB after the generated conversion")

        // BUSY: a typed call refuses without queueing, and Apply in an open
        // sheet shows the refusal inline and keeps the sheet open.
        sheet = openSheet(controller)
        let busyContent = sheet?.contentView
        let gate = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Holding the engine", work: { gate.wait() },
                                                 completion: {})
        check(held, "the controlled admission pause takes the engine gate")
        item = indexedItem()
        check(!controller.validateMenuItem(item), "Indexed… is disabled while the engine is busy")
        var busySettings = EngineSession.IndexedSettings()
        busySettings.palette = .generated
        var busyResult: Result<Void, Error>?
        document.convertToIndexed(settings: busySettings) { busyResult = $0 }
        spin()
        check(failed(busyResult) && document.pendingWork == 0 && document.colorInfo.mode == .rgb,
              "a typed conversion refuses while the engine is busy without queueing (\(busyResult as Any))")
        // Dispatch a stale action directly; a disabled button correctly
        // ignores performClick and cannot exercise the action's guard.
        if let convert = formButton(busyContent, "Convert"), let action = convert.action {
            NSApp.sendAction(action, to: convert.target, from: convert)
        }
        spin()
        check(!(message(busyContent)?.stringValue ?? "").isEmpty
                && controller.window?.attachedSheet === sheet
                && formButton(busyContent, "Convert")?.isEnabled == false,
              "Apply while busy shows an inline error, disables Convert and keeps the sheet open")
        check(document.colorInfo.mode == .rgb && document.undoInfo.undoCount == depth,
              "the busy Apply mutates nothing")
        formButton(busyContent, "Cancel")?.performClick(nil)
        spin()
        gate.signal()
        wait { !EngineActivity.shared.isBusy }

        // The exclusive count and the global accepted-input drain: another
        // document's accepted input lands first and its later edits refuse.
        let otherImage = try session.newImage(width: 16, height: 16)
        let other = try ImageDocument(session: session, image: otherImage, name: "Indexed other")
        documents.items.append(other)
        defer {
            documents.items.removeAll { $0 === other }
            other.closeImageWhenDrained()
        }
        let inputGate = DispatchSemaphore(value: 0)
        other.inputQueue.async { inputGate.wait() }
        other.beginStroke(at: .init(x: 8, y: 8, pressure: 1))
        other.endStroke()
        sheet = openSheet(controller)
        let drainContent = sheet?.contentView
        let drainSheet = controller.indexedSheet
        depth = try session.undoInfo(image).undoCount
        formButton(drainContent, "Convert")?.performClick(nil)
        check(document.pendingWork > 0 && EngineActivity.shared.isBusy,
              "the conversion is counted while accepted input drains")
        other.beginStroke(at: .init(x: 4, y: 4, pressure: 1))
        check(!other.strokeIsActive, "the other document's edits refuse behind the conversion gate")
        if other.strokeIsActive { other.endStroke() }
        inputGate.signal()
        wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(ok(drainSheet?.lastResult) && nativeMode(image) == .indexed
                && nativeUndoCount(image) == depth + 1,
              "the conversion completes behind the other document's accepted input as one undo step")
        check((pixel(session, otherImage, x: 8, y: 8)?[0] ?? 255) < 128,
              "the accepted stroke in the other document survived the drain")
        document.undo()
        wait { document.pendingWork == 0 }
        spin()
        check(nativeMode(image) == .rgb, "undo restores RGB after the drained conversion")

        // Editable text with Dither text off: converts and stays editable.
        let textImage = try session.newImage(width: 96, height: 64)
        var textSettings = EngineSession.TextSettings()
        textSettings.size = 24
        let textID = try session.addTextLayer(image: textImage, text: "Editable",
                                             settings: textSettings, at: CGPoint(x: 3, y: 3))
        let textDocument = try ImageDocument(session: session, image: textImage, name: "Indexed text")
        documents.items.append(textDocument)
        let textController = DocumentWindowController(document: textDocument)
        textController.showWindow(nil)
        defer {
            if let open = textController.window?.attachedSheet { textController.window?.endSheet(open) }
            documents.items.removeAll { $0 === textDocument }
            textDocument.closeImageWhenDrained()
            textController.window?.close()
        }
        func textIsEditable() -> Bool {
            (try? session.layers(textImage).first(where: { $0.id == textID })?.kind == .text) == true
                && (try? session.textLayer(image: textImage, layer: textID).text) == "Editable"
        }
        sheet = openSheet(textController)
        var textContent = sheet?.contentView
        check(checkbox(textContent, "Dither text")?.state == .off, "Dither text is off by default")
        var textDepth = try session.undoInfo(textImage).undoCount
        formButton(textContent, "Convert")?.performClick(nil)
        wait { textDocument.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(nativeMode(textImage) == .indexed && textIsEditable()
                && nativeUndoCount(textImage) == textDepth + 1,
              "with Dither text off the text layer stays editable after one undo-step conversion")
        textDocument.undo()
        wait { textDocument.pendingWork == 0 }
        spin()
        check(nativeMode(textImage) == .rgb && textIsEditable(),
              "undo restores RGB with the editable text")

        // Dither text on: the rasterization refusal opens the inline
        // confirmation region in the SAME sheet; nothing mutates yet.
        sheet = openSheet(textController)
        textContent = sheet?.contentView
        checkbox(textContent, "Dither text")?.state = .on
        formButton(textContent, "Convert")?.performClick(nil)
        wait { textDocument.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        var consentBox = confirmation(textContent)
        check(consentBox != nil && consentBox?.isHidden == false,
              "a rasterization refusal opens the inline confirmation region in the same sheet")
        check(button(consentBox, "Rasterize and Convert") != nil && button(consentBox, "Back") != nil
                && button(consentBox, "Cancel") != nil,
              "the confirmation offers Rasterize and Convert / Back / Cancel")
        textContent?.layoutSubtreeIfNeeded()
        let visibleConsent = button(confirmation(textContent)?.contentView, "Rasterize and Convert")
        check(visibleConsent?.isHiddenOrHasHiddenAncestor == false
                && visibleConsent?.visibleRect.isEmpty == false,
              "the rasterization confirmation button occupies visible sheet space")
        check(nativeMode(textImage) == .rgb && textIsEditable()
                && nativeUndoCount(textImage) == textDepth,
              "the consent step mutates nothing")
        check(field(textContent, "Maximum colors")?.isEnabled == false
                && formButton(textContent, "Cancel")?.isEnabled == false,
              "the fields stay disabled and the form Cancel is not offered while consent is pending")

        // Back returns to the form; still no mutation.
        button(consentBox, "Back")?.performClick(nil)
        spin()
        check(confirmation(textContent)?.isHidden == true && field(textContent, "Maximum colors")?.isEnabled == true,
              "Back returns to the editable form")
        check(nativeMode(textImage) == .rgb && textIsEditable(),
              "Back mutates nothing")

        // Consent again, then Cancel: the sheet closes with no mutation.
        formButton(textContent, "Convert")?.performClick(nil)
        wait { textDocument.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        consentBox = confirmation(textContent)
        button(consentBox, "Cancel")?.performClick(nil)
        spin()
        check(textController.window?.attachedSheet == nil, "consent Cancel closes the sheet")
        check(nativeMode(textImage) == .rgb && textIsEditable()
                && nativeUndoCount(textImage) == textDepth && textDocument.pendingWork == 0,
              "consent Cancel mutates nothing")

        // Explicit confirm: allowRasterize on the captured document and the
        // captured settings; accepted work disables the controls and offers
        // no Cancel; undo restores the editable text.
        sheet = openSheet(textController)
        textContent = sheet?.contentView
        checkbox(textContent, "Dither text")?.state = .on
        formButton(textContent, "Convert")?.performClick(nil)
        wait { textDocument.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        consentBox = confirmation(textContent)
        textDocument.inputQueue.async { usleep(400_000) }
        button(consentBox, "Rasterize and Convert")?.performClick(nil)
        check(textDocument.pendingWork > 0
                && field(textContent, "Maximum colors")?.isEnabled == false
                && formButton(textContent, "Cancel")?.isEnabled == false
                && confirmation(textContent)?.isHidden == true,
              "accepted work disables the mutating controls and offers no Cancel")
        wait { textDocument.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(nativeMode(textImage) == .indexed
                && nativeLayerKind(textImage, textID) == .pixel
                && nativeUndoCount(textImage) == textDepth + 1,
              "the confirmed conversion rasterizes the text as one undo step (session oracles)")
        check(textController.window?.attachedSheet == nil, "success after consent closes the sheet")
        textDocument.undo()
        wait { textDocument.pendingWork == 0 }
        spin()
        check(nativeMode(textImage) == .rgb && textIsEditable(),
              "undo restores RGB and the editable text after the consented conversion")

        // Two documents keep their captured owner across a retarget: B
        // frontmost, A's sheet still converts A only.
        let imageA = try session.newImage(width: 24, height: 16)
        let imageB = try session.newImage(width: 24, height: 16)
        try session.select(.all, image: imageA)
        try session.fill(image: imageA, at: .zero, mode: .selection, color: .blue)
        try session.select(.all, image: imageB)
        try session.fill(image: imageB, at: .zero, mode: .selection, color: .red)
        let docA = try ImageDocument(session: session, image: imageA, name: "Indexed A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Indexed B")
        documents.items += [docA, docB]
        let controllerA = DocumentWindowController(document: docA)
        let controllerB = DocumentWindowController(document: docB)
        controllerA.showWindow(nil)
        controllerB.showWindow(nil)
        defer {
            for (c, d) in [(controllerA, docA), (controllerB, docB)] {
                if let open = c.window?.attachedSheet { c.window?.endSheet(open) }
                c.window?.close()
                documents.items.removeAll { $0 === d }
                d.closeImageWhenDrained()
            }
        }
        let sheetA = openSheet(controllerA)
        let sheetB = openSheet(controllerB)
        check(sheetA != nil && sheetB != nil && sheetA !== sheetB && controllerA.indexedSheet !== controllerB.indexedSheet,
              "two documents open independent Indexed sheets owned by their windows")
        controllerB.window?.orderFront(nil)
        spin(0.05)
        formButton(sheetA?.contentView, "Convert")?.performClick(nil)
        wait { docA.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(nativeMode(imageA) == .indexed && nativeMode(imageB) == .rgb,
              "A's sheet converts its captured document A while frontmost B stays RGB")
        let bDepth = docB.undoInfo.undoCount
        formButton(sheetB?.contentView, "Cancel")?.performClick(nil)
        spin()
        check(nativeMode(imageB) == .rgb && docB.pendingWork == 0
                && docB.undoInfo.undoCount == bDepth,
              "B's cancelled sheet changes nothing")

        // Native eligibility gates from cached state: u16 precision and a
        // layer group disable the item and say why; the action refuses too.
        let precImage = try session.newImage(width: 16, height: 16)
        try session.convertPrecision(precImage, component: .u16, trc: .nonlinear)
        let precDocument = try ImageDocument(session: session, image: precImage, name: "Indexed u16")
        documents.items.append(precDocument)
        let precController = DocumentWindowController(document: precDocument)
        precController.showWindow(nil)
        defer {
            documents.items.removeAll { $0 === precDocument }
            precDocument.closeImageWhenDrained()
            precController.window?.close()
        }
        item = indexedItem()
        check(!precController.validateMenuItem(item) && item.toolTip?.contains("8-bit non-linear") == true,
              "Indexed… is disabled with a precision explanation on a u16 image")
        var precErrors: [String] = []
        let oldPrecError = precDocument.onError
        precDocument.onError = { precErrors.append($0); oldPrecError?($0) }
        defer { precDocument.onError = oldPrecError }
        precController.convertImageToIndexed(nil)
        spin()
        check(precController.window?.attachedSheet == nil && !precErrors.isEmpty
                && (try? session.colorInfo(precImage).mode) == .rgb,
              "the action itself refuses a u16 image without opening the sheet or mutating")
        precDocument.onError = oldPrecError

        let groupImage = try session.newImage(width: 16, height: 16)
        _ = try session.createGroup(image: groupImage, index: 0)
        let groupDocument = try ImageDocument(session: session, image: groupImage, name: "Indexed group")
        documents.items.append(groupDocument)
        let groupController = DocumentWindowController(document: groupDocument)
        groupController.showWindow(nil)
        defer {
            documents.items.removeAll { $0 === groupDocument }
            groupDocument.closeImageWhenDrained()
            groupController.window?.close()
        }
        item = indexedItem()
        check(!groupController.validateMenuItem(item) && item.toolTip?.contains("group") == true,
              "Indexed… is disabled with a group explanation on a grouped image")

        // Late close safety: accepted work stays counted while the input
        // drains; ending the sheet invalidates the controller, the late
        // completion still lands exactly once, and the image is destroyed
        // only after the drain.
        let closingImage = try session.newImage(width: 16, height: 16)
        let closing = try ImageDocument(session: session, image: closingImage, name: "Indexed closing")
        documents.items.append(closing)
        let closingController = DocumentWindowController(document: closing)
        closingController.showWindow(nil)
        defer {
            documents.items.removeAll { $0 === closing }
            closing.closeImageWhenDrained()
            closingController.window?.close()
        }
        closing.inputQueue.async { usleep(400_000) }
        let closingSheet = openSheet(closingController)
        let closingSheetRef = closingController.indexedSheet
        formButton(closingSheet?.contentView, "Convert")?.performClick(nil)
        wait { closing.pendingWork > 0 && EngineActivity.shared.isBusy }
        check(closing.pendingWork > 0, "the queued conversion is counted behind the closing document's input drain")
        var closed = false
        closing.closeImageWhenDrained { closed = true }
        if let closingSheet { closingController.window?.endSheet(closingSheet) }
        spin()
        check(closingController.indexedSheet == nil, "ending the sheet releases the window's reference")
        wait { closed && closing.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin()
        check(closed && (try? session.info(closingImage)) == nil,
              "the close destroys the image only after the accepted conversion drained")
        check(ok(closingSheetRef?.lastResult),
              "the late completion still lands exactly once after invalidation (\(closingSheetRef?.lastResult as Any))")
    }

    private static func exerciseLayerSourceCache(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 96, height: 64)
        let text = try session.addTextLayer(image: image, text: "Source", settings: .init(), at: CGPoint(x: 4, y: 4))
        try session.selectLayer(text, image: image)
        let document = try ImageDocument(session: session, image: image, name: "Layer source cache")
        documents.items.append(document)
        var errors: [String] = []
        document.onError = { errors.append($0) }
        func settle() {
            document.inputQueue.sync {}
            let deadline = Date().addingTimeInterval(10)
            while (document.pendingWork > 0 || EngineActivity.shared.isBusy) && Date() < deadline { spin(0.01) }
            spin()
        }
        defer {
            documents.items.removeAll { $0 === document }
            var closed = false
            document.closeImageWhenDrained { closed = true }
            let deadline = Date().addingTimeInterval(10)
            while !closed && Date() < deadline { spin(0.01) }
            check(closed && (try? session.info(image)) == nil, "the source cache image closes before shutdown")
        }
        let source = EngineSession.LayerSource(kind: .text, isRasterized: false, hasSource: true)
        check(document.layerSources[text] == source && document.activeLayer == text,
              "document reload caches the selected text layer's retained-source state")
        let pixels = try session.copyPixels(image, merged: true).pixels
        let undo = document.undoInfo.undoCount
        document.layerCommand(.rasterize)
        settle()
        let raster = EngineSession.LayerSource(kind: .text, isRasterized: true, hasSource: true)
        check(errors.isEmpty && document.layerSources[text] == raster
                && document.layers.first(where: { $0.id == text })?.kind == .pixel,
              "queued Rasterize refreshes source and current content kinds independently")
        check(try document.undoInfo.undoCount == undo + 1
                && session.copyPixels(image, merged: true).pixels == pixels,
              "queued Rasterize keeps pixels identical and adds one undo step")
        document.layerCommand(.rasterize)
        settle()
        check(document.undoInfo.undoCount == undo + 1 && document.layerSources[text] == raster,
              "repeating queued Rasterize is a no-op with the source retained")
        document.undo()
        settle()
        check(document.layerSources[text] == source
                && document.layers.first(where: { $0.id == text })?.kind == .text,
              "undo refreshes the editable text state in the document cache")
        document.redo()
        settle()
        check(document.layerSources[text] == raster && errors.isEmpty,
              "redo refreshes the rasterized retained-source state")
        let baseline = errors.count
        let accepted = EngineActivity.shared.perform(label: "Source busy check", work: {}, completion: {})
        document.layerCommand(.rasterize)
        check(accepted && errors.count == baseline + 1 && document.pendingWork == 0,
              "busy admission refuses Rasterize before queueing input")
        settle()
    }

    /// Layer ▸ Rasterize Layer… / Restore Layer Source…: menu wiring and
    /// cached gating, the per-window confirmation sheets (Cancel changes
    /// nothing, Apply runs on the captured document and explicit layer
    /// id), the counted explicit-id document methods, the exclusive
    /// restore with its global input drain, BUSY refusal, stale-id
    /// NOT_FOUND and late-close safety. Pixel and kind oracles read the
    /// session directly, never the document cache; sheet buttons are
    /// queried by their accessibility labels.
    private static func exerciseLayerSourceControls(_ session: EngineSession, work: URL,
                                                    documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func buttons(in view: NSView?) -> [NSButton] {
            guard let view else { return [] }
            if let button = view as? NSButton { return [button] }
            return view.subviews.flatMap { buttons(in: $0) }
        }
        func alertButton(_ sheet: NSWindow?, _ label: String) -> NSButton? {
            buttons(in: sheet?.contentView).first { $0.accessibilityLabel() == label }
        }
        func endSheet(_ controller: DocumentWindowController, _ response: NSApplication.ModalResponse) {
            wait { controller.window?.attachedSheet != nil }
            if let sheet = controller.window?.attachedSheet {
                NSApp.endSheet(sheet, returnCode: response.rawValue)
            }
        }

        // Document A holds a genuine text layer plus a plain pixel layer;
        // document B only witnesses the global drain.
        let imageA = try session.newImage(width: 96, height: 64)
        let pixelLayer = try session.layerCommand(.new, image: imageA) ?? 0
        let text = try session.addTextLayer(image: imageA, text: "Source", settings: .init(),
                                            at: CGPoint(x: 4, y: 4))
        try session.selectLayer(text, image: imageA)
        let docA = try ImageDocument(session: session, image: imageA, name: "Source A")
        let imageB = try session.newImage(width: 64, height: 64)
        let docB = try ImageDocument(session: session, image: imageB, name: "Source B")
        documents.items += [docA, docB]
        let a = DocumentWindowController(document: docA)
        let b = DocumentWindowController(document: docB)
        a.showWindow(nil)
        b.showWindow(nil)
        var errors: [String] = []
        docA.onError = { errors.append($0) }
        docB.onError = { errors.append($0) }
        func settle() {
            docA.inputQueue.sync {}
            docB.inputQueue.sync {}
            wait { docA.pendingWork == 0 && docB.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        defer {
            for (controller, document) in [(a, docA), (b, docB)] {
                if let sheet = controller.window?.attachedSheet {
                    NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertSecondButtonReturn.rawValue)
                }
                controller.window?.close()
                documents.items.removeAll { $0 === document }
                document.closeImageWhenDrained()
            }
            wait { (try? session.info(imageA)) == nil && (try? session.info(imageB)) == nil }
        }

        // Menu wiring: both commands sit on the Layer menu, on the
        // document window's own sheet selectors.
        let mainMenu = MainMenu.make()
        let layerMenu = mainMenu.items.first { $0.title == "Layer" }?.submenu
        let rasterizeItem = NSMenuItem(title: "Rasterize Layer…",
                                       action: #selector(DocumentWindowController.rasterizeLayer(_:)),
                                       keyEquivalent: "")
        let restoreItem = NSMenuItem(title: "Restore Layer Source…",
                                     action: #selector(DocumentWindowController.restoreLayerSource(_:)),
                                     keyEquivalent: "")
        check(layerMenu?.items.first { $0.title == "Rasterize Layer…" }?.action
                == #selector(DocumentWindowController.rasterizeLayer(_:))
                && layerMenu?.items.first { $0.title == "Restore Layer Source…" }?.action
                == #selector(DocumentWindowController.restoreLayerSource(_:)),
              "the Layer menu lists Rasterize Layer… and Restore Layer Source… on the document's selectors")

        let editable = EngineSession.LayerSource(kind: .text, isRasterized: false, hasSource: true)
        let rasterized = EngineSession.LayerSource(kind: .text, isRasterized: true, hasSource: true)
        check(docA.layerSources[text] == editable && docA.activeLayer == text,
              "the text layer starts editable with its source retained")

        // The ordinary unconfirmed restore route still refuses.
        let bErrors0 = errors.count
        docB.layerCommand(.restoreSource)
        check(errors.count == bErrors0 + 1 && docB.pendingWork == 0,
              "layerCommand(.restoreSource) still refuses unconfirmed calls")

        // Cached gating: an editable text layer offers Rasterize only.
        check(a.validateMenuItem(rasterizeItem) && !a.validateMenuItem(restoreItem),
              "an editable text layer offers Rasterize only")
        docA.selectLayer(pixelLayer)
        settle()
        check(!a.validateMenuItem(rasterizeItem) && !a.validateMenuItem(restoreItem),
              "an ordinary pixel layer offers neither source command")
        docA.selectLayer(text)
        settle()
        check(a.validateMenuItem(rasterizeItem) && !a.validateMenuItem(restoreItem),
              "selecting the text layer again offers Rasterize only")
        // An effective pixel lock (own or inherited) disables the item.
        docA.setLayerLocks(text, .pixels, to: true)
        settle()
        try docA.reload()
        check(!a.validateMenuItem(rasterizeItem), "a pixel-locked text layer disables Rasterize")
        docA.setLayerLocks(text, .pixels, to: false)
        settle()
        try docA.reload()
        check(a.validateMenuItem(rasterizeItem), "unlocking re-enables Rasterize")

        // Sheet Cancel changes nothing; the sheet's buttons are found by
        // their accessibility labels, and both items disable while it is
        // attached.
        let undo0 = docA.undoInfo.undoCount
        let pixels0 = try session.copyPixels(imageA, merged: true).pixels
        a.rasterizeLayer(nil)
        wait { a.window?.attachedSheet != nil }
        let cancelSheet = a.window?.attachedSheet
        check(alertButton(cancelSheet, "Rasterize") != nil && alertButton(cancelSheet, "Cancel") != nil,
              "the rasterize sheet offers labeled Rasterize and Cancel buttons")
        check(!a.validateMenuItem(rasterizeItem) && !a.validateMenuItem(restoreItem),
              "both source items disable while the sheet is attached")
        if let cancelSheet {
            NSApp.endSheet(cancelSheet, returnCode: NSApplication.ModalResponse.alertSecondButtonReturn.rawValue)
        }
        spin(0.15)
        check(docA.pendingWork == 0 && docA.undoInfo.undoCount == undo0
                && docA.layerSources[text] == editable
                && (try? session.copyPixels(imageA, merged: true).pixels) == pixels0,
              "the rasterize sheet's Cancel queues nothing and changes nothing")

        // Sheet Apply rasterizes only the captured explicit id: the
        // selection is retargeted to the pixel layer while the sheet is
        // up, and the other document stays untouched.
        let bLayersBefore = try session.layers(imageB)
        let bPixelsBefore = try session.copyPixels(imageB, merged: true).pixels
        a.rasterizeLayer(nil)
        wait { a.window?.attachedSheet != nil }
        docA.selectLayer(pixelLayer)
        settle()
        check(docA.activeLayer == pixelLayer, "the selection retargets while the sheet is up")
        endSheet(a, .alertFirstButtonReturn)
        wait { docA.layerSources[text]?.isRasterized == true && docA.pendingWork == 0 }
        settle()
        check(docA.undoInfo.undoCount == undo0 + 1, "Rasterize Apply is one undo step")
        check(docA.layerSources[text] == rasterized
                && docA.layers.first(where: { $0.id == text })?.kind == .pixel
                && (try? session.layerSource(text, image: imageA)) == rasterized,
              "Apply updates the cached kind and the session oracle agrees")
        check(docA.layerSources[pixelLayer] == .init(kind: .pixel, isRasterized: false, hasSource: false)
                && docA.activeLayer == pixelLayer
                && docA.layers.first(where: { $0.id == pixelLayer })?.kind == .pixel
                && (try? session.layers(imageB)) == bLayersBefore
                && (try? session.copyPixels(imageB, merged: true).pixels) == bPixelsBefore,
              "retarget-before-Apply and the second document stay untouched")
        docA.selectLayer(text)
        settle()
        check(!a.validateMenuItem(rasterizeItem) && a.validateMenuItem(restoreItem),
              "after rasterize the gating flips: Restore offered, Rasterize not")
        let sourcePixels = try session.copyPixels(imageA, merged: true).pixels
        check(sourcePixels == pixels0, "rasterizing keeps the pixels identical")

        // A pixel stroke on the rasterized layer, as one undo step.
        docA.selectLayer(text)
        settle()
        let undoBeforeStroke = docA.undoInfo.undoCount
        docA.beginStroke(at: .init(x: 8, y: 8, pressure: 1))
        docA.endStroke()
        settle()
        let paintedPixels = try session.copyPixels(imageA, merged: true).pixels
        check(docA.undoInfo.undoCount == undoBeforeStroke + 1 && paintedPixels != sourcePixels,
              "a stroke paints on the rasterized layer as one undo step")

        // BUSY refusal: while a controlled pause holds the engine-wide
        // gate, the explicit restore refuses before queueing, reports,
        // and the menu item disables.
        let gate = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Source controls hold", work: { gate.wait() },
                                                 completion: {})
        check(held && EngineActivity.shared.isBusy, "the controlled pause holds the engine-wide gate")
        var busyResult: Result<Void, Error>?
        let busyErrors = errors.count
        docA.restoreLayerSource(text) { busyResult = $0 }
        if case .failure(ImageDocument.DocumentError.busy) = busyResult {
            check(docA.pendingWork == 0 && errors.count == busyErrors + 1,
                  "a busy restore refuses without queueing and reports busy")
        } else {
            check(false, "a busy restore refuses with busy (got \(String(describing: busyResult)))")
        }
        check(!a.validateMenuItem(restoreItem), "the Restore item disables while the engine is busy")
        gate.signal()
        wait { !EngineActivity.shared.isBusy }
        settle()

        // The restore sheet's Cancel also changes nothing.
        a.restoreLayerSource(nil)
        wait { a.window?.attachedSheet != nil }
        check(alertButton(a.window?.attachedSheet, "Restore") != nil
                && alertButton(a.window?.attachedSheet, "Cancel") != nil,
              "the restore sheet offers labeled Restore and Cancel buttons")
        endSheet(a, .alertSecondButtonReturn)
        spin(0.15)
        check(docA.pendingWork == 0 && docA.layerSources[text] == rasterized
                && docA.undoInfo.undoCount == undoBeforeStroke + 1,
              "the restore sheet's Cancel queues nothing")

        // Accepted input in the other document drains before the restore
        // runs; the admitted restore stays counted until its completion.
        docB.beginStroke(at: .init(x: 20, y: 20, pressure: 1))
        docB.endStroke()
        var restoreResult: Result<Void, Error>?
        let undoBeforeRestore = docA.undoInfo.undoCount
        docA.restoreLayerSource(text) { restoreResult = $0 }
        check(docA.pendingWork == 1, "the admitted restore is counted in pendingWork until completion")
        wait { restoreResult != nil && docA.pendingWork == 0 && !EngineActivity.shared.isBusy }
        settle()
        if case .failure(let error) = restoreResult { check(false, "restore failed: \(error)") }
        check(docA.undoInfo.undoCount == undoBeforeRestore + 1, "Restore is one undo step")
        check(try session.copyPixels(imageA, merged: true).pixels == sourcePixels,
              "Restore after a pixel stroke gives the exact source pixels")
        check(docA.layerSources[text] == editable
                && docA.layers.first(where: { $0.id == text })?.kind == .text
                && (try? session.layerSource(text, image: imageA)) == editable,
              "Restore refreshes the cached kind to editable text")
        check((pixel(session, imageB, x: 20, y: 20)?.first ?? 255) < 128,
              "input accepted in the other document drained before the restore ran")

        // Undo brings the painted pixels back.
        docA.undo()
        settle()
        check(try session.copyPixels(imageA, merged: true).pixels == paintedPixels
                && docA.layerSources[text] == rasterized,
              "undo restores the painted pixels and the rasterized cache")

        // A deleted/stale explicit id reaches native NOT_FOUND and is
        // never retargeted.
        let errorsBeforeStale = errors.count
        var staleResult: Result<Void, Error>?
        docA.rasterizeLayerSource(424242) { staleResult = $0 }
        wait { staleResult != nil && docA.pendingWork == 0 }
        if case .failure(let error as EngineSession.EngineError) = staleResult {
            check(error.isNotFound, "a stale explicit id reports native NOT_FOUND")
        } else {
            check(false, "a stale explicit id fails with NOT_FOUND (got \(String(describing: staleResult)))")
        }
        check(errors.count == errorsBeforeStale + 1 && docA.layerSources[text] == rasterized,
              "the stale id changed nothing, was reported, and never retargeted")

        // Late-close safety: a sheet still up when the document begins
        // closing queues nothing on Apply.
        a.restoreLayerSource(nil)
        wait { a.window?.attachedSheet != nil }
        var closedA = false
        docA.closeImageWhenDrained { closedA = true }
        let errorsBeforeLateApply = errors.count
        endSheet(a, .alertFirstButtonReturn)
        spin(0.2)
        check(docA.pendingWork == 0 && errors.count == errorsBeforeLateApply,
              "a late Apply after close queues nothing and reports nothing")
        wait { closedA }
        check(closedA && (try? session.info(imageA)) == nil,
              "the late-closed document drained and its image is gone")
        documents.items.removeAll { $0 === docA }
    }

    private static func exerciseGuideCache(_ session: EngineSession, documents: DocumentList) throws {
        let image = try session.newImage(width: 96, height: 64)
        let document = try ImageDocument(session: session, image: image, name: "Guide cache")
        documents.items.append(document)
        var errors: [String] = []
        document.onError = { errors.append($0) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        defer {
            documents.items.removeAll { $0 === document }
            var closed = false
            document.closeImageWhenDrained { closed = true }
            wait { closed }
            check(closed && (try? session.info(image)) == nil,
                  "the guide-cache image closes before engine shutdown")
        }
        let pixels = try session.copyPixels(image, merged: true).pixels
        let before = document.undoInfo.undoCount
        check(document.guides.isEmpty, "a new document caches an empty guide list")
        document.addGuide(.horizontal, at: 12)
        settle()
        guard let guide = document.guides.first else {
            return check(false, "the queued add refreshes the guide cache")
        }
        check(guide.orientation == .horizontal && guide.position == 12
                && document.undoInfo.undoCount == before + 1 && errors.isEmpty,
              "queued guide creation refreshes orientation and position with one undo")
        document.moveGuide(guide, to: 24)
        settle()
        check(document.guides.first?.position == 24 && document.undoInfo.undoCount == before + 2,
              "queued guide movement refreshes the cache with one undo")
        document.removeGuide(guide.id)
        settle()
        check(document.guides.isEmpty && document.undoInfo.undoCount == before + 3,
              "queued guide removal refreshes the cache with one undo")
        document.undo()
        settle()
        check(document.guides.count == 1 && document.guides.first?.position == 24,
              "undo restores a removed guide in the document cache")
        let afterGuides = try session.copyPixels(image, merged: true).pixels
        check(afterGuides == pixels, "guide commands and undo leave image pixels unchanged")

        let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let accepted = EngineActivity.shared.perform(label: "Guide cache refresh", work: {
            _ = try? session.putGuide(.init(id: 0, orientation: .vertical, position: 20), image: image)
            _ = try? session.putGuide(.init(id: 0, orientation: .horizontal, position: 40), image: image)
            ready.signal()
            release.wait()
        }, completion: {})
        var started = false
        let deadline = Date().addingTimeInterval(10)
        while !started && Date() < deadline {
            started = ready.wait(timeout: .now()) == .success
            if !started { spin(0.01) }
        }
        spin()
        check(accepted && started && document.guides.count == 1,
              "guide events defer cached native reads while exclusive work is busy")
        let errorCount = errors.count
        document.addGuide(.vertical, at: 30)
        check(errors.count == errorCount + 1 && document.pendingWork == 0,
              "a guide command reports a busy admission without queueing")
        release.signal()
        wait { !EngineActivity.shared.isBusy && document.guides.count == 3 }
        check(document.guides.count == 3,
              "deferred guide events refresh the full cache after exclusive work")
    }

    /// The Gradient tool's Tool Options rows and the actual chooser panel,
    /// wired to the real canvas gradient gesture: selection, Default/reset,
    /// search and lazy previews, missing-identity reporting, close/retarget
    /// invalidation, and the queued resource gradient with undo.
    private static func exerciseGradientChooser(_ session: EngineSession, documents: DocumentList) throws {
        let suite = "ch.lkmc.Glims.smoke.gradientchooser.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = GradientToolStore(defaults: defaults)
        let state = ToolState.shared
        let previousStore = state.gradientStore
        let previousTool = state.current
        let previousFG = state.foreground
        let previousBG = state.background
        state.gradientStore = store
        store.reset()
        defer {
            GradientChooser.shared.close()
            state.gradientStore = previousStore
            state.select(previousTool)
            state.foreground = previousFG
            state.background = previousBG
            defaults.removePersistentDomain(forName: suite)
        }

        let image = try session.newImage(width: 120, height: 80)
        let document = try ImageDocument(session: session, image: image, name: "Gradient chooser")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        var errors: [String] = []
        document.onError = { errors.append($0) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        func views<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            return (root as? T).map { [$0] } ?? root.subviews.flatMap { views($0, as: type) }
        }
        defer {
            controller.window?.close()
            documents.items.removeAll { $0 === document }
            var closed = false
            document.closeImageWhenDrained { closed = true }
            wait { closed }
            check(closed && (try? session.info(image)) == nil,
                  "the gradient-chooser image closes before engine shutdown")
        }

        state.select(.gradient)
        state.foreground = .black
        state.background = .white
        let options = ToolOptionsPaletteController()
        _ = options.view
        options.retarget(to: document)
        func gradientButton() -> NSButton? {
            views(options.view, as: NSButton.self).first { $0.toolTip == "Choose the gradient" }
        }
        func panelButton(_ title: String) -> NSButton? {
            let panel = NSApp.windows.first { $0.title == "Gradient" && $0.isVisible }
            return views(panel?.contentView, as: NSButton.self).first { $0.title == title }
        }

        // The gradient rows: the resource button on the Default, the three
        // shapes, a blend popup with only Perceptual RGB and Lab, Reverse,
        // and opacity.
        check(gradientButton()?.title == "Foreground to Background",
              "Tool Options shows the Foreground-to-Background Default with no explicit choice")
        let popups = views(options.view, as: NSPopUpButton.self)
        let shape = popups.first { $0.numberOfItems == 3 }
        check(shape?.itemTitle(at: 0) == "Linear" && shape?.itemTitle(at: 1) == "Bi-Linear"
                && shape?.itemTitle(at: 2) == "Radial",
              "all three gradient shapes stay available")
        let blend = popups.first { $0.numberOfItems == 2 }
        check(blend?.itemTitle(at: 0) == "Perceptual RGB" && blend?.itemTitle(at: 1) == "Lab",
              "the blend popup offers only Perceptual RGB and Lab (never the UNSUPPORTED RGB Linear)")
        check(views(options.view, as: NSButton.self).contains { $0.title == "Reverse" },
              "the Reverse control shows")

        // Open the actual panel: the full catalog loads off the main thread,
        // with the Default row on top.
        gradientButton()?.performClick(nil)
        wait { GradientChooser.shared.isOpen }
        let panel = NSApp.windows.first { $0.title == "Gradient" && $0.isVisible }
        check(panel != nil, "the gradient chooser opens its owned panel")
        let table = views(panel?.contentView, as: NSTableView.self).first
        let picker = table?.delegate as? GradientChooserPanel
        let catalogCount = try DispatchQueue.global(qos: .userInitiated).sync {
            try session.resources(.gradient).count
        }
        wait { (table?.numberOfRows ?? 0) == catalogCount + 1 && !EngineActivity.shared.isBusy }
        check((table?.numberOfRows ?? 0) == catalogCount + 1 && catalogCount > ResourceThumbnailQueue.batchSize,
              "the actual panel lists the whole native gradient catalog plus the Default row")
        check((table?.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)?.textField?.stringValue
                == "Foreground to Background (Default)",
              "row 0 is the explicit Foreground-to-Background Default")
        check(table?.selectedRow == 0, "with no persisted choice the Default row is selected")
        let firstCell = table?.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView
        wait { firstCell?.imageView?.image != nil && !EngineActivity.shared.isBusy }
        check(firstCell?.textField?.stringValue.isEmpty == false && firstCell?.imageView?.image != nil,
              "actual gradient cells display real names and native previews")

        // Search a catalog gradient beyond the first batch, select it, Choose.
        let chosen = try DispatchQueue.global(qos: .userInitiated).sync {
            () -> (EngineSession.Resource, EngineSession.ResourceIdentity) in
            let rows = try session.resources(.gradient)
            guard let row = rows.last else { throw NoWindow() }
            return (row, try session.resourceIdentifiers(row.id))
        }
        let search = views(panel?.contentView, as: NSSearchField.self)
            .first { $0.accessibilityLabel() == "Search gradients" }
            ?? views(panel?.contentView, as: NSSearchField.self).first
        search?.stringValue = chosen.0.displayName
        if let search, let picker {
            picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: search))
        }
        spin(0.1)
        guard let picker,
              let match = picker.model.rows(matching: chosen.0.displayName)
                  .firstIndex(where: { $0.identity == chosen.1 }) else {
            check(false, "search finds the gradient beyond the first preview batch")
            return
        }
        if let table {
            table.selectRowIndexes(IndexSet(integer: match + 1), byExtendingSelection: false)
            picker.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification,
                                                           object: table))
        }
        let chosenID = picker.model.rows(matching: chosen.0.displayName)[match].id
        wait { picker.model.thumbnail(chosenID) != nil && !EngineActivity.shared.isBusy }
        panelButton("Choose")?.performClick(nil)
        wait { !GradientChooser.shared.isOpen && !EngineActivity.shared.isBusy }
        check(state.gradientResource == chosen.1 && store.preferences.identity == chosen.1,
              "choosing in the real panel persists exactly the selected gradient identity")
        check(gradientButton()?.title == chosen.1.name,
              "Tool Options shows the chosen gradient's real name")
        wait { gradientButton()?.image != nil && !EngineActivity.shared.isBusy }
        check(gradientButton()?.image != nil, "the chosen gradient's identity-tagged preview reaches Tool Options")

        // Explicit reset to the Foreground-to-Background Default (nil).
        views(options.view, as: NSButton.self).first { $0.toolTip == "Reset to the Foreground-to-Background default gradient" }?
            .performClick(nil)
        check(state.gradientResource == nil && store.preferences.identity == nil
                && gradientButton()?.title == "Foreground to Background" && gradientButton()?.image == nil,
              "Reset clears the choice, preview and marker to the Default")

        // A persisted identity the engine cannot resolve is reported as
        // missing, never substituted; closing preserves it.
        let missing = EngineSession.ResourceIdentity(name: "Glims missing gradient", collection: nil, isInternal: false)
        state.setGradientResource(missing)
        gradientButton()?.performClick(nil)
        wait { GradientChooser.shared.isOpen }
        wait { GradientChooser.shared.missingIdentity(choice: missing) != nil && !EngineActivity.shared.isBusy }
        check(gradientButton()?.title == "Missing: Glims missing gradient",
              "the real chooser reports a missing persisted gradient in Tool Options")
        panelButton("Cancel")?.performClick(nil)
        wait { !GradientChooser.shared.isOpen }
        check(state.gradientResource == missing,
              "cancelling preserves the missing choice instead of substituting another resource")

        // A palette retarget closes the open chooser (close-generation
        // invalidation: no late result may restore the stale panel).
        gradientButton()?.performClick(nil)
        wait { GradientChooser.shared.isOpen }
        options.retarget(to: nil)
        check(!GradientChooser.shared.isOpen, "retargeting Tool Options closes the gradient chooser")
        options.retarget(to: document)

        // The real canvas gradient gesture with the chosen resource: one
        // undoable edit through the counted queue.
        state.setGradientResource(chosen.1)
        settle()
        let before = try session.copyPixels(image, merged: true).pixels
        let undoBefore = document.undoInfo.undoCount
        func send(_ type: NSEvent.EventType, _ point: CGPoint) {
            guard let window = controller.window,
                  let event = NSEvent.mouseEvent(
                      with: type, location: controller.canvas.convert(
                          CGPoint(x: point.x * controller.canvas.scale, y: point.y * controller.canvas.scale), to: nil),
                      modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                      eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: controller.canvas.mouseDown(with: event)
            case .leftMouseDragged: controller.canvas.mouseDragged(with: event)
            default: controller.canvas.mouseUp(with: event)
            }
        }
        send(.leftMouseDown, CGPoint(x: 10, y: 40))
        send(.leftMouseDragged, CGPoint(x: 60, y: 40))
        send(.leftMouseUp, CGPoint(x: 110, y: 40))
        settle()
        let afterChosen = try session.copyPixels(image, merged: true).pixels
        check(errors.isEmpty && afterChosen != before
                && document.undoInfo.undoCount == undoBefore + 1,
              "the actual canvas gesture paints the chosen gradient as one undo step")
        document.undo()
        settle()
        check(try session.copyPixels(image, merged: true).pixels == before,
              "undo restores the pixels before the chosen-gradient gesture")

        // The Default (nil choice) uses the built-in FG/BG resource path,
        // and the gesture's colors are captured at the press: a mid-drag
        // color change cannot redirect the queued work.
        state.setGradientResource(nil)
        state.foreground = .black
        state.background = .white
        settle()
        let beforeDefault = try session.copyPixels(image, merged: true).pixels
        let undoDefault = document.undoInfo.undoCount
        send(.leftMouseDown, CGPoint(x: 10, y: 40))
        state.foreground = .red
        state.background = .blue
        send(.leftMouseDragged, CGPoint(x: 60, y: 40))
        send(.leftMouseUp, CGPoint(x: 110, y: 40))
        settle()
        let mid = pixel(session, image, x: 60, y: 40) ?? []
        check(errors.isEmpty && mid.count == 4 && (118...138).contains(Int(mid[0])) && (118...138).contains(Int(mid[1]))
                && document.undoInfo.undoCount == undoDefault + 1,
              "the Default gesture draws the built-in FG-to-BG gradient captured at the press (gray midpoint)")
        document.undo()
        settle()
        check(try session.copyPixels(image, merged: true).pixels == beforeDefault,
              "undo restores the pixels before the Default gesture")
    }

}

@MainActor
final class DocumentList {
    var items: [ImageDocument] = []
    var progressEvents: [EngineSession.Progress?] = []
}
