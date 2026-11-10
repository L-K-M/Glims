import AppKit

/// Focused window-server fixtures need AppKit's normal launch and real events.
/// This host installs no AppController and starts only the smoke engine.
@MainActor
enum EngineSmokeTestHost {
    static func run() -> Int32 {
        let app = NSApplication.shared
        guard !app.isRunning, app.delegate == nil,
              !NSRunningApplication.current.isFinishedLaunching else {
            print("FAIL focused smoke requires its own unlaunched AppKit host")
            return 1
        }
        let previousPolicy = app.activationPolicy()
        guard app.setActivationPolicy(.regular) else {
            print("FAIL focused smoke AppKit host could not become regular")
            return 1
        }
        let host = EngineSmokeTestHostDelegate()
        app.delegate = host
        defer {
            app.delegate = nil
            _ = app.setActivationPolicy(previousPolicy)
        }
        app.run()
        guard host.completed else {
            print("FAIL focused smoke AppKit host stopped before its checks completed")
            return 1
        }
        return host.result
    }

    /// A synchronous fixture suspends NSApp.run's outer event dispatch.
    /// Deliver actual events while also servicing queued engine completions.
    static func pumpEvents(for seconds: TimeInterval = 0.01) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            while Date() < end,
                  let event = NSApp.nextEvent(matching: .any, until: Date(),
                                             inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            _ = RunLoop.main.run(mode: .default, before: end)
        } while Date() < end
    }
}

@MainActor
private final class EngineSmokeTestHostDelegate: NSObject, NSApplicationDelegate {
    private(set) var result: Int32 = 1
    private(set) var completed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Let finishLaunching return before entering nested completion waits.
        perform(#selector(runChecks(_:)), with: nil, afterDelay: 0)
    }

    @objc private func runChecks(_ unused: Any?) {
        defer {
            completed = true
            NSApp.stop(nil)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
                                            modifierFlags: [], timestamp: 0, windowNumber: 0,
                                            context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: true)
            }
        }
        guard NSApp.isRunning else {
            print("FAIL focused smoke AppKit event loop did not start")
            return
        }
        print("focused smoke host finishedLaunching=true running=true")
        result = EngineSmokeTest.run()
    }
}
