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
        let originalImage = try session.openImage(path: path)
        let originalPixels = try session.copyPixels(originalImage, merged: true).pixels
        let hasTransparency = originalPixels.enumerated().contains { $0.offset % 4 == 3 && $0.element != 255 }
        var transparentDocument: ImageDocument?
        let image: Int32
        if hasTransparency {
            // Some engine versions cannot import the fixture's live gradient
            // and leave it transparent. Preserve that image to verify refusal,
            // then exercise successful export with an independent flat PSD
            // carrying the identical Photoshop-authored color-mode block.
            let source = try ImageDocument(session: session, image: originalImage, name: "Incomplete Duotone fixture")
            documents.items.append(source)
            transparentDocument = source
            let header: [UInt8] = [0x38, 0x42, 0x50, 0x53, 0, 1, 0, 0, 0, 0, 0, 0,
                                   0, 1, 0, 0, 0, 4, 0, 0, 0, 4, 0, 8, 0, 8]
            var flat = Data(header)
            flat.append(input.subdata(in: 26..<(30 + length)))
            flat.append(Data(repeating: 0, count: 10))
            flat.append(contentsOf: [0, 17, 34, 51, 68, 85, 102, 119,
                                     136, 153, 170, 187, 204, 221, 238, 255])
            let flatURL = work.appendingPathComponent("flat-duotone-fixture.psd")
            try flat.write(to: flatURL)
            image = try session.openImage(path: flatURL.path)
        } else {
            image = originalImage
        }
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
            if let transparentDocument {
                var sourceClosed = false
                transparentDocument.closeImageWhenDrained { sourceClosed = true }; wait { sourceClosed }
                documents.items.removeAll { $0 === transparentDocument }
            }
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
        if let transparentDocument {
            let sourceUndo = try session.undoInfo(originalImage)
            let sourceDirty = transparentDocument.hasUnsavedChanges
            let refusedURL = work.appendingPathComponent("transparent-duotone-refused.psd")
            var refusalFinished = false
            var refusal: Error?
            transparentDocument.export(to: refusedURL, settings: settings) { error in
                refusal = error; refusalFinished = true
            }
            wait(seconds: 90) { refusalFinished }
            check(try refusalFinished && (refusal?.localizedDescription.contains("opaque") ?? false) &&
                  !FileManager.default.fileExists(atPath: refusedURL.path) &&
                  session.copyPixels(originalImage, merged: true).pixels == originalPixels &&
                  session.undoInfo(originalImage) == sourceUndo && transparentDocument.hasUnsavedChanges == sourceDirty,
                  "an incomplete transparent Duotone import refuses export without changing the source")
        }
        let output = work.appendingPathComponent("duotone-export.psd")
        var finished = false
        var failure: Error?
        document.export(to: output, settings: settings) { error in failure = error; finished = true }
        wait(seconds: 90) { finished }
        let outputExists = FileManager.default.fileExists(atPath: output.path)
        let diagnostic = "finished=\(finished), error=\(failure.map { String(describing: $0) } ?? "none"), file=\(outputExists)"
        check(finished && failure == nil && outputExists,
              "the document export pipeline writes Duotone PSD (\(diagnostic))")
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
