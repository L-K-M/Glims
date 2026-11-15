import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseBitmapDiffusion(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(seconds: TimeInterval = 20, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
        }
        let input = work.appendingPathComponent("diffusion-source.pgm")
        var data = Data("P5\n4 4\n255\n".utf8)
        data.append(contentsOf: Array(repeating: UInt8(128), count: 16))
        try data.write(to: input)
        let image = try session.openImage(path: input.path)
        let document = try ImageDocument(session: session, image: image, name: "Diffusion source")
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
              let diffusion = ExportSettings.BitmapMethod.allCases.firstIndex(of: .diffusion),
              let item = form.bitmapMethodPopup.item(at: diffusion) else {
            return check(false, "diffusion export opens its real options sheet")
        }
        form.selectFormat(.psd)
        if session.supportsBitmapPSD {
            form.psdColorPopup.selectItem(at: bitmap)
            form.psdColorPopup.sendAction(form.psdColorPopup.action, to: form.psdColorPopup.target)
        }
        check(item.isEnabled == session.supportsBitmapDiffusionPSD,
              "diffusion choice follows the adapter capability")
        guard session.supportsBitmapPSD && session.supportsBitmapDiffusionPSD else { panel.cancel(nil); return }
        form.bitmapMethodPopup.selectItem(at: diffusion)
        form.bitmapMethodPopup.sendAction(form.bitmapMethodPopup.action, to: form.bitmapMethodPopup.target)
        check(form.commitEditing() && form.settings.bitmapMethod == .diffusion
              && form.psdExplanation.stringValue.contains("dithering"),
              "the actual sheet captures the explicit diffusion method")
        let settings = form.settings
        panel.cancel(nil); wait { controller.window?.attachedSheet == nil }
        let output = work.appendingPathComponent("diffusion-export.psd")
        var finished = false
        var failure: Error?
        document.export(to: output, settings: settings) { error in failure = error; finished = true }
        wait(seconds: 90) { finished }
        check(finished && failure == nil && FileManager.default.fileExists(atPath: output.path),
              "the document pipeline exports diffusion Bitmap")
        guard finished, failure == nil, FileManager.default.fileExists(atPath: output.path) else { return }
        let bytes = try Data(contentsOf: output)
        check(bytes.count == 44 && bytes[23] == 1 && bytes[25] == 0
              && Array(bytes[40..<44]) == [0x50, 0xa0, 0x50, 0xa0],
              "the exported one-bit pixels match the independent diffusion pattern")
        check(document.lastExportSettings == settings && document.fileState.lastExportURL == output,
              "the diffusion choice is remembered for Repeat Export")
        check(try session.copyPixels(image, merged: true).pixels == original
              && session.undoInfo(image).undoCount == undo,
              "diffusion export preserves source pixels and Undo")
        try FileManager.default.removeItem(at: output)
        controller.repeatExport(nil)
        wait(seconds: 90) { FileManager.default.fileExists(atPath: output.path) && document.pendingWork == 0 }
        check((try? Data(contentsOf: output)) == bytes, "Repeat Export preserves diffusion")
    }
}
