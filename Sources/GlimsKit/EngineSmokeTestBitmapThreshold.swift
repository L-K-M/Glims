import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseBitmapThreshold(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(seconds: TimeInterval = 20, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
        }
        let input = work.appendingPathComponent("threshold-source.pgm")
        var data = Data("P5\n5 1\n255\n".utf8)
        data.append(contentsOf: [0, 64, 127, 128, 255])
        try data.write(to: input)
        let image = try session.openImage(path: input.path)
        let document = try ImageDocument(session: session, image: image, name: "Threshold source")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document, exportDirectory: work)
        controller.showWindow(nil)
        defer {
            if let panel = controller.window?.attachedSheet as? NSSavePanel { panel.cancel(nil) }
            controller.window?.orderOut(nil)
            var stopped = false
            controller.canvas.stopRendering { stopped = true }; wait { stopped }
            var closed = false
            document.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === document }
        }
        let original = try session.copyPixels(image, merged: true).pixels
        let undo = try session.undoInfo(image).undoCount
        controller.exportDocument(nil)
        wait { controller.window?.attachedSheet != nil }
        guard let panel = controller.window?.attachedSheet as? NSSavePanel,
              let form = panel.accessoryView as? ExportOptionsForm,
              let bitmap = PsdOutputColor.allCases.firstIndex(of: .bitmap),
              let threshold = ExportSettings.BitmapMethod.allCases.firstIndex(of: .threshold),
              let item = form.bitmapMethodPopup.item(at: threshold) else {
            return check(false, "threshold export opens its real options sheet")
        }
        form.selectFormat(.psd)
        if session.supportsBitmapPSD {
            form.psdColorPopup.selectItem(at: bitmap)
            form.psdColorPopup.sendAction(form.psdColorPopup.action, to: form.psdColorPopup.target)
        }
        check(item.isEnabled == session.supportsBitmapThresholdPSD,
              "threshold choice follows the adapter capability")
        guard session.supportsBitmapPSD && session.supportsBitmapThresholdPSD else { panel.cancel(nil); return }
        form.bitmapMethodPopup.selectItem(at: threshold)
        form.bitmapMethodPopup.sendAction(form.bitmapMethodPopup.action, to: form.bitmapMethodPopup.target)
        form.bitmapThresholdRow.field.stringValue = "128"
        check(form.commitEditing() && form.settings.bitmapMethod == .threshold
              && form.settings.bitmapThreshold == 128 && form.psdExplanation.stringValue.contains("at or below"),
              "the actual sheet captures the explicit threshold")
        let settings = form.settings
        panel.cancel(nil); wait { controller.window?.attachedSheet == nil }
        let output = work.appendingPathComponent("threshold-export.psd")
        var finished = false
        var failure: Error?
        document.export(to: output, settings: settings) { error in failure = error; finished = true }
        wait(seconds: 90) { finished }
        check(finished && failure == nil && FileManager.default.fileExists(atPath: output.path),
              "the document pipeline exports threshold Bitmap")
        guard finished, failure == nil, FileManager.default.fileExists(atPath: output.path) else { return }
        let bytes = try Data(contentsOf: output)
        check(bytes.count == 41 && bytes[23] == 1 && bytes[25] == 0 && bytes[40] == 0xf0,
              "the threshold's inclusive boundary produces the expected one-bit pixels")
        check(document.lastExportSettings == settings && document.fileState.lastExportURL == output,
              "the threshold choice is remembered for Repeat Export")
        check(try session.copyPixels(image, merged: true).pixels == original
              && session.undoInfo(image).undoCount == undo,
              "threshold export preserves source pixels and Undo")
        try FileManager.default.removeItem(at: output)
        controller.repeatExport(nil)
        wait(seconds: 90) { FileManager.default.fileExists(atPath: output.path) && document.pendingWork == 0 }
        check((try? Data(contentsOf: output)) == bytes, "Repeat Export preserves the threshold")
    }
}
