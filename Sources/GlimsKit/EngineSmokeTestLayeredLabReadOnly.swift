import AppKit

extension EngineSmokeTest {
    static func exerciseLayeredLabReadOnly(session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        guard let path = ProcessInfo.processInfo.environment["GLIMS_LAYERED_LAB_FIXTURE"],
              !path.isEmpty else {
            throw NSError(domain: "LayeredLabSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing layered Lab fixture path"])
        }
        let image = try session.openImage(path: path)
        var document: ImageDocument?
        var controller: DocumentWindowController?
        let palette = LayersPaletteController()
        let paletteWindow = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 260, height: 300),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        paletteWindow.isReleasedWhenClosed = false
        defer {
            palette.retarget(to: nil)
            paletteWindow.orderOut(nil)
            paletteWindow.close()
            if let controller, !controller.closeStarted { controller.closeDiscardingChanges() }
            if let document {
                if controller == nil && !document.isClosing { document.closeImageWhenDrained() }
                let deadline = Date().addingTimeInterval(15)
                while (try? session.info(image)) != nil && Date() < deadline {
                    EngineSmokeTestHost.pumpEvents(for: 0.02)
                }
                check((try? session.info(image)) == nil, "layered Lab document closes")
                documents.items.removeAll { $0 === document }
            } else {
                try? session.closeImage(image)
            }
        }
        let opened = try ImageDocument(session: session, image: image, name: "Layered Lab",
                                       openedFrom: URL(fileURLWithPath: path))
        document = opened
        documents.items.append(opened)
        let windowController = DocumentWindowController(document: opened, exportDirectory: work)
        controller = windowController
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        paletteWindow.contentView = palette.view
        palette.retarget(to: opened)
        paletteWindow.orderFront(nil)
        EngineSmokeTestHost.pumpEvents(for: 0.2)
        check(windowController.window?.title.contains("Read-only") == true,
              "document window identifies the read-only state")
        let selectAll = NSMenuItem(title: "Select All", action: #selector(DocumentWindowController.selectAll(_:)), keyEquivalent: "")
        check(!windowController.validateMenuItem(selectAll), "editing menu commands are disabled")
        let saveCopy = NSMenuItem(title: "Save a Copy", action: #selector(DocumentWindowController.saveDocumentCopy(_:)), keyEquivalent: "")
        check(windowController.validateMenuItem(saveCopy), "Save a Copy stays available")
        // Exercise AppKit's actual target resolution, not a direct call to
        // the document controller for selectors it does not implement.
        let previousDelegate = NSApp.delegate
        let previousMenu = NSApp.mainMenu
        let appOwner = AppController(session: session)
        NSApp.delegate = appOwner
        NSApp.mainMenu = MainMenu.make()
        defer { NSApp.delegate = previousDelegate; NSApp.mainMenu = previousMenu }
        NSApp.activate(ignoringOtherApps: true)
        windowController.window?.makeKeyAndOrderFront(nil)
        windowController.window?.makeMain()
        let keyDeadline = Date().addingTimeInterval(3)
        while NSApp.keyWindow !== windowController.window && Date() < keyDeadline {
            EngineSmokeTestHost.pumpEvents(for: 0.02)
        }
        func menuItem(_ action: Selector, in menu: NSMenu?) -> NSMenuItem? {
            guard let menu else { return nil }
            for item in menu.items {
                if item.action == action { return item }
                if let found = menuItem(action, in: item.submenu) { return found }
            }
            return nil
        }
        for (label, action) in [("New", #selector(AppController.newDocument(_:))),
                                ("Open", #selector(AppController.openDocument(_:))),
                                ("Preferences", #selector(AppController.showPreferences(_:)))] {
            if let item = menuItem(action, in: NSApp.mainMenu) {
                let target = NSApp.target(forAction: action, to: item.target, from: item)
                let validation = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
                check((target as AnyObject?) === appOwner && validation,
                      "read-only document leaves application \(label) available")
            } else { check(false, "application \(label) menu item exists") }
        }
        if let item = menuItem(#selector(NSWindow.performMiniaturize(_:)), in: NSApp.mainMenu) {
            let target = NSApp.target(forAction: #selector(NSWindow.performMiniaturize(_:)), to: item.target, from: item)
            let validation = (target as? NSMenuItemValidation)?.validateMenuItem(item) ?? true
            check((target as AnyObject?) === windowController.window && validation,
                  "read-only document leaves window Minimize available (target: \(String(describing: target)), key: \(String(describing: NSApp.keyWindow)))")
        } else { check(false, "window Minimize menu item exists") }
        check(opened.storage.layout == .layeredLab && opened.storage.readOnly,
              "document recognizes read-only layered Lab storage")
        check(!opened.acceptsEdits && opened.acceptsLayerSelection,
              "layer selection remains available while editing is disabled")
        check(opened.colorInfo.mode == .lab && opened.labAxes == nil && opened.channels.isEmpty,
              "document does not expose private Lab planes as channels")
        check(opened.layers.count == 2, "document shows two logical layers")
        check(!opened.toolIsAvailable(.paintbrush) && opened.toolIsAvailable(.zoom),
              "editing tools are unavailable while zoom remains available")
        func outline(in view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            return view.subviews.lazy.compactMap { outline(in: $0) }.first
        }
        if let other = opened.layers.first(where: { !opened.selectedLayerIDs.contains($0.id) }),
           let list = outline(in: palette.view),
           let row = (0..<list.numberOfRows).first(where: { index in
               guard let node = list.item(atRow: index) as? LayerTree.Node else { return false }
               return node.layer.id == other.id
           }), let item = list.item(atRow: row) {
            check(palette.outlineView(list, shouldSelectItem: item), "palette permits a logical layer pick")
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let deadline = Date().addingTimeInterval(15)
            while opened.pendingWork > 0 && Date() < deadline {
                EngineSmokeTestHost.pumpEvents(for: 0.02)
            }
            check(opened.selectedLayerIDs == [other.id] && (try? session.selectedLayers(image)) == [other.id],
                  "logical layer selection reaches the engine")
        } else {
            check(false, "fixture has a second selectable layer")
        }
        let busyReady = DispatchSemaphore(value: 0), busyRelease = DispatchSemaphore(value: 0)
        let busyAdmitted = EngineActivity.shared.perform(label: "Layered Lab selection test", work: {
            busyReady.signal(); busyRelease.wait()
        }, completion: {})
        check(busyAdmitted, "busy selection fixture is admitted")
        if busyAdmitted {
            defer { busyRelease.signal() }
            let deadline = Date().addingTimeInterval(15)
            while busyReady.wait(timeout: .now()) != .success && Date() < deadline {
                EngineSmokeTestHost.pumpEvents(for: 0.02)
            }
            var message: String?
            let previousError = opened.onError
            opened.onError = { message = $0 }
            let before = opened.selectedLayerIDs
            if let other = opened.layers.first(where: { !before.contains($0.id) }),
               let list = outline(in: palette.view),
               let row = (0..<list.numberOfRows).first(where: { index in
                   (list.item(atRow: index) as? LayerTree.Node)?.layer.id == other.id
               }), let item = list.item(atRow: row) {
                check(!palette.outlineView(list, shouldSelectItem: item) && message != nil && opened.selectedLayerIDs == before,
                      "a busy logical-layer pick explains its refusal and leaves the selection unchanged")
            } else { check(false, "busy fixture has a second selectable layer") }
            opened.onError = previousError
        }
        let idleDeadline = Date().addingTimeInterval(15)
        while EngineActivity.shared.isBusy && Date() < idleDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
        check(!EngineActivity.shared.isBusy, "busy selection fixture drains")
        let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 1, height: 1))
        check(rendered.width == 1 && rendered.height == 1, "layered Lab canvas renders")
        let copy = work.appendingPathComponent("layered-copy.xcf")
        var copyFinished = false
        var copyError: Error?
        opened.saveCopy(to: copy) { error in copyError = error; copyFinished = true }
        let saveDeadline = Date().addingTimeInterval(30)
        while !copyFinished && Date() < saveDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
        guard copyFinished, copyError == nil else {
            throw copyError ?? NSError(domain: "LayeredLabSmoke", code: 2,
                                       userInfo: [NSLocalizedDescriptionKey: "Save copy did not finish"])
        }
        check(true, "document saves an XCF copy")
        let reopened = try session.openImage(path: copy.path)
        defer { try? session.closeImage(reopened) }
        check(try session.imageStorage(reopened).layout == .layeredLab,
              "saved XCF copy reopens as layered Lab")
    }
}
