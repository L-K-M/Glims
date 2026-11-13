import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderInkBrush(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var owned: [ImageDocument] = []
        var loose: [Int32] = []

        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "RecorderInkBrushFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ condition: () -> Bool, _ message: String) throws {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.005) }
            try require(condition(), message)
        }
        func drain(_ document: ImageDocument) throws {
            try wait({
                document.pendingWork == 0 && document.recorder.pendingCount == 0 &&
                !document.recorder.isReplaying && !EngineActivity.shared.isBusy
            }, "Ink brush Recorder work timed out")
        }
        func pixels(_ image: Int32) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 32, height: 24))
            guard let data = rendered.dataProvider?.data as Data? else {
                throw NSError(domain: "RecorderInkBrushFixture", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Missing rendered pixels"])
            }
            return data
        }
        func document(_ image: Int32, _ name: String) throws -> ImageDocument {
            let result = try ImageDocument(session: session, image: image, name: name)
            result.onError = { _ in }
            owned.append(result)
            documents.items.append(result)
            loose.removeAll { $0 == image }
            return result
        }
        func install(_ prepared: RecorderFileSemanticBridge.PreparedRecording,
                     target: ImageDocument,
                     symbol: UUID,
                     channel: Int32) throws -> Result<Void, Error> {
            var settled = false
            DispatchQueue.main.async { settled = true }
            try wait({ settled }, "Install precondition events did not settle")
            try drain(target)
            var result: Result<Void, Error>?
            target.installRecording(prepared, checkpoint: try target.recorderInstallCheckpoint(),
                                    choices: [symbol: .channel(channel)]) { result = $0 }
            try drain(target)
            try require(result != nil, "Missing ink brush install completion")
            return result!
        }
        func closeOwned() throws {
            for item in owned { item.cancelInkBrushStroke(); item.closeImageWhenDrained() }
            try wait({ owned.allSatisfy { (try? session.info($0.image)) == nil } },
                     "Ink brush fixture did not close owned images")
            check(owned.allSatisfy { (try? session.info($0.image)) == nil },
                  "Ink brush Recorder closes owned images")
            documents.items.removeAll { row in owned.contains { $0 === row } }
            for image in loose { try? session.closeImage(image) }
            loose.removeAll()
            owned.removeAll()
        }
        defer {
            for item in owned { item.cancelInkBrushStroke(); item.closeImageWhenDrained() }
            let deadline = Date().addingTimeInterval(20)
            while !(owned.allSatisfy { (try? session.info($0.image)) == nil }) && Date() < deadline {
                EngineSmokeTestHost.pumpEvents(for: 0.005)
            }
            documents.items.removeAll { row in owned.contains { $0 === row } }
            for image in loose { try? session.closeImage(image) }
        }

        guard session.supportsInkEdits else {
            return try require(false, "Ink brush fixture requires ink edit support")
        }
        guard let resource = try session.resources(.brush).first(where: { $0.displayName == "2. Hardness 025" }) else {
            return try require(false, "The native brush fixture is missing")
        }

        let modes: [EngineSession.ColorMode] = [.cmyk, .multichannel]
        let components: [EngineSession.ColorComponent] = [.u8, .u16, .float]
        let tools: [EngineSession.Brush.Tool] = [.paintbrush, .pencil]
        let tabletModes = [false, true]

        var brush = EngineSession.Brush()
        brush.tool = .paintbrush
        brush.size = 7
        brush.opacity = 0.6
        brush.hardness = 0.4
        brush.pressureSize = false
        brush.resource = try session.resourceIdentifiers(resource.id)
        let rgb: (Double, Double, Double) = (0.2, 0.4, 0.6)

        if !session.supportsInkBrushCapture {
            var legacy = EngineSession.Brush()
            legacy.tool = .paintbrush
            legacy.size = 7
            legacy.opacity = 0.6
            legacy.hardness = 0.4
            legacy.pressureSize = false
            legacy.red = rgb.0; legacy.green = rgb.1; legacy.blue = rgb.2
            legacy.resource = try session.resourceIdentifiers(resource.id)

            func makeLegacy(_ mode: EngineSession.ColorMode, _ component: EngineSession.ColorComponent) throws -> (Int32, Int32) {
                let image: Int32
                if mode == .cmyk {
                    guard let profile = NSColorSpace.genericCMYK.iccProfileData else {
                        throw NSError(domain: "RecorderInkBrushFixture", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "Missing generic CMYK profile"])
                    }
                    image = try session.newCmykImage(width: 32, height: 24, component: component, profileICC: profile)
                } else {
                    image = try session.newMultichannelImage(width: 32, height: 24, component: component, channelCount: 4)
                }
                loose.append(image)
                let channel = try session.channels(image)[1].id
                try session.channelCommand(.select, channel: channel, image: image)
                try session.editInk(image, channel: channel, settings: .init(operation: .fill, intensity: 1, opacity: 1))
                return (image, channel)
            }

            let (image, _) = try makeLegacy(.cmyk, .u8)
            let doc = try document(image, "Legacy ink brush")
            let baseline = try pixels(image)
            try RecorderPaletteAction.record.perform(on: doc)
            doc.beginStroke(at: .init(x: 6, y: 7, pressure: 0.8), brush: legacy)
            doc.continueStroke([.init(x: 13, y: 10, pressure: 0.5), .init(x: 21, y: 16, pressure: 0.9)])
            doc.endStroke()
            try drain(doc)
            try RecorderPaletteAction.stop.perform(on: doc)
            check(try pixels(image) != baseline, "Older ink engine keeps live paint on non-capturing path")
            check(doc.recorder.records.count == 1, "Older ink engine settles one recording row")
            if case .failure = doc.recorder.records.first?.resolution {
                check(true, "Older ink engine preserves painting and explicitly refuses typed recording")
            } else {
                check(false, "Older ink engine invented capture facts without support")
            }
            try closeOwned()
            return
        }

        for mode in modes {
            for component in components {
                for tool in tools {
                    for tablet in tabletModes {
                        let label = "Ink brush \(mode.rawValue)/\(component.rawValue)/\(tool)/\(tablet ? "tablet" : "mouse")"
                        var toolBrush = brush
                        toolBrush.tool = tool
                        toolBrush.red = rgb.0; toolBrush.green = rgb.1; toolBrush.blue = rgb.2

                        func makeImage() throws -> (image: Int32, channel: Int32, identity: EngineSession.InkChannelIdentity) {
                            let image: Int32
                            if mode == .cmyk {
                                guard let profile = NSColorSpace.genericCMYK.iccProfileData else {
                                    throw NSError(domain: "RecorderInkBrushFixture", code: 3,
                                                  userInfo: [NSLocalizedDescriptionKey: "Missing generic CMYK profile"])
                                }
                                image = try session.newCmykImage(width: 32, height: 24, component: component, profileICC: profile)
                            } else {
                                image = try session.newMultichannelImage(width: 32, height: 24, component: component, channelCount: 4)
                            }
                            loose.append(image)
                            let channels = try session.channels(image)
                            try require(channels.count > 1, "\(label) needs a non-first ink channel")
                            let channel = channels[1].id
                            try session.channelCommand(.select, channel: channel, image: image)
                            try session.editInk(image, channel: channel, settings: .init(operation: .fill, intensity: 1, opacity: 1))
                            let identity = try session.inkChannelIdentity(image, channel: channel)
                            return (image, channel, identity)
                        }

                        let source = try makeImage()
                        let target = try makeImage()
                        let oracle = try makeImage()
                        let sourceDoc = try document(source.image, "Ink brush source \(label)")
                        let targetDoc = try document(target.image, "Ink brush target \(label)")
                        let baseline = try pixels(source.image)
                        let originalUndo = sourceDoc.undoInfo.undoCount

                        let first = EngineSession.StrokeSampleV2(
                            point: .init(x: 6, y: 7, pressure: 0.8, xTilt: -0.3, yTilt: 0.2, timeMilliseconds: UInt32.max - 10),
                            rotationTurns: tablet ? 0 : nil,
                            tangentialPressure: tablet ? 0 : nil)
                        let batches: [[EngineSession.StrokeSampleV2]] = [
                            [.init(point: .init(x: 13, y: 10, pressure: 0.5, xTilt: 0.2, yTilt: -0.4, timeMilliseconds: 3),
                                   rotationTurns: tablet ? 0.4 : nil, tangentialPressure: nil)],
                            [.init(point: .init(x: 21, y: 16, pressure: 0.9, timeMilliseconds: 16),
                                   rotationTurns: nil, tangentialPressure: tablet ? -0.2 : nil)]
                        ]

                        let nativeStroke = try session.beginTabletStroke(image: oracle.image, drawable: oracle.channel,
                                                                         brush: toolBrush, first: first)
                        for batch in batches { try session.continueTabletStroke(nativeStroke, points: batch) }
                        try session.endStroke(nativeStroke)
                        let expected = try pixels(oracle.image)
                        check(expected != baseline, "\(label) independent native stroke changes visible pixels")

                        var liveBrush = toolBrush
                        try RecorderPaletteAction.record.perform(on: sourceDoc)
                        if tablet {
                            sourceDoc.beginTabletStroke(at: first, brush: liveBrush)
                        } else {
                            sourceDoc.beginStroke(at: first.point, brush: liveBrush)
                        }
                        // Accepted settings must not be altered by later local mutations.
                        liveBrush.size = 99; liveBrush.opacity = 0.1
                        for batch in batches {
                            if tablet { sourceDoc.continueTabletStroke(batch) }
                            else { sourceDoc.continueStroke(batch.map(\.point)) }
                        }
                        sourceDoc.endStroke()
                        try drain(sourceDoc)
                        try RecorderPaletteAction.stop.perform(on: sourceDoc)

                        check(try pixels(source.image) == expected && sourceDoc.undoInfo.undoCount == originalUndo + 1,
                              "\(label) recorded live typed stroke matches independent native oracle and one Undo")
                        try require(sourceDoc.recorder.records.count == 1, "\(label) captured exactly one record")

                        guard case .success(.completeInkStroke(let captured)) = sourceDoc.recorder.records[0].resolution,
                              case .ink(let symbol, let identity)? = sourceDoc.recorderBindingDescriptions[0] else {
                            return try require(false, "Missing successful typed ink brush record: \(label)")
                        }
                        check(identity.uuid == source.identity.uuid, "\(label) owns the selected ink binding UUID")
                        check(captured.settings.tool == (tool == .paintbrush ? .paintbrush : .pencil),
                              "\(label) preserves tool")
                        check(captured.settings.size == toolBrush.size &&
                              abs(captured.settings.opacity - toolBrush.opacity) < 1e-12 &&
                              abs(captured.settings.red - rgb.0) < 1e-12 &&
                              abs(captured.settings.green - rgb.1) < 1e-12 &&
                              abs(captured.settings.blue - rgb.2) < 1e-12 &&
                              captured.settings.hardness == toolBrush.hardness &&
                              captured.settings.pressureSize == false,
                              "\(label) preserves exact RGB/settings and explicit pressureSize false")
                        if let hardness = captured.settings.hardness {
                            check(abs(hardness - 0.4) < 1e-12, "\(label) preserves hardness")
                        } else {
                            check(false, "\(label) missing hardness")
                        }
                        let expectedTrace = try RecorderTabletStrokeTrace(first: .init(native: first),
                                                                          batches: batches.map { try $0.map { try .init(native: $0) } })
                        check(captured.trace == expectedTrace, "\(label) preserves exact V2 trace and batch boundaries")
                        check(captured.facts.brush == toolBrush.resource, "\(label) preserves accepted brush resource")
                        if tool == .paintbrush {
                            check(captured.settings.antiErase == false, "\(label) has explicit antiErase absence/zero semantics")
                        }

                        let url = work.appendingPathComponent("ink-brush-\(mode.rawValue)-\(component.rawValue)-\(tool)-\(tablet).glims-recording")
                        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
                        sourceDoc.saveRecording(to: url, checkpoint: try sourceDoc.recorderSaveCheckpoint()) { saved = $0 }
                        try drain(sourceDoc)
                        try require(saved != nil, "\(label) missing save completion")
                        _ = try saved!.get()
                        let bytes = try Data(contentsOf: url)
                        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                        check(object?["version"] as? Int == 16, "\(label) saves version 16")

                        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
                        sourceDoc.prepareRecordingFile(at: url, checkpoint: try sourceDoc.recorderInstallCheckpoint()) { loaded = $0 }
                        try drain(sourceDoc)
                        try require(loaded != nil, "\(label) missing load completion")
                        let prepared = try loaded!.get()
                        if prepared.file.records.count == 1,
                           case .success(.completeInkStroke(let savedStroke), .ink(let savedSymbol, let savedIdentity)) = prepared.file.records[0].outcome {
                            check(savedStroke == captured && savedSymbol == symbol && savedIdentity == identity,
                                  "\(label) actual save/load preserves exact settings facts V2 trace and binding")
                        } else {
                            check(false, "\(label) actual save/load changed the complete ink record")
                        }

                        // Representative guard cases on first combo to keep exercise bounded.
                        if mode == .cmyk && component == .u8 && tool == .paintbrush && !tablet {
                            let targetChannels = try session.channels(target.image)
                            let wrongRole = targetChannels[2].id // Yellow
                            if case .failure = try install(prepared, target: targetDoc, symbol: symbol, channel: wrongRole) {
                                check(true, "\(label) wrong CMYK role refused")
                            } else {
                                check(false, "\(label) wrong CMYK role accepted")
                            }

                            // Wrong selected channel refusal with history preserved.
                            try install(prepared, target: targetDoc, symbol: symbol, channel: target.channel).get()
                            let wrongSelection = targetChannels[2].id
                            try session.channelCommand(.select, channel: wrongSelection, image: target.image)
                            try targetDoc.reload()
                            let beforeRefusalPixels = try pixels(target.image)
                            let beforeRefusalUndo = try session.undoInfo(target.image)
                            try targetDoc.startReplay()
                            try drain(targetDoc)
                            if case .failed = targetDoc.replayStatus {
                                check(true, "\(label) wrong selected channel refuses replay")
                            } else {
                                check(false, "\(label) wrong selected channel replayed")
                            }
                            check(try pixels(target.image) == beforeRefusalPixels &&
                                  session.undoInfo(target.image) == beforeRefusalUndo,
                                  "\(label) wrong selected channel refusal preserves pixels/history")
                            try session.channelCommand(.select, channel: target.channel, image: target.image)
                            try targetDoc.reload()

                            // Changed fingerprint pre-dab refusal.
                            let digest = captured.facts.fingerprint
                            let changed = (digest.first == "0" ? "1" : "0") + digest.dropFirst()
                            let mismatched = RecorderInkStrokeCommand(settings: captured.settings, trace: captured.trace,
                                                                      facts: .init(brush: captured.facts.brush, fingerprint: changed))
                            let history = try session.undoInfo(target.image)
                            do {
                                try mismatched.apply(session: session, image: target.image, channel: target.channel,
                                                     identity: try RecorderInkIdentity(target.identity))
                                check(false, "\(label) changed fingerprint accepted")
                            } catch {
                                check(true, "\(label) changed fingerprint refused before dab")
                            }
                            check(try pixels(target.image) == beforeRefusalPixels && session.undoInfo(target.image) == history,
                                  "\(label) changed fingerprint preserves pixels/history")

                            // Explicit compatible channel rebinding: different UUID but same role accepted.
                            let reboundBaseline = try pixels(target.image)
                            try install(prepared, target: targetDoc, symbol: symbol, channel: target.channel).get()
                            try targetDoc.startReplay()
                            try drain(targetDoc)
                            check(try pixels(target.image) == expected, "\(label) explicit compatible channel rebind replays")
                            targetDoc.undo(); try drain(targetDoc)
                            check(try pixels(target.image) == reboundBaseline, "\(label) explicit rebind undo restores")
                        }

                        if mode == .multichannel && component == .u8 && tool == .pencil && tablet {
                            // Wrong mode refusal (multichannel recording onto CMYK).
                            guard let cmykProfile = NSColorSpace.genericCMYK.iccProfileData else {
                                throw NSError(domain: "RecorderInkBrushFixture", code: 4,
                                              userInfo: [NSLocalizedDescriptionKey: "Missing generic CMYK profile"])
                            }
                            let wrongModeImage = try session.newCmykImage(width: 32, height: 24, component: .u8, profileICC: cmykProfile)
                            loose.append(wrongModeImage)
                            let wrongModeChannel = try session.channels(wrongModeImage)[1].id
                            try session.channelCommand(.select, channel: wrongModeChannel, image: wrongModeImage)
                            try session.editInk(wrongModeImage, channel: wrongModeChannel, settings: .init(operation: .fill, intensity: 1, opacity: 1))
                            let wrongModeDoc = try document(wrongModeImage, "Wrong mode target")
                            if case .failure = try install(prepared, target: wrongModeDoc, symbol: symbol, channel: wrongModeChannel) {
                                check(true, "\(label) wrong mode refused")
                            } else {
                                check(false, "\(label) wrong mode accepted")
                            }

                            // Cancel queued gesture rollback/failure Recorder row.
                            try RecorderPaletteAction.record.perform(on: sourceDoc)
                            let beforeCancelPixels = try pixels(source.image)
                            let beforeCancelUndo = sourceDoc.undoInfo.undoCount
                            sourceDoc.beginTabletStroke(at: first, brush: toolBrush)
                            sourceDoc.continueTabletStroke(batches[0])
                            try require(sourceDoc.inkBrushStrokeIsActive, "\(label) active ink stroke before cancel")
                            sourceDoc.cancelInkBrushStroke()
                            try drain(sourceDoc)
                            try RecorderPaletteAction.stop.perform(on: sourceDoc)
                            check(try pixels(source.image) == beforeCancelPixels &&
                                  sourceDoc.undoInfo.undoCount == beforeCancelUndo,
                                  "\(label) cancelled gesture restores pixels and existing history")
                            if case .failure = sourceDoc.recorder.records.last?.resolution {
                                check(true, "\(label) cancelled gesture cannot become replayable edit")
                            } else {
                                check(false, "\(label) cancelled gesture recorded as success")
                            }
                        }

                        // Replay equals legacy/native oracle pixels and exact Undo/Redo on target.
                        try session.channelCommand(.select, channel: target.channel, image: target.image)
                        try targetDoc.reload()
                        let beforeReplayPixels = try pixels(target.image)
                        let beforeReplayUndo = targetDoc.undoInfo.undoCount
                        try install(prepared, target: targetDoc, symbol: symbol, channel: target.channel).get()
                        try RecorderPaletteAction.replay.perform(on: targetDoc)
                        try drain(targetDoc)
                        check(targetDoc.replayStatus == .finished(total: 1), "\(label) loaded replay finishes")
                        check(try pixels(target.image) == expected && targetDoc.undoInfo.undoCount == beforeReplayUndo + 1,
                              "\(label) replay equals oracle pixels and one Undo")
                        targetDoc.undo(); try drain(targetDoc)
                        check(try pixels(target.image) == beforeReplayPixels, "\(label) replay Undo restores baseline")
                        targetDoc.redo(); try drain(targetDoc)
                        check(try pixels(target.image) == expected, "\(label) replay Redo restores oracle pixels")

                        try closeOwned()
                    }
                }
            }
        }

        check(modes.count * components.count * tools.count * tabletModes.count == 24,
              "Ink brush fixture exercised 24 CMYK/Multichannel x component x tool x pointer combinations")
    }
}
