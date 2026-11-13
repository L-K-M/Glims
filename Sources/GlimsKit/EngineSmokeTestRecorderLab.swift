import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderLab(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var owned: [ImageDocument] = [], loose: [Int32] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "RecorderLabFixture", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.005) }
            try require(condition(), "Lab Recorder work timed out")
        }
        func drain(_ document: ImageDocument) throws {
            try wait { document.pendingWork == 0 && document.recorder.pendingCount == 0 &&
                !document.recorder.isReplaying && !EngineActivity.shared.isBusy }
        }
        func views<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views($0, type) }
        }
        func bindingPicker(_ prepared: RecorderFileSemanticBridge.PreparedRecording, target: ImageDocument,
                           expectedAxis: Int32?, symbol: UUID) throws {
            let parent = NSWindow(contentRect: CGRect(x: 100, y: 100, width: 600, height: 480),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            parent.isReleasedWhenClosed = false
            let sheet = try RecorderBindingSheetController(file: prepared.file, document: target)
            var finished = false
            var chosen: [UUID: ImageDocument.RecorderInstallChoice]?
            defer {
                if let attached = parent.attachedSheet { parent.endSheet(attached, returnCode: .cancel) }
                parent.orderOut(nil); parent.close()
                withExtendedLifetime(sheet) {}
            }
            parent.makeKeyAndOrderFront(nil)
            sheet.begin(on: parent) { chosen = $0; finished = true }
            try wait { parent.attachedSheet != nil }
            guard let content = parent.attachedSheet?.contentView,
                  let popup = views(content, NSPopUpButton.self).first,
                  let load = views(content, NSButton.self).first(where: { $0.title == "Load Recording" }),
                  let cancel = views(content, NSButton.self).first(where: { $0.title == "Cancel" }) else {
                return try require(false, "Lab binding sheet controls missing")
            }
            let candidates = popup.itemArray.compactMap { $0.representedObject as? ImageDocument.RecorderInstallChoice }
            check(!load.isEnabled, "Lab picker never selects a destination automatically")
            if let expectedAxis {
                check(candidates == [.channel(expectedAxis)], "Lab picker offers only the matching physical axis and precision")
                guard let index = popup.itemArray.firstIndex(where: { ($0.representedObject as? ImageDocument.RecorderInstallChoice) == .channel(expectedAxis) }) else {
                    return try require(false, "Matching Lab choice missing")
                }
                popup.selectItem(at: index)
                _ = popup.sendAction(popup.action, to: popup.target)
                check(load.isEnabled, "Explicit Lab choice enables Load Recording")
                load.performClick(nil)
                try wait { finished && parent.attachedSheet == nil }
                check(chosen == [symbol: .channel(expectedAxis)], "Lab sheet returns the explicit axis choice")
            } else {
                check(candidates.isEmpty && !popup.isEnabled, "Lab picker refuses incompatible precision")
                cancel.performClick(nil)
                try wait { finished && parent.attachedSheet == nil }
                check(chosen == nil, "Lab picker Cancel returns no binding")
            }
        }
        func pixels(_ image: Int32) throws -> Data {
            let result = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 12, height: 8))
            return result.dataProvider!.data! as Data
        }
        func document(_ image: Int32) throws -> ImageDocument {
            let value = try ImageDocument(session: session, image: image, name: "Lab recording")
            value.onError = { _ in }; owned.append(value); documents.items.append(value)
            loose.removeAll { $0 == image }; return value
        }
        func install(_ prepared: RecorderFileSemanticBridge.PreparedRecording, in target: ImageDocument,
                     symbol: UUID, axis: Int32) throws -> Result<Void, Error> {
            var settled = false
            DispatchQueue.main.async { settled = true }
            try wait { settled }; try drain(target)
            var result: Result<Void, Error>?
            target.installRecording(prepared, checkpoint: try target.recorderInstallCheckpoint(),
                                    choices: [symbol: .channel(axis)]) { result = $0 }
            try drain(target); try require(result != nil, "Lab install callback missing")
            return result!
        }
        defer {
            for document in owned { document.filterPreviewIsOpen = false; document.closeImageWhenDrained() }
            try? wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            check(owned.allSatisfy { (try? session.info($0.image)) == nil }, "Lab Recorder closes owned images")
            documents.items.removeAll { row in owned.contains { $0 === row } }
            for image in loose { try? session.closeImage(image) }
        }
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            for role in 0..<3 {
                func make(_ precision: EngineSession.ColorComponent? = nil) throws -> Int32 {
                    let image = try session.newLabImage(width: 12, height: 8, component: precision ?? component)
                    loose.append(image)
                    let axis = try session.labAxes(image).axes[role]
                    try session.channelCommand(.select, channel: axis.id, image: image)
                    return image
                }
                let a = try document(make()), b = try document(make())
                let wrongPrecision = try document(make(component == .float ? .u8 : .float))
                let aAxis = try session.labAxes(a.image).axes[role]
                let bAxis = try session.labAxes(b.image).axes[role]
                let oracle = try make(), oracleAxis = try session.labAxes(oracle).axes[role]
                let expectedValue = role == 0 ? 50.0 : -0.5
                for curves in [false, true] {
                    let label = "Lab \(component)/\(role) \(curves ? "Curves" : "Fill")"
                    for (image, axis) in [(a.image, aAxis), (b.image, bAxis)] {
                        try session.fillLab(image, axis: axis, value: role == 0 ? 25 : -64, opacity: 1)
                    }
                    try a.reload(); try b.reload()
                    try session.fillLab(oracle, axis: oracleAxis, value: expectedValue, opacity: 1)
                    let original = try pixels(a.image), expected = try pixels(oracle), undo = a.undoInfo.undoCount
                    check(RecorderPalettePresentation(document: a).canPerform(.record), "\(label) Record is available")
                    try RecorderPaletteAction.record.perform(on: a)
                    check(RecorderPalettePresentation(document: a).canPerform(.stop), "\(label) Stop is available")
                    var applied: Result<Void, Error>?
                    if curves {
                        a.filterPreviewIsOpen = true
                        var began: Result<UInt64, Error>?
                        a.beginLabCurvesPreview(axis: aAxis) { began = $0 }
                        try drain(a); try require(began != nil, "Missing Lab preview completion")
                        let token = try began!.get()
                        check(a.recorder.records.isEmpty, "\(label) preview does not record")
                        check(a.applyLabCurvesPreview(token, settings: .init(samples: Array(repeating: 0.5, count: 256))) { applied = $0 },
                              "\(label) Apply admitted")
                    } else {
                        check(a.fillLabAxis(aAxis, value: expectedValue, opacity: 1) { applied = $0 }, "\(label) Fill admitted")
                    }
                    try drain(a); a.filterPreviewIsOpen = false
                    try require(applied != nil, "Missing Lab edit result"); try applied!.get()
                    try RecorderPaletteAction.stop.perform(on: a)
                    check(try pixels(a.image) == expected && original != expected && a.undoInfo.undoCount == undo + 1,
                          "\(label) live edit matches physical Fill and one Undo")
                    guard case .lab(let symbol, let identity)? = a.recorderBindingDescriptions[0] else {
                        throw NSError(domain: "RecorderLabFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing Lab binding: \(String(describing: a.recorderBindingDescriptions[0])) records=\(a.recorder.records)"])
                    }
                    check(a.recorder.records.count == 1 && identity.uuid == aAxis.uuid && identity.nativeRole == aAxis.role,
                          "\(label) captures one command and original Lab axis")
                    let url = work.appendingPathComponent("lab-\(component.rawValue)-\(role)-\(curves).glims-recording")
                    var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
                    a.saveRecording(to: url, checkpoint: try a.recorderSaveCheckpoint()) { saved = $0 }
                    try drain(a); try require(saved != nil, "Missing Lab save result"); _ = try saved!.get()
                    let bytes = try Data(contentsOf: url)
                    let json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
                    check(json["version"] as? Int == 13, "\(label) saves version 13")
                    var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
                    a.prepareRecordingFile(at: url, checkpoint: try a.recorderInstallCheckpoint()) { loaded = $0 }
                    try drain(a); try require(loaded != nil, "Missing Lab load result")
                    let prepared = try loaded!.get()
                    if component == .u8, !curves {
                        try bindingPicker(prepared, target: b, expectedAxis: bAxis.id, symbol: symbol)
                        try bindingPicker(prepared, target: wrongPrecision, expectedAxis: nil, symbol: symbol)
                    }
                    do {
                        _ = try RecorderBatchBindings.resolve(file: prepared.file, candidates: b.recorderBatchCandidates(), policy: .matchingNamesAndKinds)
                        check(false, "\(label) batch must require explicit Lab binding")
                    } catch RecorderBatchBindings.MatchError.explicitLabBindingRequired {
                        check(true, "\(label) batch refuses automatic Lab binding")
                    }
                    let wrongAxis = try session.labAxes(b.image).axes[(role + 1) % 3]
                    let history = try session.undoInfo(b.image), before = try pixels(b.image)
                    if case .failure = try install(prepared, in: b, symbol: symbol, axis: wrongAxis.id) {
                        check(true, "\(label) mismatched physical axis refuses installation")
                    } else { check(false, "\(label) wrong-axis installation succeeded") }
                    check(try pixels(b.image) == before && session.undoInfo(b.image) == history,
                          "\(label) refused installation preserves pixels and history")
                    let incompatible = try session.labAxes(wrongPrecision.image).axes[role]
                    if case .failure = try install(prepared, in: wrongPrecision, symbol: symbol, axis: incompatible.id) {
                        check(true, "\(label) mismatched precision refuses installation")
                    } else { check(false, "\(label) wrong-precision installation succeeded") }
                    try install(prepared, in: b, symbol: symbol, axis: bAxis.id).get()
                    check(bAxis.uuid != aAxis.uuid, "\(label) explicit destination owns a distinct UUID")
                    try session.channelCommand(.select, channel: wrongAxis.id, image: b.image); try b.reload()
                    try b.startReplay(); try drain(b)
                    if case .failed = b.replayStatus { check(true, "\(label) changed selection refuses replay") }
                    else { check(false, "\(label) replay redirected to selected axis") }
                    check(try pixels(b.image) == original, "\(label) refused replay preserves original pixels")
                    try session.channelCommand(.select, channel: bAxis.id, image: b.image); try b.reload()
                    check(RecorderPalettePresentation(document: b).canPerform(.replay), "\(label) settled Replay is available")
                    try RecorderPaletteAction.replay.perform(on: b); try drain(b)
                    if case .finished(1) = b.replayStatus { check(true, "\(label) one rebound command replays") }
                    else { check(false, "\(label) replay failed") }
                    check(try pixels(b.image) == expected, "\(label) rebound result matches independent physical Fill")
                    b.undo(); try drain(b)
                    check(try pixels(b.image) == original, "\(label) Undo restores rebound destination")
                    a.undo(); try drain(a)
                    try a.startReplay(); try drain(a)
                    check(try pixels(a.image) == expected, "\(label) original document replays its captured identity")
                }
            }
        }
    }
}
