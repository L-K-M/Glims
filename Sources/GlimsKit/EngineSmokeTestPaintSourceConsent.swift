import AppKit

@MainActor
extension EngineSmokeTest {
    /// Existing APIs deliberately make this case runnable before the consent gate exists.
    static func exercisePaintSourceConsent(_ session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        func wait(_ condition: () -> Bool, seconds: TimeInterval = 15) {
            let limit = Date().addingTimeInterval(seconds)
            while !condition() && Date() < limit { spin(0.01) }
        }
        func buttons(_ root: NSView?) -> [NSButton] {
            guard let root else { return [] }
            return ((root as? NSButton).map { [$0] } ?? []) + root.subviews.flatMap { buttons($0) }
        }
        func button(_ sheet: NSWindow?, _ title: String) -> NSButton? {
            buttons(sheet?.contentView).first { $0.title == title || $0.accessibilityLabel() == title }
        }

        let imageA = try session.newImage(width: 160, height: 100)
        var settings = EngineSession.TextSettings()
        settings.size = 24
        let text = try session.addTextLayer(image: imageA, text: "Consent", settings: settings,
                                            at: CGPoint(x: 12, y: 12))
        try session.selectLayer(text, image: imageA)
        let imageB = try session.newImage(width: 32, height: 32)
        let document = try ImageDocument(session: session, image: imageA, name: "Consent A")
        let other = try ImageDocument(session: session, image: imageB, name: "Consent B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document)
        let front = DocumentWindowController(document: other)
        controller.showWindow(nil)
        front.showWindow(nil)
        var paintErrors: [String] = []
        let priorError = document.onError
        document.onError = { message in priorError?(message); paintErrors.append(message) }
        defer { document.onError = priorError }
        func settle() {
            document.inputQueue.sync {}
            other.inputQueue.sync {}
            wait { document.pendingWork == 0 && other.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin(0.03)
        }
        defer {
            document.endStroke()
            other.endStroke()
            settle()
            for item in [controller, front] {
                if let sheet = item.window?.attachedSheet {
                    NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertSecondButtonReturn.rawValue)
                }
                item.window?.orderOut(nil)
                var stopped = false
                item.canvas.stopRendering { stopped = true }
                wait { stopped }
                check(stopped, "paint-consent teardown drains the window's renderer")
            }
            for item in [document, other] where !item.isClosing {
                var closed = false
                item.closeImageWhenDrained { closed = true }
                wait { closed }
                check(closed, "paint-consent teardown closes the native document")
            }
            documents.items.removeAll { $0 === document || $0 === other }
        }
        settle()
        let editable = EngineSession.LayerSource(kind: .text, isRasterized: false, hasSource: true)
        guard let row = document.layers.first(where: { $0.id == text }) else {
            return check(false, "paint-consent fixture resolves the selected text layer")
        }
        check(try session.layerSource(text, image: imageA) == editable
                && document.layerSources[text] == editable && document.activeDrawable == text,
              "paint-consent fixture is an editable text layer selected as the layer target")
        let beforePixels = try session.copyPixels(imageA, merged: true).pixels
        let beforeSource = try session.copyPixels(imageA, merged: false).pixels
        let beforeText = try session.textLayer(image: imageA, layer: text).text
        let beforeUndo = try session.undoInfo(imageA)
        let otherPixels = try session.copyPixels(imageB, merged: true).pixels
        let otherUndo = try session.undoInfo(imageB)
        let beforeVersion = document.stateVersion
        var brush = EngineSession.Brush()
        brush.size = 8
        brush.red = 1
        brush.hardness = 1
        func dab() {
            document.beginStroke(at: .init(x: row.bounds.midX, y: row.bounds.midY, pressure: 1), brush: brush)
            document.endStroke()
            settle()
        }
        func consent() -> NSWindow? {
            dab()
            wait { controller.window?.attachedSheet != nil }
            return controller.window?.attachedSheet
        }
        func applyConsent(_ sheet: NSWindow) {
            button(sheet, "Rasterize")?.performClick(nil)
            wait { controller.window?.attachedSheet == nil }
            settle()
        }
        func drawableBytes(_ drawable: Int32) throws -> Data? {
            guard let image = try session.drawableThumbnail(drawable, image: imageA, maxSize: 256),
                  let bytes = image.dataProvider?.data else { return nil }
            return bytes as Data
        }
        front.window?.makeKeyAndOrderFront(nil)
        document.beginStroke(at: .init(x: row.bounds.midX, y: row.bounds.midY, pressure: 1), brush: brush)
        // End immediately even on the pre-gate implementation; a RED run must not leak a stroke.
        document.endStroke()
        settle()
        wait({ controller.window?.attachedSheet != nil }, seconds: 2)
        let sheet = controller.window?.attachedSheet
        let isConsent = sheet != nil && sheet?.sheetParent === controller.window
            && button(sheet, "Rasterize") != nil && button(sheet, "Cancel") != nil
            && front.window?.attachedSheet == nil
        check(isConsent, "editable text paint opens Rasterize/Cancel on the captured window while another document is front")
        func originalStateIsIntact() -> Bool {
            (try? session.layerSource(text, image: imageA)) == editable
                && (try? session.textLayer(image: imageA, layer: text).text) == beforeText
                && (try? session.copyPixels(imageA, merged: true).pixels) == beforePixels
                && (try? session.copyPixels(imageA, merged: false).pixels) == beforeSource
                && (try? session.undoInfo(imageA)) == beforeUndo
                && document.stateVersion == beforeVersion && document.pendingWork == 0 && !document.strokeIsActive
                && (try? session.copyPixels(imageB, merged: true).pixels) == otherPixels
                && (try? session.undoInfo(imageB)) == otherUndo
        }
        check(originalStateIsIntact(), "the refused gesture queues no paint and preserves text, pixels, history and both documents")
        // The first RED uses no future production types or buttons when there is no consent sheet.
        guard isConsent, let sheet else { return }
        button(sheet, "Cancel")?.performClick(nil)
        wait { controller.window?.attachedSheet == nil }
        settle()
        check(originalStateIsIntact(), "paint-consent Cancel preserves the editable source and every captured native state")

        // Window close stops document admission while its asynchronous
        // render drain retains the native image. A late response must refuse.
        let closingImage = try session.newImage(width: 160, height: 100)
        let closingText = try session.addTextLayer(image: closingImage, text: "Closing", settings: settings,
                                                   at: CGPoint(x: 12, y: 12))
        try session.selectLayer(closingText, image: closingImage)
        let closingDocument = try ImageDocument(session: session, image: closingImage, name: "Consent closing")
        let closingController = DocumentWindowController(document: closingDocument)
        documents.items.append(closingDocument)
        closingController.showWindow(nil)
        let renderHeld = DispatchSemaphore(value: 0)
        let renderRelease = DispatchSemaphore(value: 0)
        var renderReleased = false
        defer {
            if !renderReleased { renderRelease.signal() }
            if let sheet = closingController.window?.attachedSheet {
                NSApp.endSheet(sheet, returnCode: NSApplication.ModalResponse.alertSecondButtonReturn.rawValue)
            }
            closingController.window?.orderOut(nil)
            var stopped = false
            closingController.canvas.stopRendering { stopped = true }
            wait { stopped }
            if !closingDocument.isClosing { closingDocument.closeImageWhenDrained() }
            wait { (try? session.info(closingImage)) == nil }
            documents.items.removeAll { $0 === closingDocument }
        }
        closingDocument.inputQueue.sync {}
        wait { closingDocument.pendingWork == 0 }
        guard let closingRow = closingDocument.layers.first(where: { $0.id == closingText }) else {
            return check(false, "the close-race fixture resolves its editable text")
        }
        let closingUndo = try session.undoInfo(closingImage)
        let closingPixels = try session.copyPixels(closingImage, merged: true).pixels
        closingDocument.beginStroke(at: .init(x: closingRow.bounds.midX, y: closingRow.bounds.midY, pressure: 1), brush: brush)
        closingDocument.endStroke()
        closingDocument.inputQueue.sync {}
        wait { closingDocument.pendingWork == 0 && closingController.window?.attachedSheet != nil }
        guard let closingSheet = closingController.window?.attachedSheet,
              let lateRasterize = button(closingSheet, "Rasterize") else {
            return check(false, "the fresh closing document owns a paint consent sheet")
        }
        closingController.canvas.enqueueRenderBarrier { renderHeld.signal(); _ = renderRelease.wait(timeout: .now() + 30) }
        guard renderHeld.wait(timeout: .now() + 5) == .success else {
            return check(false, "the render drain is held before the window close begins")
        }
        closingController.windowWillClose(Notification(name: NSWindow.willCloseNotification,
                                                        object: closingController.window))
        check(closingController.closeStarted && closingDocument.isClosing && !closingDocument.acceptsEdits
                && (try? session.info(closingImage)) != nil,
              "window close stops admission while the native image remains alive behind the render barrier")
        lateRasterize.performClick(nil)
        spin(0.03)
        closingDocument.inputQueue.sync {}
        wait { closingDocument.pendingWork == 0 }
        check(try closingDocument.isClosing && !closingDocument.acceptsEdits && closingDocument.pendingWork == 0
                && (try? session.info(closingImage)) != nil
                && session.layerSource(closingText, image: closingImage) == editable
                && session.undoInfo(closingImage) == closingUndo
                && session.copyPixels(closingImage, merged: true).pixels == closingPixels,
              "late paint consent after window close queues no rasterization before native teardown")
        renderRelease.signal()
        renderReleased = true
        wait { (try? session.info(closingImage)) == nil }
        check((try? session.info(closingImage)) == nil, "the close-race fixture drains and destroys its native image")

        // An accepted edit may still be queued when Apply arrives, before
        // stateVersion can reflect it. Consent cannot approve across that work.
        document.beginStroke(at: .init(x: row.bounds.midX, y: row.bounds.midY, pressure: 1), brush: brush)
        document.endStroke()
        settle()
        wait { controller.window?.attachedSheet != nil }
        guard let queuedSheet = controller.window?.attachedSheet,
              let rasterize = button(queuedSheet, "Rasterize") else {
            return check(false, "paint consent reopens for the pending-work race")
        }
        let queuedUndo = try session.undoInfo(imageA)
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var released = false
        defer { if !released { release.signal() } }
        document.inputQueue.async { held.signal(); _ = release.wait(timeout: .now() + 30) }
        guard held.wait(timeout: .now() + 5) == .success else {
            return check(false, "the input queue is held before queuing the concurrent edit")
        }
        let queued = document.run { session, image in
            try session.editMetadata(image, tag: "Exif.Image.Artist", .set, values: ["Queued consent fixture"])
        }
        check(queued && document.pendingWork > 0,
              "a real metadata edit is accepted while consent's captured version has not advanced")
        rasterize.performClick(nil)
        wait { controller.window?.attachedSheet == nil }
        release.signal()
        released = true
        settle()
        try document.reload()
        check(try session.metadataValues(imageA, tag: "Exif.Image.Artist") == ["Queued consent fixture"]
                && session.undoInfo(imageA).undoCount == queuedUndo.undoCount + 1
                && session.layerSource(text, image: imageA) == editable
                && session.textLayer(image: imageA, layer: text).text == beforeText
                && session.copyPixels(imageA, merged: true).pixels == beforePixels
                && session.copyPixels(imageA, merged: false).pixels == beforeSource,
              "late consent with pending input refuses rasterization and leaves only the queued metadata Undo")

        // Ending a field edit during Apply can queue work after the sheet's
        // first admission check; the document must check again afterward.
        guard let commitSheet = consent() else { return check(false, "consent opens for the field-commit race") }
        let commitUndo = try session.undoInfo(imageA).undoCount
        let priorEndEdits = document.onWillChangeLayers
        var commitQueued = false
        document.onWillChangeLayers = {
            priorEndEdits?()
            commitQueued = document.run { session, image in
                try session.editMetadata(image, tag: "Exif.Image.Artist", .set, values: ["Field commit fixture"])
            }
        }
        guard let commitApply = button(commitSheet, "Rasterize") else {
            return check(false, "the field-commit sheet exposes its Rasterize action")
        }
        commitApply.performClick(nil)
        wait { commitQueued }
        document.onWillChangeLayers = priorEndEdits
        settle()
        check(try commitQueued && session.undoInfo(imageA).undoCount == commitUndo + 1
                && session.metadataValues(imageA, tag: "Exif.Image.Artist") == ["Field commit fixture"]
                && session.layerSource(text, image: imageA) == editable
                && session.copyPixels(imageA, merged: true).pixels == beforePixels,
              "a real field-commit edit invalidates paint consent before rasterization is enqueued")

        guard let busySheet = consent(), let busyApply = button(busySheet, "Rasterize") else {
            return check(false, "consent opens before an exclusive activity starts during field commit")
        }
        let busyUndo = try session.undoInfo(imageA)
        let busyRelease = DispatchSemaphore(value: 0)
        var activityStarted = false, activityFinished = false
        document.onWillChangeLayers = {
            priorEndEdits?()
            activityStarted = EngineActivity.shared.perform(label: "Consent field activity", work: {
                _ = busyRelease.wait(timeout: .now() + 15)
            }, completion: { activityFinished = true })
        }
        busyApply.performClick(nil)
        wait { activityStarted && EngineActivity.shared.isBusy }
        document.onWillChangeLayers = priorEndEdits
        let queuedDuringActivity = document.pendingWork
        busyRelease.signal()
        wait { activityFinished }
        settle()
        check(try activityStarted && queuedDuringActivity == 0
                && session.layerSource(text, image: imageA) == editable
                && session.undoInfo(imageA) == busyUndo,
              "an exclusive activity started by field commit refuses consent before any rasterization queues")

        guard let pixel = document.layers.first(where: { $0.id != text && $0.kind == .pixel })?.id,
              let retargetSheet = consent() else { return check(false, "consent opens for a target change") }
        let retargetUndo = try session.undoInfo(imageA)
        let retargetVersion = document.stateVersion
        document.selectLayer(pixel)
        settle()
        applyConsent(retargetSheet)
        check(try document.activeDrawable == pixel && document.stateVersion != retargetVersion
                && session.layerSource(text, image: imageA) == editable && session.undoInfo(imageA) == retargetUndo,
              "retargeting before Apply refuses the old consent without touching either layer")
        document.selectLayer(text)
        settle()
        guard let versionSheet = consent() else { return check(false, "consent opens for a completed edit") }
        let versionUndo = try session.undoInfo(imageA).undoCount
        _ = document.run { session, image in
            try session.editMetadata(image, tag: "Exif.Image.Artist", .set, values: ["Completed edit fixture"])
        }
        settle()
        applyConsent(versionSheet)
        check(try document.activeDrawable == text && session.layerSource(text, image: imageA) == editable
                && session.undoInfo(imageA).undoCount == versionUndo + 1,
              "a completed edit invalidates consent even when the selected layer is unchanged")

        guard let acceptedSheet = consent() else { return check(false, "consent opens for explicit acceptance") }
        let acceptUndo = try session.undoInfo(imageA).undoCount
        front.window?.makeKeyAndOrderFront(nil)
        applyConsent(acceptedSheet)
        let rasterized = EngineSession.LayerSource(kind: .text, isRasterized: true, hasSource: true)
        check(try session.layerSource(text, image: imageA) == rasterized
                && session.undoInfo(imageA).undoCount == acceptUndo + 1
                && session.copyPixels(imageA, merged: true).pixels == beforePixels
                && session.copyPixels(imageA, merged: false).pixels == beforeSource
                && session.copyPixels(imageB, merged: true).pixels == otherPixels && session.undoInfo(imageB) == otherUndo,
              "Rasterize accepts only the captured document, retains source, and leaves the consumed gesture unpainted")
        dab()
        let paintedPixels = try session.copyPixels(imageA, merged: true).pixels
        let paintedSource = try session.copyPixels(imageA, merged: false).pixels
        check(try controller.window?.attachedSheet == nil && paintedSource != beforeSource
                && session.undoInfo(imageA).undoCount == acceptUndo + 2,
              "drawing again paints the rasterized text without asking a second time")
        document.undo(); settle()
        check(try session.copyPixels(imageA, merged: true).pixels == beforePixels
                && session.copyPixels(imageA, merged: false).pixels == beforeSource
                && session.layerSource(text, image: imageA) == rasterized,
              "paint Undo restores exact prepaint pixels while the separately rasterized source remains retained")
        document.redo(); settle()
        check(try session.copyPixels(imageA, merged: true).pixels == paintedPixels
                && session.copyPixels(imageA, merged: false).pixels == paintedSource,
              "paint Redo restores the exact actual painted pixels")

        // A queued Undo can restore editable text behind a rasterized UI
        // cache. The worker's fresh source read must refuse the next dab.
        document.undo(); settle()
        let fenceUndo = try session.undoInfo(imageA)
        let fenceErrors = paintErrors.count
        let fenceHeld = DispatchSemaphore(value: 0), fenceRelease = DispatchSemaphore(value: 0)
        var fenceReleased = false
        defer { if !fenceReleased { fenceRelease.signal() } }
        document.inputQueue.async { fenceHeld.signal(); _ = fenceRelease.wait(timeout: .now() + 30) }
        guard fenceHeld.wait(timeout: .now() + 5) == .success else { return check(false, "the stale-cache fixture holds input") }
        _ = document.run { session, image in try session.undo(image) }
        document.beginStroke(at: .init(x: row.bounds.midX, y: row.bounds.midY, pressure: 1), brush: brush)
        document.endStroke()
        fenceRelease.signal(); fenceReleased = true
        settle()
        try document.reload()
        check(try session.layerSource(text, image: imageA) == editable
                && session.textLayer(image: imageA, layer: text).text == beforeText
                && session.undoInfo(imageA).undoCount == fenceUndo.undoCount - 1
                && session.copyPixels(imageA, merged: false).pixels == beforeSource
                && paintErrors.dropFirst(fenceErrors).contains(where: { $0.contains("Rasterize") }),
              "a fresh worker source check refuses painting after a held Undo restores editability")

        let textBytes = try drawableBytes(text)
        document.addMask(text, source: .white, edit: true)
        settle()
        guard let mask = document.maskStates[text]?.mask else { return check(false, "the editable text has an editing mask") }
        let maskBytes = try drawableBytes(mask)
        let maskUndo = try session.undoInfo(imageA).undoCount
        dab()
        let paintedMaskBytes = try drawableBytes(mask)
        check(try document.isMaskTargetActive && controller.window?.attachedSheet == nil && maskBytes != nil
                && paintedMaskBytes != nil && paintedMaskBytes != maskBytes && drawableBytes(text) == textBytes
                && session.layerSource(text, image: imageA) == editable
                && session.textLayer(image: imageA, layer: text).text == beforeText
                && session.undoInfo(imageA).undoCount == maskUndo + 1,
              "painting an editable text layer's mask changes only mask pixels without consent or source loss")

        let channel = try session.channelFromSelection(imageA, name: "Consent channel")
        try document.reload()
        document.selectChannel(channel); settle()
        let channelBytes = try drawableBytes(channel)
        let channelUndo = try session.undoInfo(imageA).undoCount
        dab()
        let paintedChannelBytes = try drawableBytes(channel)
        check(try document.activeChannel == channel && controller.window?.attachedSheet == nil && channelBytes != nil
                && paintedChannelBytes != nil && paintedChannelBytes != channelBytes
                && session.layerSource(text, image: imageA) == editable
                && session.undoInfo(imageA).undoCount == channelUndo + 1,
              "saved channel painting bypasses layer consent and keeps the editable text source")
        let pixelUndo = try session.undoInfo(imageB).undoCount
        other.beginStroke(at: .init(x: 16, y: 16, pressure: 1), brush: brush)
        other.endStroke(); settle()
        check(try front.window?.attachedSheet == nil && session.undoInfo(imageB).undoCount == pixelUndo + 1
                && session.copyPixels(imageB, merged: true).pixels != otherPixels,
              "ordinary pixel-layer painting remains available without consent")
    }
}
