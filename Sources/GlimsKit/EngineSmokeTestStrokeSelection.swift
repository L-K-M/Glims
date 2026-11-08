import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    static func exerciseStrokeSelectionControls(_ session: EngineSession, work: URL,
                                                        documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        // Enumerates children recursively even when the root itself matches.
        func allViews<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            var found: [T] = []
            if let match = root as? T { found.append(match) }
            found += root.subviews.flatMap { allViews($0, as: type) }
            return found
        }
        func button(_ sheet: NSWindow?, _ label: String) -> NSButton? {
            allViews(sheet?.contentView, as: NSButton.self).first { $0.accessibilityLabel() == label }
        }
        func editableField(_ sheet: NSWindow?, _ label: String) -> NSTextField? {
            allViews(sheet?.contentView, as: NSTextField.self)
                .first { $0.isEditable && $0.accessibilityLabel() == label }
        }
        func messageField(_ sheet: NSWindow?) -> NSTextField? {
            allViews(sheet?.contentView, as: NSTextField.self)
                .first { !$0.isEditable && $0.accessibilityLabel() == "Stroke selection message" }
        }
        func brushLabel(_ sheet: NSWindow?) -> NSTextField? {
            allViews(sheet?.contentView, as: NSTextField.self)
                .first { !$0.isEditable && $0.accessibilityLabel() == "Captured brush name" }
        }
        func colorWell(_ sheet: NSWindow?) -> NSColorWell? {
            allViews(sheet?.contentView, as: NSColorWell.self)
                .first { $0.accessibilityLabel() == "Stroke color" }
        }
        func strokeItem() -> NSMenuItem {
            NSMenuItem(title: "Stroke Selection…",
                       action: #selector(DocumentWindowController.strokeSelection(_:)), keyEquivalent: "")
        }

        // A throwaway store so the scenario's brush choice never persists.
        let suite = "ch.lkmc.Glims.smoke.stroke-selection.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrushSelectionStore(defaults: defaults)
        let state = ToolState.shared
        let previousStore = state.brushStore
        let previousTool = state.current
        let previousForeground = state.foreground
        let previousBackground = state.background
        let previousPaintbrush = state.brush(for: .paintbrush)
        state.brushStore = store
        defer {
            state.brushStore = previousStore
            state.select(previousTool)
            state.foreground = previousForeground
            state.background = previousBackground
            state.update(.paintbrush) { $0 = previousPaintbrush }
        }

        let rows = try session.resources(.brush)
        guard let soft = rows.first(where: { $0.displayName == "2. Hardness 025" }) else {
            check(false, "the hard brush fixture exists for the capture scenario")
            return
        }
        let softIdentity = try session.resourceIdentifiers(soft.id)

        let imageA = try session.newImage(width: 32, height: 32)
        let imageB = try session.newImage(width: 32, height: 32)
        let docA = try ImageDocument(session: session, image: imageA, name: "Stroke A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Stroke B")
        documents.items += [docA, docB]
        let a = DocumentWindowController(document: docA)
        let b = DocumentWindowController(document: docB)
        a.showWindow(nil)
        b.showWindow(nil)
        var errorsA: [String] = []
        var errorsB: [String] = []
        // Chain onto the window's existing callback instead of replacing it.
        let previousErrorA = docA.onError
        docA.onError = { message in previousErrorA?(message); errorsA.append(message) }
        let previousErrorB = docB.onError
        docB.onError = { message in previousErrorB?(message); errorsB.append(message) }
        defer {
            for (controller, document) in [(a, docA), (b, docB)] {
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
                controller.window?.close()
                documents.items.removeAll { $0 === document }
                document.closeImageWhenDrained()
            }
        }

        // Non-default capture: a named brush resource, size, opacity and a
        // non-default foreground color on the current paint tool.
        state.select(.paintbrush)
        state.setBrushResource(softIdentity, for: .paintbrush)
        state.update(.paintbrush) { $0.size = 9; $0.opacity = 0.5 }
        state.foreground = .blue
        let fixturePaintbrush = state.brush(for: .paintbrush)
        check(state.brush(for: .paintbrush).resource == softIdentity
                && state.brush(for: .paintbrush).size == 9
                && state.brush(for: .paintbrush).opacity == 0.5,
              "the fixture sets a non-default brush resource, size and opacity")

        try session.select(.rectangle(CGRect(x: 4, y: 4, width: 16, height: 16)),
                           image: imageA, options: .init())
        try session.select(.rectangle(CGRect(x: 8, y: 8, width: 16, height: 16)),
                           image: imageB, options: .init())
        docA.refreshSelection()
        docB.refreshSelection()
        wait { docA.pendingWork == 0 && docB.pendingWork == 0 }
        spin()

        // Menu wiring: the item sits on the document's own selector.
        let editMenu = MainMenu.make().items.first { $0.title == "Edit" }?.submenu
        check(editMenu?.items.first { $0.title == "Stroke Selection…" }?.action
                == #selector(DocumentWindowController.strokeSelection(_:)),
              "Edit offers Stroke Selection… on the document's selector")
        check(a.validateMenuItem(strokeItem()), "the item validates with a selection and a paint target")

        // Two documents open independent sheets through the actual action.
        a.strokeSelection(nil)
        b.strokeSelection(nil)
        let sheetA = a.window?.attachedSheet
        let sheetB = b.window?.attachedSheet
        check(sheetA != nil && sheetB != nil && sheetA !== sheetB
                && a.strokeSelectionSheet != nil && a.strokeSelectionSheet !== b.strokeSelectionSheet,
              "two documents open independent Stroke Selection sheets owned by their windows")
        check(!a.validateMenuItem(strokeItem()), "the item is disabled while its sheet is open")
        for label in ["Stroke selection", "Cancel stroke selection"] {
            let control = button(sheetA, label)
            check(control != nil && control!.visibleRect.contains(control!.bounds),
                  "the entire \(label) button is visible inside the sheet")
        }
        let well = colorWell(sheetA)
        check(well != nil && well!.visibleRect.contains(well!.bounds),
              "the captured color control is fully visible inside the sheet")
        check(brushLabel(sheetA)?.stringValue == softIdentity.name,
              "the sheet shows the captured current brush resource name (\(brushLabel(sheetA)?.stringValue ?? "nil"))")
        check(editableField(sheetA, "Stroke size, pixels")?.stringValue == "9.0"
                && editableField(sheetA, "Stroke opacity, percent")?.stringValue == "50",
              "the sheet seeds size and opacity from the captured brush by value")
        let capturedWell = colorWell(sheetA)?.color.usingColorSpace(.sRGB)
        check(capturedWell != nil && capturedWell!.blueComponent > 0.9 && capturedWell!.redComponent < 0.1,
              "the color well is seeded with the captured foreground color")
        check(state.brush(for: .paintbrush) == fixturePaintbrush,
              "opening the sheets never mutates the global ToolState")

        // Cancel on B after local edits: nothing mutates anywhere.
        let undoB0 = docB.undoInfo.undoCount
        editableField(sheetB, "Stroke size, pixels")?.stringValue = "77"
        button(sheetB, "Cancel stroke selection")?.performClick(nil)
        spin(0.1)
        check(b.window?.attachedSheet == nil && b.strokeSelectionSheet == nil, "Cancel closes B's sheet")
        check(docB.undoInfo.undoCount == undoB0 && docB.pendingWork == 0 && errorsB.isEmpty,
              "Cancel mutates nothing: no undo, no queued work, no error")
        check(state.brush(for: .paintbrush) == fixturePaintbrush,
              "editing and cancelling the sheet never mutates the global ToolState")

        // Accept on A while B's window is front: the captured document and
        // settings still win.
        b.window?.makeKeyAndOrderFront(nil)
        let undoA0 = docA.undoInfo.undoCount
        let boundsA = try session.selectionBounds(image: imageA)
        let outlineA = docA.selectionOutline
        let pixelsABefore = try session.copyPixels(imageA, merged: true).pixels
        editableField(sheetA, "Stroke opacity, percent")?.stringValue = "100"
        colorWell(sheetA)?.color = .red
        button(sheetA, "Stroke selection")?.performClick(nil)
        wait { docA.pendingWork == 0 }
        spin()
        check(a.window?.attachedSheet == nil && a.strokeSelectionSheet == nil,
              "the sheet closes after one accepted enqueue")
        check(errorsA.isEmpty, "a valid accept reports no error (\(errorsA))")
        check(docA.undoInfo.undoCount == undoA0 + 1, "Stroke Selection is exactly one undo step")
        check(docB.undoInfo.undoCount == undoB0, "the other document is untouched even while its window is front")
        let boundary = pixel(session, imageA, x: 4, y: 12) ?? []
        let inside = pixel(session, imageA, x: 12, y: 12) ?? []
        let outside = pixel(session, imageA, x: 30, y: 30) ?? []
        check(boundary.count == 4 && boundary[0] > 240 && boundary[1] < 20 && boundary[2] < 20,
              "the boundary is stroked in the sheet's local color (\(boundary))")
        check(inside.count == 4 && inside.prefix(3).allSatisfy({ $0 == 255 })
                && outside.count == 4 && outside.prefix(3).allSatisfy({ $0 == 255 }),
              "the selection interior and the far outside stay untouched")
        check(try session.selectionBounds(image: imageA) == boundsA && docA.selectionOutline == outlineA,
              "the selection itself is unchanged by the stroke")
        docA.undo()
        wait { docA.pendingWork == 0 }
        spin()
        check(try session.copyPixels(imageA, merged: true).pixels == pixelsABefore,
              "undo restores the exact pixels before the stroke")
        docA.redo()
        wait { docA.pendingWork == 0 }
        spin()
        check(pixel(session, imageA, x: 4, y: 12)?.prefix(3).contains(where: { $0 < 20 }) == true,
              "redo repaints the boundary")

        // Invalid local input keeps the sheet open with an inline reason.
        a.strokeSelection(nil)
        let sheetA2 = a.window?.attachedSheet
        check(sheetA2 != nil, "the sheet reopens while a selection exists")
        let undoInv = docA.undoInfo.undoCount
        editableField(sheetA2, "Stroke size, pixels")?.stringValue = "12px"
        button(sheetA2, "Stroke selection")?.performClick(nil)
        spin(0.05)
        check(a.window?.attachedSheet === sheetA2 && a.strokeSelectionSheet?.lastError != nil
                && !(messageField(sheetA2)?.stringValue ?? "").isEmpty,
              "invalid size text keeps the sheet open with an inline reason")
        check(docA.undoInfo.undoCount == undoInv && docA.pendingWork == 0, "invalid input enqueues nothing")
        editableField(sheetA2, "Stroke opacity, percent")?.stringValue = "nan"
        button(sheetA2, "Stroke selection")?.performClick(nil)
        spin(0.05)
        check(a.window?.attachedSheet === sheetA2 && docA.undoInfo.undoCount == undoInv && docA.pendingWork == 0,
              "a non-finite opacity is refused inline and the sheet stays open")
        button(sheetA2, "Cancel stroke selection")?.performClick(nil)
        spin(0.05)

        // Gate: empty selection.
        docA.select(.none)
        wait { docA.pendingWork == 0 }
        docA.refreshSelection()
        spin()
        check(docA.selectionOutline.isEmpty && docA.strokeSelectionRefusal?.contains("no selection") == true
                && !a.validateMenuItem(strokeItem()),
              "an empty selection gates the item with a reason")
        let errorsBeforeEmpty = errorsA.count
        a.strokeSelection(nil)
        check(a.window?.attachedSheet == nil && errorsA.count > errorsBeforeEmpty,
              "opening the sheet without a selection refuses through the error path")
        try session.select(.rectangle(CGRect(x: 4, y: 4, width: 16, height: 16)),
                           image: imageA, options: .init())
        docA.refreshSelection()
        wait { docA.pendingWork == 0 }
        spin()
        check(a.validateMenuItem(strokeItem()), "the item validates again once a selection exists")

        // Gate: busy engine, held by a controlled gate released on every path.
        do {
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let held = EngineActivity.shared.perform(label: "Stroke selection busy gate",
                                                     work: { gate.wait() }, completion: {})
            check(held && docA.strokeSelectionRefusal != nil && !a.validateMenuItem(strokeItem()),
                  "a busy engine gates the item with a cached reason")
            let errorsBeforeBusy = errorsA.count
            a.strokeSelection(nil)
            check(a.window?.attachedSheet == nil && errorsA.count > errorsBeforeBusy,
                  "opening the sheet while busy refuses through the error path")
        }
        wait { !EngineActivity.shared.isBusy }
        spin(0.05)

        // Gate: busy acquired after the sheet opened — accept refuses inline.
        a.strokeSelection(nil)
        let sheetBusy = a.window?.attachedSheet
        check(sheetBusy != nil, "the sheet opens while the engine is idle")
        do {
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let held = EngineActivity.shared.perform(label: "Busy after open",
                                                     work: { gate.wait() }, completion: {})
            check(held, "the busy-after-open gate holds")
            let undoBusy = docA.undoInfo.undoCount
            button(sheetBusy, "Stroke selection")?.performClick(nil)
            spin(0.05)
            check(a.window?.attachedSheet === sheetBusy
                    && !(messageField(sheetBusy)?.stringValue ?? "").isEmpty
                    && docA.undoInfo.undoCount == undoBusy && docA.pendingWork == 0
                    && button(sheetBusy, "Stroke selection")?.isEnabled == false,
                  "accepting while the engine became busy keeps the sheet open with a reason and mutates nothing")
        }
        wait { !EngineActivity.shared.isBusy }
        spin(0.05)
        button(sheetBusy, "Cancel stroke selection")?.performClick(nil)
        spin(0.05)

        // Gate: an open filter preview (cached flag).
        docA.filterPreviewIsOpen = true
        check(docA.strokeSelectionRefusal?.contains("preview") == true && !a.validateMenuItem(strokeItem()),
              "an open filter preview gates the item")
        docA.filterPreviewIsOpen = false

        // Gates: mask, channel, group, pixel lock, editable structured source.
        guard let layerA = docA.activeLayer else {
            check(false, "the gate fixture has an active layer")
            return
        }
        docA.addMask(layerA, source: .white, edit: true)
        wait { docA.pendingWork == 0 }
        spin()
        check(docA.isMaskTargetActive && docA.strokeSelectionRefusal?.contains("mask") == true
                && !a.validateMenuItem(strokeItem()),
              "a mask target gates the item")
        docA.selectLayer(layerA)
        wait { docA.pendingWork == 0 }
        spin()

        let channel = try session.channelFromSelection(imageA, name: "Stroke gate")
        docA.selectChannel(channel)
        wait { docA.pendingWork == 0 }
        spin()
        check(docA.isChannelTargetActive && docA.strokeSelectionRefusal?.contains("channel") == true
                && !a.validateMenuItem(strokeItem()),
              "a channel target gates the item")
        docA.selectLayer(layerA)
        wait { docA.pendingWork == 0 }
        spin()

        docA.createGroup()
        wait { docA.pendingWork == 0 }
        spin()
        check(docA.activeLayer != layerA
                && docA.layers.first(where: { $0.id == docA.activeLayer ?? 0 })?.kind == .group
                && docA.strokeSelectionRefusal?.contains("group") == true
                && !a.validateMenuItem(strokeItem()),
              "a layer group target gates the item")
        docA.layerCommand(.delete)
        wait { docA.pendingWork == 0 }
        docA.selectLayer(layerA)
        wait { docA.pendingWork == 0 }
        spin()

        try session.setLayerLocks(layerA, image: imageA, mask: .pixels, values: .pixels)
        try docA.reload()
        check(docA.strokeSelectionRefusal?.contains("Unlock") == true && !a.validateMenuItem(strokeItem()),
              "a pixel-locked target gates the item")
        try session.setLayerLocks(layerA, image: imageA, mask: .pixels, values: [])
        try docA.reload()

        let text = try session.addTextLayer(image: imageA, text: "Src", settings: .init(),
                                            at: CGPoint(x: 2, y: 2))
        try session.selectLayer(text, image: imageA)
        try docA.reload()
        spin()
        check(docA.layerSources[text]?.hasSource == true && docA.layerSources[text]?.isRasterized == false,
              "the text layer's editable structured source is cached")
        check(docA.strokeSelectionRefusal?.contains("Rasterize") == true && !a.validateMenuItem(strokeItem()),
              "an editable structured source gates with a rasterize-first reason")
        let errorsBeforeStruct = errorsA.count
        let undoStruct = docA.undoInfo.undoCount
        a.strokeSelection(nil)
        check(a.window?.attachedSheet == nil && errorsA.count > errorsBeforeStruct
                && errorsA.last?.contains("Rasterize") == true && docA.undoInfo.undoCount == undoStruct,
              "the sheet refuses a structured target through the error path without mutating")
        try session.selectLayer(layerA, image: imageA)
        try docA.reload()
        wait { docA.pendingWork == 0 }
        spin()
        check(docA.strokeSelectionRefusal == nil, "the gate clears once a plain pixel layer is active again")

        // Hold this document's serial input queue without marking the
        // engine globally busy: these are accepted input commands. A fill
        // precedes a real stroke, then Stroke Selection must end that
        // stroke before its own native boundary operation.
        let undoB = docB.undoInfo.undoCount
        var strokeBrush = EngineSession.Brush()
        strokeBrush.size = 5
        strokeBrush.pressureSize = false
        let p0 = EngineSession.StrokePoint(x: 12, y: 12, pressure: 1, timeMilliseconds: 0)
        let p1 = EngineSession.StrokePoint(x: 13, y: 12, pressure: 1, timeMilliseconds: 8)
        var selectionBrush = EngineSession.Brush()
        selectionBrush.size = 12
        selectionBrush.pressureSize = false
        selectionBrush.blue = 1
        do {
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            docB.inputQueue.async { gate.wait() }
            docB.fill(at: CGPoint(x: 16, y: 16), mode: .selection, color: .green,
                      threshold: 0, sampleMerged: false)
            docB.beginStroke(at: p0, brush: strokeBrush)
            docB.continueStroke([p1])
            check(!EngineActivity.shared.isBusy && docB.pendingWork > 0 && docB.strokeIsActive,
                  "the fill and active stroke are accepted behind the document input gate")
            let pending = docB.pendingWork
            docB.strokeSelection(selectionBrush)
            check(!docB.strokeIsActive && docB.pendingWork >= pending + 2,
                  "Stroke Selection queues the active stroke end and its own operation before the gate releases")
        }
        wait { docB.pendingWork == 0 }
        spin()
        check(errorsB.isEmpty, "no BUSY refusal: the active stroke finished before the selection stroke")
        check(docB.undoInfo.undoCount == undoB + 3,
              "stroke + accepted fill + selection stroke are exactly three undo steps, in queue order")
        check(docB.undoInfo.nextUndo.contains("Stroke Selection"),
              "the selection stroke is the last undo step, behind every accepted input")
        let bInside = pixel(session, imageB, x: 16, y: 16) ?? []
        check(bInside.count == 4 && bInside[1] > 240 && bInside[0] < 20,
              "the queued accepted fill landed inside B's selection before the stroke (\(bInside))")
        let bBoundary = pixel(session, imageB, x: 8, y: 16) ?? []
        check(bBoundary.count == 4 && bBoundary[2] > bBoundary[0],
              "the selection boundary was stroked after the fill, in the stroke's color (\(bBoundary))")

        // No duplicate/reentrant acceptance: two synchronous clicks enqueue
        // exactly one stroke.
        b.strokeSelection(nil)
        let sheetDup = b.window?.attachedSheet
        let undoDup = docB.undoInfo.undoCount
        button(sheetDup, "Stroke selection")?.performClick(nil)
        button(sheetDup, "Stroke selection")?.performClick(nil)
        wait { docB.pendingWork == 0 }
        spin()
        check(docB.undoInfo.undoCount == undoDup + 1,
              "a duplicate/reentrant accept enqueues exactly one stroke")

        // Accepting with an in-flight field edit commits it once (no UI
        // reentry) and enqueues one stroke.
        b.strokeSelection(nil)
        let sheetRe = b.window?.attachedSheet
        guard let sizeField = editableField(sheetRe, "Stroke size, pixels") else {
            check(false, "the size field is reachable by its accessibility label")
            return
        }
        sheetRe?.makeFirstResponder(sizeField)
        sizeField.stringValue = "7"
        let undoRe = docB.undoInfo.undoCount
        button(sheetRe, "Stroke selection")?.performClick(nil)
        wait { docB.pendingWork == 0 }
        spin()
        check(docB.undoInfo.undoCount == undoRe + 1,
              "accepting with an in-flight field edit commits once and enqueues one stroke")

        // Late callbacks after close never reopen or update the sheet.
        b.strokeSelection(nil)
        let stale = b.strokeSelectionSheet
        if let sheet = b.window?.attachedSheet {
            b.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        spin(0.05)
        stale?.showError("late error")
        stale?.documentStateDidChange()
        stale?.commitFieldEdit()
        check(b.window?.attachedSheet == nil && b.strokeSelectionSheet == nil,
              "late callbacks after close never reopen or update the sheet")

        // Close-drain: accept, then close the document at once; the close
        // drains the accepted stroke before destroying the image.
        b.strokeSelection(nil)
        let sheetClose = b.window?.attachedSheet
        button(sheetClose, "Stroke selection")?.performClick(nil)
        var closedB = false
        docB.closeImageWhenDrained { closedB = true }
        check(docB.strokeSelectionRefusal == ImageDocument.DocumentError.closed.localizedDescription,
              "a closing document gates with the closed reason")
        wait { closedB }
        check(closedB && (try? session.info(imageB)) == nil,
              "the close drains the accepted stroke before destroying the image")
        check(errorsB.isEmpty,
              "the whole scenario reports no error; every accept landed exactly once above (\(errorsB))")
    }
}
