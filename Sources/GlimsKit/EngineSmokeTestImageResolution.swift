import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// Image > Image Size with the resolution slots (245-247): the menu
    /// item validates for an ordinary image, File > New's panel reads a
    /// resolution with a unit and a width/height unit, and the document's
    /// commands change the resolution alone or the size and resolution
    /// together, each as one undo step, captured by the Recorder. Older
    /// adapters keep the pixel-only sheet and refuse the commands cleanly.
    static func exerciseImageResolution(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        func rowHidden(_ view: NSView) -> Bool {
            var ancestor = view.superview
            while let current = ancestor, !(current is NSGridView) { ancestor = current.superview }
            return (ancestor as? NSGridView)?.cell(for: view)?.row?.isHidden ?? true
        }

        // The Image menu offers Image Size… with the controller's action.
        let imageMenu = MainMenu.make().items.first { $0.title == "Image" }?.submenu
        let menuItem = imageMenu?.items.first { $0.action == #selector(DocumentWindowController.imageSize(_:)) }
        check(menuItem?.title == "Image Size…", "Image offers Image Size…")

        // File > New: the resolution field, its unit and the width/height
        // unit drive the created settings; the rows hide on older adapters.
        func newSettings(supportsResolution: Bool, width: String = "1600", height: String = "1200",
                         widthUnit: String? = nil, resolution: String = "72",
                         resolutionUnit: String? = nil) -> (NewImageSettings?, Bool) {
            let panel = NewImagePanel(supportsLab: false, supportsContents: false,
                                      supportsResolution: supportsResolution)
            defer { panel.close() }
            panel.showWindow(nil)
            guard let content = panel.window?.contentView else { return (nil, false) }
            let views = descendants(content)
            guard let widthField = views.first(where: { $0.accessibilityLabel() == "Width" }) as? NSTextField,
                  let heightField = views.first(where: { $0.accessibilityLabel() == "Height" }) as? NSTextField,
                  let resolutionField = views.first(where: { $0.accessibilityLabel() == "Resolution" }) as? NSTextField,
                  let sizeUnit = views.first(where: { $0.accessibilityLabel() == "Width and height unit" }) as? NSPopUpButton,
                  let resolutionPopup = views.first(where: { $0.accessibilityLabel() == "Resolution unit" }) as? NSPopUpButton,
                  let create = views.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Create" })
            else { return (nil, false) }
            widthField.stringValue = width
            heightField.stringValue = height
            let offered = !rowHidden(resolutionField)
            if offered { resolutionField.stringValue = resolution }
            if let widthUnit {
                sizeUnit.selectItem(withTitle: widthUnit)
                _ = sizeUnit.sendAction(sizeUnit.action, to: sizeUnit.target)
            }
            if let resolutionUnit {
                resolutionPopup.selectItem(withTitle: resolutionUnit)
                _ = resolutionPopup.sendAction(resolutionPopup.action, to: resolutionPopup.target)
            }
            var result: NewImageSettings?
            panel.onCreate = { result = $0 }
            create.performClick(nil)
            return (result, offered)
        }

        let supported = session.supportsImageResolution
        let (plain, offered) = newSettings(supportsResolution: true)
        check(offered && plain?.resolutionX == 72 && plain?.resolutionY == 72 && plain?.width == 1600,
              "File > New defaults to pixels and 72 ppi (\(String(describing: plain?.resolutionX)))")
        let (perCm, _) = newSettings(supportsResolution: true, resolution: "118.11", resolutionUnit: "pixels/cm")
        check(abs((perCm?.resolutionX ?? 0) - 300) < 0.1,
              "a resolution in pixels/cm converts to ppi (\(String(describing: perCm?.resolutionX)))")
        let (inches, _) = newSettings(supportsResolution: true, width: "5", widthUnit: "in", resolution: "144")
        check(inches?.width == 720 && inches?.resolutionX == 144,
              "a width in inches becomes pixels at the chosen resolution (\(String(describing: inches?.width)))")
        let (legacy, legacyOffered) = newSettings(supportsResolution: false, resolution: "300")
        check(!legacyOffered && legacy?.resolutionX == 72,
              "an adapter without the resolution slots hides the rows and keeps 72 ppi")

        // A document on the engine.
        let image = try session.newImage(width: 1200, height: 900)
        let document: ImageDocument
        do { document = try ImageDocument(session: session, image: image, name: "Resolution") }
        catch { try? session.closeImage(image); throw error }
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        defer {
            controller.window?.orderOut(nil)
            var stopped = false; controller.canvas.stopRendering { stopped = true }; wait { stopped }
            var closed = false; document.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === document }
        }
        func settle() {
            document.inputQueue.sync {}
            spin()
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        }
        try document.reload()
        settle()
        let item = NSMenuItem(title: "Image Size…",
                              action: #selector(DocumentWindowController.imageSize(_:)), keyEquivalent: "")

        guard supported else {
            check(document.resolution == nil && controller.validateMenuItem(item),
                  "an older adapter keeps the pixel-only Image Size enabled")
            var refused = false
            do { try SemanticImageCommand.setResolution(x: 150, y: 150).apply(session: session, image: image) }
            catch { refused = (error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue) }
            let undo = try session.undoInfo(image).undoCount
            check(refused && undo == 0, "an older adapter refuses a resolution change without history")
            return
        }

        check(document.resolution != nil && controller.validateMenuItem(item),
              "Image Size is enabled for an ordinary image with a readable resolution")
        check(document.imageSizeRefusal == nil, "Image Size has no refusal for an ordinary image")

        // A sheet already attached blocks presenting another one.
        if let window = controller.window {
            let blocker = NSAlert()
            blocker.messageText = "Blocking sheet"
            blocker.beginSheetModal(for: window) { _ in }
            wait { window.attachedSheet != nil }
            controller.imageSize(nil)
            spin()
            check(window.sheets.count == 1 && window.attachedSheet === blocker.window,
                  "Image Size presents nothing while another sheet is attached (\(window.sheets.count))")
            check(!controller.validateMenuItem(item), "Image Size is disabled while a sheet is attached")
            window.endSheet(blocker.window)
            wait { window.attachedSheet == nil }
            check(controller.validateMenuItem(item), "Image Size is enabled again once the sheet ends")
        }

        // Resample off: the resolution changes, the pixels stay, one undo
        // step, one recorded command.
        let undoBefore = document.undoInfo.undoCount
        try document.startRecording()
        document.setResolution(.init(x: 150, y: 150))
        try document.stopRecording()
        settle()
        var recordedSetResolution = false
        if case .success(.setResolution(let x, let y))? = document.recorder.records.last?.resolution {
            recordedSetResolution = x == 150 && y == 150
        }
        check(document.recorder.records.count == 1 && recordedSetResolution,
              "a resolution-only change records one setResolution command")
        check(document.resolution?.x == 150 && document.resolution?.y == 150
                && document.info.width == 1200 && document.info.height == 900
                && document.undoInfo.undoCount == undoBefore + 1,
              "setting the resolution is one undo step and keeps the pixels "
              + "(\(String(describing: document.resolution?.x)), \(document.info.width)x\(document.info.height))")

        // Resample on: the pixel size and the resolution change together as
        // one undo step.
        try document.startRecording()
        document.resize(toWidth: 600, height: 450, resolution: .init(x: 300, y: 300),
                        interpolation: .cubic)
        try document.stopRecording()
        settle()
        var recordedResize = false
        if case .success(.resize(let width, let height, let xResolution, let yResolution, let interpolation))?
            = document.recorder.records.last?.resolution {
            recordedResize = width == 600 && height == 450 && xResolution == 300 && yResolution == 300
                && interpolation == .cubic
        }
        check(document.recorder.records.count == 2 && recordedResize,
              "a resampling resize records one combined command")
        check(document.info.width == 600 && document.info.height == 450
                && document.resolution?.x == 300 && document.undoInfo.undoCount == undoBefore + 2,
              "a combined resize is one undo step with the new size and resolution "
              + "(\(document.info.width)x\(document.info.height), \(String(describing: document.resolution?.x)))")

        // Undo restores both the size and the resolution.
        document.undo()
        settle()
        check(document.info.width == 1200 && document.info.height == 900
                && document.resolution?.x == 150 && document.undoInfo.undoCount == undoBefore + 1,
              "Undo restores the pixel size and the resolution of the combined resize")
        document.undo()
        settle()
        check(document.info.width == 1200 && document.info.height == 900
                && document.resolution?.x == 300 && document.undoInfo.undoCount == undoBefore,
              "a second Undo restores the original resolution")
    }
}
