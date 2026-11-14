import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseDuotoneExport(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(seconds: TimeInterval = 20, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
        }
        guard let path = ProcessInfo.processInfo.environment["GLIMS_DUOTONE_FIXTURE"] else {
            return check(false, "Duotone fixture path is supplied")
        }
        let input = try Data(contentsOf: URL(fileURLWithPath: path))
        guard input.count >= 30 else { return check(false, "Duotone fixture has a header") }
        let length = input[26..<30].reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= input.count - 30 else { return check(false, "Duotone settings are bounded") }
        let block = input.subdata(in: 30..<(30 + length))
        let image = try session.openImage(path: path)
        let document = try ImageDocument(session: session, image: image, name: "Duotone fixture")
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
              let index = PsdOutputColor.allCases.firstIndex(of: .duotone),
              let item = form.psdColorPopup.item(at: index) else {
            return check(false, "Duotone export opens the options sheet")
        }
        form.selectFormat(.psd)
        check(item.isEnabled == session.supportsDuotonePSD, "Duotone choice follows engine capability")
        guard session.supportsDuotonePSD else { panel.cancel(nil); return }
        form.psdColorPopup.selectItem(at: index)
        form.psdColorPopup.sendAction(form.psdColorPopup.action, to: form.psdColorPopup.target)
        check(form.commitEditing() && form.settings.psdColor == .duotone && form.settings.psdLayout == .merged &&
              !form.psdLayoutPopup.isEnabled && form.psdExplanation.stringValue.contains("preview remains grayscale"),
              "the export sheet explains and captures retained Duotone settings")
        let settings = form.settings
        panel.cancel(nil)
        wait { controller.window?.attachedSheet == nil }
        let output = work.appendingPathComponent("duotone-export.psd")
        var finished = false
        var failure: Error?
        document.export(to: output, settings: settings) { error in failure = error; finished = true }
        wait(seconds: 90) { finished }
        check(finished && failure == nil && FileManager.default.fileExists(atPath: output.path),
              "the document export pipeline writes Duotone PSD")
        guard finished, failure == nil, FileManager.default.fileExists(atPath: output.path) else { return }
        let exported = try Data(contentsOf: output)
        check(exported.count >= 30 + length && exported[23] == 8 && exported[25] == 8 &&
              exported.subdata(in: 30..<(30 + length)) == block,
              "export retains the exact Photoshop color-mode block")
        check(try session.copyPixels(image, merged: true).pixels == before && session.undoInfo(image).undoCount == undo &&
              document.hasUnsavedChanges == dirty && document.lastExportSettings == settings,
              "export preserves source state and records the explicit choice")
        try FileManager.default.removeItem(at: output)
        controller.repeatExport(nil)
        wait(seconds: 90) { FileManager.default.fileExists(atPath: output.path) && document.pendingWork == 0 }
        check((try? Data(contentsOf: output)) == exported, "Repeat Export reuses the Duotone settings")
    }
}
