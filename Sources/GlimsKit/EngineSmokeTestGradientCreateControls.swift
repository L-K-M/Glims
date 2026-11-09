import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// `GLIMS_SMOKE_CASE=gradient-create-controls` (wired by root, also in
    /// the full suite): Edit ▸ Create Resource ▸ Gradient… driven through
    /// the real menu item and the real sheet controls, with independent
    /// native catalog/identity readback oracles. Covers the no-selection
    /// catalog gate, two-document capture with the other window front,
    /// visible control bounds inside the panel, invalid and edge-
    /// whitespace names with inline errors and disabled Create, the
    /// accepted-create count with fields and Create/Cancel gated, the
    /// exact typed name and authored endpoint colors, duplicate-name
    /// retry, the busy gate, Cancel with no mutation, a fresh and a
    /// currently open gradient chooser seeing the created row while the
    /// pending highlight and the committed choice stay put, image pixels
    /// and undo quiet, and close draining with exactly-one completion plus
    /// a clean late refusal. Resources are uniquely named per process and
    /// the smoke engine's private HOME is already isolated per run.
    static func exerciseGradientCreateControls(_ session: EngineSession, work: URL,
                                               documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func allViews<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            let match = root as? T
            return (match.map { [$0] } ?? []) + root.subviews.flatMap { allViews($0, as: type) }
        }
        func button(_ root: NSView?, _ label: String) -> NSButton? {
            allViews(root, as: NSButton.self).first { $0.accessibilityLabel() == label }
        }
        func field(_ root: NSView?, _ label: String) -> NSTextField? {
            allViews(root, as: NSTextField.self).first { $0.isEditable && $0.accessibilityLabel() == label }
        }
        func label(_ root: NSView?, _ text: String) -> NSTextField? {
            allViews(root, as: NSTextField.self).first { !$0.isEditable && $0.accessibilityLabel() == text }
        }
        func colorWell(_ root: NSView?, _ label: String) -> NSColorWell? {
            allViews(root, as: NSColorWell.self).first { $0.accessibilityLabel() == label }
        }
        func rowTitle(_ table: NSTableView?, _ row: Int) -> String? {
            guard let table, let column = table.tableColumns.first else { return nil }
            let cell = table.delegate?.tableView?(table, viewFor: column, row: row) as? NSTableCellView
            return cell?.textField?.stringValue
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
        func textChanged(_ input: NSTextField?) {
            // The same notification the field editor posts on typing.
            guard let input else { return }
            NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: input)
        }
        /// Independent native reads run off the main thread, like the
        /// interface's own catalog work.
        func native<T>(_ read: () throws -> T) throws -> T {
            try DispatchQueue.global(qos: .userInitiated).sync(execute: read)
        }
        func components(_ color: NSColor) -> [Double] {
            guard let rgb = color.usingColorSpace(.sRGB) else { return [] }
            return [Double(rgb.redComponent), Double(rgb.greenComponent),
                    Double(rgb.blueComponent), Double(rgb.alphaComponent)]
        }
        func near(_ pixel: [UInt8], _ expected: [Int]) -> Bool {
            pixel.count == 4 && zip(pixel, expected).allSatisfy { abs(Int($0) - $1) <= 16 }
        }

        let unique = ProcessInfo.processInfo.processIdentifier
        let nameOne = "Grad Smoke \(unique)  One"
        let nameTwo = "Grad Smoke \(unique) Two"
        let nameThree = "Grad Smoke \(unique) Three"
        let busyName = "Grad Smoke \(unique) Busy"
        let cancelName = "Grad Smoke \(unique) Cancel"
        let drainName = "Grad Smoke \(unique) Drain"
        let closeName = "Grad Smoke \(unique) Close"
        let lateName = "Grad Smoke \(unique) Late"

        // Fixtures: document A driven throughout while B's window stays
        // front the whole time — nothing may retarget to the front window.
        let imageA = try session.newImage(width: 32, height: 32)
        let imageB = try session.newImage(width: 32, height: 32)
        let docA = try ImageDocument(session: session, image: imageA, name: "Gradient A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Gradient B")
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
            GradientChooser.shared.close()
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

        let gradientBefore = ToolState.shared.gradientResource
        let foregroundBefore = ToolState.shared.foreground
        let backgroundBefore = ToolState.shared.background
        let undoABefore = docA.undoInfo.undoCount
        let pixelsABefore = try session.copyPixels(imageA, merged: true).pixels
        let pixelsBBefore = try session.copyPixels(imageB, merged: true).pixels
        let pasteboardCountBefore = NSPasteboard.general.changeCount

        // Menu wiring: Edit ▸ Create Resource lists Gradient… with no
        // shortcut on the document's own selector; it validates with NO
        // selection at all (the catalog is global) while the brush item
        // still refuses.
        let gradientItem = createItem("Gradient…")
        let brushItem = createItem("Brush from Selection…")
        check(gradientItem != nil && brushItem != nil,
              "Edit ▸ Create Resource lists Gradient… next to Brush/Pattern from Selection…")
        check(gradientItem?.keyEquivalent == "", "the Gradient… item has no shortcut")
        check(gradientItem?.action == #selector(DocumentWindowController.createGradient(_:)),
              "the Gradient… item sits on the document's own selector")
        check(a.validateMenuItem(gradientItem!) && gradientItem?.toolTip == nil,
              "the gradient item validates with no selection while B's window is front")
        check(!a.validateMenuItem(brushItem!),
              "the brush item still needs a selection — the gradient gate is independent of it")

        // The sheet opens on A's captured document, not on front window B.
        send(gradientItem, to: a)
        let sheet = a.window?.attachedSheet
        check(sheet != nil && a.gradientCreateSheet != nil && b.gradientCreateSheet == nil,
              "the sheet opens on A's window, not on front window B's (captured document)")
        let nameInput = field(sheet?.contentView, "Gradient name")
        let leftInput = colorWell(sheet?.contentView, "Gradient left endpoint")
        let rightInput = colorWell(sheet?.contentView, "Gradient right endpoint")
        let create = button(sheet?.contentView, "Create gradient")
        let cancel = button(sheet?.contentView, "Cancel gradient")
        check(nameInput != nil && leftInput != nil && rightInput != nil
                && create != nil && cancel != nil
                && label(sheet?.contentView, "Gradient creation message") != nil
                && label(sheet?.contentView, "Gradient creation scope") != nil,
              "the sheet shows the name field, both endpoint wells, a preview and Create/Cancel with labels")
        // Visible control bounds: every control — and every button in
        // particular — lies inside the panel's content view (the old
        // fittingSize content-resize clipped whole button rows).
        if let content = sheet?.contentView {
            content.layoutSubtreeIfNeeded()
            for input in [nameInput, leftInput, rightInput, create, cancel].compactMap({ $0 as NSView? }) {
                let frame = input.convert(input.bounds, to: content)
                check(frame.width >= 20 && frame.height >= 12 && content.bounds.contains(frame),
                      "\(input.accessibilityLabel() ?? "gradient input") has a visible frame inside the sheet")
            }
            let views = allViews(content, as: NSView.self).filter { $0 !== content }
            let outside = views.filter {
                !content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(content.convert($0.bounds, from: $0))
            }
            for view in outside {
                print("layout diagnostic: \(type(of: view)) \(view.accessibilityLabel() ?? "") \(content.convert(view.bounds, from: view)) in \(content.bounds)")
            }
            check(outside.isEmpty, "every sheet control lies inside the panel's content bounds (\(outside.count) outside)")
            let buttonsOutside = allViews(content, as: NSButton.self).filter {
                !content.bounds.insetBy(dx: -0.5, dy: -0.5).contains(content.convert($0.bounds, from: $0))
            }
            check(buttonsOutside.isEmpty && create?.isHidden == false && cancel?.isHidden == false,
                  "every button is laid out inside the bounds and visible")
        } else {
            check(false, "the sheet has a content view")
        }
        // The wells capture the foreground/background colors as sRGB on
        // the main thread at open.
        let leftInitial = leftInput.map { components($0.color) } ?? []
        let rightInitial = rightInput.map { components($0.color) } ?? []
        let foregroundComponents = components(foregroundBefore)
        let backgroundComponents = components(backgroundBefore)
        check(leftInitial.count == 4 && zip(leftInitial, foregroundComponents).allSatisfy { abs($0 - $1) < 0.001 },
              "the left well captures the foreground color as sRGB at open")
        check(rightInitial.count == 4 && zip(rightInitial, backgroundComponents).allSatisfy { abs($0 - $1) < 0.001 },
              "the right well captures the background color as sRGB at open")

        // Invalid input: inline refusal, Create disabled, nothing queued.
        let workBeforeInvalid = docA.pendingWork
        nameInput?.stringValue = ""
        create?.performClick(nil)
        spin(0.05)
        check(a.window?.attachedSheet === sheet && a.gradientCreateSheet?.lastError != nil
                && docA.pendingWork == workBeforeInvalid,
              "an empty name is refused inline with nothing queued")
        check(create?.isEnabled == false, "an invalid draft disables Create")
        nameInput?.stringValue = " Edge Name"
        textChanged(nameInput)
        check(a.gradientCreateSheet?.lastError?.contains("start or end") == true
                && create?.isEnabled == false && docA.pendingWork == workBeforeInvalid,
              "edge whitespace is refused live with the reason inline and Create disabled")
        nameInput?.stringValue = nameOne
        textChanged(nameInput)
        check(create?.isEnabled == true && a.gradientCreateSheet?.lastError == nil,
              "a valid draft clears the inline error and enables Create")

        // Accepted Create under a deterministic pause: counted, gated,
        // then published under the exact typed name with the authored
        // endpoints; nothing else moves.
        leftInput?.color = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        rightInput?.color = NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)
        settle(docA)
        let acceptHold = DispatchSemaphore(value: 0)
        docA.inputQueue.async { _ = acceptHold.wait(timeout: .now() + 15) }
        let workBeforeAccept = docA.pendingWork
        create?.performClick(nil)
        check(docA.pendingWork >= workBeforeAccept + 1, "the accepted creation is counted as pending work")
        check(create?.isEnabled == false && cancel?.isEnabled == false
                && nameInput?.isEnabled == false && leftInput?.isEnabled == false
                && rightInput?.isEnabled == false,
              "the fields and Create/Cancel are gated while the accepted write is active")
        acceptHold.signal()
        wait { docA.pendingWork == 0 && a.window?.attachedSheet == nil && !EngineActivity.shared.isBusy }
        spin()
        check(a.gradientCreateSheet == nil && errorsA.isEmpty,
              "the sheet closes after the accepted write succeeds (\(errorsA))")

        // Independent native readback: catalog membership under the exact
        // typed name, its identity and resolution — and the thumbnail
        // renders the authored endpoints.
        let rowsOne = try native { try session.resources(.gradient) }
        let createdOne = rowsOne.first { $0.displayName == nameOne }
        var madeOne = false
        if let createdOne {
            madeOne = true
            let identity = try native { try session.resourceIdentifiers(createdOne.id) }
            let resolved = try native { try session.resolveResource(identity, kind: .gradient) }
            check(createdOne.kind == .gradient, "the created resource is a gradient")
            check(identity.name == nameOne, "the identity carries the exact typed name (interior spaces kept)")
            check(resolved == createdOne.id, "the created gradient resolves by its identity")
            let thumbnail = try native { try session.resourceThumbnail(createdOne.id, maxSize: 32) }
            check(thumbnail.width == 32 && thumbnail.height == 16,
                  "the gradient thumbnail is the contract's 32 x 16 (\(thumbnail.width) x \(thumbnail.height))")
            let leftPixel = Array(thumbnail.pixels.prefix(4))
            let rightOffset = (thumbnail.width - 1) * 4
            let rightPixel = rightOffset + 3 < thumbnail.pixels.count
                ? Array(thumbnail.pixels[rightOffset..<(rightOffset + 4)]) : []
            check(near(leftPixel, [255, 0, 0, 255]) && near(rightPixel, [0, 0, 255, 255]),
                  "the thumbnail renders the authored endpoint colors (\(leftPixel) … \(rightPixel))")
        }
        check(madeOne && nameOne.contains("  "), "the gradient is published under the exact typed name")
        let pixelsAAfterCreate = try session.copyPixels(imageA, merged: true).pixels
        let pixelsBAfterCreate = try session.copyPixels(imageB, merged: true).pixels
        check(pixelsAAfterCreate == pixelsABefore && pixelsBAfterCreate == pixelsBBefore
                && docA.undoInfo.undoCount == undoABefore && docB.pendingWork == 0,
              "creation is image-pixel and undo quiet and never touches front document B")
        check(ToolState.shared.gradientResource == gradientBefore
                && ToolState.shared.foreground == foregroundBefore
                && ToolState.shared.background == backgroundBefore,
              "the committed gradient choice and the color sources are unchanged")
        check(NSPasteboard.general.changeCount == pasteboardCountBefore, "the system clipboard is untouched")

        // Duplicate name: native FAILED after acceptance keeps the sheet
        // open with the draft for retry; the failure is reported once.
        send(gradientItem, to: a)
        let dupSheet = a.window?.attachedSheet
        let dupName = field(dupSheet?.contentView, "Gradient name")
        let dupCreate = button(dupSheet?.contentView, "Create gradient")
        dupName?.stringValue = nameOne
        let errorsBeforeDuplicate = errorsA.count
        dupCreate?.performClick(nil)
        wait { docA.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin(0.05)
        let duplicateMessage = a.gradientCreateSheet?.lastError
        check(a.window?.attachedSheet === dupSheet && duplicateMessage?.contains("already exists") == true,
              "a duplicate name fails after acceptance and shows the native error inline")
        check(dupName?.stringValue == nameOne, "the draft is preserved after the native failure")
        check(dupCreate?.isEnabled == true, "a valid retry draft keeps Create enabled")
        check(errorsA.count == errorsBeforeDuplicate + 1
                && errorsA.last?.contains("already exists") == true,
              "the expected duplicate-name failure is reported exactly once")
        if !errorsA.isEmpty { errorsA.removeLast() }
        let rowsAfterDuplicate = try native { try session.resources(.gradient) }
        let duplicateCount = rowsAfterDuplicate.filter { $0.displayName == nameOne }.count
        check(duplicateCount == 1, "the duplicate was never silently renamed or created twice")
        dupName?.stringValue = nameTwo
        dupCreate?.performClick(nil)
        wait { docA.pendingWork == 0 && a.window?.attachedSheet == nil && !EngineActivity.shared.isBusy }
        let rowsTwo = try native { try session.resources(.gradient) }
        let madeTwo = rowsTwo.contains { $0.displayName == nameTwo }
        check(madeTwo, "retrying the renamed draft publishes exactly the requested resource")

        // Busy: while an exclusive activity holds the engine, the menu
        // item disables from cache with the reason and the open sheet's
        // Create disables with the same reason; idle re-enables it and
        // Cancel closes with nothing created.
        send(gradientItem, to: a)
        let busySheet = a.window?.attachedSheet
        check(busySheet != nil, "the sheet opens while idle")
        let busyNameInput = field(busySheet?.contentView, "Gradient name")
        let busyCreate = button(busySheet?.contentView, "Create gradient")
        busyNameInput?.stringValue = busyName
        textChanged(busyNameInput)
        let ready = DispatchSemaphore(value: 0), releaseHold = DispatchSemaphore(value: 0)
        let busyHeld = EngineActivity.shared.perform(label: "Gradient create busy hold", work: {
            ready.signal()
            _ = releaseHold.wait(timeout: .now() + 30)
        }, completion: {})
        var holdStarted = false
        let holdDeadline = Date().addingTimeInterval(10)
        while !holdStarted && Date() < holdDeadline {
            holdStarted = ready.wait(timeout: .now()) == .success
            if !holdStarted { spin(0.01) }
        }
        check(busyHeld && holdStarted, "the exclusive busy hold is running")
        check(!a.validateMenuItem(gradientItem!) && gradientItem?.toolTip?.contains("Wait for it to finish") == true,
              "while the engine is busy the menu item disables from cache with the reason as tooltip")
        check(busyCreate?.isEnabled == false
                && a.gradientCreateSheet?.lastError?.contains("Wait for it to finish") == true,
              "the open sheet disables Create and shows the cached busy reason")
        releaseHold.signal()
        wait { !EngineActivity.shared.isBusy }
        spin()
        check(busyCreate?.isEnabled == true && a.gradientCreateSheet?.lastError == nil,
              "Create re-enables automatically when the engine becomes idle")
        button(busySheet?.contentView, "Cancel gradient")?.performClick(nil)
        spin(0.05)
        check(a.gradientCreateSheet == nil && docA.pendingWork == 0,
              "Cancel closes the sheet with nothing queued")
        let rowsAfterBusy = try native { try session.resources(.gradient) }
        check(!rowsAfterBusy.contains { $0.displayName == busyName },
              "the busy-gated attempt created nothing")

        // Cancel with a real draft: closes with no mutation at all.
        send(gradientItem, to: a)
        let cancelSheet = a.window?.attachedSheet
        field(cancelSheet?.contentView, "Gradient name")?.stringValue = cancelName
        button(cancelSheet?.contentView, "Cancel gradient")?.performClick(nil)
        spin(0.05)
        let rowsAfterCancel = try native { try session.resources(.gradient) }
        check(a.gradientCreateSheet == nil && docA.pendingWork == 0
                && !rowsAfterCancel.contains { $0.displayName == cancelName }
                && ToolState.shared.gradientResource == gradientBefore,
              "Cancel closes with no catalog, work or preference change")

        // A currently open gradient chooser refreshes through the focused
        // catalog reload: the created row appears while the pending
        // highlight and the committed choice stay put; a freshly opened
        // chooser lists the created gradients too.
        GradientChooser.shared.open(document: docA)
        let gradPanel = NSApp.windows.first { $0.title == "Gradient" && $0.isVisible }
        let gradTable = allViews(gradPanel?.contentView, as: NSTableView.self).first
        wait { (gradTable?.numberOfRows ?? 0) > 1 && !EngineActivity.shared.isBusy }
        gradTable?.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        spin(0.05)
        let titleBefore = rowTitle(gradTable, gradTable?.selectedRow ?? -1)
        let rowsBeforeCreate = gradTable?.numberOfRows ?? 0
        check(titleBefore != nil, "the chooser has a highlighted row before the create")
        send(gradientItem, to: a)
        let chooserSheet = a.window?.attachedSheet
        field(chooserSheet?.contentView, "Gradient name")?.stringValue = nameThree
        button(chooserSheet?.contentView, "Create gradient")?.performClick(nil)
        wait { docA.pendingWork == 0 && a.window?.attachedSheet == nil && !EngineActivity.shared.isBusy }
        wait { gradTable?.numberOfRows == rowsBeforeCreate + 1 }
        spin()
        let namesAfter = (1..<max(1, gradTable?.numberOfRows ?? 1)).compactMap { rowTitle(gradTable, $0) }
        let titleAfter = rowTitle(gradTable, gradTable?.selectedRow ?? -1)
        check(namesAfter.contains(nameThree),
              "the open chooser's refreshed catalog lists the created gradient")
        check(titleBefore != nil && titleAfter == titleBefore,
              "creation leaves the chooser's pending highlight untouched")
        check(ToolState.shared.gradientResource == gradientBefore,
              "creation never selects the new gradient or changes the committed choice")
        GradientChooser.shared.close()
        wait { !EngineActivity.shared.isBusy }
        GradientChooser.shared.open(document: docA)
        let freshTable = allViews(
            NSApp.windows.first { $0.title == "Gradient" && $0.isVisible }?.contentView,
            as: NSTableView.self).first
        wait { (freshTable?.numberOfRows ?? 0) > 1 && !EngineActivity.shared.isBusy }
        let freshNames = (1..<max(1, freshTable?.numberOfRows ?? 1)).compactMap { rowTitle(freshTable, $0) }
        check(freshNames.contains(nameThree) && freshNames.contains(nameOne),
              "a freshly opened chooser lists the created gradients")
        GradientChooser.shared.close()
        wait { !EngineActivity.shared.isBusy }

        // Closing the actual host invalidates an accepted sheet before
        // completion. The global catalog still refreshes independently.
        let hostName = closeName + " host"
        GradientChooser.shared.open(document: docB)
        let hostChooserTable = allViews(
            NSApp.windows.first { $0.title == "Gradient" && $0.isVisible }?.contentView,
            as: NSTableView.self).first
        wait { (hostChooserTable?.numberOfRows ?? 0) > 1 && !EngineActivity.shared.isBusy }
        let closeImage = try session.newImage(width: 16, height: 16)
        let closeDoc = try ImageDocument(session: session, image: closeImage, name: "Gradient close")
        documents.items.append(closeDoc)
        let closeController = DocumentWindowController(document: closeDoc)
        closeController.showWindow(nil)
        send(gradientItem, to: closeController)
        guard let closingForm = closeController.gradientCreateSheet else {
            check(false, "the close fixture opens a gradient form"); return
        }
        field(closingForm.panel.contentView, "Gradient name")?.stringValue = hostName
        let hostCloseHold = DispatchSemaphore(value: 0)
        closeDoc.inputQueue.async { _ = hostCloseHold.wait(timeout: .now() + 15) }
        button(closingForm.panel.contentView, "Create gradient")?.performClick(nil)
        check(closingForm.phase == .accepting && closeDoc.pendingWork > 0,
              "the closing host has an accepted counted gradient write")
        var hostClosed = false
        closeController.onClose = { _ in hostClosed = true }
        closeController.window?.close()
        check(closingForm.isInvalidated && closeController.gradientCreateSheet == nil,
              "host window close invalidates and releases the gradient form immediately")
        hostCloseHold.signal()
        wait { hostClosed }
        spin()
        check((try? session.info(closeImage)) == nil && !closingForm.panel.isVisible,
              "the host and form stay closed after the accepted work drains")
        let closeRows = try native { try session.resources(.gradient) }
        check(closeRows.contains { $0.displayName == hostName },
              "the accepted write still publishes after its host closes")
        wait {
            (1..<max(1, hostChooserTable?.numberOfRows ?? 1)).contains {
                rowTitle(hostChooserTable, $0) == hostName
            }
        }
        let hostVisibleNames = (1..<max(1, hostChooserTable?.numberOfRows ?? 1))
            .compactMap { rowTitle(hostChooserTable, $0) }
        check(hostVisibleNames.contains(hostName),
              "another document’s open chooser refreshes even after the creating host closes")
        GradientChooser.shared.close()
        wait { !EngineActivity.shared.isBusy }
        documents.items.removeAll { $0 === closeDoc }

        // Accepted work drains on close with exactly-one completion; the
        // late call refuses through its callback without a window error.
        settle(docA)
        let drainHold = DispatchSemaphore(value: 0)
        docA.inputQueue.async { _ = drainHold.wait(timeout: .now() + 15) }
        var completions = 0
        docA.createGradient(name: drainName,
                            left: EngineSession.RGBAColor(red: 0, green: 1, blue: 0, alpha: 1),
                            right: EngineSession.RGBAColor(red: 0, green: 0, blue: 0, alpha: 1)) { _ in
            completions += 1
        }
        check(docA.pendingWork > 0, "the accepted creation is counted as pending work before close")
        drainHold.signal()
        var closedA = false
        docA.closeImageWhenDrained { closedA = true }
        wait { closedA }
        check(completions == 1, "the completion ran exactly once through the close drain")
        let aliveA = try? session.info(imageA)
        check(aliveA == nil, "A's image was destroyed only after the drain")
        let rowsAfterDrain = try native { try session.resources(.gradient) }
        check(rowsAfterDrain.contains { $0.displayName == drainName },
              "the drained job published the resource")
        var lateResult: Result<ImageDocument.CreatedResource, Error>?
        docA.createGradient(name: lateName,
                            left: EngineSession.RGBAColor(red: 0, green: 0, blue: 0, alpha: 1),
                            right: EngineSession.RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)) { lateResult = $0 }
        check(lateResult != nil, "a creation requested after close fails through its callback without crashing")
        let lateRefused: Bool
        if case .failure(let error)? = lateResult {
            lateRefused = error.localizedDescription == ImageDocument.DocumentError.closed.localizedDescription
        } else {
            lateRefused = false
        }
        check(lateRefused, "the closed-document refusal is the explicit closed error")
        let rowsAfterLate = try native { try session.resources(.gradient) }
        check(!rowsAfterLate.contains { $0.displayName == lateName },
              "the late refusal created nothing")

        // Final quiet oracles: B untouched throughout and no document
        // error left unexamined.
        let pixelsBFinal = try session.copyPixels(imageB, merged: true).pixels
        check(pixelsBFinal == pixelsBBefore, "front document B is pixel-identical throughout")

        // Window close after acceptance: the sheet is invalidated (no
        // stale UI resurrects) and the accepted job still drains to a
        // published resource before the image is destroyed.
        send(gradientItem, to: b)
        let closeSheet = b.window?.attachedSheet
        let closeNameInput = field(closeSheet?.contentView, "Gradient name")
        let closeCreate = button(closeSheet?.contentView, "Create gradient")
        closeNameInput?.stringValue = closeName
        let closeSheetController = b.gradientCreateSheet
        let closeHold = DispatchSemaphore(value: 0)
        docB.inputQueue.async { _ = closeHold.wait(timeout: .now() + 15) }
        closeCreate?.performClick(nil)
        check(docB.pendingWork > 0, "B's accepted write is counted before the window closes")
        var windowClosedB = false
        b.onClose = { _ in windowClosedB = true }
        b.window?.close()
        closeHold.signal()
        wait { windowClosedB }
        check(closeSheetController?.isInvalidated == true,
              "the closing window invalidated its sheet; no stale UI resurrects")
        let aliveB = try? session.info(imageB)
        check(aliveB == nil, "B's image drained and closed")
        let rowsAfterClose = try native { try session.resources(.gradient) }
        check(rowsAfterClose.contains { $0.displayName == closeName },
              "the accepted job drained and published before the image was destroyed")
        check(errorsA.isEmpty, "no document errors were reported (\(errorsA))")
    }
}
