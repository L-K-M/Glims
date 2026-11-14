import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseBitmapPSD(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(seconds: TimeInterval = 20, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
        }
        let input = work.appendingPathComponent("bitmap-source.pgm")
        var data = Data("P5\n9 2\n255\n".utf8)
        data.append(contentsOf: [0,255,0,255,0,255,0,255,0, 255,0,255,0,255,0,255,0,255])
        try data.write(to: input)
        let image = try session.openImage(path: input.path)
        let document = try ImageDocument(session: session, image: image, name: "Bitmap source")
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
        let before = try session.copyPixels(image, merged: true).pixels
        let undo = try session.undoInfo(image).undoCount
        let dirty = document.hasUnsavedChanges
        controller.exportDocument(nil)
        wait { controller.window?.attachedSheet != nil }
        guard let panel = controller.window?.attachedSheet as? NSSavePanel,
              let form = panel.accessoryView as? ExportOptionsForm,
              let index = PsdOutputColor.allCases.firstIndex(of: .bitmap),
              let item = form.psdColorPopup.item(at: index) else {
            return check(false, "Bitmap PSD export opens the native options sheet")
        }
        form.selectFormat(.psd)
        check(item.isEnabled == session.supportsBitmapPSD,
              "Bitmap PSD choice follows the adapter capability")
        guard session.supportsBitmapPSD else { panel.cancel(nil); return }
        form.psdColorPopup.selectItem(at: index)
        form.psdColorPopup.sendAction(form.psdColorPopup.action, to: form.psdColorPopup.target)
        check(form.commitEditing() && form.settings.psdColor == .bitmap && form.settings.psdLayout == .merged
              && !form.psdLayoutPopup.isEnabled && form.psdExplanation.stringValue.contains("transparency"),
              "the real Export sheet captures flattened opaque Bitmap output")
        let settings = form.settings
        panel.cancel(nil)
        wait { controller.window?.attachedSheet == nil }
        let output = work.appendingPathComponent("bitmap-export.psd")
        var finished = false
        var failure: Error?
        document.export(to: output, settings: settings) { error in failure = error; finished = true }
        wait(seconds: 90) { finished }
        check(finished && failure == nil && FileManager.default.fileExists(atPath: output.path),
              "the document export pipeline writes the chosen Bitmap PSD")
        guard finished, failure == nil, FileManager.default.fileExists(atPath: output.path) else { return }
        let bytes = try Data(contentsOf: output)
        check(bytes.count == 44 && bytes[23] == 1 && bytes[25] == 0
              && Array(bytes[40..<44]) == [0xaa,0x80,0x55,0],
              "the published file has 1-bit Bitmap mode and the expected pixels")
        check(document.fileState.lastExportURL == output && document.lastExportSettings == settings,
              "successful export remembers the Bitmap choice for repeat export")
        check(try session.copyPixels(image, merged: true).pixels == before
              && session.undoInfo(image).undoCount == undo && document.hasUnsavedChanges == dirty,
              "Bitmap export preserves the source pixels, Undo and dirty state")
        try FileManager.default.removeItem(at: output)
        controller.repeatExport(nil)
        wait(seconds: 90) { FileManager.default.fileExists(atPath: output.path) && document.pendingWork == 0 }
        let repeated = try? Data(contentsOf: output)
        check(repeated == bytes,
              "Repeat Export reuses the Bitmap settings")
    }
}
