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
    private(set) var documents: [DocumentWindowController] = []
    private var workspace: WorkspaceWindowController?
    private var newImagePanel: NewImagePanel?
    private var preferencesWindow: PreferencesWindowController?
    private var helpWindow: HelpWindowController?
    private var batchWindow: RecorderBatchWindowController?
    private var pendingOpenURLs: [URL] = []
    private var openingURLs: Set<URL> = []
    private var pendingFileOperations = 0
    private var terminationRequested = false
    private let fileWrites = FileWriteCoordinator()
    private var closingDocument: DocumentWindowController?
    /// Newest first, captured once. Documents adopted after Close All starts
    /// remain open; Quit deliberately switches back to the live document list.
    private var closeAllRemaining: [DocumentWindowController]?
    /// Periodic recovery copies into the private store; starts with the
    /// engine and stays off when the store cannot be created.
    private var recovery: RecoveryScheduler?
    /// The shared store the scheduler writes into and the recovery panel
    /// reads prior runs' records from; kept even when the scheduler
    /// cannot start so prior records stay reachable.
    var recoveryStore: RecoveryStore?
    private(set) var recoveryPanel: RecoveryPanelController?
    /// Records with a recovery open in flight, so a repeated click
    /// cannot duplicate the operation.
    private(set) var inFlightRecoveries: Set<RecoveryKey> = []
    /// Prior records whose recovered document is still open, by that
    /// document's recovery id; a record is retired when its document
    /// closes for good.
    private var recoveredSources: [UUID: RecoveryStore.RecoveredDocument] = [:]
    /// The last recovery failure shown nonmodally in the panel.
    private(set) var lastRecoveryFailure: String?
    /// A copy's identity: which dead run's folder and which document id.
    struct RecoveryKey: Hashable {
        var runID: UUID
        var documentID: UUID
        init(_ candidate: RecoveryStore.RecoveredDocument) {
            runID = candidate.runID
            documentID = candidate.documentID
        }
    }

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

    private lazy var historyPalette: Palette = PaletteCenter.shared.palette(
        for: HistoryPaletteController.definition,
        target: { [weak self] in self?.frontDocument },
        makeContent: { HistoryPaletteController() })

    private lazy var recorderPalette: Palette = PaletteCenter.shared.palette(
        for: RecorderPaletteController.definition,
        target: { [weak self] in self?.frontDocument },
        makeContent: { [weak self] in
            RecorderPaletteController(currentDocument: { [weak self] in self?.frontDocument },
                                      performAction: { [weak self] action, document in
                guard let self else { throw RecorderFileCoordinator.Refusal.windowUnavailable }
                try self.performRecorderAction(action, in: document)
            })
        })

    private lazy var channelsPalette: Palette = PaletteCenter.shared.palette(
        for: ChannelsPaletteController.definition,
        target: { [weak self] in self?.frontDocument },
        makeContent: { ChannelsPaletteController() })

    var frontDocument: ImageDocument? {
        (NSApp.mainWindow?.windowController as? DocumentWindowController)?.imageDocument ?? documents.last?.imageDocument
    }

    var session: EngineSession? {
        if case .running(let session) = state { return session }
        return nil
    }

    /// The first-launch layout (docs/design.md, section 2): Tools at the
    /// top left with Tool Options docked under it as one column, Layers at
    /// the top right. History and Recorder share Layers' and Paths' group rather than
    /// adding a column. Rigi keeps whatever the person arranges since, and
    /// a frame saved by an earlier build still places its palette once.
    static let defaultPaletteLayout = [
        PaletteGroupDefault([ToolsPaletteController.definition.kind], placement: .topLeading),
        PaletteGroupDefault([ToolOptionsPaletteController.definition.kind],
                            placement: .docked(below: ToolsPaletteController.definition.kind)),
        PaletteGroupDefault([LayersPaletteController.definition.kind, ChannelsPaletteController.definition.kind,
                             PathsPaletteController.definition.kind,
                             HistoryPaletteController.definition.kind, RecorderPaletteController.definition.kind],
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
        // The shortcut manager attaches exactly once, now that the real
        // main menu is installed (GlimsApplication set it before the run
        // loop started). MainMenu.make() itself never attaches or rewrites
        // anything global.
        MenuShortcutManager.shared.attach()
        ClassicChrome.apply(scheme: EditorPreferences.shared.appearance)
        NotificationCenter.default.addObserver(self, selector: #selector(preferencesChanged),
                                               name: EditorPreferences.didChange, object: EditorPreferences.shared)
        NotificationCenter.default.addObserver(self, selector: #selector(auxiliaryWindowBecameKey(_:)),
                                               name: NSWindow.didBecomeKeyNotification, object: nil)
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

    @objc private func preferencesChanged() {
        ClassicChrome.apply(scheme: EditorPreferences.shared.appearance)
        NSApp.windows.forEach { applyAuxiliaryAppearance($0) }
        applyRecoveryPreferences()
    }

    /// Applies the recovery preferences to the live scheduler. Stopping
    /// only disarms the tick — a copy already in flight still finishes
    /// and commits; restarting keeps the tracked documents and their
    /// copied revisions, so existing copies are never re-made or lost.
    private func applyRecoveryPreferences() {
        let preferences = EditorPreferences.shared
        guard let recovery else { return }
        if preferences.recoveryCopiesEnabled {
            recovery.setInterval(preferences.recoveryInterval.seconds)
            recovery.start()
        } else {
            recovery.stop()
        }
    }

    @objc private func auxiliaryWindowBecameKey(_ notification: Notification) {
        if let window = notification.object as? NSWindow { applyAuxiliaryAppearance(window) }
    }

    private func applyAuxiliaryAppearance(_ window: NSWindow) {
        guard !(window.windowController is DocumentWindowController) else { return }
        window.appearance = EditorPreferences.shared.chromeAppearance
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindow == nil { preferencesWindow = PreferencesWindowController() }
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    /// App ▸ Keyboard Shortcuts…: the menu shortcut customization panel.
    @objc func showKeyboardShortcuts(_ sender: Any?) {
        MenuShortcutManager.shared.showPanel()
    }

    /// Help > Glims Help: the bundled manual in its own window. The panel
    /// never becomes main, so the front document stays the target.
    @objc func showGlimsHelp(_ sender: Any?) {
        showHelp(section: nil)
    }

    /// Help > Keyboard & Mouse Reference: the manual's key tables.
    @objc func showKeyboardReference(_ sender: Any?) {
        showHelp(section: HelpManual.keyboardReferenceTitle)
    }

    /// Help > Engine Manual: the engine's official documentation in the
    /// user's web browser. The only external link in Glims, opened solely
    /// on this explicit request.
    @objc func openEngineManual(_ sender: Any?) {
        NSWorkspace.shared.open(HelpManual.engineManualURL)
    }

    private func showHelp(section: String?) {
        if helpWindow == nil { helpWindow = HelpWindowController() }
        helpWindow?.show(section: section)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationRequested else { return .terminateLater }
        guard !documents.isEmpty || pendingFileOperations > 0 || closingDocument != nil || batchWindow?.isRunning == true else { return .terminateNow }
        terminationRequested = true
        closeAllRemaining = nil
        newImagePanel?.close()
        recoveryPanel?.close()
        batchWindow?.cancel()
        batchWindow?.window?.performClose(nil)
        // AppKit expects terminateLater before reply(toApplicationShouldTerminate:).
        DispatchQueue.main.async { self.advanceDocumentClosing() }
        return .terminateLater
    }

    private var canCloseAllDocuments: Bool {
        !documents.isEmpty && !terminationRequested && closeAllRemaining == nil
            && closingDocument == nil && !PlugInCommands.isRunning
    }

    /// Close only the current finite set. This does not gate New/Open or
    /// recovery adoption and never replies to AppKit's termination protocol.
    @objc func closeAllDocuments(_ sender: Any?) {
        guard canCloseAllDocuments else { return }
        closeAllRemaining = Array(documents.reversed())
        advanceDocumentClosing()
    }

    /// One in-flight request serves both commands. A Quit that arrives during
    /// Close All joins that request, then closes the live list if it succeeds.
    private func advanceDocumentClosing() {
        guard closingDocument == nil, pendingFileOperations == 0, batchWindow?.isRunning != true else { return }
        let controller: DocumentWindowController
        if terminationRequested {
            guard let next = documents.last else {
                terminationRequested = false
                NSApp.reply(toApplicationShouldTerminate: true)
                return
            }
            controller = next
        } else if var remaining = closeAllRemaining {
            remaining.removeAll { candidate in !documents.contains { $0 === candidate } }
            guard !remaining.isEmpty else {
                closeAllRemaining = nil
                return
            }
            controller = remaining.removeFirst()
            closeAllRemaining = remaining
        } else {
            return
        }
        closingDocument = controller
        controller.requestClose { [weak self, weak controller] closed in
            guard let self, let controller, self.closingDocument === controller else { return }
            self.closingDocument = nil
            if closed {
                self.advanceDocumentClosing()
            } else {
                self.closeAllRemaining = nil
                if self.terminationRequested {
                    self.terminationRequested = false
                    NSApp.reply(toApplicationShouldTerminate: false)
                }
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrushChooser.shared.close()
        recovery?.stop()
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

    /// Where recovery copies live: Application Support, beside the
    /// engine's own directory.
    static func recoveryDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Glims/Recovery", isDirectory: true)
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
            let store = RecoveryStore(base: Self.recoveryDirectory())
            recoveryStore = store
            do {
                try store.prepare()
                let scheduler = RecoveryScheduler(store: store,
                                                  interval: EditorPreferences.shared.recoveryInterval.seconds)
                // A missed copy is visible in the affected document's
                // status bar and in the recovery panel's status line.
                scheduler.onFailure = { [weak self] candidate, message in
                    (candidate as? ImageDocument)?.onError?(message)
                    self?.noteRecoveryFailure(message)
                }
                recovery = scheduler
                applyRecoveryPreferences()
            } catch {
                // Periodic copies stay off; the documents are unaffected
                // and prior records can still be offered read-only.
                noteRecoveryFailure("Recovery copies are unavailable: \(error.localizedDescription)")
            }
            workspace?.close()
            workspace = nil
            if pendingOpenURLs.isEmpty {
                createDocument(width: Self.defaultImageSize.width, height: Self.defaultImageSize.height)
            } else {
                let urls = pendingOpenURLs
                pendingOpenURLs.removeAll()
                openFiles(urls)
            }
            offerRecoveryAfterStartup()
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
            let running = PlugInCommands.running?.document ?? EngineActivity.shared.progressDocument
            documents.first { $0.imageDocument === running }?.showProgress(progress)
            return
        }
        for controller in documents { controller.imageDocument.handle(event) }
        if case .message(let text) = event {
            (NSApp.mainWindow?.windowController as? DocumentWindowController)?.statusBar.message = text
        }
    }

    func open(_ document: ImageDocument) {
        document.snapshotHandler = { [weak self] document in self?.snapshot(document) }
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
        controller.revertHandler = { [weak self, weak controller] source, done in
            guard let self, let controller else {
                return done(.failure(ImageDocument.DocumentError.closed))
            }
            self.revert(controller, to: source, completion: done)
        }
        let previousWindow = documents.last?.window.flatMap { $0.isVisible ? $0 : nil }
        controller.onClose = { [weak self] closed in
            self?.documents.removeAll { $0 === closed }
            self?.recovery?.untrack(closed.imageDocument)
            // A document recovered from a prior record is closed for
            // good (saved or Don't Save): the prior copy has served its
            // purpose and is retired. A record already gone is the same
            // end state, not an error.
            if let prior = self?.recoveredSources.removeValue(forKey: closed.imageDocument.recoveryID) {
                do {
                    try self?.recoveryStore?.discardRecoverable(prior)
                } catch RecoveryStore.StoreError.recordMismatch {
                } catch {
                    self?.noteRecoveryFailure("Could not remove the recovery copy of \u{201C}\(prior.name)\u{201D}: \(error.localizedDescription)")
                }
            }
            PaletteCenter.shared.frontDocumentDidChange()
        }
        documents.append(controller)
        recovery?.track(document, isReady: { [weak controller] in
            controller?.isReadyForRecoveryCopy ?? false
        })
        // Materialize the current palette arrangement before choosing the
        // new document's frame. Fitting before this point used the old
        // viewport and could leave the canvas underneath palette columns.
        PaletteCenter.shared.setDefaultLayout(Self.defaultPaletteLayout)
        // Paths, History and Recorder before Layers, so Layers is the tab their
        // shared group shows.
        for palette in [toolsPalette, toolOptionsPalette, channelsPalette, pathsPalette, historyPalette, recorderPalette, layersPalette]
        where !palette.isPresented {
            palette.showPanel()
        }
        if let window = controller.window,
           let visible = (previousWindow?.screen ?? window.screen ?? NSScreen.main)?.visibleFrame {
            let palettes = NSApp.windows.filter { $0.isVisible && $0 is ClassicPaletteWindow }.map(\.frame)
            let available = DocumentWindowPlacement.availableFrame(in: visible, avoiding: palettes)
            let frame = DocumentWindowPlacement.frame(size: window.frame.size,
                                                       after: previousWindow?.frame, in: available)
            if !frame.isEmpty { window.setFrame(frame, display: false) }
        }
        controller.showWindow(nil)
        if EditorPreferences.shared.initialView == .fit { controller.fitImage(nil) }
        PaletteCenter.shared.frontDocumentDidChange()
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
        guard let session, !terminationRequested else { return }
        if let newImagePanel { newImagePanel.showWindow(nil); return }
        let panel = NewImagePanel(supportsLab: session.supportsLabCreation
                                  && session.supportsLabAxes && session.supportsLabFill)
        panel.onCreate = { [weak self] settings in
            self?.createDocument(width: settings.width, height: settings.height,
                                 kind: settings.kind, component: settings.component,
                                 channelCount: settings.channelCount, profileICC: settings.profileICC)
        }
        panel.onClose = { [weak self] in self?.newImagePanel = nil }
        newImagePanel = panel
        panel.showWindow(nil)
    }

    private func createDocument(width: Int, height: Int, kind: NewImageSettings.Kind = .rgb,
                                component: EngineSession.ColorComponent = .u8, channelCount: Int = 4,
                                profileICC: Data? = nil) {
        guard let session, !terminationRequested else { return }
        pendingFileOperations += 1
        EngineActivity.shared.performWhenReady(label: "Creating an image", work: {
            let result = Result<Int32, Error> {
                switch kind {
                case .rgb: return try session.newImage(width: width, height: height)
                case .multichannel:
                    return try session.newMultichannelImage(width: width, height: height,
                                                            component: component, channelCount: channelCount)
                case .cmyk:
                    guard let profileICC else {
                        throw EngineSession.EngineError(status: 1, message: "Choose a CMYK source profile before creating the image.")
                    }
                    return try session.newCmykImage(width: width, height: height,
                                                   component: component, profileICC: profileICC)
                case .lab:
                    return try session.newLabImage(width: width, height: height, component: component)
                }
            }
            DispatchQueue.main.async {
                self.pendingFileOperations -= 1
                defer { self.advanceDocumentClosing() }
                do {
                    let image = try result.get()
                    do { self.open(try ImageDocument(session: session, image: image, name: "Untitled")) }
                    catch { try? session.closeImage(image); throw error }
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        })
    }

    @objc func pasteAsNewImage(_ sender: Any?) {
        guard let session, !terminationRequested, !PlugInCommands.isRunning else { return }
        let payload: ClipboardImage.Payload
        do { payload = try ClipboardImage.readPayload(from: .general) } catch {
            NSAlert(error: error).runModal()
            return
        }
        pendingFileOperations += 1
        EngineActivity.shared.performWhenReady(label: "Creating an image from the clipboard", work: {
            let result = Result { try session.newImage(pixels: payload.decoded()) }
            DispatchQueue.main.async {
                self.pendingFileOperations -= 1
                defer { self.advanceDocumentClosing() }
                do {
                    let image = try result.get()
                    do { self.open(try ImageDocument(session: session, image: image, name: "Clipboard")) }
                    catch { try? session.closeImage(image); throw error }
                } catch {
                    NSAlert(error: error).runModal()
                }
            }
        })
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
            EngineActivity.shared.performWhenReady(label: "Opening \(url.lastPathComponent)", work: {
                let result = Result { try session.openImage(path: url.path) }
                DispatchQueue.main.async {
                    self.openingURLs.remove(url)
                    self.pendingFileOperations -= 1
                    defer { self.advanceDocumentClosing() }
                    do {
                        try Self.adoptOpenedImage(result, adopt: { image in
                            self.open(try ImageDocument(session: session, image: image,
                                                       name: url.lastPathComponent, openedFrom: url))
                        }, close: { try session.closeImage($0) })
                        NSDocumentController.shared.noteNewRecentDocumentURL(url)
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                }
            })
        }
    }

    /// A successful load transfers its native image only once adoption succeeds.
    /// On failed construction, attempt cleanup before reporting the original
    /// error; a cleanup failure must not replace that construction error.
    static func adoptOpenedImage(_ result: Result<Int32, Error>,
                                 adopt: (Int32) throws -> Void,
                                 close: (Int32) throws -> Void) throws {
        let image = try result.get()
        do { try adopt(image) }
        catch {
            try? close(image)
            throw error
        }
    }

    @objc func showTools(_ sender: Any?) {
        toolsPalette.focusPanel()
    }

    @objc func showToolOptions(_ sender: Any?) {
        toolOptionsPalette.focusPanel()
    }

    @objc func showLayers(_ sender: Any?) {
        layersPalette.focusPanel()
    }

    @objc func showChannels(_ sender: Any?) {
        channelsPalette.focusPanel()
    }

    @objc func showPaths(_ sender: Any?) {
        pathsPalette.focusPanel()
    }

    @objc func showHistory(_ sender: Any?) {
        historyPalette.focusPanel()
    }

    @objc func showRecorder(_ sender: Any?) {
        recorderPalette.focusPanel()
    }

    @objc func showBatch(_ sender: Any?) {
        guard let session, !terminationRequested else { return }
        if batchWindow == nil {
            let controller = RecorderBatchWindowController(session: session)
            controller.onRunStateChange = { [weak self] in self?.advanceDocumentClosing() }
            batchWindow = controller
        }
        batchWindow?.showWindow(sender)
        batchWindow?.window?.makeKeyAndOrderFront(sender)
    }

    @objc func recorderCommand(_ sender: NSMenuItem) {
        guard let action = RecorderPaletteAction(rawValue: sender.tag),
              let document = frontDocument else { return }
        showRecorder(sender)
        let presentation = RecorderPalettePresentation(document: document)
        if let refusal = presentation.refusal(for: action) {
            document.onError?(refusal)
            return
        }
        do { try performRecorderAction(action, in: document) }
        catch { document.onError?(RecorderPalettePresentation.message(for: error)) }
    }

    private func performRecorderAction(_ action: RecorderPaletteAction, in document: ImageDocument) throws {
        if action.needsFileSheet ||
            ((action == .record || action == .clear) && document.hasUnsavedRecordingChanges) {
            guard let owner = documents.first(where: { $0.imageDocument === document }) else {
                throw RecorderFileCoordinator.Refusal.windowUnavailable
            }
            try owner.presentRecorderFileAction(action)
        } else {
            try action.perform(on: document)
        }
    }

    /// File ▸ Recover Documents…: the panel is never a dead end — Later
    /// keeps the records and this menu item reopens the list.
    @objc func recoverDocuments(_ sender: Any?) {
        showRecoveryPanel()
    }

    /// Offers prior copies when the startup document has been adopted.
    func offerRecoveryAfterStartup() {
        // Let this idle-action batch admit any opens queued after the
        // offer before testing readiness. Otherwise one of those opens
        // could adopt a window on top of a panel just presented here.
        EngineActivity.shared.whenIdle { [weak self] in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.terminationRequested else { return }
                guard !EngineActivity.shared.isBusy, self.pendingFileOperations == 0 else {
                    self.offerRecoveryAfterStartup()
                    return
                }
                guard self.recoveryStore?.discoverRecoverableDocuments().isEmpty == false else { return }
                self.showRecoveryPanel()
            }
        }
    }

    private func showRecoveryPanel() {
        if recoveryPanel == nil {
            let panel = RecoveryPanelController()
            panel.onRecover = { [weak self] records in
                guard let self, let session = self.session else { return }
                self.recover(records, using: session)
            }
            panel.onDiscard = { [weak self] records in self?.discardSelected(records) }
            recoveryPanel = panel
        }
        guard let panel = recoveryPanel else { return }
        let found = recoveryStore?.discoverRecoverableDocuments() ?? []
        panel.setRecords(found)
        if let lastRecoveryFailure {
            panel.showStatus(lastRecoveryFailure)
        } else if recoveryStore == nil {
            panel.showStatus("Recovery copies are unavailable.")
        } else if !found.isEmpty {
            panel.showStatus("")
        }
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
    }

    /// A recovery failure is never dropped silently: it lands in the
    /// panel's status line when the panel is up, and always on stderr.
    private func noteRecoveryFailure(_ message: String) {
        lastRecoveryFailure = message
        recoveryPanel?.showStatus(message)
        FileHandle.standardError.write(Data("Glims: \(message)\n".utf8))
    }

    /// The still-open document a record was recovered into, if any.
    private func recoveredDocument(for key: RecoveryKey) -> DocumentWindowController? {
        for (id, record) in recoveredSources where RecoveryKey(record) == key {
            if let controller = documents.first(where: { $0.imageDocument.recoveryID == id }) {
                return controller
            }
        }
        return nil
    }

    /// Opens each selected record's copy as a new unsaved document. The
    /// record itself is re-validated against the store — a stale row
    /// refuses visibly — then the copy is opened and duplicated into an
    /// independent image on the engine queue, counted as a file
    /// operation so Quit and engine-busy work are respected. The prior
    /// record is kept until the recovered document closes: deleting the
    /// only copy at open would leave a second crash with nothing.
    func recover(_ candidates: [RecoveryStore.RecoveredDocument], using session: EngineSession) {
        guard let store = recoveryStore, !terminationRequested else { return }
        for candidate in candidates {
            let key = RecoveryKey(candidate)
            if let existing = recoveredDocument(for: key) {
                existing.window?.makeKeyAndOrderFront(nil)
                continue
            }
            guard inFlightRecoveries.insert(key).inserted else { continue }
            pendingFileOperations += 1
            guard let record = store.recoverableDocument(matching: candidate) else {
                inFlightRecoveries.remove(key)
                pendingFileOperations -= 1
                advanceDocumentClosing()
                // Refresh first: an emptied list's message must not
                // overwrite the refusal error.
                recoveryPanel?.setRecords(store.discoverRecoverableDocuments())
                noteRecoveryFailure("\u{201C}\(candidate.name)\u{201D} is no longer available to recover.")
                continue
            }
            recoveryPanel?.setBusy(true)
            recoveryPanel?.showStatus("Recovering \u{201C}\(record.name)\u{201D}\u{2026}")
            EngineActivity.shared.performWhenReady(label: "Recovering \(record.name)", work: {
                let result = Self.recoverImage(from: record, session: session)
                DispatchQueue.main.async { self.finishRecovery(result, for: record, key: key, session: session) }
            })
        }
    }

    /// Runs on the engine activity queue: opens the store's copy into an
    /// intermediate image, duplicates it so the document to open is
    /// independent of the copy's own identity, and closes the
    /// intermediate handle on every outcome. Lab uses direct ownership transfer
    /// because native duplication is not supported for its typed planes.
    private nonisolated static func recoverImage(from record: RecoveryStore.RecoveredDocument,
                                                 session: EngineSession) -> Result<Int32, Error> {
        do {
            let opened = try session.openImage(path: record.copyURL.path)
            do {
                if try session.colorInfo(opened).mode == .lab { return .success(opened) }
                let duplicated = try session.duplicateImage(opened)
                do { try session.closeImage(opened) }
                catch {
                    try? session.closeImage(duplicated)
                    throw error
                }
                return .success(duplicated)
            } catch {
                try? session.closeImage(opened)
                return .failure(error)
            }
        } catch {
            return .failure(error)
        }
    }

    /// Adopts the recovered image on the main queue. A failed recovery
    /// keeps the record; a Quit or a failed document construction closes
    /// the duplicate instead of adopting it.
    private func finishRecovery(_ result: Result<Int32, Error>,
                                for record: RecoveryStore.RecoveredDocument,
                                key: RecoveryKey, session: EngineSession) {
        pendingFileOperations -= 1
        inFlightRecoveries.remove(key)
        defer {
            recoveryPanel?.setBusy(!inFlightRecoveries.isEmpty)
            advanceDocumentClosing()
        }
        switch result {
        case .success(let image):
            guard !terminationRequested else {
                try? session.closeImage(image)
                return
            }
            do {
                let document = try ImageDocument(session: session, image: image,
                                                 name: "\(record.name) recovered")
                document.noteRecovered()
                recoveredSources[document.recoveryID] = record
                open(document)
                lastRecoveryFailure = nil
                recoveryPanel?.showStatus(
                    "Recovered \u{201C}\(record.name)\u{201D} as a new unsaved document. Its copy is kept until that document closes.")
            } catch {
                try? session.closeImage(image)
                noteRecoveryFailure("Could not recover \u{201C}\(record.name)\u{201D}: \(error.localizedDescription)")
            }
        case .failure(let error):
            noteRecoveryFailure("Could not recover \u{201C}\(record.name)\u{201D}: \(error.localizedDescription)")
        }
    }

    /// Deletes the selected prior records through the store's validated
    /// path; every failure is visible in the panel and the list is
    /// re-read from disk so removed rows disappear.
    func discardSelected(_ candidates: [RecoveryStore.RecoveredDocument]) {
        guard let store = recoveryStore else { return }
        var failures: [String] = []
        for candidate in candidates {
            let key = RecoveryKey(candidate)
            if inFlightRecoveries.contains(key) {
                failures.append("\u{201C}\(candidate.name)\u{201D} is being recovered")
            } else if recoveredDocument(for: key) != nil {
                failures.append("\u{201C}\(candidate.name)\u{201D} is open as a recovered document; close it first")
            } else {
                do { try store.discardRecoverable(candidate) }
                catch { failures.append("\u{201C}\(candidate.name)\u{201D}: \(error.localizedDescription)") }
            }
        }
        recoveryPanel?.setRecords(store.discoverRecoverableDocuments())
        if failures.isEmpty {
            recoveryPanel?.showStatus("Discarded \(candidates.count) recovery \(candidates.count == 1 ? "copy" : "copies").")
            lastRecoveryFailure = nil
        } else {
            noteRecoveryFailure("Could not discard \(failures.joined(separator: "; "))")
        }
    }

    /// Image ▸ New Snapshot and the History palette's button: queues a
    /// native copy on the source document, then opens it as a fresh
    /// unsaved document. The whole transaction counts as a file operation
    /// so Quit waits; a copy nobody can adopt — a failed ImageDocument or
    /// a Quit that already started — is closed again. The callback stays
    /// bound to the source document, whoever is front document then.
    func snapshot(_ document: ImageDocument) {
        guard !terminationRequested else { return }
        guard document.acceptsEdits else {
            document.onError?(document.isClosing
                ? ImageDocument.DocumentError.closed.localizedDescription
                : ImageDocument.DocumentError.busy.localizedDescription)
            return
        }
        let session = document.session
        pendingFileOperations += 1
        document.snapshot { [weak self] result in
            guard let self else {
                if case .success(let image) = result { try? session.closeImage(image) }
                return
            }
            self.pendingFileOperations -= 1
            defer { self.advanceDocumentClosing() }
            switch result {
            case .success(let image):
                if self.terminationRequested {
                    try? session.closeImage(image)
                    return
                }
                do {
                    self.open(try ImageDocument(session: session, image: image,
                                                name: "\(document.name) snapshot"))
                } catch {
                    try? session.closeImage(image)
                    NSAlert(error: error).runModal()
                }
            case .failure(let error):
                document.onError?(String(describing: error))
            }
        }
    }

    /// File ▸ Revert's load for a confirmed discard. The reload is a
    /// file operation — it waits behind other engine work, gates new
    /// edits on every document and counts toward Quit — and the
    /// replacement is adopted only into a still-live window.
    func revert(_ controller: DocumentWindowController, to source: URL,
                completion: @escaping @MainActor (Result<DocumentWindowController, Error>) -> Void) {
        guard !terminationRequested else {
            return completion(.failure(ImageDocument.DocumentError.closed))
        }
        // The reload runs in the document's own engine session.
        let session = controller.imageDocument.session
        pendingFileOperations += 1
        EngineActivity.shared.performWhenReady(label: "Reverting \(source.lastPathComponent)", work: {
            let result = Result { try session.openImage(path: source.path) }
            DispatchQueue.main.async {
                self.pendingFileOperations -= 1
                defer { self.advanceDocumentClosing() }
                self.adoptRevertedImage(result, from: source, into: controller, completion: completion)
            }
        })
    }

    /// The loaded side of Revert on the main queue. Adoption is all or
    /// nothing: the replacement opens through the ordinary document
    /// path, takes the old window's frame and view, and only then does
    /// the old document close without asking again. A window that
    /// closed or a Quit that began while the file loaded wins instead:
    /// the loaded image is destroyed unopened.
    private func adoptRevertedImage(_ result: Result<Int32, Error>, from source: URL,
                                    into controller: DocumentWindowController,
                                    completion: @escaping @MainActor (Result<DocumentWindowController, Error>) -> Void) {
        let session = controller.imageDocument.session
        switch result {
        case .failure(let error):
            completion(.failure(error))
        case .success(let image):
            guard !terminationRequested, documents.contains(where: { $0 === controller }),
                  !controller.imageDocument.isClosing, !controller.closeStarted,
                  !controller.waitingForActivityToClose else {
                // The confirmed discard still stands — a Quit or close
                // in flight must never prompt to save it — and the
                // image nobody can adopt is destroyed on the engine
                // queue, behind every earlier file call.
                controller.approveDiscard()
                EngineActivity.shared.closeImage(image, session: session) { _ in }
                return completion(.failure(ImageDocument.DocumentError.closed))
            }
            guard controller.canDiscardRecordingForRevert else {
                EngineActivity.shared.closeImage(image, session: session) { _ in }
                return completion(.failure(RecorderFileCoordinator.Refusal.changed))
            }
            let frame = controller.window?.frame
            let zoom = controller.canvas.zoomPercent
            let center = controller.canvasCenter
            do {
                let document = try ImageDocument(session: session, image: image,
                                                 name: source.lastPathComponent, openedFrom: source)
                open(document)
                guard let replacement = documents.first(where: { $0.imageDocument === document }) else {
                    // open() only appends, so this cannot happen; if it
                    // ever does, keep the adopted document rather than
                    // destroying its image under it.
                    return completion(.failure(ImageDocument.DocumentError.closed))
                }
                if let frame { replacement.window?.setFrame(frame, display: false) }
                replacement.zoom(to: zoom)
                replacement.center(on: center)
                guard controller.closeAfterRevert() else {
                    replacement.closeDiscardingChanges()
                    return completion(.failure(RecorderFileCoordinator.Refusal.changed))
                }
                completion(.success(replacement))
            } catch {
                EngineActivity.shared.closeImage(image, session: session) { _ in }
                completion(.failure(error))
            }
        }
    }

    @objc func togglePaletteVisibility(_ sender: Any?) {
        Self.togglePalettes(keepingTools: false)
    }

    @objc func resetPaletteLayout(_ sender: Any?) {
        PaletteCenter.shared.resetLayout()
    }

    @objc func selectToolFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              item.identifier == MenuShortcutBridge.builtinIdentifier,
              item.action == #selector(selectToolFromMenu(_:)),
              let tool = ToolMenuCatalog.tool(forTag: item.tag),
              tool.isAvailable(in: frontDocument?.colorInfo.mode) else { return }
        ToolState.shared.select(tool)
    }

    @objc func selectMoveTargetFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem,
              item.identifier == MenuShortcutBridge.builtinIdentifier,
              item.action == #selector(selectMoveTargetFromMenu(_:)),
              let mode = ToolMenuCatalog.moveTarget(forTag: item.tag) else { return }
        ToolState.shared.setMoveTargetMode(mode)
    }

    @objc func editForegroundColorFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, item.identifier == MenuShortcutBridge.builtinIdentifier,
              item.action == #selector(editForegroundColorFromMenu(_:)),
              item.tag == ToolMenuCatalog.foregroundColorTag else { return }
        ToolColorEditorController.shared.open(target: .foreground)
    }

    @objc func editBackgroundColorFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, item.identifier == MenuShortcutBridge.builtinIdentifier,
              item.action == #selector(editBackgroundColorFromMenu(_:)),
              item.tag == ToolMenuCatalog.backgroundColorTag else { return }
        ToolColorEditorController.shared.open(target: .background)
    }

    @objc func swapColorsFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, item.identifier == MenuShortcutBridge.builtinIdentifier,
              item.action == #selector(swapColorsFromMenu(_:)), item.tag == ToolMenuCatalog.swapColorsTag else { return }
        ToolState.shared.swapColors()
    }

    @objc func resetColorsFromMenu(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, item.identifier == MenuShortcutBridge.builtinIdentifier,
              item.action == #selector(resetColorsFromMenu(_:)), item.tag == ToolMenuCatalog.defaultColorsTag else { return }
        ToolState.shared.resetColors()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(closeAllDocuments(_:)):
            return canCloseAllDocuments
        case #selector(pasteAsNewImage(_:)):
            return session != nil && !PlugInCommands.isRunning && !terminationRequested
                && NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
        case #selector(newDocument(_:)), #selector(openDocument(_:)), #selector(openRecentDocument(_:)):
            // A plug-in dialog is modal for the engine (glims_engine.h).
            return session != nil && !PlugInCommands.isRunning && !terminationRequested
        case #selector(recoverDocuments(_:)):
            return session != nil && !terminationRequested
        case #selector(showBatch(_:)):
            return session != nil && !terminationRequested && !PlugInCommands.isRunning
        case #selector(recorderCommand(_:)):
            guard session != nil, !terminationRequested,
                  let action = RecorderPaletteAction(rawValue: menuItem.tag),
                  let document = frontDocument else { return false }
            if action.needsFileSheet,
               documents.first(where: { $0.imageDocument === document })?.canPresentRecorderFileSheet != true {
                return false
            }
            return RecorderPalettePresentation(document: document).canPerform(action)
        case #selector(showLayers(_:)), #selector(showChannels(_:)), #selector(showPaths(_:)), #selector(showHistory(_:)), #selector(showRecorder(_:)),
             #selector(showTools(_:)), #selector(showToolOptions(_:)):
            return session != nil
        case #selector(togglePaletteVisibility(_:)):
            menuItem.title = PaletteCenter.shared.isHidingPalettes ? "Show Palettes" : "Hide Palettes"
            return session != nil
        case #selector(selectToolFromMenu(_:)):
            // Like the Tools palette, these change the global context, even
            // while loading or busy. No image service or engine read is needed.
            guard menuItem.identifier == MenuShortcutBridge.builtinIdentifier,
                  let tool = ToolMenuCatalog.tool(forTag: menuItem.tag) else {
                menuItem.state = .off; return false
            }
            menuItem.state = tool == ToolState.shared.current ? .on : .off
            return tool.isAvailable(in: frontDocument?.colorInfo.mode)
        case #selector(selectMoveTargetFromMenu(_:)):
            guard menuItem.identifier == MenuShortcutBridge.builtinIdentifier,
                  let mode = ToolMenuCatalog.moveTarget(forTag: menuItem.tag) else {
                menuItem.state = .off; return false
            }
            menuItem.state = mode == ToolState.shared.moveTargetMode ? .on : .off
            return true
        case #selector(editForegroundColorFromMenu(_:)):
            menuItem.state = .off
            return menuItem.identifier == MenuShortcutBridge.builtinIdentifier && menuItem.tag == ToolMenuCatalog.foregroundColorTag
        case #selector(editBackgroundColorFromMenu(_:)):
            menuItem.state = .off
            return menuItem.identifier == MenuShortcutBridge.builtinIdentifier && menuItem.tag == ToolMenuCatalog.backgroundColorTag
        case #selector(swapColorsFromMenu(_:)):
            menuItem.state = .off
            return menuItem.identifier == MenuShortcutBridge.builtinIdentifier && menuItem.tag == ToolMenuCatalog.swapColorsTag
        case #selector(resetColorsFromMenu(_:)):
            menuItem.state = .off
            return menuItem.identifier == MenuShortcutBridge.builtinIdentifier && menuItem.tag == ToolMenuCatalog.defaultColorsTag
        default:
            return true
        }
    }
}
