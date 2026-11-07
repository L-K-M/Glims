import AppKit
import RigiUI

/// Owns the engine and the open documents for an interactive run.
///
/// With an engine library configured (see `EngineLibrary`), the engine
/// starts in the background at launch and a new document opens when it is
/// ready. Without one, the phase 0 workspace with its placeholder canvas is
/// shown and document commands stay disabled.
@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    enum EngineState {
        case unavailable(String)
        case starting
        case running(EngineSession)
        case failed(String)
    }

    static let defaultImageSize = (width: 1600, height: 1200)

    private(set) var state: EngineState = .starting
    private var documents: [DocumentWindowController] = []
    private var workspace: WorkspaceWindowController?
    private var newImagePanel: NewImagePanel?
    private var pendingOpenURLs: [URL] = []
    private var openingURLs: Set<URL> = []
    private var pendingFileOperations = 0
    private var terminationRequested = false
    private let fileWrites = FileWriteCoordinator()
    private var terminationClosingDocument: DocumentWindowController?
    private let openQueue = DispatchQueue(label: "ch.lkmc.Glims.open", qos: .userInitiated)

    private lazy var toolsPalette: Palette = PaletteCenter.shared.palette(
        for: ToolsPaletteController.definition,
        target: { [weak self] in self?.frontDocument },
        makeContent: { ToolsPaletteController() })

    private lazy var toolOptionsPalette: Palette = PaletteCenter.shared.palette(
        for: ToolOptionsPaletteController.definition,
        target: { [weak self] in self?.frontDocument },
        makeContent: { ToolOptionsPaletteController() })

    private lazy var layersPalette: Palette = PaletteCenter.shared.palette(
        for: LayersPaletteController.definition,
        target: { [weak self] in self?.frontDocument },
        makeContent: { LayersPaletteController() })

    private lazy var pathsPalette: Palette = PaletteCenter.shared.palette(
        for: PathsPaletteController.definition,
        target: { [weak self] in self?.frontDocument },
        makeContent: { PathsPaletteController() })

    var frontDocument: ImageDocument? {
        (NSApp.mainWindow?.windowController as? DocumentWindowController)?.imageDocument ?? documents.last?.imageDocument
    }

    var session: EngineSession? {
        if case .running(let session) = state { return session }
        return nil
    }

    /// The first-launch layout (docs/design.md, section 2): Tools at the
    /// top left with Tool Options docked under it as one column, Layers at
    /// the top right. Rigi keeps whatever the person arranges since, and a
    /// frame saved by an earlier build still places its palette once.
    static let defaultPaletteLayout = [
        PaletteGroupDefault([ToolsPaletteController.definition.kind], placement: .topLeading),
        PaletteGroupDefault([ToolOptionsPaletteController.definition.kind],
                            placement: .docked(below: ToolsPaletteController.definition.kind)),
        PaletteGroupDefault([LayersPaletteController.definition.kind, PathsPaletteController.definition.kind],
                            placement: .topTrailing),
    ]

    /// Tab hides every palette and Shift-Tab every palette but Tools; either
    /// brings them back while they are hidden (docs/design.md, rule 8).
    static func togglePalettes(keepingTools: Bool) {
        let center = PaletteCenter.shared
        if center.isHidingPalettes {
            center.restoreAll()
        } else {
            center.hideAll(except: keepingTools ? [ToolsPaletteController.definition.kind] : [])
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(self, selector: #selector(openPendingFiles),
                                               name: PlugInCommands.didFinishNotification, object: nil)
        guard let path = EngineLibrary.configuredPath() else {
            showWorkspace(message: "This build is missing its image engine. Build Glims with scripts/build.sh, or set \(EngineLibrary.environmentVariable) for development.")
            workspace?.canvas.message = "Image engine unavailable"
            state = .unavailable("not configured")
            reportPendingOpenFailure("This build is missing its image engine.")
            return
        }
        showWorkspace(message: "Starting the engine…")
        state = .starting
        let directories = Self.engineDirectories()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result {
                try EngineSession.start(api: EngineLibrary.load(path: path),
                                        userDirectory: directories.user,
                                        cacheDirectory: directories.cache,
                                        onEvent: { event in self?.route(event) })
            }
            DispatchQueue.main.async { self?.engineDidStart(result) }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        guard !documents.isEmpty || pendingFileOperations > 0 else { return .terminateNow }
        terminationRequested = true
        newImagePanel?.close()
        // AppKit expects terminateLater before reply(toApplicationShouldTerminate:).
        DispatchQueue.main.async { self.closeNextDocumentForTermination() }
        return .terminateLater
    }

    private func closeNextDocumentForTermination() {
        guard terminationRequested, terminationClosingDocument == nil, pendingFileOperations == 0 else { return }
        guard let controller = documents.last else {
            terminationRequested = false
            NSApp.reply(toApplicationShouldTerminate: true)
            return
        }
        terminationClosingDocument = controller
        controller.requestClose { [weak self] closed in
            guard let self else { return }
            self.terminationClosingDocument = nil
            if closed {
                self.closeNextDocumentForTermination()
            } else {
                self.terminationRequested = false
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        session?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        session == nil
    }

    /// Glims-owned locations; the user's own GIMP settings are never used.
    static func engineDirectories() -> (user: URL, cache: URL) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return (support.appendingPathComponent("Glims/Engine", isDirectory: true),
                caches.appendingPathComponent("Glims/Engine", isDirectory: true))
    }

    private func engineDidStart(_ result: Result<EngineSession, Error>) {
        switch result {
        case .success(let session):
            state = .running(session)
            if let mainMenu = NSApp.mainMenu, let procedures = try? session.procedures() {
                PlugInMenus.install(procedures, in: mainMenu)
            }
            // The operation catalog is slower: fetched off-main, its menu
            // lands whenever it is ready.
            NativeFilterCatalog.shared.load(using: session)
            workspace?.close()
            workspace = nil
            if pendingOpenURLs.isEmpty {
                createDocument(width: Self.defaultImageSize.width, height: Self.defaultImageSize.height)
            } else {
                let urls = pendingOpenURLs
                pendingOpenURLs.removeAll()
                openFiles(urls)
            }
        case .failure(let error):
            state = .failed(String(describing: error))
            workspace?.canvas.message = "Image engine could not start"
            workspace?.statusBar.message = "The engine did not start: \(error)"
            reportPendingOpenFailure("The engine did not start: \(error)")
        }
    }

    private func reportPendingOpenFailure(_ message: String) {
        guard !pendingOpenURLs.isEmpty else { return }
        let names = pendingOpenURLs.map(\.lastPathComponent).joined(separator: ", ")
        pendingOpenURLs.removeAll()
        let alert = NSAlert()
        alert.messageText = "Could not open \(names)"
        alert.informativeText = message
        if let window = workspace?.window { alert.beginSheetModal(for: window) }
    }

    private func showWorkspace(message: String) {
        let controller = WorkspaceWindowController()
        controller.statusBar.message = message
        controller.showWindow(nil)
        workspace = controller
    }

    private func route(_ event: EngineSession.Event) {
        if case .progress(let progress) = event {
            let running = PlugInCommands.running?.document
            documents.first { $0.imageDocument === running }?.showProgress(progress)
            return
        }
        for controller in documents { controller.imageDocument.handle(event) }
        if case .message(let text) = event {
            (NSApp.mainWindow?.windowController as? DocumentWindowController)?.statusBar.message = text
        }
    }

    func open(_ document: ImageDocument) {
        let controller = DocumentWindowController(document: document)
        controller.reserveWrite = { [weak self, weak controller] url in
            guard let self, let controller else { throw ImageDocument.DocumentError.closed }
            let openFiles = self.documents.compactMap { item -> (owner: UUID, url: URL)? in
                guard let url = item.imageDocument.fileState.nativeURL ?? item.imageDocument.fileState.importedSourceURL else { return nil }
                return (item.fileAccessID, url)
            }
            let token = try self.fileWrites.reserve(url, owner: controller.fileAccessID,
                                                    openFiles: openFiles, opening: Array(self.openingURLs))
            return { [weak self] in self?.fileWrites.release(token) }
        }
        if let previous = documents.last?.window, previous.isVisible, let window = controller.window,
           let visible = (previous.screen ?? NSScreen.main)?.visibleFrame {
            window.setFrameTopLeftPoint(DocumentWindowController.cascadedTopLeft(
                after: previous.frame, size: window.frame.size, in: visible))
        }
        controller.onClose = { [weak self] closed in
            self?.documents.removeAll { $0 === closed }
            PaletteCenter.shared.frontDocumentDidChange()
        }
        documents.append(controller)
        controller.showWindow(nil)
        controller.fitImage(nil)
        PaletteCenter.shared.frontDocumentDidChange()
        PaletteCenter.shared.setDefaultLayout(Self.defaultPaletteLayout)
        // Paths before Layers, so Layers is the tab their group shows.
        for palette in [toolsPalette, toolOptionsPalette, pathsPalette, layersPalette] where !palette.isPresented {
            palette.showPanel()
        }
        loadFontsIfNeeded(using: document)
    }

    /// The engine finishes loading fonts in the background after it starts;
    /// asking waits for that, so it happens off the main thread, once.
    private func loadFontsIfNeeded(using document: ImageDocument) {
        guard ToolState.shared.fontNames.isEmpty, !fontsRequested else { return }
        fontsRequested = true
        let session = document.session
        document.longQueue.async {
            let names = (try? session.fonts()) ?? []
            DispatchQueue.main.async {
                ToolState.shared.setEngineFonts(names)
                ToolState.shared.notifyChange()
            }
        }
    }

    private var fontsRequested = false

    // MARK: Menu commands

    @objc func newDocument(_ sender: Any?) {
        guard session != nil, !terminationRequested else { return }
        if let newImagePanel { newImagePanel.showWindow(nil); return }
        let panel = NewImagePanel()
        panel.onCreate = { [weak self] settings in
            self?.createDocument(width: settings.width, height: settings.height)
        }
        panel.onClose = { [weak self] in self?.newImagePanel = nil }
        newImagePanel = panel
        panel.showWindow(nil)
    }

    private func createDocument(width: Int, height: Int) {
        guard let session, !terminationRequested else { return }
        pendingFileOperations += 1
        openQueue.async {
            let result = Result { try session.newImage(width: width, height: height) }
            DispatchQueue.main.async {
                self.pendingFileOperations -= 1
                defer { self.closeNextDocumentForTermination() }
                do {
                    self.open(try ImageDocument(session: session, image: result.get(), name: "Untitled"))
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    @objc func pasteAsNewImage(_ sender: Any?) {
        guard let session, !terminationRequested, !PlugInCommands.isRunning else { return }
        let payload: ClipboardImage.Payload
        do { payload = try ClipboardImage.readPayload(from: .general) } catch {
            NSAlert(error: error).runModal()
            return
        }
        pendingFileOperations += 1
        openQueue.async {
            let result = Result { try session.newImage(pixels: payload.decoded()) }
            DispatchQueue.main.async {
                self.pendingFileOperations -= 1
                defer { self.closeNextDocumentForTermination() }
                do {
                    let image = try result.get()
                    do { self.open(try ImageDocument(session: session, image: image, name: "Clipboard")) }
                    catch { try? session.closeImage(image); throw error }
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        }
    }

    @objc func openRecentDocument(_ sender: Any?) {
        guard let url = (sender as? NSMenuItem)?.representedObject as? URL else { return }
        openFiles([url])
    }

    @objc func openDocument(_ sender: Any?) {
        guard session != nil else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }
        openFiles(panel.urls)
    }

    // Finder sends these before the engine has necessarily finished starting.
    func application(_ sender: NSApplication, open urls: [URL]) {
        if session != nil {
            openFiles(urls)
        } else if case .starting = state {
            pendingOpenURLs.append(contentsOf: urls)
        } else {
            NSAlert(error: NSError(domain: "ch.lkmc.Glims", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "The image engine is unavailable. Rebuild Glims with its engine to open images."])).runModal()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, session != nil, !terminationRequested { newDocument(nil) }
        return true
    }

    @objc private func openPendingFiles() {
        guard !pendingOpenURLs.isEmpty else { return }
        let urls = pendingOpenURLs
        pendingOpenURLs.removeAll()
        if !terminationRequested { openFiles(urls) }
    }

    private func openFiles(_ urls: [URL]) {
        guard let session, !terminationRequested else { return }
        guard !PlugInCommands.isRunning else {
            pendingOpenURLs.append(contentsOf: urls)
            return
        }
        for requested in urls {
            let url = requested.standardizedFileURL
            if let owner = fileWrites.owner(writing: url), let writer = documents.first(where: { $0.fileAccessID == owner }) {
                writer.window?.makeKeyAndOrderFront(nil)
                continue
            }
            if let existing = documents.first(where: {
                guard let source = $0.imageDocument.fileState.nativeURL ?? $0.imageDocument.fileState.importedSourceURL else { return false }
                return FileWriteCoordinator.sameFile(source, url)
            }) {
                existing.window?.makeKeyAndOrderFront(nil)
                continue
            }
            guard openingURLs.insert(url).inserted else { continue }
            pendingFileOperations += 1
            // File plug-ins must not block the AppKit thread.
            openQueue.async {
                let result = Result { try session.openImage(path: url.path) }
                DispatchQueue.main.async {
                    self.openingURLs.remove(url)
                    self.pendingFileOperations -= 1
                    defer { self.closeNextDocumentForTermination() }
                    do {
                        self.open(try ImageDocument(session: session, image: result.get(), name: url.lastPathComponent, openedFrom: url))
                        NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                }
            }
        }
    }

    @objc func showTools(_ sender: Any?) {
        toolsPalette.isPresented ? toolsPalette.bringToFront() : toolsPalette.showPanel()
    }

    @objc func showToolOptions(_ sender: Any?) {
        toolOptionsPalette.isPresented ? toolOptionsPalette.bringToFront() : toolOptionsPalette.showPanel()
    }

    @objc func showLayers(_ sender: Any?) {
        layersPalette.isPresented ? layersPalette.bringToFront() : layersPalette.showPanel()
    }

    @objc func showPaths(_ sender: Any?) {
        pathsPalette.isPresented ? pathsPalette.bringToFront() : pathsPalette.showPanel()
    }

    @objc func togglePaletteVisibility(_ sender: Any?) {
        Self.togglePalettes(keepingTools: false)
    }

    @objc func resetPaletteLayout(_ sender: Any?) {
        PaletteCenter.shared.resetLayout()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(pasteAsNewImage(_:)):
            return session != nil && !PlugInCommands.isRunning && !terminationRequested
                && NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
        case #selector(newDocument(_:)), #selector(openDocument(_:)), #selector(openRecentDocument(_:)):
            // A plug-in dialog is modal for the engine (glims_engine.h).
            return session != nil && !PlugInCommands.isRunning && !terminationRequested
        case #selector(showLayers(_:)), #selector(showPaths(_:)), #selector(showTools(_:)),
             #selector(showToolOptions(_:)):
            return session != nil
        case #selector(togglePaletteVisibility(_:)):
            menuItem.title = PaletteCenter.shared.isHidingPalettes ? "Show Palettes" : "Hide Palettes"
            return session != nil
        default:
            return true
        }
    }
}
