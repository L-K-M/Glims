import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseNumericTransform(_ session: EngineSession, documents: DocumentList) throws {
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            let deadline = Date().addingTimeInterval(10)
            while (document.pendingWork != 0 || EngineActivity.shared.isBusy) && Date() < deadline { spin(0.01) }
            spin()
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let oldTool = ToolState.shared.current
        let oldInterpolation = ToolState.shared.transformInterpolation
        ToolState.shared.select(.transform)
        ToolState.shared.transformInterpolation = .none
        let image = try session.newImage(width: 48, height: 32)
        var bytes = [UInt8]()
        for i in 0..<48 {
            bytes.append(contentsOf: [UInt8(i * 5), UInt8(255 - i * 3), UInt8(i * 2), 255])
        }
        let pixels = Data(bytes)
        let layer = try session.pastePixels(image, pixels: ClipboardImage(width: 8, height: 6,
                                                                           pixels: pixels, origin: .zero),
                                            at: CGPoint(x: 3, y: 4))
        let document = try ImageDocument(session: session, image: image, name: "Numeric Transform")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        document.selectLayer(layer)
        settle(document)
        let options = ToolOptionsPaletteController()
        let host = NSWindow(contentRect: NSRect(x: 50, y: 90, width: 250, height: 190),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = options.view
        options.retarget(to: document)
        host.makeKeyAndOrderFront(nil)
        defer {
            host.makeFirstResponder(nil)
            host.close()
            controller.window?.close()
            documents.items.removeAll { $0 === document }
            if !document.isClosing {
                var closed = false
                document.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(10)
                while !closed && Date() < deadline { spin(0.01) }
            }
            ToolState.shared.transformInterpolation = oldInterpolation
            ToolState.shared.select(oldTool)
        }
        let views = descendants(options.view)
        func field(_ name: String) -> NSTextField? {
            views.compactMap { $0 as? NSTextField }.first { $0.accessibilityLabel() == "Transform \(name)" }
        }
        func button(_ title: String) -> NSButton? {
            views.compactMap { $0 as? NSButton }.first { $0.title == title }
        }
        func type(_ text: String, into field: NSTextField) {
            host.makeKeyAndOrderFront(nil)
            field.selectText(nil)
            guard let editor = field.currentEditor() as? NSTextView else {
                return check(false, "a real field editor accepts numeric input")
            }
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
            spin()
        }
        func key(_ character: String, code: UInt16) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: host.windowNumber, context: nil,
                                               characters: character, charactersIgnoringModifiers: character,
                                               isARepeat: false, keyCode: code) else { return }
            host.sendEvent(event)
            spin()
        }
        guard let width = field("Width"), let x = field("X"), let apply = button("Apply"),
              let cancel = button("Cancel") else { return check(false, "numeric fields and actions exist") }
        host.contentView?.layoutSubtreeIfNeeded()
        for (name, control) in [("top", x as NSView), ("actions", apply as NSView)] {
            control.scrollToVisible(control.bounds)
            options.view.layoutSubtreeIfNeeded()
            check(control.visibleRect.insetBy(dx: -1, dy: -1).contains(control.bounds),
                  "the default palette reveals its \(name) controls without clipping")
            if let path = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"],
               let bitmap = options.view.bitmapImageRepForCachingDisplay(in: options.view.bounds) {
                options.view.cacheDisplay(in: options.view.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: path).appendingPathComponent("transform-\(name).png"))
            }
        }
        check(width.isEnabled && !apply.isEnabled, "transform fields are ready before any canvas drag")
        let initialBounds = document.layers.first { $0.id == layer }!.bounds
        let initialPixels = try session.copyPixels(image, merged: true).pixels
        let undo = document.undoInfo.undoCount
        type("16", into: width)
        check(apply.isEnabled, "typing the first numeric draft enables Apply")
        key("\r", code: 36)
        check(controller.canvas.tools.transformPreview?.box.width == 16 && document.undoInfo.undoCount == undo,
              "field Return updates only the preview with no Undo step")
        type("-", into: x)
        key("\r", code: 36)
        host.makeFirstResponder(nil)
        try document.reload()
        settle(document)
        check(x.stringValue == "-", "invalid text survives focus loss and document refresh")
        apply.performClick(nil)
        settle(document)
        check(document.undoInfo.undoCount == undo && document.layers.first { $0.id == layer }?.bounds == initialBounds,
              "invalid drafts block Apply without changing pixels or bounds")
        x.selectText(nil)
        key("\u{1b}", code: 53)
        check(x.stringValue != "-" && controller.canvas.tools.transformPreview?.box.width == 16,
              "field Escape discards only its draft and keeps the pending size")
        cancel.performClick(nil)
        settle(document)
        check(controller.canvas.tools.transformSession == nil && document.undoInfo.undoCount == undo,
              "Cancel discards the numeric preview without an Undo step")
        type("16", into: width)
        apply.performClick(nil)
        settle(document)
        let transformedBounds = document.layers.first { $0.id == layer }!.bounds
        let transformedPixels = try session.copyPixels(image, merged: true).pixels
        let expectedBounds = CGRect(origin: initialBounds.origin, size: CGSize(width: 16, height: initialBounds.height))
        check(transformedBounds == expectedBounds && document.undoInfo.undoCount == undo + 1,
              "numeric-only Apply preserves origin and adds exactly one native Undo step")
        check(transformedPixels != initialPixels, "numeric Apply changes the composite")
        if let editor = width.currentEditor() as? NSTextView {
            editor.insertText("18", replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        } else {
            type("18", into: width)
        }
        key("\r", code: 36)
        check(controller.canvas.tools.transformPreview?.box.width == 18,
              "the next value after Apply belongs to the new transform lifetime")
        cancel.performClick(nil)
        document.undo()
        settle(document)
        let undonePixels = try session.copyPixels(image, merged: true).pixels
        check(document.layers.first { $0.id == layer }?.bounds == initialBounds && undonePixels == initialPixels,
              "Undo restores exact pixels and layer bounds")
        document.redo()
        settle(document)
        let redonePixels = try session.copyPixels(image, merged: true).pixels
        check(document.layers.first { $0.id == layer }?.bounds == transformedBounds && redonePixels == transformedPixels,
              "Redo restores exact transformed pixels and bounds")
        // Retarget while a genuine editor contains a draft. Neither late
        // Return nor Cancel may send it to the newly selected layer.
        type("22", into: width)
        if let other = document.layers.first(where: { $0.id != layer }) {
            document.selectLayer(other.id)
            settle(document)
            key("\r", code: 36)
            check(controller.canvas.tools.transformSession == nil,
                  "a late field commit refuses after the selected layer changes")
            cancel.performClick(nil)
            check(width.stringValue != "22", "Cancel clears the stale field draft")
        } else { check(false, "the fixture has another layer for stale-target admission") }
    }
}
