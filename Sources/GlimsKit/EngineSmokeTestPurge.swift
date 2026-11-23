import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// Edit > Purge (facade slot 253): Undo clears the active document's
    /// history only, Histories clears every open document's, and Clipboard
    /// clears the system pasteboard only while it still holds Glims's own
    /// copy. None of it changes pixels or adds a Recorder row, and the
    /// menu's confirmation is required.
    static func exercisePurge(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            spin()
            wait { document.pendingWork == 0 && document.recorder.pendingCount == 0 && !EngineActivity.shared.isBusy }
            if (try? session.info(document.image)) != nil { try? document.reload() }
        }
        func button(_ title: String, in view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap { button(title, in: $0) }.first
        }
        func edit(_ document: ImageDocument, color: NSColor) {
            var options = EngineSession.SelectOptions()
            options.operation = .replace
            options.antialias = false
            document.select(.rectangle(CGRect(x: 0, y: 0, width: 32, height: 32)), options: options)
            document.fill(at: CGPoint(x: 16, y: 16), mode: .selection, color: color,
                          threshold: 0, sampleMerged: false)
        }

        // Save and restore the user's pasteboard, like the clipboard smokes.
        let savedItems = (NSPasteboard.general.pasteboardItems ?? []).map { item in
            item.types.compactMap { type -> (NSPasteboard.PasteboardType, Data)? in
                item.data(forType: type).map { (type, $0) }
            }
        }
        func restorePasteboard() {
            NSPasteboard.general.clearContents()
            let restored = savedItems.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { NSPasteboard.general.writeObjects(restored) }
            ClipboardImage.ownedChangeCount = nil
        }

        let imageA = try session.newImage(width: 32, height: 32)
        let documentA = try ImageDocument(session: session, image: imageA, name: "Purge A")
        documents.items.append(documentA)
        let controllerA = DocumentWindowController(document: documentA)
        controllerA.showWindow(nil)
        let imageB = try session.newImage(width: 32, height: 32)
        let documentB = try ImageDocument(session: session, image: imageB, name: "Purge B")
        documents.items.append(documentB)
        let controllerB = DocumentWindowController(document: documentB)
        controllerB.showWindow(nil)
        let app = AppController(session: session)
        defer {
            controllerA.window?.orderOut(nil)
            controllerB.window?.orderOut(nil)
            var stopped = false
            controllerA.canvas.stopRendering { stopped = true }
            controllerB.canvas.stopRendering { stopped = true }
            let stopDeadline = Date().addingTimeInterval(20)
            while !stopped && Date() < stopDeadline { spin(0.01) }
            for document in [documentA, documentB] where !document.isClosing {
                var closed = false
                document.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(20)
                while !closed && Date() < deadline { spin(0.01) }
            }
            documents.items.removeAll { $0 === documentA || $0 === documentB }
            restorePasteboard()
        }

        try documentA.reload()
        try documentB.reload()
        settle(documentA)
        settle(documentB)
        edit(documentA, color: .red)
        settle(documentA)
        edit(documentB, color: .blue)
        settle(documentB)
        let undoAfterEditB = documentB.undoInfo.undoCount
        check(documentA.undoInfo.undoCount > 0 && undoAfterEditB > 0,
              "both documents have an undo step")

        guard session.supportsPurge else {
            check(true, "an older adapter has no purge slot; the smoke case is skipped")
            return
        }

        // Undo through the confirmed controller path, without the alert.
        controllerA.purgeUndoConfirmed()
        wait { !EngineActivity.shared.isBusy }
        try? documentA.reload()
        try? documentB.reload()
        check(documentA.undoInfo.undoCount == 0 && documentA.undoInfo.redoCount == 0
                && documentB.undoInfo.undoCount == undoAfterEditB,
              "Purge > Undo clears the active document's history only "
              + "(\(documentA.undoInfo.undoCount) vs \(documentB.undoInfo.undoCount))")

        // Histories clears every open document.
        app.purgeHistoriesConfirmed()
        wait { !EngineActivity.shared.isBusy }
        try? documentA.reload()
        try? documentB.reload()
        check(documentA.undoInfo.undoCount == 0 && documentB.undoInfo.undoCount == 0,
              "Purge > Histories clears every open document's history")

        // The menu action asks first: Cancel leaves the history.
        edit(documentA, color: .red)
        settle(documentA)
        let undoBeforeCancel = documentA.undoInfo.undoCount
        controllerA.window?.makeKeyAndOrderFront(nil)
        controllerA.purgeUndo(nil)
        wait { controllerA.window?.attachedSheet != nil }
        let cancel = button("Cancel", in: controllerA.window?.attachedSheet?.contentView)
        check(cancel != nil, "Purge > Undo asks for confirmation")
        cancel?.performClick(nil)
        wait { controllerA.window?.attachedSheet == nil }
        settle(documentA)
        check(documentA.undoInfo.undoCount == undoBeforeCancel,
              "cancelling Purge > Undo changes nothing")

        // Clipboard: Glims's own copy is cleared.
        let pixels = Data((0..<(8 * 8)).flatMap { _ in [UInt8(255), 0, 0, 255] })
        try ClipboardImage(width: 8, height: 8, pixels: pixels, origin: .zero).write(to: .general)
        check(ClipboardImage.clipboardIsOwned(current: NSPasteboard.general.changeCount,
                                               owned: ClipboardImage.ownedChangeCount),
              "a Glims copy marks the pasteboard as its own")
        app.purgeClipboardConfirmed()
        wait { !EngineActivity.shared.isBusy }
        check(NSPasteboard.general.availableType(from: [.png, .tiff]) == nil
                && ClipboardImage.ownedChangeCount == nil,
              "Purge > Clipboard clears Glims's own pasteboard copy")

        // Another application's data is left untouched.
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("another application", forType: .string)
        app.purgeClipboardConfirmed()
        wait { !EngineActivity.shared.isBusy }
        check(NSPasteboard.general.string(forType: .string) == "another application",
              "Purge > Clipboard leaves another application's data alone")

        // A purge is not an image edit: it adds no Recorder row.
        try documentB.startRecording()
        edit(documentB, color: .blue)
        settle(documentB)
        let rowsBeforePurge = documentB.recorder.records.count
        check(rowsBeforePurge > 0, "the recorded edit adds a row")
        app.purgeHistoriesConfirmed()
        wait { !EngineActivity.shared.isBusy }
        try? documentB.reload()
        check(documentB.recorder.records.count == rowsBeforePurge,
              "a purge adds no Recorder row")
        try documentB.stopRecording()
    }
}
