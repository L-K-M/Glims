import AppKit

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
            try exercisePlugInCommands(session, documents: documents)
            try measurePluginStalls(session, work: work)
        } catch {
            check(false, "unexpected engine error: \(error)")
        }

        print(failures == 0 ? "PASSED" : "FAILED: \(failures) failure(s)")
        return failures == 0 ? 0 : 1
    }

    private static func exerciseDocument(_ session: EngineSession, work: URL,
                                         documents: DocumentList) throws {
        let image = try session.newImage(width: 2400, height: 1600)
        let document = try ImageDocument(session: session, image: image, name: "Smoke")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.window?.orderFront(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        let tilesRendered = try controller.canvas.renderVisibleTilesNow()
        check(tilesRendered > 0, "canvas renders its visible tiles (\(tilesRendered))")
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

    /// The plug-in menus and a plug-in command run through a document
    /// window, without a dialog (with last values), as Filter ▸ Last Filter
    /// runs one.
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
