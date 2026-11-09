import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseMetadataLanguageControls(_ session: EngineSession, documents: DocumentList) throws {
        guard let fixture = ProcessInfo.processInfo.environment["GLIMS_LANGUAGE_FIXTURE"] else {
            return check(false, "language controls need their independent known XCF fixture")
        }
        // Recurse even when a parent is itself of the requested type.
        func all<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            var result = (root as? T).map { [$0] } ?? []
            for child in root.subviews { result += all(child, type) }
            return result
        }
        func button(_ panel: NSWindow, _ label: String) -> NSButton? {
            all(panel.contentView, NSButton.self).first { $0.accessibilityLabel() == label }
        }
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        let imageA = try session.openImage(path: fixture), imageB = try session.openImage(path: fixture)
        let a = try ImageDocument(session: session, image: imageA, name: "Language A")
        let b = try ImageDocument(session: session, image: imageB, name: "Language B")
        documents.items += [a, b]
        let ca = DocumentWindowController(document: a), cb = DocumentWindowController(document: b)
        ca.showWindow(nil); cb.showWindow(nil)
        var heldFilter: Int32?
        defer {
            if let heldFilter { try? session.abortFilter(heldFilter) }
            for controller in [ca, cb] {
                controller.metadataSheet?.invalidate()
                if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet) }
                controller.window?.orderOut(nil)
                var stopped = false
                controller.canvas.stopRendering { stopped = true }
                wait { stopped }
            }
            for doc in [a, b] where !doc.isClosing {
                var closed = false
                doc.closeImageWhenDrained { closed = true }
                wait { closed }
            }
            documents.items.removeAll { $0 === a || $0 === b }
        }
        ca.showMetadata(nil)
        guard let metadata = ca.metadataSheet,
              let domain = all(metadata.panel.contentView, NSPopUpButton.self).first(where: { $0.accessibilityLabel() == "Metadata domain" }),
              let tags = all(metadata.panel.contentView, NSTableView.self).first(where: { $0.accessibilityLabel() == "Metadata tag list" }) else {
            return check(false, "the actual metadata form exposes domain and tag controls")
        }
        domain.selectItem(at: 2)
        if let action = domain.action { NSApp.sendAction(action, to: domain.target, from: domain) }
        func titleRow() -> Int? {
            (0..<metadata.numberOfRows(in: tags)).first {
                metadata.tableView(tags, objectValueFor: nil, row: $0) as? String == "Xmp.dc.title"
            }
        }
        wait { titleRow() != nil }
        guard let row = titleRow() else { return check(false, "the known title is listed in the XMP domain") }
        tags.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        metadata.tableViewSelectionDidChange(Notification(name: NSTableView.selectionDidChangeNotification, object: tags))
        guard let launch = button(metadata.panel, "Edit metadata language") else {
            return check(false, "the metadata sheet exposes the dedicated language action")
        }
        wait { launch.isEnabled }
        launch.performClick(nil)
        guard let language = metadata.languageEditor else { return check(false, "the real action creates its typed editor") }
        let panel = language.panel
        guard let popup = all(panel.contentView, NSPopUpButton.self).first(where: { $0.accessibilityLabel() == "Metadata language" }),
              let editor = all(panel.contentView, NSTextView.self).first(where: { $0.accessibilityLabel() == "Metadata language text" }),
              let apply = button(panel, "Apply metadata language"),
              let close = button(panel, "Close metadata language editor") else {
            return check(false, "the typed editor exposes labeled language, text, Apply and Close controls")
        }
        wait { apply.isEnabled }
        check(panel.sheetParent === metadata.panel && panel.isVisible,
              "the language editor is attached to its captured metadata form")
        check(Set(popup.itemTitles) == Set(["x-default", "fr", "de"]),
              "only existing exact language keys from the engine are offered")
        func choose(_ key: String) {
            popup.selectItem(withTitle: key)
            if let action = popup.action { NSApp.sendAction(action, to: popup.target, from: popup) }
        }
        func text(_ value: String) {
            editor.string = value
            language.textDidChange(Notification(name: NSText.didChangeNotification, object: editor))
        }
        func settle() {
            a.inputQueue.sync {}
            wait { a.pendingWork == 0 && !EngineActivity.shared.isBusy && apply.isEnabled }
        }
        let before = try session.undoInfo(imageA)
        let originalB = try session.metadataLanguages(imageB, tag: "Xmp.dc.title")
        choose("de"); text("Unapplied German draft")
        choose("fr"); text("Bonjour 山")
        cb.window?.makeKeyAndOrderFront(nil)
        apply.performClick(nil)
        settle()
        let changed = try session.metadataLanguages(imageA, tag: "Xmp.dc.title")
        check(try changed.contains(.init(language: "fr", text: "Bonjour 山"))
                && changed.contains(.init(language: "de", text: "Hallo"))
                && session.metadataLanguages(imageB, tag: "Xmp.dc.title") == originalB
                && session.undoInfo(imageA).undoCount == before.undoCount + 1,
              "Apply changes exactly the selected language in captured A while B is frontmost, as one Undo")
        choose("de")
        check(editor.string == "Unapplied German draft", "applying French preserves an unapplied German draft")
        choose("fr")
        a.undo(); settle()
        check(editor.string == "Salut", "document Undo refreshes the selected clean language text")
        choose("de")
        check(editor.string == "Unapplied German draft", "external Undo preserves another dirty language draft")
        choose("fr")
        a.redo(); settle()
        check(editor.string == "Bonjour 山", "document Redo refreshes the selected language text")
        let noOpHistory = try session.undoInfo(imageA)
        apply.performClick(nil); settle()
        check(try session.undoInfo(imageA) == noOpHistory, "applying unchanged language text adds no Undo")
        text("")
        apply.performClick(nil)
        check(language.lastError?.contains("nonempty") == true && editor.string.isEmpty
                && (try? session.undoInfo(imageA)) == noOpHistory,
              "empty text refuses locally and retains the draft and history")
        text("Refused draft")
        if let drawable = a.activeDrawable {
            heldFilter = try session.beginFilter(image: imageA, drawable: drawable, operation: "gegl:gaussian-blur")
            apply.performClick(nil); settle()
            check(language.lastError != nil && editor.string == "Refused draft"
                    && (try? session.metadataLanguages(imageA, tag: "Xmp.dc.title")) == changed,
                  "a real native busy refusal stays visible without losing the draft or falsely updating values")
            if let filter = heldFilter { try session.abortFilter(filter); heldFilter = nil }
        } else { check(false, "the native refusal fixture has a real drawable") }
        let gate = DispatchSemaphore(value: 0)
        a.inputQueue.async { gate.wait() }
        text("Final queued text")
        apply.performClick(nil)
        close.performClick(nil)
        check(metadata.languageEditor == nil && !panel.isVisible,
              "Close invalidates the editor immediately while an accepted edit remains counted")
        gate.signal()
        a.inputQueue.sync {}
        wait { a.pendingWork == 0 }
        check((try? session.metadataLanguages(imageA, tag: "Xmp.dc.title"))?.contains(.init(language: "fr", text: "Final queued text")) == true
                && !panel.isVisible && metadata.languageEditor == nil,
              "an accepted edit completes after editor Close without reopening the form")
        wait { launch.isEnabled }
        let readGate = DispatchSemaphore(value: 0)
        a.inputQueue.async { readGate.wait() }
        launch.performClick(nil)
        let latePanel = metadata.languageEditor?.panel
        ca.window?.close()
        readGate.signal()
        wait { (try? session.info(imageA)) == nil }
        check(latePanel?.isVisible == false && ca.metadataSheet == nil,
              "host window close dismisses the child and ignores its late language-read completion")
    }
}
