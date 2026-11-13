import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderLabBrush(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var owned: [ImageDocument] = [], loose: [Int32] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "RecorderLabBrush", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.005) }
            try require(condition(), "Lab brush recording timed out")
        }
        func drain(_ document: ImageDocument) throws {
            try wait { document.pendingWork == 0 && document.recorder.pendingCount == 0 &&
                !document.recorder.isReplaying && !EngineActivity.shared.isBusy }
        }
        func pixels(_ image: Int32) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 32, height: 24))
            return rendered.dataProvider!.data! as Data
        }
        func document(_ image: Int32) throws -> ImageDocument {
            let result = try ImageDocument(session: session, image: image, name: "Lab brush recording")
            result.onError = { _ in }; owned.append(result); documents.items.append(result)
            loose.removeAll { $0 == image }; return result
        }
        func install(_ prepared: RecorderFileSemanticBridge.PreparedRecording, target: ImageDocument,
                     symbol: UUID, axis: Int32) throws -> Result<Void, Error> {
            var settled = false
            DispatchQueue.main.async { settled = true }
            try wait { settled }; try drain(target)
            var result: Result<Void, Error>?
            target.installRecording(prepared, checkpoint: try target.recorderInstallCheckpoint(),
                choices: [symbol: .channel(axis)]) { result = $0 }
            try drain(target); try require(result != nil, "Missing Lab stroke install completion")
            return result!
        }
        defer {
            for document in owned { document.cancelLabBrushStroke(); document.closeImageWhenDrained() }
            try? wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            check(owned.allSatisfy { (try? session.info($0.image)) == nil }, "Lab stroke Recorder closes owned images")
            documents.items.removeAll { row in owned.contains { $0 === row } }
            for image in loose { try? session.closeImage(image) }
        }
        guard let resource = try session.resources(.brush).first(where: { $0.displayName == "2. Hardness 025" }) else {
            return try require(false, "The native brush fixture is missing")
        }
        var brush = EngineSession.Brush()
        brush.tool = .paintbrush; brush.size = 7; brush.opacity = 0.73; brush.hardness = 0.4
        brush.resource = try session.resourceIdentifiers(resource.id)
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            for role in 0..<3 {
                for tablet in [false, true] {
                    let label = "Lab stroke \(component)/\(role)/\(tablet ? "tablet" : "mouse")"
                    func make(_ precision: EngineSession.ColorComponent? = nil) throws -> Int32 {
                        let image = try session.newLabImage(width: 32, height: 24, component: precision ?? component)
                        loose.append(image)
                        let axis = try session.labAxes(image).axes[role]
                        try session.channelCommand(.select, channel: axis.id, image: image)
                        try session.fillLab(image, axis: axis, value: role == 0 ? 25 : 32, opacity: 1)
                        return image
                    }
                    let source = try document(make()), target = try document(make())
                    let oracle = try make()
                    let sourceAxis = try session.labAxes(source.image).axes[role]
                    let targetAxis = try session.labAxes(target.image).axes[role]
                    let oracleAxis = try session.labAxes(oracle).axes[role]
                    let value = role == 0 ? 75.0 : -64.0
                    let first = EngineSession.StrokeSampleV2(point: .init(x: 6, y: 7, pressure: 0.8,
                        xTilt: -0.3, yTilt: 0.2, timeMilliseconds: UInt32.max - 10),
                        rotationTurns: tablet ? 0 : nil, tangentialPressure: tablet ? 0 : nil)
                    let batches: [[EngineSession.StrokeSampleV2]] = [
                        [.init(point: .init(x: 13, y: 10, pressure: 0.5, xTilt: 0.2, yTilt: -0.4, timeMilliseconds: 3),
                               rotationTurns: tablet ? 0.4 : nil, tangentialPressure: nil)],
                        [.init(point: .init(x: 21, y: 16, pressure: 0.9, timeMilliseconds: 16),
                               rotationTurns: nil, tangentialPressure: tablet ? -0.2 : nil)],
                    ]
                    let baseline = try pixels(source.image), originalUndo = source.undoInfo.undoCount
                    let native = try session.beginLabStroke(image: oracle, axis: oracleAxis, value: value, brush: brush, first: first)
                    for batch in batches { try session.continueTabletStroke(native, points: batch) }
                    try session.endStroke(native)
                    let expected = try pixels(oracle)
                    check(expected != baseline, "\(label) independent native stroke changes visible pixels")
                    source.setLabBrushDraft(String(value), for: sourceAxis)
                    try RecorderPaletteAction.record.perform(on: source)
                    if tablet { source.beginTabletStroke(at: first, brush: brush) }
                    else { source.beginStroke(at: first.point, brush: brush) }
                    // Changing the visible field must not alter accepted settings.
                    source.setLabBrushDraft("0", for: sourceAxis)
                    for batch in batches {
                        if tablet { source.continueTabletStroke(batch) }
                        else { source.continueStroke(batch.map(\.point)) }
                    }
                    source.endStroke(); try drain(source)
                    try RecorderPaletteAction.stop.perform(on: source)
                    check(try pixels(source.image) == expected && source.undoInfo.undoCount == originalUndo + 1,
                          "\(label) recorded live stroke matches independent native begin/continue/end and one Undo")
                    if !session.supportsLabBrushCapture {
                        check(source.recorder.records.count == 1, "\(label) older engine settles its recording row")
                        if case .failure = source.recorder.records.first?.resolution {
                            check(true, "\(label) older engine preserves painting and explicitly refuses recording")
                        } else { check(false, "\(label) older engine invented capture facts") }
                        continue
                    }
                    guard case .success(.completeLabStroke(let captured))? = source.recorder.records.first?.resolution,
                          case .lab(let symbol, let identity)? = source.recorderBindingDescriptions[0] else {
                        return try require(false, "Missing successful physical Lab stroke record: \(label)")
                    }
                    check(source.recorder.records.count == 1 && identity.uuid == sourceAxis.uuid,
                          "\(label) captures exactly one complete gesture and its owning axis")
                    check(captured.settings.value == value && captured.settings.size == brush.size &&
                          captured.settings.opacity == brush.opacity && captured.settings.hardness == brush.hardness,
                          "\(label) owns the originally accepted physical settings")
                    let expectedTrace = try RecorderTabletStrokeTrace(first: .init(native: first),
                        batches: batches.map { try $0.map { try .init(native: $0) } })
                    check(captured.trace == expectedTrace && captured.facts.brush == brush.resource,
                          "\(label) preserves exact V2 samples, optional axes, timestamp wrap and accepted batches")
                    let url = work.appendingPathComponent("lab-brush-\(component)-\(role)-\(tablet).glims-recording")
                    var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
                    source.saveRecording(to: url, checkpoint: try source.recorderSaveCheckpoint()) { saved = $0 }
                    try drain(source); try require(saved != nil, "Missing Lab brush save completion"); _ = try saved!.get()
                    let bytes = try Data(contentsOf: url)
                    check((try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["version"] as? Int == 14,
                          "\(label) saves version 14")
                    var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
                    source.prepareRecordingFile(at: url, checkpoint: try source.recorderInstallCheckpoint()) { loaded = $0 }
                    try drain(source); try require(loaded != nil, "Missing Lab brush load completion")
                    let prepared = try loaded!.get()
                    let wrongAxis = try session.labAxes(target.image).axes[(role + 1) % 3]
                    if case .failure = try install(prepared, target: target, symbol: symbol, axis: wrongAxis.id) {
                        check(true, "\(label) incompatible destination role refuses")
                    } else { check(false, "\(label) wrong role accepted") }
                    let incompatible = try document(make(component == .float ? .u8 : .float))
                    let incompatibleAxis = try session.labAxes(incompatible.image).axes[role]
                    if case .failure = try install(prepared, target: incompatible, symbol: symbol, axis: incompatibleAxis.id) {
                        check(true, "\(label) incompatible precision refuses")
                    } else { check(false, "\(label) wrong precision accepted") }
                    try install(prepared, target: target, symbol: symbol, axis: targetAxis.id).get()
                    try session.channelCommand(.select, channel: wrongAxis.id, image: target.image); try target.reload()
                    let beforeRefusal = try session.undoInfo(target.image)
                    try target.startReplay(); try drain(target)
                    if case .failed = target.replayStatus { check(true, "\(label) changed selection refuses replay") }
                    else { check(false, "\(label) changed selection replayed") }
                    check(try pixels(target.image) == baseline && session.undoInfo(target.image) == beforeRefusal,
                          "\(label) refusal preserves pixels and history")
                    try session.channelCommand(.select, channel: targetAxis.id, image: target.image); try target.reload()
                    try RecorderPaletteAction.replay.perform(on: target); try drain(target)
                    check(target.replayStatus == .finished(total: 1), "\(label) loaded recording replays through palette action")
                    check(try pixels(target.image) == expected && target.undoInfo.undoCount == beforeRefusal.undoCount + 1,
                          "\(label) loaded replay matches independent native pixels and one Undo")
                    target.undo(); try drain(target)
                    check(try pixels(target.image) == baseline, "\(label) replay Undo restores baseline")
                    // A syntactically valid but changed fingerprint must fail before a dab.
                    let digest = captured.facts.fingerprint
                    let changed = (digest.first == "0" ? "1" : "0") + digest.dropFirst()
                    let mismatched = RecorderLabStrokeCommand(settings: captured.settings, trace: captured.trace,
                        facts: .init(brush: captured.facts.brush, fingerprint: changed))
                    let history = try session.undoInfo(target.image)
                    do {
                        try mismatched.apply(session: session, image: target.image, labAxis: targetAxis)
                        check(false, "\(label) changed brush fingerprint accepted")
                    } catch { check(true, "\(label) changed brush fingerprint refuses before painting") }
                    check(try pixels(target.image) == baseline && session.undoInfo(target.image) == history,
                          "\(label) changed fingerprint preserves pixels and full Undo/Redo history")
                    source.undo(); try drain(source)
                    try source.startReplay(); try drain(source)
                    check(try pixels(source.image) == expected, "\(label) original-document binding also replays")
                    source.undo(); try drain(source)
                    try RecorderPaletteAction.record.perform(on: source)
                    source.setLabBrushDraft(String(value), for: sourceAxis)
                    let beforeCancel = try session.undoInfo(source.image)
                    source.beginTabletStroke(at: first, brush: brush)
                    source.continueTabletStroke(batches[0]); source.cancelLabBrushStroke(); try drain(source)
                    try RecorderPaletteAction.stop.perform(on: source)
                    check(try pixels(source.image) == baseline && session.undoInfo(source.image) == beforeCancel,
                          "\(label) cancelled gesture restores pixels and existing Undo/Redo")
                    if case .failure = source.recorder.records.last?.resolution {
                        check(true, "\(label) cancelled gesture cannot become a replayable edit")
                    } else { check(false, "\(label) cancelled stroke recorded as success") }
                }
            }
        }
    }
}
