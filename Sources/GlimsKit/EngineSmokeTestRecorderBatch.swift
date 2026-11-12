import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderBatch(_ session: EngineSession, work: URL) throws {
        let root = work.appendingPathComponent("batch")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "BatchFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(45)
            while !condition() && Date() < deadline { spin(0.005) }
            try require(condition(), "Batch did not finish and drain")
        }
        let service = RecorderBatchService(session: session)
        defer {
            service.cancel()
            try? wait { !service.isRunning }
        }
        var bytes: [UInt8] = []
        for index in 0..<12 { bytes += [UInt8(index * 17), UInt8(index * 7), UInt8(index * 13), 255] }
        let sourcePixels = ClipboardImage(width: 4, height: 3, pixels: Data(bytes), origin: .zero)
        var flipped: [UInt8] = []
        for y in 0..<3 { for x in (0..<4).reversed() { flipped += bytes[((y * 4 + x) * 4)..<((y * 4 + x + 1) * 4)] } }
        func input(_ name: String, layerName: String = "Subject", locked: Bool = false) throws -> URL {
            let path = root.appendingPathComponent(name + ".xcf")
            let image = try session.newImage(pixels: sourcePixels)
            defer { try? session.closeImage(image) }
            let layer = try session.layers(image)[0].id
            try session.changeLayer(layer, image: image, .init(name: layerName))
            if locked { try session.setLayerLocks(layer, image: image, mask: .pixels, values: .pixels) }
            try session.save(image, to: path.path)
            return path
        }
        let first = try input("First"), second = try input("Second"), other = try input("Other", layerName: "Other")
        let originals = try [first, second, other].map { try Data(contentsOf: $0) }
        let origin = RecorderFileValue.Origin(imageLabel: "Fixture", initialWidth: 4, initialHeight: 3)
        func recording(_ name: String, commands: [(RecorderFileCommand, RecorderBindingDescription)],
                       symbols: [RecorderFileValue.Symbol] = []) throws -> URL {
            let file = RecorderFileValue(recordingID: UUID(), name: name, origin: origin, symbols: symbols,
                records: commands.enumerated().map { .init(ordinal: $0.offset, outcome: .success($0.element.0, $0.element.1)) })
            let path = root.appendingPathComponent(name + ".glimsrecording")
            // Independently authored file value goes through the real codec;
            // the service subsequently loads it with RecorderFileStore.
            try RecorderFileCodec.encode(file).write(to: path)
            return path
        }
        func folder(_ name: String) throws -> URL {
            let path = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false)
            return path
        }
        func run(_ recording: URL, _ inputs: [URL], _ output: URL,
                 format: RecorderBatchService.Output = .exported(ExportSettings()),
                 policy: RecorderBatchBindings.Policy = .requireNoTargets,
                 progress: @escaping (RecorderBatchService.Progress) -> Void = { _ in }) throws -> [RecorderBatchService.Item] {
            var result: Result<[RecorderBatchService.Item], Error>?
            try service.start(recording: recording, inputs: inputs, directory: output, output: format,
                              matching: policy, progress: progress) { result = $0 }
            try wait { result != nil && !service.isRunning }
            return try result!.get()
        }
        func saved(_ item: RecorderBatchService.Item) throws -> URL {
            guard case .saved(let url, let warning) = item.outcome else {
                throw NSError(domain: "BatchFixture", code: 2, userInfo: [NSLocalizedDescriptionKey: "Expected saved output for \(item.source): \(item.outcome)"])
            }
            check(warning == nil, "Batch output and temporary cleanup finish without warnings")
            return url
        }
        func pixels(_ file: URL) throws -> Data {
            let image = try session.openImage(path: file.path)
            defer { try? session.closeImage(image) }
            return try session.copyPixels(image, merged: true).pixels
        }
        let flip = try recording("Flip", commands: [(.transformImage(.flipHorizontal), .none)])
        let outputs = try folder("png")
        let collision = outputs.appendingPathComponent("First edited.png")
        let oldBytes = Data("preexisting output".utf8)
        try oldBytes.write(to: collision)
        let corrupt = root.appendingPathComponent("Broken.png")
        try Data("invalid image".utf8).write(to: corrupt)
        let rows = try run(flip, [first, corrupt, second, first], outputs)
        try require(rows.count == 3, "Batch should deduplicate repeated inputs")
        let a = try saved(rows[0]), b = try saved(rows[2])
        check(a.lastPathComponent == "First edited 2.png", "Batch chooses an unused destination instead of overwriting a file")
        check(try Data(contentsOf: collision) == oldBytes, "Batch preserves preexisting output bytes")
        if case .failed = rows[1].outcome { check(true, "One unreadable input is reported and later inputs continue") }
        else { check(false, "An unreadable input must fail") }
        check(try pixels(a) == Data(flipped) && pixels(b) == Data(flipped),
              "Saved recording replays across two imported images with independently expected flipped pixels")
        check(try FileManager.default.contentsOfDirectory(atPath: outputs.path).allSatisfy { !$0.hasPrefix(".glims-batch-") },
              "Completed Batch leaves no temporary export directories")

        // The shared export form must carry its PSD layout through Batch's
        // private document, staging filename and asynchronous publication.
        let layeredInput = root.appendingPathComponent("Layered.xcf")
        let layeredImage = try session.newImage(pixels: sourcePixels)
        do {
            _ = try session.duplicateLayers(layeredImage, layers: [session.layers(layeredImage)[0].id])
            try session.save(layeredImage, to: layeredInput.path)
        } catch {
            try? session.closeImage(layeredImage)
            throw error
        }
        try session.closeImage(layeredImage)
        let layeredOriginal = try Data(contentsOf: layeredInput)
        for layout in ExportSettings.PsdLayout.allCases {
            var settings = ExportSettings()
            settings.format = .psd
            settings.psdLayout = layout
            let destination = try folder("psd-\(layout)")
            let items = try run(flip, [layeredInput], destination, format: .exported(settings))
            try require(items.count == 1, "PSD Batch result missing")
            let output = try saved(items[0])
            let reopened = try session.openImage(path: output.path)
            defer { try? session.closeImage(reopened) }
            let reopenedLayers = try session.layers(reopened)
            check(output.pathExtension == "psd" && reopenedLayers.count == (layout == .layers ? 2 : 1),
                  "Batch publishes PSD with the selected layered or merged structure")
            check(try session.copyPixels(reopened, merged: true).pixels == Data(flipped),
                  "Batch PSD contains the independently expected replayed pixels")
        }
        check(try Data(contentsOf: layeredInput) == layeredOriginal,
              "Layered and merged PSD Batch exports preserve the source file")

        var gifSettings = ExportSettings()
        gifSettings.format = .gif
        let gifItems = try run(flip, [layeredInput], folder("gif"), format: .exported(gifSettings))
        try require(gifItems.count == 1, "GIF Batch result missing")
        let gifOutput = try saved(gifItems[0])
        let gifImage = try session.openImage(path: gifOutput.path)
        check(try session.layers(gifImage).count == 1 && gifOutput.pathExtension == "gif",
              "GIF Batch publishes one still image from the layered source")
        check(try session.copyPixels(gifImage, merged: true).pixels == Data(flipped),
              "GIF Batch contains the independently expected flipped palette pixels")
        try session.closeImage(gifImage)
        check(try Data(contentsOf: layeredInput) == layeredOriginal,
              "GIF Batch leaves its source file unchanged")

        // Keep the selected ICC bytes in the immutable Batch settings, and
        // compare replay output with an independently authored flipped image.
        guard let cmykBytes = NSColorSpace.genericCMYK.iccProfileData else {
            throw NSError(domain: "BatchFixture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Fixture needs a CMYK ICC profile"])
        }
        let cmykProfile = try PsdCmykProfile(displayName: "Fixture printer", iccData: cmykBytes)
        for layout in ExportSettings.PsdLayout.allCases {
            var settings = ExportSettings()
            settings.format = .psd
            settings.psdLayout = layout
            settings.psdColor = .cmyk
            settings.psdCmykProfile = cmykProfile
            let destination = try folder("cmyk-\(layout)")
            let items = try run(flip, [layeredInput], destination, format: .exported(settings))
            try require(items.count == 1, "CMYK Batch result missing")
            if session.version.hasPrefix("3.3.") {
                if case .failed(let reason) = items[0].outcome {
                    check(reason.contains("development image engine"), "Batch reports the CMYK development writer refusal")
                } else { check(false, "Development CMYK Batch must refuse") }
                check(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty,
                      "Refused CMYK Batch publishes no file or staging directory")
                continue
            }
            let output = try saved(items[0])
            let data = try Data(contentsOf: output)
            check(data.count > 26 && data[24] == 0 && data[25] == 4 && data.range(of: cmykBytes) != nil,
                  "Batch publishes CMYK PSD with the captured ICC bytes")
            let reopened = try session.openImage(path: output.path)
            defer { try? session.closeImage(reopened) }
            check(try session.layers(reopened).count == (layout == .layers ? 2 : 1),
                  "CMYK Batch preserves the selected PSD layout")
            let expected = try session.newImage(pixels: .init(width: 4, height: 3, pixels: Data(flipped), origin: .zero))
            defer { try? session.closeImage(expected) }
            let expectedFile = root.appendingPathComponent("expected-cmyk-\(layout).psd")
            try session.export(expected, to: expectedFile.path, settings: settings)
            check(try session.copyPixels(reopened, merged: true).pixels == pixels(expectedFile),
                  "CMYK Batch contains the independently authored flipped image after the same output conversion")
        }
        check(try Data(contentsOf: layeredInput) == layeredOriginal,
              "CMYK Batch leaves its source XCF unchanged")

        let symbol = UUID()
        let description = RecorderTargetDescription(name: "Subject", kind: .pixel, ancestors: [], siblingIndex: 0,
                                                   bounds: .init(x: 0, y: 0, width: 4, height: 3))
        let opacity = try recording("Opacity", commands: [(.layerProperties(.init(name: nil, visible: nil, opacity: 0.5, mode: nil)), .layer(symbol))],
                                   symbols: [.init(id: symbol, description: description)])
        let nativeOutputs = try folder("native")
        let bound = try run(opacity, [first, other, second], nativeOutputs, format: .native, policy: .matchingNamesAndKinds)
        try require(bound.count == 3, "All distinct Batch sources need results")
        for index in [0, 2] {
            let url = try saved(bound[index]), image = try session.openImage(path: url.path)
            let layers = try session.layers(image)
            check(layers.count == 1 && layers[0].name == "Subject" && abs(layers[0].opacity - 0.5) < 0.0001,
                  "Explicit Batch name/kind matching rebinds each image and preserves a layered XCF output")
            try session.closeImage(image)
        }
        if case .failed(let reason) = bound[1].outcome { check(reason.contains("Subject"), "Missing named target reports the specific target and publishes no output") }
        else { check(false, "Missing named target must fail") }
        check(!FileManager.default.fileExists(atPath: nativeOutputs.appendingPathComponent("Other edited.xcf").path),
              "Refused target matching publishes no partially edited image")
        let defaultOutputs = try folder("default-refusal")
        do {
            _ = try run(opacity, [first], defaultOutputs)
            check(false, "Default Batch policy must require explicit target matching")
        } catch { check(error is RecorderBatchBindings.MatchError, "Target-bound recording refuses before opening inputs under the default policy") }
        check(try FileManager.default.contentsOfDirectory(atPath: defaultOutputs.path).isEmpty, "Refused Batch creates no outputs")

        let locked = try input("Locked", locked: true), lockedOriginal = try Data(contentsOf: locked)
        let adjustment = try RecorderColorBalanceValue(EngineSession.ColorBalanceSettings())
        let partial = try recording("Selection then adjustment", commands: [
            (.selectCommand(.all, radius: 0), .none), (.applyColorBalance(adjustment), .layer(symbol))],
            symbols: [.init(id: symbol, description: description)])
        let partialOutputs = try folder("partial")
        let partialResults = try run(partial, [locked, first], partialOutputs, format: .native, policy: .matchingNamesAndKinds)
        try require(partialResults.count == 2, "Partial replay results missing")
        if case .failed(let reason) = partialResults[0].outcome {
            check(reason.contains("Command 2") && reason.localizedCaseInsensitiveContains("unlock"),
                  "Mid-recording failure reports the actual command and native lock refusal")
        } else { check(false, "A locked adjustment target must fail at command two") }
        _ = try saved(partialResults[1])
        check(try Data(contentsOf: locked) == lockedOriginal &&
              FileManager.default.contentsOfDirectory(atPath: partialOutputs.path) == ["First edited.xcf"],
              "A partially replayed failure preserves its input, leaves no staged output, and later files continue")

        let cancelledFailureOutputs = try folder("cancelled-failure")
        let cancelledFailure = try run(flip, [corrupt], cancelledFailureOutputs) { update in
            if update.message.hasPrefix("Opening ") { DispatchQueue.main.async { service.cancel() } }
        }
        if case .failed(let reason) = cancelledFailure.first?.outcome {
            check(!reason.isEmpty, "A corrupt input still reports its real failure when Cancel arrives during open")
        } else { check(false, "Cancel must not erase an accepted native open failure") }

        let doubleFlip = try recording("Two flips", commands: [
            (.transformImage(.flipHorizontal), .none), (.transformImage(.flipHorizontal), .none)])
        let bindingOutputs = try folder("concurrent-binding")
        var bindingForeignFinished = false
        let bindingResults = try run(flip, [first], bindingOutputs) { update in
            guard update.message.hasPrefix("Binding ") else { return }
            DispatchQueue.main.async {
                EngineActivity.shared.performWhenReady(label: "Other document work during binding", work: {
                    Thread.sleep(forTimeInterval: 0.15)
                }, completion: { bindingForeignFinished = true })
            }
        }
        try wait { bindingForeignFinished }
        if case .saved(let url, _) = bindingResults.first?.outcome {
            check(try pixels(url) == Data(flipped), "Batch retries an uncommitted binding after concurrent engine work")
        } else { check(false, "Concurrent engine work must not reject an otherwise valid recording installation") }
        let concurrentOutputs = try folder("concurrent")
        let foreignImage = try session.newImage(pixels: sourcePixels)
        let foreignDocument = try ImageDocument(session: session, image: foreignImage, name: "Other document")
        defer {
            var closed = false
            foreignDocument.closeImageWhenDrained { closed = true }
            try? wait { closed }
        }
        let foreignExport = root.appendingPathComponent("Foreign.png")
        var foreignAccepted = false, foreignFinished = false, foreignError: Error?
        let concurrent = try run(doubleFlip, [first], concurrentOutputs) { update in
            guard update.message.hasPrefix("Replaying ") else { return }
            DispatchQueue.main.async {
                foreignAccepted = EngineActivity.shared.perform(label: "Saving another document", work: {
                    // Hold the real exclusive activity across the next replay
                    // scheduling turn, then perform an actual native export.
                    Thread.sleep(forTimeInterval: 0.15)
                    do { try session.export(foreignImage, to: foreignExport.path) }
                    catch { foreignError = error }
                }, completion: { foreignFinished = true })
            }
        }
        try wait { foreignFinished }
        check(foreignAccepted && foreignError == nil, "Another document can finish a real export during Batch replay")
        try require(concurrent.count == 1, "Concurrent Batch result missing")
        if case .saved(let concurrentFile, _) = concurrent[0].outcome {
            check(try pixels(concurrentFile) == sourcePixels.pixels,
                  "Batch waits between commands for another document's export and resumes without duplicate steps")
        } else { check(false, "Concurrent document work must not fail a Batch replay: \(concurrent[0].outcome)") }

        let waitingOutputs = try folder("cancelled-wait")
        foreignFinished = false
        let cancelledWait = try run(doubleFlip, [first, second], waitingOutputs) { update in
            guard update.message.hasPrefix("Replaying ") else { return }
            DispatchQueue.main.async {
                EngineActivity.shared.performWhenReady(label: "Concurrent save", work: {
                    Thread.sleep(forTimeInterval: 0.15)
                }, completion: { foreignFinished = true })
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { service.cancel() }
            }
        }
        try wait { foreignFinished }
        check(cancelledWait.count == 1, "Cancel during an engine wait stops later Batch inputs")
        if case .cancelled = cancelledWait.first?.outcome { check(true, "Cancel fences the paused replay continuation") }
        else { check(false, "An engine-wait cancellation must remain cancelled") }
        spin(0.05)
        check(try FileManager.default.contentsOfDirectory(atPath: waitingOutputs.path).isEmpty,
              "A delayed engine-idle callback cannot resume a cancelled replay or publish output")

        let procedure = try session.procedures(image: foreignImage).first
        try require(procedure != nil, "A native procedure is needed for the plug-in completion-order fixture")
        for cancelDuringLag in [false, true] {
            let lagOutputs = try folder(cancelDuringLag ? "cancelled-plugin-lag" : "plugin-lag")
            var plugInFlagCleared = false
            let lagResults = try run(flip, [first, second], lagOutputs) { update in
                guard update.message.hasPrefix("Exporting ") else { return }
                // Reproduce the real completion-order window: the engine is
                // idle but the app's plug-in flag has not cleared yet. No
                // external plug-in or dialog is launched by this fixture.
                PlugInCommands.willRun(procedure!, on: foreignDocument)
                DispatchQueue.main.asyncAfter(deadline: .now() + (cancelDuringLag ? 1.0 : 0.05)) {
                    PlugInCommands.didRun(procedure!, outcome: nil)
                    plugInFlagCleared = true
                }
                if cancelDuringLag { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { service.cancel() } }
            }
            let completedBeforeFlagCleared = !plugInFlagCleared
            try wait { plugInFlagCleared }
            if cancelDuringLag {
                check(completedBeforeFlagCleared, "Cancel closes its drained private image without waiting for a foreign plug-in status flag")
                check(try lagResults.count == 1 && FileManager.default.contentsOfDirectory(atPath: lagOutputs.path).isEmpty,
                      "Cancel during a plug-in completion lag discards the current export and later inputs")
                if case .cancelled = lagResults.first?.outcome { check(true, "Plug-in flag waiting retains the Cancel result") }
                else { check(false, "Plug-in lag cancellation must remain cancelled") }
            } else {
                try require(lagResults.count == 2, "Plug-in lag results missing")
                let output = try saved(lagResults[0])
                _ = try saved(lagResults[1])
                check(try pixels(output) == Data(flipped), "Batch waits for the plug-in flag to clear before export admission")
            }
        }

        let cancelledOutputs = try folder("cancelled")
        let cancelled = try run(flip, [first, second], cancelledOutputs) { update in
            if update.message.hasPrefix("Exporting ") { service.cancel() }
        }
        check(cancelled.count == 1, "Cancel stops scheduling later Batch inputs")
        if case .cancelled(let warning) = cancelled.first?.outcome { check(warning == nil, "Cancel drains the image and removes the staged export") }
        else { check(false, "Cancelled current input is reported") }
        check(try FileManager.default.contentsOfDirectory(atPath: cancelledOutputs.path).isEmpty,
              "Cancel after replay publishes no current output")
        check(try [first, second, other].enumerated().allSatisfy { try Data(contentsOf: $0.element) == originals[$0.offset] },
              "Successful, refused and cancelled Batch runs preserve every original input byte")
        check(!service.isRunning && !EngineActivity.shared.isBusy, "Batch completion follows native work and image teardown")

        let window = RecorderBatchWindowController(session: session)
        defer { window.cancel(); window.window?.orderOut(nil); window.close() }
        let windowOutputs = try folder("window")
        window.selectRecording(flip)
        window.selectInputs([first, second])
        window.selectOutputDirectory(windowOutputs)
        window.showWindow(nil)
        var transitions = 0
        window.onRunStateChange = { transitions += 1 }
        window.runBatch(nil)
        check(window.isRunning && !window.runButton.isEnabled && window.cancelButton.isEnabled,
              "Actual Batch window starts its service and keeps Cancel enabled while choice controls are disabled")
        try wait { !window.isRunning }
        check(window.items.count == 2 && window.resultsText.contains("2 saved, 0 failed") && transitions == 2,
              "Actual Batch window shows individual results and reports both lifetime transitions")
        check(window.runButton.isEnabled && !window.cancelButton.isEnabled && window.lastError == nil,
              "Batch window becomes usable again after completion")
        if let view = window.window?.contentView {
            view.layoutSubtreeIfNeeded()
            if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let artifacts = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"].map { URL(fileURLWithPath: $0) } ?? work
                try bitmap.representation(using: .png, properties: [:])?.write(to: artifacts.appendingPathComponent("batch-window.png"))
            }
        }
        if ProcessInfo.processInfo.environment["GLIMS_SMOKE_CASE"] == "recorder-batch-window",
           let directory = ProcessInfo.processInfo.environment["GLIMS_SMOKE_ARTIFACT_DIR"] {
            NSApp.activate(ignoringOtherApps: true)
            window.window?.deminiaturize(nil)
            window.window?.makeKeyAndOrderFront(nil)
            spin(0.1)
            let artifacts = URL(fileURLWithPath: directory)
            try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: artifacts.appendingPathComponent("batch-window-ready"))
            let deadline = Date().addingTimeInterval(45)
            while !FileManager.default.fileExists(atPath: artifacts.appendingPathComponent("batch-window-continue").path), Date() < deadline { spin(0.02) }
        }
        window.chooseInputs(nil)
        try wait { window.openPanel != nil }
        check(window.openPanel?.canChooseDirectories == true && window.openPanel?.allowsMultipleSelection == true,
              "Actual Batch input picker accepts files and flat folders")
        _ = window.windowShouldClose(window.window!)
        try wait { window.openPanel == nil && window.window?.attachedSheet == nil }
        check(true, "Closing the Batch window dismisses its owned file picker")
        window.selectInputs([first, second])
        window.runBatch(nil)
        let acceptedClose = window.windowShouldClose(window.window!)
        check(!acceptedClose && window.isRunning, "Closing a running Batch requests cancellation and defers close")
        try wait { !window.isRunning && window.window?.isVisible == false }
        check(window.statusText.hasPrefix("Batch cancelled"), "Batch closes only after its cancelled service drains")
    }
}
