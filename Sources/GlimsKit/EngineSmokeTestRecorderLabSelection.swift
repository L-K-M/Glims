import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderLabSelection(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var owned: [ImageDocument] = [], loose: [Int32] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else { throw NSError(domain: "RecorderLabSelection", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.005) }
            try require(condition(), "Lab selection recording timed out")
        }
        func drain(_ document: ImageDocument) throws {
            try wait { document.pendingWork == 0 && document.recorder.pendingCount == 0 &&
                !document.recorder.isReplaying && !EngineActivity.shared.isBusy }
        }
        func pixels(_ image: Int32) throws -> Data {
            let output = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 20, height: 16))
            try require(output.bytesPerRow == 80, "Unexpected fixture stride")
            return output.dataProvider!.data! as Data
        }
        func document(_ image: Int32) throws -> ImageDocument {
            let result = try ImageDocument(session: session, image: image, name: "Lab selection recording")
            result.onError = { _ in }; owned.append(result); documents.items.append(result)
            loose.removeAll { $0 == image }; return result
        }
        func install(_ prepared: RecorderFileSemanticBridge.PreparedRecording, target: ImageDocument) throws {
            var settled = false
            DispatchQueue.main.async { settled = true }
            try wait { settled }; try drain(target)
            var result: Result<Void, Error>?
            target.installRecording(prepared, checkpoint: try target.recorderInstallCheckpoint(), choices: [:]) { result = $0 }
            try drain(target); try require(result != nil, "Missing selection install completion"); try result!.get()
        }
        defer {
            for document in owned { document.closeImageWhenDrained() }
            try? wait { owned.allSatisfy { (try? session.info($0.image)) == nil } }
            check(owned.allSatisfy { (try? session.info($0.image)) == nil }, "Lab selection Recorder closes owned images")
            documents.items.removeAll { row in owned.contains { $0 === row } }
            for image in loose { try? session.closeImage(image) }
        }
        if !session.supportsLabSelections {
            let image = try session.newLabImage(width: 20, height: 16, component: .u8); loose.append(image)
            let before = try session.undoInfo(image), original = try pixels(image)
            do {
                try RecorderLabSelectionCommand.command(.all).apply(session: session, image: image)
                check(false, "Older producer replay must refuse its missing typed selection capability")
            } catch { check(true, "Older producer replay refuses its missing typed selection capability") }
            check(try pixels(image) == original && session.undoInfo(image) == before && session.selectionBounds(image: image) == nil,
                  "Older producer refusal preserves pixels, mask and history")
            return
        }
        let base = CGRect(x: 2, y: 2, width: 8, height: 8)
        var hard = EngineSession.SelectOptions(); hard.antialias = false
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            for scenario in 0..<15 {
                let label = "Lab selection \(component)/\(scenario)"
                func make() throws -> Int32 {
                    let image = try session.newLabImage(width: 20, height: 16, component: component)
                    loose.append(image)
                    try session.selectLab(.rectangle(base), image: image, options: hard)
                    return image
                }
                let source = try document(make()), target = try document(make()), oracle = try make()
                let sourceAxis = try session.labAxes(source.image).axes[2]
                try session.channelCommand(.select, channel: sourceAxis.id, image: source.image); try source.reload()
                let axesBefore = try session.labAxes(source.image), white = try pixels(source.image)
                let originalOutline = try session.selectionOutline(image: source.image)
                let before = try session.undoInfo(source.image)
                var options = EngineSession.SelectOptions()
                options.operation = [EngineSession.SelectOperation.replace, .add, .subtract, .intersect][scenario % 4]
                options.antialias = scenario >= 4
                options.feather = scenario >= 8 ? 0.75 : 0
                options.cornerRadius = 0
                let shape: EngineSession.SelectShape
                switch scenario / 4 {
                case 0: shape = .rectangle(.init(x: 6, y: 5, width: 10, height: 8))
                case 1: shape = .ellipse(.init(x: -2.25, y: 3.5, width: 14.75, height: 9.25))
                default: shape = .polygon([.init(x: 1.5, y: -2), .init(x: 17.25, y: 6.5), .init(x: 5, y: 14.75)])
                }
                let selection: EngineSession.SelectCommand = scenario == 12 ? .all : scenario == 13 ? .none : .invert
                // Independent native call uses the original fixture inputs,
                // never the captured/decoded Recorder value.
                if scenario < 12 { try session.selectLab(shape, image: oracle, options: options) }
                else { try session.selectLab(selection, image: oracle) }
                let expectedOutline = try session.selectionOutline(image: oracle)
                let expectedBounds = try session.selectionBounds(image: oracle)
                try RecorderPaletteAction.record.perform(on: source)
                if scenario < 12 { source.select(shape, options: options) }
                else { source.select(selection) }
                try drain(source); try RecorderPaletteAction.stop.perform(on: source)
                guard case .success(.labSelection(let captured))? = source.recorder.records.first?.resolution else {
                    return try require(false, "Missing successful Lab selection row: \(label)")
                }
                check(source.recorder.records.count == 1 && source.recorderBindingDescriptions[0] == RecorderBindingDescription.none,
                      "\(label) captures one root-mask command without an axis binding")
                check(try session.labAxes(source.image) == axesBefore && pixels(source.image) == white,
                      "\(label) selection preserves physical axes, identity and displayed samples")
                check(try session.selectionOutline(image: source.image) == expectedOutline && session.selectionBounds(image: source.image) == expectedBounds,
                      "\(label) live captured selection matches independent native geometry")
                check(source.undoInfo.undoCount == before.undoCount + 1, "\(label) captured selection has one native Undo")
                source.undo(); try drain(source)
                check(try session.selectionOutline(image: source.image) == originalOutline, "\(label) Undo restores original mask geometry")
                source.redo(); try drain(source)
                check(try session.selectionOutline(image: source.image) == expectedOutline, "\(label) Redo restores captured mask geometry")
                let url = work.appendingPathComponent("lab-selection-\(component)-\(scenario).glimsrecording")
                var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
                source.saveRecording(to: url, checkpoint: try source.recorderSaveCheckpoint()) { saved = $0 }
                try drain(source); try require(saved != nil, "Missing selection save callback"); _ = try saved!.get()
                let bytes = try Data(contentsOf: url)
                check((try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["version"] as? Int == 15,
                      "\(label) saves a version 15 file")
                var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
                source.prepareRecordingFile(at: url, checkpoint: try source.recorderInstallCheckpoint()) { loaded = $0 }
                try drain(source); try require(loaded != nil, "Missing selection load callback")
                let prepared = try loaded!.get()
                check(prepared.file.symbols.isEmpty, "\(label) loading requires no irrelevant axis or layer choice")
                guard case .success(.labSelection(let detached), .none) = prepared.file.records[0].outcome else {
                    return try require(false, "Saved Lab selection lost its explicit mode or binding")
                }
                check(detached == captured, "\(label) file preserves exact geometry and consumed options")
                try install(prepared, target: target)
                try RecorderPaletteAction.replay.perform(on: target); try drain(target)
                check(target.replayStatus == .finished(total: 1), "\(label) loaded selection replays on a differently selected Lab axis")
                check(try session.selectionOutline(image: target.image) == expectedOutline && session.selectionBounds(image: target.image) == expectedBounds,
                      "\(label) rebound replay matches independent selection geometry")
                check(try pixels(target.image) == white, "\(label) replay does not paint physical samples")
                target.undo(); try drain(target)
                check(try session.selectionOutline(image: target.image) == originalOutline, "\(label) replay Undo restores original mask")
                target.redo(); try drain(target)
                // Physical Fill exposes every coverage sample at displayed
                // precision, including antialias/feather, on target and oracle.
                for image in [target.image, oracle] {
                    let axis = try session.labAxes(image).axes[0]
                    try session.fillLab(image, axis: axis, value: 0, opacity: 1)
                }
                let actual = try pixels(target.image)
                check(try actual == pixels(oracle), "\(label) replay coverage matches independent native rasterization through Fill")
                if scenario < 4 {
                    let agrees = (0..<16).allSatisfy { y in (0..<20).allSatisfy { x in
                        let a = (2..<10).contains(x) && (2..<10).contains(y)
                        let b = (6..<16).contains(x) && (5..<13).contains(y)
                        let selected: Bool
                        switch scenario { case 0: selected = b; case 1: selected = a || b; case 2: selected = a && !b; default: selected = a && b }
                        let offset = (y * 20 + x) * 4, expected: UInt8 = selected ? 0 : 255
                        return actual[offset] == expected && actual[offset + 1] == expected && actual[offset + 2] == expected
                    }}
                    check(agrees, "\(label) hard-mask pixels also match an independent Boolean grid")
                }
                if component == .u8 && scenario == 0 {
                    for image in [try session.newImage(width: 20, height: 16),
                                  try session.newMultichannelImage(width: 20, height: 16, component: .u8, channelCount: 2)] {
                        loose.append(image); let incompatible = try document(image)
                        let original = try pixels(image), history = try session.undoInfo(image)
                        let mask = try session.selectionOutline(image: image)
                        try install(prepared, target: incompatible)
                        try incompatible.startReplay(); try drain(incompatible)
                        if case .failed = incompatible.replayStatus { check(true, "Lab-only replay refuses an ordinary/ink destination") }
                        else { check(false, "Lab-only replay was silently rerouted") }
                        check(try pixels(image) == original && session.undoInfo(image) == history && session.selectionOutline(image: image) == mask,
                              "Wrong-mode refusal leaves pixels, mask and history unchanged")
                    }
                }
            }
        }
    }
}
