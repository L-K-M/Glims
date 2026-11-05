import AppKit

/// The menu bar. Items act through the responder chain: document commands
/// reach the front `DocumentWindowController`, app commands the
/// `AppController`. The full outline is in docs/design.md, section 4.
@MainActor
enum MainMenu {
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
            item("Undo", #selector(DocumentWindowController.undo(_:)), "z"),
            item("Redo", #selector(DocumentWindowController.redo(_:)), "Z"),
        ])
        add(menu, "View", [
            item("Zoom In", #selector(DocumentWindowController.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(DocumentWindowController.zoomOut(_:)), "-"),
            item("Actual Pixels", #selector(DocumentWindowController.actualPixels(_:)), "1"),
        ])
        add(menu, "Filter", [
            item("Gaussian Blur…", #selector(DocumentWindowController.gaussianBlur(_:))),
        ])
        let windowMenu = add(menu, "Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            .separator(),
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
