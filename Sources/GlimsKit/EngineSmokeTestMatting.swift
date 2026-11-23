import AppKit

// MARK: - GLIMS_SMOKE_CASE=matting

@MainActor
extension EngineSmokeTest {
    /// GLIMS_SMOKE_CASE=matting (also in the full run): Layer > Matting.
    /// Remove Black Matte runs through the menu action as one undo step
    /// named "Remove Black Matte" and undo restores the source. Defringe
    /// runs through its real sheet: Cancel changes nothing, OK with width
    /// 2 copies the nearest opaque color into the partial pixels within
    /// two pixels. The three items are disabled with the refusal as their
    /// tool tip on a group. Remove White Matte and Defringe record, save,
    /// load, install and replay into a second identical document with the
    /// same pixels.
    static func exerciseMatting(_ session: EngineSession, work: URL, documents: DocumentList) throws {
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
        func pixels(_ image: Int32) throws -> [UInt8] { [UInt8](try session.copyPixels(image, merged: true).pixels) }
        func pixel(_ bytes: [UInt8], _ x: Int, _ y: Int, _ width: Int) -> [UInt8] {
            let offset = (y * width + x) * 4
            return [bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3]]
        }
        func button(_ title: String, in view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap { button(title, in: $0) }.first
        }
        func field(in view: NSView?) -> NSTextField? {
            guard let view else { return nil }
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }

        var owned: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        func fixture(_ name: String, bytes: [UInt8], width: Int, height: Int) throws -> (ImageDocument, DocumentWindowController) {
            let image = try session.newImage(pixels: ClipboardImage(width: width, height: height,
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
            return (document, controller)
        }
        defer {
            for controller in controllers {
                if let window = controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
                controller.window?.orderOut(nil)
                var stopped = false; controller.canvas.stopRendering { stopped = true }
                while !stopped { spin(0.01) }
            }
            for document in owned { document.closeImageWhenDrained() }
            wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            documents.items.removeAll { document in owned.contains { $0 === document } }
        }

        let menu = MainMenu.make()
        NSApp.mainMenu = menu
        guard let layerMenu = menu.item(withTitle: "Layer")?.submenu,
              let matting = layerMenu.item(withTitle: "Matting")?.submenu,
              let defringeItem = matting.item(withTitle: "Defringe…"),
              let blackItem = matting.item(withTitle: "Remove Black Matte"),
              let whiteItem = matting.item(withTitle: "Remove White Matte") else {
            return check(false, "Layer > Matting exists with its three commands")
        }
        check(defringeItem.action == #selector(DocumentWindowController.defringe(_:))
              && blackItem.action == #selector(DocumentWindowController.removeBlackMatte(_:))
              && whiteItem.action == #selector(DocumentWindowController.removeWhiteMatte(_:)),
              "the Matting commands carry their actions")

        // Remove Black Matte: (100,50,0,128) -> (199,100,0,128); the
        // clamped (200,150,128,128) becomes white; transparent and opaque
        // pixels stay byte-identical.
        var blackBytes: [UInt8] = []
        for y in 0..<4 {
            for x in 0..<4 {
                switch (x, y) {
                case (0, 0): blackBytes += [100, 50, 0, 128]
                case (1, 0): blackBytes += [200, 150, 128, 128]
                case (2, 0): blackBytes += [0, 0, 0, 0]
                case (3, 0): blackBytes += [10, 20, 30, 255]
                default: blackBytes += [70, 80, 90, 255]
                }
            }
        }
        let (black, blackController) = try fixture("Matting black", bytes: blackBytes, width: 4, height: 4)
        black.selectLayer(black.layers.last?.id ?? 0)
        settle(black)
        let blackUndo = try session.undoInfo(black.image).undoCount
        blackController.removeBlackMatte(nil)
        settle(black)
        var bytes = try pixels(black.image)
        let blackInfo = try session.undoInfo(black.image)
        check(blackInfo.undoCount == blackUndo + 1 && blackInfo.nextUndo == "Remove Black Matte",
              "Remove Black Matte is one undo step named after the operation "
              + "(\(blackInfo.nextUndo))")
        check(pixel(bytes, 0, 0, 4).elementsEqual([199, 100, 0, 128])
              && pixel(bytes, 1, 0, 4).elementsEqual([255, 255, 255, 128])
              && pixel(bytes, 2, 0, 4).elementsEqual([0, 0, 0, 0])
              && pixel(bytes, 3, 0, 4).elementsEqual([10, 20, 30, 255]),
              "black matte divides by alpha and leaves transparent and opaque pixels")
        black.undo()
        settle(black)
        bytes = try pixels(black.image)
        check(try session.undoInfo(black.image).undoCount == blackUndo
              && pixel(bytes, 0, 0, 4).elementsEqual([100, 50, 0, 128]),
              "undo restores the black matte source")

        // Defringe through its real sheet: Cancel changes nothing, OK with
        // width 2 reaches the two nearest partial pixels.
        var fringeBytes: [UInt8] = []
        for y in 0..<4 {
            for x in 0..<4 {
                switch (x, y) {
                case (0, 0): fringeBytes += [10, 20, 30, 255]
                case (1, 0): fringeBytes += [200, 100, 50, 128]
                case (2, 0): fringeBytes += [200, 100, 50, 128]
                case (3, 0): fringeBytes += [200, 100, 50, 128]
                default: fringeBytes += [0, 0, 0, 0]
                }
            }
        }
        let (fringe, fringeController) = try fixture("Matting fringe", bytes: fringeBytes, width: 4, height: 4)
        fringe.selectLayer(fringe.layers.last?.id ?? 0)
        settle(fringe)
        guard let window = fringeController.window else { return check(false, "the fringe fixture has a window") }
        let fringeUndo = try session.undoInfo(fringe.image).undoCount

        fringeController.defringe(nil)
        wait { window.attachedSheet != nil }
        let cancel = button("Cancel", in: window.attachedSheet?.contentView)
        check(cancel != nil, "the Defringe sheet has Cancel")
        cancel?.performClick(nil)
        wait { window.attachedSheet == nil }
        settle(fringe)
        check(try session.undoInfo(fringe.image).undoCount == fringeUndo
              && try pixels(fringe.image) == fringeBytes,
              "cancelling the Defringe sheet changes nothing")

        fringeController.defringe(nil)
        wait { window.attachedSheet != nil }
        let sheet = window.attachedSheet
        let widthField = field(in: sheet?.contentView)
        check(widthField?.stringValue == "1", "the Defringe sheet starts at width 1")
        widthField?.stringValue = "2"
        button("OK", in: sheet?.contentView)?.performClick(nil)
        wait { window.attachedSheet == nil }
        settle(fringe)
        bytes = try pixels(fringe.image)
        let fringeInfo = try session.undoInfo(fringe.image)
        check(fringeInfo.undoCount == fringeUndo + 1 && fringeInfo.nextUndo == "Defringe",
              "the Defringe sheet's OK applies width 2 as one step")
        check(pixel(bytes, 1, 0, 4).elementsEqual([10, 20, 30, 128])
              && pixel(bytes, 2, 0, 4).elementsEqual([10, 20, 30, 128])
              && pixel(bytes, 3, 0, 4).elementsEqual([200, 100, 50, 128])
              && pixel(bytes, 1, 0, 4)[3] == 128,
              "Defringe width 2 reaches two pixels and never writes alpha")
        fringe.undo()
        settle(fringe)

        // The three items are disabled with the refusal as their tool tip
        // on a group layer.
        guard let group = try? session.createGroup(image: fringe.image, index: 0, name: "Matting group") else {
            return check(false, "the group fixture is created")
        }
        try session.selectLayer(group, image: fringe.image)
        try fringe.reload()
        settle(fringe)
        check(fringe.activeLayer == group, "the group becomes the active layer")
        for (item, operation) in [(defringeItem, EngineSession.Matting.defringe),
                                 (blackItem, EngineSession.Matting.removeBlackMatte),
                                 (whiteItem, EngineSession.Matting.removeWhiteMatte)] {
            let enabled = fringeController.validateMenuItem(item)
            check(!enabled && item.toolTip != nil && fringe.mattingRefusal(operation) != nil,
                  "\(operation.title) is disabled with a tooltip on a group")
        }
        try session.selectLayer(fringe.layers.last?.id ?? 0, image: fringe.image)
        try fringe.reload()
        settle(fringe)

        // Record Remove White Matte then Defringe, save, load, install and
        // replay into an equal fresh document.
        var recordBytes: [UInt8] = []
        for y in 0..<8 {
            for x in 0..<8 {
                switch (x, y) {
                case (0, 0): recordBytes += [10, 20, 30, 255]
                case (1, 0), (2, 0), (3, 0): recordBytes += [200, 100, 50, 128]
                case (0, 1): recordBytes += [100, 50, 0, 128]
                case (1, 1): recordBytes += [200, 150, 128, 128]
                default: recordBytes += [0, 0, 0, 0]
                }
            }
        }
        let (record, _) = try fixture("Matting record", bytes: recordBytes, width: 8, height: 8)
        try record.startRecording()
        record.applyMatting(.removeWhiteMatte, width: 0)
        settle(record)
        record.applyMatting(.defringe, width: 2)
        settle(record)
        try record.stopRecording()
        settle(record)
        let rows = record.recorder.records
        check(rows.count == 2
              && rows.allSatisfy({ if case .success = $0.resolution { return true }; return false })
              && record.recorder.replayRefusal == nil,
              "both matting commands record one successful row (\(rows.count) rows)")
        if case .success(.matting(let operation, let width))? = rows.first?.resolution {
            check(operation == .removeWhiteMatte && width == 0, "Remove White Matte records its operation")
        } else { check(false, "the first row is Remove White Matte") }
        if case .success(.matting(let operation, let width))? = rows.last?.resolution {
            check(operation == .defringe && width == 2, "Defringe records its operation and width")
        } else { check(false, "the second row is Defringe") }

        let url = work.appendingPathComponent("matting.glims-recording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        record.saveRecording(to: url, checkpoint: try record.recorderSaveCheckpoint()) { saved = $0 }
        settle(record)
        guard let saved, (try? saved.get()) != nil else {
            return check(false, "the matting recording saves")
        }
        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        record.prepareRecordingFile(at: url, checkpoint: try record.recorderInstallCheckpoint()) { loaded = $0 }
        settle(record)
        guard let loaded, let file = try? loaded.get().file else {
            return check(false, "the matting recording loads")
        }
        check(file.records.count == 2, "the saved recording keeps both matting rows")

        let (replay, _) = try fixture("Matting replay", bytes: recordBytes, width: 8, height: 8)
        let choices = try RecorderBatchBindings.resolve(
            file: file, candidates: replay.recorderBatchCandidates(), policy: .matchingNamesAndKinds)
        check(choices.count == 1, "only the base layer needs an install choice (\(choices.count))")
        var installed: Result<Void, Error>?
        replay.installRecording(try RecorderFileSemanticBridge.prepare(file),
                                checkpoint: try replay.recorderInstallCheckpoint(),
                                choices: choices) { installed = $0 }
        settle(replay)
        try installed!.get()
        try replay.startReplay()
        settle(replay)
        check(try pixels(record.image) == pixels(replay.image),
              "the replayed matting renders the same pixels")
    }
}
