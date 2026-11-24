import AppKit

/// GLIMS_SMOKE_CASE=replace-color (also in the full run): Image > Adjust >
/// Replace Color. The real utility panel samples through the engine, writes
/// the scalar properties, previews the live composite, applies one
/// "Replace Color" undo step on OK, refuses Cancel changes, and replays a
/// saved recording at format version 38 onto a twin.
@MainActor
extension EngineSmokeTest {
    static func exerciseReplaceColor(_ session: EngineSession, work: URL, documents: DocumentList) throws {
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

        var bytes: [UInt8] = []
        for y in 0..<8 {
            for x in 0..<8 {
                switch (x < 4, y < 4) {
                case (true, true): bytes += [255, 0, 0, 255]
                case (false, true): bytes += [0, 255, 0, 255]
                case (true, false): bytes += [0, 0, 255, 255]
                default: bytes += [255, 255, 255, 255]
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
                (controller.previewPanel as? ReplaceColorPanel)?.cancel()
                controller.previewPanel?.window?.orderOut(nil)
                controller.colorRangePanel?.cancel()
                controller.colorRangePanel?.window?.orderOut(nil)
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet)
                }
                controller.window?.orderOut(nil)
                var stopped = false
                controller.canvas.stopRendering { stopped = true }
                wait { stopped }
                check(stopped, "the Replace Color canvas stops rendering in time")
            }
            for document in owned { document.closeImageWhenDrained() }
            wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            documents.items.removeAll { document in owned.contains { $0 === document } }
        }

        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        let menu = MainMenu.make()
        NSApp.mainMenu = menu
        NativeFilterMenus.install(operations, in: menu)
        guard let adjust = menu.item(withTitle: "Image")?.submenu?
                .item(withTitle: MainMenu.adjustTitle)?.submenu,
              let item = adjust.item(withTitle: "Replace Color…"),
              let command = item.representedObject as? NativeFilterCommand,
              let action = item.action else {
            return check(false, "Image ▸ Adjust offers Replace Color from the catalog")
        }
        check(command.operation.name == ReplaceColorPanel.operation,
              "Replace Color routes a supported owned operation")

        let (document, controller) = try fixture("Replace Color")
        let original = try pixels(document.image)
        let baseline = try session.undoInfo(document.image).undoCount

        // Record the Apply so the later replay covers the real panel path.
        try document.startRecording()

        NSApp.sendAction(action, to: controller, from: item)
        wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let panel = controller.previewPanel as? ReplaceColorPanel, let filter = panel.filter else {
            return check(false, "Replace Color opens its editor")
        }
        panel.sample(at: CGPoint(x: 1.5, y: 1.5), flags: [])
        wait { panel.maskWidth == 8 && panel.maskHeight == 8 && !panel.maskBytes.isEmpty }
        guard panel.maskBytes.count >= 64 else {
            return check(false, "the preview computes a full-canvas mask")
        }
        check(panel.maskBytes[0] == 255 && panel.maskBytes[7] == 0
              && panel.maskBytes[56] == 0 && panel.maskBytes[63] == 0,
              "the preview marks only the sampled quadrant")

        panel.setProperty("hue", .number(180))
        settle(document)
        check((try? session.filterProperty(filter, "hue")) == .number(180),
              "the hue slider's property write reaches the live session")
        let preview = try pixels(document.image)
        check(preview != original, "the live Replace Color preview changes the composite")

        panel.apply()
        wait { controller.previewPanel == nil && document.pendingWork == 0 }
        guard controller.previewPanel == nil else {
            return check(false, "OK commits and closes the Replace Color panel")
        }
        settle(document)
        let applied = try pixels(document.image)
        let info = try session.undoInfo(document.image)
        var exact = applied != original
        for y in 0..<8 {
            for x in 0..<8 {
                let at = (y * 8 + x) * 4
                let wanted: [UInt8]
                if y < 4 && x < 4 { wanted = [0, 255, 255, 255] }
                else if y < 4 { wanted = [0, 255, 0, 255] }
                else if x < 4 { wanted = [0, 0, 255, 255] }
                else { wanted = [255, 255, 255, 255] }
                if Array(applied[at..<at + 4]) != wanted { exact = false }
            }
        }
        check(exact && info.undoCount == baseline + 1 && info.nextUndo == "Replace Color",
              "OK applies one named Replace Color undo step (\(info.nextUndo); errors: \(errors))")

        // Cancel leaves the committed pixels alone.
        NSApp.sendAction(action, to: controller, from: item)
        wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let cancelPanel = controller.previewPanel as? ReplaceColorPanel else {
            return check(false, "Replace Color reopens after Apply")
        }
        cancelPanel.sample(at: CGPoint(x: 6.5, y: 6.5), flags: [])
        wait { cancelPanel.maskWidth == 8 && cancelPanel.maskHeight == 8 && !cancelPanel.maskBytes.isEmpty }
        cancelPanel.setProperty("hue", .number(-90))
        settle(document)
        cancelPanel.cancel()
        wait { controller.previewPanel == nil && document.pendingWork == 0 }
        settle(document)
        check(try pixels(document.image) == applied
              && session.undoInfo(document.image).undoCount == baseline + 1,
              "Cancel changes neither pixels nor history")

        try document.stopRecording()
        settle(document)
        let rows = document.recorder.records
        check(rows.count == 1
              && rows.allSatisfy({ if case .success = $0.resolution { return true }; return false })
              && document.recorder.replayRefusal == nil,
              "Replace Color records one successful row (\(rows.count) rows)")
        if case .success(.applyReplaceColor(let captured))? = rows.first?.resolution {
            check(captured.hue == 180 && captured.fuzziness == 40
                  && captured.samples.count == 1 && !captured.samples[0].subtract,
                  "the Replace Color row keeps its exact settings")
        } else {
            check(false, "the Replace Color row was lost")
        }

        let url = work.appendingPathComponent("replace-color.glimsrecording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        document.saveRecording(to: url, checkpoint: try document.recorderSaveCheckpoint()) { saved = $0 }
        settle(document)
        guard let saved, (try? saved.get()) != nil else {
            return check(false, "the Replace Color recording saves")
        }
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        check(text.contains("\"applyReplaceColor\"") && text.contains("\"version\":38"),
              "the saved recording declares Replace Color at version 38")

        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        document.prepareRecordingFile(at: url, checkpoint: try document.recorderInstallCheckpoint()) { loaded = $0 }
        settle(document)
        guard let loaded, let prepared = try? loaded.get() else {
            return check(false, "the Replace Color recording loads")
        }
        check(prepared.file.records.count == 1, "the saved recording keeps the Replace Color row")

        let (replay, _) = try fixture("Replace Color replay")
        guard let symbol = prepared.file.symbols.first?.id,
              let replayLayer = replay.activeLayer else {
            return check(false, "the Replace Color recording names its layer and the twin has one")
        }
        var installed: Result<Void, Error>?
        replay.installRecording(prepared, checkpoint: try replay.recorderInstallCheckpoint(),
                                choices: [symbol: .layer(replayLayer)]) { installed = $0 }
        settle(replay)
        guard let installed, (try? installed.get()) != nil else {
            return check(false, "the Replace Color recording installs")
        }
        try replay.startReplay()
        settle(replay)
        check(try pixels(replay.image) == applied,
              "the replayed Replace Color reproduces the committed pixels")

        // A grayscale twin refuses the replay at the recorded step, as the
        // menu item refuses grayscale images, and keeps its pixels.
        let (gray, _) = try fixture("Replace Color grayscale replay")
        try session.convertMode(gray.image, to: .grayscale)
        try gray.reload()
        settle(gray)
        guard let grayLayer = gray.activeLayer else {
            return check(false, "the grayscale twin has a layer")
        }
        let grayBefore = try pixels(gray.image), grayUndo = try session.undoInfo(gray.image)
        var grayInstalled: Result<Void, Error>?
        gray.installRecording(prepared, checkpoint: try gray.recorderInstallCheckpoint(),
                              choices: [symbol: .layer(grayLayer)]) { grayInstalled = $0 }
        settle(gray)
        guard let grayInstalled, (try? grayInstalled.get()) != nil else {
            return check(false, "the Replace Color recording installs on the grayscale twin")
        }
        try gray.startReplay()
        settle(gray)
        if case .failed(index: 0, reason: _) = gray.replayStatus {
            check(try pixels(gray.image) == grayBefore && session.undoInfo(gray.image) == grayUndo,
                  "a grayscale replay of Replace Color refuses and keeps pixels and history")
        } else {
            check(false, "a grayscale replay of Replace Color reports a refusal at its step")
        }
    }
}
