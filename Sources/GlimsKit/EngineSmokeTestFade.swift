import AppKit

@MainActor
extension EngineSmokeTest {
    /// Filter ▸ Fade: offered only while a new filter Apply on a layer is
    /// the newest history step, applied as the effect's opacity in one undo
    /// step, through the real sheet, and recorded as an explicit gap.
    static func exerciseFade(_ session: EngineSession, documents: DocumentList) throws {
        var owned: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "FadeFixture", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.005) }
            try require(condition(), "fade work timed out")
        }
        func drain(_ doc: ImageDocument) throws {
            try wait { doc.pendingWork == 0 && doc.recorder.pendingCount == 0 && !EngineActivity.shared.isBusy }
        }
        func pixels(_ image: Int32) throws -> [UInt8] { [UInt8](try session.copyPixels(image, merged: true).pixels) }
        func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
            guard a.count == b.count else { return 256 }
            return zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
        }
        var bytes: [UInt8] = []
        for i in 0..<120 { bytes += [UInt8(i * 13 % 256), UInt8(i * 31 % 256), UInt8(i * 7 % 256), 255] }
        let input = ClipboardImage(width: 12, height: 10, pixels: Data(bytes), origin: .zero)
        func fixture(_ name: String) throws -> (ImageDocument, Int32) {
            let image = try session.newImage(width: 16, height: 14)
            let layer = try session.pastePixels(image, pixels: input, at: CGPoint(x: 2, y: 2))
            let doc = try ImageDocument(session: session, image: image, name: name)
            doc.onError = { _ in }
            owned.append(doc); documents.items.append(doc)
            return (doc, layer)
        }
        func blur(_ doc: ImageDocument) throws {
            var started: Result<ImageDocument.FilterPreviewStart, Error>?
            doc.beginFilterPreview(operation: EngineSession.gaussianBlurOperation, properties: []) { started = $0 }
            try drain(doc); try require(started != nil, "blur begin callback missing")
            let filter = try started!.get().filter
            for property in ["std-dev-x", "std-dev-y"] {
                var written: Result<Void, Error>?
                doc.setFilterProperty(filter, property, .number(3)) { written = $0 }
                try drain(doc); try written?.get()
            }
            var finished: Bool?
            doc.finishFilter(filter, commit: true) { finished = $0 }
            try drain(doc); try require(finished == true, "blur commit failed")
        }
        func topOpacity(_ doc: ImageDocument, _ layer: Int32) -> Double? {
            (try? session.effects(on: layer, image: doc.image))?.first?.opacity
        }
        func button(_ title: String, in view: NSView?) -> NSButton? {
            guard let view else { return nil }
            if let button = view as? NSButton, button.title == title { return button }
            return view.subviews.lazy.compactMap { button(title, in: $0) }.first
        }
        func field(in view: NSView?) -> NSTextField? {
            guard let view else { return nil }
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { field(in: $0) }.first
        }
        defer {
            for doc in owned { try? drain(doc) }
            for controller in controllers {
                if let window = controller.window, let sheet = window.attachedSheet { window.endSheet(sheet) }
                controller.window?.orderOut(nil)
                var stopped = false; controller.canvas.stopRendering { stopped = true }
                while !stopped { spin(0.01) }
            }
            for doc in owned { doc.closeImageWhenDrained() }
            try? wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            check(owned.allSatisfy { (try? session.info($0.image)) == nil }, "fade closes every owned image")
            documents.items.removeAll { doc in owned.contains { $0 === doc } }
        }

        let (doc, layer) = try fixture("Fade")
        let original = try pixels(doc.image)
        let controller = DocumentWindowController(document: doc)
        controllers.append(controller)
        let fadeItem = NSMenuItem(title: "Fade…", action: #selector(DocumentWindowController.fadeLastFilter(_:)),
                                  keyEquivalent: "")
        check(doc.fadeTarget == nil && !controller.validateMenuItem(fadeItem) && fadeItem.title == "Fade…",
              "Fade is unavailable before any filter")
        let menuFade = NSApp.mainMenu?.item(withTitle: "Filter")?.submenu?.items
            .first { $0.action == #selector(DocumentWindowController.fadeLastFilter(_:)) }
        check(menuFade?.keyEquivalent == "f" && menuFade?.keyEquivalentModifierMask == [.command, .shift],
              "Filter ▸ Fade… uses Shift-Command-F")

        try blur(doc)
        let blurred = try pixels(doc.image)
        let undoAfterBlur = doc.undoInfo.undoCount
        guard let target = doc.fadeTarget else { return check(false, "a layer filter Apply offers Fade") }
        check(target.layer == layer && !target.title.isEmpty, "Fade targets the filtered layer (\(target.title))")
        check(controller.validateMenuItem(fadeItem) && fadeItem.title == "Fade \(target.title)…",
              "the Fade item names the filter (\(fadeItem.title))")
        check(maxDifference(blurred, original) > 8, "the blur fixture changes the pixels")

        doc.fade(target, opacity: 0.4)
        try drain(doc)
        check(abs((topOpacity(doc, layer) ?? -1) - 0.4) < 0.001, "Fade sets the filter effect's opacity")
        check(doc.undoInfo.undoCount == undoAfterBlur + 1, "Fade is one undo step")
        let faded = try pixels(doc.image)
        check(maxDifference(faded, blurred) > 0 && maxDifference(faded, original) > 0,
              "a partial Fade blends the result with the original")
        check(doc.fadeTarget == nil, "Fade is not offered again on its own result")

        try session.undo(doc.image); try doc.reload()
        check(doc.fadeTarget == target && abs((topOpacity(doc, layer) ?? -1) - 1) < 0.001,
              "undoing Fade restores the filter and offers Fade again")
        doc.fade(target, opacity: 0)
        try drain(doc)
        check(maxDifference(try pixels(doc.image), original) <= 1, "Fade to 0% shows the layer as it was")
        try session.undo(doc.image); try doc.reload()

        // The real sheet: Cancel changes nothing, OK applies the field.
        controller.showWindow(nil)
        guard let window = controller.window else { return check(false, "fade fixture has a window") }
        let blocker = NSAlert()
        blocker.messageText = "Blocking sheet"
        blocker.beginSheetModal(for: window) { _ in }
        try wait { window.attachedSheet != nil }
        controller.fadeLastFilter(nil)
        spin(0.1)
        check(window.sheets.count == 1 && window.attachedSheet === blocker.window,
              "Fade presents nothing while another sheet is attached")
        window.endSheet(blocker.window)
        try wait { window.attachedSheet == nil }

        controller.fadeLastFilter(nil)
        try wait { window.attachedSheet != nil }
        let cancel = button("Cancel", in: window.attachedSheet?.contentView)
        check(cancel != nil, "the Fade sheet has Cancel")
        cancel?.performClick(nil)
        try wait { window.attachedSheet == nil }
        try drain(doc)
        check(doc.undoInfo.undoCount == undoAfterBlur && abs((topOpacity(doc, layer) ?? -1) - 1) < 0.001,
              "cancelling the Fade sheet changes nothing")

        controller.fadeLastFilter(nil)
        try wait { window.attachedSheet != nil }
        let sheet = window.attachedSheet
        let opacityField = field(in: sheet?.contentView)
        check(opacityField?.stringValue == "100", "the Fade sheet starts at the effect's opacity")
        opacityField?.stringValue = "55"
        button("OK", in: sheet?.contentView)?.performClick(nil)
        try wait { window.attachedSheet == nil }
        try drain(doc)
        check(abs((topOpacity(doc, layer) ?? -1) - 0.55) < 0.001 && doc.undoInfo.undoCount == undoAfterBlur + 1,
              "the Fade sheet's OK applies its opacity as one step")
        try session.undo(doc.image); try doc.reload()

        // Another step after the filter withdraws Fade.
        doc.select(.all)
        try drain(doc)
        check(doc.fadeTarget == nil && !controller.validateMenuItem(fadeItem),
              "a later step withdraws Fade")
        try session.undo(doc.image); try doc.reload()
        check(doc.fadeTarget == target, "undoing the later step offers Fade again")

        // A stale target is refused.
        try session.undo(doc.image); try doc.reload()
        let undoBeforeStale = doc.undoInfo.undoCount
        doc.fade(target, opacity: 0.5)
        try drain(doc)
        check(doc.fadeTarget == nil && doc.undoInfo.undoCount == undoBeforeStale,
              "Fade refuses a target whose filter was undone")
        window.orderOut(nil)

        // While recording, Fade adds an explicit unsupported row.
        let (recorded, recordedLayer) = try fixture("Fade recording")
        try recorded.startRecording()
        try blur(recorded)
        if let recordedTarget = recorded.fadeTarget {
            recorded.fade(recordedTarget, opacity: 0.5)
            try drain(recorded)
            check(abs((topOpacity(recorded, recordedLayer) ?? -1) - 0.5) < 0.001, "Fade applies while recording")
        } else { check(false, "a recorded filter Apply still offers Fade") }
        try recorded.stopRecording(); try drain(recorded)
        let rows = recorded.recorder.records
        if rows.count == 2, case .failure(let reason)? = rows.last?.resolution {
            check(reason == ImageDocument.fadeRecordingGap, "Fade records an explicit unsupported row")
        } else { check(false, "Fade must not be silently missing from a recording (\(rows.count) rows)") }
    }
}
