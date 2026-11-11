import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseProjectiveControls(_ session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        func drain(_ document: ImageDocument) {
            let deadline = Date().addingTimeInterval(15)
            while (document.pendingWork != 0 || EngineActivity.shared.isBusy) && Date() < deadline { spin(0.01) }
            check(document.pendingWork == 0, "projective document work drains")
            spin()
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        let oldTool = ToolState.shared.current, oldInterpolation = ToolState.shared.transformInterpolation
        ToolState.shared.select(.transform)
        ToolState.shared.transformInterpolation = .none
        var bytes = [UInt8]()
        for y in 0..<100 { for x in 0..<100 {
            bytes += [UInt8(x * 2), UInt8(y * 2), UInt8((x + y) % 256), 255]
        } }
        let pixels = ClipboardImage(width: 100, height: 100, pixels: Data(bytes), origin: .zero)
        let image = try session.newImage(width: 160, height: 150)
        let layer = try session.pastePixels(image, pixels: pixels, at: CGPoint(x: 20, y: 20))
        let oracle = try session.newImage(width: 160, height: 150)
        let oracleLayer = try session.pastePixels(oracle, pixels: pixels, at: CGPoint(x: 20, y: 20))
        defer { try? session.closeImage(oracle) }
        var extraDocuments: [ImageDocument] = []
        let document = try ImageDocument(session: session, image: image, name: "Perspective Controls")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        document.selectLayer(layer); drain(document)
        let canvas = controller.canvas, tools = controller.canvas.tools
        let options = ToolOptionsPaletteController()
        let host = NSWindow(contentRect: NSRect(x: 50, y: 90, width: 250, height: 420),
                            styleMask: [.titled], backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = options.view; options.retarget(to: document)
        host.makeKeyAndOrderFront(nil)
        var messages: [String] = [], errors: [String] = []
        let oldStatus = tools.onStatus
        tools.onStatus = { messages.append($0); oldStatus?($0) }
        document.onError = { errors.append($0) }
        defer {
            host.close(); controller.window?.close()
            documents.items.removeAll { $0 === document }
            if !document.isClosing {
                var closed = false
                document.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(15)
                while !closed && Date() < deadline { spin(0.01) }
                check(closed, "projective control document closes cleanly")
            }
            for extra in extraDocuments {
                documents.items.removeAll { $0 === extra }
                var closed = false
                extra.closeImageWhenDrained { closed = true }
                let deadline = Date().addingTimeInterval(15)
                while !closed && Date() < deadline { spin(0.01) }
                check(closed, "rebound transform document closes cleanly")
            }
            ToolState.shared.transformInterpolation = oldInterpolation
            ToolState.shared.select(oldTool)
        }
        let views = descendants(options.view)
        guard let mode = views.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.accessibilityLabel() == "Transform mode" }),
              let apply = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Apply" }),
              let cancel = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }),
              let window = canvas.window else { return check(false, "projective mode and actions exist") }
        func choose(_ title: String) {
            mode.selectItem(withTitle: title)
            _ = mode.sendAction(mode.action, to: mode.target)
            spin()
        }
        func mouse(_ type: NSEvent.EventType, _ point: CGPoint) {
            let location = canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
            switch type {
            case .leftMouseDown: canvas.mouseDown(with: event)
            case .leftMouseDragged: canvas.mouseDragged(with: event)
            case .leftMouseUp: canvas.mouseUp(with: event)
            default: break
            }
        }
        let original = try session.copyPixels(image, merged: true).pixels
        let originalBounds = CGRect(x: 20, y: 20, width: 100, height: 100)
        let undo = document.undoInfo.undoCount
        check(mode.itemTitles == ["Scale / Rotate", "Skew", "Distort", "Perspective"], "all four modes are visible")
        choose("Perspective")
        mouse(.leftMouseDown, CGPoint(x: 120, y: 20))
        mouse(.leftMouseDragged, CGPoint(x: 100, y: 20))
        mouse(.leftMouseDragged, CGPoint(x: 100, y: 50))
        mouse(.leftMouseUp, CGPoint(x: 100, y: 50))
        let expectedCorners = [CGPoint(x: 40, y: 20), CGPoint(x: 100, y: 20),
                               CGPoint(x: 120, y: 120), CGPoint(x: 20, y: 120)]
        guard let preview = tools.transformPreview else { return check(false, "perspective pointer preview exists") }
        check(zip(preview.imageCorners, expectedCorners).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 1e-8 },
              "perspective axis stays horizontal through later vertical movement and release")
        check(try session.copyPixels(image, merged: true).pixels == original && document.undoInfo.undoCount == undo,
              "perspective pointer preview changes no native pixels or history")
        choose("Scale / Rotate")
        check(tools.transformPreview?.projectiveMatrix == preview.projectiveMatrix,
              "mode switches preserve the pending warp")
        choose("Perspective")
        cancel.performClick(nil); drain(document)
        check(tools.transformSession == nil && document.undoInfo.undoCount == undo, "Cancel drops a warp without Undo")
        check(canvas.transformPreviewImage == nil, "Cancel immediately removes the warped pixel preview")
        choose("Skew")
        mouse(.leftMouseDown, CGPoint(x: 70, y: 20)); mouse(.leftMouseDragged, CGPoint(x: 85, y: 27)); mouse(.leftMouseUp, CGPoint(x: 85, y: 27))
        check(tools.transformPreview.map { hypot($0.imageCorners[0].x - 35, $0.imageCorners[0].y - 20) < 1e-8 } == true, "Skew edge follows its tangent")
        cancel.performClick(nil)
        choose("Distort")
        mouse(.leftMouseDown, CGPoint(x: 120, y: 20)); mouse(.leftMouseDragged, CGPoint(x: 105, y: 30)); mouse(.leftMouseUp, CGPoint(x: 105, y: 30))
        check(tools.transformPreview.map { hypot($0.imageCorners[1].x - 105, $0.imageCorners[1].y - 30) < 1e-8 } == true, "Distort moves one corner independently")
        cancel.performClick(nil)
        choose("Perspective")
        mouse(.leftMouseDown, CGPoint(x: 120, y: 20)); mouse(.leftMouseDragged, CGPoint(x: 100, y: 20)); mouse(.leftMouseUp, CGPoint(x: 100, y: 20))
        // Analytic forward mapping for the independently specified trapezoid.
        let expectedMatrix = ProjectiveTransform(h00: 0.6, h01: -0.28, h02: 33.6,
            h10: 0, h11: 0.52, h12: 9.6, h20: 0, h21: -0.004, h22: 1.08)
        try session.transformLayer(oracleLayer, image: oracle, matrix: expectedMatrix, interpolation: .none)
        let expectedPixels = try session.copyPixels(oracle, merged: true).pixels
        canvas.refreshTransformPixelPreview()
        let previewDeadline = Date().addingTimeInterval(15)
        while (canvas.transformPreviewIsPending || canvas.transformPreviewImage == nil) && Date() < previewDeadline {
            spin(0.01)
        }
        if let shown = canvas.transformPreviewImage, let request = canvas.transformPreviewRequest {
            let reference = try CanvasDisplayDestination.render(session, image: oracle,
                scale: request.renderScale, area: request.renderArea, destination: request.destination, proof: request.proof)
            check((shown.dataProvider?.data as Data?) == (reference.dataProvider?.data as Data?),
                  "the actual canvas pixel preview matches the independent transformed viewport")
            check(try session.copyPixels(image, merged: true).pixels == original,
                  "showing warped canvas pixels leaves the document's committed pixels unchanged")
            if let path = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"],
               let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.visibleRect) {
                canvas.cacheDisplay(in: canvas.visibleRect, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(
                    to: URL(fileURLWithPath: path).appendingPathComponent("projective-pixel-preview.png"))
            }
        } else { check(false, "the actual canvas publishes its warped pixel preview") }
        drain(document)
        try document.startRecording()
        // Hold input to prove UI acknowledgement follows the result, and that
        // an accepted Apply cannot be resubmitted or misleadingly cancelled.
        let hold = DispatchSemaphore(value: 0)
        document.inputQueue.async { hold.wait() }
        defer { hold.signal() }
        apply.performClick(nil)
        check(tools.transformCommitIsPending && !apply.isEnabled && !cancel.isEnabled && !mode.isEnabled,
              "accepted Apply disables repeated submission and editing until completion")
        check(!messages.contains("Transformed."), "queue admission never reports a completed transform")
        tools.cancelPendingTransform()
        check(tools.transformCommitIsPending, "Cancel cannot falsely cancel an accepted native edit")
        try document.stopRecording()
        hold.signal(); drain(document)
        check(!tools.transformCommitIsPending && tools.transformSession == nil && messages.contains("Transformed."),
              "only native success clears the preview and reports completion")
        check(try session.copyPixels(image, merged: true).pixels == expectedPixels && document.undoInfo.undoCount == undo + 1,
              "canvas Apply matches analytic perspective pixels and creates exactly one Undo")
        guard case .success(.transformProjectiveLayer(let recorded, .none))? = document.recorder.records.first?.resolution else {
            return check(false, "perspective Apply records its complete nine-coefficient command")
        }
        check(recorded.projectedBounds(forSource: originalBounds) != nil, "recorded perspective has valid source geometry")
        document.undo(); drain(document)
        check(try session.copyPixels(image, merged: true).pixels == original, "perspective Undo restores exact pixels")
        document.redo(); drain(document)
        check(try session.copyPixels(image, merged: true).pixels == expectedPixels, "perspective Redo restores exact pixels")
        document.undo(); drain(document)
        try document.startReplay(); drain(document)
        check(try session.copyPixels(image, merged: true).pixels == expectedPixels, "recorded perspective replays through captured native validation")
        document.undo(); drain(document)
        let recordingURL = work.appendingPathComponent("perspective.glimsrecording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        document.saveRecording(to: recordingURL, checkpoint: try document.recorderSaveCheckpoint()) { saved = $0 }
        drain(document)
        guard let saved else { return check(false, "projective recording save completes") }
        _ = try saved.get()
        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        document.prepareRecordingFile(at: recordingURL, checkpoint: try document.recorderInstallCheckpoint()) { loaded = $0 }
        drain(document)
        guard let loaded, case .layer(let symbol)? = document.recorderBindingDescriptions[0] else {
            return check(false, "projective recording load preserves explicit target metadata")
        }
        let prepared = try loaded.get()
        let encoded = try String(contentsOf: recordingURL, encoding: .utf8)
        check(encoded.contains("\"version\":6") || encoded.contains("\"version\" : 6"), "saved perspective declares format six")
        let reboundImage = try session.newImage(width: 160, height: 150)
        let reboundLayer = try session.pastePixels(reboundImage, pixels: pixels, at: CGPoint(x: 20, y: 20))
        let rebound = try ImageDocument(session: session, image: reboundImage, name: "Rebound Perspective")
        extraDocuments.append(rebound); documents.items.append(rebound)
        rebound.onError = { errors.append($0) }
        rebound.selectLayer(reboundLayer); drain(rebound)
        var installed: Result<Void, Error>?
        rebound.installRecording(prepared, checkpoint: try rebound.recorderInstallCheckpoint(), choices: [symbol: .layer(reboundLayer)]) {
            installed = $0
        }
        drain(rebound)
        guard let installed else { return check(false, "rebound perspective install completes") }
        try installed.get()
        guard let unrelated = rebound.layers.first(where: { $0.id != reboundLayer }) else {
            return check(false, "rebound image has an unrelated selected layer")
        }
        rebound.selectLayer(unrelated.id); drain(rebound)
        let reboundUndo = rebound.undoInfo.undoCount
        try rebound.startReplay(); drain(rebound)
        check(try session.copyPixels(reboundImage, merged: true).pixels == expectedPixels
              && rebound.undoInfo.undoCount == reboundUndo + 1 && session.selectedLayers(reboundImage) == [unrelated.id],
              "saved v6 rebinds explicitly, reproduces pixels and preserves unrelated selection with one Undo")
        rebound.undo(); drain(rebound)
        check(try session.copyPixels(reboundImage, merged: true).pixels == original, "rebound perspective Undo restores exact source pixels")
        // Both legacy affine and new projective semantic dispatch must retain
        // editable sources when rebound to text instead of a raster layer.
        let textImage = try session.newImage(width: 160, height: 150)
        defer { try? session.closeImage(textImage) }
        let textLayer = try session.addTextLayer(image: textImage, text: "Source", settings: .init(), at: CGPoint(x: 20, y: 20))
        let textPixels = try session.copyPixels(textImage, merged: true).pixels
        let textUndo = try session.undoInfo(textImage)
        let commands: [SemanticImageCommand] = [
            .transformLayer(matrix: CGAffineTransform(translationX: 2, y: 0), interpolation: .none),
            .transformProjectiveLayer(matrix: expectedMatrix, interpolation: .none),
        ]
        for command in commands {
            var refused = false
            do { try command.apply(session: session, image: textImage, layer: textLayer) }
            catch { refused = error.localizedDescription.contains("Rasterize") }
            check(try refused && session.copyPixels(textImage, merged: true).pixels == textPixels
                  && session.undoInfo(textImage) == textUndo && session.textLayer(image: textImage, layer: textLayer).text == "Source",
                  "semantic transform replay refuses editable text without pixels, source or Undo changes")
        }
        // A geometry mutation already ahead of Apply must not be overwritten.
        check(tools.setTransformGeometry(origin: originalBounds.origin, width: 120, height: 100, degrees: 0,
            expectedLayer: layer, expectedOriginal: originalBounds), "a fresh captured preview starts")
        let staleHold = DispatchSemaphore(value: 0)
        document.inputQueue.async { staleHold.wait() }
        defer { staleHold.signal() }
        tools.applyPendingTransform()
        try session.moveLayer(layer, image: image, by: CGSize(width: 5, height: 0))
        let stalePixels = try session.copyPixels(image, merged: true).pixels
        let staleUndo = try session.undoInfo(image).undoCount
        staleHold.signal(); drain(document)
        check(try session.copyPixels(image, merged: true).pixels == stalePixels && document.undoInfo.undoCount == staleUndo,
              "captured commit refuses intervening geometry without pixels or Undo changes")
        check(errors.contains(where: { $0.contains("layer changed") }), "stale captured geometry has an actionable reason")
        check(!tools.transformCommitIsPending, "native refusal releases pending UI state")
        // A Text click may wait for a private transform read in another
        // document. Escape must cancel that intent before the read drains.
        ToolState.shared.select(.text)
        canvas.window?.makeFirstResponder(canvas)
        EngineActivity.shared.beginTransformPreview()
        mouse(.leftMouseDown, CGPoint(x: 5, y: 5))
        mouse(.leftMouseUp, CGPoint(x: 5, y: 5))
        check(tools.textEditor == nil, "Text waits for a private transform read without blocking the canvas")
        if let window = canvas.window, let escape = NSEvent.keyEvent(with: .keyDown, location: .zero,
            modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
            _ = tools.keyDown(with: escape)
        } else { check(false, "deferred Text regression creates an Escape event") }
        EngineActivity.shared.endTransformPreview()
        spin()
        check(tools.textEditor == nil, "Escape prevents a late text editor after the preview read drains")
        ToolState.shared.select(.transform)
        if let path = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"],
           let bitmap = options.view.bitmapImageRepForCachingDisplay(in: options.view.bounds) {
            options.view.cacheDisplay(in: options.view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path).appendingPathComponent("projective-options.png"))
        }
    }
}
