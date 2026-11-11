import AppKit

private struct ChannelSelectionMask: Equatable {
    let width: Int
    let height: Int
    let bytes: Data
}

@MainActor
extension EngineSmokeTest {
    /// Channel ▸ To Selection recorder capture/replay on the normal engine:
    /// the explicit source channel is bound even when it differs from the
    /// active paint target, replay reproduces an independently computed
    /// selection with normal native Undo, absent or wrong-source bindings
    /// refuse at their indexed row, and the saved file round-trips.
    static func exerciseRecorderChannelSelection(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        let directory = work.appendingPathComponent("recorder-channel-selection-fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks = 0
        var owned: [ImageDocument] = []
        var loose: [Int32] = []

        func expect(_ condition: Bool, _ message: String) {
            checks += 1
            check(condition, "recorder channel selection: \(message)")
        }
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "RecorderChannelSelectionFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.005) }
            return condition()
        }
        func drain(_ document: ImageDocument) throws {
            try require(wait { document.pendingWork == 0 && !document.recorder.isReplaying && !EngineActivity.shared.isBusy },
                        "fixture timed out draining \(document.name)")
            spin(0.02)
        }
        func commands(_ document: ImageDocument) -> [SemanticImageCommand] {
            document.recorder.records.compactMap { if case .success(let command) = $0.resolution { return command }; return nil }
        }
        func isChannelAdd(_ command: SemanticImageCommand) -> Bool {
            if case .channelToSelection(.add) = command { return true }
            return false
        }
        func failedAtIndexOne(_ status: RecorderLog<SemanticImageCommand>.ReplayStatus) -> Bool {
            if case .failed(index: 1, reason: let reason) = status { return !reason.isEmpty }
            return false
        }
        func decodeRefuses(_ text: String, _ message: String) {
            do { _ = try RecorderFileCodec.decode(Data(text.utf8)); expect(false, message) }
            catch { expect(true, message) }
        }
        var pixels: [UInt8] = []
        for y in 0..<29 {
            for x in 0..<41 {
                let red: Int = (x * 17 + y * 7) % 256
                let green: Int = (x * 3 + y * 23) % 256
                let blue: Int = (x * x + y * 11 + 31) % 256
                pixels.append(UInt8(red))
                pixels.append(UInt8(green))
                pixels.append(UInt8(blue))
                pixels.append(255)
            }
        }
        let source = ClipboardImage(width: 41, height: 29, pixels: Data(pixels), origin: .zero)
        let baseRect = CGRect(x: 4, y: 2, width: 20, height: 15)
        let sourceEllipse = CGRect(x: 15, y: 10, width: 18, height: 12)

        // Read the full selection content as a channel thumbnail on a
        // duplicate, so the oracle never mutates the tested image.
        func selectionMask(_ image: Int32) throws -> ChannelSelectionMask {
            let copy = try session.duplicateImage(image)
            defer { try? session.closeImage(copy) }
            let channel = try session.channelFromSelection(copy, name: "Selection oracle")
            guard let rendered = try session.drawableThumbnail(channel, image: copy, maxSize: 4096),
                  let bytes = rendered.dataProvider?.data as Data? else {
                throw NSError(domain: "RecorderChannelSelectionFixture", code: 2)
            }
            return ChannelSelectionMask(width: rendered.width, height: rendered.height, bytes: bytes)
        }
        func outline(_ image: Int32) throws -> [EngineSession.Segment] { try session.selectionOutline(image: image) }

        /// A bare image with two saved channels and the layer paint target.
        func rawFixture() throws -> (image: Int32, layer: Int32, second: Int32) {
            let image = try session.newImage(pixels: source)
            loose.append(image)
            let layer = try session.layers(image)[0].id
            try session.select(.rectangle(CGRect(x: 2, y: 3, width: 12, height: 9)), image: image)
            _ = try session.channelFromSelection(image, name: "Left source")
            try session.select(.ellipse(sourceEllipse), image: image)
            let second = try session.channelFromSelection(image, name: "Right source")
            try session.selectItems([], kind: .channel, image: image)
            try session.select(.none, image: image)
            return (image, layer, second)
        }
        func document(_ name: String) throws -> (doc: ImageDocument, layer: Int32, second: Int32) {
            let fixture = try rawFixture()
            let doc = try ImageDocument(session: session, image: fixture.image, name: name)
            loose.removeAll { $0 == fixture.image }
            owned.append(doc)
            documents.items.append(doc)
            try drain(doc)
            return (doc, fixture.layer, fixture.second)
        }
        func record(_ document: ImageDocument, _ actions: () -> Void) throws {
            try document.startRecording()
            actions()
            try document.stopRecording()
            try drain(document)
        }

        defer {
            for item in owned { item.onRecorderChange = nil; item.onError = nil }
            var closing = 0
            for item in owned where !item.isClosing {
                closing += 1
                item.closeImageWhenDrained { closing -= 1 }
            }
            expect(wait { closing == 0 && owned.allSatisfy { $0.pendingWork == 0 } }, "fixture documents close cleanly")
            documents.items.removeAll { item in owned.contains { $0 === item } }
            for handle in loose { try? session.closeImage(handle) }
            try? FileManager.default.removeItem(at: directory)
            print("     recorder-channel-selection checks: \(checks)")
        }

        // Independent native oracles on bare images: the exact expected
        // selection for the recorded sequence, and the row-0-only selection.
        let oracleImage = try rawFixture()
        try session.select(.rectangle(baseRect), image: oracleImage.image)
        try session.channelToSelection(oracleImage.second, image: oracleImage.image, operation: .add)
        let expectedCombined = try selectionMask(oracleImage.image)
        let expectedOutline = try outline(oracleImage.image)
        let rectOnlyImage = try rawFixture()
        try session.select(.rectangle(baseRect), image: rectOnlyImage.image)
        let expectedRectOnly = try selectionMask(rectOnlyImage.image)

        // Capture: the invoked source channel differs from the active paint
        // target (a layer), and the recorded row binds that explicit channel.
        let a = try document("Channel selection A")
        var aErrors: [String] = []
        a.doc.onError = { aErrors.append($0) }
        expect(a.doc.selectedChannelIDs.isEmpty && a.doc.activeLayer == a.layer,
               "the active paint target is the layer while a saved channel exists")
        try record(a.doc) {
            a.doc.select(.rectangle(baseRect), options: .init())
            a.doc.channelToSelection(a.second, operation: .add)
        }
        let aCommands = commands(a.doc)
        expect(aCommands.count == 2 && a.doc.recorder.replayRefusal == nil,
               "rectangle plus channel-to-selection capture as two replayable rows")
        expect(aCommands.count == 2 && isChannelAdd(aCommands[1]),
               "the second row is the channel selection with its captured operation")
        if case .channel(let symbol)? = a.doc.recorderBindingDescriptions[1],
           case .available(let description)? = a.doc.recorderDescriptions.values[symbol] {
            expect(description.kind == .channel && description.name == "Right source",
                   "the row binds the explicit source channel symbol, not the paint target")
        } else { expect(false, "the row binds the explicit source channel symbol, not the paint target") }
        expect(try selectionMask(a.doc.image) == expectedCombined && outline(a.doc.image) == expectedOutline,
               "the live captured action matches the independent native selection exactly")
        expect(aErrors.isEmpty, "live capture reports no errors")

        // Replay reconstructs the exact selection; each step keeps its normal
        // native Undo entry, and Undo removes the channel step alone.
        try session.select(.none, image: a.doc.image)
        try a.doc.reload()
        try drain(a.doc)
        let undoBeforeReplay = try session.undoInfo(a.doc.image)
        try a.doc.startReplay()
        try drain(a.doc)
        expect(a.doc.replayStatus == .finished(total: 2) && aErrors.isEmpty,
               "replay of both rows finishes on the same image")
        expect(try selectionMask(a.doc.image) == expectedCombined && outline(a.doc.image) == expectedOutline,
               "replay reproduces the independently expected selection exactly")
        expect(try session.undoInfo(a.doc.image).undoCount == undoBeforeReplay.undoCount + 2,
               "each replayed step adds one normal native Undo entry")
        a.doc.undo()
        try drain(a.doc)
        expect(try selectionMask(a.doc.image) == expectedRectOnly
                && session.undoInfo(a.doc.image).undoCount == undoBeforeReplay.undoCount + 1,
               "native Undo removes exactly the replayed channel-to-selection step")

        // Saved-file round-trip: version 3, one channel-binding row, and a
        // clean install plus replay into another image's chosen source channel.
        let url = directory.appendingPathComponent("channel-selection.glimsrecording")
        let checkpoint = try a.doc.recorderInstallCheckpoint()
        var saveResult: Result<ImageDocument.RecorderSaveOutcome, Error>?
        a.doc.saveRecording(to: url, checkpoint: checkpoint) { saveResult = $0 }
        try drain(a.doc)
        expect(saveResult != nil, "save completion ran exactly once")
        try saveResult?.get()
        let fileBytes = try Data(contentsOf: url)
        let file = try RecorderFileCodec.decode(fileBytes)
        expect(String(decoding: fileBytes, as: UTF8.self).contains(#""version":3"#), "the saved file is version 3")
        try require(file.records.count == 2, "the saved file keeps both rows")
        guard case .success(.channelToSelection(.add), .channel(let sourceSymbol)) = file.records[1].outcome else {
            throw NSError(domain: "RecorderChannelSelectionFixture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "The saved channel row lost its binding"])
        }
        expect(file.symbols.first(where: { $0.id == sourceSymbol })?.description.kind == .channel,
               "the saved source symbol keeps its channel description")
        // Strict refusal of a wrong-source binding or a foreign symbol kind.
        var wrongBindingObject = try JSONSerialization.jsonObject(with: fileBytes) as! [String: Any]
        var records = wrongBindingObject["records"] as! [[String: Any]]
        records[1]["binding"] = ["kind": "layer", "symbol": sourceSymbol.uuidString.lowercased()]
        wrongBindingObject["records"] = records
        let wrongBinding = String(decoding: try JSONSerialization.data(withJSONObject: wrongBindingObject), as: UTF8.self)
        decodeRefuses(wrongBinding, "a layer binding is refused as a channel source")
        var wrongKindObject = try JSONSerialization.jsonObject(with: fileBytes) as! [String: Any]
        var symbols = wrongKindObject["symbols"] as! [[String: Any]]
        let sourceIndex = symbols.firstIndex { ($0["id"] as? String)?.lowercased() == sourceSymbol.uuidString.lowercased() }!
        var description = symbols[sourceIndex]["description"] as! [String: Any]
        description["kind"] = "pixel"
        symbols[sourceIndex]["description"] = description
        wrongKindObject["symbols"] = symbols
        let wrongKind = String(decoding: try JSONSerialization.data(withJSONObject: wrongKindObject), as: UTF8.self)
        decodeRefuses(wrongKind, "a pixel description is refused as a channel source")

        let prepared = try RecorderFileSemanticBridge.prepare(file)
        let d = try document("Channel selection D")
        try session.select(.none, image: d.doc.image)
        try d.doc.reload()
        try drain(d.doc)
        var installResult: Result<Void, Error>?
        d.doc.installRecording(prepared, checkpoint: try d.doc.recorderInstallCheckpoint(),
                               choices: [sourceSymbol: .channel(d.second)]) { installResult = $0 }
        try drain(d.doc)
        expect(installResult != nil, "install completion ran")
        try installResult?.get()
        try d.doc.startReplay()
        try drain(d.doc)
        expect(try d.doc.replayStatus == .finished(total: 2)
                && selectionMask(d.doc.image) == expectedCombined,
               "the loaded file replays onto the explicitly chosen source channel in another image")

        // Wrong-source install refusal: a layer choice cannot bind a channel symbol.
        let e = try document("Channel selection E")
        var wrongInstall: Result<Void, Error>?
        e.doc.installRecording(prepared, checkpoint: try e.doc.recorderInstallCheckpoint(),
                               choices: [sourceSymbol: .layer(e.layer)]) { wrongInstall = $0 }
        try drain(e.doc)
        if case .failure(let error) = wrongInstall {
            expect(error as? ImageDocument.RecorderInstallError == .unavailableTarget("Right source"),
                   "a layer choice for the channel symbol refuses the install")
        } else { expect(false, "a layer choice for the channel symbol refuses the install") }

        // Indexed absent-source refusal, fresh native: the channel is deleted
        // behind the document's back, so the cached gate passes and the queued
        // fresh validation fails at internal index 1 (displayed row 2) before mutating.
        for reloaded in [false, true] {
            let item = try document("Absent source \(reloaded)")
            var errors: [String] = []
            item.doc.onError = { errors.append($0) }
            try record(item.doc) {
                item.doc.select(.rectangle(baseRect), options: .init())
                item.doc.channelToSelection(item.second, operation: .replace)
            }
            try require(commands(item.doc).count == 2, "absent-source fixture captured two rows")
            _ = try session.channelCommand(.delete, channel: item.second, image: item.doc.image)
            if reloaded { try item.doc.reload(); try drain(item.doc) }
            try item.doc.startReplay()
            try drain(item.doc)
            expect(failedAtIndexOne(item.doc.replayStatus),
                   "\(reloaded ? "cached" : "fresh-native") absent source fails at internal index 1 (displayed row 2)")
            expect(try selectionMask(item.doc.image) == expectedRectOnly && !errors.isEmpty,
                   "row 0 stays applied, the channel row mutates nothing and reports its reason")
        }
    }
}
