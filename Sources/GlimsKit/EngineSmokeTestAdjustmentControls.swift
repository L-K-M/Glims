import AppKit

// MARK: - GLIMS_SMOKE_CASE=adjustment-controls

@MainActor
extension EngineSmokeTest {
    /// Layer ▸ New Adjustment Layer…, end to end: menu wiring and cached
    /// validation (RGB/grayscale vs Indexed), the creation sheet's Cancel
    /// (no mutation) and accepted Create (counted, ONE undo step, actual
    /// native layer/effect ids, phase-2 parameter editor), two-document
    /// capture with B front, busy and floating refusals, Undo/Redo of the
    /// creation, and close draining with late-editor suppression.
    static func exerciseAdjustmentControls(_ session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        // Recursive view search that recurses into children EVEN WHEN THE
        // ROOT ITSELF MATCHES the type (an NSStackView root must not hide
        // a nested match of the same class).
        func allViews<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            var found: [T] = []
            if let match = root as? T { found.append(match) }
            for child in root.subviews { found += allViews(child, as: type) }
            return found
        }
        func control<T: NSView>(_ sheet: NSWindow?, _ label: String, as type: T.Type) -> T? {
            allViews(sheet?.contentView, as: type).first { $0.accessibilityLabel() == label }
        }

        // Fixture: A (RGB, one white layer), B; B is front so every capture
        // on A's controller must still land in A.
        let imageA = try session.newImage(width: 48, height: 32)
        let white = ClipboardImage(width: 48, height: 32,
                                   pixels: Data(repeating: 255, count: 48 * 32 * 4), origin: .zero)
        let layerA = try session.pastePixels(imageA, pixels: white, at: .zero)
        let docA = try ImageDocument(session: session, image: imageA, name: "Adj A")
        documents.items.append(docA)
        let a = DocumentWindowController(document: docA)
        a.showWindow(nil)
        let imageB = try session.newImage(width: 24, height: 24)
        let docB = try ImageDocument(session: session, image: imageB, name: "Adj B")
        documents.items.append(docB)
        let b = DocumentWindowController(document: docB)
        b.showWindow(nil)
        b.window?.makeKeyAndOrderFront(nil)
        var errorsA: [String] = []
        let reportA = docA.onError
        docA.onError = { reportA?($0); errorsA.append($0) }
        defer {
            for (controller, document) in [(a, docA), (b, docB)] {
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
                controller.previewPanel?.cancel()
                controller.window?.close()
                documents.items.removeAll { $0 === document }
                guard !document.isClosing else { continue }
                var closed = false
                document.closeImageWhenDrained { closed = true }
                wait { closed }
            }
        }
        guard a.window != nil else { return check(false, "the adjustment windows exist") }
        docA.selectLayer(layerA)
        settle(docA)

        // MARK: Menu wiring and the cached mode gate

        let adjSelector = #selector(DocumentWindowController.newAdjustmentLayer(_:))
        let layerMenu = MainMenu.make().items.first { $0.title == "Layer" }?.submenu
        let adjItem = layerMenu?.items.first { $0.title == "New Adjustment Layer…" }
        check(adjItem?.action == adjSelector, "Layer offers New Adjustment Layer… on the document's selector")
        check(adjItem.map { a.validateMenuItem($0) } == true, "the item validates on an RGB image")
        do {
            let imageI = try session.newImage(width: 16, height: 16)
            try session.convertToIndexed(imageI, settings: .init())
            let docI = try ImageDocument(session: session, image: imageI, name: "Adj I")
            documents.items.append(docI)
            let c = DocumentWindowController(document: docI)
            c.showWindow(nil)
            defer {
                c.window?.close()
                documents.items.removeAll { $0 === docI }
                if !docI.isClosing {
                    var closed = false
                    docI.closeImageWhenDrained { closed = true }
                    wait { closed }
                }
            }
            let item = NSMenuItem(title: "New Adjustment Layer…", action: adjSelector, keyEquivalent: "")
            check(!c.validateMenuItem(item) && item.toolTip?.contains("indexed") == true,
                  "on an indexed image the item disables with the reason as tooltip")
            c.newAdjustmentLayer(nil)
            check(c.adjustmentSheet == nil && c.window?.attachedSheet == nil,
                  "the action opens no sheet on an indexed image")
            let imageG = try session.newImage(width: 16, height: 16)
            try session.convertMode(imageG, to: .grayscale)
            let docG = try ImageDocument(session: session, image: imageG, name: "Adj G")
            documents.items.append(docG)
            let g = DocumentWindowController(document: docG)
            let itemG = NSMenuItem(title: "New Adjustment Layer…", action: adjSelector, keyEquivalent: "")
            check(g.validateMenuItem(itemG), "grayscale validates")
            g.window?.close()
            documents.items.removeAll { $0 === docG }
            var closedG = false
            docG.closeImageWhenDrained { closedG = true }
            wait { closedG }
        }

        // MARK: Cancel before Create mutates nothing (B front)

        let layersBefore = docA.layers.count
        let undoBefore = docA.undoInfo.undoCount
        a.newAdjustmentLayer(nil)
        guard let sheet = a.adjustmentSheet, let sheetWindow = a.window?.attachedSheet else {
            return check(false, "the creation sheet opens on A while B is front")
        }
        wait { !sheet.isLoadingOperations }
        check(!sheet.availableOperations.isEmpty, "the counted catalog load offers supported adjustments")
        check(adjItem.map { a.validateMenuItem($0) } == false, "the item disables while its sheet is attached")
        let nameField = control(sheetWindow, "Adjustment layer name", as: NSTextField.self)
        let popup = control(sheetWindow, "Adjustment", as: NSPopUpButton.self)
        let createButton = control(sheetWindow, "Create adjustment layer", as: NSButton.self)
        let cancelButton = control(sheetWindow, "Cancel adjustment layer", as: NSButton.self)
        check(nameField != nil && popup != nil && createButton != nil && cancelButton != nil,
              "the sheet's fields and buttons carry accessibility labels")
        check(createButton?.isEnabled == true && cancelButton?.isEnabled == true,
              "Create and Cancel start enabled")
        nameField?.stringValue = "  Draft  "
        popup?.selectItem(at: 0)
        cancelButton?.performClick(nil)
        wait { a.adjustmentSheet == nil && a.window?.attachedSheet == nil }
        check(docA.layers.count == layersBefore && docA.undoInfo.undoCount == undoBefore
                && errorsA.isEmpty,
              "Cancel before Create mutates nothing")

        // MARK: Accepted Create: ONE undo step, real ids, phase-2 editor

        let pixelsBefore = try session.copyPixels(imageA, merged: true).pixels
        a.newAdjustmentLayer(nil)
        guard let sheet2 = a.adjustmentSheet else { return check(false, "the sheet reopens for Create") }
        wait { !sheet2.isLoadingOperations && !sheet2.availableOperations.isEmpty }
        guard let opName = sheet2.availableOperations.first?.name else {
            return check(false, "a supported native adjustment is available")
        }
        let sheetWindow2 = a.window?.attachedSheet
        control(sheetWindow2, "Adjustment layer name", as: NSTextField.self)?.stringValue = "Brightness Test"
        control(sheetWindow2, "Adjustment", as: NSPopUpButton.self)?.selectItem(at: 0)
        let create2 = control(sheetWindow2, "Create adjustment layer", as: NSButton.self)
        let cancel2 = control(sheetWindow2, "Cancel adjustment layer", as: NSButton.self)
        let creationHold = DispatchSemaphore(value: 0)
        docA.inputQueue.async { creationHold.wait() }
        create2?.performClick(nil)
        check(create2?.isEnabled == false && cancel2?.isEnabled == false,
              "Create and Cancel disable while accepted work runs")
        creationHold.signal()
        wait { !sheet2.isCreating }
        settle(docA)
        let newLayer = docA.layers.first { $0.name == "Brightness Test" }
        check(newLayer?.kind == .group && newLayer?.filterCount == 1,
              "the native adjustment layer lands in A (B front) with one effect")
        check((try? session.layers(imageB).contains { $0.name == "Brightness Test" }) == false,
              "the front document B receives nothing")
        check(docA.undoInfo.undoCount == undoBefore + 1, "the creation is exactly ONE undo step")
        guard let newLayer else { return check(false, "the created adjustment layer exists") }
        let effects = try session.effects(on: newLayer.id, image: imageA)
        check(effects.count == 1 && effects[0].operation == opName,
              "the actual native effect id resolves to the chosen operation")
        wait { a.previewPanel != nil }
        check(a.previewPanel is NativeFilterPanel,
              "phase 2 opens the existing generic effect-parameter editor on the created effect")

        // Busy refusal while the parameter preview holds the image.
        var busyResult: Result<(layer: Int32, effect: Int32), Error>?
        docA.createAdjustmentLayer(name: "Second", operation: opName) { busyResult = $0 }
        settle(docA)
        check(busyResult.map { if case .failure = $0 { return true }; return false } == true
                && errorsA.contains { $0.contains("filter preview") },
              "a second creation refuses while the parameter editor's preview is open")

        // Canceling the parameter edit keeps the created layer, no extra undo.
        a.previewPanel?.cancel()
        settle(docA)
        check(a.previewPanel == nil && docA.layers.contains { $0.name == "Brightness Test" }
                && docA.undoInfo.undoCount == undoBefore + 1,
              "canceling the parameter editor keeps the explicitly created layer and adds no undo")
        let restoredEffects = try session.effects(on: newLayer.id, image: imageA)
        check(restoredEffects.count == 1 && restoredEffects[0].id == effects[0].id
                && restoredEffects[0].operation == opName && restoredEffects[0].isEnabled,
              "Cancel restores the same committed effect's enabled state after the temporary preview")

        // ONE Undo/Redo of the creation restores the original pixels.
        docA.undo()
        settle(docA)
        let pixelsAfterUndo = try session.copyPixels(imageA, merged: true).pixels
        check(docA.layers.first { $0.name == "Brightness Test" } == nil
                && pixelsAfterUndo == pixelsBefore,
              "one Undo removes the adjustment layer and restores the original pixels")
        docA.redo()
        settle(docA)
        check(docA.layers.first { $0.name == "Brightness Test" } != nil,
              "Redo brings the adjustment layer back")

        // All dedicated tonal choices must reach their actual parameter
        // editor from the creation sheet, then cancel without an edit undo.
        let tonalPanels: [(String, (FilterPreviewPanel) -> Bool)] = [
            ("gimp:levels", { $0 is LevelsPanel }),
            ("gimp:curves", { $0 is CurvesPanel }),
            ("glims:posterize", { $0 is NativeFilterPanel }),
            ("gimp:color-balance", { $0 is ColorBalancePanel }),
            ("gimp:hue-saturation", { $0 is HueSaturationPanel }),
        ]
        for (operation, isExpectedPanel) in tonalPanels {
            docA.selectLayer(layerA)
            settle(docA)
            let previousUndo = docA.undoInfo.undoCount
            a.newAdjustmentLayer(nil)
            guard let tonalSheet = a.adjustmentSheet else {
                return check(false, "creation sheet opens for \(operation)")
            }
            wait { !tonalSheet.isLoadingOperations }
            guard let index = tonalSheet.availableOperations.firstIndex(where: { $0.name == operation }) else {
                return check(false, "creation picker offers \(operation)")
            }
            control(a.window?.attachedSheet, "Adjustment", as: NSPopUpButton.self)?.selectItem(at: index)
            control(a.window?.attachedSheet, "Create adjustment layer", as: NSButton.self)?.performClick(nil)
            wait { !tonalSheet.isCreating && a.previewPanel != nil }
            settle(docA)
            check(a.previewPanel.map(isExpectedPanel) == true,
                  "\(operation) creation opens its dedicated parameter editor")
            check(docA.undoInfo.undoCount == previousUndo + 1,
                  "\(operation) sheet creation adds one undo step")
            a.previewPanel?.cancel()
            settle(docA)
            check(a.previewPanel == nil && docA.undoInfo.undoCount == previousUndo + 1,
                  "\(operation) editor cancel preserves creation without an edit undo")
            docA.undo()
            settle(docA)
        }

        // MARK: Floating-selection refusal

        var options = EngineSession.SelectOptions()
        options.antialias = false
        docA.select(.rectangle(CGRect(x: 4, y: 4, width: 8, height: 8)), options: options)
        settle(docA)
        docA.refreshSelection()
        docA.floatSelectedPixels(mode: .move, target: layerA) { _ in }
        settle(docA)
        check(docA.floatingState.isActive, "the floating fixture is active on A")
        check(adjItem.map { !a.validateMenuItem($0) } == true,
              "the adjustment creation menu disables while a floating selection is active")
        var floatResult: Result<(layer: Int32, effect: Int32), Error>?
        docA.createAdjustmentLayer(name: "Float", operation: opName) { floatResult = $0 }
        settle(docA)
        check(floatResult.map { if case .failure = $0 { return true }; return false } == true,
              "creation refuses while a floating selection is active")
        docA.resolveFloatingSelection(.anchor) { _ in }
        settle(docA)
        check(!docA.floatingState.isActive, "the floating fixture resolves for the close test")

        // MARK: Close drains the counted work; a closed host opens no editor

        a.newAdjustmentLayer(nil)
        guard let sheet3 = a.adjustmentSheet else { return check(false, "the sheet opens for the close test") }
        wait { !sheet3.isLoadingOperations && !sheet3.availableOperations.isEmpty }
        let sheetWindow3 = a.window?.attachedSheet
        control(sheetWindow3, "Adjustment layer name", as: NSTextField.self)?.stringValue = "Close Test"
        let closeHold = DispatchSemaphore(value: 0)
        docA.inputQueue.async { closeHold.wait() }
        control(sheetWindow3, "Create adjustment layer", as: NSButton.self)?.performClick(nil)
        // Inspect native state on the counted queue before teardown. A closed
        // host intentionally stops refreshing its presentation cache.
        final class CloseCreationProbe: @unchecked Sendable { var found = false }
        let creationProbe = CloseCreationProbe()
        docA.run(effect: .readsPixels) { session, image in
            creationProbe.found = try session.layers(image).contains { $0.name == "Close Test" }
        }
        // Hold the accepted worker explicitly: performClick can pump the main
        // run loop, so same-turn timing alone cannot establish an in-flight job.
        a.window?.close()
        check(sheet3.isCreating, "the accepted creation is still running when the window closes")
        closeHold.signal()
        settle(docA)
        wait { (try? session.info(imageA)) == nil }
        check(docA.isClosing && creationProbe.found,
              "the counted creation ran to completion before the close destroyed the image")
        check(a.previewPanel == nil,
              "a host closed before the creation completed never opens the parameter editor")
    }

    /// Run only with the test proxy: the catalog fails while image/layer APIs
    /// remain real. A failed query must not erase a previously working cache.
    static func exerciseAdjustmentCatalogFailure(_ session: EngineSession,
                                                 documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func views(_ root: NSView?) -> [NSView] {
            guard let root else { return [] }
            return [root] + root.subviews.flatMap { views($0) }
        }
        let cached = NativeFilterCatalog.shared.operations
        let sentinel = EngineSession.FilterOperation(name: "gegl:brightness-contrast",
            title: "Existing catalog entry", categories: ["color"], blurb: "", support: .supported)
        NativeFilterCatalog.shared.install([sentinel])
        defer { NativeFilterCatalog.shared.install(cached) }
        let image = try session.newImage(width: 16, height: 16)
        let document = try ImageDocument(session: session, image: image, name: "Catalog failure")
        let originalLayerIDs = document.layers.map(\.id)
        let originalUndo = document.undoInfo.undoCount
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        defer {
            if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
            controller.window?.close()
            documents.items.removeAll { $0 === document }
            if !document.isClosing {
                var closed = false
                document.closeImageWhenDrained { closed = true }
                wait { closed }
            }
        }
        controller.newAdjustmentLayer(nil)
        guard let sheet = controller.adjustmentSheet else {
            return check(false, "the adjustment form opens for the failed catalog read")
        }
        wait { !sheet.isLoadingOperations && document.pendingWork == 0 }
        check(sheet.lastError != nil && sheet.lastError != "No supported adjustments are available.",
              "the actual catalog failure is visible instead of an empty-catalog explanation")
        check(NativeFilterCatalog.shared.operation(named: sentinel.name)?.title == sentinel.title,
              "a failed native catalog query preserves the working shared cache")
        let buttons = views(sheet.panel.contentView).compactMap { $0 as? NSButton }
        check(buttons.first { $0.accessibilityLabel() == "Create adjustment layer" }?.isEnabled == false,
              "Create remains disabled without a valid catalog")
        check(buttons.first { $0.accessibilityLabel() == "Cancel adjustment layer" }?.isEnabled == true,
              "Cancel remains available after a catalog failure")
        check(document.layers.map(\.id) == originalLayerIDs && document.undoInfo.undoCount == originalUndo,
              "the failed catalog read creates no layer or history entry")
    }
}
