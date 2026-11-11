import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderStrokeCapture(_ session: EngineSession, documents: DocumentList) throws {
        struct Pixels: Equatable {
            let raw: Data
            let merged: Data
        }
        struct Scene {
            let image: Int32
            let layer: Int32
        }

        var looseImages: [Int32] = []
        var owned: ImageDocument?
        let release = DispatchSemaphore(value: 0)
        var checks = 0
        var complete = false

        func expect(_ value: Bool, _ message: String) {
            checks += 1
            check(value, "Recorder stroke: \(message)")
        }
        func require(_ value: Bool, _ message: String) throws {
            guard value else {
                throw NSError(domain: "RecorderStrokeCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.005) }
            return condition()
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        defer {
            release.signal()
            if let owned {
                owned.closeImageWhenDrained()
                expect(wait { owned.pendingWork == 0 && gone(owned.image) }, "the owning image and accepted input drain")
                documents.items.removeAll { $0 === owned }
            }
            for image in looseImages { try? session.closeImage(image) }
            expect(looseImages.allSatisfy(gone), "reference and temporary images close")
            expect(complete, "all live and reference stroke checks ran")
            print("     recorder-stroke-capture checks: \(checks)")
        }

        // Textured layers with different alpha make the raw and merged
        // comparisons exercise different bytes. Both scenes start identically.
        var background: [UInt8] = [], foreground: [UInt8] = []
        for y in 0..<29 {
            for x in 0..<37 {
                background.append(contentsOf: [UInt8((x * 17 + y * 7) % 256), UInt8(y * 7), UInt8(x * 5), 255])
                foreground.append(contentsOf: [UInt8(x * 6), UInt8((y * 19 + x * 9) % 256), UInt8(y * 8), UInt8(77 + (x + y) % 96)])
            }
        }
        func scene() throws -> Scene {
            let bottom = ClipboardImage(width: 37, height: 29, pixels: Data(background), origin: .zero)
            let top = ClipboardImage(width: 37, height: 29, pixels: Data(foreground), origin: .zero)
            let image = try session.newImage(pixels: bottom)
            looseImages.append(image)
            let layer = try session.pastePixels(image, pixels: top, at: .zero)
            return Scene(image: image, layer: layer)
        }
        func pixels(_ image: Int32) throws -> Pixels {
            try Pixels(raw: session.copyPixels(image, merged: false).pixels,
                       merged: session.copyPixels(image, merged: true).pixels)
        }
        func sameHistory(_ image: Int32, _ other: Int32) throws -> Bool {
            let actual = try session.history(image)
            let reference = try session.history(other)
            let actualUndo = try session.undoInfo(image)
            let referenceUndo = try session.undoInfo(other)
            return actual.currentPosition == reference.currentPosition && actual.rows == reference.rows
                && actualUndo == referenceUndo
        }

        guard let row = try session.resources(.brush).first(where: { $0.displayName == "2. Hardness 025" }) else {
            throw NSError(domain: "RecorderStrokeCapture", code: 2, userInfo: [NSLocalizedDescriptionKey: "The installed Pencil brush fixture is absent"])
        }
        let resource = try session.resourceIdentifiers(row.id)
        let brush = EngineSession.Brush(tool: .pencil, size: 7, opacity: 0.67, red: 0.83, green: 0.15, blue: 0.41,
                                        pressureSize: false, resource: resource)
        let first = EngineSession.StrokePoint(x: 6, y: 7, pressure: 0.91)
        let firstBatch: [EngineSession.StrokePoint] = [
            .init(x: 10, y: 8, pressure: 0.73, timeMilliseconds: 17),
            .init(x: 15, y: 11, pressure: 0.58, timeMilliseconds: 34),
        ]
        let finalBatch: [EngineSession.StrokePoint] = [
            .init(x: 20, y: 16, pressure: 0.85, timeMilliseconds: 50),
            .init(x: 26, y: 17, pressure: 0.94, timeMilliseconds: 69),
        ]
        let later = EngineSession.StrokePoint(x: 30, y: 24)
        let laterBatch: [EngineSession.StrokePoint] = [.init(x: 32, y: 22, timeMilliseconds: 15)]

        let actual = try scene(), reference = try scene()
        let doc = try ImageDocument(session: session, image: actual.image, name: "Recorder Pencil")
        owned = doc
        looseImages.removeAll { $0 == actual.image }
        documents.items.append(doc)
        var errors: [String] = []
        doc.onError = { errors.append($0) }

        func drain() throws {
            try require(wait { doc.pendingWork == 0 && doc.recorder.pendingCount == 0 && !EngineActivity.shared.isBusy },
                        "The Pencil fixture did not drain")
        }
        func referenceStroke(_ point: EngineSession.StrokePoint, batches: [[EngineSession.StrokePoint]]) throws {
            let stroke = try session.beginStroke(image: reference.image, drawable: reference.layer, brush: brush, first: point)
            do {
                for batch in batches { try session.continueStroke(stroke, points: batch) }
            } catch {
                try? session.endStroke(stroke)
                throw error
            }
            try session.endStroke(stroke)
        }
        func hasSelectionPrefix() -> Bool {
            guard let row = doc.recorder.records.first, row.ordinal == 0,
                  case .success(.selectCommand(.all, radius: 0)) = row.resolution else { return false }
            return true
        }

        try drain()
        let initial = try pixels(actual.image)
        expect(try doc.activeDrawable == actual.layer && session.selectedLayers(reference.image) == [reference.layer]
            && initial == pixels(reference.image) && initial.raw != initial.merged,
               "identical textured fixtures have distinct raw/composite bytes and their own selected layer")
        try doc.startRecording()
        doc.select(.all)
        try drain()
        try session.select(.all, image: reference.image)
        let before = try pixels(actual.image)
        let beforeUndo = try session.undoInfo(actual.image)
        expect(try doc.recorder.records.count == 1 && hasSelectionPrefix() && before == pixels(reference.image)
            && sameHistory(actual.image, reference.image), "the known Select All settles first and agrees with its native reference")

        doc.beginStroke(at: first, brush: brush)
        doc.continueStroke(firstBatch)
        let entered = DispatchSemaphore(value: 0)
        doc.inputQueue.async { entered.signal(); _ = release.wait(timeout: .now() + 20) }
        try require(entered.wait(timeout: .now() + 3) == .success, "The hold after native begin and first continuation did not start")
        expect(doc.strokeIsActive && doc.recorder.isRecording && hasSelectionPrefix() && doc.recorder.records.count == 1,
               "the accepted Pencil remains an open gesture after its first native batch")
        try doc.stopRecording()
        doc.continueStroke(finalBatch)
        doc.endStroke()
        expect(!doc.strokeIsActive && !doc.recorder.isRecording && doc.pendingWork >= 2
            && doc.recorder.records.count == 1, "Stop fences new capture while the accepted Pencil continuation and end stay queued")
        release.signal()
        try drain()

        // Apply the literal input to a separate native image through the
        // facade directly, independent of document capture and replay.
        try referenceStroke(first, batches: [firstBatch, finalBatch])
        let painted = try pixels(actual.image)
        let paintedUndo = try session.undoInfo(actual.image)
        expect(try errors.isEmpty && painted.raw != before.raw && painted.merged != before.merged
            && session.selectedLayers(actual.image) == [actual.layer], "the live Pencil changed both buffers on the admitted layer")
        expect(try painted == pixels(reference.image) && sameHistory(actual.image, reference.image),
               "live raw and merged bytes and history match the independent native Pencil")
        expect(paintedUndo.undoCount == beforeUndo.undoCount + 1 && paintedUndo.redoCount == 0,
               "the two continuation batches and end create exactly one native Undo")

        doc.undo(); try drain()
        try session.undo(reference.image)
        expect(try pixels(actual.image) == before && pixels(reference.image) == before
            && sameHistory(actual.image, reference.image), "ordinary Undo restores both initial buffers and the reference history position")
        doc.redo(); try drain()
        try session.redo(reference.image)
        expect(try pixels(actual.image) == painted && pixels(reference.image) == painted
            && sameHistory(actual.image, reference.image), "ordinary Redo restores both exact painted buffers")

        doc.beginStroke(at: later, brush: brush)
        doc.continueStroke(laterBatch)
        doc.endStroke(); try drain()
        try referenceStroke(later, batches: [laterBatch])
        let afterStop = try pixels(actual.image)
        expect(try errors.isEmpty && afterStop != painted && afterStop == pixels(reference.image)
            && session.undoInfo(actual.image).undoCount == paintedUndo.undoCount + 1,
               "a separate post-Stop Pencil paints normally and creates its own native Undo")

        let records = doc.recorder.records
        var capturedPencil = false
        if records.count == 2, records[1].ordinal == 1, case .success(let command) = records[1].resolution {
            capturedPencil = command.title == "Pencil Stroke"
        }
        expect(hasSelectionPrefix() && capturedPencil && doc.recorder.pendingCount == 0 && !doc.recorder.isRecording,
               "the accepted Pencil settles once after Stop in its ordered Recorder row, while the later Pencil stays out")

        if capturedPencil {
            guard case .success(.completeStroke(let command)) = records[1].resolution else {
                throw NSError(domain: "RecorderStrokeCapture", code: 3, userInfo: [NSLocalizedDescriptionKey: "The stroke row lacks its owned payload"])
            }
            expect(try command.facts.brush == resource && command.facts.fingerprint.utf8.count == 64
                   && command.trace.first == .init(first)
                   && command.trace.batches == [firstBatch, finalBatch].map { try $0.map(RecorderStrokeTrace.Point.init) },
                   "the payload preserves the actual brush, first sample and both ordered batches")
            for _ in 0..<2 {
                doc.undo()
                try drain()
                try session.undo(reference.image)
            }
            try doc.startReplay()
            try require(wait { doc.replayStatus == .finished(total: 2) && doc.pendingWork == 0 },
                        "the loaded Pencil commands did not replay")
            try session.select(.all, image: reference.image)
            try referenceStroke(first, batches: [firstBatch, finalBatch])
            expect(try pixels(actual.image) == painted && pixels(actual.image) == pixels(reference.image)
                   && sameHistory(actual.image, reference.image) && doc.recorder.records.count == 2,
                   "whole-stroke replay matches an independent native edit, history and the settled log")
        }

        doc.beginStroke(at: later, brush: brush)
        var refusedMidStroke = false
        do { try doc.startRecording() } catch { refusedMidStroke = true }
        doc.endStroke()
        try drain()
        expect(refusedMidStroke && !doc.recorder.isRecording,
               "starting Recorder mid-stroke cannot capture a suffix")

        try doc.startRecording()
        var unsupported = brush
        unsupported.tool = .paintbrush
        unsupported.red = 0.12
        let beforeUnsupported = try pixels(actual.image)
        doc.beginStroke(at: first, brush: unsupported)
        doc.continueStroke(firstBatch)
        doc.endStroke()
        try doc.stopRecording()
        try drain()
        let unsupportedRow = doc.recorder.records.first
        var recordedRefusal = false
        if case .failure? = unsupportedRow?.resolution { recordedRefusal = true }
        expect(try pixels(actual.image) != beforeUnsupported && recordedRefusal &&
               doc.recorder.records.count == 1 && doc.recorder.replayRefusal != nil,
               "an unsupported stroke paints normally and produces a visible nonreplayable row")
        complete = true
    }
}
