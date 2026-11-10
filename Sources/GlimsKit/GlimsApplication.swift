import AppKit

/// Entry point shared by the executable and tests.
@MainActor
public enum GlimsApplication {

    /// Keeps the delegate alive; `NSApplication.delegate` is weak.
    private static var controller: AppController?

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
        // Rigi draws its chrome light, so the whole app keeps the light
        // Aqua appearance even when the Mac uses Dark Mode; system-colored
        // text would otherwise turn white on light bars (Rigi's interface
        // guidelines, "Appearance").
        app.appearance = NSAppearance(named: .aqua)
        app.setActivationPolicy(mode == .interactive ? .regular : .accessory)
        app.mainMenu = MainMenu.make()

        switch mode {
        case .smokeTest:
            let workspace = WorkspaceWindowController()
            workspace.window?.orderFront(nil)
            return SmokeTest.run(workspace)
        case .engineSmokeTest:
            if let smokeCase = ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"],
               ["metadata-rating-edit", "layer-rasterize-batch", "layer-restore-batch",
                "tablet-eraser-proximity", "recorder-layer-properties", "text-floating-create",
                "displace-source", "recorder-file-ui"].contains(smokeCase) {
                return EngineSmokeTestHost.run()
            }
            return EngineSmokeTest.run()
        case .interactive, .printVersion:
            let controller = AppController()
            Self.controller = controller
            app.delegate = controller
            app.run()
            return 0
        }
    }
}
