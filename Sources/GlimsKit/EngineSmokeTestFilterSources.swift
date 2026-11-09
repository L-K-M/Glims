import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseFilterSources(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(15)
            while !condition() && Date() < end { spin(0.01) }
        }
        func views<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type) }
        }
        func button(_ root: NSView?, _ label: String) -> NSButton? {
            views(root, NSButton.self).first { $0.accessibilityLabel() == label || $0.title == label }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}; wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }; spin()
        }
        let host = NSWindow(contentRect: NSRect(x: 10, y: 10, width: 300, height: 200),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        defer { host.close() }
        var rows = [FilterSourceChoice(id: 11, name: "Same"), .init(id: 22, name: "Same"),
                    .init(id: 11, name: "Duplicate ID"), .init(id: 0, name: "Invalid")]
        var refusal: String?, accepted: [Int32] = [], replies: [(Result<Void, Error>) -> Void] = [], closes = 0
        let chooser = FilterSourceChooserController(targetName: "Captured target Ω", preferredSource: 22,
            rows: { rows }, refusal: { refusal }, hostWindow: host, preview: { id, reply in accepted.append(id); replies.append(reply) })
        chooser.onClosed = { closes += 1 }; chooser.show()
        defer { chooser.invalidate() }
        let popup = views(chooser.panel.contentView, NSPopUpButton.self).first
        let preview = button(chooser.panel.contentView, "Preview Bump Map")
        check(popup?.numberOfItems == 2 && popup?.indexOfSelectedItem == 1,
              "source chooser keeps duplicate labels as distinct positive IDs and chooses the preferred source")
        refusal = "Busy fixture"; chooser.refresh()
        check(preview?.isEnabled == false, "a changed cached refusal disables Preview without a native read")
        refusal = nil; chooser.refresh()
        popup?.selectItem(at: 0)
        if let action = popup?.action { _ = NSApp.sendAction(action, to: popup?.target, from: popup) }
        preview?.performClick(nil)
        check(accepted == [11] && chooser.isRunning && popup?.isEnabled == false,
              "Preview captures the explicit source and disables changing it during accepted work")
        rows.removeAll { $0.id == 11 }; chooser.refresh()
        check(popup?.indexOfSelectedItem == 1 && popup?.selectedItem?.isEnabled == false,
              "refresh retains a disappeared captured source instead of choosing another row")
        if let first = replies.first { first(.failure(NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "Try again fixture"]))) }
        check(!chooser.isRunning && preview?.isEnabled == false,
              "a failed preview preserves the missing selection and requires an explicit replacement")
        rows = [.init(id: 11, name: "Same"), .init(id: 22, name: "Same")]; chooser.refresh()
        check(popup?.indexOfSelectedItem == 0 && preview?.isEnabled == true,
              "a returned source enables manual retry with the same explicit ID")
        preview?.performClick(nil)
        replies.first?(.success(()))
        check(chooser.isRunning && !chooser.isInvalidated && accepted == [11, 11],
              "a duplicate old completion cannot close a newer retry")
        chooser.invalidate(); chooser.invalidate()
        replies.last?(.success(()))
        check(closes == 1 && !chooser.panel.isVisible, "host invalidation closes once and drops a late accepted result")

        var initiallyEmpty: [FilterSourceChoice] = []
        let empty = FilterSourceChooserController(targetName: "Empty", preferredSource: 7,
            rows: { initiallyEmpty }, refusal: { nil }, hostWindow: host, preview: { _, _ in check(false, "an unchosen source cannot preview") })
        empty.show(); defer { empty.invalidate() }
        initiallyEmpty = [.init(id: 7, name: "Arrived later")]; empty.refresh()
        check(views(empty.panel.contentView, NSPopUpButton.self).first?.selectedItem == nil
              && button(empty.panel.contentView, "Preview Bump Map")?.isEnabled == false,
              "an empty initial catalog does not silently choose a later source")
        empty.invalidate()

        let image = try session.newImage(width: 24, height: 20)
        let otherImage = try session.newImage(width: 12, height: 12)
        let document = try ImageDocument(session: session, image: image, name: "Bump A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Bump B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        controller.showWindow(nil); front.showWindow(nil)
        controller.cancelOperation(nil)
        check(!document.filterPreviewIsOpen && document.pendingWork == 0,
              "idle Escape is harmless before a filter starts")
        defer {
            controller.cancelOperation(nil)
            for c in [controller, front] {
                c.window?.orderOut(nil)
                var stopped = false; c.canvas.stopRendering { stopped = true }; wait { stopped }
            }
            for doc in [document, other] where !doc.isClosing {
                var closed = false; doc.closeImageWhenDrained { closed = true }; wait { closed }
            }
            documents.items.removeAll { $0 === document || $0 === other }
        }
        let operations = try session.filterOperations()
        guard let operation = operations.first(where: { $0.name == "gegl:bump-map" }) else {
            return check(false, "the native catalog lists Bump Map")
        }
        let baseline = try session.undoInfo(image).undoCount
        let before = try session.copyPixels(image, merged: true).pixels
        let otherBefore = try session.copyPixels(otherImage, merged: true).pixels
        NativeFilterMenus.install(operations, in: NSApp.mainMenu!)
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] { menu.items + menu.items.flatMap { $0.submenu.map(menuItems) ?? [] } }
        let item = menuItems(NSApp.mainMenu!).first { ($0.representedObject as? NativeFilterCommand)?.operation.name == operation.name }
        check(item.map { controller.validateMenuItem($0) && $0.title == "\(operation.title)…" } == true,
              "the actual Bump Map menu item is enabled and opens a source chooser")
        if let item { controller.runNativeFilter(item) }
        let sourceWindow = NSApp.windows.first { $0.isVisible && $0.title == "Bump Map Source" }
        check(sourceWindow != nil && button(sourceWindow?.contentView, "Preview Bump Map")?.isEnabled == true,
              "the real Bump Map action offers the captured document's source list")
        button(sourceWindow?.contentView, "Cancel filter source")?.performClick(nil)
        settle(document)
        check(try session.undoInfo(image).undoCount == baseline && session.copyPixels(image, merged: true).pixels == before,
              "cancelling source selection leaves stored pixels and history unchanged")
        controller.openNativeFilter(operation)
        let acceptedSource = NSApp.windows.first { $0.isVisible && $0.title == "Bump Map Source" }
        front.window?.makeKeyAndOrderFront(nil)
        button(acceptedSource?.contentView, "Preview Bump Map")?.performClick(nil)
        wait { NSApp.windows.contains { $0.isVisible && $0.title == operation.title } && document.pendingWork == 0 }
        let previewWindow = NSApp.windows.first { $0.isVisible && $0.title == operation.title }
        check(previewWindow != nil && document.filterPreviewIsOpen && !other.filterPreviewIsOpen,
              "accepted source preview opens for captured A while B is frontmost")
        check(button(previewWindow?.contentView, "Apply to Pixels") != nil,
              "the parameter editor explicitly offers Apply to Pixels")
        button(previewWindow?.contentView, "Cancel")?.performClick(nil); settle(document)
        check(try session.undoInfo(image).undoCount == baseline && session.copyPixels(image, merged: true).pixels == before,
              "cancelling the snapshot preview leaves stored pixels and history unchanged")
        controller.openNativeFilter(operation)
        let finalSource = NSApp.windows.first { $0.isVisible && $0.title == "Bump Map Source" }
        button(finalSource?.contentView, "Preview Bump Map")?.performClick(nil)
        wait { NSApp.windows.contains { $0.isVisible && $0.title == operation.title } && document.pendingWork == 0 }
        let applyWindow = NSApp.windows.first { $0.isVisible && $0.title == operation.title }
        button(applyWindow?.contentView, "Apply to Pixels")?.performClick(nil); settle(document)
        check(try session.undoInfo(image).undoCount == baseline + 1 && !document.filterPreviewIsOpen,
              "Apply to Pixels commits exactly one native Undo and closes the preview")
        let applied = try session.copyPixels(image, merged: true).pixels
        document.undo(); settle(document)
        check(try session.copyPixels(image, merged: true).pixels == before, "Bump Map document Undo restores independent original pixels")
        document.redo(); settle(document)
        check(try session.copyPixels(image, merged: true).pixels == applied && session.copyPixels(otherImage, merged: true).pixels == otherBefore,
              "Bump Map Redo restores the applied pixels while the other document stays unchanged")
        check(document.pendingWork == 0 && other.pendingWork == 0, "all source preparation, preview and commit work drains")
    }
}
