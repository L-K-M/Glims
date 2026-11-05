import AppKit

/// The menu bar. Items act through the responder chain: document commands
/// reach the front `DocumentWindowController`, app commands the
/// `AppController`. The full outline is in docs/design.md, section 4.
@MainActor
enum MainMenu {
    static let recentlyUsedTitle = "Recently Used"

    static func make() -> NSMenu {
        let menu = NSMenu()

        add(menu, AppIdentity.name, [
            item("About \(AppIdentity.name)", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            .separator(),
            item("Hide \(AppIdentity.name)", #selector(NSApplication.hide(_:)), "h"),
            item("Quit \(AppIdentity.name)", #selector(NSApplication.terminate(_:)), "q"),
        ])
        add(menu, "File", [
            item("New", #selector(AppController.newDocument(_:)), "n"),
            item("Open…", #selector(AppController.openDocument(_:)), "o"),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save As…", #selector(DocumentWindowController.saveDocumentAs(_:)), "S"),
            item("Export…", #selector(DocumentWindowController.exportDocument(_:)), "E"),
        ])
        add(menu, "Edit", [
            // Answered by the key window from its undo manager.
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "Z"),
        ])
        // Image, Layer and Select hold the engine's plug-in commands until
        // their native commands arrive (PlugInMenus).
        add(menu, "Image", [])
        add(menu, "Layer", [])
        let inverse = item("Inverse", #selector(DocumentWindowController.selectInverse(_:)), "i")
        inverse.keyEquivalentModifierMask = [.command, .shift]
        add(menu, "Select", [
            item("All", #selector(DocumentWindowController.selectAll(_:)), "a"),
            item("Deselect", #selector(DocumentWindowController.selectNone(_:)), "d"),
            inverse,
            .separator(),
            item("Feather…", #selector(DocumentWindowController.featherSelection(_:))),
            item("Grow…", #selector(DocumentWindowController.growSelection(_:))),
            item("Shrink…", #selector(DocumentWindowController.shrinkSelection(_:))),
            item("Border…", #selector(DocumentWindowController.borderSelection(_:))),
            item("Remove Antialiasing", #selector(DocumentWindowController.sharpenSelection(_:))),
            .separator(),
            item("From Layer Transparency", #selector(DocumentWindowController.selectFromAlpha(_:))),
        ])
        add(menu, "View", [
            item("Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(DocumentWindowController.zoomOut(_:)), "-"),
            item("Actual Pixels", #selector(DocumentWindowController.actualPixels(_:)), "1"),
        ])
        let lastFilterSettings = item("Last Filter Settings…", #selector(DocumentWindowController.reshowLastFilter(_:)), "f")
        lastFilterSettings.keyEquivalentModifierMask = [.command, .option]
        let recent = NSMenuItem(title: recentlyUsedTitle, action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: recentlyUsedTitle)
        let blur = NSMenuItem(title: "Blur", action: nil, keyEquivalent: "")
        blur.submenu = NSMenu(title: "Blur")
        blur.submenu?.addItem(item("Gaussian Blur…", #selector(DocumentWindowController.gaussianBlur(_:))))
        add(menu, "Filter", [
            item("Last Filter", #selector(DocumentWindowController.repeatLastFilter(_:)), "f"),
            lastFilterSettings,
            recent,
            .separator(),
            blur,
        ])
        let windowMenu = add(menu, "Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            .separator(),
            item("Tools", #selector(AppController.showTools(_:))),
            item("Tool Options", #selector(AppController.showToolOptions(_:))),
            item("Layers", #selector(AppController.showLayers(_:))),
        ])
        NSApplication.shared.windowsMenu = windowMenu

        return menu
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        NSMenuItem(title: title, action: action, keyEquivalent: key)
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let submenu = NSMenu(title: title)
        items.forEach(submenu.addItem)
        menu.addItem(withTitle: title, action: nil, keyEquivalent: "").submenu = submenu
        return submenu
    }
}
