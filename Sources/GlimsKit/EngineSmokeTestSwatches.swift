import AppKit

@MainActor
extension EngineSmokeTest {
    /// Window ▸ Swatches through its actual grid: a click takes the
    /// foreground color, Option-click the background, a click on empty
    /// space adds the foreground color, Shift-click replaces and
    /// Command-click deletes a swatch, and none of it touches the image.
    static func exerciseSwatches(_ session: EngineSession, documents: DocumentList) throws {
        let suite = "ch.lkmc.Glims.smoke.swatches.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { return check(false, "a swatch defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let image = try session.newImage(width: 40, height: 30)
        let document = try ImageDocument(session: session, image: image, name: "Swatches")
        documents.items.append(document)
        let store = SwatchStore(defaults: defaults), tools = ToolState.shared
        let oldForeground = tools.foreground, oldBackground = tools.background
        let palette = SwatchesPaletteController(store: store)
        let host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 170),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentViewController = palette
        host.setContentSize(SwatchesPaletteController.definition.contentSize)
        host.orderFront(nil)
        host.contentView?.layoutSubtreeIfNeeded()
        palette.retarget(to: document)
        defer {
            tools.foreground = oldForeground; tools.background = oldBackground; tools.notifyChange()
            host.orderOut(nil); host.close()
            var closed = false; document.closeImageWhenDrained { closed = true }
            let deadline = Date().addingTimeInterval(10)
            while !closed && Date() < deadline { spin(0.01) }
            documents.items.removeAll { $0 === document }
        }

        let menuItem = NSApp.mainMenu?.item(withTitle: "Window")?.submenu?.items
            .first { $0.action == #selector(AppController.showSwatches(_:)) }
        check(menuItem?.title == "Swatches", "Window ▸ Swatches opens the palette")

        let grid = palette.grid
        func click(_ index: Int?, _ flags: NSEvent.ModifierFlags = []) {
            let count = grid.swatches.count
            let cell = grid.rect(at: index ?? count)
            let location = grid.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: flags,
                                                 timestamp: 0, windowNumber: host.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else {
                return check(false, "a swatch click constructs")
            }
            grid.mouseDown(with: event)
        }
        let historyBefore = try session.undoInfo(image), dirtyBefore = try session.info(image).isDirty
        check(grid.swatches == SwatchList.defaults && grid.bounds.width > 100,
              "the palette shows the default swatches (\(grid.swatches.count) in \(Int(grid.bounds.width)) pt)")

        click(0)
        check(Swatch(tools.foreground) == SwatchList.defaults[0], "a click makes the swatch the foreground color")
        click(46, .option)
        check(Swatch(tools.background) == SwatchList.defaults[46], "an Option-click makes it the background color")

        tools.foreground = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        click(nil)
        check(store.list.swatches.count == 48 && store.list.swatches.last?.hex == "#336699" &&
              grid.swatches == store.list.swatches,
              "a click on the empty space adds the foreground color")
        click(1, .shift)
        check(store.list.swatches[1].hex == "#336699", "a Shift-click replaces the swatch with the foreground color")
        click(1, .command)
        check(store.list.swatches.count == 47 && store.list.swatches[1] == SwatchList.defaults[2],
              "a Command-click deletes the swatch")
        check(try session.undoInfo(image) == historyBefore && session.info(image).isDirty == dirtyBefore,
              "choosing and editing swatches leaves the image and its history alone")
    }
}
