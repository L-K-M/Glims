import AppKit

@MainActor
extension EngineSmokeTest {
    /// Filter ▸ Last Filter, Last Filter Settings and Recently Used track
    /// native filters alongside plug-ins: the newest Filter-menu apply
    /// wins, a repeat reruns the committed settings on the current
    /// document's target as one undo step with no panel, a reopen seeds
    /// the filter's own editor, and an Image ▸ Adjust apply or a Cancel
    /// never changes the choice.
    static func exerciseLastFilter(_ session: EngineSession, documents: DocumentList) throws {
        var owned: [ImageDocument] = []
        var controllers: [DocumentWindowController] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "LastFilterFixture", code: 1,
                                                  userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.005) }
            try require(condition(), "last-filter work timed out")
        }
        func drain(_ doc: ImageDocument) throws {
            try wait { doc.pendingWork == 0 && doc.recorder.pendingCount == 0 && !EngineActivity.shared.isBusy }
            if (try? session.info(doc.image)) != nil { try doc.reload() }
        }
        func pixels(_ image: Int32) throws -> [UInt8] { [UInt8](try session.copyPixels(image, merged: true).pixels) }
        var bytes: [UInt8] = []
        for i in 0..<120 { bytes += [UInt8(i * 13 % 256), UInt8(i * 31 % 256), UInt8(i * 7 % 256), 255] }
        let input = ClipboardImage(width: 12, height: 10, pixels: Data(bytes), origin: .zero)
        func fixture(_ name: String) throws -> ImageDocument {
            let image = try session.newImage(width: 16, height: 14)
            _ = try session.pastePixels(image, pixels: input, at: CGPoint(x: 2, y: 2))
            let doc = try ImageDocument(session: session, image: image, name: name)
            doc.onError = { _ in }
            owned.append(doc); documents.items.append(doc)
            return doc
        }
        func submenu(_ path: [String]) -> NSMenu? {
            path.reduce(NSApp.mainMenu as NSMenu?) { menu, title in menu?.item(withTitle: title)?.submenu }
        }
        defer {
            for doc in owned { try? drain(doc) }
            for controller in controllers {
                controller.previewPanel?.cancel()
                controller.window?.orderOut(nil)
                var stopped = false; controller.canvas.stopRendering { stopped = true }
                check((try? wait { stopped }) != nil, "last-filter stops rendering before it closes")
            }
            for doc in owned { doc.closeImageWhenDrained() }
            try? wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            check(owned.allSatisfy { (try? session.info($0.image)) == nil }, "last-filter closes every owned image")
            documents.items.removeAll { doc in owned.contains { $0 === doc } }
        }

        let mainMenu = MainMenu.make()
        NSApp.mainMenu = mainMenu
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        NativeFilterMenus.install(operations, in: mainMenu)
        let procedures = try session.procedures()
        PlugInMenus.install(procedures, in: mainMenu)
        guard let checkerboard = procedures.first(where: { $0.name == "plug-in-checkerboard" }) else {
            return check(false, "the engine offers plug-in-checkerboard")
        }
        let filterMenu = submenu(["Filter"])
        guard let repeatItem = filterMenu?.items.first(where: {
                  $0.action == #selector(DocumentWindowController.repeatLastFilter(_:)) }),
              let reshowItem = filterMenu?.items.first(where: {
                  $0.action == #selector(DocumentWindowController.reshowLastFilter(_:)) }) else {
            return check(false, "the Filter menu keeps Last Filter and Last Filter Settings")
        }
        func recentTitles() -> [String] { submenu(["Filter", MainMenu.recentlyUsedTitle])?.items.map(\.title) ?? [] }
        func slider(in view: NSView?) -> NSSlider? {
            guard let view else { return nil }
            if let slider = view as? NSSlider { return slider }
            return view.subviews.lazy.compactMap { slider(in: $0) }.first
        }

        let docA = try fixture("Last Filter A"), docB = try fixture("Last Filter B")
        let controllerA = DocumentWindowController(document: docA)
        let controllerB = DocumentWindowController(document: docB)
        controllers = [controllerA, controllerB]
        let original = try pixels(docA.image)

        // The real Filter ▸ Blur ▸ Gaussian Blur item applies non-default
        // settings through its dedicated panel.
        func applyBlur(_ controller: DocumentWindowController, _ doc: ImageDocument, radius: Double) throws {
            controller.gaussianBlur(nil)
            try wait { controller.previewPanel != nil }
            guard let panel = controller.previewPanel as? GaussianBlurPanel else {
                return check(false, "Gaussian Blur opens its dedicated panel")
            }
            panel.apply(radius: radius)
            try drain(doc)
            panel.commit()
            try wait { controller.previewPanel == nil }
            try drain(doc)
        }
        let undoBeforeBlur = docA.undoInfo.undoCount
        try applyBlur(controllerA, docA, radius: 9)
        let blurred = try pixels(docA.image)
        check(blurred != original && docA.undoInfo.undoCount == undoBeforeBlur + 1,
              "the native filter Apply changed the image in one undo step")
        guard case .native(let applied)? = FilterCommands.last else {
            return check(false, "a native Filter-menu apply becomes the last filter")
        }
        check(applied.operation == GaussianBlurPanel.operation && applied.title == "Gaussian Blur"
                && applied.isRepeatable && applied.gaussianDeviation == 9,
              "the last filter names the native apply and keeps its committed settings")
        check(controllerB.validateMenuItem(repeatItem) && repeatItem.title == "Last Filter: Gaussian Blur",
              "Last Filter names the native filter (\(repeatItem.title))")
        check(controllerB.validateMenuItem(reshowItem) && reshowItem.title == "Last Filter Settings: Gaussian Blur…",
              "Last Filter Settings names the native filter (\(reshowItem.title))")
        check(recentTitles().first == "Gaussian Blur…",
              "Recently Used leads with the native filter (\(recentTitles()))")

        // Command-F on another document: identical input, identical
        // committed settings, identical pixels, one undo step, no panel.
        try docB.startRecording()
        let undoBeforeRepeat = docB.undoInfo.undoCount
        controllerB.repeatLastFilter(nil)
        check(controllerB.previewPanel == nil, "a repeat opens no panel")
        let blurItem = NSMenuItem(title: "Gaussian Blur…",
                                  action: #selector(DocumentWindowController.gaussianBlur(_:)), keyEquivalent: "")
        // From the begin until the commit lands, another filter's begin
        // would queue behind the commit and lose its preview gate. The hold
        // runs after the begin, so the admitted commit cannot land under it.
        check(!controllerB.validateMenuItem(blurItem), "no other filter is offered while a repeat begins")
        let hold = DispatchSemaphore(value: 0)
        defer { hold.signal() }
        docB.inputQueue.async { _ = hold.wait(timeout: .now() + 20) }
        try wait { docB.recorder.pendingCount > 0 }
        check(docB.filterPreviewIsOpen && !controllerB.validateMenuItem(blurItem),
              "no other filter is offered until a repeat's commit lands")
        hold.signal()
        try drain(docB)
        try wait { !docB.filterPreviewIsOpen }
        check(docB.undoInfo.undoCount == undoBeforeRepeat + 1, "Last Filter is one undo step")
        check(try pixels(docB.image) == blurred,
              "Last Filter produces the same pixels as a manual Apply with those settings")
        check(docB.fadeTarget != nil, "Fade is offered after a repeated filter")
        try docB.stopRecording()
        try drain(docB)
        if case .success(let command)? = docB.recorder.records.last?.resolution,
           case .applyGaussianBlur(let settings) = command {
            check(settings.deviationX == 9 && settings.deviationY == 9,
                  "a repeated filter records the same semantic row a normal Apply does")
        } else {
            check(false, "a repeated filter must not be silently missing from a recording")
        }
        try session.undo(docB.image); try docB.reload()
        check(try pixels(docB.image) == original, "undo reverts the repeated filter")
        try session.redo(docB.image); try docB.reload()
        check(try pixels(docB.image) == blurred, "redo replays the repeated filter")

        // Last Filter Settings reopens the dedicated panel at the
        // committed radius; Cancel applies nothing.
        controllerB.reshowLastFilter(nil)
        try wait { controllerB.previewPanel != nil }
        let reshowPanel = controllerB.previewPanel
        check(reshowPanel is GaussianBlurPanel, "Last Filter Settings reopens the filter's own editor")
        let reshowSlider = slider(in: reshowPanel?.window?.contentView)
        check(reshowSlider?.doubleValue == 9,
              "the reopened editor starts at the committed settings (\(reshowSlider?.doubleValue ?? -1))")
        controllerB.previewPanel?.cancel()
        try wait { controllerB.previewPanel == nil }
        try drain(docB)
        check(docB.undoInfo.undoCount == undoBeforeRepeat + 1, "Last Filter Settings alone applies nothing")

        // A refused preset write must not leave its session open: Levels
        // begins only on an image without one.
        var refused: Bool?
        docB.beginFilterPreview(operation: GaussianBlurPanel.operation, properties: [],
                                preset: .properties(["no-such-property": .number(1)])) { result in
            if case .failure = result { refused = true } else { refused = false }
        }
        try wait { refused != nil }
        try drain(docB)
        var reopened = false
        if let drawable = docB.activeDrawable,
           let probe = try? session.beginFilter(image: docB.image, drawable: drawable, operation: "gimp:levels") {
            reopened = true
            try session.abortFilter(probe)
        }
        check(refused == true && reopened, "a refused preset write aborts the session it began")

        // Cancel does not replace the last filter.
        let beforeCancel = FilterCommands.entries
        controllerA.gaussianBlur(nil)
        try wait { controllerA.previewPanel != nil }
        (controllerA.previewPanel as? GaussianBlurPanel)?.apply(radius: 3)
        try drain(docA)
        controllerA.previewPanel?.cancel()
        try wait { controllerA.previewPanel == nil }
        try drain(docA)
        check(FilterCommands.entries == beforeCancel, "Cancel changes neither Last Filter nor Recently Used")

        // An Image ▸ Adjust apply is not a filter.
        guard let adjustItem = submenu(["Image", MainMenu.adjustTitle])?.items
                .first(where: { $0.representedObject is NativeFilterCommand }) else {
            return check(false, "Image ▸ Adjust lists a native adjustment")
        }
        controllerA.runNativeFilter(adjustItem)
        try wait { controllerA.previewPanel != nil }
        controllerA.previewPanel?.commit()
        try wait { controllerA.previewPanel == nil }
        try drain(docA)
        check(FilterCommands.entries == beforeCancel,
              "an Image ▸ Adjust apply never becomes the last filter")

        // A plug-in applied after a native filter wins; a native filter
        // applied after that plug-in wins again.
        func runCheckerboard() throws {
            controllerA.run(checkerboard, mode: .withLastValues)
            let deadline = Date().addingTimeInterval(30)
            while PlugInCommands.isRunning && Date() < deadline { spin(0.02) }
            try drain(docA)
        }
        try runCheckerboard()
        guard case .plugIn(let ranPlugIn)? = FilterCommands.last, ranPlugIn.name == checkerboard.name else {
            return check(false, "a plug-in applied after a native filter becomes the last filter")
        }
        try applyBlur(controllerA, docA, radius: 9)
        guard case .native = FilterCommands.last else {
            return check(false, "a native filter applied after a plug-in becomes the last filter")
        }
        check(controllerB.validateMenuItem(repeatItem) && repeatItem.title == "Last Filter: Gaussian Blur",
              "the newest apply wins across filter kinds")
        check(recentTitles().prefix(2) == ["Gaussian Blur…", checkerboard.label],
              "Recently Used mixes native and plug-in filters newest first (\(recentTitles()))")

        // A filter that cannot rerun without its editor is named but
        // disabled rather than falling back to an older apply.
        FilterCommands.record(.native(AppliedNativeFilter(operation: "gegl:oilify", variant: nil,
                                                          title: "Oilify", capture: .names([]),
                                                          isRepeatable: false, settings: nil)))
        check(!controllerB.validateMenuItem(repeatItem) && repeatItem.title == "Last Filter: Oilify",
              "a non-repeatable last filter is named but disabled (\(repeatItem.title))")
        check(recentTitles().first == "Oilify…", "it still leads Recently Used (\(recentTitles()))")

        // A rank filter's reopened field shows the committed radius too.
        let maximum = RankFilterPanel.Rank.maximum
        FilterCommands.record(.native(AppliedNativeFilter(operation: RankFilterPanel.operation,
                                                          variant: maximum.variantTitle, title: maximum.title,
                                                          capture: .names(RankFilterPanel.captureNames),
                                                          isRepeatable: true,
                                                          settings: .properties(["radius": .integer(9)]))))
        func editableField(in view: NSView?) -> NSTextField? {
            guard let view else { return nil }
            if let field = view as? NSTextField, field.isEditable { return field }
            return view.subviews.lazy.compactMap { editableField(in: $0) }.first
        }
        controllerB.reshowLastFilter(nil)
        try wait { controllerB.previewPanel != nil }
        let rankField = editableField(in: controllerB.previewPanel?.window?.contentView)
        check(rankField?.integerValue == 9,
              "a reopened rank filter's field shows the committed radius (\(rankField?.integerValue ?? -1))")
        controllerB.previewPanel?.cancel()
        try wait { controllerB.previewPanel == nil }
        try drain(docB)
        controllerB.window?.orderOut(nil)
        controllerA.window?.orderOut(nil)
    }
}
