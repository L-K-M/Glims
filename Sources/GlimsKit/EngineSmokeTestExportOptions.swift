import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseExportOptions(_ session: EngineSession, work: URL,
                                       documents: DocumentList) throws {
        func wait(seconds: TimeInterval = 20, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
        }
        let image = try session.newImage(width: 32, height: 24)
        let document = try ImageDocument(session: session, image: image, name: "Export controls")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document, exportDirectory: work)
        controller.showWindow(nil)
        var exportError: String?
        document.onError = { exportError = $0 }
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
        let dirty = document.hasUnsavedChanges

        controller.exportDocument(nil)
        wait { controller.window?.attachedSheet != nil }
        guard let panel = controller.window?.attachedSheet as? NSSavePanel,
              let form = panel.accessoryView as? ExportOptionsForm else {
            return check(false, "File Export opens a native save sheet with format controls")
        }
        check(form.settings.format == .png && panel.allowedContentTypes == [.png],
              "Export starts with the PNG controls and matching filename type")
        form.selectFormat(.jpeg)
        check(panel.allowedContentTypes == [.jpeg] && panel.nameFieldStringValue.hasSuffix(".jpg"),
              "changing the export format changes the allowed type and filename extension")
        form.qualityRow.field.stringValue = "not a number"
        var refused = false
        do { try (panel.delegate as? ExportSavePanel)?.panel(panel, validate: work.appendingPathComponent("invalid.jpg")) }
        catch { refused = true }
        check(refused && form.lastError != nil && controller.window?.attachedSheet === panel,
              "invalid quality keeps the export sheet open with an inline correction")
        form.qualityRow.field.stringValue = "37"
        form.progressiveBox.state = .off
        form.progressiveBox.sendAction(form.progressiveBox.action, to: form.progressiveBox.target)
        check(form.commitEditing() && form.settings.jpegQuality == 0.37 && !form.settings.jpegProgressive,
              "the visible export fields commit the requested values")
        let file = work.appendingPathComponent("native-export-options.jpg")
        // The native picker resolves /var to /private/var on this Mac.
        func remembersDestination() -> Bool {
            document.fileState.lastExportURL?.resolvingSymlinksInPath() == file.resolvingSymlinksInPath()
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        // Like the Recorder picker fixture, the external UI driver operates
        // the native remote file panel. AppKit has no programmatic OK action.
        FileHandle.standardError.write(Data("Export picker: save only to \(file.path)\n".utf8))
        wait(seconds: 90) { controller.window?.attachedSheet == nil && document.pendingWork == 0
            && (remembersDestination() || exportError != nil) }
        check(exportError == nil && FileManager.default.fileExists(atPath: file.path)
              && remembersDestination() && document.lastExportSettings == form.settings,
              "accepting Export writes the image and remembers its exact settings: \(exportError ?? "ok")")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let first = try Data(contentsOf: file)
        check(first.starts(with: [0xff, 0xd8]) && first.range(of: Data([0xff, 0xc0])) != nil,
              "the actual sheet produces the requested baseline JPEG")

        // Delete the output, then exercise the ordinary Cmd-E action. It
        // must repeat the successful captured request without opening a sheet.
        try FileManager.default.removeItem(at: file)
        controller.repeatExport(nil)
        wait { document.pendingWork == 0 && FileManager.default.fileExists(atPath: file.path) }
        check(controller.window?.attachedSheet == nil && (try? Data(contentsOf: file)) == first,
              "Repeat Export reuses the saved format and encoder settings")

        var failureReturned = false, refusedWrite = false
        let mismatched = work.appendingPathComponent("mismatched.png")
        document.export(to: mismatched, settings: form.settings) { error in
            refusedWrite = error != nil
            failureReturned = true
        }
        wait { failureReturned && document.pendingWork == 0 }
        check(refusedWrite && !FileManager.default.fileExists(atPath: mismatched.path)
              && remembersDestination() && document.lastExportSettings == form.settings,
              "a failed export preserves the previous destination and settings")

        controller.exportDocument(nil)
        wait { controller.window?.attachedSheet != nil }
        if let cancelled = controller.window?.attachedSheet as? NSSavePanel,
           let draft = cancelled.accessoryView as? ExportOptionsForm {
            check(draft.settings == form.settings, "the next export sheet restores the successful options")
            draft.selectFormat(.tiff)
            cancelled.cancel(nil)
            wait { controller.window?.attachedSheet == nil }
            check(document.lastExportSettings == form.settings,
                  "cancelling a changed export draft preserves the repeat-export settings")
        } else { check(false, "the next Export opens a native sheet") }
        check(try session.copyPixels(image, merged: true).pixels == original,
              "configured export preserves the source pixels")
        check(try session.undoInfo(image).undoCount == undo,
              "configured export does not add an editing Undo step")
        check(document.hasUnsavedChanges == dirty,
              "exporting does not mark the document saved")
    }
}
