import AppKit
import RigiUI

/// Layer multi-selection through the real UI path: native Shift/Command
/// NSOutlineView selection in the Layers palette driving the document's
/// ordered `selectedLayerIDs` (primary first) into the engine's
/// `selectLayers`, with the engine's own `selectedLayers` read-back as
/// an independent oracle. Covers the primary-layer policy, queue
/// ordering, two-document capture, reload/Undo/Redo reconciliation,
/// hidden/collapsed rows, stale-row refusal, the intentional mask-edit
/// exit with unchanged pixels, and the "Choose one layer" gates on
/// painting, moves, transforms and destructive single-layer commands.
@MainActor
extension EngineSmokeTest {
    static func exerciseLayerMultiselectionControls(_ session: EngineSession, work: URL,
                                                     documents: DocumentList) throws {
        let imageA = try session.newImage(width: 64, height: 64)
        let documentA = try ImageDocument(session: session, image: imageA, name: "Multi A")
        documents.items.append(documentA)
        let controllerA = DocumentWindowController(document: documentA)
        controllerA.showWindow(nil)
        let imageB = try session.newImage(width: 64, height: 64)
        let documentB = try ImageDocument(session: session, image: imageB, name: "Multi B")
        documents.items.append(documentB)
        let controllerB = DocumentWindowController(document: documentB)
        controllerB.showWindow(nil)
        // B front: work queued on A must still land in A, never in the
        // front window's document.
        controllerB.window?.makeKeyAndOrderFront(nil)
        guard let bgB = documentB.activeLayer else {
            check(false, "document B has a layer")
            return
        }
        var errorsA: [String] = []
        documentA.onError = { errorsA.append($0) }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            let deadline = Date().addingTimeInterval(10)
            while (document.pendingWork > 0 || EngineActivity.shared.isBusy) && Date() < deadline { spin(0.01) }
            spin()
        }
        defer {
            controllerA.window?.orderOut(nil)
            controllerB.window?.orderOut(nil)
            documents.items.removeAll { $0 === documentA || $0 === documentB }
            for document in [documentA, documentB] where !document.isClosing {
                var closed = false
                document.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(10)
                while !closed && Date() < deadline { spin(0.01) }
            }
            check((try? session.info(imageA)) == nil && (try? session.info(imageB)) == nil,
                  "both multi-selection images drain accepted work and close before engine shutdown")
        }

        // A's tree, top first: group > [l2, l1], bg.
        guard let bg = documentA.activeLayer else {
            check(false, "document A has a background layer")
            return
        }
        documentA.layerCommand(.new)
        settle(documentA)
        guard let l1 = documentA.activeLayer, l1 != bg else {
            check(false, "a new layer was created and selected")
            return
        }
        documentA.layerCommand(.new)
        settle(documentA)
        guard let l2 = documentA.activeLayer, l2 != l1 else {
            check(false, "a second new layer was created and selected")
            return
        }
        documentA.createGroup()
        settle(documentA)
        guard let group = documentA.layers.first(where: { $0.kind == .group })?.id else {
            check(false, "a group was created")
            return
        }
        documentA.moveLayer(l1, toParent: group, atIndex: 0)
        settle(documentA)
        documentA.moveLayer(l2, toParent: group, atIndex: 0)
        settle(documentA)
        check(documentA.layers.first(where: { $0.id == l2 })?.parent == group
                && documentA.layers.first(where: { $0.id == l1 })?.parent == group,
              "the nested group holds both layers")
        documentA.selectLayer(bg)
        settle(documentA)

        // The palette, hosted like a torn-off panel, bound to A.
        let palette = LayersPaletteController()
        palette.retarget(to: documentA)
        let paletteHost = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 200),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        paletteHost.isReleasedWhenClosed = false
        paletteHost.contentView = palette.view
        paletteHost.contentView?.frame = NSRect(x: 0, y: 0, width: 220, height: 200)
        paletteHost.orderFront(nil)
        defer { paletteHost.close() }
        palette.reload()
        palette.view.layoutSubtreeIfNeeded()
        guard let outline = descendant(of: palette.view, as: NSOutlineView.self) else {
            check(false, "the Layers palette has an outline")
            return
        }
        func node(of id: Int32) -> LayerTree.Node? {
            (0..<outline.numberOfRows).compactMap { outline.item(atRow: $0) as? LayerTree.Node }
                .first { $0.id == id }
        }
        func row(of id: Int32) -> Int {
            guard let item = node(of: id) else { return -1 }
            return outline.row(forItem: item)
        }
        func selectedIDs() -> [Int32] {
            outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? LayerTree.Node)?.id }
        }
        func oracle(_ image: Int32) -> [Int32] { (try? session.selectedLayers(image)) ?? [] }
        if let groupNode = node(of: group) { outline.expandItem(groupNode) }
        palette.reload()
        check(row(of: l2) >= 0 && row(of: l1) >= 0 && row(of: bg) >= 0,
              "the outline shows the nested group's rows")

        // MARK: Native selection through the outline's delegate path

        outline.selectRowIndexes(IndexSet(integer: row(of: bg)), byExtendingSelection: false)
        settle(documentA)
        check(oracle(imageA) == [bg] && documentA.selectedLayerIDs == [bg] && documentA.activeLayer == bg,
              "a single row click selects exactly that layer; the native read-back agrees")

        outline.selectRowIndexes(IndexSet(integer: row(of: l2)), byExtendingSelection: true)
        settle(documentA)
        check(oracle(imageA) == [l2, bg] && documentA.selectedLayerIDs == [l2, bg] && documentA.activeLayer == l2,
              "a Shift-click adds the row and makes it the primary: the oracle order is [l2, bg]")
        check(Set(selectedIDs()) == [l2, bg], "the outline shows both rows selected")

        // Adding the nested l1: row order is [l2, l1, bg], but the
        // primary-first write is [l1, l2, bg] — exact ids, not tree order.
        outline.selectRowIndexes(IndexSet(integer: row(of: l1)), byExtendingSelection: true)
        settle(documentA)
        check(oracle(imageA) == [l1, l2, bg],
              "primary-first order, not accidental tree-row order: [l1, l2, bg]")

        // Command-removing the primary passes it to the topmost remaining row.
        outline.deselectRow(row(of: l1))
        settle(documentA)
        check(oracle(imageA) == [l2, bg] && documentA.selectedLayerIDs.first == l2,
              "removing the primary makes the topmost remaining row primary")

        outline.selectRowIndexes(IndexSet(integer: row(of: l1)), byExtendingSelection: false)
        settle(documentA)
        check(oracle(imageA) == [l1] && documentA.activeLayer == l1 && documentA.hasMultipleSelectedLayers == false,
              "normal single-select behavior is preserved")

        // MARK: Counted, serial, per-document queue

        let pendingBefore = documentA.pendingWork
        documentA.selectLayers([bg, l2])
        check(documentA.pendingWork == pendingBefore + 1, "a multi-selection write is counted as pending work")
        documentA.selectLayers([l2])
        controllerB.window?.makeKeyAndOrderFront(nil)
        settle(documentA)
        check(oracle(imageA) == [l2], "queued selections run serially; the last one wins")
        check(oracle(imageB) == [bgB],
              "A's queued selection never retargets to the front document B")
        // The palette is still bound to A while B is front.
        outline.selectRowIndexes(IndexSet(integer: row(of: bg)), byExtendingSelection: false)
        settle(documentA)
        check(oracle(imageA) == [bg] && oracle(imageB) == [bgB],
              "the palette bound to A lands its selection in A while B is front")

        // MARK: Hidden/collapsed rows and programmatic reload

        outline.selectRowIndexes(IndexSet(integer: row(of: l2)), byExtendingSelection: false)
        outline.selectRowIndexes(IndexSet(integer: row(of: l1)), byExtendingSelection: true)
        settle(documentA)
        check(oracle(imageA) == [l1, l2], "multi-selection over the nested rows established")
        if let groupNode = node(of: group) { outline.collapseItem(groupNode) }
        palette.reload()
        check(oracle(imageA) == [l1, l2] && documentA.selectedLayerIDs == [l1, l2],
              "a programmatic palette reload never clears the native selection")
        check(selectedIDs().isEmpty, "hidden rows are not re-selected while collapsed")
        if let groupNode = node(of: group) { outline.expandItem(groupNode) }
        palette.reload()
        check(Set(selectedIDs()) == [l1, l2], "re-expanding shows both selected rows again")

        // MARK: Native multi-selection exits mask editing, pixels unchanged

        outline.selectRowIndexes(IndexSet(integer: row(of: l2)), byExtendingSelection: false)
        settle(documentA)
        documentA.addMask(l2, source: .white, edit: true)
        settle(documentA)
        guard let maskID = documentA.maskStates[l2]?.mask, maskID != 0, documentA.isMaskTargetActive else {
            check(false, "mask editing is the target before the multi-select")
            return
        }
        check((try? session.layerMask(l2, image: imageA))?.editing == true,
              "the native mask edit flag is on before the multi-select")
        let maskBytesBefore = (try? session.drawableThumbnail(maskID, image: imageA, maxSize: 64))
            .flatMap { $0?.dataProvider?.data as Data? }
        let compositeBefore = try session.copyPixels(imageA, merged: true).pixels
        let undoBeforeMask = documentA.undoInfo.undoCount
        let dirtyBeforeMask = documentA.info.isDirty
        outline.selectRowIndexes(IndexSet(integer: row(of: l1)), byExtendingSelection: true)
        settle(documentA)
        check(oracle(imageA) == [l1, l2], "the multi-selection landed with the clicked row primary")
        check(documentA.maskStates[l2]?.editing == false && (try? session.layerMask(l2, image: imageA))?.editing == false,
              "native multi-selection exits mask editing (cached and native agree)")
        check((try? session.layerMask(l2, image: imageA))?.enabled == true, "the mask's enabled flag is unchanged")
        let maskBytesAfter = (try? session.drawableThumbnail(maskID, image: imageA, maxSize: 64))
            .flatMap { $0?.dataProvider?.data as Data? }
        check(maskBytesBefore != nil && maskBytesBefore == maskBytesAfter, "mask pixels are byte-identical")
        check(try session.copyPixels(imageA, merged: true).pixels == compositeBefore,
              "composite pixels are unchanged by the selection")
        check(documentA.undoInfo.undoCount == undoBeforeMask && documentA.info.isDirty == dirtyBeforeMask,
              "the selection is transient: no undo step, no dirty change")

        // MARK: "Choose one layer" gates under the multi-selection

        errorsA.removeAll()
        let layersBeforeGates = documentA.layers
        let undoBeforeGates = documentA.undoInfo.undoCount
        let pixelsBeforeGates = try session.copyPixels(imageA, merged: true).pixels
        let boundsL2 = documentA.layers.first(where: { $0.id == l2 })?.bounds

        documentA.beginStroke(at: .init(x: 8, y: 8, pressure: 1))
        check(!documentA.strokeIsActive && errorsA.last?.contains("Choose one layer") == true,
              "painting refuses under a multi-selection with the actionable reason")
        documentA.endStroke()
        documentA.fill(at: CGPoint(x: 8, y: 8), mode: .similarColors, color: .red, threshold: 0.2, sampleMerged: false)
        documentA.layerCommand(.delete)
        documentA.layerCommand(.duplicate)
        documentA.layerCommand(.raise)
        documentA.layerCommand(.fitToImage)
        documentA.moveActiveLayer(by: CGSize(width: 4, height: 4))
        documentA.transformActiveLayer(.flipHorizontal)
        documentA.applyMask()
        documentA.deleteMask()
        documentA.toggleMaskEnabled()
        documentA.maskToSelection(.replace)
        documentA.moveLayer(l2, toParent: 0, atIndex: 0)
        documentA.toggleLocks(l2, .pixels)
        check(documentA.runOnPaintTarget { _, _ in } == false, "the paint-target runner refuses under multi-selection")
        var copyError: Error?
        documentA.copyPixels(.layer, background: .white, consume: { _ in }, completion: { copyError = $0 })
        settle(documentA)
        check(documentA.layers == layersBeforeGates, "no gated layer command mutated the tree")
        check(documentA.undoInfo.undoCount == undoBeforeGates, "no gated command pushed an undo step")
        check(try session.copyPixels(imageA, merged: true).pixels == pixelsBeforeGates, "no gated command changed pixels")
        check(documentA.layers.first(where: { $0.id == l2 })?.bounds == boundsL2, "no move or transform happened")
        check(documentA.layers.first(where: { $0.id == l2 })?.parent == group, "the drag-drop move was refused")
        check(documentA.layerLocks[l2]?.local.isEmpty == true, "the lock toggle was refused")
        check(copyError != nil && String(describing: copyError ?? NSError()).contains("Choose one layer"),
              "copy of the active layer is gated with the reason")
        check(errorsA.filter { $0.contains("Choose one layer") }.count >= 10,
              "every gated route reports the actionable 'Choose one layer' reason (\(errorsA.count) errors)")
        var previewResult: Result<ImageDocument.FilterPreviewStart, Error>?
        documentA.beginFilterPreview(operation: "gegl:gaussian-blur", properties: []) { previewResult = $0 }
        settle(documentA)
        if case .failure(let error)? = previewResult {
            check(String(describing: error).contains("Choose one layer"), "a filter preview on the primary alone is gated")
        } else {
            check(false, "a filter preview under a multi-selection refuses")
        }

        // Cached menu and palette admission under the multi-selection.
        let menu = MainMenu.make()
        let layerMenu = menu.items.first { $0.title == "Layer" }?.submenu
        func layerItem(_ title: String) -> NSMenuItem? { layerMenu?.items.first { $0.title == title } }
        if let deleteItem = layerItem("Delete Layer") {
            check(controllerA.validateMenuItem(deleteItem) == false
                    && deleteItem.toolTip?.contains("Choose one layer") == true,
                  "Layer ▸ Delete Layer validates disabled with the reason under a multi-selection")
        } else {
            check(false, "the Layer menu lists Delete Layer")
        }
        check(layerItem("Duplicate Layer").map { controllerA.validateMenuItem($0) } == false,
              "Layer ▸ Duplicate Layer validates disabled")
        check(layerItem("Layer Properties…").map { controllerA.validateMenuItem($0) } == false,
              "Layer ▸ Properties validates disabled")
        check(layerItem("New Layer").map { controllerA.validateMenuItem($0) } == true,
              "Layer ▸ New Layer stays available (it creates and selects a fresh row)")
        let editMenu = menu.items.first { $0.title == "Edit" }?.submenu
        check(editMenu?.items.first { $0.title == "Copy Merged" }.map { controllerA.validateMenuItem($0) } == true,
              "Copy Merged reads the composite and stays available")
        check(editMenu?.items.first { $0.title == "Cut" }.map { controllerA.validateMenuItem($0) } == false,
              "Cut is gated under a multi-selection")
        if let paletteDup = palette.paletteMenu?.items.first(where: { $0.title == "Duplicate Layer" }) {
            check(palette.validateMenuItem(paletteDup) == false
                    && paletteDup.toolTip?.contains("Choose one layer") == true,
                  "the palette menu's Duplicate Layer validates disabled with the reason")
        } else {
            check(false, "the palette menu lists Duplicate Layer")
        }
        check(palette.paletteMenu?.items.first(where: { $0.title == "New Layer" })
            .map { palette.validateMenuItem($0) } == true, "the palette menu's New Layer stays available")
        if let bar = descendant(of: palette.view, as: ClassicPaletteButtonBar.self) {
            check(bar.isEnabled(item: "duplicate") == false && bar.isEnabled(item: "delete") == false,
                  "the duplicate and delete buttons are disabled under a multi-selection")
            check(bar.isEnabled(item: "new") && bar.isEnabled(item: "group"),
                  "the new layer and group buttons stay enabled")
        } else {
            check(false, "the palette has a button bar")
        }

        // Explicit per-row edits keep targeting their captured row.
        var hide = EngineSession.LayerChange()
        hide.isVisible = false
        documentA.changeLayer(l1, hide)
        settle(documentA)
        check(documentA.layers.first(where: { $0.id == l1 })?.isVisible == false,
              "per-row visibility still targets the captured row under a multi-selection")
        var rename = EngineSession.LayerChange()
        rename.name = "renamed-l1"
        documentA.changeLayer(l1, rename)
        settle(documentA)
        check(documentA.layers.first(where: { $0.id == l1 })?.name == "renamed-l1",
              "per-row rename still targets the captured row under a multi-selection")
        var show = EngineSession.LayerChange()
        show.isVisible = true
        rename.name = "l1"
        documentA.changeLayer(l1, show)
        documentA.changeLayer(l1, rename)
        settle(documentA)

        // New Layer under a multi-selection creates and selects a fresh row.
        let countBeforeNew = documentA.layers.count
        documentA.layerCommand(.new)
        settle(documentA)
        check(documentA.layers.count == countBeforeNew + 1, "New Layer runs under a multi-selection")
        check(documentA.selectedLayerIDs.count == 1 && oracle(imageA) == documentA.selectedLayerIDs
                && documentA.activeLayer == documentA.selectedLayerIDs.first,
              "the fresh row is selected alone (safe), and the oracle agrees")
        let fresh = documentA.selectedLayerIDs.first ?? 0
        documentA.layerCommand(.delete)
        settle(documentA)
        check(documentA.layers.count == countBeforeNew && !documentA.layers.contains(where: { $0.id == fresh }),
              "the fresh row deletes under the single selection it created")

        // MARK: Undo/Redo reconciliation

        outline.selectRowIndexes(IndexSet(integer: row(of: l2)), byExtendingSelection: false)
        outline.selectRowIndexes(IndexSet(integer: row(of: l1)), byExtendingSelection: true)
        settle(documentA)
        check(oracle(imageA) == [l1, l2], "multi-selection re-established for undo/redo")
        documentA.undo()
        settle(documentA)
        check(documentA.selectedLayerIDs == oracle(imageA)
                && documentA.selectedLayerIDs.allSatisfy({ id in documentA.layers.contains { $0.id == id } }),
              "after Undo the cached selection reconciles to the native read-back, stale ids gone")
        documentA.redo()
        settle(documentA)
        check(documentA.selectedLayerIDs == oracle(imageA)
                && documentA.selectedLayerIDs.allSatisfy({ id in documentA.layers.contains { $0.id == id } }),
              "after Redo the cached selection reconciles to the native read-back")

        // MARK: Floating-selection resolve-first gating is preserved

        var options = EngineSession.SelectOptions()
        options.antialias = false
        documentA.select(.rectangle(CGRect(x: 10, y: 10, width: 8, height: 8)), options: options)
        settle(documentA)
        let red = ClipboardImage(width: 8, height: 8,
                                 pixels: Data((0..<(8 * 8)).flatMap { _ in [UInt8]([255, 0, 0, 255]) }),
                                 origin: .zero)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try red.write(to: board)
        let payload = try ClipboardImage.readPayload(from: board)
        outline.selectRowIndexes(IndexSet(integer: row(of: l2)), byExtendingSelection: false)
        settle(documentA)
        documentA.pasteIntoPixels(payload, target: l2) { _ in }
        settle(documentA)
        check((try? session.floatingSelection(imageA))?.isActive == true, "a floating selection is active")
        let fsSelection = oracle(imageA)
        errorsA.removeAll()
        outline.selectRowIndexes(IndexSet(integer: row(of: l1)), byExtendingSelection: true)
        settle(documentA)
        check(oracle(imageA) == fsSelection && (try? session.floatingSelection(imageA))?.isActive == true,
              "a multi-selection attempt under a floating selection is refused; the FS is never anchored")
        check(errorsA.contains(where: { $0.contains("floating selection") }),
              "the resolve-first reason is reported for the refused pick")
        documentA.resolveFloatingSelection(.discard) { _ in }
        settle(documentA)
        check((try? session.floatingSelection(imageA))?.isActive == false, "Discard resolves the floating selection")
        outline.selectRowIndexes(IndexSet(integer: row(of: l1)), byExtendingSelection: true)
        settle(documentA)
        check(oracle(imageA) == [l1, l2], "multi-selection works again after the floating selection resolved")

        // MARK: Stale row refusal: refresh, never a cleared native selection

        let staleTarget = l1
        var deleteSucceeded = true
        do {
            _ = try session.layerCommand(.delete, image: imageA, layer: staleTarget)
        } catch {
            deleteSucceeded = false
            check(false, "the native delete of the stale layer succeeded: \(error)")
        }
        if deleteSucceeded {
            try? documentA.reload()
            check(!documentA.layers.contains(where: { $0.id == staleTarget }),
                  "the layer is gone from the document cache after the native delete")
            let oracleBeforeStale = oracle(imageA)
            check(documentA.selectedLayerIDs == oracleBeforeStale
                    && !documentA.selectedLayerIDs.contains(staleTarget),
                  "reload reconciliation drops the stale id from the cached selection")
            // The palette still shows the old snapshot's row for the
            // deleted layer; selecting it must refuse and refresh.
            let staleRow = row(of: staleTarget)
            check(staleRow >= 0, "the palette still shows the stale row before its reload")
            outline.selectRowIndexes(IndexSet([row(of: l2), staleRow].filter { $0 >= 0 }),
                                     byExtendingSelection: false)
            settle(documentA)
            check(oracle(imageA) == oracleBeforeStale && documentA.selectedLayerIDs == oracleBeforeStale,
                  "a stale row's selection refuses; the native selection is unchanged")
            documentA.undo()
            settle(documentA)
            check(documentA.layers.contains(where: { $0.id == staleTarget }), "Undo restores the deleted layer")
        }

        // MARK: Per-document palette binding

        palette.retarget(to: documentB)
        palette.reload()
        check(row(of: bgB) >= 0, "retargeting the palette to B shows B's rows")
        outline.selectRowIndexes(IndexSet(integer: row(of: bgB)), byExtendingSelection: false)
        settle(documentB)
        check(oracle(imageB) == [bgB] && documentB.selectedLayerIDs == [bgB],
              "the palette bound to B lands its selection in B")
        check(oracle(imageA) == documentA.selectedLayerIDs, "A's native selection is untouched by B's palette")
        palette.retarget(to: documentA)
        palette.reload()
    }
}
