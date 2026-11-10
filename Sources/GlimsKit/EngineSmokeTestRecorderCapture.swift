import AppKit

private enum RecorderCaptureFixtureError: Error { case missingPixels, timedOut }

private struct RecorderCaptureNativeState: Equatable {
    let info: EngineSession.ImageInfo
    let pixels: Data
    let selectionBounds: CGRect?
    let selectionOutline: [EngineSession.Segment]
    let undo: EngineSession.UndoInfo
    let historyPosition: Int32
    let historyRows: [EngineSession.HistoryRow]
}

@MainActor
extension EngineSmokeTest {
    /// GLIMS_SMOKE_CASE=recorder-capture: capture only, with no replay or windows.
    static func exerciseRecorderCapture(_ session: EngineSession, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "recorder capture: \(message)") }
        func wait(_ condition: () -> Bool, seconds: TimeInterval = 15) -> Bool {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { spin(0.005) }
            return condition()
        }
        func settle(_ document: ImageDocument, _ message: String) throws {
            let idle = wait { document.pendingWork == 0 && document.recorder.pendingCount == 0 && !EngineActivity.shared.isBusy }
            expect(idle, message)
            guard idle else { throw RecorderCaptureFixtureError.timedOut }
            spin(0.03)
        }
        func snapshot(_ image: Int32) throws -> RecorderCaptureNativeState {
            let info = try session.info(image)
            let rendered = try session.render(image, scale: 1,
                area: CGRect(x: 0, y: 0, width: info.width, height: info.height))
            guard let pixels = rendered.dataProvider?.data as Data? else { throw RecorderCaptureFixtureError.missingPixels }
            let history = try session.history(image)
            return RecorderCaptureNativeState(info: info, pixels: pixels,
                selectionBounds: try session.selectionBounds(image: image),
                selectionOutline: try session.selectionOutline(image: image), undo: try session.undoInfo(image),
                historyPosition: history.currentPosition, historyRows: history.rows)
        }
        // Every row and column differs; rotations, offsets and crops cannot pass
        // merely because a uniform background happened to look unchanged.
        var bytes: [UInt8] = []
        for y in 0..<29 {
            for x in 0..<41 {
                bytes += [UInt8((x * 17 + y * 7) % 256), UInt8((x * 3 + y * 23) % 256),
                          UInt8((x * x + y * 11 + 31) % 256), 255]
            }
        }
        let fixture = ClipboardImage(width: 41, height: 29, pixels: Data(bytes), origin: .zero)
        var owned: [ImageDocument] = []
        var looseImages: [Int32] = []
        func makeImage() throws -> Int32 {
            let image = try session.newImage(pixels: fixture)
            looseImages.append(image)
            return image
        }
        func makeDocument(_ name: String) throws -> ImageDocument {
            let image = try makeImage()
            let document = try ImageDocument(session: session, image: image, name: name)
            looseImages.removeAll { $0 == image }
            owned.append(document)
            documents.items.append(document)
            return document
        }
        defer {
            for document in owned {
                document.onRecorderChange = nil
                if !document.isClosing {
                    var closed = false
                    document.closeImageWhenDrained { closed = true }
                    expect(wait { closed }, "teardown closes \(document.name)")
                }
            }
            expect(owned.allSatisfy { $0.pendingWork == 0 }, "teardown leaves no counted work")
            documents.items.removeAll { item in owned.contains { $0 === item } }
            for image in looseImages { try? session.closeImage(image) }
        }
        func holdInput(_ document: ImageDocument) throws -> DispatchSemaphore {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            document.inputQueue.async {
                entered.signal()
                _ = release.wait(timeout: .now() + 20)
            }
            let held = entered.wait(timeout: .now() + 3) == .success
            expect(held, "bounded input hold begins for \(document.name)")
            guard held else { release.signal(); throw RecorderCaptureFixtureError.timedOut }
            return release
        }

        let document = try makeDocument("Recorder A")
        let other = try makeDocument("Recorder B")
        let reference = try makeImage()
        let initial = try snapshot(document.image)
        let untouchedB = try snapshot(other.image)
        var errors: [String] = []
        var stateNotifications = 0
        var recorderNotifications = 0
        document.onError = { errors.append($0) }
        document.onStateChange = { stateNotifications += 1 }
        document.onRecorderChange = { recorderNotifications += 1 }

        var vertices = [CGPoint(x: 3, y: 4), CGPoint(x: 26, y: 6), CGPoint(x: 20, y: 21), CGPoint(x: 5, y: 17)]
        let expectedShape = EngineSession.SelectShape.polygon(vertices)
        var shapeOptions = EngineSession.SelectOptions()
        shapeOptions.feather = 1.25
        shapeOptions.cornerRadius = 2.5
        shapeOptions.threshold = 0.23
        shapeOptions.contiguous = false
        shapeOptions.sampleMerged = true
        let expectedShapeOptions = shapeOptions
        var colorOptions = EngineSession.SelectOptions()
        colorOptions.operation = .add
        colorOptions.antialias = false
        colorOptions.threshold = 0.18
        let expectedColorOptions = colorOptions
        let colorPoint = CGPoint(x: 13, y: 9)
        let offset = CGPoint(x: 4, y: 3)
        let fill = NSColor(srgbRed: 0.2, green: 0.35, blue: 0.6, alpha: 0.8)
        let crop = CGRect(x: 2, y: 1, width: 40, height: 45)
        let release = try holdInput(document)
        defer { release.signal() }
        try document.startRecording()
        document.select(.polygon(vertices), options: shapeOptions)
        document.selectColor(at: colorPoint, options: colorOptions)
        document.select(.invert, radius: 2.75)
        document.transformImage(.rotate90)
        document.scale(toWidth: 35, height: 43)
        document.resizeCanvas(width: 45, height: 49, offset: offset, fill: fill)
        document.crop(to: crop)
        vertices[0] = CGPoint(x: 99, y: 99)
        shapeOptions.feather = 9
        colorOptions.threshold = 0.9
        try document.stopRecording()
        expect(!document.recorder.isRecording && document.recorder.pendingCount == 7
                && document.recorder.records.isEmpty && document.pendingWork == 7,
               "Stop fences seven accepted edits while their native work is held")
        release.signal() // Never synchronously wait on inputQueue while it is held.
        try settle(document, "all seven completions settle after Stop")

        // This oracle deliberately repeats the intended native calls, rather
        // than invoking SemanticImageCommand.apply or inspecting its switch.
        try session.select(expectedShape, image: reference, options: expectedShapeOptions)
        try session.selectColor(at: colorPoint, image: reference, options: expectedColorOptions)
        try session.select(.invert, image: reference, radius: 2.75)
        try session.transformImage(reference, .rotate90)
        try session.scaleImage(reference, width: 35, height: 43)
        try session.resizeCanvas(reference, width: 45, height: 49, offset: offset, fill: fill)
        try session.crop(image: reference, to: crop)
        let actual = try snapshot(document.image)
        let expected = try snapshot(reference)
        expect(actual == expected, "native pixels, dimensions, selection and history match independent direct calls")
        expect(actual.info.width == 40 && actual.info.height == 45 && actual.pixels != initial.pixels,
               "asymmetric fixture really changed through transform, scale, resize and crop")
        expect(try snapshot(other.image) == untouchedB, "a separate B document keeps its pixels, selection and history")
        expect(errors.isEmpty, "successful capture preserves the original error channel")
        expect(stateNotifications > 0 && recorderNotifications == 16,
               "image-state handler survives and Recorder notifies once per admission/completion plus Start/Stop")

        let commands = document.recorder.records.compactMap { record -> SemanticImageCommand? in
            if case .success(let command) = record.resolution { return command }
            return nil
        }
        expect(document.recorder.records.count == 7 && commands.map(\.title) == [
            "Polygon Selection", "Select Color", "Invert Selection", "Rotate Image 90°",
            "Scale Image", "Resize Canvas", "Crop Image"
        ], "seven successful semantic titles retain acceptance order")
        guard commands.count == 7 else { return }
        if case .selectionShape(let shape, let options) = commands[0] {
            expect(shape == expectedShape && options == expectedShapeOptions, "shape/options capture values before caller mutation")
        } else { expect(false, "shape payload exists") }
        if case .selectColor(let point, let options) = commands[1] {
            expect(point == colorPoint && options == expectedColorOptions, "color point/options capture values before caller mutation")
        } else { expect(false, "color selection payload exists") }
        if case .selectCommand(let command, let radius) = commands[2] {
            expect(command == .invert && radius == 2.75, "selection command/radius payload is exact")
        } else { expect(false, "selection command payload exists") }
        if case .transformImage(let transform) = commands[3] {
            expect(transform == .rotate90, "image transform payload is exact")
        } else { expect(false, "transform payload exists") }
        if case .scale(let width, let height) = commands[4] {
            expect(width == 35 && height == 43, "scale dimensions are exact")
        } else { expect(false, "scale payload exists") }
        if case .resizeCanvas(let width, let height, let capturedOffset, let capturedFill) = commands[5] {
            expect(width == 45 && height == 49 && capturedOffset == offset && capturedFill.isEqual(fill),
                   "canvas dimensions, offset and copied color payload are exact")
        } else { expect(false, "resize payload exists") }
        if case .crop(let rect) = commands[6] {
            expect(rect == crop, "crop rectangle payload is exact")
        } else { expect(false, "crop payload exists") }

        // A full-size saved channel also checks fractional selection coverage,
        // which outline segments alone only describe at the 50% threshold.
        let maskA = try session.channelFromSelection(document.image, name: "Recorder selection oracle")
        let maskR = try session.channelFromSelection(reference, name: "Recorder selection oracle")
        let thumbA = try session.drawableThumbnail(maskA, image: document.image, maxSize: 45)
        let thumbR = try session.drawableThumbnail(maskR, image: reference, maxSize: 45)
        let maskBytesA = thumbA?.dataProvider?.data as Data?
        let maskBytesR = thumbR?.dataProvider?.data as Data?
        expect(thumbA?.width == 40 && thumbA?.height == 45 && maskBytesA != nil && maskBytesA == maskBytesR,
               "full-resolution saved selection coverage matches the independent reference")

        let beforeFailure = try snapshot(document.image)
        try document.startRecording()
        document.scale(toWidth: 0, height: 45) // Admitted by the service; native validation must reject it.
        try document.stopRecording()
        try settle(document, "accepted invalid scale settles its actual native failure")
        expect(errors == ["The new size must be between 1 and 524288 pixels."],
               "native failure still reaches the original onError exactly once")
        let failed = document.recorder.records
        let failedMessage: String?
        if failed.count == 1, case .failure(let message) = failed[0].resolution { failedMessage = message }
        else { failedMessage = nil }
        expect(failedMessage == errors.first && failedMessage != nil
                && document.recorder.replayRefusal == .unsuccessfulRecording,
               "native failure is visible and cannot masquerade as a successful macro")
        expect(try snapshot(document.image) == beforeFailure, "invalid scale changes no native pixels, selection or history")

        let epochRelease = try holdInput(document)
        defer { epochRelease.signal() }
        try document.startRecording()
        document.scale(toWidth: 36, height: 38)
        document.clearRecording()
        try document.startRecording()
        document.transformImage(.flipHorizontal)
        try document.stopRecording()
        expect(document.pendingWork == 2 && document.recorder.pendingCount == 1 && document.recorder.records.isEmpty,
               "new epoch fences only the old recording token, preserving both accepted engine jobs")
        epochRelease.signal()
        try settle(document, "old/new epoch native edits both drain")
        try session.scaleImage(reference, width: 36, height: 38)
        try session.transformImage(reference, .flipHorizontal)
        let epochTitles = document.recorder.records.compactMap { record -> String? in
            if case .success(let command) = record.resolution { return command.title }
            return nil
        }
        expect(epochTitles == ["Flip Image Horizontally"], "late old-epoch success cannot populate the new log")
        expect(try snapshot(document.image) == snapshot(reference), "epoch fencing preserves native execution order and values")
        expect(errors.count == 1, "expected stale tokens add no error or invariant failure")

        let closing = try makeDocument("Recorder close")
        let closeReference = try makeImage()
        try session.scaleImage(closeReference, width: 27, height: 19)
        let expectedBeforeClose = try snapshot(closeReference)
        let closeRelease = try holdInput(closing)
        defer { closeRelease.signal() }
        var closeErrors: [String] = []
        var closeRequests = 0
        var closeCompletions = 0
        var closeRecorderNotifications = 0
        var observedBeforeClose: RecorderCaptureNativeState?
        closing.onError = { closeErrors.append($0) }
        try closing.startRecording()
        closing.onRecorderChange = {
            closeRecorderNotifications += 1
            if closeRequests == 0 {
                closeRequests += 1
                closing.closeImageWhenDrained { closeCompletions += 1 }
            } else if closing.recorder.pendingCount == 0 {
                observedBeforeClose = try? snapshot(closing.image)
            }
        }
        closing.scale(toWidth: 27, height: 19)
        expect(closing.isClosing && closing.pendingWork == 1 && closing.recorder.pendingCount == 1 && closeCompletions == 0,
               "close requested by admission observer waits for the already-counted native edit")
        closeRelease.signal()
        let closed = wait { closeCompletions == 1 }
        expect(closed, "close observer's accepted work drains and native image closes")
        guard closed else { throw RecorderCaptureFixtureError.timedOut }
        spin(0.05)
        expect(observedBeforeClose == expectedBeforeClose, "native values/history are readable at settlement before counted close")
        let closeTitles = closing.recorder.records.compactMap { record -> String? in
            if case .success(let command) = record.resolution { return command.title }
            return nil
        }
        expect(closeTitles == ["Scale Image"] && closing.recorder.pendingCount == 0 && closing.pendingWork == 0,
               "close loses no successful step and leaves no reservation/work count")
        expect(closeRequests == 1 && closeCompletions == 1 && closeRecorderNotifications == 2 && closeErrors.isEmpty,
               "admission/settlement notify once each and cause no late native-after-close errors")
        closing.onRecorderChange = nil
    }
}
