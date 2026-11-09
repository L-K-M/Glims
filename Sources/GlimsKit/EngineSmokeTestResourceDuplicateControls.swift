import AppKit
import CGlimsEngine

/// Persistence evidence one smoke run records to the work directory: the
/// created resource's persistent identity, its facade kind and its native
/// thumbnail. No session handle is recorded — handles are local to the
/// running engine and a number can be reused after a restart.
private struct DuplicateEvidence: Codable {
    let identity: EngineSession.ResourceIdentity
    let kindRaw: UInt32
    let thumbnailWidth: Int
    let thumbnailHeight: Int
    let thumbnailPixels: String
}

@MainActor
extension EngineSmokeTest {
    /// `GLIMS_SMOKE_CASE=resource-duplicate-controls` (wired by root, also
    /// in the full suite): the Duplicate… controls of the brush chooser,
    /// the gradient chooser and the Fill sheet's embedded pattern picker,
    /// driven through their real buttons and the shared nonmodal form, with
    /// independent native catalog/thumbnail oracles. Covers captured-source
    /// retarget safety (two documents, the other window front), the Default
    /// row's refusal, inline name/duplicate-name errors with retry, Cancel,
    /// accepted-work counting with global drain and close (exactly-one
    /// completion), and ToolState/pattern-fill preferences unchanged until
    /// explicit Choose/Fill. Native writes go solely through the document's
    /// counted `duplicateResource` route (slot 131).
    static func exerciseResourceDuplicateControls(_ session: EngineSession, work: URL,
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
        func label(_ root: NSView?, _ text: String) -> String? {
            allViews(root, as: NSTextField.self).first { !$0.isEditable && $0.accessibilityLabel() == text }?.stringValue
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin()
        }
        /// One actual native catalog row (never the choosers' Default row).
        func nativeRow(_ kind: EngineSession.ResourceKind, at index: Int = 0) throws -> (EngineSession.Resource, EngineSession.ResourceIdentity, [EngineSession.Resource]) {
            try DispatchQueue.global(qos: .userInitiated).sync {
                let rows = try session.resources(kind)
                guard rows.indices.contains(index) else {
                    throw EngineSession.EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                                                     message: "The engine lists no \(kind.singular).")
                }
                return (rows[index], try session.resourceIdentifiers(rows[index].id), rows)
            }
        }
        func window(_ title: String) -> NSWindow? { NSApp.windows.first { $0.title == title && $0.isVisible } }
        // Fixtures: document A driven throughout while B's window stays front.
        let imageA = try session.newImage(width: 32, height: 32)
        let imageB = try session.newImage(width: 32, height: 32)
        let docA = try ImageDocument(session: session, image: imageA, name: "Dup A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Dup B")
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
            BrushChooser.shared.close()
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

        let brushBefore = ToolState.shared.brush(for: .paintbrush).resource
        let gradientBefore = ToolState.shared.gradientResource
        let patternBefore = PatternFillStore.shared.identity
        let undoABefore = docA.undoInfo.undoCount
        let pixelsABefore = try session.copyPixels(imageA, merged: true).pixels
        let pixelsBBefore = try session.copyPixels(imageB, merged: true).pixels
        let pasteboardCountBefore = NSPasteboard.general.changeCount
        let (brushSource, brushIdentity, brushRows) = try nativeRow(.brush)

        // Brush chooser: real Duplicate… button, Default row refused.
        BrushChooser.shared.open(document: docA, tool: .paintbrush)
        let brushPanel = window("Brush Brush")
        let brushTable = allViews(brushPanel?.contentView, as: NSTableView.self).first
        wait { (brushTable?.numberOfRows ?? 0) > 1 && !EngineActivity.shared.isBusy }
        let dupBrush = button(brushPanel?.contentView, "Duplicate brush")
        brushTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        spin(0.05)
        check(dupBrush?.isEnabled == false && dupBrush?.toolTip?.contains("not a saved resource") == true,
              "the brush Default row disables Duplicate… with the reason as tooltip")
        let sourceRow = brushRows.firstIndex { $0.id == brushSource.id }.map { $0 + 1 } ?? 1
        brushTable?.selectRowIndexes(IndexSet(integer: sourceRow), byExtendingSelection: false)
        spin(0.05)
        check(dupBrush?.isEnabled == true, "a highlighted native row enables Duplicate…")
        dupBrush?.performClick(nil)
        let form = window("Duplicate Brush")
        check(form != nil && field(form?.contentView, "Duplicate resource name") != nil
                && button(form?.contentView, "Create duplicate") != nil
                && button(form?.contentView, "Cancel duplicate") != nil,
              "the shared Duplicate… form opens as a nonmodal panel with labeled controls")
        check(label(form?.contentView, "Duplicate source")?.contains(brushSource.displayName) == true,
              "the form shows the captured source name")
        // A later table-highlight change cannot alter the captured source.
        brushTable?.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        spin(0.05)
        check(label(form?.contentView, "Duplicate source")?.contains(brushSource.displayName) == true,
              "changing the highlight after Duplicate opens cannot alter the captured source")

        // Local invalid name: inline refusal, nothing queued.
        let workBefore = docA.pendingWork
        field(form?.contentView, "Duplicate resource name")?.stringValue = "bad\u{01}name"
        button(form?.contentView, "Create duplicate")?.performClick(nil)
        spin(0.05)
        check(window("Duplicate Brush") != nil && docA.pendingWork == workBefore,
              "an invalid name is refused inline with nothing queued")

        // Accepted Create under a deterministic pause: counted, gated, published.
        field(form?.contentView, "Duplicate resource name")?.stringValue = "Dup Smoke Brush"
        let hold = DispatchSemaphore(value: 0)
        docA.inputQueue.async { _ = hold.wait(timeout: .now() + 15) }
        button(form?.contentView, "Create duplicate")?.performClick(nil)
        check(docA.pendingWork >= workBefore + 1, "the accepted duplicate is counted as pending work")
        check(button(form?.contentView, "Create duplicate")?.isEnabled == false
                && button(form?.contentView, "Cancel duplicate")?.isEnabled == false,
              "Create/Cancel are gated while the accepted write is active")
        hold.signal()
        wait { docA.pendingWork == 0 && !EngineActivity.shared.isBusy && window("Duplicate Brush") == nil }
        spin()
        let createdBrush = try session.resources(.brush).first { $0.displayName == "Dup Smoke Brush" }
        check(createdBrush != nil && createdBrush?.kind == .brush, "the brush duplicate is published under the exact name and kind")
        var createdBrushIdentity: EngineSession.ResourceIdentity?
        if let createdBrush {
            createdBrushIdentity = try session.resourceIdentifiers(createdBrush.id)
            check(try session.resolveResource(createdBrushIdentity!, kind: .brush) == createdBrush.id,
                  "the duplicate resolves by its identity")
            check(createdBrush.id != brushSource.id, "the duplicate is a distinct handle")
            let sourceThumb = try session.resourceThumbnail(brushSource.id, maxSize: 32)
            let newThumb = try session.resourceThumbnail(createdBrush.id, maxSize: 32)
            check(sourceThumb.pixels == newThumb.pixels && sourceThumb.width == newThumb.width
                    && sourceThumb.height == newThumb.height,
                  "the duplicate's native thumbnail equals the source's (payload equivalence)")
        }
        check(try session.resolveResource(brushIdentity, kind: .brush) == brushSource.id,
              "the source resource is unchanged")
        let pixelsAAfter = try session.copyPixels(imageA, merged: true).pixels
        let pixelsBAfter = try session.copyPixels(imageB, merged: true).pixels
        check(ToolState.shared.brush(for: .paintbrush).resource == brushBefore
                && docA.undoInfo.undoCount == undoABefore
                && pixelsAAfter == pixelsABefore && pixelsBAfter == pixelsBBefore,
              "no committed ToolState, history or pixels changed (A or front B) until explicit Choose")
        check(NSPasteboard.general.changeCount == pasteboardCountBefore, "the system clipboard is untouched")

        // Native duplicate-name error: inline, draft kept, retry renamed works.
        dupBrush?.performClick(nil)
        let form2 = window("Duplicate Brush")
        let beforeExpectedFailure = errorsA.count
        field(form2?.contentView, "Duplicate resource name")?.stringValue = "Dup Smoke Brush"
        button(form2?.contentView, "Create duplicate")?.performClick(nil)
        wait { docA.pendingWork == 0 && !EngineActivity.shared.isBusy }
        spin(0.05)
        check(window("Duplicate Brush") != nil
                && (label(form2?.contentView, "Duplicate message")?.isEmpty == false),
              "a duplicate name fails after acceptance and shows the native error inline")
        check(field(form2?.contentView, "Duplicate resource name")?.stringValue == "Dup Smoke Brush",
              "the draft is preserved after the native failure")
        let expectedFailureReportedOnce = errorsA.count == beforeExpectedFailure + 1
            && errorsA.last?.contains("already exists") == true
        check(expectedFailureReportedOnce, "the expected duplicate-name error is reported exactly once")
        if expectedFailureReportedOnce { errorsA.removeLast() }

        let gateReady = DispatchSemaphore(value: 0), gateHold = DispatchSemaphore(value: 0)
        _ = EngineActivity.shared.perform(label: "Dup gate hold", work: {
            gateReady.signal()
            _ = gateHold.wait(timeout: .now() + 30)
        }, completion: {})
        var gateStarted = false
        let gateDeadline = Date().addingTimeInterval(10)
        while !gateStarted && Date() < gateDeadline {
            gateStarted = gateReady.wait(timeout: .now()) == .success
            if !gateStarted { spin(0.01) }
        }
        check(gateStarted, "the unrelated busy gate is running")
        check(button(form2?.contentView, "Create duplicate")?.isEnabled == false,
              "the visible form follows document busy state without a focus bounce")

        check(label(form2?.contentView, "Duplicate message")?.isEmpty == false,
              "an unrelated busy gate preserves the native draft error")
        gateHold.signal()
        wait { !EngineActivity.shared.isBusy }
        check(button(form2?.contentView, "Create duplicate")?.isEnabled == true,
              "Create re-enables automatically when the engine becomes idle")
        field(form2?.contentView, "Duplicate resource name")?.stringValue = "Dup Smoke Brush 2"
        button(form2?.contentView, "Create duplicate")?.performClick(nil)
        wait { docA.pendingWork == 0 && window("Duplicate Brush") == nil && !EngineActivity.shared.isBusy }
        check((try? session.resources(.brush).contains { $0.displayName == "Dup Smoke Brush 2" }) == true,
              "retrying the renamed draft publishes exactly the requested resource")

        // Cancel: no mutation, catalog and preferences unchanged.
        let brushCountBeforeCancel = try session.resources(.brush).count
        dupBrush?.performClick(nil)
        let form3 = window("Duplicate Brush")
        button(form3?.contentView, "Cancel duplicate")?.performClick(nil)
        spin(0.05)
        let brushCountAfterCancel = try session.resources(.brush).count
        check(window("Duplicate Brush") == nil && brushCountAfterCancel == brushCountBeforeCancel
                && ToolState.shared.brush(for: .paintbrush).resource == brushBefore,
              "Cancel closes the form with no catalog or preference change")
        BrushChooser.shared.close()
        wait { !EngineActivity.shared.isBusy }

        // A pending Default must also survive a persisted native brush choice.
        // This panel's model provides that fixture without changing ToolState.
        let remembered = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: brushIdentity)
        let rememberedPanel = BrushChooserPanel(document: docA, model: remembered)
        rememberedPanel.showWindow(nil)
        rememberedPanel.load()
        let rememberedTable = allViews(rememberedPanel.window?.contentView, as: NSTableView.self).first
        wait { (rememberedTable?.numberOfRows ?? 0) > 1 && !EngineActivity.shared.isBusy }
        button(rememberedPanel.window?.contentView, "Duplicate brush")?.performClick(nil)
        let rememberedForm = window("Duplicate Brush")
        field(rememberedForm?.contentView, "Duplicate resource name")?.stringValue = "Dup Brush Keep Default"
        rememberedTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        spin(0.05)
        button(rememberedForm?.contentView, "Create duplicate")?.performClick(nil)
        wait { docA.pendingWork == 0 && window("Duplicate Brush") == nil && !EngineActivity.shared.isBusy }
        check(remembered.selection == .nativeDefault && rememberedTable?.selectedRow == 0,
              "explicit brush Default survives refresh despite a remembered native choice")
        check(ToolState.shared.brush(for: .paintbrush).resource == brushBefore,
              "the remembered-choice fixture never changes the committed brush preference")
        // Keep the catalog RPC behind an admitted document barrier so the
        // click definitely occurs AFTER reload captured its old highlight.
        for useDefault in [true, false] {
            settle(docA)
            rememberedTable?.selectRowIndexes(IndexSet(integer: useDefault ? sourceRow : 0), byExtendingSelection: false)
            spin(0.02)
            let release = DispatchSemaphore(value: 0)
            defer { release.signal() }
            docA.inputQueue.async { _ = release.wait(timeout: .now() + 15) }
            remembered.select(useDefault ? .resource(brushSource.id) : .nativeDefault)
            rememberedPanel.reloadAfterDuplicate()
            check(EngineActivity.shared.isBusy, "the brush refresh is admitted and paused before delivery")
            rememberedTable?.selectRowIndexes(IndexSet(integer: useDefault ? 0 : sourceRow), byExtendingSelection: false)
            let chosen = remembered.selection
            release.signal()
            wait { !EngineActivity.shared.isBusy }
            spin()
            check(remembered.selection == chosen && chosen == (useDefault ? .nativeDefault : .resource(brushSource.id)),
                  "a newer brush \(useDefault ? "Default" : "native row") click survives in-flight refresh")
        }
        rememberedPanel.dismiss()

        // The gradient/pattern controller has the same asynchronous refresh
        // route; nil is an explicit Default choice, not absence of a restore.
        for kind in [EngineSession.ResourceKind.gradient, .pattern] {
            let (row, identity, _) = try nativeRow(kind)
            let model = ResourceChooserModel(kind: kind, currentIdentity: identity)
            let picker = ResourcePickerController(document: docA, model: model)
            defer { picker.invalidate() }
            picker.load()
            wait { !EngineActivity.shared.isBusy }
            for useDefault in [true, false] {
                settle(docA)
                let release = DispatchSemaphore(value: 0)
                defer { release.signal() }
                docA.inputQueue.async { _ = release.wait(timeout: .now() + 15) }
                model.select(useDefault ? row.id : nil)
                picker.reloadCatalog()
                check(EngineActivity.shared.isBusy, "the \(kind.singular) refresh is admitted and paused")
                model.select(useDefault ? nil : row.id)
                release.signal()
                wait { !EngineActivity.shared.isBusy }
                check(model.selection == (useDefault ? nil : row.id),
                      "a newer \(kind.singular) \(useDefault ? "Default" : "native row") choice survives in-flight refresh")
            }
        }
        wait { !EngineActivity.shared.isBusy }

        // Gradient chooser: same shared form, Default row refused.
        let (gradSource, gradIdentity, gradRows) = try nativeRow(.gradient)
        GradientChooser.shared.open(document: docA)
        let gradPanel = window("Gradient")
        let gradTable = allViews(gradPanel?.contentView, as: NSTableView.self).first
        wait { (gradTable?.numberOfRows ?? 0) > 1 && !EngineActivity.shared.isBusy }
        gradTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        spin(0.05)
        check(button(gradPanel?.contentView, "Duplicate gradient")?.isEnabled == false,
              "the gradient Default row disables Duplicate…")
        let gradRow = gradRows.firstIndex { $0.id == gradSource.id }.map { $0 + 1 } ?? 1
        gradTable?.selectRowIndexes(IndexSet(integer: gradRow), byExtendingSelection: false)
        spin(0.05)
        button(gradPanel?.contentView, "Duplicate gradient")?.performClick(nil)
        let gradForm = window("Duplicate Gradient")
        check(gradForm != nil && label(gradForm?.contentView, "Duplicate source")?.contains(gradSource.displayName) == true,
              "the gradient form captures the highlighted gradient")
        field(gradForm?.contentView, "Duplicate resource name")?.stringValue = "Dup Smoke Gradient"
        button(gradForm?.contentView, "Create duplicate")?.performClick(nil)
        wait { docA.pendingWork == 0 && window("Duplicate Gradient") == nil && !EngineActivity.shared.isBusy }
        let createdGrad = try session.resources(.gradient).first { $0.displayName == "Dup Smoke Gradient" }
        let gradSourceStill = try session.resolveResource(gradIdentity, kind: .gradient)
        check(createdGrad != nil && gradSourceStill == gradSource.id,
              "the gradient duplicate is published and its source unchanged")
        if let createdGrad {
            let t1 = try session.resourceThumbnail(gradSource.id, maxSize: 32)
            let t2 = try session.resourceThumbnail(createdGrad.id, maxSize: 32)
            check(t1.pixels == t2.pixels, "the gradient duplicate's thumbnail equals the source's")
        }
        check(ToolState.shared.gradientResource == gradientBefore,
              "the gradient preference is unchanged until explicit Choose")
        check((gradTable?.selectedRow ?? 0) > 0,
              "gradient catalog refresh preserves the pending native row instead of showing Default")
        button(gradPanel?.contentView, "Duplicate gradient")?.performClick(nil)
        let defaultForm = window("Duplicate Gradient")
        field(defaultForm?.contentView, "Duplicate resource name")?.stringValue = "Dup Gradient Keep Default"
        gradTable?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        spin(0.05)
        button(defaultForm?.contentView, "Create duplicate")?.performClick(nil)
        wait { docA.pendingWork == 0 && window("Duplicate Gradient") == nil && !EngineActivity.shared.isBusy }
        check(gradTable?.selectedRow == 0
                && button(gradPanel?.contentView, "Duplicate gradient")?.isEnabled == false,
              "explicit gradient Default survives duplication refresh with no hidden resource selection")
        GradientChooser.shared.close()
        wait { !EngineActivity.shared.isBusy }

        // Embedded pattern picker inside the Fill sheet: inline Duplicate… (no nested sheet).
        let (patSource, patIdentity, patRows) = try nativeRow(.pattern)
        a.fill(nil)
        guard let sheet = a.window?.attachedSheet,
              let choice = allViews(sheet.contentView, as: NSPopUpButton.self).first
        else { return check(false, "the Fill sheet opens") }
        choice.selectItem(at: 5)
        if let action = choice.action { NSApp.sendAction(action, to: choice.target, from: choice) }
        let patTable = allViews(sheet.contentView, as: NSTableView.self).first
        wait { (patTable?.numberOfRows ?? 0) > 0 && !EngineActivity.shared.isBusy }
        let patRow = patRows.firstIndex { $0.id == patSource.id } ?? 0
        patTable?.selectRowIndexes(IndexSet(integer: patRow), byExtendingSelection: false)
        spin(0.05)
        let dupPat = button(sheet.contentView, "Duplicate pattern")
        check(dupPat?.isEnabled == true, "the embedded pattern picker enables Duplicate… on a real row")
        dupPat?.performClick(nil)
        let patForm = window("Duplicate Pattern")
        check(patForm != nil && patForm?.parent === sheet,
              "the pattern Duplicate… form is a nonmodal child of the Fill sheet, not a nested sheet")
        field(patForm?.contentView, "Duplicate resource name")?.stringValue = "Dup Smoke Pattern"
        button(patForm?.contentView, "Create duplicate")?.performClick(nil)
        wait { docA.pendingWork == 0 && window("Duplicate Pattern") == nil && !EngineActivity.shared.isBusy }
        let createdPat = try session.resources(.pattern).first { $0.displayName == "Dup Smoke Pattern" }
        let patSourceStill = try session.resolveResource(patIdentity, kind: .pattern)
        check(createdPat != nil && patSourceStill == patSource.id,
              "the pattern duplicate is published and its source unchanged")
        if let createdPat {
            let t1 = try session.resourceThumbnail(patSource.id, maxSize: 32)
            let t2 = try session.resourceThumbnail(createdPat.id, maxSize: 32)
            check(t1.pixels == t2.pixels, "the pattern duplicate's thumbnail equals the source's")
        }
        check(PatternFillStore.shared.identity == patternBefore,
              "the pattern-fill preference is unchanged until explicit Fill")
        if let sheet = a.window?.attachedSheet {
            a.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        }
        spin(0.1)

        // Accepted work drains on close with exactly-one completion; late call fails.
        let source = ResourceDuplicateValidation.Source(kind: .brush, id: brushSource.id, identity: brushIdentity)
        let drainHold = DispatchSemaphore(value: 0)
        docA.inputQueue.async { _ = drainHold.wait(timeout: .now() + 15) }
        var completions = 0
        docA.duplicateResource(source: source, name: "Dup Drain Brush") { _ in completions += 1 }
        check(docA.pendingWork > 0, "the accepted duplicate is counted before close")
        drainHold.signal()
        var closedA = false
        docA.closeImageWhenDrained { closedA = true }
        wait { closedA }
        check(completions == 1, "the completion ran exactly once through the close drain")
        check((try? session.info(imageA)) == nil, "A's image was destroyed only after the drain")
        check(try session.resources(.brush).contains { $0.displayName == "Dup Drain Brush" },
              "the drained job published the resource")
        var late: Result<ImageDocument.CreatedResource, Error>?
        let beforeClosedRefusal = errorsA.count
        docA.duplicateResource(source: source, name: "Late Dup") { late = $0 }
        check(late != nil, "a duplicate requested after close fails through its callback without crashing")
        let closedInCompletion = late.map { result in
            if case .failure(let error) = result {
                return error.localizedDescription == ImageDocument.DocumentError.closed.localizedDescription
            }
            return false
        } == true
        check(closedInCompletion && errorsA.count == beforeClosedRefusal,
              "the closed-document refusal returns through completion without a late window error")


        // Persistence evidence for the fresh-session verification (no saved handles).
        if let createdBrush, let identity = createdBrushIdentity {
            let thumb = try session.resourceThumbnail(createdBrush.id, maxSize: 32)
            let evidence = DuplicateEvidence(identity: identity, kindRaw: createdBrush.kind.rawValue,
                                             thumbnailWidth: thumb.width, thumbnailHeight: thumb.height,
                                             thumbnailPixels: thumb.pixels.base64EncodedString())
            try JSONEncoder().encode(evidence)
                .write(to: work.appendingPathComponent("resource-duplicate-evidence.json"))
            check(true, "recorded the created identity, kind and thumbnail evidence to the work dir")
        }
        check(errorsA.isEmpty, "no document errors were reported (\(errorsA))")
    }

    /// Fresh-session persistence verification — wired and run by ROOT with
    /// a genuinely fresh `EngineSession` (never this run's session; the
    /// shared smoke engine is never stopped/restarted here): verifies the
    /// persisted exact name/catalog and thumbnail through the recorded
    /// `ResourceIdentity` only — no saved handles.
    static func verifyPersistedResourceDuplicate(record: URL, session: EngineSession) throws {
        let evidence = try JSONDecoder().decode(DuplicateEvidence.self, from: Data(contentsOf: record))
        guard let kind = EngineSession.ResourceKind(rawValue: evidence.kindRaw) else {
            return check(false, "the recorded kind is a facade kind")
        }
        let rows = try session.resources(kind)
        check(rows.contains { $0.displayName == evidence.identity.name },
              "the persisted exact name is in the fresh session's catalog")
        let resolved = try session.resolveResource(evidence.identity, kind: kind)
        check(try session.resourceIdentifiers(resolved) == evidence.identity,
              "the recorded identity resolves in the fresh session")
        let thumbnail = try session.resourceThumbnail(resolved, maxSize: 32)
        check(thumbnail.width == evidence.thumbnailWidth && thumbnail.height == evidence.thumbnailHeight
                && thumbnail.pixels.base64EncodedString() == evidence.thumbnailPixels,
              "the persisted thumbnail matches the recorded evidence")
    }
}
