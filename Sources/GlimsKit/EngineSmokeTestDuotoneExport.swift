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
        func alternateResource(_ data: Data) -> Data? {
            guard data.count >= 30 else { return nil }
            let mode = data[26..<30].reduce(0) { ($0 << 8) | Int($1) }
            guard mode <= data.count - 30, data.count - 30 - mode >= 4 else { return nil }
            var position = 30 + mode
            let size = data[position..<(position + 4)].reduce(0) { ($0 << 8) | Int($1) }
            position += 4
            guard size <= data.count - position else { return nil }
            let end = position + size
            var found: Data?
            while position < end {
                guard end - position >= 12,
                      data[position..<(position + 4)].elementsEqual([0x38, 0x42, 0x49, 0x4d]) else { return nil }
                let id = (Int(data[position + 4]) << 8) | Int(data[position + 5])
                let nameSize = (Int(data[position + 6]) + 2) & ~1
                guard nameSize <= end - position - 6, end - position - 6 - nameSize >= 4 else { return nil }
                let offset = position + 6 + nameSize
                let count = data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
                let start = offset + 4
                guard count <= end - start, count % 2 == 0 || count < end - start else { return nil }
                if id == 1066 {
                    guard found == nil else { return nil }
                    found = data.subdata(in: start..<(start + count))
                }
                position = start + count + count % 2
            }
            return position == end ? found : nil
        }
        guard let alternate = alternateResource(input), alternate.count == 794 else {
            return check(false, "Duotone fixture contains alternate-color data")
        }
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
        check(alternateResource(exported) == alternate,
              "document export retains the exact alternate-color resource")
        check(try session.copyPixels(image, merged: true).pixels == before && session.undoInfo(image).undoCount == undo &&
              document.hasUnsavedChanges == dirty && document.lastExportSettings == settings,
              "export preserves source state and records the explicit choice")
        try FileManager.default.removeItem(at: output)
        controller.repeatExport(nil)
        wait(seconds: 90) { FileManager.default.fileExists(atPath: output.path) && document.pendingWork == 0 }
        check((try? Data(contentsOf: output)) == exported, "Repeat Export reuses the Duotone settings")
    }
}
