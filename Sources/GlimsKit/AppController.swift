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

    private lazy var layersPalette: Palette = PaletteCenter.shared.palette(
        for: LayersPaletteController.definition,
        target: { [weak self] in self?.frontDocument },
        makeContent: { LayersPaletteController() })

    var frontDocument: ImageDocument? {
        (NSApp.mainWindow?.windowController as? DocumentWindowController)?.imageDocument ?? documents.last?.imageDocument
    }

    var session: EngineSession? {
        if case .running(let session) = state { return session }
        return nil
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
        for controller in documents { controller.imageDocument.handle(event) }
        if case .message(let text) = event {
            (NSApp.mainWindow?.windowController as? DocumentWindowController)?.statusBar.message = text
        }
    }

    func open(_ document: ImageDocument) {
        let controller = DocumentWindowController(document: document)
        controller.onClose = { [weak self] closed in
            self?.documents.removeAll { $0 === closed }
            PaletteCenter.shared.frontDocumentDidChange()
        }
        documents.append(controller)
        controller.showWindow(nil)
        PaletteCenter.shared.frontDocumentDidChange()
        if !layersPalette.isPresented { layersPalette.showPanel() }
    }

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

    @objc func showLayers(_ sender: Any?) {
        layersPalette.isPresented ? layersPalette.bringToFront() : layersPalette.showPanel()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(newDocument(_:)), #selector(openDocument(_:)), #selector(showLayers(_:)):
            return session != nil
        default:
            return true
        }
    }
}
