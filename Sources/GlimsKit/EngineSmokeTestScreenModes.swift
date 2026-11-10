import AppKit
import RigiUI

@MainActor
private final class ScreenModeSmokeHost: NSObject, NSApplicationDelegate {
    var result: Int32 = 1
    var completed = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        perform(#selector(runChecks(_:)), with: nil, afterDelay: 0)
    }

    @objc private func runChecks(_ sender: Any?) {
        result = EngineSmokeTest.run()
        completed = true
        NSApp.stop(nil)
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero,
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            subtype: 0, data1: 0, data2: 0) { NSApp.postEvent(wake, atStart: true) }
    }
}

@MainActor
extension EngineSmokeTest {
    static func runHostedScreenModes() -> Int32 {
        let app = NSApplication.shared
        guard !app.isRunning, app.delegate == nil,
              !NSRunningApplication.current.isFinishedLaunching else { return 1 }
        let policy = app.activationPolicy()
        guard app.setActivationPolicy(.regular) else { return 1 }
        let host = ScreenModeSmokeHost()
        app.delegate = host
        defer { app.delegate = nil; _ = app.setActivationPolicy(policy) }
        app.run()
        return host.completed ? host.result : 1
    }

    static func exerciseScreenModes(_ session: EngineSession, documents: DocumentList) throws {
        var count = 0
        func expect(_ value: Bool, _ message: String) {
            count += 1
            check(value, "screen modes: \(message)")
        }
        func pump() {
            let deadline = Date().addingTimeInterval(0.01)
            while Date() < deadline,
                  let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            _ = RunLoop.main.run(mode: .default, before: deadline)
        }
        func wait(_ message: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if condition() { return }
                pump()
            }
            throw NSError(domain: "ScreenModeFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
        }
        func descendants<T: NSView>(_ root: NSView, _ type: T.Type) -> [T] {
            ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { descendants($0, type) }
        }
        var owners: [DocumentWindowController] = []
        var images: [Int32] = []
        var panels: [NSWindow] = []
        let originalTool = ToolState.shared.current
        var complete = false
        defer {
            for owner in owners {
                if owner.window?.styleMask.contains(.fullScreen) == true {
                    owner.window?.toggleFullScreen(nil)
                    try? wait("owned full-screen exit during cleanup", {
                        owner.window?.styleMask.contains(.fullScreen) != true
                    })
                }
                owner.window?.orderOut(nil)
                var stopped = false
                owner.canvas.stopRendering { stopped = true }
                try? wait("owned screen-mode renderer drain", { stopped })
                owner.window?.close()
                owner.imageDocument.closeImageWhenDrained()
            }
            panels.forEach { $0.close() }
            try? wait("owned screen-mode images close", {
                images.allSatisfy { (try? session.info($0)) == nil }
            })
            expect(images.allSatisfy { (try? session.info($0)) == nil }, "teardown closes every owned native image")
            expect(owners.allSatisfy { $0.window?.attachedSheet == nil }
                && panels.allSatisfy { !$0.isVisible }, "teardown leaves no owned dialog or palette")
            documents.items.removeAll { candidate in owners.contains { $0.imageDocument === candidate } }
            ToolState.shared.select(originalTool)
            expect(complete, "all screen-mode scenarios complete")
            print("     screen-mode checks: \(count)")
        }
        func make(_ title: String) throws -> DocumentWindowController {
            let image = try session.newImage(width: 48, height: 32)
            images.append(image)
            let doc = try ImageDocument(session: session, image: image, name: title)
            documents.items.append(doc)
            let owner = DocumentWindowController(document: doc)
            owners.append(owner)
            owner.showWindow(nil)
            return owner
        }
        let a = try make("Screen Modes A"), b = try make("Screen Modes B")
        let originalPixels = try session.copyPixels(a.imageDocument.image, merged: true).pixels
        let originalHistory = try session.undoInfo(a.imageDocument.image)
        let otherPixels = try session.copyPixels(b.imageDocument.image, merged: true).pixels
        let otherHistory = try session.undoInfo(b.imageDocument.image)
        let originalFrame = a.window!.frame
        let originalStyle = a.window!.styleMask
        let originalCollection = a.window!.collectionBehavior
        let originalMovable = a.window!.isMovable
        ToolState.shared.select(.hand)
        NSApp.activate(ignoringOtherApps: true)
        a.window?.makeKeyAndOrderFront(nil)
        a.window?.makeFirstResponder(a.canvas)
        try wait("A becomes the actual key document", { NSApp.isActive && NSApp.keyWindow === a.window })
        let originalOptions = NSApp.presentationOptions
        let palette = ToolsPaletteController()
        let panel = ClassicPaletteWindow(contentSize: ToolsPaletteController.definition.contentSize)
        panels.append(panel)
        panel.contentView = palette.view
        panel.setFrameOrigin(NSPoint(x: 20, y: 100))
        palette.retarget(to: a.imageDocument)
        panel.orderFront(nil)
        guard let segments = descendants(palette.view, NSSegmentedControl.self).first(where: {
            $0.accessibilityLabel() == "Screen mode"
        }), let modes = NSApp.mainMenu?.item(withTitle: "View")?.submenu?.item(withTitle: "Screen Mode")?.submenu else {
            return expect(false, "actual menus and visible Tools palette expose mode controls")
        }
        expect(panel.isVisible && segments.isEnabled && segments.segmentCount == 3,
               "the visible native palette has three enabled screen modes")
        expect(modes.items.map(\.title) == ["Windowed", "Full Screen with Menu", "Full Screen Bare"],
               "installed main menu names all three modes")
        expect(modes.items.allSatisfy { $0.keyEquivalent.isEmpty }, "plain F remains a canvas key rather than a global menu equivalent")
        func key(_ text: String, code: UInt16) throws {
            a.window?.makeKeyAndOrderFront(nil)
            a.window?.makeFirstResponder(a.canvas)
            try wait("canvas owns the actual key event", { NSApp.keyWindow === a.window })
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: a.window!.windowNumber,
                context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code) else {
                throw NSError(domain: "ScreenModeFixture", code: 2)
            }
            NSApp.sendEvent(event)
        }
        func settled(_ owner: DocumentWindowController, _ mode: DocumentScreenMode) throws {
            try wait("native screen transition reaches \(mode.title)", {
                owner.screenMode == mode && owner.screenModeState.phase == .stable
                    && owner.window?.styleMask.contains(.fullScreen) == false
                    && owner.window?.styleMask.contains(.titled) == (mode == .windowed)
            })
        }
        try key("f", code: 3)
        try settled(a, .fullScreenWithMenu)
        expect(!NSApp.presentationOptions.contains(.autoHideMenuBar)
            && !NSApp.presentationOptions.contains(.hideMenuBar) && NSMenu.menuBarVisible(),
               "first F fills the screen while the menu remains visible")
        expect(a.window!.canBecomeKey && a.window!.canBecomeMain && NSApp.mainWindow === a.window,
               "borderless document keeps actual key/main command ownership")
        expect(a.window!.frame.maxY <= a.window!.screen!.frame.maxY - NSStatusBar.system.thickness + 1,
               "menu mode reserves the actual menu strip above the document")
        expect(segments.selectedSegment == 1 && panel.isVisible, "palette follows its owning mode without changing visibility")
        expect(b.screenMode == .windowed && b.window?.styleMask.contains(.fullScreen) == false,
               "A's native mode change leaves B windowed")
        try key("f", code: 3)
        try settled(a, .fullScreenBare)
        expect(NSApp.presentationOptions.contains(.autoHideMenuBar), "second F enters bare mode with auto-hidden menu")
        expect(segments.selectedSegment == 2 && panel.isVisible, "bare mode preserves the user's visible palette")
        try key("f", code: 3)
        try settled(a, .windowed)
        expect(abs(a.window!.frame.minX - originalFrame.minX) < 2
            && abs(a.window!.frame.minY - originalFrame.minY) < 2
            && abs(a.window!.frame.width - originalFrame.width) < 2
            && abs(a.window!.frame.height - originalFrame.height) < 2, "third F restores the original window frame")
        expect(a.window!.styleMask == originalStyle && a.window!.collectionBehavior == originalCollection
            && a.window!.isMovable == originalMovable, "windowed mode restores style, collection and movement")
        expect(NSApp.presentationOptions == originalOptions, "windowed mode restores the prior application presentation options")
        expect(segments.selectedSegment == 0 && panel.isVisible, "palette remains visible after the full cycle")

        palette.retarget(to: b.imageDocument)
        for mode in [DocumentScreenMode.fullScreenWithMenu, .fullScreenBare, .windowed] {
            segments.selectedSegment = mode.rawValue
            _ = segments.sendAction(segments.action, to: segments.target)
            try settled(b, mode)
            expect(a.screenMode == .windowed && b.screenMode == mode,
                   "visible mode control targets captured B for \(mode.title)")
        }
        palette.retarget(to: a.imageDocument)
        let field = NSTextField(frame: NSRect(x: 30, y: 40, width: 140, height: 24))
        a.window?.contentView?.addSubview(field)
        a.window?.makeKeyAndOrderFront(nil)
        a.window?.makeFirstResponder(field)
        guard let typed = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: a.window!.windowNumber,
            context: nil, characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3) else {
            throw NSError(domain: "ScreenModeFixture", code: 3)
        }
        NSApp.sendEvent(typed)
        expect(field.currentEditor()?.string == "f" && a.screenMode == .windowed,
               "real field-editor F types text without changing screen mode")
        a.window?.endEditing(for: nil)
        field.removeFromSuperview()

        for tag in [-1, 3, Int.max] {
            let invalid = NSMenuItem(title: "invalid", action: #selector(DocumentWindowController.chooseScreenMode(_:)), keyEquivalent: "")
            invalid.tag = tag
            expect(!a.validateMenuItem(invalid), "invalid screen mode tag \(tag) refuses without conversion")
            a.chooseScreenMode(invalid)
        }
        expect(a.screenMode == .windowed, "invalid packets perform no transition")
        _ = NSApp.sendAction(modes.items[2].action!, to: a, from: modes.items[2])
        try settled(a, .fullScreenBare)
        try key("\u{1b}", code: 53)
        try settled(a, .windowed)
        expect(!a.window!.styleMask.contains(.fullScreen), "idle Escape leaves bare mode")
        expect(try session.copyPixels(a.imageDocument.image, merged: true).pixels == originalPixels
            && session.undoInfo(a.imageDocument.image) == originalHistory,
               "all view and keyboard mode changes preserve A's native pixels and history")
        expect(try session.copyPixels(b.imageDocument.image, merged: true).pixels == otherPixels
            && session.undoInfo(b.imageDocument.image) == otherHistory,
               "captured palette changes preserve B's native pixels and history")
        panel.orderOut(nil)
        a.setScreenMode(.fullScreenWithMenu)
        try settled(a, .fullScreenWithMenu)
        a.setScreenMode(.fullScreenBare)
        a.window?.close()
        try wait("closing native full-screen window completes", {
            a.closeStarted && a.screenModeState.isClosed && a.window?.isVisible != true
        })
        expect(a.screenModeState.isClosed && !panel.isVisible && NSApp.presentationOptions == originalOptions,
               "closing restores presentation and preserves a hidden palette")
        complete = true
    }
}
