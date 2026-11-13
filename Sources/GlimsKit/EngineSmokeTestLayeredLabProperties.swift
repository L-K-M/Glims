import AppKit
import RigiUI

extension EngineSmokeTest {
    static func exerciseLayeredLabProperties(session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        guard let path = ProcessInfo.processInfo.environment["GLIMS_LAYERED_LAB_FIXTURE"],
              !path.isEmpty else {
            throw NSError(domain: "LayeredLabSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing layered Lab fixture path"])
        }
        let image = try session.openImage(path: path)
        var document: ImageDocument?
        var controller: DocumentWindowController?
        let palette = LayersPaletteController()
        let paletteWindow = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 260, height: 300),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        paletteWindow.isReleasedWhenClosed = false
        defer {
            palette.retarget(to: nil)
            paletteWindow.orderOut(nil)
            paletteWindow.close()
            if let controller, !controller.closeStarted { controller.closeDiscardingChanges() }
            if let document {
                if controller == nil && !document.isClosing { document.closeImageWhenDrained() }
                let deadline = Date().addingTimeInterval(15)
                while (try? session.info(image)) != nil && Date() < deadline {
                    EngineSmokeTestHost.pumpEvents(for: 0.02)
                }
                check((try? session.info(image)) == nil, "layered Lab document closes")
                documents.items.removeAll { $0 === document }
            } else {
                try? session.closeImage(image)
            }
        }
        let opened = try ImageDocument(session: session, image: image, name: "Layered Lab",
                                       openedFrom: URL(fileURLWithPath: path))
        document = opened
        documents.items.append(opened)
        let windowController = DocumentWindowController(document: opened, exportDirectory: work)
        controller = windowController
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        paletteWindow.contentView = palette.view
        palette.retarget(to: opened)
        paletteWindow.orderFront(nil)
        EngineSmokeTestHost.pumpEvents(for: 0.2)
        check(windowController.window?.title.contains("Limited editing") == true,
              "document window identifies limited editing")
        let selectAll = NSMenuItem(title: "Select All", action: #selector(DocumentWindowController.selectAll(_:)), keyEquivalent: "")
        check(!windowController.validateMenuItem(selectAll), "editing menu commands are disabled")
        let saveCopy = NSMenuItem(title: "Save a Copy", action: #selector(DocumentWindowController.saveDocumentCopy(_:)), keyEquivalent: "")
        check(windowController.validateMenuItem(saveCopy), "Save a Copy stays available")
        check(opened.storage.layout == .layeredLab && opened.storage.allowsLayerProperties,
              "document recognizes limited layered Lab editing")
        check(!opened.acceptsEdits && opened.acceptsLayerSelection,
              "layer selection remains available while editing is disabled")
        check(opened.acceptsLayerProperties, "layer properties are available")
        check(opened.colorInfo.mode == .lab && opened.labAxes == nil && opened.channels.isEmpty,
              "document does not expose private Lab planes as channels")
        check(opened.layers.count == 2, "document shows two logical layers")
        check(!opened.toolIsAvailable(.paintbrush) && opened.toolIsAvailable(.zoom),
              "editing tools are unavailable while zoom remains available")
        func drain(_ step: String) {
            let deadline = Date().addingTimeInterval(15)
            while opened.pendingWork > 0 && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
            check(opened.pendingWork == 0, "engine work finishes after \(step)")
        }
        func outline(in view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            return view.subviews.lazy.compactMap { outline(in: $0) }.first
        }
        if let other = opened.layers.first(where: { !opened.selectedLayerIDs.contains($0.id) }),
           let list = outline(in: palette.view),
           let row = (0..<list.numberOfRows).first(where: { index in
               guard let node = list.item(atRow: index) as? LayerTree.Node else { return false }
               return node.layer.id == other.id
           }), let item = list.item(atRow: row) {
            check(palette.outlineView(list, shouldSelectItem: item), "palette permits a logical layer pick")
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let deadline = Date().addingTimeInterval(15)
            while opened.pendingWork > 0 && Date() < deadline {
                EngineSmokeTestHost.pumpEvents(for: 0.02)
            }
            check(opened.selectedLayerIDs == [other.id] && (try? session.selectedLayers(image)) == [other.id],
                  "logical layer selection reaches the engine")
        } else {
            check(false, "fixture has a second selectable layer")
        }
        if let list = outline(in: palette.view), let first = opened.layers.first,
           let index = (0..<list.numberOfRows).first(where: { index in
               (list.item(atRow: index) as? LayerTree.Node)?.layer.id == first.id
           }), let row = list.view(atColumn: 0, row: index, makeIfNecessary: true) as? LayerRowView {
            check(row.checkbox.isEnabled, "logical layer visibility control is enabled")
            let initiallyVisible = first.isVisible
            row.checkbox.performClick(nil)
            drain("visibility edit")
            check(opened.layers.first(where: { $0.id == first.id })?.isVisible == !initiallyVisible,
                  "visibility control changes the captured logical layer")
            let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "")
            check(windowController.window?.validateMenuItem(undo) == true, "window Undo is available after the layer edit")
            check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                  "window responder handles Undo")
            drain("visibility Undo")
            check(opened.layers.first(where: { $0.id == first.id })?.isVisible == initiallyVisible,
                  "Undo restores logical visibility")
            let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "")
            check(windowController.window?.validateMenuItem(redo) == true, "window Redo is available after Undo")
            check(windowController.window?.tryToPerform(Selector(("redo:")), with: redo) == true,
                  "window responder handles Redo")
            drain("visibility Redo")
            check(opened.layers.first(where: { $0.id == first.id })?.isVisible == !initiallyVisible,
                  "Redo reapplies logical visibility")
            check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                  "window responder handles a second Undo")
            drain("second visibility Undo")
            check(opened.layers.first(where: { $0.id == first.id })?.isVisible == initiallyVisible,
                  "second Undo restores logical visibility")
        } else {
            check(false, "logical layer visibility control exists")
        }
        if let list = outline(in: palette.view), let first = opened.layers.first,
           let index = (0..<list.numberOfRows).first(where: { index in
               (list.item(atRow: index) as? LayerTree.Node)?.layer.id == first.id
           }), let row = list.view(atColumn: 0, row: index, makeIfNecessary: true) as? LayerRowView {
            if opened.storage.allowsLayerRename {
                check(row.nameField.isEditable, "logical layer name is editable when advertised")
                let originalName = first.name
                row.nameField.stringValue = "Retouched Lab"
                row.finishNameEditing()
                drain("layer rename")
                check(opened.layers.first(where: { $0.id == first.id })?.name == "Retouched Lab",
                      "palette rename reaches the logical layer")
                let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "")
                let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "")
                check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                      "window handles rename Undo")
                drain("rename Undo")
                check(opened.layers.first(where: { $0.id == first.id })?.name == originalName,
                      "Undo restores logical layer name")
                check(windowController.window?.tryToPerform(Selector(("redo:")), with: redo) == true,
                      "window handles rename Redo")
                drain("rename Redo")
                check(opened.layers.first(where: { $0.id == first.id })?.name == "Retouched Lab",
                      "Redo restores logical layer name")
                check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                      "window restores original layer name")
                drain("restore layer name")
                check(opened.layers.first(where: { $0.id == first.id })?.name == originalName,
                      "final Undo restores the original layer name")
            } else {
                check(!row.nameField.isEditable, "logical layer name stays disabled on older engines")
                var rejected = false
                opened.changeLayer(first.id, .init(name: "Must not change")) { result in
                    if case .failure = result { rejected = true }
                }
                drain("legacy rename refusal")
                check(rejected && opened.layers.first(where: { $0.id == first.id })?.name == first.name,
                      "older engine refuses rename without changing the layer")
            }
        } else {
            check(false, "logical layer name control exists")
        }
        // This standalone palette is not registered with PaletteCenter, so
        // mirror the normal retarget/reload after the selection and undo.
        palette.reload()
        EngineSmokeTestHost.pumpEvents(for: 0.05)
        func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, as: type) }
        }
        let duplicateMenu = NSMenuItem(title: "Duplicate Layer", action: #selector(DocumentWindowController.duplicateLayer(_:)), keyEquivalent: "")
        let duplicateButton = descendants(palette.view, as: NSButton.self).first { $0.accessibilityLabel() == "Duplicate Layers" }
        if opened.storage.allowsLayerDuplicate {
            check(windowController.validateMenuItem(duplicateMenu), "Layer menu enables logical duplication")
            check(duplicateButton?.isEnabled == true, "palette enables logical duplication")
            let originalIDs = opened.layers.map(\.id)
            duplicateButton?.performClick(nil)
            drain("logical layer duplicate")
            check(opened.layers.count == 3 && Set(originalIDs).isSubset(of: Set(opened.layers.map(\.id))),
                  "palette duplicates one logical layer")
            let undo = EngineUndoManager(document: opened)
            check(undo.canUndo, "logical duplication offers Undo")
            undo.undo()
            drain("logical duplication Undo")
            check(opened.layers.map(\.id) == originalIDs, "Undo restores the original logical layers")
            check(undo.canRedo, "logical duplication offers Redo")
            undo.redo()
            drain("logical duplication Redo")
            check(opened.layers.count == 3, "Redo restores the logical copy")
            undo.undo()
            drain("restore original layers")
            check(opened.layers.map(\.id) == originalIDs, "final Undo restores the original layer tree")
        } else {
            check(!windowController.validateMenuItem(duplicateMenu) && duplicateButton?.isEnabled == false,
                  "older engines keep logical duplication disabled")
        }
        palette.reload()
        let newMenu = NSMenuItem(title: "New Layer", action: #selector(DocumentWindowController.newLayer(_:)), keyEquivalent: "")
        let newButton = descendants(palette.view, as: NSButton.self).first { $0.accessibilityLabel() == "New Layer" }
        if opened.storage.allowsLayerCreate {
            check(windowController.validateMenuItem(newMenu), "Layer menu enables logical layer creation")
            check(newButton?.isEnabled == true, "palette enables logical layer creation")
            let originalIDs = opened.layers.map(\.id)
            newButton?.performClick(nil)
            drain("new logical layer")
            check(opened.layers.count == 3 && Set(originalIDs).isSubset(of: Set(opened.layers.map(\.id))),
                  "palette creates one logical layer")
            let undo = EngineUndoManager(document: opened)
            check(undo.canUndo, "logical layer creation offers Undo")
            undo.undo()
            drain("new layer Undo")
            check(opened.layers.map(\.id) == originalIDs, "Undo restores the original layer tree")
            check(undo.canRedo, "logical layer creation offers Redo")
            undo.redo()
            drain("new layer Redo")
            check(opened.layers.count == 3, "Redo restores the new logical layer")
            undo.undo()
            drain("restore original layers after creation")
            check(opened.layers.map(\.id) == originalIDs, "final Undo removes the new logical layer")
        } else {
            check(!windowController.validateMenuItem(newMenu) && newButton?.isEnabled == false,
                  "older engines keep logical layer creation disabled")
        }
        palette.reload()
        var editedOpacity = -1.0 // No valid layer opacity can satisfy the saved-copy check until an edit runs.
        if let target = opened.activeLayer,
           let opacity = descendants(palette.view, as: ClassicValueSlider.self).first(where: { $0.accessibilityTitle == "Layer opacity" }),
           let field = descendants(opacity, as: NSTextField.self).first(where: { $0.isEditable }),
           let originalOpacity = opened.layers.first(where: { $0.id == target })?.opacity {
            check(opacity.isEnabled, "logical layer opacity control is enabled")
            editedOpacity = abs(originalOpacity - 0.5) < 0.0001 ? 0.75 : 0.5
            field.stringValue = editedOpacity == 0.5 ? "50" : "75"
            check(field.sendAction(field.action, to: field.target), "opacity field action is delivered")
            drain("opacity edit")
            check(abs((opened.layers.first(where: { $0.id == target })?.opacity ?? -1) - editedOpacity) < 0.0001,
                  "opacity field changes the captured logical layer")
            let manager = EngineUndoManager(document: opened)
            check(manager.canUndo, "Undo is available after the opacity edit")
            manager.undo()
            drain("opacity Undo")
            check(abs((opened.layers.first(where: { $0.id == target })?.opacity ?? -1) - originalOpacity) < 0.0001,
                  "Undo restores logical layer opacity")
            check(manager.canRedo, "Redo is available after opacity Undo")
            manager.redo()
            drain("opacity Redo")
            check(abs((opened.layers.first(where: { $0.id == target })?.opacity ?? -1) - editedOpacity) < 0.0001,
                  "Redo reapplies logical layer opacity")
        } else {
            check(false, "logical layer opacity field exists")
        }
        let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 1, height: 1))
        check(rendered.width == 1 && rendered.height == 1, "layered Lab canvas renders")
        let copy = work.appendingPathComponent("layered-copy.xcf")
        var copyFinished = false
        var copyError: Error?
        opened.saveCopy(to: copy) { error in copyError = error; copyFinished = true }
        let saveDeadline = Date().addingTimeInterval(30)
        while !copyFinished && Date() < saveDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
        guard copyFinished, copyError == nil else {
            throw copyError ?? NSError(domain: "LayeredLabSmoke", code: 2,
                                       userInfo: [NSLocalizedDescriptionKey: "Save copy did not finish"])
        }
        check(true, "document saves an XCF copy")
        let reopened = try session.openImage(path: copy.path)
        defer { try? session.closeImage(reopened) }
        check(try session.imageStorage(reopened).layout == .layeredLab,
              "saved XCF copy reopens as layered Lab")
        check(try session.layers(reopened).contains(where: { abs($0.opacity - editedOpacity) < 0.0001 }),
              "saved XCF copy retains the edited opacity")
    }
}
