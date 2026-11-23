import AppKit

// MARK: - GLIMS_SMOKE_CASE=recorder-gaps

@MainActor
extension EngineSmokeTest {
    /// GLIMS_SMOKE_CASE=recorder-gaps (also in the full run): every editing
    /// command the Recorder cannot replay reserves one explicit failed row
    /// while recording, in acceptance order, so a recording can never look
    /// complete while omitting an edit. The table drives real document
    /// commands through one recording, checks one ordered failed row each,
    /// and shows that replay is refused. A refused command, a read-only
    /// command, an unrecorded command and a replayed command add none, and a
    /// whole Move-tool drag adds one row rather than one per event.
    static func exerciseRecorderGaps(_ session: EngineSession, work: URL,
                                     documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
            if !condition() { check(false, "a fixture wait timed out after 15 seconds") }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && document.recorder.pendingCount == 0
                && !EngineActivity.shared.isBusy }
            spin(0.02)
        }
        func mouse(_ type: NSEvent.EventType, _ location: CGPoint, _ window: NSWindow,
                   flags: NSEvent.ModifierFlags = []) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags, timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                               clickCount: 1, pressure: 1)
        }

        let image = try session.newImage(width: 96, height: 96)
        let document = try ImageDocument(session: session, image: image, name: "Recorder gaps")
        documents.items.append(document)
        try document.reload()
        settle(document)
        guard let layer = document.activeLayer else {
            return check(false, "the recorder-gap fixture has an active layer")
        }
        try session.select(.rectangle(CGRect(x: 8, y: 8, width: 40, height: 40)),
                           image: image, options: .init())
        document.refreshSelection()
        settle(document)

        // A saved set and a clipboard payload the table edits and pastes.
        var setToken: UInt64?
        document.editSavedSet(ImageDocument.SavedSetEditRequest(
            operation: .create, kind: .layer, token: 0, name: "Gap Set",
            members: [layer], captureSelection: false)) { setToken = try? $0.get() }
        wait { setToken != nil }
        settle(document)
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        try ClipboardImage(width: 8, height: 8,
                           pixels: Data(repeating: 255, count: 8 * 8 * 4),
                           origin: .zero).write(to: board)
        let payload = try ClipboardImage.readPayload(from: board)
        let importURL = work.appendingPathComponent("recorder-gaps-import.png")
        try session.export(image, to: importURL.path)

        // Not recording: the same command adds no row and costs no reservation.
        document.addGuide(.horizontal, at: 30)
        settle(document)
        check(document.recorder.records.isEmpty && document.recorder.pendingCount == 0,
              "an unrecorded Add Guide reserves no row")

        // The table: one named formerly silent command per line. `expected`
        // keeps the acceptance order the rows must match.
        var expected: [String] = []
        func perform(_ action: String, _ command: () -> Void) {
            command()
            settle(document)
            expected.append(action)
        }
        var verticalGuide: EngineSession.Guide?
        var channel: Int32?
        var pathID: Int32?
        var adjustment: (layer: Int32, effect: Int32)?
        var textLayer: Int32?
        let path = VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: 20, y: 20)),
                                                        .init(CGPoint(x: 60, y: 20)),
                                                        .init(CGPoint(x: 60, y: 60))],
                                               isClosed: true)])
        let movedPath = VectorPath(subpaths: [.init(anchors: [.init(CGPoint(x: 24, y: 24)),
                                                             .init(CGPoint(x: 70, y: 24)),
                                                             .init(CGPoint(x: 70, y: 70))],
                                                    isClosed: true)])

        try document.startRecording()
        // A command the busy engine refuses changes nothing, so it must not
        // leave the row that makes a recording refuse replay.
        let hold = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Holding the engine",
                                                 work: { _ = hold.wait(timeout: .now() + 20) },
                                                 completion: {})
        document.convertMode(to: .grayscale) { _ in }
        document.openLayers(from: importURL) { _ in }
        _ = document.runOnPaintTarget("Fill") { _, _ in }
        hold.signal()
        settle(document)
        check(held, "the fixture holds the engine")
        check(document.recorder.records.isEmpty, "commands the busy engine refuses add no row")
        let beforeUnchangedMove = document.recorder.records.count
        if let guide = document.guides.first {
            document.moveGuide(guide, to: guide.position)
            settle(document)
            check(document.recorder.records.count == beforeUnchangedMove,
                  "moving a guide to where it is adds no row")
        } else {
            check(false, "the fixture has a guide")
        }
        let beforeUnchangedGrid = document.recorder.records.count
        document.setGrid(document.grid) { _ in }
        settle(document)
        check(document.recorder.records.count == beforeUnchangedGrid,
              "applying the grid the image already has adds no row")
        perform("Add Guide") { document.addGuide(.vertical, at: 20) }
        verticalGuide = document.guides.first { $0.orientation == .vertical }
        perform("Move Guide") {
            guard let guide = verticalGuide else { return check(false, "the vertical guide exists") }
            document.moveGuide(guide, to: 40)
        }
        // A caller's copy can be older than the engine: this moves 40 back to 20.
        let beforeStaleMove = document.recorder.records.count
        perform("Move Guide") {
            guard let guide = verticalGuide else { return check(false, "the vertical guide exists") }
            document.moveGuide(guide, to: guide.position)
        }
        check(document.recorder.records.count == beforeStaleMove + 1,
              "a real move from a stale copy of a guide adds a row")
        perform("Remove Guide") {
            guard let guide = verticalGuide else { return check(false, "the vertical guide exists") }
            document.removeGuide(guide.id)
        }
        perform("Grid") {
            document.setGrid(EngineSession.Grid(style: .solid, spacingX: 7, spacingY: 7)) { _ in }
        }
        // So can the cached grid: the engine changes before the cache reloads.
        let cachedGrid = document.grid
        try session.setGrid(EngineSession.Grid(style: .solid, spacingX: 9, spacingY: 9), image: image)
        let beforeStaleGrid = document.recorder.records.count
        perform("Grid") { document.setGrid(cachedGrid) { _ in } }
        check(document.recorder.records.count == beforeStaleGrid + 1,
              "a real grid change over a stale cache adds a row")
        perform("Stroke Selection") { document.strokeSelection(EngineSession.Brush()) }
        perform("Fill") {
            document.fill(at: CGPoint(x: 60, y: 60), mode: .selection, color: .red,
                          threshold: 0, sampleMerged: false)
        }
        perform("Gradient") {
            document.gradient(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 50, y: 50),
                              shape: .linear, fromColor: .red, toColor: .blue)
        }
        perform("Select Similar") { document.selectSimilar(options: .init()) { _ in } }
        perform("Save Selection to Channel") { document.saveSelectionToChannel(name: "Gap") { _ in } }
        channel = document.channels.first { $0.name == "Gap" }?.id
        perform("Channel Properties") {
            guard let id = channel else { return check(false, "the saved channel exists") }
            document.changeChannel(id, EngineSession.ChannelChange(name: "Gap Renamed")) { _ in }
        }
        perform("Quick Mask") { document.setQuickMask(true) }
        perform("Quick Mask") { document.setQuickMask(false) }
        // Saving a selection leaves the new channel targeted. The path and
        // layer commands below need the layer, and a target pick adds no row.
        document.selectLayer(layer)
        settle(document)
        check(document.activeLayer == layer && document.selectedLayerIDs == [layer],
              "the fixture targets its layer again")
        perform("Add Path") {
            document.addPath(path) { result in pathID = try? result.get() }
        }
        perform("Update Path") {
            guard let id = pathID else { return check(false, "the path was added") }
            document.updatePath(id, to: movedPath)
        }
        perform("Rename Path") {
            guard let id = pathID else { return check(false, "the path was added") }
            document.renamePath(id, to: "Gap Path")
        }
        perform("Path Visibility") {
            guard let id = pathID else { return check(false, "the path was added") }
            document.setPathVisible(id, false)
        }
        perform("Select From Path") {
            guard let id = pathID else { return check(false, "the path was added") }
            document.selectFromPath(id)
        }
        perform("Stroke Path") {
            guard let id = pathID else { return check(false, "the path was added") }
            document.strokePath(id, settings: EngineSession.LineSettings(width: 2, color: .black))
        }
        perform("Fill Path") {
            guard let id = pathID else { return check(false, "the path was added") }
            document.fillPath(id, settings: EngineSession.PathFillSettings(color: .blue))
        }
        perform("Add Layer Mask") { document.addMask(layer, source: .white, edit: false) }
        perform("Enable Layer Mask") { document.toggleMaskEnabled() }
        perform("Mask to Selection") { document.maskToSelection(.replace) }
        perform("Apply Layer Mask") { document.applyMask() }
        perform("Duplicate Layers") { document.duplicateSelectedLayers { _ in } }
        perform("Layer to Image Size") { document.fitSelectedLayers { _ in } }
        perform("New Layer Group") { document.createGroup() }
        perform("New Adjustment Layer") {
            document.createAdjustmentLayer(name: "Gap", operation: "gegl:brightness-contrast") { result in
                adjustment = try? result.get()
            }
        }
        perform("Effect Properties") {
            guard let target = adjustment else { return check(false, "the adjustment layer exists") }
            document.changeEffect(target.effect, on: target.layer, EngineSession.EffectChange(opacity: 0.5))
        }
        perform("Effect Stack") {
            guard let target = adjustment else { return check(false, "the adjustment layer exists") }
            document.effectCommand(.raise, effect: target.effect, on: target.layer)
        }
        perform("Merge Visible") { document.mergeVisible() }
        perform("Move Layer") { document.moveActiveLayer(by: CGSize(width: 3, height: 0)) }
        perform("Transform Layer") { document.transformActiveLayer(.flipHorizontal) }
        perform("Text") { document.addText("Gap", settings: .init(), at: CGPoint(x: 10, y: 10)) }
        textLayer = document.activeLayer
        perform("Text") {
            guard let id = textLayer else { return check(false, "the text layer exists") }
            document.updateText(id, text: "Gap Two", settings: nil)
        }
        perform("Undo") { document.undo() }
        perform("Redo") { document.redo() }
        perform("Metadata") {
            document.editMetadata("Exif.Image.Artist", .set, values: ["Gap"]) { _ in }
        }
        perform("Saved Set Editing") {
            guard let token = setToken else { return check(false, "the saved set exists") }
            document.editSavedSet(ImageDocument.SavedSetEditRequest(
                operation: .rename, kind: .layer, token: token, name: "Renamed",
                members: [], captureSelection: false)) { _ in }
        }
        perform("Saved Set Recall") {
            guard let token = setToken else { return check(false, "the saved set exists") }
            document.recallItemSet(token: token, kind: .layer) { _ in }
        }
        perform("Paste") { document.pastePixels(payload, origin: { _ in .zero }) { _ in } }
        perform("Cut") {
            document.copyPixels(.cutLayer, background: .white, consume: { _ in }) { _ in }
        }
        perform("Layer Locks") {
            guard let id = document.activeLayer else { return check(false, "an active layer exists") }
            document.setLayerLocks(id, .pixels, to: true)
        }
        perform("Bring Forward") { document.layerCommand(.raise) }
        perform("Color Mode") { document.convertMode(to: .grayscale) { _ in } }
        perform("Precision") {
            document.convertPrecision(component: .u16, trc: .nonlinear) { _ in }
        }
        perform("Assign Color Profile") { document.assignProfile(path: nil) { _ in } }
        perform("Convert Color Profile") {
            document.convertProfile(path: nil, intent: .perceptual,
                                   blackPointCompensation: false) { _ in }
        }
        perform("Indexed Mode") { document.convertToIndexed(settings: .init()) { _ in } }
        perform("Open as Layers") { document.openLayers(from: importURL) { _ in } }
        perform("Place") { document.placeLink(from: importURL) { _ in } }
        perform("Delete Path") {
            guard let id = pathID else { return check(false, "the path was added") }
            document.deletePath(id)
        }

        // A refused command adds no row: an unknown layer id fails admission
        // before the recorder is asked.
        let refusedBefore = document.recorder.records.count
        document.rasterizeLayerSources([9999]) { _ in }
        settle(document)
        check(document.recorder.records.count == refusedBefore,
              "a command refused before admission adds no row")

        // A read-only command adds no row.
        var readDone = false
        document.readMetadataTags(.exif) { _ in readDone = true }
        settle(document)
        check(readDone && document.recorder.records.count == refusedBefore,
              "a read-only command adds no row")

        try document.stopRecording()
        settle(document)
        let rows = document.recorder.records
        check(rows.count == expected.count,
              "every formerly silent command reserves exactly one row "
              + "(\(rows.count) rows for \(expected.count) commands)")
        for (index, record) in rows.enumerated() where index < expected.count {
            guard case .failure(let reason) = record.resolution else {
                check(false, "row \(index + 1) is a failure row, not a silent gap")
                continue
            }
            check(reason == "Recorder does not yet save \(expected[index]).",
                  "row \(index + 1) names its command in order (expected "
                  + "\"\(expected[index])\", got \"\(reason)\")")
        }
        check(document.recorder.replayRefusal == .unsuccessfulRecording,
              "a recording with unsupported rows refuses replay")
        do {
            try document.startReplay()
            check(false, "replay of an incomplete recording is refused")
        } catch {
            check(true, "replay of an incomplete recording is refused")
        }
        document.onError = nil
        document.closeImageWhenDrained()
        wait { (try? session.info(image)) == nil }
        documents.items.removeAll { $0 === document }

        // A whole Move-tool drag is one command: several mouseDragged events
        // commit exactly one row on the release.
        let moveImage = try session.newImage(width: 64, height: 64)
        let moveDocument = try ImageDocument(session: session, image: moveImage, name: "Recorder gaps move")
        documents.items.append(moveDocument)
        try moveDocument.reload()
        settle(moveDocument)
        let movedLayer = try session.pastePixels(moveImage,
                                                 pixels: ClipboardImage(width: 8, height: 8,
                                                                         pixels: Data(repeating: 200, count: 8 * 8 * 4),
                                                                         origin: .zero),
                                                 at: CGPoint(x: 8, y: 8))
        try moveDocument.reload()
        moveDocument.selectLayer(movedLayer)
        settle(moveDocument)
        let moveController = DocumentWindowController(document: moveDocument)
        moveController.showWindow(nil)
        moveController.window?.contentView?.layoutSubtreeIfNeeded()
        guard let moveWindow = moveController.window else {
            return check(false, "the move-drag window exists")
        }
        let moveCanvas = moveController.canvas
        let previousTool = ToolState.shared.current
        defer {
            ToolState.shared.select(previousTool)
            moveController.window?.orderOut(nil)
            moveDocument.onError = nil
            moveDocument.closeImageWhenDrained()
            wait { (try? session.info(moveImage)) == nil }
            documents.items.removeAll { $0 === moveDocument }
        }
        func windowPoint(ofImagePoint p: CGPoint) -> CGPoint {
            moveCanvas.convert(CGPoint(x: p.x * moveCanvas.scale, y: p.y * moveCanvas.scale), to: nil)
        }
        try moveDocument.startRecording()
        ToolState.shared.select(.move)
        let press = CGPoint(x: 12, y: 12)
        guard let down = mouse(.leftMouseDown, windowPoint(ofImagePoint: press), moveWindow) else {
            return check(false, "the move press event builds")
        }
        moveCanvas.mouseDown(with: down)
        for dragged in [CGPoint(x: 16, y: 12), CGPoint(x: 20, y: 12), CGPoint(x: 24, y: 12)] {
            guard let event = mouse(.leftMouseDragged, windowPoint(ofImagePoint: dragged), moveWindow) else {
                return check(false, "the move drag event builds")
            }
            moveCanvas.mouseDragged(with: event)
        }
        guard let up = mouse(.leftMouseUp, windowPoint(ofImagePoint: CGPoint(x: 24, y: 12)), moveWindow) else {
            return check(false, "the move release event builds")
        }
        moveCanvas.mouseUp(with: up)
        settle(moveDocument)
        let moveRows = moveDocument.recorder.records
        check(moveRows.count == 1
              && moveRows.first.map { if case .failure(let reason) = $0.resolution {
                  return reason == "Recorder does not yet save Move Layer."
              } else { return false } } == true,
              "a whole Move drag reserves one row, not one per event (\(moveRows.count) rows)")
        try moveDocument.stopRecording()
        settle(moveDocument)

        // Replay itself adds no row: a recording of one replayable command
        // keeps exactly that row after a successful replay.
        let replayImage = try session.newImage(width: 32, height: 32)
        let replayDocument = try ImageDocument(session: session, image: replayImage, name: "Recorder gaps replay")
        documents.items.append(replayDocument)
        try replayDocument.reload()
        settle(replayDocument)
        replayDocument.onError = nil
        defer {
            replayDocument.closeImageWhenDrained()
            wait { (try? session.info(replayImage)) == nil }
            documents.items.removeAll { $0 === replayDocument }
        }
        try replayDocument.startRecording()
        replayDocument.select(.all)
        settle(replayDocument)
        try replayDocument.stopRecording()
        settle(replayDocument)
        check(replayDocument.recorder.records.count == 1
              && replayDocument.recorder.replayRefusal == nil,
              "one replayable command settles one row")
        try replayDocument.startReplay()
        wait { !replayDocument.recorder.isReplaying }
        spin(0.05)
        check(replayDocument.recorder.records.count == 1
              && replayDocument.replayStatus == .finished(total: 1),
              "replay does not recursively record itself")
    }
}

// MARK: - Plug-ins that change the image without saying so

@MainActor
extension EngineSmokeTest {
    /// Two plug-in commands: one leaves the image's undo disabled, which
    /// GIMP does not clean up, and one changes the image and then waits
    /// with a progress bar until it is cancelled. Only the focused case
    /// installs them, so the full run's plug-in menus stay the engine's.
    private static let recorderGapPlugIn = """
        #!/usr/bin/env python3
        import gi
        gi.require_version('Gimp', '3.0')
        from gi.repository import Gimp
        from gi.repository import GLib
        import sys, time

        def run(procedure, run_mode, image, drawables, config, data):
            if procedure.get_name() == 'plug-in-glims-freeze-undo':
                image.undo_disable()
            else:
                image.add_hguide(12)
                Gimp.progress_init('Waiting for Cancel')
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    Gimp.progress_pulse()
                    time.sleep(0.05)
            return procedure.new_return_values(Gimp.PDBStatusType.SUCCESS, GLib.Error())

        class GlimsRecorderGaps(Gimp.PlugIn):
            def do_query_procedures(self):
                return ['plug-in-glims-freeze-undo', 'plug-in-glims-change-then-wait']

            def do_create_procedure(self, name):
                procedure = Gimp.ImageProcedure.new(self, name, Gimp.PDBProcType.PLUGIN, run, None)
                procedure.set_image_types('*')
                procedure.set_menu_label('Glims Freeze Undo' if name.endswith('undo')
                                         else 'Glims Change Then Wait')
                procedure.set_documentation('Recorder test fixture', 'Recorder test fixture', name)
                procedure.add_menu_path('<Image>/Filters/Glims Tests')
                return procedure

        Gimp.main(GlimsRecorderGaps.__gtype__, sys.argv)
        """

    static func installRecorderGapPlugIn(work: URL) -> Bool {
        let directory = work.appendingPathComponent("user/plug-ins/glims-recorder-gaps")
        let file = directory.appendingPathComponent("glims-recorder-gaps.py")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(recorderGapPlugIn.utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
            return true
        } catch {
            check(false, "the Recorder fixture plug-in installs (\(error))")
            return false
        }
    }

    /// A missing undo step and a cancelled status prove nothing: GIMP
    /// changes an image whose undo is frozen without an undo step, and
    /// Cancel kills a plug-in without rolling back what it changed.
    static func exerciseRecorderGapPlugIns(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.02) }
            if !condition() { check(false, "a plug-in fixture wait timed out after 20 seconds") }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && document.recorder.pendingCount == 0
                && !EngineActivity.shared.isBusy }
            spin(0.02)
        }
        func failedRows(_ document: ImageDocument) -> [String] {
            document.recorder.records.map {
                if case .failure(let reason) = $0.resolution { return reason }
                return "not a failed row"
            }
        }
        func open(_ name: String) throws -> ImageDocument {
            let document = try ImageDocument(session: session, image: session.newImage(width: 48, height: 48),
                                             name: name)
            documents.items.append(document)
            try document.reload()
            settle(document)
            return document
        }
        func close(_ document: ImageDocument) {
            document.onError = nil
            document.closeImageWhenDrained()
            wait { (try? session.info(document.image)) == nil }
            documents.items.removeAll { $0 === document }
        }

        let frozen = try open("Recorder frozen undo")
        defer { close(frozen) }
        let procedures = try session.procedures(image: frozen.image)
        guard let freeze = procedures.first(where: { $0.name == "plug-in-glims-freeze-undo" }),
              let changeThenWait = procedures.first(where: { $0.name == "plug-in-glims-change-then-wait" }) else {
            return check(false, "the engine lists the Recorder fixture plug-ins")
        }
        frozen.addGuide(.horizontal, at: 10)
        settle(frozen)
        var froze = false
        var freezeEnded = false
        frozen.run(freeze, mode: .withLastValues) {
            if case .success(.completed) = $0 { froze = true }
            freezeEnded = true
        }
        wait { freezeEnded }
        settle(frozen)
        check(froze, "the fixture plug-in leaves undo frozen")
        guard let guide = try session.guides(frozen.image).first else {
            return check(false, "the frozen image has a guide")
        }
        let revision = try session.historyRevision(frozen.image)
        try frozen.startRecording()
        frozen.moveGuide(guide, to: guide.position)
        settle(frozen)
        check(frozen.recorder.records.isEmpty, "with undo frozen, an unchanged guide still adds no row")
        frozen.moveGuide(guide, to: 30)
        settle(frozen)
        check(try session.guides(frozen.image).first?.position == 30, "the guide moves while undo is frozen")
        check(failedRows(frozen) == ["Recorder does not yet save Move Guide."],
              "a guide moved while undo is frozen keeps its row")
        let grid = EngineSession.Grid(style: .solid, spacingX: 5, spacingY: 5)
        frozen.setGrid(grid) { _ in }
        settle(frozen)
        check(try session.grid(frozen.image).spacingX == 5, "the grid changes while undo is frozen")
        check(failedRows(frozen) == ["Recorder does not yet save Move Guide.", "Recorder does not yet save Grid."],
              "a grid changed while undo is frozen keeps its row")
        check(try session.historyRevision(frozen.image) != revision,
              "the changes move the history revision while undo is frozen")
        try frozen.stopRecording()

        let cancelled = try open("Recorder cancelled plug-in")
        defer { close(cancelled) }
        try cancelled.startRecording()
        var wasCancelled = false
        var cancelEnded = false
        cancelled.run(changeThenWait, mode: .withLastValues) {
            if case .success(.cancelled) = $0 { wasCancelled = true }
            cancelEnded = true
        }
        wait {
            if !cancelEnded, let guides = try? session.guides(cancelled.image), !guides.isEmpty {
                _ = session.cancelProcedure()
            }
            return cancelEnded
        }
        settle(cancelled)
        check(wasCancelled, "Cancel stops the fixture plug-in")
        check(try session.guides(cancelled.image).count == 1, "the cancelled plug-in's change remains")
        check(failedRows(cancelled) == ["Recorder does not yet save Glims Change Then Wait."],
              "a cancelled plug-in that changed the image keeps its row")
        try cancelled.stopRecording()
        check(cancelled.recorder.replayRefusal == .unsuccessfulRecording,
              "a recording with a cancelled plug-in's change refuses replay")
    }
}
