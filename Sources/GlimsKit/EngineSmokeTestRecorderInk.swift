import AppKit

@MainActor
extension EngineSmokeTest {
    /// Document services and disk round trips, with independent scalar Fill
    /// oracles. Actual panel/Stop/Close controls have their ink-levels and
    /// ink-edits fixtures; this case opens no windows or dialogs.
    static func exerciseRecorderInk(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var owned: [ImageDocument] = []
        var loose: [Int32] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "RecorderInkFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.005) }
            try require(condition(), "Ink Recorder work timed out")
        }
        func drain(_ document: ImageDocument) throws {
            try wait { document.pendingWork == 0 && document.recorder.pendingCount == 0 &&
                !document.recorder.isReplaying && !EngineActivity.shared.isBusy }
        }
        func pixels(_ image: Int32) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 12, height: 8))
            return rendered.dataProvider!.data! as Data
        }
        func document(_ image: Int32, _ name: String) throws -> ImageDocument {
            let result = try ImageDocument(session: session, image: image, name: name)
            result.onError = { _ in }
            owned.append(result); documents.items.append(result)
            loose.removeAll { $0 == image }
            return result
        }
        func install(_ prepared: RecorderFileSemanticBridge.PreparedRecording, in destination: ImageDocument,
                     symbol: UUID, channel: Int32) throws -> Result<Void, Error> {
            // Direct fixture setup can have native events queued on main even
            // after its RPC returns. Let them update the image revision before
            // simulating the user's installation checkpoint/confirmation.
            var eventsDelivered = false
            DispatchQueue.main.async { eventsDelivered = true }
            try wait { eventsDelivered }
            try drain(destination)
            var result: Result<Void, Error>?
            destination.installRecording(prepared, checkpoint: try destination.recorderInstallCheckpoint(),
                choices: [symbol: .channel(channel)]) { result = $0 }
            try drain(destination)
            try require(result != nil, "Ink recording install callback missing")
            return result!
        }
        defer {
            for item in owned { item.filterPreviewIsOpen = false; item.closeImageWhenDrained() }
            try? wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            check(owned.allSatisfy { (try? session.info($0.image)) == nil }, "ink Recorder closes every owned image")
            documents.items.removeAll { candidate in owned.contains { $0 === candidate } }
            for image in loose { try? session.closeImage(image) }
        }
        guard let profile = NSColorSpace.genericCMYK.iccProfileData else {
            throw ImageDocument.DocumentError.targetChanged
        }
        for mode in [EngineSession.ColorMode.cmyk, .multichannel] {
            for component in [EngineSession.ColorComponent.u8, .u16, .float] {
                func make() throws -> Int32 {
                    let image = try mode == .cmyk
                        ? session.newCmykImage(width: 12, height: 8, component: component, profileICC: profile)
                        : session.newMultichannelImage(width: 12, height: 8, component: component, channelCount: 4)
                    loose.append(image)
                    let channel = try session.channels(image)[0].id
                    try session.channelCommand(.select, channel: channel, image: image)
                    return image
                }
                let a = try document(make(), "Ink recording source")
                let b = try document(make(), "Explicit destination")
                let aChannel = try session.channels(a.image)[0].id
                let bChannels = try session.channels(b.image)
                let bChannel = bChannels[0].id
                let oracle = try make(), oracleChannel = try session.channels(oracle)[0].id
                let originalIdentity = try session.inkChannelIdentity(a.image, channel: aChannel)
                try session.changeChannel(bChannel, image: b.image, .init(name: "Unrelated destination name"))
                try b.reload()
                let operations: [(String, EngineSession.InkEdit?, Double)] = [
                    ("Fill", .init(operation: .fill, intensity: 0.75, opacity: 0.5), component == .u8 ? 128.0 / 255 : 0.5),
                    ("Clear", .clear, 1),
                    ("Invert", .invert, component == .u8 ? 191.0 / 255 : component == .u16 ? 49151.0 / 65535 : 0.75),
                    ("Levels", nil, component == .u8 ? 128.0 / 255 : 0.5)
                ]
                for (name, edit, expectedValue) in operations {
                    for (image, channel) in [(a.image, aChannel), (b.image, bChannel)] {
                        try session.editInk(image, channel: channel,
                            settings: .init(operation: .fill, intensity: 0.25, opacity: 1))
                    }
                    try a.reload(); try b.reload()
                    try session.editInk(oracle, channel: oracleChannel,
                        settings: .init(operation: .fill, intensity: expectedValue, opacity: 1))
                    let original = try pixels(a.image), expected = try pixels(oracle)
                    let aUndo = a.undoInfo.undoCount
                    try a.startRecording()
                    var applied: Result<Void, Error>?
                    if let edit {
                        check(a.editInk(edit, channel: aChannel) { applied = $0 }, "\(name) recording is admitted")
                    } else {
                        a.filterPreviewIsOpen = true
                        var began: Result<UInt64, Error>?
                        a.beginInkLevelsPreview(channel: aChannel) { began = $0 }
                        try drain(a)
                        let token = try began!.get()
                        check(a.recorder.records.isEmpty, "Levels Begin creates no Recorder row")
                        check(a.applyInkLevelsPreview(token, settings: .init(value: .init(gamma: 2))) { applied = $0 },
                              "Levels Apply recording is admitted")
                    }
                    try drain(a)
                    a.filterPreviewIsOpen = false
                    try require(applied != nil, "Ink edit completion missing")
                    try applied!.get()
                    try a.stopRecording()
                    check(try pixels(a.image) == expected && expected != original && a.undoInfo.undoCount == aUndo + 1,
                          "\(name) live capture matches independent scalar Fill and one Undo")
                    guard case .ink(let symbol, let identity)? = a.recorderBindingDescriptions[0] else {
                        throw NSError(domain: "RecorderInkFixture", code: 2)
                    }
                    check(a.recorder.records.count == 1 && identity.uuid == originalIdentity.uuid,
                          "\(name) captures exactly one row bound to the original ink UUID")

                    let url = work.appendingPathComponent("ink-\(mode.rawValue)-\(component.rawValue)-\(name).glims-recording")
                    var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
                    a.saveRecording(to: url, checkpoint: try a.recorderSaveCheckpoint()) { saved = $0 }
                    try drain(a); try require(saved != nil, "Ink recording save callback missing"); _ = try saved!.get()
                    let bytes = try Data(contentsOf: url)
                    let object = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                    check(object["version"] as? Int == 11, "\(name) persists as recording version eleven")
                    var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
                    a.prepareRecordingFile(at: url, checkpoint: try a.recorderInstallCheckpoint()) { loaded = $0 }
                    try drain(a); try require(loaded != nil, "Ink recording load callback missing")
                    let prepared = try loaded!.get()
                    do {
                        _ = try RecorderBatchBindings.resolve(file: prepared.file, candidates: b.recorderBatchCandidates(),
                                                              policy: .matchingNamesAndKinds)
                        check(false, "Batch must not guess ink identity from names")
                    } catch RecorderBatchBindings.MatchError.explicitInkBindingRequired {
                        check(true, "Batch refuses automatic ink matching")
                    }
                    if mode == .cmyk {
                        let before = try pixels(b.image), history = try session.undoInfo(b.image)
                        let wrong = try install(prepared, in: b, symbol: symbol, channel: bChannels[1].id)
                        if case .failure = wrong { check(true, "CMYK rejects binding Cyan to Magenta") }
                        else { check(false, "CMYK role mismatch must refuse installation") }
                        check(try pixels(b.image) == before && session.undoInfo(b.image) == history,
                              "wrong-role installation preserves destination pixels and history")
                    }
                    try install(prepared, in: b, symbol: symbol, channel: bChannel).get()
                    let destinationIdentity = try session.inkChannelIdentity(b.image, channel: bChannel)
                    check(destinationIdentity.uuid != originalIdentity.uuid,
                          "explicit destination binding does not require unrelated documents to share UUIDs")
                    b.selectChannel(bChannels[1].id); try drain(b)
                    let beforeRefusal = try pixels(b.image), refusalUndo = try session.undoInfo(b.image)
                    try b.startReplay(); try drain(b)
                    if case .failed(index: 0, reason: _) = b.replayStatus {
                        check(true, "\(name) replay refuses the wrong selected ink")
                    } else { check(false, "\(name) must not silently select another ink") }
                    check(try pixels(b.image) == beforeRefusal && session.undoInfo(b.image) == refusalUndo,
                          "\(name) selection refusal preserves pixels and Undo")
                    if name == "Levels", component == .u8 {
                        // A successful suffix must never run after a refused
                        // first command, even though it would visibly clear ink.
                        let stoppedFile = RecorderFileValue(recordingID: prepared.file.recordingID,
                            name: prepared.file.name, origin: prepared.file.origin, symbols: prepared.file.symbols,
                            records: prepared.file.records + [.init(ordinal: 1, outcome: .success(
                                .editInk(.init(operation: .clear, intensity: 1, opacity: 1)),
                                .ink(symbol: symbol, identity: identity)))])
                        let stopped = try RecorderFileSemanticBridge.prepare(stoppedFile)
                        try install(stopped, in: b, symbol: symbol, channel: bChannel).get()
                        try b.startReplay(); try drain(b)
                        check(try pixels(b.image) == beforeRefusal && session.undoInfo(b.image) == refusalUndo,
                              "a failed first ink command never schedules its Clear suffix")
                        try install(prepared, in: b, symbol: symbol, channel: bChannel).get()
                        b.selectChannel(bChannel); try drain(b)
                        try session.channelCommand(.select, channel: bChannels[1].id, image: b.image)
                        check(b.selectedChannelIDs == [bChannel], "fixture holds a stale cached ink selection before native replay")
                        try b.startReplay(); try drain(b)
                        if case .failed(index: 0, reason: _) = b.replayStatus {
                            check(true, "fresh worker admission rejects a native retarget behind the cached choice")
                        } else { check(false, "native retarget must refuse before ink replay") }
                        check(try pixels(b.image) == beforeRefusal && session.undoInfo(b.image) == refusalUndo,
                              "native retarget refusal preserves every pixel and Undo entry")
                    }
                    b.selectChannel(bChannel); try drain(b)
                    let bUndo = b.undoInfo.undoCount
                    try b.startReplay(); try drain(b)
                    check(try pixels(b.image) == expected && b.undoInfo.undoCount == bUndo + 1,
                          "\(name) saved replay edits the chosen ink with one Undo")
                    b.undo(); try drain(b)
                    check(try pixels(b.image) == original, "\(name) replay Undo restores exact destination")
                    b.redo(); try drain(b)
                    check(try pixels(b.image) == expected, "\(name) replay Redo restores expected destination")
                    check(try pixels(a.image) == expected, "\(name) destination replay leaves source untouched")
                    if name == "Levels", mode == .multichannel, component == .u8 {
                        let xcf = work.appendingPathComponent("recorded-ink.xcf")
                        try session.save(a.image, to: xcf.path)
                        let reopened = try session.openImage(path: xcf.path); loose.append(reopened)
                        let restored = try document(reopened, "Reopened ink")
                        let restoredChannel = try session.channels(reopened)[0].id
                        let restoredIdentity = try session.inkChannelIdentity(reopened, channel: restoredChannel)
                        check(restoredChannel != aChannel && restoredIdentity.uuid == originalIdentity.uuid,
                              "XCF reopens the same persisted ink UUID with a different runtime ID")
                        try session.channelCommand(.select, channel: restoredChannel, image: reopened)
                        try session.editInk(reopened, channel: restoredChannel,
                            settings: .init(operation: .fill, intensity: 0.25, opacity: 1))
                        try restored.reload()
                        try install(prepared, in: restored, symbol: symbol, channel: restoredChannel).get()
                        try restored.startReplay(); try drain(restored)
                        check(try pixels(reopened) == expected, "saved recording replays after XCF reopen and explicit binding")
                    }
                }
            }
        }
    }
}
