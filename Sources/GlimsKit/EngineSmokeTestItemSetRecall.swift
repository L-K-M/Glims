import AppKit
import RigiUI

/// `GLIMS_SMOKE_CASE=item-set-recall` (wired by root, also in the full
/// suite): saved-set recall of all three kinds plus the ambiguous
/// multi-selection policies through the real document methods — exact
/// order/reorder, stale and foreign tokens quiet, the 2-channel refusal
/// pass (pixels on all targets and history unchanged), the 2-path recall
/// with an older path alive (no implicit new path, single pick restores
/// editing), the floating-selection rules, and close/drain with exactly
/// one completion. Native fixtures use slots 136/137 in test code only.
@MainActor
extension EngineSmokeTest {
    static func exerciseItemSetRecall(_ session: EngineSession, work: URL,
                                      documents: DocumentList) throws {
        let image = try session.newImage(width: 64, height: 64)
        let doc = try ImageDocument(session: session, image: image, name: "Recall")
        documents.items.append(doc)
        let controller = DocumentWindowController(document: doc)
        controller.showWindow(nil)
        var errors: [String] = []
        doc.onError = { errors.append($0) }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle() {
            doc.inputQueue.sync {}
            wait { doc.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        func thumb(_ drawable: Int32) -> Data? {
            (try? session.drawableThumbnail(drawable, image: image, maxSize: 64))?.dataProvider?.data as Data?
        }
        func makeSet(_ kind: EngineSession.ItemSetKind, _ name: String, _ members: [Int32]) -> UInt64 {
            var token: UInt64?
            doc.editSavedSet(ImageDocument.SavedSetEditRequest(
                operation: .create, kind: kind, token: 0, name: name,
                members: members, captureSelection: false)) { token = try? $0.get() }
            wait { token != nil }
            guard let token else { check(false, "set \(name) created"); return 0 }
            return token
        }
        func recall(_ token: UInt64, _ kind: EngineSession.ItemSetKind) -> Result<Void, Error> {
            var result: Result<Void, Error>?
            doc.recallItemSet(token: token, kind: kind) { result = $0 }
            wait { result != nil }
            return result ?? .failure(ImageDocument.DocumentError.busy)
        }
        func succeeded(_ result: Result<Void, Error>) -> Bool {
            if case .success = result { return true }
            return false
        }
        defer {
            controller.window?.orderOut(nil)
            documents.items.removeAll { $0 === doc }
            if !doc.isClosing {
                var closed = false
                doc.closeImageWhenDrained { closed = true }
                wait { closed }
            }
            check((try? session.info(image)) == nil, "the recall image drains and closes before engine shutdown")
        }

        // Fixtures: layers bg+l1, channels c1/c2, paths p0 (older), p1, p2.
        guard let bg = doc.activeLayer else { check(false, "background layer"); return }
        doc.layerCommand(.new)
        settle()
        guard let l1 = doc.activeLayer, l1 != bg else { check(false, "layer l1 created"); return }
        try session.select(.rectangle(CGRect(x: 2, y: 2, width: 20, height: 20)), image: image)
        let c1 = try session.channelFromSelection(image, name: "C1")
        try session.select(.none, image: image)
        try session.select(.rectangle(CGRect(x: 30, y: 30, width: 20, height: 20)), image: image)
        let c2 = try session.channelFromSelection(image, name: "C2")
        try session.select(.none, image: image)
        try session.channelCommand(.select, channel: 0, image: image)
        let shape = VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: 5, y: 5)), .init(CGPoint(x: 25, y: 25))])])
        guard let p0 = doc.addPath(shape), let p1 = doc.addPath(shape), let p2 = doc.addPath(shape) else {
            check(false, "three paths created"); return
        }
        settle()

        // Saved sets of all three kinds, with non-trivial orders.
        let layerSet = makeSet(.layer, "Layers", [l1, bg])
        let channelSet = makeSet(.channel, "Chans", [c2, c1])
        let pathSet = makeSet(.path, "Paths", [p2, p1])
        check(layerSet != 0 && channelSet != 0 && pathSet != 0, "three sets created")

        // Recall, layer kind: exact order, then reorder.
        check(succeeded(recall(layerSet, .layer)), "layer recall succeeds")
        settle()
        check((try? session.selectedItems(.layer, image: image)) == [l1, bg] && doc.selectedLayerIDs == [l1, bg],
              "layer recall selects exactly the stored order")
        let layerSetReordered = makeSet(.layer, "LayersR", [bg, l1])
        check(succeeded(recall(layerSetReordered, .layer)), "reordered layer recall succeeds")
        settle()
        check((try? session.selectedItems(.layer, image: image)) == [bg, l1],
              "recall applies the new order exactly")

        // Recall, channel kind: exact order; two selected channels are an
        // ambiguous target (no drawable, no single active channel).
        check(succeeded(recall(channelSet, .channel)), "channel recall succeeds")
        settle()
        check((try? session.selectedItems(.channel, image: image)) == [c2, c1] && doc.selectedChannelIDs == [c2, c1],
              "channel recall selects exactly the stored order")
        check(doc.activeChannel == nil && doc.activeDrawable == nil && doc.isChannelTargetActive
                && doc.hasMultipleSelectedChannels,
              "two selected channels: no single target, channel target still active")

        // Recall, path kind: exact order; no active path while two are
        // selected, the older path still alive and unselected.
        check(succeeded(recall(pathSet, .path)), "path recall succeeds")
        settle()
        check((try? session.selectedItems(.path, image: image)) == [p2, p1]
                && doc.selectedPathIDs == [p2, p1] && doc.activePath == nil && doc.hasMultipleSelectedPaths,
              "path recall selects exactly the stored order with no active path")
        check(doc.paths.contains { $0.id == p0 && !$0.isSelected }, "the older unselected path is alive")

        // Stale token: removed natively; recall refuses quietly, the
        // current selection is untouched.
        try session.editItemSet(image, .remove, kind: .layer, token: layerSetReordered)
        let beforeStale = try session.selectedItems(.layer, image: image)
        if case .success = recall(layerSetReordered, .layer) { check(false, "a stale-token recall refuses") }
        settle()
        check((try? session.selectedItems(.layer, image: image)) == beforeStale,
              "a stale-token recall changes no selection (quiet)")
        check(!errors.isEmpty, "the stale recall reports its refusal")

        // Foreign token: another document's set recalled here refuses.
        let imageB = try session.newImage(width: 16, height: 16)
        let docB = try ImageDocument(session: session, image: imageB, name: "Recall B")
        documents.items.append(docB)
        defer {
            documents.items.removeAll { $0 === docB }
            var closedB = false
            docB.closeImageWhenDrained { closedB = true }
            wait { closedB }
        }
        var foreign: Result<Void, Error>?
        docB.recallItemSet(token: channelSet, kind: .channel) { foreign = $0 }
        wait { foreign != nil }
        if case .success = foreign { check(false, "a foreign-document token refuses NOT_FOUND") }
        check((try? session.selectedItems(.channel, image: imageB))?.isEmpty == true,
              "the foreign recall changed nothing in B")

        // MARK: 2-channel recall: every ambiguous target edit refuses,
        // all targets' pixels and the history unchanged.
        check(succeeded(recall(channelSet, .channel)), "recall the 2-channel set for the refusal pass")
        settle()
        let undoBefore = doc.undoInfo.undoCount
        let mergedBefore = try session.copyPixels(image, merged: true).pixels
        let thumbsBefore = [bg, l1, c1, c2].map { thumb($0) }
        doc.beginStroke(at: .init(x: 8, y: 8, pressure: 1))
        check(!doc.strokeIsActive, "Paint refuses under a 2-channel selection")
        doc.fill(at: CGPoint(x: 8, y: 8), mode: .similarColors, color: .red, threshold: 0, sampleMerged: false)
        check(doc.runOnPaintTarget { _, _ in } == false, "Clear refuses under a 2-channel selection")
        var copyError: Error?
        doc.copyPixels(.layer, background: .white, consume: { _ in }) { copyError = $0 }
        wait { copyError != nil }
        check(copyError != nil, "Copy refuses under a 2-channel selection")
        copyError = nil
        doc.copyPixels(.cutLayer, background: .white, consume: { _ in }) { copyError = $0 }
        wait { copyError != nil }
        check(copyError != nil, "Cut refuses under a 2-channel selection")
        let filter = EngineSession.Procedure(name: "plug-in-glims-smoke-none", label: "Smoke Filter…",
                                              menuPath: "", blurb: "", isSensitive: true)
        var filterResult: Result<EngineSession.RunOutcome, Error>?
        doc.run(filter, mode: .withLastValues) { filterResult = $0 }
        wait { filterResult != nil }
        if case .success = filterResult { check(false, "a filter refuses under a 2-channel selection") }
        check(!doc.pasteIntoReadiness.allowed && doc.floatReadiness(.copy).drawable == nil,
              "Paste Into and Float refuse under a 2-channel selection")
        let boundsBefore = doc.layers.first { $0.id == bg }?.bounds
        doc.moveActiveLayer(by: CGSize(width: 4, height: 0))
        doc.transformActiveLayer(.rotate90)
        settle()
        check(doc.layers.first { $0.id == bg }?.bounds == boundsBefore,
              "Move and Transform refuse under a 2-channel selection")
        check(doc.undoInfo.undoCount == undoBefore, "the refused edits added no undo step")
        check(try session.copyPixels(image, merged: true).pixels == mergedBefore
                && [bg, l1, c1, c2].map({ thumb($0) }) == thumbsBefore,
              "the refused edits changed no pixel on any target")

        // MARK: 2-path recall with the older path alive: the Path tool
        // consumes click/Delete, the palette's single-path commands
        // disable.
        check(succeeded(recall(pathSet, .path)), "recall the 2-path set")
        settle()
        let pathCountBefore = doc.paths.count
        let shapesBefore = doc.pathShapes
        let pathUndoBefore = doc.undoInfo.undoCount
        let tool = PathTool(canvas: controller.canvas)
        tool.mouseDown(at: CGPoint(x: 10, y: 10), flags: [])
        tool.mouseUp()
        check(doc.paths.count == pathCountBefore && doc.selectedPathIDs == [p2, p1],
              "a Path-tool click under a 2-path selection creates no implicit new path")
        check(tool.keyDown(keyCode: 51) == true, "Delete is consumed under a 2-path selection")
        check(doc.paths.count == pathCountBefore && doc.pathShapes == shapesBefore
                && doc.undoInfo.undoCount == pathUndoBefore,
              "Delete under a 2-path selection edits nothing")
        let palette = PathsPaletteController()
        palette.retarget(to: doc)
        func commandEnabled(_ command: PathsPaletteController.Command) -> Bool {
            guard let item = palette.paletteMenu?.items.first(where: { $0.tag == command.rawValue }) else {
                return false
            }
            return palette.validateMenuItem(item)
        }
        check(commandEnabled(.new), "New Path stays enabled under a 2-path selection")
        for command in [PathsPaletteController.Command.delete, .toSelection, .stroke, .fill, .toVectorLayer] {
            check(!commandEnabled(command), "\(command.menuTitle) disables under a 2-path selection")
        }
        palette.run(.stroke)
        palette.run(.fill)
        palette.run(.delete)
        settle()
        check(doc.paths.count == pathCountBefore && doc.undoInfo.undoCount == pathUndoBefore,
              "the disabled palette commands run nothing")

        // One palette row pick resolves the multi-selection to that path
        // and restores editing.
        doc.selectPath(p0)
        settle()
        check(doc.selectedPathIDs == [p0] && doc.activePath == p0,
              "a single row pick resolves the 2-path selection to exactly one")
        check((try? session.selectedItems(.path, image: image)) == [p0],
              "the native read-back matches the single pick")
        for command in [PathsPaletteController.Command.delete, .toSelection, .stroke, .fill] {
            check(commandEnabled(command), "\(command.menuTitle) enables again after the single pick")
        }

        // MARK: Floating-selection rules: layer/channel recall refuses,
        // path recall keeps the drawable state.
        try session.select(.all, image: image)
        try doc.reload()
        doc.refreshSelection()
        var floated: Result<Void, Error>?
        doc.floatSelectedPixels(mode: .copy, target: bg) { floated = $0 }
        wait { floated != nil }
        settle()
        check(doc.floatingState.isActive, "the floating selection is active")
        let floatingDrawable = doc.activeDrawable
        if case .success = recall(channelSet, .channel) {
            check(false, "channel recall refuses under a floating selection")
        }
        if case .success = recall(layerSet, .layer) {
            check(false, "layer recall refuses under a floating selection")
        }
        check(succeeded(recall(pathSet, .path)), "path recall is allowed under a floating selection")
        settle()
        check(doc.selectedPathIDs == [p2, p1] && doc.activeDrawable == floatingDrawable
                && doc.floatingState.isActive,
              "path recall keeps the floating drawable state")
        var anchored: Result<Void, Error>?
        doc.resolveFloatingSelection(.anchor) { anchored = $0 }
        wait { anchored != nil }
        settle()
        check(!doc.floatingState.isActive, "the floating selection anchored")

        // MARK: Close drain: the accepted recall is counted, its
        // completion runs exactly once; a recall after close fails
        // through its callback.
        var drainCompletions = 0
        let workBeforeDrain = doc.pendingWork
        doc.recallItemSet(token: pathSet, kind: .path) { _ in drainCompletions += 1 }
        check(doc.pendingWork > workBeforeDrain, "the accepted recall is counted as pending work")
        var closed = false
        doc.closeImageWhenDrained { closed = true }
        wait { closed }
        check(drainCompletions == 1, "the recall completion ran exactly once through the close drain")
        var late: Result<Void, Error>?
        doc.recallItemSet(token: pathSet, kind: .path) { late = $0 }
        check(late != nil, "a recall requested after close fails through its callback without crashing")
    }
}
