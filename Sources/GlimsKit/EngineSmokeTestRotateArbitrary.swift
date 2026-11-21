import AppKit
import CGlimsEngine

@MainActor
extension EngineSmokeTest {
    /// Image ▸ Rotate ▸ Arbitrary: the sheet reads a nonzero angle within
    /// ±359.99 and a direction; the command grows the canvas, fills the
    /// background's new corners with the fill color and undoes in one
    /// step. Adapters without slot 242 keep the command disabled.
    static func exerciseRotateArbitrary(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.01) }
        }

        // The form.
        let form = ArbitraryRotationForm()
        form.angle.stringValue = "30"
        let clockwise = form.clockwiseDegrees
        form.counterclockwise.performClick(nil)
        let counter = form.clockwiseDegrees
        form.angle.stringValue = "360"
        check(clockwise == 30 && counter == -30 && form.clockwise.state == .off && form.clockwiseDegrees == nil,
              "Rotate Canvas reads the angle and direction and refuses 360 "
              + "(\(String(describing: clockwise)), \(String(describing: counter)))")
        let menu = MainMenu.make().items.first { $0.title == "Image" }?.submenu?
            .items.first { $0.title == "Rotate" }?.submenu
        let menuItem = menu?.items.first { $0.action == #selector(DocumentWindowController.rotateImageArbitrary(_:)) }
        check(menuItem?.title == "Arbitrary…", "Image ▸ Rotate offers Arbitrary…")

        // A 40x20 white background under a layer red on its left half.
        let image = try session.newImage(width: 40, height: 20)
        let document: ImageDocument
        do { document = try ImageDocument(session: session, image: image, name: "Turn") }
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
        if try session.layerCommand(.new, image: image) != nil {
            try session.select(.rectangle(CGRect(x: 0, y: 0, width: 20, height: 20)), image: image,
                               options: EngineSession.SelectOptions(antialias: false))
            try session.fill(image: image, at: .zero, mode: .selection, color: .red)
            try session.select(.none, image: image)
        }
        try document.reload()
        let item = NSMenuItem(title: "Arbitrary…",
                              action: #selector(DocumentWindowController.rotateImageArbitrary(_:)), keyEquivalent: "")

        guard session.supportsRotateArbitrary else {
            check(!document.canRotateArbitrary && !controller.validateMenuItem(item),
                  "an older adapter keeps Rotate ▸ Arbitrary disabled")
            var refused = false
            let replay = SemanticImageCommand.rotateCanvas(degrees: 30, fill: try EngineSession.recorderColor(.blue))
            do { try replay.apply(session: session, image: image) }
            catch { refused = (error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue) }
            check(refused && (try? session.undoInfo(image))?.undoCount == document.undoInfo.undoCount,
                  "an older adapter refuses recorded rotation without adding an Undo step")
            return
        }

        check(document.canRotateArbitrary && controller.validateMenuItem(item),
              "Rotate ▸ Arbitrary is enabled for an ordinary layered image")
        if let window = controller.window {
            let blocker = NSAlert()
            blocker.messageText = "Blocking sheet"
            blocker.beginSheetModal(for: window) { _ in }
            wait { window.attachedSheet != nil }
            controller.rotateImageArbitrary(nil)
            spin()
            check(window.sheets.count == 1 && window.attachedSheet === blocker.window,
                  "Rotate Canvas presents nothing while another sheet is attached (\(window.sheets.count))")
            window.endSheet(blocker.window)
            wait { window.attachedSheet == nil }
        }
        let undoBefore = document.undoInfo.undoCount
        try document.startRecording()
        document.rotateCanvas(degrees: -30, fill: .blue)
        try document.stopRecording()
        settle()
        check(document.recorder.records.count == 1, "an accepted arbitrary rotation records one command")
        let info = document.info
        check(info.width >= 44 && info.width <= 47 && info.height >= 37 && info.height <= 40
                && document.undoInfo.undoCount == undoBefore + 1,
              "-30° grows the canvas as one undo step (\(info.width)x\(info.height))")
        let corner = pixel(session, image, x: 0, y: 0)
        let middle = pixel(session, image, x: info.width / 2, y: info.height / 2)
        check(corner == [0, 0, 255, 255] && middle?[3] == 255,
              "the background's new corners take the fill color (\(String(describing: corner)))")

        let rotated = try session.copyPixels(image, merged: true)
        document.undo()
        settle()
        check(document.info.width == 40 && document.info.height == 20 && document.undoInfo.undoCount == undoBefore,
              "Undo restores the 40x20 canvas")

        let file = try RecorderFileCodec.snapshot(document.recorder, recordingID: UUID(), name: "Rotate",
            origin: .init(imageLabel: "Turn", initialWidth: 40, initialHeight: 20), descriptions: .init(), bindings: [:])
        let prepared = try RecorderFileSemanticBridge.prepare(RecorderFileCodec.decode(RecorderFileCodec.encode(file)))
        let checkpoint = try document.recorderInstallCheckpoint()
        var installed: Result<Void, Error>?
        document.installRecording(prepared, checkpoint: checkpoint, choices: [:]) { installed = $0 }
        wait { installed != nil }
        guard let installed else { return check(false, "the saved rotation installs") }
        try installed.get()
        try document.startReplay()
        wait { !document.recorder.isReplaying }
        settle()
        let replayed = try session.copyPixels(image, merged: true)
        check(replayed.width == rotated.width && replayed.height == rotated.height && replayed.pixels == rotated.pixels
                && document.undoInfo.undoCount == undoBefore + 1,
              "the saved rotation replays the exact pixels and fill in one Undo step")
        document.undo()
        settle()

        var errors: [String] = []
        let previousError = document.onError
        document.onError = { errors.append($0) }
        defer { document.onError = previousError }
        try document.startRecording()
        document.rotateCanvas(degrees: 0, fill: .blue)
        try document.stopRecording()
        settle()
        if case .failure? = document.recorder.records.last?.resolution {
            check(true, "a refused angle leaves a failed recording row")
        } else {
            check(false, "a refused angle leaves a failed recording row")
        }
        check(document.info.width == 40 && document.undoInfo.undoCount == undoBefore && errors.count == 1,
              "a zero angle is refused without an undo step (\(errors))")
    }
}
