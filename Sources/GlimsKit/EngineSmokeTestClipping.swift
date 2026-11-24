import AppKit

// MARK: - GLIMS_SMOKE_CASE=clipping-groups

private struct ClippingFixtureError: Error {}

@MainActor
extension EngineSmokeTest {
    /// GLIMS_SMOKE_CASE=clipping-groups (also in the full run): Layer >
    /// Group with Previous, Ungroup and Merge Group. A white-based fixture
    /// with an opaque left half clips a fully opaque red layer; the menu
    /// action builds the group, the role report names every row, the
    /// palette marks the clipped row and underlines the base, and the
    /// composite shows red only over the base. Option-click toggles the
    /// clip through the palette's handler, Ungroup releases the child, and
    /// Merge Group bakes the group into one layer named after the base. A
    /// recording of Group with Previous and Merge Group replays into a twin
    /// document with the same pixels and tree.
    static func exerciseClipping(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && document.recorder.pendingCount == 0
                && !document.recorder.isReplaying && !EngineActivity.shared.isBusy }
            spin(0.02)
        }
        func pixels(_ document: ImageDocument) throws -> [UInt8] {
            [UInt8](try session.copyPixels(document.image, merged: true).pixels)
        }
        func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int, _ width: Int) -> [UInt8] {
            let offset = (y * width + x) * 4
            return [bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]]
        }

        var owned: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        func fixture(_ name: String) throws -> (ImageDocument, DocumentWindowController, Int32, Int32) {
            var bytes: [UInt8] = []
            for y in 0..<2 {
                for x in 0..<8 {
                    if x < 4 { bytes += [255, 255, 255, 255] }
                    else { bytes += [0, 0, 0, 0] }
                }
            }
            let image = try session.newImage(pixels: ClipboardImage(width: 8, height: 2,
                                                                   pixels: Data(bytes), origin: .zero))
            let document = try ImageDocument(session: session, image: image, name: name)
            document.onError = { _ in }
            owned.append(document)
            documents.items.append(document)
            let controller = DocumentWindowController(document: document)
            controller.showWindow(nil)
            controllers.append(controller)
            try document.reload()
            settle(document)
            let base = try session.layers(image)[0].id
            controller.newLayer(nil)
            settle(document)
            guard let red = document.layers.first(where: { $0.id != base })?.id else {
                throw ClippingFixtureError()
            }
            document.fill(at: .zero, mode: .selection, color: .red, threshold: 0.1, sampleMerged: false)
            settle(document)
            return (document, controller, base, red)
        }
        defer {
            for controller in controllers {
                if let window = controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
                controller.window?.orderOut(nil)
                var stopped = false
                controller.canvas.stopRendering { stopped = true }
                wait { stopped }
                check(stopped, "the clipping canvas stops rendering in time")
            }
            for document in owned { document.closeImageWhenDrained() }
            wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            documents.items.removeAll { document in owned.contains { $0 === document } }
        }

        let menu = MainMenu.make()
        NSApp.mainMenu = menu
        guard let layerMenu = menu.item(withTitle: "Layer")?.submenu,
              let groupItem = layerMenu.item(withTitle: "Group with Previous"),
              let ungroupItem = layerMenu.item(withTitle: "Ungroup"),
              let mergeItem = layerMenu.item(withTitle: "Merge Group") else {
            return check(false, "Layer > Group with Previous, Ungroup and Merge Group exist")
        }
        check(groupItem.action == #selector(DocumentWindowController.groupWithPrevious(_:))
              && ungroupItem.action == #selector(DocumentWindowController.ungroup(_:))
              && mergeItem.action == #selector(DocumentWindowController.mergeGroup(_:)),
              "the clipping commands carry their actions")

        let (document, controller, base, red) = try fixture("Clipping groups")
        let undoBefore = document.undoInfo.undoCount

        // The palette rows: the group row stays visible, the clipped row
        // carries the marker and the base name is underlined.
        let palette = LayersPaletteController()
        _ = palette.view
        palette.retarget(to: document)
        palette.reload()
        guard let outline = descendant(of: palette.view, as: NSOutlineView.self) else {
            return check(false, "the clipping fixture has a Layers outline")
        }
        func rowView(_ layerID: Int32) -> LayerRowView? {
            let rowsBefore = outline.numberOfRows
            for row in 0..<rowsBefore {
                if let node = outline.item(atRow: row) as? LayerTree.Node, node.layer.kind == .group {
                    outline.expandItem(node)
                }
            }
            for row in 0..<outline.numberOfRows {
                guard let node = outline.item(atRow: row) as? LayerTree.Node, node.id == layerID else { continue }
                return outline.view(atColumn: 0, row: row, makeIfNecessary: true) as? LayerRowView
            }
            return nil
        }

        controller.groupWithPrevious(nil)
        settle(document)
        palette.reload()
        guard let group = document.layers.first(where: { $0.kind == .group })?.id else {
            return check(false, "Group with Previous builds a group")
        }
        check(document.undoInfo.undoCount == undoBefore + 1
              && document.undoInfo.nextUndo == "Group with Previous",
              "Group with Previous is one undo step named after itself (\(document.undoInfo.nextUndo))")
        check(document.layerClipping[group]?.role == .group
              && document.layerClipping[red]?.role == .clipped
              && document.layerClipping[base]?.role == .base
              && document.layerClipping[red]?.base == base
              && document.layerClipping[base]?.group == group,
              "the role report names the group, its clipped child and its base")

        let clippedRow = rowView(red)
        let baseRow = rowView(base)
        check(clippedRow?.clipMarker.isHidden == false,
              "the clipped row carries the clip marker")
        check(baseRow?.clipMarker.isHidden == true
              && baseRow?.nameField.attributedStringValue
                  .attribute(.underlineStyle, at: 0, effectiveRange: nil) != nil,
              "the base row's name is underlined")

        var bytes = try pixels(document)
        check(pixel(bytes, 0, 0, 8).elementsEqual([255, 0, 0, 255])
              && pixel(bytes, 7, 0, 8).elementsEqual([0, 0, 0, 0]),
              "the clipped red shows only over the base's opaque half")

        // Option-click on the clipped row's lower boundary releases it.
        check(clippedRow?.onLowerBoundaryOptionClick != nil,
              "the clipped row has a lower-boundary clipping handler")
        clippedRow?.onLowerBoundaryOptionClick?()
        settle(document)
        palette.reload()
        check(document.layers.contains(where: { $0.id == group }) == false
              && document.layerClipping.values.allSatisfy { $0.role == .none },
              "Option-click ungroups the released layer and clears the roles")

        // Toggling again regroups the layer through the same handler.
        guard let redAgain = rowView(red) else {
            return check(false, "the released red row is still shown")
        }
        redAgain.onLowerBoundaryOptionClick?()
        settle(document)
        check(document.layerClipping[red]?.role == .clipped,
              "Option-click regroups the layer on the second toggle")

        // Merge Group through the menu, on the active clipped layer.
        let baseName = document.layers.first(where: { $0.id == base })?.name
        document.selectLayer(red)
        settle(document)
        let mergeUndo = document.undoInfo.undoCount
        controller.mergeGroup(nil)
        settle(document)
        guard document.layers.count == 1, document.layers.first?.name == baseName else {
            return check(false, "Merge Group leaves one layer named after the base")
        }
        check(document.undoInfo.undoCount == mergeUndo + 1
              && document.undoInfo.nextUndo == "Merge Clipping Group",
              "Merge Group is one undo step named Merge Clipping Group (\(document.undoInfo.nextUndo))")
        bytes = try pixels(document)
        check(pixel(bytes, 0, 0, 8).elementsEqual([255, 0, 0, 255])
              && pixel(bytes, 7, 0, 8).elementsEqual([0, 0, 0, 0]),
              "the merged layer keeps the clipped composite")

        // Record Group with Previous and Merge Group, then replay into a
        // twin document and compare pixels and structure.
        let (record, recordController, _, recordRed) = try fixture("Clipping record")
        try record.startRecording()
        recordController.groupWithPrevious(nil)
        settle(record)
        record.selectLayer(recordRed)
        settle(record)
        recordController.mergeGroup(nil)
        settle(record)
        try record.stopRecording()
        settle(record)
        let rows = record.recorder.records
        check(rows.count == 2
              && rows.allSatisfy({ if case .success = $0.resolution { return true }; return false })
              && record.recorder.replayRefusal == nil,
              "both clipping commands record one successful row (\(rows.count) rows)")
        if case .success(.clipping(let command))? = rows.first?.resolution {
            check(command == .groupWithPrevious, "Group with Previous records its tag")
        } else { check(false, "the first row is Group with Previous") }
        if case .success(.clipping(let command))? = rows.last?.resolution {
            check(command == .mergeGroup, "Merge Group records its tag")
        } else { check(false, "the second row is Merge Group") }

        let url = work.appendingPathComponent("clipping.glims-recording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        record.saveRecording(to: url, checkpoint: try record.recorderSaveCheckpoint()) { saved = $0 }
        settle(record)
        guard let saved, (try? saved.get()) != nil else {
            return check(false, "the clipping recording saves")
        }
        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        record.prepareRecordingFile(at: url, checkpoint: try record.recorderInstallCheckpoint()) { loaded = $0 }
        settle(record)
        guard let loaded, let file = try? loaded.get().file else {
            return check(false, "the clipping recording loads")
        }
        check(file.records.count == 2, "the saved recording keeps both clipping rows")
        check(file.records.last?.produces != nil, "Merge Group records a produced layer symbol")

        let (replay, _, _, _) = try fixture("Clipping replay")
        let choices = try RecorderBatchBindings.resolve(
            file: file, candidates: replay.recorderBatchCandidates(), policy: .matchingNamesAndKinds)
        check(choices.count == 1, "only the clipped source layer needs an install choice (\(choices.count))")
        var installed: Result<Void, Error>?
        replay.installRecording(try RecorderFileSemanticBridge.prepare(file),
                                checkpoint: try replay.recorderInstallCheckpoint(),
                                choices: choices) { installed = $0 }
        settle(replay)
        guard let installed else {
            return check(false, "the clipping recording installs into the twin")
        }
        try installed.get()
        try replay.startReplay()
        settle(replay)
        check(try pixels(record) == pixels(replay),
              "the replayed clipping renders the same pixels")
        check(record.layers.map(\.name) == replay.layers.map(\.name),
              "the replayed clipping keeps the same layer names")
    }
}
