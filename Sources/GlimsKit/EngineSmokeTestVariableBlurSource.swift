import AppKit

@MainActor
extension EngineSmokeTest {
    /// Real menu -> captured source chooser -> shared parameter form. The
    /// standalone C harness independently checks this operation's GEGL pixels;
    /// this test checks that the UI sends the chosen source/settings to it.
    static func exerciseVariableBlurSource(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func views<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type) }
        }
        func button(_ root: NSView?, _ label: String) -> NSButton? {
            views(root, NSButton.self).first { $0.accessibilityLabel() == label || $0.title == label }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin(0.03)
        }
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items + menu.items.flatMap { $0.submenu.map(menuItems) ?? [] }
        }
        let side = 32
        var targetBytes = [UInt8](), maskBytes = [UInt8]()
        for y in 0..<side { for x in 0..<side {
            targetBytes += [((x / 2 + y / 3) & 1) == 0 ? 19 : 231,
                            UInt8((x * 29 + y * 13) % 256), UInt8((x * 7 + y * 47) % 256),
                            UInt8(48 + (x * 11 + y * 17) % 208)]
            let value = UInt8((x * 5 + y * 19 + (x > 19 ? 83 : 0)) % 256)
            maskBytes += [value, value, value, 255]
        } }
        let pixels = ClipboardImage(width: side, height: side, pixels: Data(targetBytes), origin: .zero)
        let maskPixels = ClipboardImage(width: side, height: side, pixels: Data(maskBytes), origin: .zero)
        func fixture() throws -> (image: Int32, target: Int32, source: Int32) {
            let image = try session.newImage(pixels: pixels)
            do {
                guard let target = try session.layers(image).first?.id else { throw ImageDocument.DocumentError.busy }
                try session.changeLayer(target, image: image, .init(name: "Variable target"))
                let source = try session.pastePixels(image, pixels: maskPixels, at: .zero)
                try session.changeLayer(source, image: image, .init(name: "Asymmetric blur mask", isVisible: false))
                try session.selectItems([target], kind: .layer, image: image)
                return (image, target, source)
            } catch { try? session.closeImage(image); throw error }
        }
        let aFixture = try fixture()
        let imageB = try session.newImage(width: 12, height: 12)
        let document = try ImageDocument(session: session, image: aFixture.image, name: "Variable Blur A")
        let other = try ImageDocument(session: session, image: imageB, name: "Variable Blur B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        controller.showWindow(nil); front.showWindow(nil)
        defer {
            controller.previewPanel?.cancel()
            for c in [controller, front] {
                c.window?.orderOut(nil)
                var stopped = false; c.canvas.stopRendering { stopped = true }; wait { stopped }
                c.window?.close()
            }
            for doc in [document, other] where !doc.isClosing {
                var closed = false; doc.closeImageWhenDrained { closed = true }; wait { closed }
            }
            wait { document.pendingWork == 0 && other.pendingWork == 0 }
            wait { (try? session.info(aFixture.image)) == nil && (try? session.info(imageB)) == nil }
            documents.items.removeAll { $0 === document || $0 === other }
        }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        guard let operation = operations.first(where: { $0.name == "gegl:variable-blur" }),
              let menu = NSApp.mainMenu else { return check(false, "the native Variable Blur catalog and main menu exist") }
        check(operation.support == .needsAuxInput, "the installed Variable Blur operation advertises its auxiliary mask input")
        NativeFilterMenus.install(operations, in: menu)
        guard let item = menuItems(menu).first(where: { ($0.representedObject as? NativeFilterCommand)?.operation.name == operation.name }) else {
            return check(false, "the real Filter menu lists Variable Blur")
        }
        check(item.title == "\(operation.title)…" && controller.validateMenuItem(item),
              "the actual Variable Blur menu item is enabled and offers the source chooser")
        let original = try session.copyPixels(aFixture.image, merged: true).pixels
        let originalHistory = try session.undoInfo(aFixture.image)
        let otherPixels = try session.copyPixels(imageB, merged: true).pixels
        let otherHistory = try session.undoInfo(imageB)
        let sourceTitle = "\(operation.title) Source"
        func sourceWindow() -> NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.title == sourceTitle && $0.parent === controller.window }
        }
        func sendMenu() {
            if let action = item.action { _ = NSApp.sendAction(action, to: controller, from: item) }
            spin(0.03)
        }
        sendMenu()
        check(sourceWindow() != nil, "the real Variable Blur menu action opens its owning document's source chooser")
        guard let initialChooser = sourceWindow() else { return }
        let initialPopup = views(initialChooser.contentView, NSPopUpButton.self).first
        check(initialPopup?.accessibilityLabel() == "Blur mask source"
                && button(initialChooser.contentView, "Preview Variable Blur") != nil,
              "Variable Blur names the mask role and its Preview action accessibly")
        check(initialPopup?.itemTitles.contains("Asymmetric blur mask") == true,
              "the captured source chooser lists A's explicit asymmetric mask")
        button(initialChooser.contentView, "Cancel filter source")?.performClick(nil)
        settle(document)
        check(try sourceWindow() == nil && !document.filterPreviewIsOpen
                && session.undoInfo(aFixture.image) == originalHistory
                && session.copyPixels(aFixture.image, merged: true).pixels == original,
              "Cancel source selection leaves pixels and all native history unchanged")

        guard let bumpItem = menuItems(menu).first(where: {
            ($0.representedObject as? NativeFilterCommand)?.operation.name == "gegl:bump-map"
        }) else { return check(false, "the retained Bump Map menu operation exists") }
        if let action = bumpItem.action { _ = NSApp.sendAction(action, to: controller, from: bumpItem) }
        guard let oldChooser = NSApp.windows.first(where: {
            $0.isVisible && $0.title == "Bump Map Source" && $0.parent === controller.window
        }), let oldPreview = button(oldChooser.contentView, "Preview Bump Map") else {
            return check(false, "Bump Map opens its original height-map chooser before replacement")
        }
        front.window?.makeKeyAndOrderFront(nil)
        sendMenu()
        guard let replacement = sourceWindow() else {
            return check(false, "Variable Blur replaces the owning window's Bump Map chooser")
        }
        check(replacement !== oldChooser && !oldChooser.isVisible
                && views(replacement.contentView, NSPopUpButton.self).first?.accessibilityLabel() == "Blur mask source",
              "changing source operation invalidates the old chooser and exposes the new mask role")
        oldPreview.performClick(nil)
        settle(document)
        check(!document.filterPreviewIsOpen && controller.previewPanel == nil && sourceWindow() === replacement,
              "retained Preview from the invalidated Bump Map chooser cannot start a stale filter")
        sendMenu()
        check(sourceWindow() === replacement && NSApp.windows.filter {
            $0.isVisible && $0.title == sourceTitle && $0.parent === controller.window
        }.count == 1, "repeating Variable Blur reuses its same owned chooser")
        button(replacement.contentView, "Cancel filter source")?.performClick(nil)
        settle(document)
        check(try session.undoInfo(aFixture.image) == originalHistory
                && session.copyPixels(aFixture.image, merged: true).pixels == original
                && session.undoInfo(imageB) == otherHistory,
              "chooser replacement and stale Preview change neither captured A nor front document B")

        // Obtain a direct facade reference in a separate image. Its mask is
        // selected explicitly, rather than using the UI's preferred target.
        let oracleFixture = try fixture()
        var oracleFilter: Int32?
        let expected: Data
        do {
            let filter = try session.beginFilter(image: oracleFixture.image, drawable: oracleFixture.target,
                                                 operation: operation.name, source: oracleFixture.source)
            oracleFilter = filter
            try session.setFilterProperty(filter, "radius", to: .number(6.25))
            try session.setFilterProperty(filter, "linear-mask", to: .boolean(true))
            let properties = try session.filterOperationProperties(operation.name)
            if properties.contains(where: { $0.name == "high-quality" }) {
                try session.setFilterProperty(filter, "high-quality", to: .boolean(true))
            }
            expected = try session.copyPixels(oracleFixture.image, merged: true).pixels
            try session.abortFilter(filter); oracleFilter = nil
            try session.closeImage(oracleFixture.image)
        } catch {
            if let oracleFilter { try? session.abortFilter(oracleFilter) }
            try? session.closeImage(oracleFixture.image)
            check(false, "the Swift source facade admits the independently selected Variable Blur mask: \(error.localizedDescription)")
            return
        }
        check(expected != original, "the direct configured-mask reference changes the textured fixture")
        let properties = try session.filterOperationProperties(operation.name)
        guard let radiusProperty = properties.first(where: { $0.name == "radius" }),
              let linearProperty = properties.first(where: { $0.name == "linear-mask" }) else {
            return check(false, "Variable Blur exposes actual Radius and Linear mask controls")
        }
        func openPreview() -> NativeFilterPanel? {
            sendMenu()
            guard let source = sourceWindow(), let popup = views(source.contentView, NSPopUpButton.self).first else { return nil }
            popup.selectItem(withTitle: "Asymmetric blur mask")
            if let action = popup.action { _ = NSApp.sendAction(action, to: popup.target, from: popup) }
            front.window?.makeKeyAndOrderFront(nil)
            button(source.contentView, "Preview Variable Blur")?.performClick(nil)
            wait { controller.previewPanel != nil || (!source.isVisible && document.pendingWork == 0) }
            settle(document)
            return controller.previewPanel as? NativeFilterPanel
        }
        guard let panel = openPreview(), let filter = panel.filter else {
            return check(false, "accepting the explicit mask opens Variable Blur's native parameter form")
        }
        check(panel.imageDocument === document && document.filterPreviewIsOpen && !other.filterPreviewIsOpen
                && sourceWindow() == nil && panel.window?.title == operation.title,
              "Preview belongs to captured A while B is frontmost and closes only A's chooser")
        let radiusField = views(panel.window?.contentView, NSTextField.self).first {
            ($0.accessibilityLabel() ?? "").hasPrefix(radiusProperty.label) && $0.isEditable
        }
        check(radiusField != nil && button(panel.window?.contentView, linearProperty.label) != nil,
              "the native form contains accessible radius and linear-mask property controls")
        radiusField?.stringValue = "6.25"
        if let field = radiusField, let action = field.action { _ = NSApp.sendAction(action, to: field.target, from: field) }
        if let linear = button(panel.window?.contentView, linearProperty.label), linear.state != .on { linear.performClick(nil) }
        if let qualityProperty = properties.first(where: { $0.name == "high-quality" }),
           let quality = button(panel.window?.contentView, qualityProperty.label), quality.state != .on { quality.performClick(nil) }
        settle(document)
        check(try session.filterProperty(filter, "radius") == .number(6.25)
                && session.filterProperty(filter, "linear-mask") == .boolean(true),
              "real property controls send Radius and Linear mask through the owning document queue")
        check(try session.copyPixels(aFixture.image, merged: true).pixels == expected,
              "the chosen-source UI preview matches the separately configured native facade reference")
        check(button(panel.window?.contentView, "Apply to Pixels") != nil,
              "the Variable Blur form explicitly offers Apply to Pixels")
        button(panel.window?.contentView, "Cancel")?.performClick(nil)
        settle(document)
        check(try !document.filterPreviewIsOpen && controller.previewPanel == nil
                && session.undoInfo(aFixture.image) == originalHistory
                && session.copyPixels(aFixture.image, merged: true).pixels == original,
              "Cancel parameter preview restores every original pixel and history fact")

        guard let applyPanel = openPreview(), let applyFilter = applyPanel.filter else {
            return check(false, "Variable Blur reopens for a confirmed pixel Apply")
        }
        applyPanel.setProperty("radius", .number(6.25))
        applyPanel.setProperty("linear-mask", .boolean(true))
        if properties.contains(where: { $0.name == "high-quality" }) { applyPanel.setProperty("high-quality", .boolean(true)) }
        settle(document)
        check(try session.filterProperty(applyFilter, "radius") == .number(6.25), "the accepted Apply preview has the requested radius")
        button(applyPanel.window?.contentView, "Apply to Pixels")?.performClick(nil)
        settle(document)
        let applied = try session.copyPixels(aFixture.image, merged: true).pixels
        check(try applied == expected && !document.filterPreviewIsOpen
                && session.undoInfo(aFixture.image).undoCount == originalHistory.undoCount + 1,
              "Apply commits the explicit mask result as exactly one Undo and closes the parameter form")
        document.undo(); settle(document)
        check(try session.copyPixels(aFixture.image, merged: true).pixels == original,
              "one document Undo restores the exact original textured pixels")
        document.redo(); settle(document)
        check(try session.copyPixels(aFixture.image, merged: true).pixels == applied
                && session.copyPixels(imageB, merged: true).pixels == otherPixels
                && session.undoInfo(imageB) == otherHistory,
              "Redo restores the exact chosen-mask pixels while front document B is unchanged")

        // Cached admission: neither menu validation nor source refresh may
        // start a native read while an exclusive activity holds the engine.
        let ready = DispatchSemaphore(value: 0), releaseHold = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Variable Blur busy fixture", work: {
            ready.signal(); _ = releaseHold.wait(timeout: .now() + 20)
        }, completion: {})
        var started = false
        let holdDeadline = Date().addingTimeInterval(10)
        while !started && Date() < holdDeadline { started = ready.wait(timeout: .now()) == .success; if !started { spin(0.01) } }
        check(held && started && !controller.validateMenuItem(item), "cached engine activity disables the Variable Blur menu")
        releaseHold.signal(); wait { !EngineActivity.shared.isBusy }
        sendMenu()
        guard let closingChooser = sourceWindow() else { return check(false, "a fresh source chooser opens before close") }
        controller.window?.close()
        wait { document.isClosing && !closingChooser.isVisible }
        button(closingChooser.contentView, "Preview Variable Blur")?.performClick(nil)
        wait { document.pendingWork == 0 }
        wait { (try? session.info(aFixture.image)) == nil }
        check(document.isClosing && !closingChooser.isVisible && controller.previewPanel == nil,
              "closing A invalidates its source chooser and a late Preview cannot open a filter")
        check(!controller.validateMenuItem(item) && (try? session.info(aFixture.image)) == nil,
              "closed-document validation disables Variable Blur and native close drains")
    }
}
