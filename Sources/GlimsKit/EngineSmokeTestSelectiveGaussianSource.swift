import AppKit

@MainActor
extension EngineSmokeTest {
    /// Real menu -> captured source chooser -> shared parameter form. The
    /// standalone C harness independently checks this operation's GEGL pixels;
    /// this test checks that the UI sends the chosen source/settings to it.
    static func exerciseSelectiveGaussianSource(_ session: EngineSession, documents: DocumentList) throws {
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
        func sendNumber(_ field: NSTextField?, _ value: Double) {
            guard let field else { return }
            field.stringValue = (field.formatter as? NumberFormatter)?.string(from: NSNumber(value: value)) ?? "\(value)"
            if let action = field.action { _ = NSApp.sendAction(action, to: field.target, from: field) }
        }
        func sameAlpha(_ a: Data, _ b: Data) -> Bool {
            guard a.count == b.count else { return false }
            return stride(from: 3, to: a.count, by: 4).allSatisfy { a[$0] == b[$0] }
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
            let referenceRed: Int = x < 13 ? 20 + x * 2 + y : 190 + (x + y) % 47
            let referenceGreen: Int = y < 19 ? 40 + y * 2 + x : 199 + x % 37
            let referenceBlue: Int = (x * 5 + y * 3) % 230
            let referenceAlpha: Int = 64 + (x * 7 + y * 19) % 192
            let redByte: UInt8 = UInt8(referenceRed)
            let greenByte: UInt8 = UInt8(referenceGreen)
            let blueByte: UInt8 = UInt8(referenceBlue)
            let alphaByte: UInt8 = UInt8(referenceAlpha)
            maskBytes.append(redByte)
            maskBytes.append(greenByte)
            maskBytes.append(blueByte)
            maskBytes.append(alphaByte)
        } }
        let pixels = ClipboardImage(width: side, height: side, pixels: Data(targetBytes), origin: .zero)
        let maskPixels = ClipboardImage(width: side, height: side, pixels: Data(maskBytes), origin: .zero)
        func fixture() throws -> (image: Int32, target: Int32, source: Int32) {
            let image = try session.newImage(pixels: pixels)
            do {
                guard let target = try session.layers(image).first?.id else { throw ImageDocument.DocumentError.busy }
                try session.changeLayer(target, image: image, .init(name: "Selective target"))
                let source = try session.pastePixels(image, pixels: maskPixels, at: .zero)
                try session.changeLayer(source, image: image, .init(name: "Asymmetric contrast reference", isVisible: false))
                try session.selectItems([target], kind: .layer, image: image)
                return (image, target, source)
            } catch { try? session.closeImage(image); throw error }
        }
        let aFixture = try fixture()
        let imageB = try session.newImage(width: 12, height: 12)
        let document = try ImageDocument(session: session, image: aFixture.image, name: "Selective Gaussian Blur A")
        let other = try ImageDocument(session: session, image: imageB, name: "Selective Gaussian Blur B")
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
        guard let operation = operations.first(where: { $0.name == "gegl:gaussian-blur-selective" }),
              let menu = NSApp.mainMenu else { return check(false, "the native Selective Gaussian Blur catalog and main menu exist") }
        check(operation.support == .needsAuxInput, "the installed Selective Gaussian Blur operation advertises its optional contrast-reference input")
        let properties = try session.filterOperationProperties(operation.name)
        guard let radiusProperty = properties.first(where: { $0.name == "blur-radius" }),
              let deltaProperty = properties.first(where: { $0.name == "max-delta" }) else {
            return check(false, "the installed Selective Gaussian Blur exposes both exact property names")
        }
        check(radiusProperty.kind == .number && deltaProperty.kind == .number,
              "the installed blur-radius and max-delta properties are numeric")
        print("Selective Gaussian installed: \(operation.name), title=\(operation.title), Radius=\(radiusProperty.label), Max delta=\(deltaProperty.label)")
        NativeFilterMenus.install(operations, in: menu)
        guard let item = menuItems(menu).first(where: { ($0.representedObject as? NativeFilterCommand)?.operation.name == operation.name }) else {
            return check(false, "the real Filter menu lists the installed Selective Gaussian Blur")
        }
        let offersSource = item.title == "\(operation.title)…" && controller.validateMenuItem(item)
        check(offersSource, "the actual Selective Gaussian Blur menu item is enabled and offers the contrast-reference chooser")
        guard offersSource else { return }
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
        check(sourceWindow() != nil, "the real Selective Gaussian Blur menu action opens its owning document's source chooser")
        guard let initialChooser = sourceWindow() else { return }
        let initialPopup = views(initialChooser.contentView, NSPopUpButton.self).first
        check(initialPopup?.accessibilityLabel() == "Contrast reference source"
                && button(initialChooser.contentView, "Preview Selective Gaussian Blur") != nil,
              "Selective Gaussian Blur names the contrast-reference role and its Preview action accessibly")
        check(initialPopup?.itemTitles.contains("Asymmetric contrast reference") == true
                && initialPopup?.itemTitles.contains("Selective target") == true,
              "the captured source chooser offers A's distinct target and asymmetric contrast reference")
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
            return check(false, "Selective Gaussian Blur replaces the owning window's Bump Map chooser")
        }
        check(replacement !== oldChooser && !oldChooser.isVisible
                && views(replacement.contentView, NSPopUpButton.self).first?.accessibilityLabel() == "Contrast reference source",
              "changing source operation invalidates the old chooser and exposes the new contrast-reference role")
        oldPreview.performClick(nil)
        settle(document)
        check(!document.filterPreviewIsOpen && controller.previewPanel == nil && sourceWindow() === replacement,
              "retained Preview from the invalidated Bump Map chooser cannot start a stale filter")
        sendMenu()
        check(sourceWindow() === replacement && NSApp.windows.filter {
            $0.isVisible && $0.title == sourceTitle && $0.parent === controller.window
        }.count == 1, "repeating Selective Gaussian Blur reuses its same owned chooser")
        button(replacement.contentView, "Cancel filter source")?.performClick(nil)
        settle(document)
        check(try session.undoInfo(aFixture.image) == originalHistory
                && session.copyPixels(aFixture.image, merged: true).pixels == original
                && session.undoInfo(imageB) == otherHistory,
              "chooser replacement and stale Preview change neither captured A nor front document B")

        // Configure an independent native preview in a separate image without
        // any chooser or property controls. Compare with target-as-reference
        // as well, so silently keeping the chooser's default cannot pass.
        let oracleFixture = try fixture()
        var oracleFilter: Int32?
        let expected: Data, targetContrast: Data
        do {
            let filter = try session.beginFilter(image: oracleFixture.image, drawable: oracleFixture.target,
                                                 operation: operation.name, source: oracleFixture.source)
            oracleFilter = filter
            try session.setFilterProperty(filter, "blur-radius", to: .number(3.75))
            try session.setFilterProperty(filter, "max-delta", to: .number(0.18))
            expected = try session.copyPixels(oracleFixture.image, merged: true).pixels
            try session.abortFilter(filter); oracleFilter = nil
            let selfFilter = try session.beginFilter(image: oracleFixture.image, drawable: oracleFixture.target,
                                                     operation: operation.name, source: oracleFixture.target)
            oracleFilter = selfFilter
            try session.setFilterProperty(selfFilter, "blur-radius", to: .number(3.75))
            try session.setFilterProperty(selfFilter, "max-delta", to: .number(0.18))
            targetContrast = try session.copyPixels(oracleFixture.image, merged: true).pixels
            try session.abortFilter(selfFilter); oracleFilter = nil
            try session.closeImage(oracleFixture.image)
        } catch {
            if let oracleFilter { try? session.abortFilter(oracleFilter) }
            try? session.closeImage(oracleFixture.image)
            check(false, "the source facade admits the independently selected contrast reference: \(error.localizedDescription)")
            return
        }
        check(expected != original && expected != targetContrast,
              "the direct native reference changes the texture and differs from silently using the target")
        check(sameAlpha(expected, original), "the independent contrast-reference result preserves every partial-alpha byte")
        var acceptedPopup: NSPopUpButton?
        func openPreview() -> NativeFilterPanel? {
            sendMenu()
            guard let source = sourceWindow(), let popup = views(source.contentView, NSPopUpButton.self).first else { return nil }
            popup.selectItem(withTitle: "Asymmetric contrast reference")
            if let action = popup.action { _ = NSApp.sendAction(action, to: popup.target, from: popup) }
            acceptedPopup = popup
            front.window?.makeKeyAndOrderFront(nil)
            button(source.contentView, "Preview Selective Gaussian Blur")?.performClick(nil)
            wait { controller.previewPanel != nil || (!source.isVisible && document.pendingWork == 0) }
            settle(document)
            return controller.previewPanel as? NativeFilterPanel
        }
        guard let panel = openPreview(), let filter = panel.filter else {
            return check(false, "accepting the explicit contrast reference opens the native parameter form")
        }
        check(panel.imageDocument === document && document.filterPreviewIsOpen && !other.filterPreviewIsOpen
                && sourceWindow() == nil && panel.window?.title == operation.title,
              "Preview belongs to captured A while B is frontmost and closes only A's chooser")
        let radiusField = views(panel.window?.contentView, NSTextField.self).first {
            ($0.accessibilityLabel() ?? "").hasPrefix(radiusProperty.label) && $0.isEditable
        }
        let deltaField = views(panel.window?.contentView, NSTextField.self).first {
            ($0.accessibilityLabel() ?? "").hasPrefix(deltaProperty.label) && $0.isEditable
        }
        check(radiusField != nil && deltaField != nil,
              "the native form contains both installed numeric Radius and Max delta controls")
        sendNumber(radiusField, 3.75)
        sendNumber(deltaField, 0.18)
        settle(document)
        check(try session.filterProperty(filter, "blur-radius") == .number(3.75)
                && session.filterProperty(filter, "max-delta") == .number(0.18),
              "real property controls send Radius and Max delta through the owning document queue")
        check(try session.copyPixels(aFixture.image, merged: true).pixels == expected,
              "the chosen-source UI preview matches the separately configured native facade reference")
        // The accepted chooser is retired. A retained source control must not
        // retarget its detached preview, including after GEGL reevaluation.
        acceptedPopup?.selectItem(withTitle: "Selective target")
        if let popup = acceptedPopup, let action = popup.action { _ = NSApp.sendAction(action, to: popup.target, from: popup) }
        sendNumber(radiusField, 5.25); settle(document)
        sendNumber(radiusField, 3.75); settle(document)
        check(try sourceWindow() == nil && session.copyPixels(aFixture.image, merged: true).pixels == expected
                && session.undoInfo(aFixture.image) == originalHistory,
              "late source selection cannot retarget the captured snapshot after parameter reevaluation")
        check(button(panel.window?.contentView, "Apply to Pixels") != nil,
              "the Selective Gaussian Blur form explicitly offers Apply to Pixels")
        button(panel.window?.contentView, "Cancel")?.performClick(nil)
        settle(document)
        check(try !document.filterPreviewIsOpen && controller.previewPanel == nil
                && session.undoInfo(aFixture.image) == originalHistory
                && session.copyPixels(aFixture.image, merged: true).pixels == original,
              "Cancel parameter preview restores every original pixel and history fact")

        guard let applyPanel = openPreview(), let applyFilter = applyPanel.filter else {
            return check(false, "Selective Gaussian Blur reopens for a confirmed pixel Apply")
        }
        applyPanel.setProperty("blur-radius", .number(3.75))
        applyPanel.setProperty("max-delta", .number(0.18))
        settle(document)
        check(try session.filterProperty(applyFilter, "blur-radius") == .number(3.75), "the accepted Apply preview has the requested radius")
        button(applyPanel.window?.contentView, "Apply to Pixels")?.performClick(nil)
        settle(document)
        let applied = try session.copyPixels(aFixture.image, merged: true).pixels
        check(try applied == expected && !document.filterPreviewIsOpen
                && session.undoInfo(aFixture.image).undoCount == originalHistory.undoCount + 1
                && session.effects(on: aFixture.target, image: aFixture.image).isEmpty,
              "Apply merges the contrast-reference result as exactly one Undo with no persisted auxiliary effect")
        document.undo(); settle(document)
        check(try session.copyPixels(aFixture.image, merged: true).pixels == original,
              "one document Undo restores the exact original textured pixels")
        document.redo(); settle(document)
        check(try session.copyPixels(aFixture.image, merged: true).pixels == applied
                && session.copyPixels(imageB, merged: true).pixels == otherPixels
                && session.undoInfo(imageB) == otherHistory,
              "Redo restores the exact contrast-reference pixels while front document B is unchanged")
        check(document.pendingWork == 0 && other.pendingWork == 0,
              "source preparation, parameter changes and pixel Apply drain both document queues")

        // Cached admission: neither menu validation nor source refresh may
        // start a native read while an exclusive activity holds the engine.
        let ready = DispatchSemaphore(value: 0), releaseHold = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Selective Gaussian Blur busy fixture", work: {
            ready.signal(); _ = releaseHold.wait(timeout: .now() + 20)
        }, completion: {})
        var started = false
        let holdDeadline = Date().addingTimeInterval(10)
        while !started && Date() < holdDeadline { started = ready.wait(timeout: .now()) == .success; if !started { spin(0.01) } }
        check(held && started && !controller.validateMenuItem(item), "cached engine activity disables the Selective Gaussian Blur menu")
        releaseHold.signal(); wait { !EngineActivity.shared.isBusy }
        sendMenu()
        guard let closingChooser = sourceWindow() else { return check(false, "a fresh source chooser opens before close") }
        controller.window?.close()
        wait { document.isClosing && !closingChooser.isVisible }
        button(closingChooser.contentView, "Preview Selective Gaussian Blur")?.performClick(nil)
        wait { document.pendingWork == 0 }
        wait { (try? session.info(aFixture.image)) == nil }
        check(document.isClosing && !closingChooser.isVisible && controller.previewPanel == nil,
              "closing A invalidates its source chooser and a late Preview cannot open a filter")
        check(!controller.validateMenuItem(item) && (try? session.info(aFixture.image)) == nil,
              "closed-document validation disables Selective Gaussian Blur and native close drains")
    }
}
