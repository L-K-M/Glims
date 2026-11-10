import AppKit
import RigiUI

private struct ToolMenuNativeState: Equatable {
    let info: EngineSession.ImageInfo
    let layers: [EngineSession.Layer]
    let pixels: Data
    let bounds: CGRect?
    let outline: [EngineSession.Segment]
    let history: EngineSession.UndoInfo
}

@MainActor
private final class ToolColorMenuSmokeHost: NSObject, NSApplicationDelegate {
    var result: Int32 = 1
    var completed = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        perform(#selector(runChecks(_:)), with: nil, afterDelay: 0)
    }
    @objc private func runChecks(_ unused: Any?) {
        result = EngineSmokeTest.run()
        completed = true
        NSApp.stop(nil)
        if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
            NSApp.postEvent(wake, atStart: true)
        }
    }
}

@MainActor
extension EngineSmokeTest {
    static func runHostedToolColorMenus() -> Int32 {
        let app = NSApplication.shared
        guard !app.isRunning, app.delegate == nil, !NSRunningApplication.current.isFinishedLaunching else {
            print("FAIL tool/color menus require their own unlaunched AppKit host")
            return 1
        }
        let previous = app.activationPolicy()
        guard app.setActivationPolicy(.regular) else { return 1 }
        let host = ToolColorMenuSmokeHost()
        app.delegate = host
        defer { app.delegate = nil; _ = app.setActivationPolicy(previous) }
        app.run()
        return host.completed ? host.result : 1
    }

    /// A real launched AppKit loop and the existing smoke engine. The temporary
    /// app delegate is installed after launch, so its startup callback never
    /// starts a second engine or needs an injected private session.
    static func exerciseToolColorMenus(_ session: EngineSession, documents: DocumentList) throws {
        var checks = 0
        func expect(_ value: Bool, _ message: String) {
            checks += 1
            check(value, "tool/color menus: \(message)")
        }
        func pump() {
            let end = Date().addingTimeInterval(0.01)
            while Date() < end, let event = NSApp.nextEvent(matching: .any, until: Date(), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
            NSApp.updateWindows()
            _ = RunLoop.main.run(mode: .default, before: end)
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let end = Date().addingTimeInterval(15)
            while Date() < end {
                if condition() { return true } // A semaphore predicate is consuming.
                pump()
            }
            return false
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "ToolMenuFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func snapshot(_ image: Int32) throws -> ToolMenuNativeState {
            ToolMenuNativeState(info: try session.info(image), layers: try session.layers(image),
                pixels: try session.copyPixels(image, merged: true).pixels,
                bounds: try session.selectionBounds(image: image),
                outline: try session.selectionOutline(image: image), history: try session.undoInfo(image))
        }
        func descendants<T: NSView>(_ view: NSView?, _ type: T.Type) -> [T] {
            guard let view else { return [] }
            return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, type) }
        }
        func leaves(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { item in item.submenu.map(leaves) ?? (item.isSeparatorItem ? [] : [item]) }
        }

        let state = ToolState.shared
        let oldTool = state.current, oldForeground = state.foreground, oldBackground = state.background
        let previousDelegate = NSApp.delegate
        let owner = AppController()
        // The Tools palette edits shared context without an engine gate.
        // Using a delegate with no session also proves the new routes do so.
        NSApp.delegate = owner
        var controller: DocumentWindowController?
        var orphan: Int32?
        var releases: [DispatchSemaphore] = []
        let field = NSTextField(string: "")
        let palette = ToolsPaletteController()
        defer {
            releases.forEach { $0.signal() }
            // Restore before the last window closes: the temporary owner's
            // engine-free last-window policy must not initiate app termination.
            NSApp.delegate = previousDelegate
            state.foreground = oldForeground; state.background = oldBackground
            state.select(oldTool)
            field.window?.makeFirstResponder(nil)
            field.removeFromSuperview()
            if let controller {
                if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet, returnCode: .abort) }
                controller.closeDiscardingChanges()
                let closed = wait { (try? session.info(controller.imageDocument.image)) == nil }
                expect(closed && controller.imageDocument.pendingWork == 0, "owned document drains before native shutdown")
                expect(controller.window?.attachedSheet == nil, "teardown leaves no owned sheet")
                documents.items.removeAll { $0 === controller.imageDocument }
            }
            if let orphan { try? session.closeImage(orphan) }
            print("     tool-color-menu checks: \(checks)")
        }
        let image = try session.newImage(width: 32, height: 24)
        orphan = image
        let document = try ImageDocument(session: session, image: image, name: "Tool/color menu")
        let window = DocumentWindowController(document: document)
        controller = window
        orphan = nil
        documents.items.append(document)
        window.showWindow(nil)
        window.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        try require(wait { NSApp.mainWindow === window.window && NSApp.keyWindow === window.window }, "tool menu document did not obtain real AppKit focus")
        _ = palette.view
        guard let grid = descendants(palette.view, ClassicToolGrid.self).first else {
            throw NSError(domain: "ToolMenuFixture", code: 2)
        }
        let before = try snapshot(image)
        guard let root = NSApp.mainMenu,
              let tools = root.item(withTitle: "View")?.submenu?.item(withTitle: "Tools")?.submenu else {
            expect(false, "actual View menu contains Tools")
            return
        }
        let items = leaves(tools)
        let toolItems = items.filter { $0.action == Selector(("selectToolFromMenu:")) }
        let expected: [(String, ToolID)] = [
            ("Move", .move), ("Transform", .transform), ("Crop", .crop),
            ("Rectangle Select", .rectangleSelect), ("Ellipse Select", .ellipseSelect), ("Lasso", .lasso),
            ("Magic Wand", .magicWand), ("Select by Color", .selectByColor), ("Eyedropper", .eyedropper),
            ("Text", .text), ("Path", .path), ("Brush", .paintbrush), ("Pencil", .pencil), ("Airbrush", .airbrush),
            ("Eraser", .eraser), ("Clone", .clone), ("Heal", .heal), ("Smudge", .smudge),
            ("Blur", .blur), ("Sharpen", .sharpen), ("Dodge", .dodge), ("Burn", .burn),
            ("Gradient", .gradient), ("Paint Bucket", .bucketFill), ("Hand", .hand), ("Zoom", .zoom),
        ]
        expect(toolItems.count == 26 && Set(toolItems.map(\.tag)).count == 26 && tools.items.count == 19,
               "actual menu mirrors exactly 26 choices in the 16 palette slots")
        expect(items.allSatisfy { $0.keyEquivalent.isEmpty && $0.keyEquivalentModifierMask.isEmpty },
               "every tool and color command has an unassigned factory shortcut")
        expect(owner.session == nil && items.allSatisfy(owner.validateMenuItem), "global context commands validate without an app-owned engine session")
        for (name, tool) in expected {
            guard let item = toolItems.first(where: { $0.title == name }), let action = item.action else {
                throw NSError(domain: "ToolMenuFixture", code: 3, userInfo: [NSLocalizedDescriptionKey: "Missing tool: \(name)"])
            }
            expect(NSApp.sendAction(action, to: nil, from: item) && state.current == tool,
                   "actual menu dispatch selects \(name) through the app delegate")
            toolItems.forEach { _ = owner.validateMenuItem($0) }
            expect(item.state == .on && toolItems.filter { $0.state == .on }.count == 1,
                   "\(name) is the sole cached selected menu mark")
            expect(grid.selectedToolID == tool.rawValue, "the existing Tools palette follows menu selection of \(name)")
        }
        expect(try snapshot(image) == before, "all 26 context choices leave native pixels, selection and history unchanged")
        guard let swap = items.first(where: { $0.action == Selector(("swapColorsFromMenu:")) }),
              let reset = items.first(where: { $0.action == Selector(("resetColorsFromMenu:")) }) else {
            throw NSError(domain: "ToolMenuFixture", code: 4)
        }
        func send(_ item: NSMenuItem) {
            if let action = item.action { _ = NSApp.sendAction(action, to: nil, from: item) }
        }
        state.foreground = .red; state.background = .cyan
        send(swap)
        expect(state.foreground.isEqual(NSColor.cyan) && state.background.isEqual(NSColor.red), "Swap Colors exchanges the shared palette values")
        send(reset)
        expect(state.foreground.isEqual(NSColor.black) && state.background.isEqual(NSColor.white), "Default Colors uses the existing black-on-white reset")
        send(reset)
        expect(state.foreground.isEqual(NSColor.black) && state.background.isEqual(NSColor.white), "Default Colors is an honest no-image context reset when already default")
        expect(try snapshot(image) == before, "color commands add no native pixels, selection or Undo changes")

        // Real field-editor input, not insertText called directly or only a
        // performKeyEquivalent probe. V/M/B would pick tools, X/D change colors
        // if a canvas/menu handler stole these unmodified text events.
        field.frame = NSRect(x: 12, y: 12, width: 200, height: 24)
        field.isEditable = true; field.isSelectable = true
        window.window?.contentView?.addSubview(field)
        window.window?.makeFirstResponder(field)
        try require(wait { field.currentEditor() === window.window?.firstResponder && field.currentEditor() != nil }, "the editable field did not acquire its real field editor")
        state.select(.paintbrush); state.foreground = .red; state.background = .cyan
        let keys: [(String, UInt16, NSEvent.ModifierFlags)] = [("v", 9, []), ("m", 46, []), ("x", 7, []), ("d", 2, []), ("B", 11, [.shift])]
        for (text, code, flags) in keys {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.window?.windowNumber ?? 0,
                context: nil, characters: text, charactersIgnoringModifiers: text.lowercased(), isARepeat: false, keyCode: code) else {
                throw NSError(domain: "ToolMenuFixture", code: 5)
            }
            if text == "d" {
                for candidate in leaves(root) where candidate.keyEquivalent.lowercased() == "d" {
                    print("MENU KEY DIAG title=\(candidate.title) action=\(String(describing: candidate.action)) key=\(candidate.keyEquivalent) mask=\(candidate.keyEquivalentModifierMask.rawValue) event=\(event.modifierFlags.rawValue)")
                }
            }
            expect(!root.performKeyEquivalent(with: event), "factory menu does not claim plain \(text)")
            NSApp.sendEvent(event)
            pump()
        }
        expect(field.currentEditor()?.string == "vmxdB" || field.stringValue == "vmxdB", "all plain letters arrive in the actual editable text field")
        expect(state.current == .paintbrush && state.foreground.isEqual(NSColor.red) && state.background.isEqual(NSColor.cyan),
               "typing does not select, swap or reset global context")
        expect(try snapshot(image) == before, "actual text-field typing leaves native image/history unchanged")
        window.window?.makeFirstResponder(window.canvas)
        field.removeFromSuperview()

        let invalid = NSMenuItem(title: "Invalid", action: Selector(("selectToolFromMenu:")), keyEquivalent: "")
        invalid.identifier = MenuShortcutBridge.builtinIdentifier
        for tag in [-1, 0, 27, 1001, Int.max] {
            invalid.tag = tag
            expect(!owner.validateMenuItem(invalid), "unknown tool tag \(tag) is refused")
            owner.selectToolFromMenu(invalid)
        }
        invalid.tag = 1; invalid.identifier = nil
        owner.selectToolFromMenu(invalid); owner.selectToolFromMenu(nil)
        expect(state.current == .paintbrush, "invalid sender/tag identities cannot fall back to another tool")
        let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        releases.append(release)
        let admitted = EngineActivity.shared.perform(label: "Tool context busy oracle", work: {
            ready.signal(); release.wait()
        }, completion: {})
        try require(admitted && wait { ready.wait(timeout: .now()) == .success }, "busy context oracle did not enter")
        expect(items.allSatisfy(owner.validateMenuItem), "tool/color context remains available during real engine activity")
        guard let hand = toolItems.first(where: { $0.title == "Hand" }) else {
            throw NSError(domain: "ToolMenuFixture", code: 6)
        }
        send(hand); send(swap)
        expect(state.current == .hand && state.foreground.isEqual(NSColor.cyan) && state.background.isEqual(NSColor.red),
               "busy context commands still use the same shared selection/color paths")
        expect(try snapshot(image) == before && document.pendingWork == 0, "busy tool/color changes queue no image work or Undo")
        release.signal()
        try require(wait { !EngineActivity.shared.isBusy }, "busy context oracle did not finish")
        expect(try snapshot(image) == before, "final native image, layer list, selection and history equal the original")
    }
}
