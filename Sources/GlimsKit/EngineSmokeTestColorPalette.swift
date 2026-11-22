import AppKit

@MainActor
extension EngineSmokeTest {
    /// Window ▸ Color through its actual controls: the sliders and fields
    /// edit the active tool color, the selector and the color bar choose
    /// which, outside changes reach the sliders, and none of it touches the
    /// image.
    static func exerciseColorPalette(_ session: EngineSession, documents: DocumentList) throws {
        let suite = ScratchDefaults.suiteName("smoke-color")
        guard let defaults = UserDefaults(suiteName: suite) else { return check(false, "a color palette defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let image = try session.newImage(width: 40, height: 30)
        let document = try ImageDocument(session: session, image: image, name: "Color Palette")
        documents.items.append(document)
        let tools = ToolState.shared
        let oldForeground = tools.foreground, oldBackground = tools.background
        tools.resetColors()
        let palette = ColorPaletteController(defaults: defaults)
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: ColorPaletteController.definition.contentSize),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentViewController = palette
        host.setContentSize(ColorPaletteController.definition.contentSize)
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
            .first { $0.action == #selector(AppController.showColor(_:)) }
        check(menuItem?.title == "Color", "Window ▸ Color opens the palette")
        let historyBefore = try session.undoInfo(image), dirtyBefore = try session.info(image).isDirty
        let bar = palette.colorBar
        check(palette.sliders.allSatisfy { $0.frame.width > 80 } && bar.bounds.width > 150 && bar.bounds.height >= 20,
              "the sliders and color bar are laid out (\(Int(bar.bounds.width)) x \(Int(bar.bounds.height)) pt)")
        check(palette.fields.map(\.stringValue) == ["0", "0", "0"], "the RGB sliders show the black foreground")

        func send(_ control: NSControl) { control.sendAction(control.action, to: control.target) }
        palette.sliders[0].doubleValue = 255
        send(palette.sliders[0])
        palette.fields[2].stringValue = "102"
        send(palette.fields[2])
        check(Swatch(tools.foreground)?.hex == "#FF0066", "a slider and a field set the foreground (\(Swatch(tools.foreground)?.hex ?? "-"))")

        guard let item = palette.paletteMenu?.items.first(where: { $0.title == "HSB Sliders" }) else {
            return check(false, "the palette menu offers HSB Sliders")
        }
        NSApp.sendAction(item.action!, to: item.target, from: item)
        check(palette.mode == .hsb && palette.fields[0].stringValue == "336",
              "the palette menu switches to HSB sliders (H \(palette.fields[0].stringValue))")

        palette.targetControl.selectedSegment = 1
        send(palette.targetControl)
        palette.fields[0].stringValue = "240"
        send(palette.fields[0])
        palette.fields[1].stringValue = "100"
        send(palette.fields[1])
        check(Swatch(tools.background)?.hex == "#0000FF" && Swatch(tools.foreground)?.hex == "#FF0066",
              "the selector makes the sliders edit the background only")

        func click(fractionX: CGFloat, fractionY: CGFloat, _ flags: NSEvent.ModifierFlags = []) {
            let point = NSPoint(x: bar.bounds.width * fractionX, y: bar.bounds.height * fractionY)
            guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: bar.convert(point, to: nil),
                                                 modifierFlags: flags, timestamp: 0, windowNumber: host.windowNumber,
                                                 context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
                return check(false, "a color bar click constructs")
            }
            bar.mouseDown(with: event)
        }
        click(fractionX: 1.0 / 3.0, fractionY: 0.5)
        check(Swatch(tools.background).map(HSBComponents.init).map { abs($0.hue - 120) < 2 && $0.saturation > 0.95 } == true,
              "a color bar click picks the active (background) color (\(Swatch(tools.background)?.hex ?? "-"))")
        click(fractionX: 0, fractionY: 0.999, .option)
        check((Swatch(tools.foreground).map(HSBComponents.init)?.brightness ?? 1) < 0.02,
              "an Option-click picks the other color (\(Swatch(tools.foreground)?.hex ?? "-"))")

        tools.resetColors()
        check(palette.fields[2].stringValue == "100" && palette.fields[1].stringValue == "0",
              "a reset made elsewhere reaches the sliders (white background)")
        let historyAfter = try session.undoInfo(image)
        check(historyAfter.undoCount == historyBefore.undoCount && (try? session.info(image).isDirty) == dirtyBefore,
              "editing colors leaves the image and its history alone")
    }
}
