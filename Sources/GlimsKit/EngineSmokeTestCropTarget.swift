import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// The Crop tool's Fixed Target Size (facade slot 252): with the
    /// option set to 60 x 40 px at 144 ppi, a canvas drag keeps the
    /// target's proportions and Return crops and resamples as one undo
    /// step and one Recorder row; undo restores the size and the
    /// resolution. With the option off the gesture is the plain crop.
    /// Older adapters refuse the combined command cleanly.
    static func exerciseCropTarget(_ session: EngineSession, documents: DocumentList) throws {
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            let deadline = Date().addingTimeInterval(10)
            while (document.pendingWork != 0 || EngineActivity.shared.isBusy) && Date() < deadline { spin(0.01) }
            spin()
        }

        let oldTool = ToolState.shared.current
        // The settings persist; keep them out of the user's preferences.
        let oldStore = ToolState.shared.cropStore
        let suite = ScratchDefaults.suiteName("smoke-crop-target")
        let defaults = UserDefaults(suiteName: suite)!
        ToolState.shared.cropStore = CropTargetStore(defaults: defaults)
        defer {
            ToolState.shared.cropStore = oldStore
            ToolState.shared.select(oldTool)
            defaults.removePersistentDomain(forName: suite)
        }
        var target = CropTargetSettings()
        target.enabled = true
        target.width = "60"
        target.height = "40"
        target.resolution = "144"
        target.interpolation = .none
        ToolState.shared.select(.crop)
        ToolState.shared.cropTarget = target

        let image = try session.newImage(width: 200, height: 150)
        let document = try ImageDocument(session: session, image: image, name: "Crop Target")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document)
        controller.showWindow(nil)
        defer {
            controller.window?.orderOut(nil)
            var stopped = false; controller.canvas.stopRendering { stopped = true }
            let stopDeadline = Date().addingTimeInterval(20)
            while !stopped && Date() < stopDeadline { spin(0.01) }
            var closed = false; document.closeImageWhenDrained { closed = true }
            let deadline = Date().addingTimeInterval(20)
            while !closed && Date() < deadline { spin(0.01) }
            documents.items.removeAll { $0 === document }
        }
        try document.reload()
        settle(document)
        guard let window = controller.window else { return check(false, "the document window exists") }
        let originalResolution = document.resolution

        guard session.supportsCropResize else {
            var refused = false
            do {
                try SemanticImageCommand.cropResize(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                    width: 60, height: 40, xResolution: 144,
                                                    yResolution: 144, interpolation: .none)
                    .apply(session: session, image: image)
            } catch {
                refused = (error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue)
            }
            let undo = try session.undoInfo(image).undoCount
            check(refused && undo == 0, "an older adapter refuses a crop to a target size without history")
            return
        }

        func pointer(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type,
                location: controller.canvas.convert(CGPoint(x: point.x * controller.canvas.scale,
                                                             y: point.y * controller.canvas.scale), to: nil),
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        func key(_ code: UInt16, character: String) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                             windowNumber: window.windowNumber, context: nil, characters: character,
                             charactersIgnoringModifiers: character, isARepeat: false, keyCode: code)
        }

        // A drag from (10,10) toward (40,40) snaps to the 3:2 target:
        // the drag's 30 px height wins and the width follows to 45 px.
        let undoBefore = document.undoInfo.undoCount
        if let down = pointer(.leftMouseDown, CGPoint(x: 10, y: 10)),
           let dragged = pointer(.leftMouseDragged, CGPoint(x: 40, y: 40)),
           let up = pointer(.leftMouseUp, CGPoint(x: 40, y: 40)) {
            controller.canvas.mouseDown(with: down)
            controller.canvas.mouseDragged(with: dragged)
            controller.canvas.mouseUp(with: up)
            spin()
        } else { return check(false, "the crop drag events exist") }
        check(controller.canvas.tools.pendingCrop == CGRect(x: 10, y: 10, width: 45, height: 30),
              "the drag keeps the target's 3:2 proportions "
              + "(\(String(describing: controller.canvas.tools.pendingCrop)))")

        try document.startRecording()
        if let enter = key(36, character: "\r") { _ = controller.canvas.tools.keyDown(with: enter) }
        try document.stopRecording()
        settle(document)
        var recordedCropResize = false
        if case .success(.cropResize(_, let width, let height, let x, let y, let interpolation))?
            = document.recorder.records.last?.resolution {
            recordedCropResize = width == 60 && height == 40 && x == 144 && y == 144
                && interpolation == .none
        }
        check(document.recorder.records.count == 1 && recordedCropResize,
              "a crop to a target size records one cropResize row "
              + "(\(document.recorder.records.count) rows)")
        check(document.info.width == 60 && document.info.height == 40
                && document.resolution?.x == 144 && document.resolution?.y == 144
                && document.undoInfo.undoCount == undoBefore + 1,
              "Return crops and resamples to 60x40 at 144 ppi in one undo step "
              + "(\(document.info.width)x\(document.info.height), "
              + "\(String(describing: document.resolution?.x)) ppi)")

        document.undo()
        settle(document)
        check(document.info.width == 200 && document.info.height == 150
                && document.resolution?.x == originalResolution?.x
                && document.undoInfo.undoCount == undoBefore,
              "Undo restores 200x150 and the original resolution")

        // An empty Resolution resamples and keeps the image's own.
        target.resolution = ""
        ToolState.shared.cropTarget = target
        if let down = pointer(.leftMouseDown, CGPoint(x: 10, y: 10)),
           let dragged = pointer(.leftMouseDragged, CGPoint(x: 40, y: 40)),
           let up = pointer(.leftMouseUp, CGPoint(x: 40, y: 40)) {
            controller.canvas.mouseDown(with: down)
            controller.canvas.mouseDragged(with: dragged)
            controller.canvas.mouseUp(with: up)
            spin()
        } else { return check(false, "the empty-resolution drag events exist") }
        if let enter = key(36, character: "\r") { _ = controller.canvas.tools.keyDown(with: enter) }
        settle(document)
        check(document.info.width == 60 && document.info.height == 40
                && document.resolution?.x == originalResolution?.x
                && document.undoInfo.undoCount == undoBefore + 1,
              "an empty Resolution resamples to 60x40 and keeps the image's resolution "
              + "(\(document.info.width)x\(document.info.height), "
              + "\(String(describing: document.resolution?.x)) ppi)")
        document.undo()
        settle(document)

        // With the option off the same gesture is the plain crop of the
        // dragged size.
        target.enabled = false
        ToolState.shared.cropTarget = target
        if let down = pointer(.leftMouseDown, CGPoint(x: 20, y: 20)),
           let dragged = pointer(.leftMouseDragged, CGPoint(x: 60, y: 50)),
           let up = pointer(.leftMouseUp, CGPoint(x: 60, y: 50)) {
            controller.canvas.mouseDown(with: down)
            controller.canvas.mouseDragged(with: dragged)
            controller.canvas.mouseUp(with: up)
            spin()
        } else { return check(false, "the plain crop drag events exist") }
        check(controller.canvas.tools.pendingCrop == CGRect(x: 20, y: 20, width: 40, height: 30),
              "the plain crop keeps the dragged size")
        if let enter = key(36, character: "\r") { _ = controller.canvas.tools.keyDown(with: enter) }
        settle(document)
        check(document.info.width == 40 && document.info.height == 30
                && document.undoInfo.undoCount == undoBefore + 1,
              "with the option off, Return applies the plain crop "
              + "(\(document.info.width)x\(document.info.height))")
    }
}
