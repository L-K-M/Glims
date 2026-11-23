import AppKit

// MARK: - GLIMS_SMOKE_CASE=variations

@MainActor
extension EngineSmokeTest {
    /// GLIMS_SMOKE_CASE=variations (also in the full run): Image > Adjust >
    /// Variations. The real sheet accumulates two More Red clicks and one
    /// Lighter click, renders thumbnails off the main thread, refuses
    /// Cancel changes and applies one "Variations" undo step on OK whose
    /// pixels equal `applyVariations` on a twin. Undo and redo bracket it,
    /// a grayscale document disables the menu item with a refusal tool
    /// tip, and a recorded row saves at version 35 and replays onto a
    /// second identical document with the same pixels.
    static func exerciseVariations(_ session: EngineSession, work: URL, documents: DocumentList) throws {
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
        func button(_ title: String, in view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap { button(title, in: $0) }.first
        }
        func thumbnailImages(_ view: NSView?) -> [NSImage] {
            guard let view else { return [] }
            var found: [NSImage] = []
            if let button = view as? NSButton, let image = button.image { found.append(image) }
            for subview in view.subviews { found += thumbnailImages(subview) }
            return found
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
        guard let adjust = menu.item(withTitle: "Image")?.submenu?
                .item(withTitle: MainMenu.adjustTitle)?.submenu,
              let variationsItem = adjust.item(withTitle: "Variations…") else {
            return check(false, "Image > Adjust > Variations… exists")
        }
        check(variationsItem.action == #selector(DocumentWindowController.variations(_:)),
              "Variations… carries its action")

        var bytes: [UInt8] = []
        for y in 0..<8 {
            for x in 0..<8 {
                switch (x, y) {
                case (0, 0): bytes += [20, 10, 10, 255]
                case (1, 0): bytes += [70, 40, 30, 255]
                case (2, 0): bytes += [130, 90, 60, 255]
                case (3, 0): bytes += [190, 120, 200, 255]
                case (4, 0): bytes += [240, 200, 110, 255]
                default: bytes += [UInt8(x * 24 + y * 8), UInt8(120 + x * 10), UInt8(180 - y * 12), 255]
                }
            }
        }
        let (document, controller) = try fixture("Variations", bytes: bytes, width: 8, height: 8)
        document.selectLayer(document.layers.last?.id ?? 0)
        settle(document)
        guard let window = controller.window else { return check(false, "the fixture has a window") }
        let undoBefore = try session.undoInfo(document.image).undoCount
        let source = try pixels(document.image)

        // Cancel first: clicks and thumbnails happen, nothing is applied.
        controller.variations(nil)
        wait { window.attachedSheet != nil }
        guard let firstForm = controller.variationsForm,
              let sheet = window.attachedSheet,
              let moreRed = button("More Red", in: sheet.contentView),
              let lighter = button("Lighter", in: sheet.contentView),
              let cancel = button("Cancel", in: sheet.contentView) else {
            return check(false, "the Variations sheet exposes its buttons")
        }
        moreRed.performClick(nil)
        moreRed.performClick(nil)
        lighter.performClick(nil)
        let step = VariationsModel.steps[VariationsModel.defaultStepIndex]
        let expected = firstForm.model.settings
        check(expected.midtones.cyanRed == 2 * step && expected.lightness == step
              && expected.shadows.cyanRed == 0 && expected.highlights.cyanRed == 0,
              "two More Red clicks and one Lighter click accumulate into Midtones and lightness")
        wait { thumbnailImages(sheet.contentView).count >= 8 }
        check(thumbnailImages(sheet.contentView).count >= 8, "the Variations thumbnails arrive")
        cancel.performClick(nil)
        wait { window.attachedSheet == nil }
        settle(document)
        let cancelUndo = try session.undoInfo(document.image).undoCount
        let cancelPixels = try pixels(document.image)
        check(cancelUndo == undoBefore && cancelPixels == source,
              "cancelling Variations changes no pixels and no history")

        // Reopen and apply through OK.
        controller.variations(nil)
        wait { window.attachedSheet != nil }
        guard let secondForm = controller.variationsForm,
              let sheet = window.attachedSheet,
              let moreRed = button("More Red", in: sheet.contentView),
              let lighter = button("Lighter", in: sheet.contentView),
              let ok = button("OK", in: sheet.contentView) else {
            return check(false, "the Variations sheet reopens with its buttons")
        }
        moreRed.performClick(nil)
        moreRed.performClick(nil)
        lighter.performClick(nil)
        let appliedSettings = secondForm.model.settings
        wait { thumbnailImages(sheet.contentView).count >= 8 }
        ok.performClick(nil)
        wait { window.attachedSheet == nil }
        settle(document)
        let applied = try pixels(document.image)
        let info = try session.undoInfo(document.image)
        check(info.undoCount == undoBefore + 1 && info.nextUndo == "Variations",
              "OK applies Variations as one named undo step (\(info.nextUndo))")

        // The destructive result equals the facade call on a twin.
        let (twin, _) = try fixture("Variations twin", bytes: bytes, width: 8, height: 8)
        try session.applyVariations(twin.image, layer: twin.layers.first?.id ?? 0,
                                    settings: appliedSettings)
        check(try pixels(twin.image) == applied,
              "the sheet's OK and the facade's applyVariations agree pixel for pixel")

        document.undo()
        settle(document)
        check(try pixels(document.image) == source, "undo restores the Variations source")
        document.redo()
        settle(document)
        check(try pixels(document.image) == applied, "redo reapplies Variations")

        // A grayscale document disables the item with its refusal as the tip.
        let (gray, grayController) = try fixture("Variations gray", bytes: bytes, width: 8, height: 8)
        try session.convertMode(gray.image, to: .grayscale)
        try gray.reload()
        settle(gray)
        gray.selectLayer(gray.layers.last?.id ?? 0)
        settle(gray)
        let grayEnabled = grayController.validateMenuItem(variationsItem)
        check(!grayEnabled && variationsItem.toolTip != nil && gray.variationsRefusal() != nil,
              "a grayscale document disables Variations with a tooltip")

        // Record, save, load, install and replay onto an equal fresh twin.
        let (record, _) = try fixture("Variations record", bytes: bytes, width: 8, height: 8)
        record.selectLayer(record.layers.last?.id ?? 0)
        settle(record)
        let recordedSettings = EngineSession.VariationsSettings(
            shadows: .init(cyanRed: 0.1, magentaGreen: 0, yellowBlue: 0),
            midtones: .init(cyanRed: 0, magentaGreen: -0.2, yellowBlue: 0),
            highlights: .init(cyanRed: 0, magentaGreen: 0, yellowBlue: 0.3),
            lightness: 0.15, saturation: -0.2)
        // OK after the active layer changed (here: a layer id the sheet
        // never previewed) is refused and edits nothing.
        let recordSource = try pixels(record.image)
        record.applyVariations(recordedSettings, layer: (record.activeLayer ?? 0) + 9999)
        settle(record)
        check(try pixels(record.image) == recordSource,
              "Variations refuses a layer other than the previewed one")

        try record.startRecording()
        record.applyVariations(recordedSettings, layer: record.activeLayer ?? 0)
        settle(record)
        try record.stopRecording()
        settle(record)
        let rows = record.recorder.records
        check(rows.count == 1
              && rows.allSatisfy({ if case .success = $0.resolution { return true }; return false })
              && record.recorder.replayRefusal == nil,
              "Variations records one successful row (\(rows.count) rows)")
        if case .success(.applyVariations(let captured))? = rows.first?.resolution {
            check(captured == recordedSettings, "the Variations row keeps its exact settings")
        } else { check(false, "the Variations row was lost") }

        let url = work.appendingPathComponent("variations.glims-recording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        record.saveRecording(to: url, checkpoint: try record.recorderSaveCheckpoint()) { saved = $0 }
        settle(record)
        guard let saved, (try? saved.get()) != nil else {
            return check(false, "the Variations recording saves")
        }
        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        record.prepareRecordingFile(at: url, checkpoint: try record.recorderInstallCheckpoint()) { loaded = $0 }
        settle(record)
        guard let loaded, let file = try? loaded.get().file else {
            return check(false, "the Variations recording loads")
        }
        check(file.records.count == 1, "the saved recording keeps the Variations row")

        let (replay, _) = try fixture("Variations replay", bytes: bytes, width: 8, height: 8)
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
              "the replayed Variations renders the same pixels")
    }
}
