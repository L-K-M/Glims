import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// Real chooser buttons and counted document writes against disposable data.
    static func exerciseResourceManagement(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let end = Date().addingTimeInterval(12)
            while !condition() && Date() < end { spin(0.01) }
        }
        func views<T: NSView>(_ root: NSView?, _ type: T.Type) -> [T] {
            guard let root else { return [] }
            return ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views($0, type) }
        }
        func button(_ root: NSView?, _ label: String) -> NSButton? {
            views(root, NSButton.self).first { $0.accessibilityLabel() == label }
        }
        func panel(_ title: String) -> NSWindow? { NSApp.windows.first { $0.isVisible && $0.title == title } }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}; wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }; spin()
        }
        let image = try session.newImage(width: 24, height: 24)
        let otherImage = try session.newImage(width: 24, height: 24)
        let document = try ImageDocument(session: session, image: image, name: "Manage A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Manage B")
        documents.items += [document, other]
        let host = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        host.showWindow(nil); front.showWindow(nil)
        let pixels = try session.copyPixels(image, merged: true).pixels
        let otherPixels = try session.copyPixels(otherImage, merged: true).pixels
        let undo = document.undoInfo.undoCount
        let oldBrush = ToolState.shared.brush(for: .paintbrush).resource
        let oldGradient = ToolState.shared.gradientResource
        defer {
            BrushChooser.shared.close(); GradientChooser.shared.close()
            ToolState.shared.setBrushResource(oldBrush, for: .paintbrush)
            ToolState.shared.setGradientResource(oldGradient)
            for window in [host.window, front.window] { window?.orderOut(nil) }
            for doc in [document, other] where !doc.isClosing {
                var closed = false; doc.closeImageWhenDrained { closed = true }; wait { closed }
            }
            documents.items.removeAll { $0 === document || $0 === other }
        }
        for kind in EngineSession.ResourceKind.allCases {
            let source = try session.resources(kind).first!
            let original = try session.duplicateResource(source.id, name: "Manage \(kind.singular)")
            let identity = try session.resourceIdentifiers(original)
            var picker: PatternFillPicker?
            var pickerWindow: NSWindow?
            let root: NSView?
            switch kind {
            case .brush:
                ToolState.shared.setBrushResource(identity, for: .paintbrush)
                BrushChooser.shared.open(document: document, tool: .paintbrush)
                root = NSApp.windows.first { $0.isVisible && $0.title.hasSuffix("Brush") && $0 !== host.window && $0 !== front.window }?.contentView
            case .gradient:
                ToolState.shared.setGradientResource(identity)
                GradientChooser.shared.open(document: document); root = panel("Gradient")?.contentView
            case .pattern:
                let created = PatternFillPicker(document: document, currentIdentity: identity); picker = created
                let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 420, height: 440),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.contentView = created.view; window.makeKeyAndOrderFront(nil); pickerWindow = window
                created.load(); root = created.view
            }
            if kind == .brush && ProcessInfo.processInfo.environment["GLIMS_RESOURCE_INFO_FAULT"] == "1" {
                wait { button(root, "Retry resource capabilities")?.isHidden == false }
                check(button(root, "Rename selected resource")?.isEnabled == false,
                      "a failed capability read keeps resource writes disabled")
                button(root, "Retry resource capabilities")?.performClick(nil)
            }
            wait { button(root, "Rename selected resource")?.isEnabled == true }
            let rename = button(root, "Rename selected resource"), delete = button(root, "Delete selected resource")
            check(rename?.isEnabled == true && delete?.isEnabled == true, "\(kind.singular) chooser exposes enabled management controls for a saved user resource")
            root?.layoutSubtreeIfNeeded()
            if let rename, let delete, let root {
                check(root.bounds.contains(rename.convert(rename.bounds, to: root)) && root.bounds.contains(delete.convert(delete.bounds, to: root)),
                      "\(kind.singular) management controls fit inside the chooser")
            }
            rename?.performClick(nil)
            let title = "Rename \(kind.singular.capitalized)"
            wait { panel(title) != nil }
            let form = panel(title)
            let field = views(form?.contentView, NSTextField.self).first { $0.isEditable && $0.accessibilityLabel() == "Resource name" }
            wait { button(form?.contentView, "Rename saved resource")?.isEnabled == true }
            check(field?.stringValue == identity.name, "\(kind.singular) Rename captures the selected name")
            // Cancel must neither write nor change the chooser's committed choice.
            views(form?.contentView, NSButton.self).first { $0.title == "Cancel" }?.performClick(nil)
            settle(document)
            check(try session.resourceIdentifiers(original) == identity, "\(kind.singular) Cancel leaves the native resource unchanged")
            rename?.performClick(nil); wait { panel(title) != nil }
            let accepted = panel(title)
            let name = "Renamed \(kind.singular) é"
            let nameField = views(accepted?.contentView, NSTextField.self).first { $0.isEditable }
            nameField?.stringValue = name
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: nameField)
            wait { button(accepted?.contentView, "Rename saved resource")?.isEnabled == true }
            if kind == .brush, let collection = identity.collection {
                let path = collection.replacingOccurrences(of: "${gimp_dir}", with: work.appendingPathComponent("user").path)
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                let date = (attributes[.modificationDate] as? Date ?? Date()).addingTimeInterval(60)
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: path)
                button(accepted?.contentView, "Rename saved resource")?.performClick(nil)
                wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
                let unchanged = try session.resourceIdentifiers(original)
                check(panel(title) != nil && unchanged == identity,
                      "a stale confirmation refuses Rename and retains its draft")
                let refresh = button(accepted?.contentView, "Refresh resource capabilities")
                refresh?.performClick(nil)
                wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy && button(accepted?.contentView, "Rename saved resource")?.isEnabled == true }
                check(nameField?.stringValue == name && refresh != nil,
                      "explicit Refresh reads a new guard while preserving the name draft")
            }
            front.window?.makeKeyAndOrderFront(nil)
            button(accepted?.contentView, "Rename saved resource")?.performClick(nil)
            check(document.pendingWork > 0, "\(kind.singular) accepted Rename remains counted on captured A while B is front")
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy && panel(title) == nil }
            var renamed = try session.resourceIdentifiers(original)
            check(renamed.name == name && renamed.collection == identity.collection,
                  "\(kind.singular) Rename preserves native handle and collection and publishes the exact name")
            if kind == .brush { check(ToolState.shared.brush(for: .paintbrush).resource == renamed, "brush choice migrates to the renamed identity") }
            if kind == .gradient { check(ToolState.shared.gradientResource == renamed, "gradient choice migrates to the renamed identity") }
            if kind == .brush {
                wait { rename?.isEnabled == true }
                rename?.performClick(nil); wait { panel(title) != nil }
                let unicodeForm = panel(title)
                let unicodeField = views(unicodeForm?.contentView, NSTextField.self).first { $0.isEditable }
                unicodeField?.stringValue = "Renamed brush e\u{301}"
                NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: unicodeField)
                wait { button(unicodeForm?.contentView, "Rename saved resource")?.isEnabled == true }
                button(unicodeForm?.contentView, "Rename saved resource")?.performClick(nil)
                wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy && panel(title) == nil }
                renamed = try session.resourceIdentifiers(original)
                check(Array(renamed.name.utf8) == Array("Renamed brush e\u{301}".utf8)
                      && ToolState.shared.brush(for: .paintbrush).resource == renamed,
                      "normalization-only Rename migrates the exact native UTF-8 identity")
                check(try session.resolveResource(ToolState.shared.brush(for: .paintbrush).resource!, kind: .brush) == original,
                      "normalization-only migrated choice resolves through the native engine")
            }
            wait { delete?.isEnabled == true }
            delete?.performClick(nil)
            let deleteTitle = "Delete \(kind.singular.capitalized)"
            wait { panel(deleteTitle) != nil }
            let confirmation = panel(deleteTitle)
            wait { button(confirmation?.contentView, "Delete saved resource")?.isEnabled == true }
            check(views(confirmation?.contentView, NSTextField.self).contains { $0.stringValue.contains("Image Undo cannot restore") },
                  "\(kind.singular) Delete explains permanent removal outside image Undo")
            button(confirmation?.contentView, "Delete saved resource")?.performClick(nil)
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy && panel(deleteTitle) == nil }
            check(!(try session.resources(kind)).contains { $0.id == original }, "\(kind.singular) Delete removes the selected native row")
            if kind == .brush { check(ToolState.shared.brush(for: .paintbrush).resource == renamed, "deleting a brush preserves its missing saved choice") }
            if kind == .gradient { check(ToolState.shared.gradientResource == renamed, "deleting a gradient preserves its missing saved choice") }
            BrushChooser.shared.close(); GradientChooser.shared.close(); picker?.invalidate(); pickerWindow?.orderOut(nil)
            settle(document)
        }
        check(try session.copyPixels(image, merged: true).pixels == pixels && session.copyPixels(otherImage, merged: true).pixels == otherPixels
              && document.undoInfo.undoCount == undo, "resource management leaves both images and image Undo unchanged")
        check(document.pendingWork == 0 && other.pendingWork == 0, "all resource management reads, writes and deferred completions drain")

        // An accepted form must drain and migrate global choices after its host closes.
        let lateImage = try session.newImage(width: 8, height: 8)
        let late = try ImageDocument(session: session, image: lateImage, name: "Closing resource host")
        documents.items.append(late)
        let nativeBrush = try session.resources(.brush).first!
        let lateID = try session.duplicateResource(nativeBrush.id, name: "Close captured brush")
        let lateIdentity = try session.resourceIdentifiers(lateID)
        ToolState.shared.setBrushResource(lateIdentity, for: .paintbrush)
        let lateSource = ResourceDuplicateValidation.Source(kind: .brush, id: lateID, identity: lateIdentity)
        let lateForm = ResourceMutationFormController(document: late, source: lateSource, delete: false, hostWindow: nil)
        lateForm.show()
        wait { button(lateForm.panel.contentView, "Rename saved resource")?.isEnabled == true }
        let lateField = views(lateForm.panel.contentView, NSTextField.self).first { $0.isEditable }
        lateField?.stringValue = "Renamed after host close"
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: lateField)
        let hold = DispatchSemaphore(value: 0)
        late.inputQueue.async { _ = hold.wait(timeout: .now() + 15) }
        button(lateForm.panel.contentView, "Rename saved resource")?.performClick(nil)
        check(late.pendingWork > 0 && lateForm.isRunning, "accepted Rename is counted before host invalidation")
        lateForm.invalidate()
        var closeCount = 0
        late.closeImageWhenDrained { closeCount += 1 }
        check(closeCount == 0, "host close waits for accepted resource work")
        hold.signal(); wait { closeCount == 1 }
        let afterClose = try session.resourceIdentifiers(lateID)
        check(afterClose.name == "Renamed after host close" && ToolState.shared.brush(for: .paintbrush).resource == afterClose,
              "accepted Rename and global reference migration survive form and image close")
        check(closeCount == 1 && late.pendingWork == 0, "closed host drains exactly once with zero pending resource work")
        documents.items.removeAll { $0 === late }
    }
}
