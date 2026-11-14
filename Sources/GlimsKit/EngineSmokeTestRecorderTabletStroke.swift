import AppKit

@MainActor
extension EngineSmokeTest {
    /// Exercises the document's actual V2 gesture path with synthetic samples.
    static func exerciseRecorderTabletStroke(_ session: EngineSession, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "Recorder tablet: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "RecorderTabletFixture", code: 1,
                                             userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
            return condition()
        }
        func drain(_ document: ImageDocument) throws {
            try require(wait { document.pendingWork == 0 && document.recorder.pendingCount == 0 &&
                               !document.strokeIsActive && !EngineActivity.shared.isBusy }, "work did not drain")
        }
        let width = 40, height = 24
        let pixels = Data(repeating: 255, count: width * height * 4)
        let image = try session.newImage(pixels: .init(width: width, height: height, pixels: pixels, origin: .zero))
        let document = try ImageDocument(session: session, image: image, name: "Tablet Recorder")
        documents.items.append(document)
        defer {
            var closed = false
            document.closeImageWhenDrained { closed = true }
            expect(wait { closed && (try? session.info(image)) == nil }, "owned image closes")
            documents.items.removeAll { $0 === document }
        }
        document.onError = { _ in }
        try drain(document)
        func imagePixels() throws -> Data { try session.copyPixels(image, merged: true).pixels }
        let before = try imagePixels()
        var brush = EngineSession.Brush()
        brush.tool = .pencil; brush.size = 8; brush.opacity = 1
        brush.red = 0; brush.green = 0; brush.blue = 0; brush.pressureSize = false
        let first = EngineSession.StrokeSampleV2(point: .init(x: 6, y: 8, pressure: 0.8, timeMilliseconds: UInt32.max),
                                                 rotationTurns: 0.25, tangentialPressure: -0.5)
        let next = EngineSession.StrokeSampleV2(point: .init(x: 25, y: 14, pressure: 0.6, timeMilliseconds: 1),
                                                rotationTurns: 0.75, tangentialPressure: 0.5)
        try RecorderPaletteAction.record.perform(on: document)
        document.beginTabletStroke(at: first, brush: brush)
        document.continueTabletStroke([next])
        document.endStroke()
        try drain(document)
        try RecorderPaletteAction.stop.perform(on: document)
        let after = try imagePixels()
        expect(before != after, "live V2 stroke paints")
        try require(document.recorder.records.count == 1, "gesture did not settle into one row")
        let supported = ProcessInfo.processInfo.environment["GLIMS_EXPECT_TABLET_CAPTURE"] == "1"
        if supported {
            guard case .success(.completeTabletStroke(let stroke)) = document.recorder.records[0].resolution else {
                throw NSError(domain: "RecorderTabletFixture", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "V2 capture did not produce a tablet stroke"])
            }
            let trace = try RecorderTabletStrokeTrace(first: .init(native: first), batches: [[.init(native: next)]])
            expect(stroke.trace == trace, "capture retains optional axes, timestamp wrap and batches")
            let metadata = document.recorderFileMetadata
            let file = try RecorderFileCodec.snapshot(document.recorder, recordingID: metadata.recordingID,
                name: metadata.name, origin: metadata.origin, descriptions: document.recorderDescriptions,
                bindings: document.recorderBindingDescriptions)
            let encoded = try RecorderFileCodec.encode(file)
            let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
            let decoded = try RecorderFileCodec.decode(encoded)
            expect(object?["version"] as? Int == 21 && decoded == file,
                   "version 21 recording round-trips")
            document.undo(); try drain(document)
            expect(try imagePixels() == before, "Undo restores the original pixels")
            try document.startReplay()
            try require(wait { document.replayStatus == .finished(total: 1) && document.pendingWork == 0 &&
                               !EngineActivity.shared.isBusy }, "tablet replay did not finish")
            expect(try imagePixels() == after, "guarded replay restores the captured pixels")
        } else {
            guard case .failure = document.recorder.records[0].resolution else {
                throw NSError(domain: "RecorderTabletFixture", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "Older engine invented tablet capture"])
            }
            expect(document.recorder.replayRefusal != nil, "older engine explicitly refuses incomplete capture")
            document.undo(); try drain(document)
            expect(try imagePixels() == before, "older-engine live stroke still undoes")
        }
    }
}
