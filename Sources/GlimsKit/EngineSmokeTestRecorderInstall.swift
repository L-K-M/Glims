import AppKit

private struct RecorderInstallNativeState: Equatable {
    let info: EngineSession.ImageInfo
    let pixels: Data
    let layers: [EngineSession.Layer]
    let channels: [EngineSession.Channel]
    let selectedLayers: [Int32]
    let selectedChannels: [Int32]
    let masks: [Int32: EngineSession.MaskState]
    let quickMask: EngineSession.QuickMaskState
    let selection: CGRect?
    let outline: [EngineSession.Segment]
    let undo: EngineSession.UndoInfo
    let history: EngineSession.History
}

private struct RecorderInstallLogState: Equatable {
    let file: RecorderFileValue?
    let rows: [RecorderFileValue.Record]
    let descriptions: RecorderDescriptionCatalog
    let bindings: [Int: RecorderBindingDescription]
    let replay: RecorderLog<SemanticImageCommand>.ReplayStatus
}

@MainActor
private final class RecorderInstallCompletion {
    var calls = 0
    var heldWork = 0
    var result: Result<Void, Error>?

    var succeeded: Bool {
        if case .success? = result { return true }
        return false
    }
    var error: Error? {
        if case .failure(let error)? = result { return error }
        return nil
    }
}

@MainActor
extension EngineSmokeTest {
    /// Detached file installation through the actual document and engine.
    /// Direct facade calls supply the independent pixel and Undo references.
    static func exerciseRecorderInstall(_ session: EngineSession, documents: DocumentList) throws {
        typealias Choice = ImageDocument.RecorderInstallChoice
        typealias Checkpoint = ImageDocument.RecorderInstallCheckpoint
        typealias InstallError = ImageDocument.RecorderInstallError
        typealias Prepared = RecorderFileSemanticBridge.PreparedRecording
        var checks = 0
        var complete = false
        var owned: [ImageDocument] = []
        var loose: [Int32] = []
        var releases: [DispatchSemaphore] = []

        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            check(condition, "recorder install: \(message)")
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "RecorderInstallFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let limit = Date().addingTimeInterval(20)
            while !condition() && Date() < limit { spin(0.005) }
            return condition()
        }
        func drain(_ doc: ImageDocument) throws {
            try require(wait { doc.pendingWork == 0 && !doc.recorder.isReplaying && !EngineActivity.shared.isBusy },
                        "Recorder install fixture did not drain \(doc.name)")
            spin(0.02)
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        defer {
            releases.forEach { $0.signal() }
            for doc in owned {
                doc.onRecorderChange = nil
                doc.onError = nil
                doc.closeImageWhenDrained()
            }
            expect(wait { owned.allSatisfy { $0.pendingWork == 0 && gone($0.image) } }, "all owned images and accepted work close")
            documents.items.removeAll { doc in owned.contains { $0 === doc } }
            for image in loose { try? session.closeImage(image) }
            expect(loose.allSatisfy(gone), "all independent native references close")
            expect(complete, "all install scenarios completed")
            print("     recorder-install checks: \(checks)")
        }

        func image(salt: Int = 0) throws -> (image: Int32, primary: Int32, extra: Int32) {
            var bytes: [UInt8] = []
            for y in 0..<29 {
                for x in 0..<41 {
                    let red = UInt8((x * 17 + y * 7 + salt) % 256)
                    let green = UInt8((x * 3 + y * 23) % 256)
                    let blue = UInt8((x * x + y * 11 + 31) % 256)
                    let alpha = UInt8(64 + ((x * 7 + y * 13) % 192))
                    bytes.append(contentsOf: [red, green, blue, alpha])
                }
            }
            let handle = try session.newImage(pixels: ClipboardImage(width: 41, height: 29, pixels: Data(bytes), origin: .zero))
            loose.append(handle)
            guard let first = try session.layers(handle).first,
                  let extra = try session.layerCommand(.new, image: handle) else {
                throw ImageDocument.DocumentError.noLayer
            }
            try session.changeLayer(first.id, image: handle, .init(name: "Duplicate"))
            try session.changeLayer(extra, image: handle, .init(name: "Chosen destination"))
            try session.selectLayer(first.id, image: handle)
            return (handle, first.id, extra)
        }
        func document(_ name: String, image: Int32) throws -> ImageDocument {
            let doc = try ImageDocument(session: session, image: image, name: name)
            loose.removeAll { $0 == image }
            owned.append(doc)
            documents.items.append(doc)
            try drain(doc)
            return doc
        }
        func native(_ image: Int32) throws -> RecorderInstallNativeState {
            let info = try session.info(image)
            let render = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: info.width, height: info.height))
            guard let data = render.dataProvider?.data as Data? else { throw ImageDocument.DocumentError.targetChanged }
            let layers = try session.layers(image)
            var masks: [Int32: EngineSession.MaskState] = [:]
            for layer in layers { masks[layer.id] = try session.layerMask(layer.id, image: image) }
            return RecorderInstallNativeState(info: info, pixels: data, layers: layers, channels: try session.channels(image),
                selectedLayers: try session.selectedLayers(image), selectedChannels: try session.selectedItems(.channel, image: image),
                masks: masks, quickMask: try session.quickMask(image), selection: try session.selectionBounds(image: image),
                outline: try session.selectionOutline(image: image), undo: try session.undoInfo(image), history: try session.history(image))
        }
        func recording(_ doc: ImageDocument) throws -> RecorderInstallLogState {
            let rows = try doc.recorder.records.map { record -> RecorderFileValue.Record in
                let outcome: RecorderFileValue.Outcome
                switch record.resolution {
                case .success(let command):
                    outcome = .success(try RecorderFileCommand(command), doc.recorderBindingDescriptions[record.ordinal] ?? .none)
                case .failure(let reason): outcome = .failure(reason)
                case .cancelled(let reason): outcome = .cancelled(reason)
                }
                return .init(ordinal: record.ordinal, outcome: outcome)
            }
            return RecorderInstallLogState(file: doc.recorderLoadedFile, rows: rows, descriptions: doc.recorderDescriptions,
                bindings: doc.recorderBindingDescriptions, replay: doc.replayStatus)
        }
        func hold(_ doc: ImageDocument) throws -> DispatchSemaphore {
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            releases.append(release)
            doc.inputQueue.async { entered.signal(); _ = release.wait(timeout: .now() + 20) }
            try require(entered.wait(timeout: .now() + 3) == .success, "Recorder install fixture input hold did not start")
            return release
        }
        func submit(_ value: Prepared, to doc: ImageDocument, checkpoint: Checkpoint? = nil,
                    choices: [UUID: Choice] = [:]) throws -> RecorderInstallCompletion {
            let stamp = try checkpoint ?? doc.recorderInstallCheckpoint()
            let completion = RecorderInstallCompletion()
            doc.installRecording(value, checkpoint: stamp, choices: choices) { result in
                completion.calls += 1
                completion.heldWork = doc.pendingWork
                completion.result = result
            }
            return completion
        }
        func finish(_ result: RecorderInstallCompletion, on doc: ImageDocument) throws {
            try drain(doc)
            try require(result.calls == 1, "Recorder installation must complete exactly once")
        }
        func recordSelection(_ command: EngineSession.SelectCommand, on doc: ImageDocument) throws {
            try doc.startRecording()
            doc.select(command)
            try doc.stopRecording()
            try drain(doc)
            try require(doc.recorder.records.count == 1 && doc.recorder.replayRefusal == nil, "Old recording fixture did not settle")
        }
        func busy(_ result: RecorderInstallCompletion) -> Bool {
            guard let error = result.error as? ImageDocument.DocumentError else { return false }
            if case .busy = error { return true }
            return false
        }
        func unsettled(_ doc: ImageDocument) -> Bool {
            do { _ = try doc.recorderInstallCheckpoint(); return false }
            catch let error as InstallError { return error == .unsettled }
            catch { return false }
        }

        let layerText = "22222222-2222-2222-2222-222222222222"
        let otherText = "33333333-3333-3333-3333-333333333333"
        let quickText = "44444444-4444-4444-4444-444444444444"
        let layerSymbol = UUID(uuidString: layerText)!
        let otherSymbol = UUID(uuidString: otherText)!
        let quickSymbol = UUID(uuidString: quickText)!
        func symbol(_ id: String, kind: String, name: String) -> String {
            "{\"id\":\"\(id)\",\"description\":{\"name\":\"\(name)\",\"kind\":\"\(kind)\",\"ancestors\":[],\"siblingIndex\":7,\"bounds\":{\"x\":-4,\"y\":7,\"width\":41,\"height\":29}}}"
        }
        let layerDescription = symbol(layerText, kind: "pixel", name: "Duplicate")
        let unusedDescription = symbol(otherText, kind: "channel", name: "Unused original alpha")
        func prepare(_ rows: String, symbols: String = "", name: String = "Original recording") throws -> Prepared {
            let bytes = "{\"format\":\"ch.lkmc.Glims.recording\",\"version\":1,\"recordingID\":\"11111111-1111-1111-1111-111111111111\",\"name\":\"\(name)\",\"origin\":{\"imageLabel\":\"Original source\",\"initialWidth\":41,\"initialHeight\":29},\"symbols\":[\(symbols)],\"records\":[\(rows)]}"
            return try RecorderFileSemanticBridge.prepare(RecorderFileCodec.decode(Data(bytes.utf8)))
        }
        func propertyRow(_ id: String, ordinal: Int = 0) -> String {
            "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":{\"tag\":\"layerProperties\",\"properties\":{\"name\":\"Loaded layer\",\"visible\":false,\"opacity\":0.35,\"mode\":\"multiply\"}},\"binding\":{\"kind\":\"layer\",\"symbol\":\"\(id)\"}}"
        }
        let fullRows = #"""
        {"ordinal":0,"outcome":"success","command":{"tag":"selectionShape","shape":{"tag":"polygon","points":[{"x":3,"y":4},{"x":26,"y":6},{"x":20,"y":21},{"x":5,"y":17}]},"options":{"operation":"replace","antialias":true,"feather":1.25,"cornerRadius":0,"threshold":0.18,"contiguous":true,"sampleMerged":false}},"binding":{"kind":"none"}},
        {"ordinal":1,"outcome":"success","command":{"tag":"selectColor","point":{"x":13,"y":9},"options":{"operation":"add","antialias":true,"feather":0,"cornerRadius":0,"threshold":0.18,"contiguous":true,"sampleMerged":true}},"binding":{"kind":"none"}},
        {"ordinal":2,"outcome":"success","command":{"tag":"selectCommand","command":"invert","radius":2.75},"binding":{"kind":"none"}},
        {"ordinal":3,"outcome":"success","command":{"tag":"transformImage","transform":"rotate90"},"binding":{"kind":"none"}},
        {"ordinal":4,"outcome":"success","command":{"tag":"scale","width":35,"height":43},"binding":{"kind":"none"}},
        {"ordinal":5,"outcome":"success","command":{"tag":"resizeCanvas","width":45,"height":49,"offset":{"x":4,"y":3},"fill":{"space":"srgb","red":0.2,"green":0.35,"blue":0.6,"alpha":0.8}},"binding":{"kind":"none"}},
        {"ordinal":6,"outcome":"success","command":{"tag":"crop","rect":{"x":42,"y":46,"width":-40,"height":-45}},"binding":{"kind":"none"}}
        """# + "," + propertyRow(layerText, ordinal: 7)
        let descriptions = layerDescription + "," + unusedDescription
        let full = try prepare(fullRows, symbols: descriptions)
        let single = try prepare(propertyRow(layerText), symbols: descriptions)

        let fixtureA = try image(), fixtureB = try image(salt: 83), reference = try image()
        let a = try document("Install A", image: fixtureA.image)
        let b = try document("Install B", image: fixtureB.image)
        try recordSelection(.none, on: a)
        try recordSelection(.all, on: b)
        try session.select(.none, image: reference.image)
        let beforeA = try native(a.image), beforeB = try native(b.image), oldB = try recording(b)
        let beforeReference = try native(reference.image)
        let oldA = try recording(a), checkpointA = try a.recorderInstallCheckpoint()
        var notices = 0
        var atomic = false
        a.onRecorderChange = {
            notices += 1
            guard case .available(let unused)? = a.recorderDescriptions.values[otherSymbol] else { return }
            atomic = a.recorderLoadedFile == full.file && a.recorder.records.count == 8
                && a.recorderBindingDescriptions[7] == .layer(layerSymbol)
                && unused.name == "Unused original alpha"
        }
        let installed = try submit(full, to: a, checkpoint: checkpointA, choices: [layerSymbol: .layer(fixtureA.extra)])
        expect(installed.calls == 0 && a.pendingWork == 1 && a.recorder.records.count == oldA.rows.count, "admission holds one read and leaves the old log visible")
        try finish(installed, on: a)
        a.onRecorderChange = nil
        expect(installed.succeeded && installed.heldWork == 1 && a.pendingWork == 0, "completion precedes the counted drain")
        expect(notices == 1 && atomic, "one notification sees every new row and original sidecar")
        expect(try native(a.image) == beforeA, "install preserves A pixels, native targets, dirty state and history")
        expect(try native(b.image) == beforeB && recording(b) == oldB, "B pixels, targets, history and recording remain intact")
        expect(try a.recorderInstallCheckpoint() != checkpointA && a.recorder.pendingCount == 0 && !a.recorder.isRecording, "successful install rotates the checkpoint and leaves a settled log")
        try require(installed.succeeded, "Eight-family fixture could not install")

        let shape = EngineSession.SelectShape.polygon([CGPoint(x: 3, y: 4), CGPoint(x: 26, y: 6), CGPoint(x: 20, y: 21), CGPoint(x: 5, y: 17)])
        try session.select(shape, image: reference.image, options: .init(feather: 1.25, threshold: 0.18))
        try session.selectColor(at: CGPoint(x: 13, y: 9), image: reference.image,
                                options: .init(operation: .add, threshold: 0.18, sampleMerged: true))
        try session.select(.invert, image: reference.image, radius: 2.75)
        try session.transformImage(reference.image, .rotate90)
        try session.scaleImage(reference.image, width: 35, height: 43)
        try session.resizeCanvas(reference.image, width: 45, height: 49, offset: CGPoint(x: 4, y: 3),
                                 fill: NSColor(srgbRed: 0.2, green: 0.35, blue: 0.6, alpha: 0.8))
        try session.crop(image: reference.image, to: CGRect(x: 2, y: 1, width: 40, height: 45))
        try session.changeLayer(reference.extra, image: reference.image, .init(name: "Loaded layer", isVisible: false, opacity: 0.35, mode: "multiply"))
        try a.startReplay()
        try drain(a)
        let afterA = try native(a.image), afterReference = try native(reference.image)
        let extra = afterA.layers.first { $0.id == fixtureA.extra }
        let refExtra = afterReference.layers.first { $0.id == reference.extra }
        expect(a.replayStatus == .finished(total: 8) && a.recorder.records.count == 8 && a.recorderLoadedFile == full.file, "loaded commands replay in order without recursive capture")
        expect(afterA.info.width == 40 && afterA.info.height == 45 && afterA.pixels == afterReference.pixels
            && afterA.selection == afterReference.selection && afterA.outline == afterReference.outline, "replay matches independent native pixels, selection and signed-crop extent")
        expect(extra?.name == "Loaded layer" && extra?.isVisible == false && extra?.opacity == refExtra?.opacity
            && extra?.mode == "multiply" && afterA.layers.first(where: { $0.id == fixtureA.primary })?.name == "Duplicate"
            && afterA.selectedLayers == [fixtureA.primary], "explicit layer receives properties while the selected layer matches the original name")
        let undoDelta = afterReference.undo.undoCount - beforeReference.undo.undoCount
        expect(undoDelta > 1 && afterA.undo.undoCount - beforeA.undo.undoCount == undoDelta
            && afterA.undo.nextUndo == afterReference.undo.nextUndo, "each loaded command retains ordinary native Undo")
        // The facade applies the property setters in order and each can push
        // its own Undo entry. Compare the first native undo on both images.
        func layerProperties(_ state: RecorderInstallNativeState, of id: Int32) -> EngineSession.LayerChange? {
            guard let row = state.layers.first(where: { $0.id == id }) else { return nil }
            return .init(name: row.name, isVisible: row.isVisible, opacity: row.opacity, mode: row.mode)
        }
        try session.undo(reference.image)
        let referenceUndo = try native(reference.image)
        a.undo()
        try drain(a)
        let undone = try native(a.image)
        let undoneProperties = layerProperties(undone, of: fixtureA.extra)
        expect(undoneProperties != nil && undoneProperties == layerProperties(referenceUndo, of: reference.extra)
            && undoneProperties != layerProperties(afterA, of: fixtureA.extra)
            && undone.undo.undoCount == afterA.undo.undoCount - 1 && undone.undo.redoCount == afterA.undo.redoCount + 1
            && undone.undo.nextUndo == referenceUndo.undo.nextUndo && undone.undo.nextRedo == referenceUndo.undo.nextRedo,
               "one Undo matches the direct native property transition and history")
        a.redo()
        try drain(a)
        expect(try native(a.image).layers == afterA.layers && native(b.image) == beforeB && recording(b) == oldB, "Redo restores bound properties while B remains untouched")

        let unsuccessfulRows = fullRows + #",{"ordinal":8,"outcome":"failure","reason":"Native refused\nstate retained"},{"ordinal":9,"outcome":"cancelled","reason":""}"#
        let unsuccessful = try prepare(unsuccessfulRows, symbols: descriptions, name: "Inspection recording")
        let beforeInspection = try native(a.image)
        let inspection = try submit(unsuccessful, to: a, choices: [layerSymbol: .layer(fixtureA.extra)])
        try finish(inspection, on: a)
        let prior = try recording(a)
        let refusesInspectionReplay: Bool
        do { try a.startReplay(); refusesInspectionReplay = false }
        catch let refusal as RecorderLog<SemanticImageCommand>.Refusal { refusesInspectionReplay = refusal == .unsuccessfulRecording }
        expect(inspection.succeeded && prior.rows == unsuccessful.file.records && refusesInspectionReplay && a.pendingWork == 0,
               "failure and cancelled inspection rows survive exactly and fence all replay")
        expect(try native(a.image) == beforeInspection, "unsuccessful-row installation preserves the native image")

        guard let deleted = try session.layerCommand(.new, image: a.image) else { throw ImageDocument.DocumentError.noLayer }
        try session.deleteLayers(a.image, layers: [deleted])
        try drain(a)
        let beforeRefusals = try native(a.image)
        try require(!beforeRefusals.layers.contains { $0.id == deleted }, "Deleted fixture ID remained live")
        let invalid: [(String, [UUID: Choice], InstallError)] = [
            ("missing symbol", [:], .incompleteChoices),
            ("unused extra symbol", [layerSymbol: .layer(fixtureA.extra), otherSymbol: .layer(fixtureA.primary)], .incompleteChoices),
            ("zero ID", [layerSymbol: .layer(0)], .unavailableTarget("Duplicate")),
            ("wrong role", [layerSymbol: .channel(fixtureA.extra)], .unavailableTarget("Duplicate")),
            ("foreign B layer", [layerSymbol: .layer(fixtureB.extra)], .unavailableTarget("Duplicate")),
            ("deleted A layer", [layerSymbol: .layer(deleted)], .unavailableTarget("Duplicate")),
        ]
        for (label, choices, expected) in invalid {
            let result = try submit(single, to: a, choices: choices)
            try finish(result, on: a)
            expect(try result.error as? InstallError == expected && result.heldWork == 1
                && recording(a) == prior && native(a.image) == beforeRefusals, "\(label) refuses without replacing the existing log or editing A")
        }
        let aliases = try prepare(propertyRow(layerText) + "," + propertyRow(otherText, ordinal: 1),
                                  symbols: layerDescription + "," + symbol(otherText, kind: "pixel", name: "Duplicate"))
        let duplicate = try submit(aliases, to: a, choices: [layerSymbol: .layer(fixtureA.extra), otherSymbol: .layer(fixtureA.extra)])
        try finish(duplicate, on: a)
        expect(try duplicate.error as? InstallError == .duplicateTarget && recording(a) == prior && native(a.image) == beforeRefusals,
               "two source symbols cannot alias one live target")
        let foreignCheckpoint = try submit(single, to: a, checkpoint: b.recorderInstallCheckpoint(), choices: [layerSymbol: .layer(fixtureA.extra)])
        expect(try foreignCheckpoint.calls == 1 && foreignCheckpoint.heldWork == 0
            && foreignCheckpoint.error as? InstallError == .wrongDocument && recording(a) == prior,
               "B's checkpoint cannot authorize a replacement in A")
        let clearedCheckpoint = try a.recorderInstallCheckpoint()
        try require(a.clearRecording(), "Could not clear the installed recording")
        let afterClear = try submit(single, to: a, checkpoint: clearedCheckpoint, choices: [layerSymbol: .layer(fixtureA.extra)])
        expect(try afterClear.calls == 1 && afterClear.heldWork == 0 && afterClear.error as? InstallError == .staleRecording
            && a.recorderLoadedFile == nil && a.recorder.records.isEmpty && a.recorderDescriptions.values.isEmpty
            && a.recorderBindingDescriptions.isEmpty && native(a.image) == beforeRefusals,
               "clearing an installed log drops its sidecars and invalidates an earlier checkpoint")

        enum Role: String, CaseIterable { case mask, channel, quickMask }
        func roleImage(_ role: Role) throws -> (image: Int32, layer: Int32, extra: Int32, channel: Int32, mask: Int32) {
            let fixture = try image()
            let mask = try session.addLayerMask(fixture.primary, image: fixture.image, source: .white, edit: false)
            try session.select(.all, image: fixture.image)
            let channel = try session.channelFromSelection(fixture.image, name: "Saved alpha")
            try session.selectItems([], kind: .channel, image: fixture.image)
            try session.selectLayer(fixture.primary, image: fixture.image)
            try session.select(.none, image: fixture.image)
            switch role {
            case .mask: try session.setLayerMask(fixture.primary, image: fixture.image, flags: [.editing], values: [.editing])
            case .channel: try session.selectItems([channel], kind: .channel, image: fixture.image)
            case .quickMask: try session.setQuickMask(fixture.image, enabled: true)
            }
            return (fixture.image, fixture.primary, fixture.extra, channel, mask)
        }
        for role in Role.allCases {
            let seeded = try roleImage(role), referenceRole = try roleImage(role)
            let doc = try document("Installed \(role.rawValue)", image: seeded.image)
            let before = try native(doc.image), refBefore = try native(referenceRole.image)
            try require(before.selectedLayers.allSatisfy { $0 == seeded.layer }, "Unexpected native layer selection in role fixture")
            var choices: [UUID: Choice] = [:]
            var roleSymbols: [String] = []
            var maskRows = ""
            let layers = before.selectedLayers.isEmpty ? "[]" : "[\"\(layerText)\"]"
            if !before.selectedLayers.isEmpty {
                choices[layerSymbol] = .layer(seeded.layer)
                roleSymbols.append(layerDescription)
                maskRows = "{\"owner\":\"\(layerText)\",\"isPresent\":true,\"enabled\":true,\"editing\":\(role == .mask),\"showing\":false}"
            }
            let target: String
            let channels: String
            var quickSymbolField = ""
            switch role {
            case .mask:
                try require(before.selectedLayers == [seeded.layer] && before.selectedChannels.isEmpty, "Mask role setup did not select its owner")
                target = "{\"kind\":\"mask\",\"owner\":\"\(layerText)\"}"
                channels = "[]"
            case .channel:
                try require(before.selectedChannels == [seeded.channel], "Saved channel role setup did not select its channel")
                choices[otherSymbol] = .channel(seeded.channel)
                roleSymbols.append(symbol(otherText, kind: "channel", name: "Saved alpha"))
                target = "{\"kind\":\"channel\",\"symbol\":\"\(otherText)\"}"
                channels = "[\"\(otherText)\"]"
            case .quickMask:
                let id = before.quickMask.channel
                try require(before.quickMask.enabled && id > 0 && before.selectedChannels == [id], "Quick Mask role setup did not select its real channel")
                choices[quickSymbol] = .quickMask(id)
                roleSymbols.append(symbol(quickText, kind: "quickMask", name: "Original Quick Mask"))
                target = "{\"kind\":\"quickMask\",\"symbol\":\"\(quickText)\"}"
                channels = "[\"\(quickText)\"]"
                quickSymbolField = ",\"symbol\":\"\(quickText)\""
            }
            let color = before.quickMask.color
            let colorJSON = "{\"space\":\"srgb\",\"red\":\(Double(color.redComponent)),\"green\":\(Double(color.greenComponent)),\"blue\":\(Double(color.blueComponent)),\"alpha\":\(Double(color.alphaComponent))}"
            let quick = "{\"enabled\":\(role == .quickMask),\"inverted\":\(before.quickMask.inverted),\"color\":\(colorJSON)\(quickSymbolField)}"
            let context = "{\"kind\":\"context\",\"context\":{\"layers\":\(layers),\"channels\":\(channels),\"target\":\(target),\"masks\":[\(maskRows)],\"quickMask\":\(quick)}}"
            let row = #"{"ordinal":0,"outcome":"success","command":{"tag":"selectColor","point":{"x":9,"y":9},"options":{"operation":"replace","antialias":true,"feather":0,"cornerRadius":0,"threshold":0.18,"contiguous":true,"sampleMerged":false}},"binding":"# + context + "}"
            let value = try prepare(row, symbols: roleSymbols.joined(separator: ","), name: "Bound role")
            let result = try submit(value, to: doc, choices: choices)
            try finish(result, on: doc)
            expect(try result.succeeded && result.heldWork == 1 && native(doc.image) == before,
                   "\(role.rawValue) install confirms the explicit role without changing native state")
            try require(result.succeeded, "Could not install the \(role.rawValue) role fixture")
            try session.selectColor(at: CGPoint(x: 9, y: 9), image: referenceRole.image, options: .init(threshold: 0.18))
            let refAfter = try native(referenceRole.image)
            try doc.startReplay()
            try drain(doc)
            let actual = try native(doc.image)
            expect(doc.replayStatus == .finished(total: 1) && actual.pixels == refAfter.pixels && actual.outline == refAfter.outline
                && actual.selection == refAfter.selection && actual.undo.undoCount - before.undo.undoCount == refAfter.undo.undoCount - refBefore.undo.undoCount
                && actual.selectedLayers == before.selectedLayers && actual.selectedChannels == before.selectedChannels,
                   "\(role.rawValue) replay matches direct native color selection and retains the target")

            if role == .mask {
                let old = try recording(doc)
                let missing = try submit(value, to: doc, choices: [layerSymbol: .layer(seeded.extra)])
                try finish(missing, on: doc)
                expect(try missing.error as? InstallError == .missingMask("Duplicate") && recording(doc) == old && native(doc.image) == actual,
                       "a layer without the required mask refuses without loss")
                let raw = try submit(value, to: doc, choices: [layerSymbol: .layer(seeded.mask)])
                try finish(raw, on: doc)
                expect(try raw.error as? InstallError == .unavailableTarget("Duplicate") && recording(doc) == old && native(doc.image) == actual,
                       "a native mask ID cannot masquerade as its layer owner")
                try session.setLayerMask(seeded.layer, image: doc.image, flags: [.editing], values: [])
            } else if role == .channel {
                try session.selectItems([], kind: .channel, image: doc.image)
                try session.selectLayer(seeded.layer, image: doc.image)
            } else {
                try session.setQuickMask(doc.image, enabled: false)
            }
            try drain(doc)
            let changed = try native(doc.image)
            let retained = try recording(doc)
            let rebound = try submit(value, to: doc, choices: choices)
            try finish(rebound, on: doc)
            if role == .quickMask {
                expect(try rebound.error as? InstallError == .unavailableTarget("Original Quick Mask") && recording(doc) == retained,
                       "a removed Quick Mask channel cannot be rebound")
            } else {
                expect(rebound.succeeded, "\(role.rawValue) ownership can bind without changing current selection or mask flags")
            }
            try doc.startReplay()
            try drain(doc)
            let refused: Bool
            if case .failed(index: 0, reason: _) = doc.replayStatus { refused = true } else { refused = false }
            expect(try refused && native(doc.image) == changed, "changed \(role.rawValue) context refuses replay without implicit retargeting")
        }

        let raceFixture = try image()
        let race = try document("Install queue and epoch races", image: raceFixture.image)
        let targetFree = try prepare(#"{"ordinal":0,"outcome":"success","command":{"tag":"transformImage","transform":"flipHorizontal"},"binding":{"kind":"none"}}"#)
        try race.startRecording()
        expect(unsettled(race), "active recording refuses a checkpoint")
        let pending = try hold(race)
        race.select(.all)
        try race.stopRecording()
        expect(race.recorder.pendingCount == 1 && unsettled(race), "stopped recording still refuses while an accepted command settles")
        pending.signal()
        try drain(race)
        let replayHold = try hold(race)
        try race.startReplay()
        expect(unsettled(race), "active replay refuses a checkpoint")
        try race.cancelReplay()
        replayHold.signal()
        try drain(race)

        let queuedStamp = try race.recorderInstallCheckpoint()
        let queued = try hold(race)
        race.select(.none)
        let tooEarly = try submit(targetFree, to: race, checkpoint: queuedStamp)
        expect(tooEarly.calls == 1 && busy(tooEarly) && tooEarly.heldWork == 1 && race.pendingWork == 1, "earlier accepted work refuses install admission")
        queued.signal()
        try drain(race)
        let raceOld = try recording(race)
        let later = try hold(race)
        let waiting = try submit(targetFree, to: race)
        expect(waiting.calls == 0 && race.pendingWork == 1, "accepted install waits behind the captured input queue")
        race.select(.all)
        later.signal()
        try finish(waiting, on: race)
        expect(try busy(waiting) && waiting.heldWork >= 2 && recording(race) == raceOld
            && session.selectionBounds(image: race.image) == CGRect(x: 0, y: 0, width: 41, height: 29),
               "intervening admitted edit drains and the prior recording survives")

        let versionHold = try hold(race)
        let changedVersion = try submit(targetFree, to: race)
        try session.changeLayer(raceFixture.extra, image: race.image, .init(name: "Edited during binding"))
        // Reload reads the native engine directly and does not wait on the held
        // input queue. Keep just the install count during this version change.
        try race.reload()
        let afterVersionEdit = try native(race.image)
        versionHold.signal()
        try finish(changedVersion, on: race)
        expect(try changedVersion.error as? InstallError == .changedImage && changedVersion.heldWork == 1
            && recording(race) == raceOld && native(race.image) == afterVersionEdit,
               "a synchronous native/cache revision change preserves the accepted edit and refuses installation")

        let epoch = try hold(race)
        let stale = try submit(targetFree, to: race)
        try race.startRecording()
        try race.stopRecording()
        epoch.signal()
        try finish(stale, on: race)
        expect(stale.error as? InstallError == .staleRecording && race.recorder.records.isEmpty && race.recorderLoadedFile == nil,
               "an accepted stale install cannot populate a newer epoch")

        let closingFixture = try image()
        let closing = try document("Install closes during read", image: closingFixture.image)
        try recordSelection(.all, on: closing)
        let closingOld = try recording(closing)
        let closingHold = try hold(closing)
        let late = try submit(targetFree, to: closing)
        var closed = 0
        closing.closeImageWhenDrained { closed += 1 }
        let whileClosing = try session.info(closing.image)
        expect(closing.isClosing && closing.pendingWork == 1 && closed == 0 && whileClosing.width == 41,
               "real close waits for the accepted install read")
        closingHold.signal()
        try require(wait { closed == 1 && late.calls == 1 && closing.pendingWork == 0 }, "Close and install did not drain")
        let isClosed: Bool
        if let error = late.error as? ImageDocument.DocumentError, case .closed = error { isClosed = true }
        else { isClosed = false }
        expect(try isClosed && late.heldWork == 1 && recording(closing) == closingOld && gone(closing.image),
               "late completion refuses before native destruction and never adopts the file")
        expect(try native(b.image) == beforeB && recording(b) == oldB, "closing A's owned install leaves B alive and unchanged")
        complete = true
    }
}
