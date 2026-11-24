import AppKit

// MARK: - GLIMS_SMOKE_CASE=recorder-layer-edits

@MainActor
extension EngineSmokeTest {
    /// GLIMS_SMOKE_CASE=recorder-layer-edits (also in the full run): the six
    /// layer edits the Recorder now saves. One document records a Move tool
    /// offset, one arrow nudge, Duplicate Layers, Delete Layers on the
    /// duplicate, Add Layer Mask (white, editing), Merge Visible and Select
    /// Similar after a rectangle selection. Every row succeeds, and the
    /// recording replays into a second identical document with the same
    /// pixels and layer tree. Duplicate with two selected layers keeps its
    /// failed row, and a Duplicate or Delete the engine refuses completes
    /// with its failure.
    static func exerciseRecorderLayerEdits(_ session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.01) }
            if !condition() { check(false, "a layer-edit fixture wait timed out after 20 seconds") }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && document.recorder.pendingCount == 0
                && !document.recorder.isReplaying && !EngineActivity.shared.isBusy }
            spin(0.02)
        }
        func pixels(_ document: ImageDocument) throws -> Data {
            try session.copyPixels(document.image, merged: true).pixels
        }
        /// Names, visibility, masks and selection, in stack order.
        func structure(_ document: ImageDocument) throws -> [String] {
            try session.layers(document.image).map { "\($0.name)|\($0.isVisible)|\($0.hasMask)|\($0.isSelected)" }
        }
        func close(_ document: ImageDocument) {
            document.onError = nil
            document.closeImageWhenDrained()
            wait { (try? session.info(document.image)) == nil }
            documents.items.removeAll { $0 === document }
        }

        var bytes: [UInt8] = []
        for index in 0..<16 * 16 {
            bytes += [UInt8(index * 7 % 256), UInt8(index * 13 % 256), UInt8(index * 29 % 256), 255]
        }
        let payload = ClipboardImage(width: 16, height: 16, pixels: Data(bytes), origin: .zero)
        func fixture(_ name: String) throws -> (ImageDocument, Int32, Int32) {
            let image = try session.newImage(width: 48, height: 48)
            let base = try session.layers(image)[0].id
            let layer = try session.pastePixels(image, pixels: payload, at: CGPoint(x: 8, y: 8))
            let document = try ImageDocument(session: session, image: image, name: name)
            document.onError = { _ in }
            documents.items.append(document)
            try document.reload()
            settle(document)
            return (document, base, layer)
        }

        let (a, _, layerA) = try fixture("Layer edits capture")
        defer { close(a) }
        try a.startRecording()
        a.moveActiveLayer(by: CGSize(width: 3, height: 2))
        settle(a)
        a.moveActiveLayer(by: CanvasKeyboardPolicy.nudge(.right, shift: false))
        settle(a)
        a.selectLayer(layerA)
        settle(a)
        a.duplicateSelectedLayers { _ in }
        settle(a)
        guard let copyA = a.activeLayer, copyA != layerA else {
            return check(false, "the duplicate is selected after Duplicate Layers")
        }
        a.deleteSelectedLayers { _ in }
        settle(a)
        a.addMask(layerA, source: .white, edit: true)
        settle(a)
        a.mergeVisible()
        settle(a)
        // A later row edits the merged layer, so replay must bind the layer
        // Merge Visible creates.
        a.moveActiveLayer(by: CGSize(width: 2, height: 1))
        settle(a)
        a.select(.rectangle(CGRect(x: 8, y: 8, width: 20, height: 20)), options: .init())
        settle(a)
        var similar = EngineSession.SelectOptions()
        similar.sampleMerged = true
        a.selectSimilar(options: similar) { _ in }
        settle(a)
        try a.stopRecording()
        settle(a)

        let rows = a.recorder.records
        check(rows.count == 9
              && rows.allSatisfy({ if case .success = $0.resolution { return true }; return false })
              && a.recorder.replayRefusal == nil,
              "every layer edit records one successful row (\(rows.count) rows)")
        if case .success(.moveLayer(let first))? = rows.first?.resolution {
            check(first == CGSize(width: 3, height: 2), "the Move tool offset is recorded")
        } else { check(false, "the first row is the Move tool offset") }
        if case .success(.moveLayer(let nudge))? = rows.dropFirst().first?.resolution {
            check(nudge == CGSize(width: 1, height: 0), "one arrow nudge is one recorded row")
        } else { check(false, "the second row is the arrow nudge") }
        if case .success(.duplicateLayers)? = rows.dropFirst(2).first?.resolution {
            check(true, "Duplicate Layers records a row without fields")
        } else { check(false, "the third row is Duplicate Layers") }
        if case .success(.deleteLayers)? = rows.dropFirst(3).first?.resolution {
            check(true, "Delete Layers records a row without fields")
        } else { check(false, "the fourth row is Delete Layers") }
        if case .success(.addLayerMask(let source, let edit))? = rows.dropFirst(4).first?.resolution {
            check(source == .white && edit, "Add Layer Mask stores the owned source and edit flag")
        } else { check(false, "the fifth row is Add Layer Mask") }
        if case .success(.mergeVisible)? = rows.dropFirst(5).first?.resolution {
            check(true, "Merge Visible records a row without fields")
        } else { check(false, "the sixth row is Merge Visible") }
        if case .success(.selectionShape(let shape, _))? = rows.dropFirst(7).first?.resolution {
            check(shape == .rectangle(CGRect(x: 8, y: 8, width: 20, height: 20)),
                  "the rectangle selection records its shape")
        } else { check(false, "the eighth row is the rectangle selection") }
        if case .success(.selectSimilar(let threshold, let antialias, let sampleMerged))?
            = rows.dropFirst(8).first?.resolution {
            check(threshold == 15.0 / 255.0 && antialias && sampleMerged,
                  "Select Similar stores threshold, antialias and sample-merged")
        } else { check(false, "the last row is Select Similar") }

        let url = work.appendingPathComponent("layer-edits.glims-recording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        a.saveRecording(to: url, checkpoint: try a.recorderSaveCheckpoint()) { saved = $0 }
        settle(a)
        guard let saved, (try? saved.get()) != nil else {
            return check(false, "the layer-edit recording saves")
        }
        var loaded: Result<RecorderFileSemanticBridge.PreparedRecording, Error>?
        a.prepareRecordingFile(at: url, checkpoint: try a.recorderInstallCheckpoint()) { loaded = $0 }
        settle(a)
        guard let loaded, let file = try? loaded.get().file else {
            return check(false, "the layer-edit recording loads")
        }
        check(file.records.count == 9,
              "the saved recording keeps every layer-edit row (\(file.records.count))")
        // The row checks below index the recording, so stop on a wrong count.
        guard file.records.count == 9 else { return }

        // Duplicate Layers (row 2) and Merge Visible (row 5) each produce a
        // symbol, and every produced description is saved as a symbol.
        let producedIDs = file.producedSymbols
        guard let duplicateProduced = file.records[2].produces,
              let mergeProduced = file.records[5].produces,
              producedIDs.contains(duplicateProduced), producedIDs.contains(mergeProduced) else {
            return check(false, "Duplicate Layers and Merge Visible record produced symbols")
        }
        check(producedIDs.allSatisfy { id in
              file.symbols.contains { $0.id == id }
          }, "every produced symbol's description is saved as a symbol")
        if case .success(.deleteLayers, .layer(let deleted)) = file.records[3].outcome,
           case .success(.moveLayer, .layer(let moved)) = file.records[6].outcome {
            check(deleted == duplicateProduced && moved == mergeProduced,
                  "Delete binds the duplicate's copy and the later move binds the merged layer")
        } else { check(false, "rows 3 and 6 bind produced layers") }

        let (b, _, _) = try fixture("Layer edits replay")
        defer { close(b) }
        // One install binds only the load-time input, the pasted layer. The
        // produced copy and merged layer resolve during replay itself.
        let choices = try RecorderBatchBindings.resolve(
            file: file, candidates: b.recorderBatchCandidates(), policy: .matchingNamesAndKinds)
        guard choices.count == 1 else {
            return check(false, "only the pasted layer needs an install choice (\(choices.count))")
        }
        var installed: Result<Void, Error>?
        b.installRecording(try RecorderFileSemanticBridge.prepare(file),
                           checkpoint: try b.recorderInstallCheckpoint(),
                           choices: choices) { installed = $0 }
        settle(b)
        guard let installed else { return check(false, "the layer-edit recording installs") }
        try installed.get()
        try b.startReplay()
        settle(b)

        check(try pixels(a) == pixels(b), "the replayed layer edits render the same pixels")
        check(try structure(a) == structure(b),
              "the replayed layer edits keep the same names, order, visibility, active layer and masks")

        // Duplicate with two selected layers keeps its explicit failed row.
        let (multi, baseMulti, layerMulti) = try fixture("Layer edits multi-select")
        defer { close(multi) }
        try multi.startRecording()
        multi.selectLayers([baseMulti, layerMulti])
        settle(multi)
        multi.duplicateSelectedLayers { _ in }
        settle(multi)
        let multiRows = multi.recorder.records
        check(multiRows.count == 1
              && multiRows.first.map({ if case .failure(let reason) = $0.resolution {
                  return reason == "Recorder saves Duplicate and Delete for one selected layer only."
              } else { return false } }) == true,
              "Duplicate with two selected layers keeps its failed row")
        try multi.stopRecording()
        settle(multi)

        // A Duplicate or Delete the engine refuses after admission (here the
        // selected layer was removed natively behind the cached state)
        // completes with the failure, reports it once and records a failed
        // row.
        for command in ["Duplicate", "Delete"] {
            let (refused, _, layerRefused) = try fixture("Layer edits refused \(command)")
            defer { close(refused) }
            var reported = 0
            refused.onError = { _ in reported += 1 }
            try refused.startRecording()
            refused.selectLayer(layerRefused)
            settle(refused)
            try session.deleteLayers(refused.image, layers: [layerRefused])
            var outcome: Result<Void, Error>?
            if command == "Duplicate" { refused.duplicateSelectedLayers { outcome = $0 } }
            else { refused.deleteSelectedLayers { outcome = $0 } }
            settle(refused)
            wait { outcome != nil }
            if case .failure? = outcome { check(true, "a refused \(command) completes with its failure") }
            else { check(false, "a refused \(command) completes with its failure") }
            check(reported == 1, "a refused \(command) reports its error once (\(reported))")
            let refusedRows = refused.recorder.records
            check(refusedRows.count == 1
                  && refusedRows.first.map({ if case .failure = $0.resolution { return true }; return false }) == true,
                  "a refused \(command) records one failed row")
            try refused.stopRecording()
            settle(refused)
        }
    }
}
