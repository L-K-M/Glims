import AppKit

@MainActor
extension EngineSmokeTest {
    /// Real menu -> captured source chooser -> shared parameter form for
    /// Negative Darkroom. The standalone C harness independently checks this
    /// operation's GEGL/native pixels and history semantics; this fixture
    /// checks that the UI sends the chosen dodge/burn map and settings to it.
    static func exerciseNegativeDarkroomSource(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
            if !condition() { check(false, "Negative Darkroom times out waiting for its UI or counted work") }
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
        func settle(_ document: ImageDocument) {
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin(0.03)
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        }
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items + menu.items.flatMap { $0.submenu.map(menuItems) ?? [] }
        }

        var ownedImages: [Int32] = []
        var ownedDocuments: [ImageDocument] = []
        var ownedControllers: [DocumentWindowController] = []
        var ownedAuxiliaryWindows: [NSWindow] = []
        var releaseGates: [DispatchSemaphore] = []
        var finished = false
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        defer {
            releaseGates.forEach { $0.signal() }
            ownedControllers.forEach { $0.previewPanel?.cancel() }
            var renderersStopped = true
            for owner in ownedControllers {
                owner.window?.orderOut(nil)
                var stopped = false
                owner.canvas.stopRendering { stopped = true }
                wait { stopped }
                renderersStopped = renderersStopped && stopped
                owner.window?.close()
            }
            check(renderersStopped, "Negative Darkroom teardown drains every owned renderer")
            ownedDocuments.forEach { $0.closeImageWhenDrained() }
            for image in ownedImages where !ownedDocuments.contains(where: { $0.image == image }) {
                if !gone(image) { try? session.closeImage(image) }
            }
            wait { ownedDocuments.allSatisfy { $0.pendingWork == 0 } && !EngineActivity.shared.isBusy }
            wait { ownedImages.allSatisfy { gone($0) } }
            check(ownedImages.allSatisfy { gone($0) } && ownedDocuments.allSatisfy { $0.pendingWork == 0 },
                  "Negative Darkroom teardown closes every owned native image after counted work")
            check(ownedAuxiliaryWindows.allSatisfy { !$0.isVisible }
                    && ownedControllers.allSatisfy { $0.window?.attachedSheet == nil },
                  "Negative Darkroom teardown leaves no owned source chooser, preview or dialog")
            documents.items.removeAll { candidate in ownedDocuments.contains { $0 === candidate } }
            check(finished, "Negative Darkroom completes every dedicated chooser acceptance scenario")
        }

        let side = 32
        var targetBytes = [UInt8](), mapBytes = [UInt8]()
        for y in 0..<side {
            for x in 0..<side {
                let alpha = UInt8(36 + (x * 13 + y * 17) % 219)
                let targetRed: UInt8 = UInt8(17 + (x * 19 + y * 7) % 211)
                let targetGreen: UInt8 = UInt8(31 + (x * 11 + y * 23) % 197)
                let targetBlue: UInt8 = UInt8(43 + (x * 29 + y * 5) % 181)
                targetBytes.append(targetRed)
                targetBytes.append(targetGreen)
                targetBytes.append(targetBlue)
                targetBytes.append(alpha)
                let red = UInt8(x < side / 2 ? 20 + x * 4 : 240 - x * 3)
                let green = UInt8(y < side / 2 ? 30 + y * 4 : 210 - y * 2)
                let blue = UInt8(10 + (x * 17 + y * 29) % 245)
                let mapAlpha = UInt8(50 + (x * 7 + y * 11) % 205)
                mapBytes.append(red)
                mapBytes.append(green)
                mapBytes.append(blue)
                mapBytes.append(mapAlpha)
            }
        }
        check(targetBytes.count == side * side * 4 && mapBytes.count == side * side * 4,
              "the Negative Darkroom fixture builds distinct partially transparent target and source textures")
        let pixels = ClipboardImage(width: side, height: side, pixels: Data(targetBytes), origin: .zero)
        let mapPixels = ClipboardImage(width: side, height: side, pixels: Data(mapBytes), origin: .zero)
        func fixture() throws -> (image: Int32, target: Int32, source: Int32, witness: Int32) {
            let image = try session.newImage(pixels: pixels)
            ownedImages.append(image)
            do {
                guard let target = try session.layers(image).first?.id else { throw ImageDocument.DocumentError.busy }
                try session.changeLayer(target, image: image, .init(name: "Negative target"))
                let source = try session.pastePixels(image, pixels: mapPixels, at: .zero)
                try session.changeLayer(source, image: image, .init(name: "Asymmetric dodge burn map", isVisible: false))
                let witnessPixels = ClipboardImage(width: 8, height: 8, pixels: Data(repeating: 127, count: 8 * 8 * 4), origin: .zero)
                let witness = try session.pastePixels(image, pixels: witnessPixels, at: .zero)
                try session.changeLayer(witness, image: image, .init(name: "Witness layer", isVisible: false))
                try session.selectItems([target], kind: .layer, image: image)
                return (image, target, source, witness)
            } catch {
                try? session.closeImage(image)
                throw error
            }
        }

        let aFixture = try fixture()
        let imageB = try session.newImage(width: 12, height: 12)
        ownedImages.append(imageB)
        let document = try ImageDocument(session: session, image: aFixture.image, name: "Negative Darkroom A")
        ownedDocuments.append(document)
        let other = try ImageDocument(session: session, image: imageB, name: "Negative Darkroom B")
        ownedDocuments.append(other)
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        ownedControllers += [controller, front]
        controller.showWindow(nil); front.showWindow(nil)

        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        guard let operation = operations.first(where: { $0.name == "gegl:negative-darkroom" }),
              let menu = NSApp.mainMenu else { return check(false, "the native Negative Darkroom catalog and main menu exist") }
        check(operation.support == .needsAuxInput,
              "the installed Negative Darkroom operation advertises its auxiliary dodge/burn-map input")
        let properties = try session.filterOperationProperties(operation.name)
        guard let dodgeProperty = properties.first(where: { $0.name == "dodge" }),
              let exposureProperty = properties.first(where: { $0.name == "exposure" }) else {
            return check(false, "the installed Negative Darkroom exposes the exact numeric dodge and exposure properties")
        }
        check(dodgeProperty.kind == .number && exposureProperty.kind == .number,
              "the installed Negative Darkroom dodge and exposure properties are numeric")
        print("Negative Darkroom installed: \(operation.name), title=\(operation.title), dodge=\(dodgeProperty.label), exposure=\(exposureProperty.label)")
        NativeFilterMenus.install(operations, in: menu)
        guard let item = menuItems(menu).first(where: { ($0.representedObject as? NativeFilterCommand)?.operation.name == operation.name }) else {
            return check(false, "the real Filter menu lists the installed Negative Darkroom")
        }
        let offersSource = item.title == "\(operation.title)…" && controller.validateMenuItem(item)
        check(offersSource, "the actual Negative Darkroom menu item is enabled and offers the dodge/burn-map chooser")
        guard offersSource else { return }

        let original = try session.copyPixels(aFixture.image, merged: true).pixels
        let originalHistory = try session.undoInfo(aFixture.image)
        let otherPixels = try session.copyPixels(imageB, merged: true).pixels
        let otherHistory = try session.undoInfo(imageB)
        let sourceTitle = "\(operation.title) Source"
        func sourceWindow() -> NSWindow? {
            guard let result = NSApp.windows.first(where: {
                $0.isVisible && $0.title == sourceTitle && $0.parent === controller.window
            }) else { return nil }
            if !ownedAuxiliaryWindows.contains(where: { $0 === result }) { ownedAuxiliaryWindows.append(result) }
            return result
        }
        func sendMenu() {
            if let action = item.action { _ = NSApp.sendAction(action, to: controller, from: item) }
            spin(0.03)
        }

        sendMenu()
        check(sourceWindow() != nil, "the real Negative Darkroom menu action opens its owning document's source chooser")
        guard let initialChooser = sourceWindow() else { return }
        let initialPopup = views(initialChooser.contentView, NSPopUpButton.self).first
        let explanation = views(initialChooser.contentView, NSTextField.self).first {
            $0.stringValue == "Preview uses a snapshot of this source. Apply makes filtered pixels opaque; Undo restores them."
        }
        check(initialPopup?.accessibilityLabel() == "Dodge/burn map source"
                && button(initialChooser.contentView, "Preview Negative Darkroom") != nil,
              "Negative Darkroom names the dodge/burn-map role and its Preview action accessibly")
        check(explanation.map { !$0.isHidden && $0.window === initialChooser } == true,
              "the chooser shows the exact visible snapshot explanation and opacity warning")
        check(initialPopup?.itemTitles.contains("Asymmetric dodge burn map") == true
                && initialPopup?.itemTitles.contains("Negative target") == true
                && initialPopup?.itemTitles.contains("Witness layer") == true,
              "the captured source chooser offers A's target, asymmetric dodge/burn map and witness layer")
        document.selectLayer(aFixture.witness); settle(document)
        let originalPreview = button(initialChooser.contentView, "Preview Negative Darkroom")
        originalPreview?.performClick(nil)
        settle(document)
        check(try document.selectedLayerIDs == [aFixture.witness] && originalPreview?.isEnabled == false
                && !document.filterPreviewIsOpen && controller.previewPanel == nil
                && sourceWindow() === initialChooser && session.undoInfo(aFixture.image) == originalHistory
                && session.copyPixels(aFixture.image, merged: true).pixels == original,
              "retargeting A disables the captured-target Preview without changing native pixels or history")
        document.selectLayer(aFixture.target); settle(document)
        check(originalPreview?.isEnabled == true && sourceWindow() === initialChooser,
              "restoring the original target re-enables the same owned chooser without manual refresh")
        button(initialChooser.contentView, "Cancel filter source")?.performClick(nil)
        settle(document)
        check(try sourceWindow() == nil && !document.filterPreviewIsOpen
                && session.undoInfo(aFixture.image) == originalHistory
                && session.copyPixels(aFixture.image, merged: true).pixels == original,
              "Cancel source selection leaves pixels and all native history unchanged")

        guard let bumpItem = menuItems(menu).first(where: {
            ($0.representedObject as? NativeFilterCommand)?.operation.name == "gegl:bump-map"
        }) else { return check(false, "the retained Bump Map menu operation exists for stale-chooser replacement") }
        if let action = bumpItem.action { _ = NSApp.sendAction(action, to: controller, from: bumpItem) }
        guard let oldChooser = NSApp.windows.first(where: {
            $0.isVisible && $0.title == "Bump Map Source" && $0.parent === controller.window
        }), let oldPreview = button(oldChooser.contentView, "Preview Bump Map") else {
            return check(false, "Bump Map opens its original height-map chooser before replacement")
        }
        ownedAuxiliaryWindows.append(oldChooser)
        front.window?.makeKeyAndOrderFront(nil)
        sendMenu()
        guard let replacement = sourceWindow() else {
            return check(false, "Negative Darkroom replaces the owning window's Bump Map chooser")
        }
        check(replacement !== oldChooser && !oldChooser.isVisible
                && views(replacement.contentView, NSPopUpButton.self).first?.accessibilityLabel() == "Dodge/burn map source",
              "changing source operation invalidates the old chooser and exposes the dodge/burn-map role")
        oldPreview.performClick(nil)
        settle(document)
        check(!document.filterPreviewIsOpen && controller.previewPanel == nil && sourceWindow() === replacement,
              "retained Preview from the invalidated Bump Map chooser cannot start a stale filter")
        sendMenu()
        check(sourceWindow() === replacement && NSApp.windows.filter {
            $0.isVisible && $0.title == sourceTitle && $0.parent === controller.window
        }.count == 1, "repeating Negative Darkroom reuses its same owned chooser")
        button(replacement.contentView, "Cancel filter source")?.performClick(nil)
        settle(document)
        check(try session.undoInfo(aFixture.image) == originalHistory
                && session.copyPixels(aFixture.image, merged: true).pixels == original
                && session.undoInfo(imageB) == otherHistory,
              "chooser replacement and stale Preview change neither captured A nor other document B")

        // Independent direct EngineSession source-preview reference on a separate
        // identical image with the same selected settings (not production UI helper).
        let oracleFixture = try fixture()
        let targetContrastFixture = try fixture()
        var oracleFilter: Int32?
        var contrastFilter: Int32?
        let expected: Data, targetContrast: Data
        do {
            let filter = try session.beginFilter(image: oracleFixture.image, drawable: oracleFixture.target,
                                                 operation: operation.name, source: oracleFixture.source)
            oracleFilter = filter
            try session.setFilterProperty(filter, "dodge", to: .number(1.30))
            try session.setFilterProperty(filter, "exposure", to: .number(0.35))
            expected = try session.copyPixels(oracleFixture.image, merged: true).pixels
            try session.abortFilter(filter); oracleFilter = nil
            try session.closeImage(oracleFixture.image)

            let selfFilter = try session.beginFilter(image: targetContrastFixture.image, drawable: targetContrastFixture.target,
                                                     operation: operation.name, source: targetContrastFixture.target)
            contrastFilter = selfFilter
            try session.setFilterProperty(selfFilter, "dodge", to: .number(1.30))
            try session.setFilterProperty(selfFilter, "exposure", to: .number(0.35))
            targetContrast = try session.copyPixels(targetContrastFixture.image, merged: true).pixels
            try session.abortFilter(selfFilter); contrastFilter = nil
            try session.closeImage(targetContrastFixture.image)
        } catch {
            if let oracleFilter { try? session.abortFilter(oracleFilter) }
            if let contrastFilter { try? session.abortFilter(contrastFilter) }
            try? session.closeImage(oracleFixture.image)
            try? session.closeImage(targetContrastFixture.image)
            check(false, "the source facade admits the independently selected dodge/burn map: \(error.localizedDescription)")
            return
        }
        check(expected != original && expected != targetContrast,
              "the direct native reference changes pixels and differs from silently using the target as source")
        let resultOpaque = stride(from: 3, to: expected.count, by: 4).allSatisfy { expected[$0] == 255 }
        let originalHasPartialAlpha = stride(from: 3, to: original.count, by: 4).contains { original[$0] > 0 && original[$0] < 255 }
        check(!expected.isEmpty && expected.count == original.count && originalHasPartialAlpha && resultOpaque,
              "Negative Darkroom makes filtered pixels opaque for a partially transparent original")

        var acceptedPopup: NSPopUpButton?
        func openPreview() -> NativeFilterPanel? {
            sendMenu()
            guard let source = sourceWindow(), let popup = views(source.contentView, NSPopUpButton.self).first else { return nil }
            popup.selectItem(withTitle: "Asymmetric dodge burn map")
            if let action = popup.action { _ = NSApp.sendAction(action, to: popup.target, from: popup) }
            acceptedPopup = popup
            front.window?.makeKeyAndOrderFront(nil)
            button(source.contentView, "Preview Negative Darkroom")?.performClick(nil)
            wait { controller.previewPanel != nil || (!source.isVisible && document.pendingWork == 0) }
            settle(document)
            let result = controller.previewPanel as? NativeFilterPanel
            if let window = result?.window { ownedAuxiliaryWindows.append(window) }
            return result
        }
        guard let panel = openPreview(), let filter = panel.filter else {
            return check(false, "accepting the explicit dodge/burn map opens the native parameter form")
        }
        check(panel.imageDocument === document && document.filterPreviewIsOpen && !other.filterPreviewIsOpen
                && sourceWindow() == nil && panel.window?.title == operation.title,
              "Preview belongs to captured A after requesting B's window in front and closes only A's chooser")

        let dodgeField = views(panel.window?.contentView, NSTextField.self).first {
            ($0.accessibilityLabel() ?? "").hasPrefix(dodgeProperty.label) && $0.isEditable
        }
        let exposureField = views(panel.window?.contentView, NSTextField.self).first {
            ($0.accessibilityLabel() ?? "").hasPrefix(exposureProperty.label) && $0.isEditable
        }
        check(dodgeField != nil && exposureField != nil,
              "the native form contains accessible numeric dodge and exposure controls")
        sendNumber(dodgeField, 1.30)
        sendNumber(exposureField, 0.35)
        settle(document)
        check(try session.filterProperty(filter, "dodge") == .number(1.30)
                && session.filterProperty(filter, "exposure") == .number(0.35),
              "real parameter controls send dodge and exposure through the owning document queue")
        check(try session.copyPixels(aFixture.image, merged: true).pixels == expected,
              "the chosen-source UI preview matches the separately configured native facade reference")
        check(try session.copyPixels(imageB, merged: true).pixels == otherPixels
                && session.undoInfo(imageB) == otherHistory,
              "captured preview ownership leaves other document B's pixels and history untouched")

        // The accepted chooser is retired. A retained source control must not
        // retarget its detached snapshot, including after GEGL reevaluation.
        acceptedPopup?.selectItem(withTitle: "Negative target")
        if let popup = acceptedPopup, let action = popup.action { _ = NSApp.sendAction(action, to: popup.target, from: popup) }
        sendNumber(dodgeField, 1.35); settle(document)
        sendNumber(dodgeField, 1.30); settle(document)
        check(try sourceWindow() == nil && session.copyPixels(aFixture.image, merged: true).pixels == expected
                && session.undoInfo(aFixture.image) == originalHistory,
              "late source selection cannot retarget the detached snapshot after parameter reevaluation")
        check(button(panel.window?.contentView, "Apply to Pixels") != nil,
              "the Negative Darkroom form explicitly offers Apply to Pixels")
        button(panel.window?.contentView, "Cancel")?.performClick(nil)
        settle(document)
        check(try !document.filterPreviewIsOpen && controller.previewPanel == nil
                && session.undoInfo(aFixture.image) == originalHistory
                && session.copyPixels(aFixture.image, merged: true).pixels == original,
              "Cancel parameter preview restores every original pixel and full native history")

        guard let applyPanel = openPreview(), let applyFilter = applyPanel.filter else {
            return check(false, "Negative Darkroom reopens for a confirmed pixel Apply")
        }
        sendNumber(views(applyPanel.window?.contentView, NSTextField.self).first {
            ($0.accessibilityLabel() ?? "").hasPrefix(dodgeProperty.label) && $0.isEditable
        }, 1.30)
        sendNumber(views(applyPanel.window?.contentView, NSTextField.self).first {
            ($0.accessibilityLabel() ?? "").hasPrefix(exposureProperty.label) && $0.isEditable
        }, 0.35)
        settle(document)
        check(try session.filterProperty(applyFilter, "dodge") == .number(1.30)
                && session.filterProperty(applyFilter, "exposure") == .number(0.35),
              "the accepted Apply preview has the requested dodge and exposure settings")
        button(applyPanel.window?.contentView, "Apply to Pixels")?.performClick(nil)
        settle(document)
        let applied = try session.copyPixels(aFixture.image, merged: true).pixels
        let appliedOpaque = stride(from: 3, to: applied.count, by: 4).allSatisfy { applied[$0] == 255 }
        check(try applied == expected && appliedOpaque && !document.filterPreviewIsOpen
                && session.undoInfo(aFixture.image).undoCount == originalHistory.undoCount + 1
                && session.effects(on: aFixture.target, image: aFixture.image).isEmpty,
              "Apply commits the chosen-map result as opaque pixels with exactly one native Undo and no saved auxiliary effect")
        document.undo(); settle(document)
        check(try session.copyPixels(aFixture.image, merged: true).pixels == original,
              "one document Undo restores the exact original partially transparent pixels")
        document.redo(); settle(document)
        check(try session.copyPixels(aFixture.image, merged: true).pixels == applied
                && session.copyPixels(imageB, merged: true).pixels == otherPixels
                && session.undoInfo(imageB) == otherHistory,
              "Redo restores the exact applied opaque result while other document B is unchanged")
        check(document.pendingWork == 0 && other.pendingWork == 0,
              "source preparation, parameter changes and pixel Apply drain both document queues")

        // Cached engine-busy disables menu and prevents a stale/late preview.
        let ready = DispatchSemaphore(value: 0), releaseHold = DispatchSemaphore(value: 0)
        releaseGates.append(releaseHold)
        let held = EngineActivity.shared.perform(label: "Negative Darkroom busy fixture", work: {
            ready.signal(); _ = releaseHold.wait(timeout: .now() + 20)
        }, completion: {})
        var started = false
        let holdDeadline = Date().addingTimeInterval(10)
        while !started && Date() < holdDeadline { started = ready.wait(timeout: .now()) == .success; if !started { spin(0.01) } }
        check(held && started && !controller.validateMenuItem(item),
              "cached engine activity disables the Negative Darkroom menu")
        releaseHold.signal(); wait { !EngineActivity.shared.isBusy }

        // If the captured source is removed, the chooser must not start/retarget preview.
        sendMenu()
        guard let removedSourceChooser = sourceWindow(),
              let removedPopup = views(removedSourceChooser.contentView, NSPopUpButton.self).first else {
            return check(false, "a fresh chooser opens before removing the selected source")
        }
        removedPopup.selectItem(withTitle: "Asymmetric dodge burn map")
        if let action = removedPopup.action { _ = NSApp.sendAction(action, to: removedPopup.target, from: removedPopup) }
        document.selectLayer(aFixture.source); settle(document)
        document.layerCommand(.delete); settle(document)
        document.selectLayer(aFixture.target); settle(document)
        let afterDelete = try session.undoInfo(aFixture.image)
        let afterDeletePixels = try session.copyPixels(aFixture.image, merged: true).pixels
        let removedPreview = button(removedSourceChooser.contentView, "Preview Negative Darkroom")
        check(try !document.layers.contains { $0.id == aFixture.source }
                && session.selectedLayers(aFixture.image) == [aFixture.target]
                && removedPopup.selectedItem?.title == "Asymmetric dodge burn map"
                && removedPopup.selectedItem?.isEnabled == false && removedPreview?.isEnabled == false,
              "real source deletion automatically keeps its disabled missing row without choosing another source")
        removedPreview?.performClick(nil)
        settle(document)
        check(try !document.filterPreviewIsOpen && controller.previewPanel == nil
                && session.undoInfo(aFixture.image) == afterDelete
                && session.copyPixels(aFixture.image, merged: true).pixels == afterDeletePixels,
              "a stale missing-source chooser starts no preview and preserves post-delete pixels and history")
        button(removedSourceChooser.contentView, "Cancel filter source")?.performClick(nil)
        settle(document)

        sendMenu()
        guard let closingChooser = sourceWindow() else { return check(false, "a fresh source chooser opens before close") }
        controller.window?.close()
        wait { document.isClosing && !closingChooser.isVisible }
        button(closingChooser.contentView, "Preview Negative Darkroom")?.performClick(nil)
        wait { document.pendingWork == 0 }
        wait { gone(aFixture.image) }
        check(document.isClosing && !closingChooser.isVisible && controller.previewPanel == nil,
              "closing A invalidates its source chooser and a late Preview cannot open a filter")
        check(!controller.validateMenuItem(item) && gone(aFixture.image),
              "closed-document validation disables Negative Darkroom and native close drains")
        finished = true
    }
}
