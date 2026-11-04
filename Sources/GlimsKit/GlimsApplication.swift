import AppKit

/// Entry point shared by the executable and tests.
@MainActor
public enum GlimsApplication {

    /// Keeps the delegate alive; `NSApplication.delegate` is weak.
    private static var delegate: AppDelegate?

    /// Runs the app and returns the process exit status. Interactive runs only
    /// return when AppKit's run loop does.
    public static func run(arguments: [String]) -> Int32 {
        let mode: LaunchMode
        do {
            mode = try LaunchMode(arguments: Array(arguments.dropFirst()))
        } catch let error as LaunchMode.UnknownOption {
            FileHandle.standardError.write(Data("glims: unknown option \(error.option)\n".utf8))
            return 2
        } catch {
            FileHandle.standardError.write(Data("glims: \(error)\n".utf8))
            return 2
        }

        if mode == .printVersion {
            print("\(AppIdentity.name) \(AppIdentity.bundleVersion ?? "(unbundled)")")
            return 0
        }

        let app = NSApplication.shared
        app.setActivationPolicy(mode == .smokeTest ? .accessory : .regular)
        app.mainMenu = MainMenu.make()
        let controller = WorkspaceWindowController()

        if mode == .smokeTest {
            controller.window?.orderFront(nil)
            return SmokeTest.run(controller)
        }

        let delegate = AppDelegate(workspace: controller)
        Self.delegate = delegate
        app.delegate = delegate
        app.run()
        return 0
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private let workspace: WorkspaceWindowController

    init(workspace: WorkspaceWindowController) {
        self.workspace = workspace
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        workspace.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Until documents exist the workspace window is the whole app.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
