import AppKit

@MainActor
extension EngineSmokeTest {
    /// Actual menu/controls and literal coordinate oracles for dual-source
    /// Displace. Compiles on the old frontend: missing UI produces one named
    /// failure followed by cleanup, while dependent cases remain unexecuted.
    static func exerciseDisplaceSource(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool, _ message: String = "Displace times out waiting for its UI or counted work", timeout: TimeInterval = 15) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while !condition() && Date() < deadline {
                EngineSmokeTestHost.pumpEvents(for: 0.01)
            }
            let ok = condition()
            if !ok { check(false, message) }
            return ok
        }
        func views<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type) }
        }
        func button(_ root: NSView?, _ label: String) -> NSButton? {
            views(root, NSButton.self).first { $0.accessibilityLabel() == label || $0.title == label }
        }
        func popup(_ root: NSView?, _ label: String) -> NSPopUpButton? {
            views(root, NSPopUpButton.self).first { $0.accessibilityLabel() == label }
        }
        func settle(_ document: ImageDocument, _ message: String = "Displace counted work drains") -> Bool {
            guard wait({ document.pendingWork == 0 && !EngineActivity.shared.isBusy }, message) else { return false }
            EngineSmokeTestHost.pumpEvents(for: 0.03)
            return wait({ document.pendingWork == 0 && !EngineActivity.shared.isBusy }, message)
        }
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items + menu.items.flatMap { $0.submenu.map(menuItems) ?? [] }
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }

        var ownedImages: [Int32] = []
        var ownedDocuments: [ImageDocument] = []
        var ownedControllers: [DocumentWindowController] = []
        var ownedAuxWindows: [NSWindow] = []
        var releaseGates: [DispatchSemaphore] = []
        var finished = false
        var baselineBailout = false
        defer {
            releaseGates.forEach { $0.signal() }
            ownedControllers.forEach { $0.previewPanel?.cancel() }
            var renderersStopped = true
            for owner in ownedControllers {
                if let sheet = owner.window?.attachedSheet {
                    NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.abort.rawValue)
                    sheet.orderOut(nil)
                }
                owner.window?.orderOut(nil)
                var stopped = false
                owner.canvas.stopRendering { stopped = true }
                _ = wait({ stopped }, "Displace teardown drains every owned renderer")
                renderersStopped = renderersStopped && stopped
                owner.window?.close()
            }
            check(renderersStopped, "Displace teardown drains every owned renderer")
            ownedDocuments.forEach { $0.closeImageWhenDrained() }
            for image in ownedImages where !ownedDocuments.contains(where: { $0.image == image }) {
                if !gone(image) { try? session.closeImage(image) }
            }
            _ = wait({ ownedDocuments.allSatisfy { $0.pendingWork == 0 } && !EngineActivity.shared.isBusy }, "Displace teardown drains owned document work")
            _ = wait({ ownedImages.allSatisfy { gone($0) } }, "Displace teardown closes owned native images")
            check(ownedImages.allSatisfy { gone($0) } && ownedDocuments.allSatisfy { $0.pendingWork == 0 },
                  "Displace teardown closes every owned native image after counted work")
            check(ownedAuxWindows.allSatisfy { !$0.isVisible } && ownedControllers.allSatisfy { $0.window?.attachedSheet == nil },
                  "Displace teardown leaves no owned source chooser, preview, alert or dialog")
            documents.items.removeAll { candidate in ownedDocuments.contains { $0 === candidate } }
            if !baselineBailout {
                check(finished, "Displace completes every dedicated chooser acceptance scenario")
            }
        }

        // Independent analytic oracle (32x32 opaque RGBA target, RGB=x/y;
        // maps X white RGBA 255, Y black RGB 0/A255). Sampler nearest, Cartesian,
        // amountx=1, amounty=1, abyss clamp, center false => out(x,y)=in(clamp(x+1),clamp(y-1)).
        let side = 32
        func clampCoord(_ value: Int) -> Int { min(max(value, 0), side - 1) }
        func targetByte(x: Int, y: Int, channel: Int) -> UInt8 {
            switch channel {
            case 0: return UInt8(x)
            case 1: return UInt8(y)
            case 2: return UInt8((x * 7 + y * 11) % 256)
            default: return 255
            }
        }
        // Literal integer coordinate oracles, not an adapter/GEGL builder or
        // a reimplementation of generalized color-to-displacement conversion.
        func displacedBytes(dx: Int, dy: Int) -> Data {
            var out = [UInt8](repeating: 0, count: side * side * 4)
            for y in 0..<side { for x in 0..<side {
                let i = (y * side + x) * 4
                let sx = clampCoord(x + dx), sy = clampCoord(y + dy)
                for channel in 0..<4 { out[i + channel] = targetByte(x: sx, y: sy, channel: channel) }
            } }
            return Data(out)
        }
        var targetBytes = [UInt8](repeating: 0, count: side * side * 4)
        let xMapBytes = [UInt8](repeating: 255, count: side * side * 4) // white RGB/A
        let yMapBytes: [UInt8] = (0..<(side * side)).flatMap { _ in [UInt8(0), 0, 0, 255] } // black RGB, opaque A
        let zeroAlphaMapBytes = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side { for x in 0..<side {
            let i = (y * side + x) * 4
            targetBytes[i + 0] = targetByte(x: x, y: y, channel: 0)
            targetBytes[i + 1] = targetByte(x: x, y: y, channel: 1)
            targetBytes[i + 2] = targetByte(x: x, y: y, channel: 2)
            targetBytes[i + 3] = 255
        } }
        let originalData = Data(targetBytes)
        let expectedXY = displacedBytes(dx: 1, dy: -1)
        let expectedXOnly = displacedBytes(dx: 1, dy: 0)
        let expectedYOnly = displacedBytes(dx: 0, dy: -1)
        let expectedSwapped = displacedBytes(dx: -1, dy: 1)
        let expectedZeroAlpha = originalData
        check(expectedXY != originalData, "Displace analytic oracle changes target pixels for X/Y displacement")
        check(expectedXOnly != originalData && expectedYOnly != originalData && expectedXOnly != expectedYOnly,
              "Displace analytic axis controls produce distinct X-only and Y-only literals")
        check(expectedSwapped != expectedXY, "swapped Displace map roles produce a distinct literal oracle")
        check(expectedZeroAlpha == originalData, "zero-alpha Displace maps produce no axis displacement by literal oracle")

        let targetPixels = ClipboardImage(width: side, height: side, pixels: originalData, origin: .zero)
        let xMapPixels = ClipboardImage(width: side, height: side, pixels: Data(xMapBytes), origin: .zero)
        let yMapPixels = ClipboardImage(width: side, height: side, pixels: Data(yMapBytes), origin: .zero)
        let zeroMapPixels = ClipboardImage(width: side, height: side, pixels: Data(zeroAlphaMapBytes), origin: .zero)

        func fixture(includeZeroMap: Bool = false) throws -> (image: Int32, target: Int32, xMap: Int32, yMap: Int32, witness: Int32, zeroMap: Int32?) {
            let image = try session.newImage(pixels: targetPixels)
            ownedImages.append(image)
            do {
                guard let target = try session.layers(image).first?.id else { throw ImageDocument.DocumentError.busy }
                try session.changeLayer(target, image: image, .init(name: "Displace target"))
                let xMap = try session.pastePixels(image, pixels: xMapPixels, at: .zero)
                try session.changeLayer(xMap, image: image, .init(name: "Map X White", isVisible: false))
                let yMap = try session.pastePixels(image, pixels: yMapPixels, at: .zero)
                try session.changeLayer(yMap, image: image, .init(name: "Map Y Black", isVisible: false))
                var zeroMap: Int32?
                if includeZeroMap {
                    let id = try session.pastePixels(image, pixels: zeroMapPixels, at: .zero)
                    try session.changeLayer(id, image: image, .init(name: "Map Zero Alpha", isVisible: false))
                    zeroMap = id
                }
                let witnessPixels = ClipboardImage(width: 8, height: 8, pixels: Data(repeating: 127, count: 8 * 8 * 4), origin: .zero)
                let witness = try session.pastePixels(image, pixels: witnessPixels, at: .zero)
                try session.changeLayer(witness, image: image, .init(name: "Witness layer", isVisible: false))
                try session.selectItems([target], kind: .layer, image: image)
                return (image, target, xMap, yMap, witness, zeroMap)
            } catch {
                try? session.closeImage(image)
                throw error
            }
        }

        let a = try fixture(includeZeroMap: true)
        let imageB = try session.newImage(width: 12, height: 12)
        ownedImages.append(imageB)
        let docA = try ImageDocument(session: session, image: a.image, name: "Displace A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Displace B")
        ownedDocuments += [docA, docB]
        documents.items += [docA, docB]
        let controllerA = DocumentWindowController(document: docA)
        let controllerB = DocumentWindowController(document: docB)
        ownedControllers += [controllerA, controllerB]
        NSApp.activate(ignoringOtherApps: true)
        controllerA.showWindow(nil)
        controllerB.showWindow(nil)
        controllerA.window?.makeKeyAndOrderFront(nil)
        guard wait({ controllerA.window?.isVisible == true && controllerB.window?.isVisible == true
                     && NSApp.isActive && NSApp.mainWindow === controllerA.window && NSApp.keyWindow === controllerA.window },
                   "Displace fixture has a real active main/key A window") else { return }
        check(true, "Displace fixture runs in a launched active AppKit host with A main/key")

        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        guard let operation = operations.first(where: { $0.name == "gegl:displace" }),
              let menu = NSApp.mainMenu else {
            return check(false, "the native Displace catalog and main menu exist")
        }
        check(operation.support == .needsAuxInput, "the installed Displace operation advertises auxiliary input")
        NativeFilterMenus.install(operations, in: menu)
        guard let item = menuItems(menu).first(where: { ($0.representedObject as? NativeFilterCommand)?.operation.name == operation.name }) else {
            return check(false, "the real Filter menu lists the installed Displace")
        }

        item.menu?.update()
        let uiReady = controllerA.validateMenuItem(item) && item.isEnabled && item.title == "Displace…"
        check(uiReady, "the actual Displace menu item is enabled and offers Displace…")
        guard uiReady else {
            print("Displace baseline bailout: missing enabled Displace chooser UI on old frontend; positive functional/chooser cases NOT RUN.")
            baselineBailout = true
            return
        }

        func sourceWindow() -> NSWindow? {
            guard let result = NSApp.windows.first(where: {
                $0.isVisible && $0.title == "Displace Sources" && $0.parent === controllerA.window
            }) else { return nil }
            if !ownedAuxWindows.contains(where: { $0 === result }) { ownedAuxWindows.append(result) }
            return result
        }
        func sendMenu() {
            controllerA.window?.makeMain()
            controllerA.window?.makeKeyAndOrderFront(nil)
            if let action = item.action { _ = NSApp.sendAction(action, to: controllerA, from: item) }
            EngineSmokeTestHost.pumpEvents(for: 0.05)
        }

        sendMenu()
        guard wait({ sourceWindow() != nil }, "the real Displace menu action opens its owning document's Displace Sources chooser"),
              let chooser = sourceWindow() else { return }
        let hLabel = "Horizontal / radial map source"
        let vLabel = "Vertical / angular map source"
        guard let hPopup = popup(chooser.contentView, hLabel),
              let vPopup = popup(chooser.contentView, vLabel),
              let preview = button(chooser.contentView, "Preview Displace"),
              let cancelChooser = button(chooser.contentView, "Cancel filter source") else {
            return check(false, "Displace chooser exposes the two map role popups and Preview/Cancel actions by exact accessible labels")
        }
        check(hPopup.selectedItem == nil && vPopup.selectedItem == nil && !preview.isEnabled,
              "Displace chooser starts with neither source chosen and Preview disabled until both are explicit live IDs")
        // Missing one selection must keep Preview disabled.
        hPopup.selectItem(withTitle: "Map X White")
        if let action = hPopup.action { _ = NSApp.sendAction(action, to: hPopup.target, from: hPopup) }
        EngineSmokeTestHost.pumpEvents(for: 0.02)
        check(!preview.isEnabled, "selecting only one Displace source keeps Preview disabled")
        vPopup.selectItem(withTitle: "Map Y Black")
        if let action = vPopup.action { _ = NSApp.sendAction(action, to: vPopup.target, from: vPopup) }
        check(preview.isEnabled, "both explicit live Displace map choices admit Preview before retargeting")

        let originalHistory = try session.undoInfo(a.image)
        let originalPixels = try session.copyPixels(a.image, merged: true).pixels
        let bPixels = try session.copyPixels(imageB, merged: true).pixels
        let bHistory = try session.undoInfo(imageB)

        // Captured target retarget refusal + restore without manual chooser refresh.
        docA.selectLayer(a.witness)
        _ = settle(docA)
        preview.performClick(nil)
        _ = settle(docA)
        check(try docA.selectedLayerIDs == [a.witness] && !preview.isEnabled
                && !docA.filterPreviewIsOpen && controllerA.previewPanel == nil
                && sourceWindow() === chooser && session.undoInfo(a.image) == originalHistory
                && session.copyPixels(a.image, merged: true).pixels == originalPixels,
              "retargeting A disables the captured Displace Preview without changing native pixels or history")
        docA.selectLayer(a.target)
        _ = settle(docA)
        check(preview.isEnabled && hPopup.selectedItem?.title == "Map X White"
                && vPopup.selectedItem?.title == "Map Y Black" && sourceWindow() === chooser,
              "restoring the original target re-enables the same two explicit choices without manual refresh")

        // Cancel chooser exact pixels/history.
        cancelChooser.performClick(nil)
        _ = settle(docA)
        check(try sourceWindow() == nil && !docA.filterPreviewIsOpen
                && session.undoInfo(a.image) == originalHistory
                && session.copyPixels(a.image, merged: true).pixels == originalPixels,
              "Cancel Displace source selection leaves pixels and all native history unchanged")

        // Generic panel preview analytic cases incl zero/axis/swapped.
        let properties = try session.filterOperationProperties(operation.name)
        func property(named: String) -> EngineSession.FilterProperty? { properties.first { $0.name == named } }
        guard let amountXProp = property(named: "amount-x"), let amountYProp = property(named: "amount-y"),
              let samplerProp = property(named: "sampler-type"), let modeProp = property(named: "displace-mode"),
              let abyssProp = property(named: "abyss-policy"), let centerProp = property(named: "center") else {
            return check(false, "Displace exposes its exact native scalar, sampler, mode, abyss and center properties")
        }
        let samplerChoices = try session.filterEnumChoices(operation.name, property: samplerProp.name)
        let modeChoices = try session.filterEnumChoices(operation.name, property: modeProp.name)
        let abyssChoices = try session.filterEnumChoices(operation.name, property: abyssProp.name)
        guard samplerChoices.contains(where: { $0.nick == "nearest" }), modeChoices.contains(where: { $0.nick == "cartesian" }),
              abyssChoices.contains(where: { $0.nick == "clamp" }) else {
            return check(false, "the installed Displace exposes exact nearest/cartesian/clamp enum nicks")
        }
        var acceptedHorizontal: NSPopUpButton?, acceptedVertical: NSPopUpButton?
        func openPanel(horizontal: String, vertical: String) -> NativeFilterPanel? {
            sendMenu()
            guard wait({ sourceWindow() != nil }, "Displace chooser opens for preview"),
                  let chooser = sourceWindow(),
                  let h = popup(chooser.contentView, hLabel),
                  let v = popup(chooser.contentView, vLabel),
                  let p = button(chooser.contentView, "Preview Displace") else { return nil }
            h.selectItem(withTitle: horizontal); if let action = h.action { _ = NSApp.sendAction(action, to: h.target, from: h) }
            v.selectItem(withTitle: vertical); if let action = v.action { _ = NSApp.sendAction(action, to: v.target, from: v) }
            EngineSmokeTestHost.pumpEvents(for: 0.02)
            acceptedHorizontal = h; acceptedVertical = v
            // B must be real main/key before A's accepted chooser action.
            controllerB.window?.makeMain(); controllerB.window?.makeKeyAndOrderFront(nil)
            guard wait({ NSApp.isActive && NSApp.mainWindow === controllerB.window && NSApp.keyWindow === controllerB.window },
                       "B is real main/key before A chooser Preview") else { return nil }
            check(true, "B is the actual main/key document before captured A's Preview")
            p.performClick(nil)
            _ = wait({ controllerA.previewPanel != nil || (!chooser.isVisible && docA.pendingWork == 0) }, "Displace chooser Preview opens the native parameter panel")
            _ = settle(docA)
            let panel = controllerA.previewPanel as? NativeFilterPanel
            if let window = panel?.window, !ownedAuxWindows.contains(where: { $0 === window }) { ownedAuxWindows.append(window) }
            return panel
        }
        func numberField(_ panel: NativeFilterPanel, label: String) -> NSTextField? {
            views(panel.window?.contentView, NSTextField.self).first {
                ($0.accessibilityLabel() ?? "").hasPrefix(label) && $0.isEditable
            }
        }
        func sendNumber(_ field: NSTextField?, _ value: Double) {
            guard let field else { return }
            field.stringValue = (field.formatter as? NumberFormatter)?.string(from: NSNumber(value: value)) ?? "\(value)"
            if let action = field.action { _ = NSApp.sendAction(action, to: field.target, from: field) }
        }
        func chooseEnum(_ panel: NativeFilterPanel, property: EngineSession.FilterProperty,
                        choices: [EngineSession.FilterEnumChoice], nick: String) -> Bool {
            guard let control = popup(panel.window?.contentView, property.label),
                  let index = choices.firstIndex(where: { $0.nick == nick }),
                  control.numberOfItems == choices.count, let action = control.action else { return false }
            control.selectItem(at: index)
            return NSApp.sendAction(action, to: control.target, from: control)
        }
        func configurePanel(_ panel: NativeFilterPanel, ax: Double, ay: Double) -> Bool {
            guard let filter = panel.filter,
                  let xField = numberField(panel, label: amountXProp.label),
                  let yField = numberField(panel, label: amountYProp.label),
                  let center = button(panel.window?.contentView, centerProp.label),
                  chooseEnum(panel, property: samplerProp, choices: samplerChoices, nick: "nearest"),
                  chooseEnum(panel, property: modeProp, choices: modeChoices, nick: "cartesian"),
                  chooseEnum(panel, property: abyssProp, choices: abyssChoices, nick: "clamp") else {
                check(false, "Displace exposes actionable numeric, enum and center controls"); return false
            }
            if center.state != .off { center.performClick(nil) }
            // Exercise the actual checkbox action in both directions.
            center.performClick(nil); center.performClick(nil)
            sendNumber(xField, ax); sendNumber(yField, ay)
            guard settle(docA) else { return false }
            let ok = (try? session.filterProperty(filter, "amount-x")) == .number(ax)
                && (try? session.filterProperty(filter, "amount-y")) == .number(ay)
                && (try? session.filterProperty(filter, "sampler-type")) == .enumeration("nearest")
                && (try? session.filterProperty(filter, "displace-mode")) == .enumeration("cartesian")
                && (try? session.filterProperty(filter, "abyss-policy")) == .enumeration("clamp")
                && (try? session.filterProperty(filter, "center")) == .boolean(false)
            check(ok, "real Displace numeric/enum/checkbox controls send exact requested native properties")
            return ok
        }
        guard let panel = openPanel(horizontal: "Map X White", vertical: "Map Y Black"),
              panel.filter != nil else {
            return check(false, "accepting two explicit Displace maps opens the native parameter form for captured A while B is frontmost")
        }
        check(docA.filterPreviewIsOpen && !docB.filterPreviewIsOpen && sourceWindow() == nil && panel.window?.title == operation.title,
              "Displace Preview belongs to captured A after B was frontmost and closes only A's chooser")
        guard configurePanel(panel, ax: 1, ay: 1) else { return }
        check(try session.copyPixels(a.image, merged: true).pixels == expectedXY,
              "Displace chosen-source UI preview matches the literal coordinate analytic oracle (x+1,y-1)")
        check(try session.copyPixels(imageB, merged: true).pixels == bPixels && session.undoInfo(imageB) == bHistory,
              "captured Displace preview leaves other document B's pixels and history untouched")

        // axis controls
        guard configurePanel(panel, ax: 1, ay: 0) else { return }
        check(try session.copyPixels(a.image, merged: true).pixels == expectedXOnly, "Displace zero-Y amount preview matches literal X-only oracle")
        guard configurePanel(panel, ax: 0, ay: 1) else { return }
        check(try session.copyPixels(a.image, merged: true).pixels == expectedYOnly, "Displace zero-X amount preview matches literal Y-only oracle")
        guard configurePanel(panel, ax: 1, ay: 1) else { return }
        let beforeLate = try session.copyPixels(a.image, merged: true).pixels
        guard let staleH = acceptedHorizontal, let staleV = acceptedVertical else {
            return check(false, "the actual accepted source controls remain available for a stale-action probe")
        }
        staleH.selectItem(withTitle: "Map Y Black"); staleV.selectItem(withTitle: "Map X White")
        for control in [staleH, staleV] {
            if let action = control.action { _ = NSApp.sendAction(action, to: control.target, from: control) }
        }
        guard configurePanel(panel, ax: 2, ay: 1), configurePanel(panel, ax: 1, ay: 1) else { return }
        check(try session.copyPixels(a.image, merged: true).pixels == beforeLate && sourceWindow() == nil,
              "late retired source controls cannot retarget either snapshot after actual parameter reevaluation")

        // parameter Cancel raw/history exact
        button(panel.window?.contentView, "Cancel")?.performClick(nil)
        _ = settle(docA)
        check(try !docA.filterPreviewIsOpen && controllerA.previewPanel == nil
                && session.undoInfo(a.image) == originalHistory
                && session.copyPixels(a.image, merged: true).pixels == originalPixels,
              "Displace parameter Cancel restores every original pixel and full native history")

        // swapped map roles and zero-map-alpha (no axis displacement)
        guard let swappedPanel = openPanel(horizontal: "Map Y Black", vertical: "Map X White") else {
            return check(false, "Displace reopens for swapped map roles preview")
        }
        guard configurePanel(swappedPanel, ax: 1, ay: 1) else { return }
        check(try session.copyPixels(a.image, merged: true).pixels == expectedSwapped,
              "swapped Displace map roles preview matches the literal swapped analytic oracle")
        button(swappedPanel.window?.contentView, "Cancel")?.performClick(nil)
        _ = settle(docA)
        guard a.zeroMap != nil, let zeroPanel = openPanel(horizontal: "Map Zero Alpha", vertical: "Map Zero Alpha") else {
            return check(false, "Displace opens both explicit zero-alpha source roles")
        }
        guard configurePanel(zeroPanel, ax: 1, ay: 1) else { return }
        check(try session.copyPixels(a.image, merged: true).pixels == expectedZeroAlpha,
              "transparent Displace maps suppress both axes and preserve every original opaque RGBA byte")
        button(zeroPanel.window?.contentView, "Cancel")?.performClick(nil)
        guard settle(docA) else { return }

        // Apply one Undo/no aux effect, Undo/Redo exact, B unchanged.
        guard let applyPanel = openPanel(horizontal: "Map X White", vertical: "Map Y Black") else {
            return check(false, "Displace reopens for confirmed pixel Apply")
        }
        guard configurePanel(applyPanel, ax: 1, ay: 1) else { return }
        button(applyPanel.window?.contentView, "Apply to Pixels")?.performClick(nil)
        _ = settle(docA)
        let applied = try session.copyPixels(a.image, merged: true).pixels
        let oneUndo = try session.undoInfo(a.image).undoCount == originalHistory.undoCount + 1
        let noAux = (try? session.effects(on: a.target, image: a.image).isEmpty) == true
        check(applied == expectedXY && oneUndo && noAux && !docA.filterPreviewIsOpen,
              "Displace Apply commits the literal result as pixels with exactly one native Undo and no saved auxiliary effect")
        docA.undo(); _ = settle(docA)
        check(try session.copyPixels(a.image, merged: true).pixels == originalPixels,
              "one document Undo restores the exact original Displace pixels")
        docA.redo(); _ = settle(docA)
        check(try session.copyPixels(a.image, merged: true).pixels == applied
                && session.copyPixels(imageB, merged: true).pixels == bPixels
                && session.undoInfo(imageB) == bHistory,
              "Displace Redo restores exact applied pixels while document B stays unchanged")

        // Cached busy menu disabled.
        let ready = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        releaseGates.append(release)
        let held = EngineActivity.shared.perform(label: "Displace busy fixture", work: {
            ready.signal(); _ = release.wait(timeout: .now() + 20)
        }, completion: {})
        var started = false
        let holdDeadline = Date().addingTimeInterval(10)
        while !started && Date() < holdDeadline {
            started = ready.wait(timeout: .now()) == .success
            if !started { EngineSmokeTestHost.pumpEvents(for: 0.01) }
        }
        check(held && started && !controllerA.validateMenuItem(item), "cached engine activity disables the Displace menu")
        release.signal()
        _ = wait({ !EngineActivity.shared.isBusy }, "Displace busy fixture releases")

        // Selected map delete while chooser open: placeholder preserved/no automatic other role/no preview.
        sendMenu()
        guard let deleteChooser = sourceWindow(),
              let dh = popup(deleteChooser.contentView, hLabel),
              let dv = popup(deleteChooser.contentView, vLabel),
              let dp = button(deleteChooser.contentView, "Preview Displace") else {
            return check(false, "Displace chooser opens before deleting a selected map")
        }
        dh.selectItem(withTitle: "Map X White"); if let action = dh.action { _ = NSApp.sendAction(action, to: dh.target, from: dh) }
        dv.selectItem(withTitle: "Map Y Black"); if let action = dv.action { _ = NSApp.sendAction(action, to: dv.target, from: dv) }
        docA.selectLayer(a.xMap); _ = settle(docA)
        docA.layerCommand(.delete); _ = settle(docA)
        docA.selectLayer(a.target); _ = settle(docA)
        let afterDeleteHistory = try session.undoInfo(a.image)
        let afterDeletePixels = try session.copyPixels(a.image, merged: true).pixels
        let deletedPlaceholder = dh.selectedItem?.title == "Map X White" && dh.selectedItem?.isEnabled == false
        check(deletedPlaceholder && dv.selectedItem?.title == "Map Y Black" && dv.selectedItem?.isEnabled == true,
              "deleting X preserves its missing placeholder and the independently selected live Y role")
        check(dp.isEnabled == false, "a missing Displace map role disables Preview")
        dp.performClick(nil); _ = settle(docA)
        check(try !docA.filterPreviewIsOpen && controllerA.previewPanel == nil
                && session.undoInfo(a.image) == afterDeleteHistory
                && session.copyPixels(a.image, merged: true).pixels == afterDeletePixels,
              "a stale missing-Displace-source chooser starts no preview and preserves post-delete pixels and history")
        button(deleteChooser.contentView, "Cancel filter source")?.performClick(nil); _ = settle(docA)

        // ownerClose while chooser/pending begin invalidates and late source controls can't start session.
        sendMenu()
        guard let closingChooser = sourceWindow() else {
            return check(false, "Displace chooser opens before owner close")
        }
        controllerA.window?.close()
        _ = wait({ docA.isClosing && !closingChooser.isVisible }, "closing A invalidates its Displace source chooser")
        button(closingChooser.contentView, "Preview Displace")?.performClick(nil)
        _ = wait({ docA.pendingWork == 0 }, "late Displace Preview after close drains without starting a session")
        _ = wait({ gone(a.image) }, "closed Displace document drains native close")
        check(docA.isClosing && !closingChooser.isVisible && controllerA.previewPanel == nil,
              "closing A invalidates its Displace chooser and a late Preview cannot open a filter")
        check(!controllerA.validateMenuItem(item) && gone(a.image),
              "closed-document validation disables Displace and native close drains")

        // Close after native Begin is genuinely queued behind accepted input.
        // The already-linked native operation must either refuse or be teardown-
        // aborted; the late completion may not display a panel or outlive close.
        let pending = try fixture()
        let pendingDoc = try ImageDocument(session: session, image: pending.image, name: "Displace Pending Close")
        ownedDocuments.append(pendingDoc); documents.items.append(pendingDoc)
        let pendingController = DocumentWindowController(document: pendingDoc)
        ownedControllers.append(pendingController); pendingController.showWindow(nil)
        sendMenuTo(pendingController, item: item)
        guard let pendingChooser = NSApp.windows.first(where: {
            $0.isVisible && $0.title == "Displace Sources" && $0.parent === pendingController.window
        }), let pendingH = popup(pendingChooser.contentView, hLabel),
            let pendingV = popup(pendingChooser.contentView, vLabel),
            let pendingPreview = button(pendingChooser.contentView, "Preview Displace") else {
            return check(false, "a captured chooser opens for the pending-Begin close fixture")
        }
        ownedAuxWindows.append(pendingChooser)
        pendingH.selectItem(withTitle: "Map X White"); pendingV.selectItem(withTitle: "Map Y Black")
        for control in [pendingH, pendingV] {
            if let action = control.action { _ = NSApp.sendAction(action, to: control.target, from: control) }
        }
        let inputReady = DispatchSemaphore(value: 0), inputRelease = DispatchSemaphore(value: 0)
        releaseGates.append(inputRelease)
        pendingDoc.inputQueue.async { inputReady.signal(); _ = inputRelease.wait(timeout: .now() + 20) }
        var inputStarted = false
        guard wait({
            if !inputStarted { inputStarted = inputReady.wait(timeout: .now()) == .success }
            return inputStarted
        }, "pending-Begin input barrier starts") else { return }
        pendingPreview.performClick(nil)
        guard wait({ pendingDoc.filterPreviewIsOpen && pendingDoc.pendingWork > 0 && pendingController.previewPanel == nil },
                   "Displace native Begin is counted and waiting behind the input barrier") else { return }
        check(true, "accepted Displace Begin reserves the owner before native completion")
        pendingController.window?.close()
        guard wait({ pendingDoc.isClosing && !pendingChooser.isVisible }, "closing the pending owner invalidates its chooser") else { return }
        pendingPreview.performClick(nil)
        inputRelease.signal()
        guard wait({ pendingDoc.pendingWork == 0 && gone(pending.image) }, "accepted Begin and stale-session teardown drain before native close") else { return }
        check(pendingController.previewPanel == nil && !pendingDoc.filterPreviewIsOpen && !pendingChooser.isVisible,
              "a late accepted Begin cannot show a panel or retain its closed native owner")
        check(try session.copyPixels(imageB, merged: true).pixels == bPixels && session.undoInfo(imageB) == bHistory,
              "pending-Begin close leaves other document B untouched")

        // Destructive-target consent is the existing Layer action, never an
        // implicit filter step. A completed rasterize requires fresh invocation.
        let textImage = try session.newImage(width: 96, height: 64)
        ownedImages.append(textImage)
        let textMapX = try session.pastePixels(textImage, pixels: xMapPixels, at: .zero)
        let textMapY = try session.pastePixels(textImage, pixels: yMapPixels, at: .zero)
        try session.changeLayer(textMapX, image: textImage, .init(name: "Text X map", isVisible: false))
        try session.changeLayer(textMapY, image: textImage, .init(name: "Text Y map", isVisible: false))
        let fonts = try session.fonts()
        guard let font = fonts.first(where: { $0.localizedCaseInsensitiveContains("sans") }) ?? fonts.first else {
            return check(false, "native text fixture has a real installed font")
        }
        var settings = EngineSession.TextSettings(); settings.font = font; settings.size = 18
        let textLayer = try session.addTextLayer(image: textImage, text: "Rasterize", settings: settings, at: CGPoint(x: 4, y: 8))
        try session.selectItems([textLayer], kind: .layer, image: textImage)
        let textDoc = try ImageDocument(session: session, image: textImage, name: "Displace Text")
        ownedDocuments.append(textDoc); documents.items.append(textDoc)
        let textController = DocumentWindowController(document: textDoc)
        ownedControllers.append(textController); textController.showWindow(nil)
        guard settle(textDoc) else { return }
        let textHistory = try session.undoInfo(textImage), textPixels = try session.copyPixels(textImage, merged: true).pixels
        func textChooser() -> NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.title == "Displace Sources" && $0.parent === textController.window }
        }
        check(!textController.validateMenuItem(item), "Displace refuses the actual unrasterized text target")
        sendMenuTo(textController, item: item)
        check(try textChooser() == nil && !textDoc.filterPreviewIsOpen && session.undoInfo(textImage) == textHistory
                && session.copyPixels(textImage, merged: true).pixels == textPixels,
              "unrasterized filter admission queues no implicit Rasterize or pixel mutation")
        guard let rasterize = menuItems(menu).first(where: { $0.action == #selector(DocumentWindowController.rasterizeLayer(_:)) }),
              textController.validateMenuItem(rasterize), let rasterizeAction = rasterize.action else {
            return check(false, "the existing Layer menu admits captured-target Rasterize")
        }
        _ = NSApp.sendAction(rasterizeAction, to: textController, from: rasterize)
        guard wait({ textController.window?.attachedSheet != nil }, "the real Rasterize confirmation appears"),
              let cancelSheet = textController.window?.attachedSheet,
              let cancelRasterize = button(cancelSheet.contentView, "Cancel") else {
            return check(false, "Rasterize confirmation exposes its actual Cancel action")
        }
        ownedAuxWindows.append(cancelSheet)
        check(textChooser() == nil && !textDoc.filterPreviewIsOpen, "Rasterize consent does not revive an old filter invocation")
        cancelRasterize.performClick(nil)
        guard wait({ textController.window?.attachedSheet == nil }, "Rasterize Cancel dismisses its owned sheet"), settle(textDoc) else { return }
        check(try textDoc.layerSources[textLayer]?.isRasterized == false && session.undoInfo(textImage) == textHistory
                && session.copyPixels(textImage, merged: true).pixels == textPixels,
              "Cancel Rasterize preserves editable text, every pixel and native history")
        _ = NSApp.sendAction(rasterizeAction, to: textController, from: rasterize)
        guard wait({ textController.window?.attachedSheet != nil }, "Rasterize confirmation reopens"),
              let confirmSheet = textController.window?.attachedSheet,
              let confirmRasterize = button(confirmSheet.contentView, "Rasterize") else {
            return check(false, "Rasterize confirmation exposes the actual destructive action")
        }
        ownedAuxWindows.append(confirmSheet)
        confirmRasterize.performClick(nil)
        guard wait({ textDoc.layerSources[textLayer]?.isRasterized == true && textDoc.pendingWork == 0 },
                   "captured native Rasterize finishes and reconciles its source state") else { return }
        check(try textDoc.selectedLayerIDs == [textLayer] && session.undoInfo(textImage).undoCount == textHistory.undoCount + 1
                && !textDoc.filterPreviewIsOpen && textChooser() == nil,
              "confirmed Rasterize changes only its captured target and starts no implicit Displace preview")
        check(textController.validateMenuItem(item), "fresh cached admission enables Displace after completed rasterization")
        sendMenuTo(textController, item: item)
        guard let freshTextChooser = textChooser() else { return check(false, "fresh Displace invocation opens after explicit rasterization") }
        ownedAuxWindows.append(freshTextChooser)
        check(popup(freshTextChooser.contentView, hLabel)?.selectedItem == nil
                && popup(freshTextChooser.contentView, vLabel)?.selectedItem == nil
                && button(freshTextChooser.contentView, "Preview Displace")?.isEnabled == false,
              "fresh post-rasterize invocation requires both new explicit map choices")
        button(freshTextChooser.contentView, "Cancel filter source")?.performClick(nil)
        guard settle(textDoc) else { return }

        finished = true
    }

    @MainActor
    private static func sendMenuTo(_ controller: DocumentWindowController, item: NSMenuItem) {
        controller.window?.makeMain()
        controller.window?.makeKeyAndOrderFront(nil)
        if let action = item.action { _ = NSApp.sendAction(action, to: controller, from: item) }
        EngineSmokeTestHost.pumpEvents(for: 0.03)
    }
}
