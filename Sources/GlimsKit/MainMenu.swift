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
            .separator(),
            item("Stroke Path", #selector(DocumentWindowController.strokePath(_:))),
        ])
        // Plug-in commands are appended to Image, Layer and Select (PlugInMenus).
        add(menu, "Image", [
            item("Image Size…", #selector(DocumentWindowController.imageSize(_:))),
            item("Canvas Size…", #selector(DocumentWindowController.canvasSize(_:))),
            submenu("Rotate", [
                item("90° Clockwise", #selector(DocumentWindowController.rotateImage90(_:))),
                item("90° Counter-Clockwise", #selector(DocumentWindowController.rotateImage270(_:))),
                item("180°", #selector(DocumentWindowController.rotateImage180(_:))),
                .separator(),
                item("Flip Horizontal", #selector(DocumentWindowController.flipImageHorizontally(_:))),
                item("Flip Vertical", #selector(DocumentWindowController.flipImageVertically(_:))),
            ]),
            .separator(),
            item("Crop to Selection", #selector(DocumentWindowController.cropToSelection(_:))),
            item("Flatten Image", #selector(DocumentWindowController.flattenImage(_:))),
        ])
        let newLayer = item("New Layer", #selector(DocumentWindowController.newLayer(_:)), "n")
        newLayer.keyEquivalentModifierMask = [.command, .shift]
        let toFront = item("Bring to Front", #selector(DocumentWindowController.bringLayerToFront(_:)), "]")
        toFront.keyEquivalentModifierMask = [.command, .shift]
        let toBack = item("Send to Back", #selector(DocumentWindowController.sendLayerToBack(_:)), "[")
        toBack.keyEquivalentModifierMask = [.command, .shift]
        let arrange = NSMenuItem(title: "Arrange", action: nil, keyEquivalent: "")
        arrange.submenu = NSMenu(title: "Arrange")
        [toFront,
         item("Bring Forward", #selector(DocumentWindowController.bringLayerForward(_:)), "]"),
         item("Send Backward", #selector(DocumentWindowController.sendLayerBackward(_:)), "["),
         toBack].forEach { arrange.submenu?.addItem($0) }
        add(menu, "Layer", [
            newLayer,
            item("Duplicate Layer", #selector(DocumentWindowController.duplicateLayer(_:)), "j"),
            item("Delete Layer", #selector(DocumentWindowController.deleteLayer(_:))),
            .separator(),
            item("Layer Properties…", #selector(DocumentWindowController.layerProperties(_:))),
            arrange,
            submenu("Transform", [
                item("Rotate 90° Clockwise", #selector(DocumentWindowController.rotateLayer90(_:))),
                item("Rotate 90° Counter-Clockwise", #selector(DocumentWindowController.rotateLayer270(_:))),
                item("Rotate 180°", #selector(DocumentWindowController.rotateLayer180(_:))),
                .separator(),
                item("Flip Horizontal", #selector(DocumentWindowController.flipLayerHorizontally(_:))),
                item("Flip Vertical", #selector(DocumentWindowController.flipLayerVertically(_:))),
            ]),
            .separator(),
            item("Merge Down", #selector(DocumentWindowController.mergeDown(_:)), "e"),
        ])
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
            item("From Path", #selector(DocumentWindowController.selectFromPath(_:))),
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
            item("Paths", #selector(AppController.showPaths(_:))),
            item("Hide Palettes", #selector(AppController.togglePaletteVisibility(_:))),
            item("Reset Palettes", #selector(AppController.resetPaletteLayout(_:))),
        ])
        NSApplication.shared.windowsMenu = windowMenu

        return menu
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: title)
        items.forEach { item.submenu?.addItem($0) }
        return item
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
