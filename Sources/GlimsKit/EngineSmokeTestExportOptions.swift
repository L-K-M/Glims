import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseExportOptions(_ session: EngineSession, work: URL,
                                       documents: DocumentList, psd: Bool = false, cmyk: Bool = false) throws {
        func wait(seconds: TimeInterval = 20, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
        }
        let image: Int32
        if psd {
            let base = ClipboardImage(width: 32, height: 24,
                pixels: Data((0..<(32 * 24)).flatMap { _ in [UInt8(20), 180, 70, 64] }), origin: .zero)
            image = try session.newImage(pixels: base)
            let overlay = ClipboardImage(width: 16, height: 24,
                pixels: Data((0..<(16 * 24)).flatMap { _ in [UInt8(180), 30, 220, 128] }), origin: .zero)
            _ = try session.pastePixels(image, pixels: overlay, at: .zero)
        } else { image = try session.newImage(width: 32, height: 24) }
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
        if psd {
            form.selectFormat(.psd)
            form.psdLayoutPopup.selectItem(at: ExportSettings.PsdLayout.allCases.firstIndex(of: .merged)!)
            form.psdLayoutPopup.sendAction(form.psdLayoutPopup.action, to: form.psdLayoutPopup.target)
            check(form.commitEditing() && form.settings.psdLayout == .merged
                  && panel.nameFieldStringValue.hasSuffix(".psd"),
                  "the actual Export sheet captures Merged appearance and its PSD extension")
        }
        if cmyk {
            form.psdColorPopup.selectItem(at: PsdOutputColor.allCases.firstIndex(of: .cmyk)!)
            form.psdColorPopup.sendAction(form.psdColorPopup.action, to: form.psdColorPopup.target)
            check(!form.commitEditing() && form.settings.psdCmykProfile == nil,
                  "CMYK output waits for an explicit profile choice")
            wait { form.psdCmykProfilePopup.numberOfItems > 1 }
            guard form.psdCmykProfilePopup.numberOfItems > 1 else {
                return check(false, "fixture needs an installed CMYK profile")
            }
            form.psdCmykProfilePopup.selectItem(at: 1)
            form.psdCmykProfilePopup.sendAction(form.psdCmykProfilePopup.action, to: form.psdCmykProfilePopup.target)
            check(form.commitEditing() && form.settings.psdCmykProfile != nil,
                  "the actual Export sheet captures the explicitly chosen ICC bytes")
        }
        let file = work.appendingPathComponent(psd ? "native-export-options.psd" : "native-export-options.jpg")
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
        if cmyk && session.version.hasPrefix("3.3.") {
            check(exportError?.contains("development image engine") == true
                  && !FileManager.default.fileExists(atPath: file.path)
                  && document.fileState.lastExportURL == nil,
                  "development CMYK refusal publishes no file or repeat-export destination")
            check(try session.copyPixels(image, merged: true).pixels == original
                  && session.undoInfo(image).undoCount == undo && document.hasUnsavedChanges == dirty,
                  "refused CMYK output preserves source pixels, Undo and dirty state")
            return
        }
        check(exportError == nil && FileManager.default.fileExists(atPath: file.path)
              && remembersDestination() && document.lastExportSettings == form.settings,
              "accepting Export writes the image and remembers its exact settings: \(exportError ?? "ok")")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let first = try Data(contentsOf: file)
        check(psd ? first.starts(with: Data("8BPS".utf8)) :
              (first.starts(with: [0xff, 0xd8]) && first.range(of: Data([0xff, 0xc0])) != nil),
              "the actual sheet produces the requested file format")
        func checkCmykEncoding(_ bytes: Data) {
            guard cmyk else { return }
            check(bytes.count >= 26 && bytes[24] == 0 && bytes[25] == 4,
                  "the published PSD header explicitly identifies CMYK encoding")
            if let profile = form.settings.psdCmykProfile {
                check(bytes.range(of: profile.iccData) != nil,
                      "the published PSD retains the exact selected ICC profile")
            } else { check(false, "CMYK settings lost their profile") }
        }
        checkCmykEncoding(first)
        var firstReopened: Data?
        func checkMergedAppearance() throws {
            guard psd else { return }
            var captured: Result<(Int, Data), Error>?
            EngineActivity.shared.performWhenReady(label: "Checking exported PSD", work: {
                let result = Result { () throws -> (Int, Data) in
                    let reopened = try session.openImage(path: file.path)
                    defer { try? session.closeImage(reopened) }
                    return (try session.layers(reopened).count, try session.copyPixels(reopened, merged: true).pixels)
                }
                DispatchQueue.main.async { captured = result }
            })
            wait { captured != nil && !EngineActivity.shared.isBusy }
            guard let captured else { throw NSError(domain: "PSD export fixture", code: 1) }
            let (layers, pixels) = try captured.get()
            check(layers == 1, "Merged appearance exports the two source layers as one PSD layer")
            if cmyk {
                check(pixels.count == original.count && stride(from: 3, to: original.count, by: 4).allSatisfy {
                    abs(Int(pixels[$0]) - Int(original[$0])) <= 1
                }, "CMYK PSD retains partial alpha while converting the colors")
                if let firstReopened { check(pixels == firstReopened, "Repeat CMYK output reproduces its converted pixels") }
                else { firstReopened = pixels }
            } else {
                check(pixels.count == original.count && zip(pixels, original).allSatisfy { abs(Int($0) - Int($1)) <= 1 },
                      "reopened PSD retains the visible colors and partial alpha within one 8-bit level")
            }
        }
        try checkMergedAppearance()

        // Delete the output, then exercise the ordinary Cmd-E action. It
        // must repeat the successful captured request without opening a sheet.
        try FileManager.default.removeItem(at: file)
        controller.repeatExport(nil)
        wait { document.pendingWork == 0 && FileManager.default.fileExists(atPath: file.path) }
        check(controller.window?.attachedSheet == nil && (psd || (try? Data(contentsOf: file)) == first),
              "Repeat Export reuses the saved format and encoder settings")
        if cmyk { checkCmykEncoding(try Data(contentsOf: file)) }
        try checkMergedAppearance()

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
