import AppKit
import RigiUI

@MainActor
extension EngineSmokeTest {
    /// `GLIMS_SMOKE_CASE=resource-selection-controls` (wired by root, also
    /// in the full suite): Edit ▸ Create Resource ▸ Brush/Pattern from
    /// Selection… driven through the real menu items and the real sheet
    /// controls, with independent native catalog/thumbnail/selection/pixel
    /// oracles. Covers two-document capture with the other window front,
    /// brush and pattern creation with selected-pixel oracles, soft
    /// selection below the ants threshold, invalid/duplicate names with
    /// retry, no-selection and oversized-selection gates, busy, the own-
    /// stroke end, Apply/Cancel gating while an accepted write is active,
    /// close draining with exactly-one completion, and preservation of
    /// pixels, selection, history, image identity and the system clipboard.
    static func exerciseResourceSelection(_ session: EngineSession, work: URL,
                                          documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
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
        func label(_ sheet: NSWindow?, _ accessibilityLabel: String) -> NSTextField? {
            allViews(sheet?.contentView, as: NSTextField.self)
                .first { !$0.isEditable && $0.accessibilityLabel() == accessibilityLabel }
        }
        func createItem(_ title: String) -> NSMenuItem? {
            MainMenu.make().items.first { $0.title == "Edit" }?.submenu?
                .items.first { $0.title == "Create Resource" }?.submenu?
                .items.first { $0.title == title }
        }
        func send(_ item: NSMenuItem?, to controller: DocumentWindowController) {
            if let item, let action = item.action { NSApp.sendAction(action, to: controller, from: item) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        let selection = CGRect(x: 4, y: 4, width: 8, height: 8)
        var options = EngineSession.SelectOptions()
        options.antialias = false

        // Fixtures: document A with a red 8x8 block inside the selection,
        // document B plain. B's window stays front the whole time.
        let imageA = try session.newImage(width: 32, height: 32)
        let imageB = try session.newImage(width: 32, height: 32)
        let docA = try ImageDocument(session: session, image: imageA, name: "Resource A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Resource B")
        documents.items += [docA, docB]
        let a = DocumentWindowController(document: docA)
        let b = DocumentWindowController(document: docB)
        a.showWindow(nil)
        b.showWindow(nil)
        b.window?.makeKeyAndOrderFront(nil)
        var errorsA: [String] = []
        let previousErrorA = docA.onError
        docA.onError = { message in previousErrorA?(message); errorsA.append(message) }
        defer {
            for controller in [a, b] {
                if let sheet = controller.window?.attachedSheet {
                    controller.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
                controller.window?.orderOut(nil)
            }
            for document in [docA, docB] where !document.isClosing {
                var closed = false
                document.closeImageWhenDrained { closed = true }
                wait { closed }
            }
            documents.items.removeAll { $0 === docA || $0 === docB }
        }

        docA.select(.rectangle(selection), options: options)
        settle(docA)
        docA.fill(at: .zero, mode: .selection, color: .red, threshold: 0, sampleMerged: false)
        settle(docA)
        docA.refreshSelection()
        spin()
        check(docA.selectionBounds == selection, "document A has the fixture selection")
        check(pixel(session, imageA, x: 5, y: 5).map { Array($0.prefix(3)) } == [255, 0, 0],
              "the fixture painted the selection red")
        let pixelsABefore = try session.copyPixels(imageA, merged: true).pixels
        let pixelsBBefore = try session.copyPixels(imageB, merged: true).pixels
        let undoABefore = docA.undoInfo.undoCount
        let nameABefore = docA.name

        // Observe the system clipboard generation without replacing the
        // user's contents or requesting any clipboard data.
        let pasteboard = NSPasteboard.general
        let pasteboardCountBefore = pasteboard.changeCount

        // Menu wiring: Edit ▸ Create Resource lists both items, no shortcuts,
        // on the document's own selectors; both validate with a selection.
        let brushItem = createItem("Brush from Selection…")
        let patternItem = createItem("Pattern from Selection…")
        check(brushItem != nil && patternItem != nil, "Edit ▸ Create Resource lists Brush and Pattern from Selection…")
        check(brushItem?.keyEquivalent == "" && patternItem?.keyEquivalent == "", "the create-resource items have no shortcut")
        check(brushItem?.action == #selector(DocumentWindowController.createBrushFromSelection(_:))
                && patternItem?.action == #selector(DocumentWindowController.createPatternFromSelection(_:)),
              "the items sit on the document's own selectors")
        check(a.validateMenuItem(brushItem!) && a.validateMenuItem(patternItem!),
              "both items validate with a selection while B's window is front")

        // Brush creation through A's real controls, while B is front.
        // Queue draining is checked separately, after preservation oracles.
        send(brushItem, to: a)
        let sheet = a.window?.attachedSheet
        check(sheet != nil && a.resourceSelectionSheet != nil && b.resourceSelectionSheet == nil,
              "the sheet opens on A's window, not on front window B's")
        check(editableField(sheet, "Resource name") != nil
                && button(sheet, "Apply resource creation") != nil
                && button(sheet, "Cancel resource creation") != nil,
              "the sheet shows the name field and Apply/Cancel with accessibility labels")
        check(editableField(sheet, "Brush spacing, percent")?.isHidden == false,
              "the brush sheet shows the spacing field")
        check(label(sheet, "Create resource scope")?.stringValue.contains("merged") == true,
              "the sheet explains the selected visible merged pixels scope")

        // Local invalid input keeps the sheet open, editable, nothing queued.
        let workBeforeInvalid = docA.pendingWork
        editableField(sheet, "Resource name")?.stringValue = ""
        button(sheet, "Apply resource creation")?.performClick(nil)
        spin(0.05)
        check(a.window?.attachedSheet === sheet && a.resourceSelectionSheet?.lastError != nil
                && docA.pendingWork == workBeforeInvalid,
              "an empty name is refused inline with nothing queued")
        editableField(sheet, "Resource name")?.stringValue = "bad\u{01}name"
        button(sheet, "Apply resource creation")?.performClick(nil)
        spin(0.05)
        check(a.window?.attachedSheet === sheet && docA.pendingWork == workBeforeInvalid,
              "a control character in the name is refused inline")
        editableField(sheet, "Resource name")?.stringValue = "Smoke Brush A"
        editableField(sheet, "Brush spacing, percent")?.stringValue = "0"
        button(sheet, "Apply resource creation")?.performClick(nil)
        spin(0.05)
        check(a.window?.attachedSheet === sheet && docA.pendingWork == workBeforeInvalid,
              "brush spacing 0 is refused inline")
        editableField(sheet, "Brush spacing, percent")?.stringValue = "1001"
        button(sheet, "Apply resource creation")?.performClick(nil)
        spin(0.05)
        check(a.window?.attachedSheet === sheet && docA.pendingWork == workBeforeInvalid,
              "brush spacing 1001 is refused inline")

        // Accepted Apply: counted pending work, gated buttons, own stroke ended.
        editableField(sheet, "Brush spacing, percent")?.stringValue = "25"
        settle(docA)
        let acceptHold = DispatchSemaphore(value: 0)
        docA.inputQueue.async { _ = acceptHold.wait(timeout: .now() + 15) }
        let workBeforeAccept = docA.pendingWork
        button(sheet, "Apply resource creation")?.performClick(nil)
        check(!docA.strokeIsActive, "the accept ends the document's own open stroke")
        check(docA.pendingWork >= workBeforeAccept + 1, "the accepted Apply is counted as pending work")
        check(button(sheet, "Apply resource creation")?.isEnabled == false
                && button(sheet, "Cancel resource creation")?.isEnabled == false,
              "Apply and Cancel are gated while the accepted write is active")
        acceptHold.signal()
        wait { docA.pendingWork == 0 && a.window?.attachedSheet == nil }
        spin()
        check(a.resourceSelectionSheet == nil && errorsA.isEmpty,
              "the sheet closes after the accepted write succeeds (\(errorsA))")

        // Independent native oracles: catalog membership under the exact
        // name, identity resolution, and the selected pixels as the brush.
        let created = try session.resources(.brush).first { $0.displayName == "Smoke Brush A" }
        check(created != nil, "the brush is published in the native catalog under the exact name")
        if let created {
            let identity = try session.resourceIdentifiers(created.id)
            check(try session.resolveResource(identity, kind: .brush) == created.id,
                  "the created brush resolves by its identity")
            let thumbnail = try session.resourceThumbnail(created.id, maxSize: 32)
            check(thumbnail.width == 8 && thumbnail.height == 8,
                  "the brush is exactly the selection's 8x8 bounds (\(thumbnail.width)x\(thumbnail.height))")
            let px = Array(thumbnail.pixels.prefix(4))
            check(px == [255, 0, 0, 255], "the brush pixel is the selected red opaque pixel (\(px))")
        }
        // Preservation: selection, pixels, history, identity, clipboard, and
        // the front document B were never touched.
        check(try session.selectionBounds(image: imageA) == selection && docA.selectionBounds == selection,
              "the selection (including its mask) is preserved")
        check(try session.copyPixels(imageA, merged: true).pixels == pixelsABefore, "the image pixels are preserved")
        check(docA.undoInfo.undoCount == undoABefore, "creation makes no undo step (history preserved)")
        check(docA.name == nameABefore, "the document's identity is preserved")
        check(pasteboard.changeCount == pasteboardCountBefore, "the system clipboard is untouched")
        check(try session.copyPixels(imageB, merged: true).pixels == pixelsBBefore
                && (try? session.selectionBounds(image: imageB)) == nil,
              "front document B was not captured or changed (no retarget)")

        // Duplicate name: native FAILED keeps the sheet open with the draft.
        send(brushItem, to: a)
        let dupSheet = a.window?.attachedSheet
        editableField(dupSheet, "Resource name")?.stringValue = "Smoke Brush A"
        button(dupSheet, "Apply resource creation")?.performClick(nil)
        wait { docA.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin(0.05)
        check(a.window?.attachedSheet === dupSheet && a.resourceSelectionSheet?.lastError?.contains("already exists") == true
                && errorsA.isEmpty == false,
              "a duplicate name fails after acceptance and shows the message in the open sheet (\(errorsA))")
        check(editableField(dupSheet, "Resource name")?.stringValue == "Smoke Brush A",
              "the draft is preserved after the native failure")
        check(try session.resources(.brush).filter { $0.displayName == "Smoke Brush A" }.count == 1,
              "the duplicate was never silently renamed or created twice")
        let duplicateHold = DispatchSemaphore(value: 0)
        let duplicateHeld = EngineActivity.shared.perform(label: "Another image operation",
            work: { _ = duplicateHold.wait(timeout: .now() + 15) }, completion: {})
        check(duplicateHeld && a.resourceSelectionSheet?.lastError?.contains("already exists") == true,
              "an unrelated busy gate preserves the native draft error")
        duplicateHold.signal()
        wait { !EngineActivity.shared.isBusy }
        check(a.resourceSelectionSheet?.lastError?.contains("already exists") == true,
              "ending that gate does not erase the native draft error")
        editableField(dupSheet, "Resource name")?.stringValue = "Retry Brush A"
        button(dupSheet, "Apply resource creation")?.performClick(nil)
        wait { docA.pendingWork == 0 && a.window?.attachedSheet == nil }
        check(a.resourceSelectionSheet == nil
                && (try? session.resources(.brush).contains { $0.displayName == "Retry Brush A" }) == true,
              "editing the failed draft and retrying publishes exactly the requested resource")

        // Pattern creation through its own item; its spacing field is hidden.
        send(patternItem, to: a)
        let patternSheet = a.window?.attachedSheet
        let patternSpacing = allViews(patternSheet?.contentView, as: NSTextField.self)
            .first { $0.accessibilityLabel() == "Brush spacing, percent" }
        check(patternSpacing?.isEnabled == false && patternSpacing?.isEditable == false,
              "the pattern sheet disables its unused spacing control")
        editableField(patternSheet, "Resource name")?.stringValue = "Smoke Pattern A"
        button(patternSheet, "Apply resource creation")?.performClick(nil)
        wait { docA.pendingWork == 0 && a.window?.attachedSheet == nil }
        spin()
        let createdPattern = try session.resources(.pattern).first { $0.displayName == "Smoke Pattern A" }
        check(createdPattern != nil, "the pattern is published in the native catalog")
        if let createdPattern {
            let thumbnail = try session.resourceThumbnail(createdPattern.id, maxSize: 32)
            check(thumbnail.width == 8 && thumbnail.height == 8
                    && Array(thumbnail.pixels.prefix(4)) == [255, 0, 0, 255],
                  "the pattern carries the selected 8x8 red pixels")
        }

        // No selection: cached gate disables both items with the reason as
        // tooltip, and the action opens nothing.
        docA.select(.none)
        settle(docA)
        docA.refreshSelection()
        spin()
        let errorsBeforeNoSelection = errorsA.count
        check(!a.validateMenuItem(brushItem!) && !a.validateMenuItem(patternItem!)
                && brushItem?.toolTip?.contains("no selection") == true,
              "without a selection both items disable from cache with the reason as tooltip")
        send(brushItem, to: a)
        spin(0.05)
        check(a.resourceSelectionSheet == nil && errorsA.count == errorsBeforeNoSelection + 1,
              "the action without a selection refuses with an error and opens no sheet")
        docA.select(.rectangle(selection), options: options)
        settle(docA)
        docA.refreshSelection()
        check(a.validateMenuItem(brushItem!), "the item re-enables after re-selecting")

        // Soft selection: 25%-alpha pixels selected From Alpha have native
        // bounds but no marching ants; they still count and still create.
        let softImage = try session.newImage(width: 32, height: 32)
        let softPixels = ClipboardImage(width: 8, height: 8,
            pixels: Data((0..<64).flatMap { _ in [UInt8(255), 0, 0, 64] }), origin: .zero)
        _ = try session.pastePixels(softImage, pixels: softPixels, at: CGPoint(x: 4, y: 4))
        let softDoc = try ImageDocument(session: session, image: softImage, name: "Soft Resource")
        documents.items.append(softDoc)
        let softController = DocumentWindowController(document: softDoc)
        softController.showWindow(nil)
        defer {
            softController.window?.orderOut(nil)
            if !softDoc.isClosing {
                var closed = false
                softDoc.closeImageWhenDrained { closed = true }
                wait { closed }
            }
            documents.items.removeAll { $0 === softDoc }
        }
        softDoc.select(.fromAlpha)
        settle(softDoc)
        softDoc.refreshSelection()
        spin()
        check((try? session.selectionBounds(image: softImage)) != nil && softDoc.selectionOutline.isEmpty,
              "a 25%-coverage selection has native bounds but no marching ants")
        check(softDoc.createResourceRefusal(kind: .pattern) == nil
                && softController.validateMenuItem(patternItem!),
              "a soft actual selection admits the cached gate and menu validation")
        send(patternItem, to: softController)
        let softSheet = softController.window?.attachedSheet
        editableField(softSheet, "Resource name")?.stringValue = "Soft Pattern"
        button(softSheet, "Apply resource creation")?.performClick(nil)
        wait { softDoc.pendingWork == 0 && softController.window?.attachedSheet == nil }
        spin()
        let softPattern = try session.resources(.pattern).first { $0.displayName == "Soft Pattern" }
        check(softPattern != nil, "the soft selection creates the pattern")
        if let softPattern {
            let thumbnail = try session.resourceThumbnail(softPattern.id, maxSize: 32)
            let alpha = thumbnail.pixels.count >= 4 ? thumbnail.pixels[3] : 0
            check(thumbnail.width == 8 && thumbnail.height == 8 && alpha > 0 && alpha < 255,
                  "the soft selection's below-threshold coverage lands as partial alpha (\(alpha))")
        }

        // Oversized selection: refused from cache before any allocation.
        let bigImage = try session.newImage(width: 10_001, height: 8)
        let bigDoc = try ImageDocument(session: session, image: bigImage, name: "Big Resource")
        documents.items.append(bigDoc)
        let bigController = DocumentWindowController(document: bigDoc)
        bigController.showWindow(nil)
        defer {
            bigController.window?.orderOut(nil)
            if !bigDoc.isClosing {
                var closed = false
                bigDoc.closeImageWhenDrained { closed = true }
                wait { closed }
            }
            documents.items.removeAll { $0 === bigDoc }
        }
        try session.select(.all, image: bigImage)
        settle(bigDoc)
        bigDoc.refreshSelection()
        spin()
        check(bigDoc.selectionBounds?.width == 10_001, "the fixture selected the full 10001-wide image")
        check(bigDoc.createResourceRefusal(kind: .brush)?.contains("10000") == true
                && !bigController.validateMenuItem(brushItem!)
                && brushItem?.toolTip?.contains("10000") == true,
              "a selection beyond 10000 px per side is refused from cache with the reason as tooltip")
        send(brushItem, to: bigController)
        spin(0.05)
        check(bigController.resourceSelectionSheet == nil, "the oversized selection opens no sheet (no pixels allocated)")

        // Accepted input precedes capture: the command itself ends the
        // active stroke, and resource creation adds no image Undo beyond it.
        let strokeUndoBefore = docA.undoInfo.undoCount
        let black = EngineSession.Brush(size: 6, opacity: 1, red: 0, green: 0, blue: 0, pressureSize: false)
        docA.beginStroke(at: .init(x: 6, y: 6, pressure: 1), brush: black)
        check(docA.strokeIsActive, "an accepted stroke is active before resource capture")
        var queuedCapture: Result<ImageDocument.CreatedResource, Error>?
        docA.createResourceFromSelection(kind: .pattern, name: "Queued Stroke Pattern", brushSpacing: 0) {
            queuedCapture = $0
        }
        check(!docA.strokeIsActive && docA.pendingWork > 0,
              "resource capture ends its own stroke and remains counted")
        wait { queuedCapture != nil && docA.pendingWork == 0 && !EngineActivity.shared.isBusy }
        check(docA.undoInfo.undoCount == strokeUndoBefore + 1
                && (pixel(session, imageA, x: 6, y: 6)?[0] ?? 255) < 100,
              "the accepted stroke adds one Undo and paints before resource capture")
        if let created = try session.resources(.pattern).first(where: { $0.displayName == "Queued Stroke Pattern" }) {
            let thumbnail = try session.resourceThumbnail(created.id, maxSize: 32)
            let selectedPixels = try session.copyPixels(imageA, merged: true)
            check(thumbnail.pixels == selectedPixels.pixels,
                  "the resource contains the drained stroke rather than the earlier pixels")
        } else { check(false, "the queued-input resource is published") }

        // Busy: the sheet opens while idle; a held exclusive activity then
        // disables the items from cache and refuses the open sheet's Apply
        // before acceptance, queueing nothing.
        send(brushItem, to: a)
        let busySheet = a.window?.attachedSheet
        check(busySheet != nil, "the sheet opens while idle")
        let ready = DispatchSemaphore(value: 0), releaseHold = DispatchSemaphore(value: 0)
        let held = EngineActivity.shared.perform(label: "Resource busy hold", work: {
            ready.signal()
            _ = releaseHold.wait(timeout: .now() + 30)
        }, completion: {})
        var holdStarted = false
        let holdDeadline = Date().addingTimeInterval(10)
        while !holdStarted && Date() < holdDeadline {
            holdStarted = ready.wait(timeout: .now()) == .success
            if !holdStarted { spin(0.01) }
        }
        check(held && holdStarted, "the exclusive hold is running")
        check(!a.validateMenuItem(brushItem!) && !a.validateMenuItem(patternItem!),
              "while the engine is busy both items disable from cache")
        let workBeforeBusyApply = docA.pendingWork
        editableField(busySheet, "Resource name")?.stringValue = "Busy Brush"
        button(busySheet, "Apply resource creation")?.performClick(nil)
        spin(0.05)
        check(a.window?.attachedSheet === busySheet && docA.pendingWork == workBeforeBusyApply
                && a.resourceSelectionSheet?.lastError != nil,
              "Apply while busy is refused before acceptance: nothing queued, sheet open with the reason")
        releaseHold.signal()
        wait { !EngineActivity.shared.isBusy }
        button(busySheet, "Cancel resource creation")?.performClick(nil)
        spin(0.05)
        check(try session.resources(.brush).contains(where: { $0.displayName == "Busy Brush" }) == false,
              "the busy-refused Apply created nothing")

        // Window close after acceptance: the sheet is invalidated (no stale
        // UI resurrects) and the accepted job still drains to a published
        // resource before the image is destroyed.
        try session.select(.rectangle(CGRect(x: 2, y: 2, width: 6, height: 6)), image: imageB,
                           options: options)
        settle(docB)
        docB.refreshSelection()
        send(brushItem, to: b)
        let closeSheet = b.window?.attachedSheet
        editableField(closeSheet, "Resource name")?.stringValue = "Window Close Brush"
        let closeSheetController = b.resourceSelectionSheet
        let closeHold = DispatchSemaphore(value: 0)
        docB.inputQueue.async { _ = closeHold.wait(timeout: .now() + 15) }
        button(closeSheet, "Apply resource creation")?.performClick(nil)
        check(docB.pendingWork > 0, "B's accepted write is counted before the window closes")
        var windowClosedB = false
        b.onClose = { _ in windowClosedB = true }
        b.window?.close()
        closeHold.signal()
        wait { windowClosedB }
        check(closeSheetController?.isInvalidated == true,
              "the closing window invalidated its sheet; no stale UI resurrects")
        check((try? session.info(imageB)) == nil, "B's image drained and closed")
        check(try session.resources(.brush).contains { $0.displayName == "Window Close Brush" },
              "the accepted job drained and published before the image was destroyed")

        // Close drain with exactly-one completion on A (direct document
        // call, the counting case): accepted work drains, the late call
        // fails through its callback without crashing.
        docA.select(.rectangle(selection), options: options)
        settle(docA)
        docA.refreshSelection()
        let workBeforeDrain = docA.pendingWork
        var drainCompletions = 0
        docA.createResourceFromSelection(kind: .brush, name: "Close Drain Brush", brushSpacing: 10) { _ in
            drainCompletions += 1
        }
        check(docA.pendingWork >= workBeforeDrain + 1, "the accepted creation is counted as pending work")
        var closedA = false
        docA.closeImageWhenDrained { closedA = true }
        wait { closedA }
        check(drainCompletions == 1, "the completion ran exactly once")
        check((try? session.info(imageA)) == nil, "A's image destroyed only after the drain")
        check(try session.resources(.brush).contains { $0.displayName == "Close Drain Brush" },
              "the drained job published the resource")
        var lateResult: Result<ImageDocument.CreatedResource, Error>?
        docA.createResourceFromSelection(kind: .brush, name: "Late Brush", brushSpacing: 10) { lateResult = $0 }
        check(lateResult != nil, "a creation requested after close fails through its callback without crashing")
    }
}
