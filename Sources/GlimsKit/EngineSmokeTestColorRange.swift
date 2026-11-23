import AppKit

/// GLIMS_SMOKE_CASE=color-range (also in the full run): Select > Color
/// Range. The real utility panel samples through the engine, renders its
/// mask off the main thread, applies one "Color Range" undo step on OK,
/// refuses Cancel changes and routes canvas presses to sampling instead of
/// painting while it is open. A recording saves at version 36 and replays
/// onto a twin with the same selection mask.
@MainActor
extension EngineSmokeTest {
    fileprivate struct SelectionMaskSnapshot: Equatable {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    static func exerciseColorRange(_ session: EngineSession, work: URL, documents: DocumentList) throws {
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
        func pixels(_ image: Int32) throws -> [UInt8] {
            [UInt8](try session.copyPixels(image, merged: true).pixels)
        }
        /// Reads the full selection as a channel thumbnail on a duplicate.
        func selectionMask(_ image: Int32) throws -> SelectionMaskSnapshot {
            let copy = try session.duplicateImage(image)
            defer { try? session.closeImage(copy) }
            let channel = try session.channelFromSelection(copy, name: "Color Range oracle")
            guard let rendered = try session.drawableThumbnail(channel, image: copy, maxSize: 64),
                  let data = rendered.dataProvider?.data as Data? else {
                throw NSError(domain: "ColorRangeSmoke", code: 1)
            }
            return SelectionMaskSnapshot(width: rendered.width, height: rendered.height,
                                         bytes: Array(data))
        }

        var bytes: [UInt8] = []
        for y in 0..<8 {
            for x in 0..<8 {
                switch (x < 4, y < 4) {
                case (true, true): bytes += [255, 100, 100, 255]
                case (false, true): bytes += [250, 250, 250, 255]
                case (true, false): bytes += [8, 8, 12, 255]
                default: bytes += [120, 160, 255, 255]
                }
            }
        }

        var owned: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        var errors: [String] = []
        func fixture(_ name: String) throws -> (ImageDocument, DocumentWindowController) {
            let image = try session.newImage(pixels: ClipboardImage(width: 8, height: 8,
                                                                    pixels: Data(bytes), origin: .zero))
            let document = try ImageDocument(session: session, image: image, name: name)
            document.onError = { errors.append($0) }
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
                controller.colorRangePanel?.cancel()
                controller.colorRangePanel?.window?.orderOut(nil)
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
                controller.window?.orderOut(nil)
                var stopped = false
                controller.canvas.stopRendering { stopped = true }
                while !stopped { spin(0.01) }
            }
            for document in owned { document.closeImageWhenDrained() }
            wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            documents.items.removeAll { document in owned.contains { $0 === document } }
        }

        let menu = MainMenu.make()
        NSApp.mainMenu = menu
        guard let select = menu.item(withTitle: "Select")?.submenu,
              let item = select.item(withTitle: "Color Range…") else {
            return check(false, "Select > Color Range… exists")
        }
        check(item.action == #selector(DocumentWindowController.colorRange(_:)),
              "Color Range… carries its action")

        // Open, sample a block through the panel's method, check the mask.
        let (document, controller) = try fixture("Color Range")
        controller.colorRange(nil)
        wait { controller.colorRangePanel != nil }
        guard let panel = controller.colorRangePanel else {
            return check(false, "the Color Range panel opens")
        }
        panel.sample(at: CGPoint(x: 1.5, y: 1.5), flags: [])
        wait { panel.maskWidth == 8 && panel.maskHeight == 8 && !panel.maskBytes.isEmpty }
        check(panel.maskWidth == 8 && panel.maskHeight == 8,
              "the panel previews at the fixture's size (\(panel.maskWidth)x\(panel.maskHeight))")
        check(panel.maskBytes[0] == 255 && panel.maskBytes[7] == 0
              && panel.maskBytes[56] == 0 && panel.maskBytes[63] == 0,
              "the preview marks only the sampled quadrant")
        check(panel.maskBytes.filter { $0 != 0 }.count == 16,
              "the preview keeps exactly the sampled block (\(panel.maskBytes.filter { $0 != 0 }.count))")

        let undoBefore = try session.undoInfo(document.image).undoCount
        panel.commit()
        wait { controller.colorRangePanel == nil }
        settle(document)
        let info = try session.undoInfo(document.image)
        check(info.undoCount == undoBefore + 1 && info.nextUndo == "Color Range",
              "OK applies one named Color Range undo step (\(info.nextUndo); errors: \(errors))")
        check(try session.selectionBounds(image: document.image) == CGRect(x: 0, y: 0, width: 4, height: 4),
              "OK replaces the selection with the sampled block")

        // Cancel leaves the selection alone.
        controller.colorRange(nil)
        wait { controller.colorRangePanel != nil }
        guard let cancelPanel = controller.colorRangePanel else {
            return check(false, "the Color Range panel reopens")
        }
        cancelPanel.sample(at: CGPoint(x: 6.5, y: 6.5), flags: [])
        wait { cancelPanel.maskWidth == 8 && !cancelPanel.maskBytes.isEmpty }
        let beforeCancel = try session.undoInfo(document.image)
        cancelPanel.cancel()
        wait { controller.colorRangePanel == nil }
        settle(document)
        check(try session.undoInfo(document.image) == beforeCancel
              && session.selectionBounds(image: document.image) == CGRect(x: 0, y: 0, width: 4, height: 4),
              "Cancel changes neither history nor selection")

        // A canvas press samples while the panel is open; painting cannot run.
        let (canvasDoc, canvasController) = try fixture("Color Range canvas")
        canvasDoc.selectLayer(canvasDoc.layers.last?.id ?? 0)
        settle(canvasDoc)
        ToolState.shared.select(.paintbrush)
        ToolState.shared.foreground = .red
        let pixelsBefore = try pixels(canvasDoc.image)
        let undoAtPaint = try session.undoInfo(canvasDoc.image).undoCount
        canvasController.colorRange(nil)
        wait { canvasController.colorRangePanel != nil }
        guard let paintPanel = canvasController.colorRangePanel,
              let window = canvasController.window else {
            return check(false, "the canvas fixture's panel opens")
        }
        let canvas = canvasController.canvas
        let location = canvas.convert(CGPoint(x: 2 * canvas.scale, y: 2 * canvas.scale), to: nil)
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: location,
                                             modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil,
                                             eventNumber: 0, clickCount: 1, pressure: 1) else {
            return check(false, "the canvas press constructs")
        }
        canvas.mouseDown(with: event)
        wait { paintPanel.maskWidth == 8 && !paintPanel.maskBytes.isEmpty }
        let canvasUnchanged = try pixels(canvasDoc.image) == pixelsBefore
            && session.undoInfo(canvasDoc.image).undoCount == undoAtPaint
        check(!canvasDoc.strokeIsActive && canvasUnchanged,
              "a canvas press while the panel is open samples instead of painting")
        paintPanel.cancel()
        wait { canvasController.colorRangePanel == nil }
        settle(canvasDoc)

        // Record, save, load, install and replay onto an equal fresh twin.
        let (record, _) = try fixture("Color Range record")
        var recordedSettings = EngineSession.ColorRangeSettings()
        recordedSettings.samples = [.init(red: 1, green: 100.0 / 255.0,
                                          blue: 100.0 / 255.0, subtract: false)]
        try record.startRecording()
        record.selectColorRange(recordedSettings)
        settle(record)
        try record.stopRecording()
        settle(record)
        let rows = record.recorder.records
        check(rows.count == 1
              && rows.allSatisfy({ if case .success = $0.resolution { return true }; return false })
              && record.recorder.replayRefusal == nil,
              "Color Range records one successful row (\(rows.count) rows)")
        if case .success(.colorRange(let captured))? = rows.first?.resolution {
            check(captured == recordedSettings, "the Color Range row keeps its exact settings")
        } else {
            check(false, "the Color Range row was lost")
        }

        let url = work.appendingPathComponent("color-range.glimsrecording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        record.saveRecording(to: url, checkpoint: try record.recorderSaveCheckpoint()) { saved = $0 }
        settle(record)
        guard let saved, (try? saved.get()) != nil else {
            return check(false, "the Color Range recording saves")
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(text.contains("\"colorRange\"") && text.contains("\"version\":36"),
              "the saved recording declares Color Range at version 36")

        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        record.prepareRecordingFile(at: url, checkpoint: try record.recorderInstallCheckpoint()) { loaded = $0 }
        settle(record)
        guard let loaded, let prepared = try? loaded.get() else {
            return check(false, "the Color Range recording loads")
        }
        check(prepared.file.records.count == 1, "the saved recording keeps the Color Range row")

        let (replay, _) = try fixture("Color Range replay")
        var installed: Result<Void, Error>?
        replay.installRecording(prepared, checkpoint: try replay.recorderInstallCheckpoint(),
                                choices: [:]) { installed = $0 }
        settle(replay)
        guard let installed, (try? installed.get()) != nil else {
            return check(false, "the Color Range recording installs")
        }
        try replay.startReplay()
        settle(replay)
        check(try selectionMask(record.image) == selectionMask(replay.image),
              "the replayed Color Range selects the same mask")
        check(try session.selectionBounds(image: record.image) == session.selectionBounds(image: replay.image),
              "both documents end with the same selection bounds")
    }
}
