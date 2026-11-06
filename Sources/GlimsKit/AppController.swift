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
        guard let path = EngineLibrary.configuredPath() else {
            showWorkspace(message: "No engine library configured; set \(EngineLibrary.environmentVariable).")
            state = .unavailable("not configured")
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
            workspace?.close()
            workspace = nil
            newDocument(nil)
        case .failure(let error):
            state = .failed(String(describing: error))
            workspace?.statusBar.message = "The engine did not start: \(error)"
        }
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
        guard let session else { return }
        do {
            let image = try session.newImage(width: Self.defaultImageSize.width, height: Self.defaultImageSize.height)
            open(try ImageDocument(session: session, image: image, name: "Untitled"))
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    @objc func openDocument(_ sender: Any?) {
        guard let session else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Opening a non-XCF file runs a plug-in; keep it off the main thread.
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try session.openImage(path: url.path) }
            DispatchQueue.main.async {
                do {
                    self.open(try ImageDocument(session: session, image: result.get(), name: url.lastPathComponent))
                } catch {
                    NSAlert(error: error).runModal()
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
        case #selector(newDocument(_:)), #selector(openDocument(_:)):
            // A plug-in dialog is modal for the engine (glims_engine.h).
            return session != nil && !PlugInCommands.isRunning
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
