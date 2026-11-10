import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseInputHistogram(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let limit = Date().addingTimeInterval(12)
            while !condition() && Date() < limit { spin(0.01) }
        }
        let bytes = Data([UInt8(51),76,102,64,204,179,153,192,51,76,102,128,204,179,153,255])
        let image = try session.newImage(pixels: ClipboardImage(width: 4, height: 1, pixels: bytes, origin: .zero))
        let otherImage = try session.newImage(width: 8, height: 8)
        let document = try ImageDocument(session: session, image: image, name: "Histogram A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Histogram B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        var controlled: [LevelsPanel] = []
        controller.showWindow(nil); front.showWindow(nil)
        defer {
            (controller.previewPanel as? FilterPreviewPanel)?.cancel()
            for panel in controlled { panel.cancel(); panel.window?.orderOut(nil) }
            for c in [controller, front] {
                c.window?.orderOut(nil)
                var stopped = false; c.canvas.stopRendering { stopped = true }; wait { stopped }
            }
            for doc in [document, other] {
                var closed = false; doc.closeImageWhenDrained { closed = true }; wait { closed }
            }
            documents.items.removeAll { $0 === document || $0 === other }
        }
        func settle() { document.inputQueue.sync {}; wait { document.pendingWork == 0 }; spin(0.03) }
        guard let layer = document.activeLayer else { return check(false, "histogram target is available") }
        // A synchronous rejected field commit must never be hidden by Auto.
        let syncFilter = try session.beginFilter(image: image, drawable: layer, operation: "gimp:levels")
        var synchronousAutoCalls = 0
        guard let sync = LevelsPanel(document: document, filter: syncFilter, settings: try session.levelsSettings(syncFilter),
            write: { _, _, reply in reply(.failure(ImageDocument.DocumentError.busy)) },
            automatic: { _, reply in synchronousAutoCalls += 1; reply(.success(.init())) }) else {
            try session.abortFilter(syncFilter); return check(false, "controlled synchronous Auto form constructs")
        }
        controlled.append(sync); sync.window?.makeKeyAndOrderFront(nil); sync.window?.makeFirstResponder(sync.gammaField)
        if let editor = sync.gammaField.currentEditor() { editor.string = "2" } else { sync.gammaField.stringValue = "2" }
        sync.automaticLevels(nil)
        check(synchronousAutoCalls == 0 && sync.lastError != nil && sync.automaticButton.isEnabled,
              "Auto refuses a synchronously rejected final numeric write")
        sync.cancel(); settle()
        let asyncFilter = try session.beginFilter(image: image, drawable: layer, operation: "gimp:levels")
        var numericReply: (@MainActor (Result<Void, Error>) -> Void)?
        var asynchronousAutoCalls = 0
        guard let async = LevelsPanel(document: document, filter: asyncFilter, settings: try session.levelsSettings(asyncFilter),
            write: { _, _, reply in numericReply = reply },
            automatic: { _, reply in asynchronousAutoCalls += 1; reply(.success(.init())) }) else {
            try session.abortFilter(asyncFilter); return check(false, "controlled asynchronous Auto form constructs")
        }
        controlled.append(async)
        async.gammaField.stringValue = "2"; async.fieldsChanged(async.gammaField); async.automaticLevels(nil)
        check(asynchronousAutoCalls == 0 && !async.gammaField.isEnabled && !async.automaticButton.isEnabled,
              "Auto waits for pending numeric acknowledgements and gates parameter edits")
        numericReply?(.failure(ImageDocument.DocumentError.busy))
        check(asynchronousAutoCalls == 0 && async.lastError != nil && async.gammaField.isEnabled,
              "a refused asynchronous prerequisite cancels Auto and restores the form")
        async.cancel(); settle()
        let operations = try session.filterOperations(); NativeFilterCatalog.shared.install(operations)
        guard let levels = operations.first(where: { $0.name == "gimp:levels" }),
              let curves = operations.first(where: { $0.name == "gimp:curves" }) else {
            return check(false, "Levels and Curves are available")
        }
        let original = try session.copyPixels(image, merged: true).pixels
        let otherPixels = try session.copyPixels(otherImage, merged: true).pixels
        let baseline = try session.undoInfo(image).undoCount
        controller.openNativeFilter(levels)
        wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let panel = controller.previewPanel as? LevelsPanel, let filter = panel.filter else {
            return check(false, "Levels input histogram opens")
        }
        check(panel.histogramView.histogram?.binCount == 256 && panel.histogramView.histogram?.trc == .linear,
              "Levels loads its native source histogram with the current transfer curve")
        if let window = panel.window, let screen = window.screen {
            print("Levels histogram frame \(window.frame), visible \(screen.visibleFrame)")
            check(screen.visibleFrame.contains(window.frame), "all Levels controls fit on the actual screen")
        } else { check(false, "Levels has an actual screen frame") }
        for selected in [1, 2, 0, 1] {
            panel.trcPopup.selectItem(at: selected); panel.optionsChanged(panel.trcPopup)
        }
        settle()
        check(panel.histogramView.histogram?.trc == .nonlinear && (try? session.levelsSettings(filter).trc) == .nonlinear,
              "rapid transfer-curve changes discard stale histogram replies")
        let sourceHistogram = try session.inputHistogram(filter)
        panel.gammaField.stringValue = "2"; panel.fieldsChanged(panel.gammaField); settle()
        check(panel.histogramView.histogram == sourceHistogram && (try? session.inputHistogram(filter)) == sourceHistogram,
              "the histogram describes input pixels before the changed Levels preview")
        front.window?.makeKeyAndOrderFront(nil)
        panel.automaticLevels(nil); settle()
        let automatic = try session.levelsSettings(filter)
        check(automatic.value == .init() && abs(automatic.red.lowInput - 51.0 / 255) < 1e-10 &&
              abs(automatic.red.highInput - 204.0 / 255) < 1e-10 && automatic.red.gamma == 1,
              "Auto returns authoritative native RGB input endpoints and resets Value")
        check(panel.gammaField.stringValue == "1" && panel.automaticButton.isEnabled,
              "Auto refreshes fields from the accepted result and reenables the form")
        check(try session.copyPixels(otherImage, merged: true).pixels == otherPixels,
              "Auto keeps its captured document while another window is frontmost")
        panel.channelPopup.selectItem(at: 4); panel.channelChanged(panel.channelPopup)
        check(panel.histogramView.channel == .alpha && panel.histogramView.histogram == sourceHistogram,
              "channel switching reuses native Alpha histogram bins")
        let log = NSButton(); log.state = .on; panel.histogramScaleChanged(log)
        check(panel.histogramView.logarithmic && (try? session.levelsSettings(filter)) == automatic,
              "histogram log scale changes only the view")
        panel.cancel(); settle()
        check(try session.copyPixels(image, merged: true).pixels == original && session.undoInfo(image).undoCount == baseline,
              "Auto Cancel restores source pixels and history")
        controller.openNativeFilter(levels); wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let applying = controller.previewPanel as? LevelsPanel else { return check(false, "Levels Auto reopens") }
        applying.automaticLevels(nil); settle(); applying.commit()
        wait { controller.previewPanel == nil && document.pendingWork == 0 }; settle()
        let applied = try session.copyPixels(image, merged: true).pixels
        check(try session.undoInfo(image).undoCount == baseline + 1 && applied != original,
              "Auto Apply commits one native Undo and visible adjustment")
        try session.undo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == original, "Auto Undo restores original pixels")
        try session.redo(image); try document.reload()
        check(try session.copyPixels(image, merged: true).pixels == applied, "Auto Redo restores accepted pixels")
        controller.openNativeFilter(curves); wait { controller.previewPanel != nil && document.pendingWork == 0 }
        guard let curve = controller.previewPanel as? CurvesPanel, let curveFilter = curve.filter else {
            return check(false, "Curves input histogram opens")
        }
        check(curve.histogramView.histogram?.trc == .perceptual && curve.histogramView.histogram?.binCount == 256,
              "Curves loads the same captured-input histogram service with its own transfer curve")
        if let window = curve.window, let screen = window.screen {
            print("Curves histogram frame \(window.frame), visible \(screen.visibleFrame)")
            check(screen.visibleFrame.contains(window.frame), "Curves histogram and controls fit on the actual screen")
        } else { check(false, "Curves has an actual screen frame") }
        let curveHistogram = try session.inputHistogram(curveFilter)
        curve.outputField.stringValue = "0.2"; curve.fieldsChanged(curve.outputField); settle()
        check(curve.histogramView.histogram == curveHistogram,
              "Curves point edits preserve the original input histogram")
        curve.cancel(); settle()
    }
}
