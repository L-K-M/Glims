import AppKit

@MainActor
extension EngineSmokeTest {
    /// The explicit oracle directory is exported by the native fixture's
    /// direct Core path. This test also compiles on the pre-chooser frontend.
    static func exerciseOilifySource(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }
        func require(_ condition: Bool, _ message: String) -> Bool {
            check(condition, message)
            return condition
        }
        func views<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type) }
        }
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items + menu.items.flatMap { $0.submenu.map(menuItems) ?? [] }
        }
        func projection(_ image: Int32) throws -> Data {
            let frame = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 32, height: 32))
            guard let bytes = frame.dataProvider?.data else { throw ImageDocument.DocumentError.busy }
            return bytes as Data
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        var images: [Int32] = []
        var owners: [DocumentWindowController] = []
        var auxiliary: [NSWindow] = []
        defer {
            var renderersStopped = true
            for owner in owners {
                owner.previewPanel?.cancel()
                owner.window?.orderOut(nil)
                var stopped = false
                owner.canvas.stopRendering { stopped = true }
                if !wait({ stopped }) { renderersStopped = false }
                owner.window?.close()
                owner.imageDocument.closeImageWhenDrained()
            }
            check(renderersStopped, "Oilify teardown drains owned renderers")
            for image in images where !owners.contains(where: { $0.imageDocument.image == image }) {
                if !gone(image) { try? session.closeImage(image) }
            }
            check(wait({ images.allSatisfy(gone) && owners.allSatisfy { $0.imageDocument.pendingWork == 0 } }),
                  "Oilify teardown drains work and closes the exact owned native images")
            check(auxiliary.allSatisfy { !$0.isVisible } && owners.allSatisfy { $0.window?.attachedSheet == nil },
                  "Oilify teardown leaves no owned chooser, preview or sheet")
            documents.items.removeAll { document in owners.contains { $0.imageDocument === document } }
        }

        guard let path = ProcessInfo.processInfo.environment["GLIMS_OILIFY_UI_ORACLES"], path.hasPrefix("/") else {
            return check(false, "Oilify requires the explicit direct-Core artifact directory")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        func bytes(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
        let before = try bytes("before.rgba")
        let roles = [("plain", "None", "None"), ("radius", "Height source", "None"), ("exponent", "None", "Exponent map")]
        let previews = try roles.map { try bytes("\($0.0)-preview.rgba") }
        let applied = try roles.map { try bytes("\($0.0)-applied.rgba") }
        guard require(before.count == 32 * 32 * 4 && (previews + applied).allSatisfy { $0.count == before.count && $0 != before }
                        && Set(previews).count == roles.count && Set(applied).count == roles.count,
                      "plain, radius-only and exponent-only direct Core frames are bounded and independently distinct") else { return }

        let seed = directory.appendingPathComponent("seed.xcf")
        let imageA = try session.openImage(path: seed.path)
        images.append(imageA)
        let layers = try session.layers(imageA)
        guard let target = layers.first(where: { $0.name == "RGBA target" })?.id,
              let radius = layers.first(where: { $0.name == "Height source" })?.id,
              let exponent = layers.first(where: { $0.name == "Exponent map" })?.id else {
            return check(false, "the exact three named Oilify seed layers exist")
        }
        try session.selectItems([target], kind: .layer, image: imageA)
        let imageB = try session.newImage(width: 32, height: 32)
        images.append(imageB)
        func show(_ image: Int32, name: String, source: URL? = nil) throws -> DocumentWindowController {
            let document = try ImageDocument(session: session, image: image, name: name, openedFrom: source)
            let owner = DocumentWindowController(document: document)
            documents.items.append(document)
            owners.append(owner)
            owner.showWindow(nil)
            return owner
        }
        let a = try show(imageA, name: "Oilify A", source: seed)
        let b = try show(imageB, name: "Oilify B")
        let docA = a.imageDocument
        let originalIDs = layers.map(\.id)
        let bIDs = try session.layers(imageB).map(\.id)
        let bBefore = try projection(imageB)
        let bHistory = try session.undoInfo(imageB)
        guard require(Set([target, radius, exponent]).count == 3 && Set(originalIDs).isDisjoint(with: bIDs)
                      && docA.selectedLayerIDs == [target] && docA.activeDrawable == target,
                      "Oilify A owns three distinct exact layer IDs and a captured target separate from B"),
              require(try projection(imageA) == before, "the seed XCF opens with the exact independent original projection") else { return }

        NSApp.activate(ignoringOtherApps: true)
        func makeFront(_ owner: DocumentWindowController) -> Bool {
            owner.window?.makeMain()
            owner.window?.makeKeyAndOrderFront(nil)
            return wait({ NSApp.isActive && NSApp.mainWindow === owner.window && NSApp.keyWindow === owner.window })
        }
        guard require(makeFront(a), "Oilify A is the actual active main and key document") else { return }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        guard let menu = NSApp.mainMenu,
              let operation = operations.first(where: { $0.name == "gegl:oilify" }) else {
            return check(false, "Oilify is present in the native catalog")
        }
        NativeFilterMenus.install(operations, in: menu)
        guard let item = menuItems(menu).first(where: { ($0.representedObject as? NativeFilterCommand)?.operation.name == operation.name }),
              let menuAction = item.action else {
            return check(false, "Oilify has its installed native menu action")
        }
        guard require(operation.support == .needsAuxInput, "the real Oilify menu entry comes from the auxiliary native operation") else { return }
        item.menu?.update()
        guard require(a.validateMenuItem(item) && item.isEnabled && item.title == "Oilify…",
                      "the actual Oilify menu item is enabled and opens its owned source chooser") else {
            print("Oilify pre-chooser baseline: dependent picker, preview and history checks NOT RUN.")
            return
        }

        func chooserWindow() -> NSWindow? {
            NSApp.windows.first { $0.isVisible && $0.parent === a.window && $0.title == "Oilify Sources" }
        }
        func choose(_ popup: NSPopUpButton, _ title: String) -> Bool {
            guard let item = popup.item(withTitle: title), let action = popup.action else { return false }
            popup.select(item)
            return NSApp.sendAction(action, to: popup.target, from: popup)
        }
        let properties = try session.filterOperationProperties(operation.name)
        let integerSettings: [(String, Int64)] = [("mask-radius", 32), ("exponent", 8), ("intensities", 16)]
        func configure(_ panel: NativeFilterPanel, filter: Int32) throws -> Bool {
            let fields = views(panel.window?.contentView, NSTextField.self)
            for (name, value) in integerSettings {
                guard let property = properties.first(where: { $0.name == name && $0.kind == .integer }),
                      let field = fields.first(where: { $0.isEditable && ($0.accessibilityLabel() ?? "").hasPrefix(property.label) }),
                      let action = field.action else { return false }
                field.stringValue = field.formatter?.string(for: NSNumber(value: value)) ?? "\(value)"
                guard NSApp.sendAction(action, to: field.target, from: field) else { return false }
            }
            guard let label = properties.first(where: { $0.name == "use-inten" && $0.kind == .boolean })?.label,
                  let intensity = views(panel.window?.contentView, NSButton.self).first(where: { $0.accessibilityLabel() == label }) else {
                return false
            }
            if intensity.state != .on { intensity.performClick(nil) }
            guard wait({ docA.pendingWork == 0 }) else { return false }
            for (name, value) in integerSettings {
                guard try session.filterProperty(filter, name) == .integer(value) else { return false }
            }
            return try session.filterProperty(filter, "use-inten") == .boolean(true)
        }
        func selectionPixelsMatch(_ expected: ClipboardImage) throws -> Bool {
            let actual = try session.copyPixels(imageA, merged: false)
            return actual.origin == expected.origin && actual.width == expected.width
                && actual.height == expected.height && actual.pixels == expected.pixels
        }

        for (index, role) in roles.enumerated() {
            let (name, radiusChoice, exponentChoice) = role
            let history = try session.undoInfo(imageA)
            let stored = try session.copyPixels(imageA, merged: false)
            guard require(makeFront(a) && NSApp.sendAction(menuAction, to: nil, from: item) && wait({ chooserWindow() != nil }),
                          "\(name) uses the installed menu responder action to open A's child chooser"),
                  let chooser = chooserWindow() else { return }
            auxiliary.append(chooser)
            let popups = views(chooser.contentView, NSPopUpButton.self)
            guard let r = popups.first(where: { $0.accessibilityLabel() == "Radius map source" }),
                  let e = popups.first(where: { $0.accessibilityLabel() == "Exponent map source" }),
                  let preview = views(chooser.contentView, NSButton.self).first(where: { $0.accessibilityLabel() == "Preview Oilify" }) else {
                return check(false, "\(name) exposes the two exact accessible role controls and Preview")
            }
            guard require(r.selectedItem?.title == "None" && e.selectedItem?.title == "None" && preview.isEnabled,
                          "\(name) defaults to two None choices with Preview available"),
                  require((radiusChoice == "None" || choose(r, radiusChoice)) && (exponentChoice == "None" || choose(e, exponentChoice))
                          && r.selectedItem?.title == radiusChoice && e.selectedItem?.title == exponentChoice && preview.isEnabled,
                          "\(name) admits the exact optional radius and exponent choices independently"),
                  require(makeFront(b), "B is actual main/key before A's \(name) Preview") else { return }
            preview.performClick(nil)
            guard require(wait({ a.previewPanel != nil && docA.pendingWork == 0 && !chooser.isVisible }),
                          "\(name) completes A's counted begin and retires its chooser"),
                  let panel = a.previewPanel as? NativeFilterPanel, let window = panel.window, let filter = panel.filter else {
                return check(false, "\(name) exposes its native scalar preview form")
            }
            auxiliary.append(window)
            guard require(panel.imageDocument === docA && b.previewPanel == nil && docA.filterPreviewIsOpen,
                          "\(name) preview stays attached to A while B is front"),
                  require(try configure(panel, filter: filter), "\(name) sends exact settings from the real scalar form"),
                  require(try projection(imageA) == previews[index] && session.undoInfo(imageA) == history,
                          "\(name) preview exactly matches independent Core bytes without new Undo") else { return }

            let apply = name == "exponent"
            let finishTitle = apply ? "Apply to Pixels" : "Cancel"
            guard let finish = views(window.contentView, NSButton.self).first(where: { $0.title == finishTitle }) else {
                return check(false, "\(name) has the real \(finishTitle) action")
            }
            finish.performClick(nil)
            guard require(wait({ a.previewPanel == nil && docA.pendingWork == 0 && !window.isVisible }),
                          "\(name) \(finishTitle) retires the form and drains native work") else { return }
            let after = try session.undoInfo(imageA)
            if apply {
                check(try projection(imageA) == applied[index] && after.undoCount == history.undoCount + 1
                      && session.effects(on: target, image: imageA).isEmpty,
                      "Apply to Pixels matches the independent exponent merge with one Undo and no retained effect")
                docA.undo()
                guard require(wait({ docA.pendingWork == 0 }), "Oilify Undo drains the captured A document") else { return }
                let undone = try session.undoInfo(imageA)
                check(try projection(imageA) == before && selectionPixelsMatch(stored)
                      && undone.undoCount == history.undoCount && undone.redoCount == after.redoCount + 1,
                      "one Undo restores the exact original projection and selected target pixels")
            } else {
                check(try projection(imageA) == before && selectionPixelsMatch(stored) && after == history
                      && session.effects(on: target, image: imageA).isEmpty,
                      "\(name) Cancel restores exact pixels and leaves history and the effect stack unchanged")
            }
            check(try session.layers(imageA).map(\.id) == originalIDs && session.selectedLayers(imageA) == [target]
                  && session.layers(imageB).map(\.id) == bIDs && projection(imageB) == bBefore && session.undoInfo(imageB) == bHistory,
                  "\(name) preserves exact A layer IDs, selected target, and B layers, pixels and history")
        }
    }
}
