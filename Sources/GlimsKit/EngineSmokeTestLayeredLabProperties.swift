import AppKit
import CGlimsEngine
import RigiUI

extension EngineSmokeTest {
    static func exerciseLayeredLabProperties(session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        guard let path = ProcessInfo.processInfo.environment["GLIMS_LAYERED_LAB_FIXTURE"],
              !path.isEmpty else {
            throw NSError(domain: "LayeredLabSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Missing layered Lab fixture path"])
        }
        let image = try session.openImage(path: path)
        var document: ImageDocument?
        var controller: DocumentWindowController?
        let palette = LayersPaletteController()
        let paletteWindow = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 260, height: 300),
                                     styleMask: [.titled], backing: .buffered, defer: false)
        paletteWindow.isReleasedWhenClosed = false
        defer {
            palette.retarget(to: nil)
            paletteWindow.orderOut(nil)
            paletteWindow.close()
            if let window = controller?.window, let sheet = window.attachedSheet {
                window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                sheet.orderOut(nil)
            }
            if let controller, !controller.closeStarted { controller.closeDiscardingChanges() }
            if let document {
                if controller == nil && !document.isClosing { document.closeImageWhenDrained() }
                let deadline = Date().addingTimeInterval(15)
                while (try? session.info(image)) != nil && Date() < deadline {
                    EngineSmokeTestHost.pumpEvents(for: 0.02)
                }
                check((try? session.info(image)) == nil, "layered Lab document closes")
                documents.items.removeAll { $0 === document }
            } else {
                try? session.closeImage(image)
            }
        }
        let opened = try ImageDocument(session: session, image: image, name: "Layered Lab",
                                       openedFrom: URL(fileURLWithPath: path))
        document = opened
        documents.items.append(opened)
        let windowController = DocumentWindowController(document: opened, exportDirectory: work)
        controller = windowController
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
        paletteWindow.contentView = palette.view
        palette.retarget(to: opened)
        paletteWindow.orderFront(nil)
        EngineSmokeTestHost.pumpEvents(for: 0.2)
        check(windowController.window?.title.contains("Limited editing") == true,
              "document window identifies limited editing")
        let selectAll = NSMenuItem(title: "Select All", action: #selector(DocumentWindowController.selectAll(_:)), keyEquivalent: "")
        check(windowController.validateMenuItem(selectAll) == opened.storage.allowsLabSelections,
              "Select All follows the layered Lab selection capability")
        let saveCopy = NSMenuItem(title: "Save a Copy", action: #selector(DocumentWindowController.saveDocumentCopy(_:)), keyEquivalent: "")
        check(windowController.validateMenuItem(saveCopy), "Save a Copy stays available")
        check(opened.storage.layout == .layeredLab && opened.storage.allowsLayerProperties,
              "document recognizes limited layered Lab editing")
        check(!opened.acceptsEdits && opened.acceptsLayerSelection,
              "layer selection remains available while editing is disabled")
        check(opened.acceptsLayerProperties, "layer properties are available")
        check(opened.colorInfo.mode == .lab && opened.labAxes == nil && opened.channels.isEmpty,
              "document does not expose private Lab planes as channels")
        check(opened.layers.count == 2, "document shows two logical layers")
        if ProcessInfo.processInfo.environment["GLIMS_REQUIRE_LAB_LAYER_SNAPSHOT"] == "1" {
            check(session.supportsLabLayerSnapshot, "test adapter supports atomic Lab layer snapshots")
            if session.supportsLabLayerSnapshot {
                let snapshot = try session.labLayerSnapshot(image)
                check(snapshot.map(\.layer) == opened.layers,
                      "Swift snapshot returns the displayed Lab layer rows")
                let identities = try snapshot.map { try session.labLayerPropertyTarget(image, root: $0.layer.id).uuid }
                check(snapshot.map(\.identity) == identities && Set(identities).count == snapshot.count,
                      "Swift snapshot pairs each displayed Lab row with its native UUID")
            }
        } else if !session.supportsLabLayerSnapshot {
            check((try? session.labLayerSnapshot(image)) == nil,
                  "an older engine refuses atomic Lab layer snapshots safely")
        }
        check(opened.toolIsAvailable(.paintbrush) == opened.storage.allowsLabLayerBrush && opened.toolIsAvailable(.zoom),
              "Brush follows its layered Lab capability while zoom remains available")
        check(opened.toolIsAvailable(.eyedropper) == session.supportsLayeredLabSampling,
              "Eyedropper follows its layered Lab sampling capability")
        if ProcessInfo.processInfo.environment["GLIMS_REQUIRE_LAYERED_LAB_SAMPLING"] == "1" {
            check(session.supportsLayeredLabSampling, "test adapter supports layered Lab color sampling")
        }
        let originalTool = ToolState.shared.current
        defer { ToolState.shared.select(originalTool) }
        let toolPalette = ToolsPaletteController()
        _ = toolPalette.view
        let flatImage = try session.newLabImage(width: 4, height: 4, component: .u8)
        let flatDocument: ImageDocument
        do { flatDocument = try ImageDocument(session: session, image: flatImage, name: "Flat Lab") }
        catch { try? session.closeImage(flatImage); throw error }
        defer {
            toolPalette.retarget(to: nil)
            flatDocument.closeImageWhenDrained()
            let deadline = Date().addingTimeInterval(15)
            while (try? session.info(flatImage)) != nil && Date() < deadline {
                EngineSmokeTestHost.pumpEvents(for: 0.02)
            }
            check((try? session.info(flatImage)) == nil, "flat Lab palette fixture closes")
        }
        toolPalette.retarget(to: flatDocument)
        toolPalette.retarget(to: opened)
        if let grid = toolPalette.view.subviews.compactMap({ $0 as? ClassicToolGrid }).first {
            let enabled = grid.slots.flatMap(\.tools).first { $0.id == ToolID.rectangleSelect.rawValue }?.isEnabled
            check(enabled == opened.storage.allowsLabSelections,
                  "Tools palette updates selection availability when switching between Lab layouts")
            let brushEnabled = grid.slots.flatMap(\.tools).first { $0.id == ToolID.paintbrush.rawValue }?.isEnabled
            check(brushEnabled == opened.storage.allowsLabLayerBrush,
                  "Tools palette updates Brush availability for the layered Lab layout")
            let sampleEnabled = grid.slots.flatMap(\.tools).first { $0.id == ToolID.eyedropper.rawValue }?.isEnabled
            check(sampleEnabled == session.supportsLayeredLabSampling,
                  "Tools palette updates Eyedropper availability for the layered Lab layout")
        } else { check(false, "Tools palette contains its tool grid") }
        do {
            let previousTool = ToolState.shared.current
            defer { ToolState.shared.select(previousTool) }
            ToolState.shared.select(.paintbrush)
            let options = ToolOptionsPaletteController()
            _ = options.view
            options.retarget(to: opened)
            defer { options.retarget(to: nil) }
            func optionDescendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap { optionDescendants($0) }
            }
            let labels = optionDescendants(options.view).compactMap { ($0 as? NSTextField)?.stringValue }
            let activeHint = labels.contains { $0.contains("Paint the selected Lab layer") }
            check(activeHint == opened.toolIsAvailable(.paintbrush),
                  "Brush hint matches layered Lab tool availability")
        }
        func drain(_ step: String) {
            let deadline = Date().addingTimeInterval(15)
            while opened.pendingWork > 0 && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
            check(opened.pendingWork == 0, "engine work finishes after \(step)")
        }
        if opened.storage.allowsLabSelections {
            check(opened.toolIsAvailable(.rectangleSelect) && opened.toolIsAvailable(.ellipseSelect) &&
                  opened.toolIsAvailable(.lasso), "layered Lab selection tools are available")
            windowController.selectAll(nil)
            drain("Select All")
            check(opened.selectionBounds == CGRect(x: 0, y: 0, width: 4, height: 4),
                  "Select All changes the layered Lab root mask")
            let undo = EngineUndoManager(document: opened)
            check(undo.canUndo, "layered Lab selection offers Undo")
            undo.undo(); drain("selection Undo")
            check(opened.selectionBounds == nil, "Undo restores the empty selection")
            let state = ToolState.shared
            let oldTool = state.current, oldOptions = state.selectOptions
            defer { state.selectOptions = oldOptions; state.select(oldTool) }
            state.selectOptions = EngineSession.SelectOptions()
            state.select(.rectangleSelect)
            if let window = windowController.window {
                let canvas = windowController.canvas
                func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
                    NSEvent.mouseEvent(with: type,
                        location: canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                if let down = mouse(.leftMouseDown, CGPoint(x: 1, y: 1)),
                   let drag = mouse(.leftMouseDragged, CGPoint(x: 3, y: 3)),
                   let up = mouse(.leftMouseUp, CGPoint(x: 3, y: 3)) {
                    canvas.mouseDown(with: down); canvas.mouseDragged(with: drag); canvas.mouseUp(with: up)
                    drain("rectangle selection gesture")
                    check(opened.selectionBounds == CGRect(x: 1, y: 1, width: 2, height: 2),
                          "canvas rectangle gesture edits the layered Lab selection")
                    undo.undo(); drain("rectangle selection Undo")
                    check(opened.selectionBounds == nil, "Undo removes the canvas selection")
                } else { check(false, "canvas selection events can be created") }
            } else { check(false, "layered Lab window exists for selection gesture") }
            try opened.startRecording()
            check(windowController.validateMenuItem(selectAll), "layered Lab selection is enabled while recording")
            windowController.selectAll(nil); drain("recorded Select All")
            if let window = windowController.window {
                let canvas = windowController.canvas
                func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
                    NSEvent.mouseEvent(with: type,
                        location: canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil),
                        modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
                }
                if let down = event(.leftMouseDown, CGPoint(x: 1, y: 1)),
                   let drag = event(.leftMouseDragged, CGPoint(x: 3, y: 3)),
                   let up = event(.leftMouseUp, CGPoint(x: 3, y: 3)) {
                    canvas.mouseDown(with: down); canvas.mouseDragged(with: drag); canvas.mouseUp(with: up)
                } else { check(false, "recorded selection canvas events can be created") }
            } else { check(false, "layered Lab window exists for recorded selection") }
            drain("recorded Lab rectangle")
            try opened.stopRecording()
            let deadline = Date().addingTimeInterval(15)
            while opened.recorder.pendingCount != 0 && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
            let records = opened.recorder.records
            if records.count == 2,
               case .success(.labSelection) = records[0].resolution,
               case .success(.labSelection) = records[1].resolution {
                check(opened.selectionBounds == CGRect(x: 1, y: 1, width: 2, height: 2),
                      "Recorder captures layered Lab All and rectangle selections in order")
                let url = work.appendingPathComponent("layered-lab-selection.glims-recording")
                var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
                opened.saveRecording(to: url, checkpoint: try opened.recorderSaveCheckpoint()) { saved = $0 }
                drain("save layered Lab selections")
                guard let saved else { throw NSError(domain: "LayeredLabSmoke", code: 6) }
                _ = try saved.get()
                let data = try Data(contentsOf: url)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                check(json?["version"] as? Int == 15, "layered Lab selections use recording version 15")
                let file = try RecorderFileCodec.decode(data)
                check(file.records.count == 2 && file.records.allSatisfy {
                    if case .success(.labSelection, .none) = $0.outcome { return true }
                    return false
                }, "layered Lab selections save without a layer binding")
                undo.undo(); drain("recorded rectangle Undo")
                undo.undo(); drain("recorded Select All Undo")
                check(opened.selectionBounds == nil, "Undo restores the mask before recorded Lab selections")
                try opened.startReplay(); drain("layered Lab selection replay")
                let replayDeadline = Date().addingTimeInterval(15)
                while opened.recorder.isReplaying && Date() < replayDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                if case .finished = opened.replayStatus {
                    check(opened.selectionBounds == CGRect(x: 1, y: 1, width: 2, height: 2),
                          "recorded Lab selections replay on the layered root mask")
                } else { check(false, "recorded Lab selections replay on the layered root mask") }
                undo.undo(); drain("replayed rectangle Undo")
                undo.undo(); drain("replayed Select All Undo")
                check(opened.selectionBounds == nil, "Undo restores the mask after Lab selection replay")
                _ = opened.clearRecording()
                let prepared = try RecorderFileSemanticBridge.prepare(file)
                var installed: Result<Void, Error>?
                opened.installRecording(prepared, checkpoint: try opened.recorderInstallCheckpoint(), choices: [:]) { installed = $0 }
                drain("install layered Lab selection recording")
                guard let installed else { throw NSError(domain: "LayeredLabSmoke", code: 7) }
                try installed.get()
                try opened.startReplay(); drain("loaded layered Lab selection replay")
                let loadedDeadline = Date().addingTimeInterval(15)
                while opened.recorder.isReplaying && Date() < loadedDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                if case .finished = opened.replayStatus {
                    check(opened.selectionBounds == CGRect(x: 1, y: 1, width: 2, height: 2),
                          "loaded Lab selections replay on the layered root mask")
                } else { check(false, "loaded Lab selections replay on the layered root mask") }
                undo.undo(); drain("loaded rectangle Undo")
                undo.undo(); drain("loaded Select All Undo")
                check(opened.selectionBounds == nil, "Undo restores the mask after loaded Lab selection replay")
            } else { check(false, "Recorder captures layered Lab All and rectangle selections in order") }
            _ = opened.clearRecording()
        } else {
            check(!opened.toolIsAvailable(.rectangleSelect), "older engines keep layered Lab selection disabled")
        }
        if ProcessInfo.processInfo.environment["GLIMS_REQUIRE_LAYERED_LAB_GUARDED_PROPERTIES"] == "1" {
            check(session.supportsLabLayerPropertyChange, "test adapter supports guarded Lab layer properties")
        }
        if let root = opened.selectedLayerIDs.first,
           let original = try session.layers(image).first(where: { $0.id == root }) {
            let before = try session.undoInfo(image)
            let target: EngineSession.LabLayerFillTarget
            if session.supportsLabLayerPropertyChange {
                target = try session.labLayerPropertyTarget(image, root: root)
                var staleBytes = target.uuid.uuid
                staleBytes.0 ^= 0x80
                let stale = EngineSession.LabLayerFillTarget(root: root, uuid: UUID(uuid: staleBytes))
                var staleError: EngineSession.EngineError?
                do { try session.changeLabLayer(image, target: stale, change: .init(opacity: 0.375)) }
                catch { staleError = error as? EngineSession.EngineError }
                let after = try session.undoInfo(image)
                let staleLayer = try session.layers(image).first(where: { $0.id == root })
                check(staleError?.status == Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue) && after == before &&
                      staleLayer?.opacity == original.opacity,
                      "guarded Lab property bridge refuses a stale UUID without changes")
                let nextOpacity = original.opacity == 0.375 ? 0.625 : 0.375
                try session.changeLabLayer(image, target: target, change: .init(opacity: nextOpacity))
                let changed = try session.layers(image).first(where: { $0.id == root })
                check(changed?.opacity == nextOpacity, "guarded Lab property bridge changes the captured layer")
                try session.undo(image)
                EngineSmokeTestHost.pumpEvents(for: 0.1); drain("guarded Lab property Undo")
                let restored = try session.layers(image).first(where: { $0.id == root })
                check(restored?.opacity == original.opacity, "Undo restores guarded Lab property bridge change")
            } else {
                target = .init(root: root, uuid: UUID(uuidString: "00112233-4455-6677-8899-AABBCCDDEEFF")!)
                var refusal: EngineSession.EngineError?
                do { try session.changeLabLayer(image, target: target, change: .init(opacity: 0.375)) }
                catch { refusal = error as? EngineSession.EngineError }
                let after = try session.undoInfo(image)
                let current = try session.layers(image).first(where: { $0.id == root })
                check(refusal?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue) && after == before &&
                      current?.opacity == original.opacity,
                      "older engines refuse guarded Lab properties without changes")
            }
        } else { check(false, "guarded Lab property bridge has a logical root") }
        if let root = opened.selectedLayerIDs.first,
           let original = try session.layers(image).first(where: { $0.id == root }),
           let other = opened.layers.first(where: { $0.id != root }) {
            let symbol = UUID()
            let description = RecorderTargetDescription(name: "Lab layer", kind: .pixel, ancestors: [], siblingIndex: 0,
                bounds: .init(x: 0, y: 0, width: Double(opened.info.width), height: Double(opened.info.height)))
            let value = RecorderFileCommand.LayerProperties(name: nil, visible: nil, opacity: 0.375, mode: nil)
            let file = RecorderFileValue(recordingID: UUID(), name: "Lab layer properties",
                origin: .init(imageLabel: "Lab.xcf", initialWidth: Int(opened.info.width), initialHeight: Int(opened.info.height)),
                symbols: [.init(id: symbol, description: description)],
                records: [.init(ordinal: 0, outcome: .success(.layerProperties(value), .layer(symbol)))])
            let prepared = try RecorderFileSemanticBridge.prepare(RecorderFileCodec.decode(RecorderFileCodec.encode(file)))
            let priorError = opened.onError
            opened.onError = { _ in }
            defer { opened.onError = priorError; _ = opened.clearRecording() }
            let history = try session.undoInfo(image)
            EngineSmokeTestHost.pumpEvents(for: 0.1); drain("before Lab property recording installation")
            var installed: Result<Void, Error>?
            opened.installRecording(prepared, checkpoint: try opened.recorderInstallCheckpoint(),
                                    choices: [symbol: .layer(root)]) { installed = $0 }
            drain("Lab property recording installation")
            guard let installed else { throw NSError(domain: "LayeredLabSmoke", code: 8) }
            if session.supportsLabLayerPropertyChange {
                try installed.get()
                opened.selectLayer(other.id); drain("select another layer before property replay")
                let otherBefore = try session.layers(image).first(where: { $0.id == other.id })
                try opened.startReplay(); drain("bound Lab property replay")
                let deadline = Date().addingTimeInterval(15)
                while opened.recorder.isReplaying && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                let after = try session.layers(image)
                let selection = try session.selectedLayers(image)
                if case .finished = opened.replayStatus {
                    check(after.first(where: { $0.id == root })?.opacity == 0.375 &&
                          after.first(where: { $0.id == other.id })?.opacity == otherBefore?.opacity && selection == [other.id],
                          "loaded Lab property recording edits its bound root while another is selected")
                } else { check(false, "loaded Lab property recording edits its bound root while another is selected") }
                opened.undo(); drain("bound Lab property replay Undo")
                let restored = try session.layers(image).first(where: { $0.id == root })
                check(restored?.opacity == original.opacity, "Undo restores loaded Lab property replay")
                opened.selectLayer(root); drain("select recorded property target for deletion")
                opened.layerCommand(.delete); drain("delete recorded property target")
                let afterDelete = try session.layers(image)
                if !afterDelete.contains(where: { $0.id == root }) {
                    let beforeRefusal = try session.undoInfo(image)
                    let remaining = afterDelete.first(where: { $0.id == other.id })
                    try opened.startReplay(); drain("refused deleted Lab property target")
                    let refusalDeadline = Date().addingTimeInterval(15)
                    while opened.recorder.isReplaying && Date() < refusalDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                    let afterRefusal = try session.undoInfo(image)
                    let current = try session.layers(image).first(where: { $0.id == other.id })
                    if case .failed(_, let reason) = opened.replayStatus {
                        check(reason == "The bound Lab layer is no longer available for this property change." &&
                              beforeRefusal == afterRefusal && current?.opacity == remaining?.opacity &&
                              current?.isVisible == remaining?.isVisible,
                              "deleted Lab property target refuses replay without changes")
                    } else { check(false, "deleted Lab property target refuses replay without changes") }
                    opened.undo(); drain("restore deleted Lab property target")
                } else { check(false, "recorded Lab property target can be deleted for refusal test") }
                opened.selectLayer(root); drain("restore selection after Lab property replay")
                let mixed = RecorderFileCommand.LayerProperties(name: "Mixed", visible: nil, opacity: 0.375, mode: nil)
                let incompatible = RecorderFileValue(recordingID: UUID(), name: "Incompatible Lab properties", origin: file.origin,
                    symbols: file.symbols, records: [.init(ordinal: 0, outcome: .success(.layerProperties(mixed), .layer(symbol)))])
                let invalidPrepared = try RecorderFileSemanticBridge.prepare(RecorderFileCodec.decode(RecorderFileCodec.encode(incompatible)))
                EngineSmokeTestHost.pumpEvents(for: 0.1); drain("before incompatible Lab property installation")
                let priorRecording = opened.recorderContentCheckpoint()
                let beforeInvalid = try session.undoInfo(image)
                var rejected: Result<Void, Error>?
                opened.installRecording(invalidPrepared, checkpoint: try opened.recorderInstallCheckpoint(),
                                        choices: [symbol: .layer(root)]) { rejected = $0 }
                drain("incompatible Lab property installation")
                let afterInvalid = try session.undoInfo(image)
                if case .failure(let error)? = rejected {
                    check((error as? RecorderFileError) == .invalid("A Lab layer property recording must change only its name, visibility or opacity.") &&
                          beforeInvalid == afterInvalid && opened.recorderContentCheckpoint() == priorRecording,
                          "incompatible Lab property recording preserves the current recording and image")
                } else { check(false, "incompatible Lab property recording preserves the current recording and image") }
            } else {
                let after = try session.undoInfo(image)
                let current = try session.layers(image).first(where: { $0.id == root })
                if case .failure(let error) = installed {
                    check((error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue) &&
                          after == history && current?.opacity == original.opacity,
                          "older engines refuse loaded Lab property recordings without changes")
                } else { check(false, "older engines refuse loaded Lab property recordings without changes") }
            }
        } else { check(false, "loaded Lab property replay has two logical roots") }
        let fillMenu = NSMenuItem(title: "Fill", action: #selector(DocumentWindowController.fill(_:)), keyEquivalent: "")
        check(windowController.validateMenuItem(fillMenu) == opened.storage.allowsLabLayerColorFill,
              "Fill menu follows the layered Lab color capability")
        if ProcessInfo.processInfo.environment["GLIMS_REQUIRE_LAYERED_LAB_COLOR_FILL"] == "1" {
            check(opened.storage.allowsLabLayerColorFill, "test adapter advertises layered Lab color Fill")
        }
        if ProcessInfo.processInfo.environment["GLIMS_REQUIRE_LAYERED_LAB_GUARDED_FILL"] == "1" {
            check(session.supportsLabLayerColorFillEmptySelection, "test adapter supports guarded Lab color Fill")
        }
        if opened.storage.allowsLabLayerColorFill, let window = windowController.window,
           let originalRoot = opened.selectedLayerIDs.first {
            let oldForeground = ToolState.shared.foreground
            defer { ToolState.shared.foreground = oldForeground }
            ToolState.shared.foreground = .red
            let beforeRecording = pixel(session, image, x: 1, y: 1)
            let previousError = opened.onError
            var recordingErrors: [String] = []
            opened.onError = { recordingErrors.append($0) }
            defer { opened.onError = previousError }
            func waitForSheet() -> NSWindow? {
                let deadline = Date().addingTimeInterval(15)
                while window.attachedSheet == nil && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                return window.attachedSheet
            }
            try opened.startRecording()
            if session.supportsLabLayerColorFillEmptySelection {
                check(windowController.validateMenuItem(fillMenu), "guarded Lab Fill is enabled while recording")
                windowController.fill(nil)
                if let sheet = waitForSheet() {
                    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    EngineSmokeTestHost.pumpEvents(for: 0.1); drain("recorded Lab layer Fill")
                    try opened.stopRecording()
                    let deadline = Date().addingTimeInterval(15)
                    while opened.recorder.pendingCount != 0 && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                    let recordedPixel = pixel(session, image, x: 1, y: 1)
                    if let row = opened.recorder.records.first, case .success(.fillLabLayer(let value)) = row.resolution {
                        check(value.color.red == 1 && value.color.green == 0 && value.color.blue == 0 &&
                              value.opacity == 1 && recordedPixel != beforeRecording && recordingErrors.isEmpty,
                              "Recorder captures the accepted Lab Fill color and opacity")
                    } else { check(false, "Recorder captures the accepted Lab Fill color and opacity") }
                    let recordingURL = work.appendingPathComponent("layered-lab-fill.glims-recording")
                    var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
                    opened.saveRecording(to: recordingURL, checkpoint: try opened.recorderSaveCheckpoint()) { saved = $0 }
                    drain("save layered Lab Fill recording")
                    guard let saved else { throw NSError(domain: "LayeredLabSmoke", code: 5) }
                    _ = try saved.get()
                    let savedFile = try RecorderFileCodec.decode(Data(contentsOf: recordingURL))
                    if let row = savedFile.records.first, case .success(.fillLabLayer, .layer) = row.outcome {
                        check(true, "recorded Lab Fill saves with an explicit layer binding")
                    } else { check(false, "recorded Lab Fill saves with an explicit layer binding") }
                    opened.undo(); drain("recorded Lab Fill Undo")
                    check(pixel(session, image, x: 1, y: 1) == beforeRecording,
                          "Undo restores the image before the recorded Lab Fill")
                    try opened.startReplay(); drain("live-bound Lab Fill replay")
                    let replayDeadline = Date().addingTimeInterval(15)
                    while opened.recorder.isReplaying && Date() < replayDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                    if case .finished = opened.replayStatus {
                        check(pixel(session, image, x: 1, y: 1) == recordedPixel,
                              "recorded Lab Fill replays on its original bound layer")
                    } else { check(false, "recorded Lab Fill replays on its original bound layer") }
                    opened.undo(); drain("recorded Lab Fill replay Undo")
                    check(pixel(session, image, x: 1, y: 1) == beforeRecording,
                          "Undo restores the replayed Lab Fill")
                    _ = opened.clearRecording()
                    let beforeCancel = try session.undoInfo(image)
                    try opened.startRecording()
                    windowController.fill(nil)
                    if let cancelled = waitForSheet() {
                        window.endSheet(cancelled, returnCode: .alertSecondButtonReturn)
                        EngineSmokeTestHost.pumpEvents(for: 0.1); drain("cancel recorded Lab Fill")
                        try opened.stopRecording()
                        let settleDeadline = Date().addingTimeInterval(15)
                        while opened.recorder.pendingCount != 0 && Date() < settleDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                        let afterCancel = try session.undoInfo(image)
                        check(opened.recorder.pendingCount == 0 && opened.recorder.records.isEmpty && beforeCancel == afterCancel &&
                              pixel(session, image, x: 1, y: 1) == beforeRecording,
                              "cancelling the recorded Lab Fill sheet leaves no record or changes")
                        _ = opened.clearRecording()
                    } else {
                        check(false, "recorded Lab Fill sheet opens for cancellation")
                        try opened.stopRecording(); _ = opened.clearRecording()
                    }
                    windowController.fill(nil)
                    if let sheet = waitForSheet() {
                        try opened.startRecording()
                        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                        EngineSmokeTestHost.pumpEvents(for: 0.1); drain("start recording with Lab Fill sheet open")
                        try opened.stopRecording()
                        let deadline = Date().addingTimeInterval(15)
                        while opened.recorder.pendingCount != 0 && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                        if let row = opened.recorder.records.first, case .success(.fillLabLayer(_)) = row.resolution {
                            check(pixel(session, image, x: 1, y: 1) != beforeRecording,
                                  "Lab Fill admitted after recording starts is recorded")
                        } else { check(false, "Lab Fill admitted after recording starts is recorded") }
                        opened.undo(); drain("Undo Fill after starting recording")
                        _ = opened.clearRecording()
                    } else { check(false, "Lab Fill sheet opens before recording starts") }
                    try opened.startRecording()
                    windowController.fill(nil)
                    if let sheet = waitForSheet() {
                        try opened.stopRecording()
                        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                        EngineSmokeTestHost.pumpEvents(for: 0.1); drain("stop recording with Lab Fill sheet open")
                        let settleDeadline = Date().addingTimeInterval(15)
                        while opened.recorder.pendingCount != 0 && Date() < settleDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                        check(opened.recorder.pendingCount == 0 && opened.recorder.records.isEmpty && pixel(session, image, x: 1, y: 1) != beforeRecording,
                              "Lab Fill admitted after recording stops is not recorded")
                        opened.undo(); drain("Undo Fill after stopping recording")
                        _ = opened.clearRecording()
                    } else {
                        check(false, "recorded Lab Fill sheet opens before recording stops")
                        try opened.stopRecording(); _ = opened.clearRecording()
                    }
                    opened.select(.rectangle(CGRect(x: 1, y: 1, width: 2, height: 2)), options: .init())
                    drain("selection before recorded Lab Fill")
                    let selectedHistory = try session.undoInfo(image)
                    recordingErrors.removeAll()
                    try opened.startRecording()
                    check(!windowController.validateMenuItem(fillMenu), "recorded Lab Fill is disabled with a selection")
                    windowController.fill(nil)
                    EngineSmokeTestHost.pumpEvents(for: 0.1); drain("selected recorded Lab Fill refusal")
                    let unexpectedSheet = window.attachedSheet
                    if let unexpectedSheet { window.endSheet(unexpectedSheet, returnCode: .alertSecondButtonReturn) }
                    try opened.stopRecording()
                    let afterRefusal = try session.undoInfo(image)
                    check(!recordingErrors.isEmpty && unexpectedSheet == nil && opened.recorder.records.isEmpty &&
                          selectedHistory == afterRefusal && pixel(session, image, x: 1, y: 1) == beforeRecording,
                          "recorded Lab Fill refuses an uncaptured selection without changes")
                    _ = opened.clearRecording(); recordingErrors.removeAll()
                    opened.undo(); drain("restore selection after recorded Lab Fill refusal")
                } else {
                    check(false, "guarded Lab Fill opens while recording")
                    try opened.stopRecording(); _ = opened.clearRecording()
                }
            } else {
                check(!windowController.validateMenuItem(fillMenu), "older engines disable Lab Fill while recording")
                windowController.fill(nil)
                EngineSmokeTestHost.pumpEvents(for: 0.1); drain("Lab Fill refusal during recording")
                check(!recordingErrors.isEmpty && window.attachedSheet == nil &&
                      pixel(session, image, x: 1, y: 1) == beforeRecording && opened.recorder.records.isEmpty,
                      "older engines refuse recorded Lab Fill without changes")
                try opened.stopRecording(); _ = opened.clearRecording()
            }
            opened.onError = previousError
            opened.select(.rectangle(CGRect(x: 1, y: 1, width: 2, height: 2)), options: .init())
            drain("fill selection")
            let insideBefore = pixel(session, image, x: 1, y: 1)
            let outsideBefore = pixel(session, image, x: 0, y: 0)
            let guardedTarget = try session.labLayerFillTarget(image, root: originalRoot)
            let guardedColor = EngineSession.RGBAColor(red: 1, green: 0, blue: 0, alpha: 1)
            let beforeGuardedRefusal = try session.undoInfo(image)
            var guardedRefusal: EngineSession.EngineError?
            do { try session.fillLabLayer(image, target: guardedTarget, color: guardedColor, opacity: 1, requireEmptySelection: true) }
            catch { guardedRefusal = error as? EngineSession.EngineError }
            let afterGuardedRefusal = try session.undoInfo(image)
            let expectedGuardedStatus = session.supportsLabLayerColorFillEmptySelection
                ? GLIMS_STATUS_INVALID_ARGUMENT : GLIMS_STATUS_UNSUPPORTED
            check(guardedRefusal?.status == Int32(expectedGuardedStatus.rawValue) &&
                  beforeGuardedRefusal == afterGuardedRefusal && pixel(session, image, x: 1, y: 1) == insideBefore,
                  "guarded Lab Fill refuses a selection or older engine without changing pixels or history")
            windowController.fill(nil)
            if let sheet = waitForSheet() {
                check(true, "captured Lab layer Fill sheet opens")
                window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                EngineSmokeTestHost.pumpEvents(for: 0.1); drain("Lab color fill")
                let insideAfter = pixel(session, image, x: 1, y: 1)
                check(insideAfter?.count == 4 && (insideAfter?[0] ?? 0) > 245 &&
                      (insideAfter?[1] ?? 255) < 20 && (insideAfter?[2] ?? 255) < 20 &&
                      pixel(session, image, x: 0, y: 0) == outsideBefore,
                      "foreground Fill changes only selected pixels to red")
                if session.supportsLayeredLabSampling {
                    let canvas = windowController.canvas
                    let location = canvas.convert(CGPoint(x: 1.5 * canvas.scale, y: 1.5 * canvas.scale), to: nil)
                    if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 1, clickCount: 1, pressure: 1),
                       let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 2, clickCount: 1, pressure: 0) {
                        let priorTool = ToolState.shared.current
                        ToolState.shared.foreground = .blue
                        ToolState.shared.select(.eyedropper)
                        canvas.mouseDown(with: down); canvas.mouseUp(with: up)
                        EngineSmokeTestHost.pumpEvents(for: 0.1)
                        let sampled = ToolState.shared.foreground.usingColorSpace(.sRGB)
                        check(sampled != nil && (sampled?.redComponent ?? 0) > 0.95 &&
                              (sampled?.greenComponent ?? 1) < 0.08 && (sampled?.blueComponent ?? 1) < 0.08,
                              "Eyedropper samples the composited layered Lab color after Fill")
                        ToolState.shared.select(priorTool)
                        ToolState.shared.foreground = .red
                    } else { check(false, "layered Lab Eyedropper mouse events can be created") }
                }
                do {
                    let canvas = windowController.canvas
                    let location = canvas.convert(CGPoint(x: 1.5 * canvas.scale, y: 1.5 * canvas.scale), to: nil)
                    if let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [.option],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 3, clickCount: 1, pressure: 1),
                       let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [.option],
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 4, clickCount: 1, pressure: 0) {
                        let priorTool = ToolState.shared.current
                        let history = try session.undoInfo(image)
                        ToolState.shared.foreground = .blue
                        ToolState.shared.select(.paintbrush)
                        canvas.mouseDown(with: down)
                        let blockedStatus = windowController.statusBar.message
                        canvas.mouseUp(with: up)
                        EngineSmokeTestHost.pumpEvents(for: 0.1); drain("Option-click layered Lab Brush")
                        if !session.supportsLayeredLabSampling {
                            check(blockedStatus == "Release Option to paint the selected Lab layer.",
                                  "unsupported Option Brush explains how to resume painting")
                        }
                        let sampled = ToolState.shared.foreground.usingColorSpace(.sRGB)
                        let expectedColor = session.supportsLayeredLabSampling
                            ? (sampled?.redComponent ?? 0) > 0.95 && (sampled?.blueComponent ?? 1) < 0.08
                            : (sampled?.blueComponent ?? 0) > 0.95 && (sampled?.redComponent ?? 1) < 0.08
                        let afterHistory = try session.undoInfo(image)
                        check(expectedColor && !opened.strokeIsActive && history == afterHistory,
                              "Option-click samples only on capable layered Lab engines without painting")
                        ToolState.shared.select(priorTool)
                        ToolState.shared.foreground = .red
                    } else { check(false, "layered Lab Option-click events can be created") }
                }
                // Option sampling owns the entire gesture, even if Option is released
                // before the pointer. Moving to a different pixel must update the color.
                do {
                    let canvas = windowController.canvas
                    let redLocation = canvas.convert(CGPoint(x: 1.5 * canvas.scale, y: 1.5 * canvas.scale), to: nil)
                    let otherLocation = canvas.convert(CGPoint(x: 0.5 * canvas.scale, y: 0.5 * canvas.scale), to: nil)
                    func event(_ type: NSEvent.EventType, _ location: NSPoint, _ flags: NSEvent.ModifierFlags) -> NSEvent? {
                        NSEvent.mouseEvent(with: type, location: location, modifierFlags: flags,
                            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                            context: nil, eventNumber: 5, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
                    }
                    if let down = event(.leftMouseDown, redLocation, [.option]),
                       let move = event(.leftMouseDragged, otherLocation, [.option]),
                       let releaseOption = event(.leftMouseDragged, redLocation, []),
                       let up = event(.leftMouseUp, redLocation, []) {
                        let priorTool = ToolState.shared.current
                        let priorForeground = ToolState.shared.foreground
                        let history = try session.undoInfo(image)
                        let outsideBeforeDrag = pixel(session, image, x: 0, y: 0)
                        let native = session.supportsLayeredLabSampling
                            ? try session.sampleLayeredLabColor(image, x: 0, y: 0) : nil
                        ToolState.shared.foreground = .blue
                        ToolState.shared.select(.paintbrush)
                        canvas.mouseDown(with: down)
                        let first = ToolState.shared.foreground.usingColorSpace(.sRGB)
                        canvas.mouseDragged(with: move)
                        let moved = ToolState.shared.foreground.usingColorSpace(.sRGB)
                        canvas.mouseDragged(with: releaseOption)
                        let released = ToolState.shared.foreground.usingColorSpace(.sRGB)
                        canvas.mouseUp(with: up)
                        EngineSmokeTestHost.pumpEvents(for: 0.1); drain("Option-drag layered Lab Brush")
                        let afterHistory = try session.undoInfo(image)
                        let expected = native.map { $0.alpha > 0 ? [$0.red, $0.green, $0.blue].map { min(1, max(0, $0)) } : [0, 0, 0] }
                        let movedMatches = expected.map { values in
                            guard let moved else { return false }
                            return abs(moved.redComponent - values[0]) < 0.01 &&
                                abs(moved.greenComponent - values[1]) < 0.01 && abs(moved.blueComponent - values[2]) < 0.01
                        } ?? ((moved?.blueComponent ?? 0) > 0.95)
                        let firstMatches = session.supportsLayeredLabSampling
                            ? (first?.redComponent ?? 0) > 0.95 : (first?.blueComponent ?? 0) > 0.95
                        let releaseMatches = session.supportsLayeredLabSampling
                            ? (released?.redComponent ?? 0) > 0.95 : (released?.blueComponent ?? 0) > 0.95
                        check(firstMatches && movedMatches && releaseMatches && !opened.strokeIsActive &&
                              history == afterHistory && pixel(session, image, x: 1, y: 1) == insideAfter &&
                              pixel(session, image, x: 0, y: 0) == outsideBeforeDrag,
                              "Option-drag samples its whole gesture without painting or changing history")
                        ToolState.shared.select(priorTool)
                        ToolState.shared.foreground = priorForeground
                    } else { check(false, "layered Lab Option-drag events can be created") }
                }
                let undo = EngineUndoManager(document: opened)
                check(undo.canUndo, "Lab color fill offers Undo")
                undo.undo(); drain("Lab color fill Undo")
                check(pixel(session, image, x: 1, y: 1) == insideBefore, "Undo restores pixels before Lab color fill")
                undo.redo(); drain("Lab color fill Redo")
                check(pixel(session, image, x: 1, y: 1) == insideAfter, "Redo restores the Lab color fill")
                undo.undo(); drain("restore pixels after Lab color fill")
                undo.undo(); drain("restore selection after Lab color fill")
                check(opened.selectionBounds == nil, "fill fixture restores its empty selection")
                if session.supportsLabLayerColorFillEmptySelection {
                    let beforeGuardedFill = pixel(session, image, x: 1, y: 1)
                    let beforeGuardedHistory = try session.undoInfo(image)
                    try session.fillLabLayer(image, target: guardedTarget, color: guardedColor, opacity: 1, requireEmptySelection: true)
                    let afterGuardedHistory = try session.undoInfo(image)
                    check(pixel(session, image, x: 1, y: 1) != beforeGuardedFill &&
                          afterGuardedHistory.undoCount == beforeGuardedHistory.undoCount + 1,
                          "guarded Lab Fill applies on an empty selection as one Undo")
                    try session.undo(image); drain("guarded Lab Fill Undo")
                    check(pixel(session, image, x: 1, y: 1) == beforeGuardedFill,
                          "Undo restores the guarded Lab Fill")
                }
            } else { check(false, "captured Lab layer Fill sheet opens") }
            // Install a detached Fill recording and exercise the document's
            // explicit layer binding and guarded replay path.
            do {
                let symbol = UUID()
                let description = RecorderTargetDescription(name: "Lab layer", kind: .pixel, ancestors: [],
                    siblingIndex: 0, bounds: .init(x: 0, y: 0, width: Double(opened.info.width), height: Double(opened.info.height)))
                let recorded = RecorderLabLayerFillValue(color: try RecorderColor(red: 0, green: 0, blue: 1, alpha: 1), opacity: 1)
                let file = RecorderFileValue(recordingID: UUID(), name: "Lab layer Fill",
                    origin: .init(imageLabel: "Lab.xcf", initialWidth: Int(opened.info.width), initialHeight: Int(opened.info.height)),
                    symbols: [.init(id: symbol, description: description)],
                    records: [.init(ordinal: 0, outcome: .success(.fillLabLayer(recorded), .layer(symbol)))])
                let prepared = try RecorderFileSemanticBridge.prepare(RecorderFileCodec.decode(RecorderFileCodec.encode(file)))
                EngineSmokeTestHost.pumpEvents(for: 0.1); drain("before Lab Fill recording installation")
                var installed: Result<Void, Error>?
                opened.installRecording(prepared, checkpoint: try opened.recorderInstallCheckpoint(),
                                        choices: [symbol: .layer(originalRoot)]) { installed = $0 }
                drain("Lab layer Fill recording installation")
                guard let installed else { throw NSError(domain: "LayeredLabSmoke", code: 4) }
                try installed.get()
                let priorError = opened.onError
                opened.onError = { _ in }
                defer { opened.onError = priorError; _ = opened.clearRecording() }
                let beforeReplay = pixel(session, image, x: 1, y: 1)
                if let other = opened.layers.first(where: { $0.id != originalRoot }) {
                    opened.selectLayer(other.id); drain("change Lab Fill replay layer")
                    let otherHistory = try session.undoInfo(image)
                    try opened.startReplay(); drain("refused Lab Fill replay target")
                    let afterWrongTarget = try session.undoInfo(image)
                    if case .failed = opened.replayStatus {
                        check(pixel(session, image, x: 1, y: 1) == beforeReplay && otherHistory == afterWrongTarget,
                              "installed Lab Fill replay refuses a different layer without changes")
                    } else { check(false, "installed Lab Fill replay refuses a different layer without changes") }
                    opened.selectLayer(originalRoot); drain("restore Lab Fill replay layer")
                } else { check(false, "installed Lab Fill replay has another layer for target validation") }
                if session.supportsLabLayerColorFillEmptySelection {
                    opened.select(.rectangle(CGRect(x: 1, y: 1, width: 2, height: 2)), options: .init())
                    drain("selection before Lab Fill replay")
                    let selectedHistory = try session.undoInfo(image)
                    try opened.startReplay(); drain("refused Lab Fill replay")
                    let afterRefusal = try session.undoInfo(image)
                    if case .failed = opened.replayStatus {
                        check(pixel(session, image, x: 1, y: 1) == beforeReplay && selectedHistory == afterRefusal,
                              "installed Lab Fill replay refuses an uncaptured selection without changes")
                    } else { check(false, "installed Lab Fill replay refuses an uncaptured selection without changes") }
                    opened.undo(); drain("restore selection before Lab Fill replay")
                    try opened.startReplay(); drain("Lab Fill replay")
                    let deadline = Date().addingTimeInterval(15)
                    while opened.recorder.isReplaying && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                    let afterReplay = pixel(session, image, x: 1, y: 1)
                    if case .finished = opened.replayStatus {
                        check(afterReplay?.count == 4 && (afterReplay?[0] ?? 255) < 10 &&
                              (afterReplay?[1] ?? 255) < 10 && (afterReplay?[2] ?? 0) > 245,
                              "installed Lab Fill recording replays its captured color")
                    } else { check(false, "installed Lab Fill recording replays its captured color") }
                    opened.undo(); drain("Lab Fill replay Undo")
                    check(pixel(session, image, x: 1, y: 1) == beforeReplay,
                          "one Undo restores the installed Lab Fill replay")
                } else {
                    let beforeHistory = try session.undoInfo(image)
                    try opened.startReplay(); drain("older engine Lab Fill replay")
                    let afterHistory = try session.undoInfo(image)
                    if case .failed = opened.replayStatus {
                        check(beforeHistory == afterHistory && pixel(session, image, x: 1, y: 1) == beforeReplay,
                              "older engine refuses installed Lab Fill replay without changes")
                    } else { check(false, "older engine refuses installed Lab Fill replay without changes") }
                }
            }
            let beforeInvalidFill = pixel(session, image, x: 1, y: 1)
            windowController.fill(nil)
            if let sheet = waitForSheet() {
                func descendants(_ view: NSView) -> [NSView] {
                    [view] + view.subviews.flatMap { descendants($0) }
                }
                let controls = sheet.contentView.map { descendants($0) } ?? []
                if let field = controls.compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "Fill opacity, percent" }),
                   let choice = controls.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains("Custom") }),
                   let well = controls.compactMap({ $0 as? NSColorWell }).first,
                   let submit = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Fill" }),
                   let action = choice.action {
                    let oldError = opened.onError
                    var errors: [String] = []
                    opened.onError = { errors.append($0) }
                    defer { opened.onError = oldError }
                    choice.selectItem(withTitle: "Custom")
                    NSApp.sendAction(action, to: choice.target, from: choice)
                    well.color = .blue
                    field.stringValue = "not a number"
                    submit.performClick(nil)
                    EngineSmokeTestHost.pumpEvents(for: 0.1); drain("invalid Lab Fill opacity")
                    let stillOpen = window.attachedSheet === sheet
                    sheet.contentView?.layoutSubtreeIfNeeded()
                    let message = controls.compactMap({ $0 as? NSTextField }).first { $0.stringValue == "Enter an opacity from 0 to 100%." }
                    let messageFits = message.map { !$0.isHiddenOrHasHiddenAncestor && $0.bounds.width + 0.5 >= $0.intrinsicContentSize.width } ?? false
                    check(stillOpen && choice.titleOfSelectedItem == "Custom" && well.color == .blue &&
                          field.stringValue == "not a number" && messageFits && errors.isEmpty &&
                          pixel(session, image, x: 1, y: 1) == beforeInvalidFill,
                          "invalid Fill opacity keeps the sheet and its choices without changing pixels")
                    if stillOpen {
                        field.stringValue = "100"
                        submit.performClick(nil)
                        EngineSmokeTestHost.pumpEvents(for: 0.1); drain("corrected Lab Fill opacity")
                        let result = pixel(session, image, x: 1, y: 1)
                        let applied = window.attachedSheet == nil && result?.count == 4 && (result?[2] ?? 0) > 245
                        check(applied,
                              "correcting Fill opacity applies the retained custom color")
                        if window.attachedSheet === sheet { window.endSheet(sheet, returnCode: .alertSecondButtonReturn) }
                        if applied {
                            opened.undo(); drain("corrected Lab Fill Undo")
                            check(pixel(session, image, x: 1, y: 1) == beforeInvalidFill,
                                  "corrected Lab Fill Undo restores prior pixels")
                        } else { check(false, "corrected Lab Fill Undo restores prior pixels") }
                    } else {
                        check(false, "correcting Fill opacity applies the retained custom color")
                    }
                } else {
                    check(false, "Lab Fill opacity and submit controls exist")
                    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
            } else { check(false, "Lab Fill sheet opens for opacity validation") }
            let beforeCustom = pixel(session, image, x: 1, y: 1)
            windowController.fill(nil)
            if let sheet = waitForSheet() {
                func descendants(_ view: NSView) -> [NSView] {
                    [view] + view.subviews.flatMap { descendants($0) }
                }
                let controls = sheet.contentView.map { descendants($0) } ?? []
                if let choice = controls.compactMap({ $0 as? NSPopUpButton }).first(where: { $0.itemTitles.contains("Custom") }),
                   let well = controls.compactMap({ $0 as? NSColorWell }).first,
                   let action = choice.action {
                    choice.selectItem(withTitle: "Custom")
                    NSApp.sendAction(action, to: choice.target, from: choice)
                    check(well.isEnabled, "Custom Fill enables the color well")
                    well.color = .blue
                    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    EngineSmokeTestHost.pumpEvents(for: 0.1); drain("custom Lab color fill")
                    let result = pixel(session, image, x: 1, y: 1)
                    check(result?.count == 4 && (result?[0] ?? 255) < 20 &&
                          (result?[1] ?? 255) < 20 && (result?[2] ?? 0) > 245,
                          "Custom Fill uses the selected blue rather than the red foreground")
                    opened.undo(); drain("custom Lab color fill Undo")
                    check(pixel(session, image, x: 1, y: 1) == beforeCustom,
                          "Undo restores pixels before Custom Fill")
                } else {
                    check(false, "Custom Fill exposes its choice and color well")
                    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
            } else { check(false, "Lab Fill sheet opens for custom color") }
            let beforeCancel = pixel(session, image, x: 1, y: 1)
            windowController.fill(nil)
            if let sheet = waitForSheet() {
                func descendants(_ view: NSView) -> [NSView] {
                    [view] + view.subviews.flatMap { descendants($0) }
                }
                let controls = sheet.contentView.map { descendants($0) } ?? []
                if let field = controls.compactMap({ $0 as? NSTextField }).first(where: { $0.accessibilityLabel() == "Fill opacity, percent" }),
                   let submit = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Fill" }),
                   let cancel = controls.compactMap({ $0 as? NSButton }).first(where: { $0.title == "Cancel" }) {
                    field.stringValue = "101"
                    submit.performClick(nil)
                    EngineSmokeTestHost.pumpEvents(for: 0.1)
                    check(window.attachedSheet === sheet, "out-of-range Fill opacity leaves the sheet open")
                    cancel.performClick(nil)
                    EngineSmokeTestHost.pumpEvents(for: 0.1); drain("cancel Lab Fill")
                    check(window.attachedSheet == nil && pixel(session, image, x: 1, y: 1) == beforeCancel,
                          "Cancel after invalid opacity leaves Lab pixels unchanged")
                } else {
                    check(false, "Lab Fill cancellation controls exist")
                    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)
                }
            } else { check(false, "Lab Fill sheet opens for cancellation") }
            if let other = opened.layers.first(where: { $0.id != originalRoot }) {
                var errors: [String] = []
                let oldError = opened.onError
                opened.onError = { errors.append($0) }
                defer { opened.onError = oldError }
                windowController.fill(nil)
                if let sheet = waitForSheet() {
                    opened.selectLayer(other.id); drain("retarget while Fill is open")
                    if window.attachedSheet === sheet {
                        window.endSheet(sheet, returnCode: .alertFirstButtonReturn)
                    }
                    EngineSmokeTestHost.pumpEvents(for: 0.1); drain("refuse retargeted Lab Fill")
                    check(!errors.isEmpty && pixel(session, image, x: 1, y: 1) == beforeCancel,
                          "Fill refuses a layer changed while its sheet was open")
                    opened.selectLayer(originalRoot); drain("restore captured layer")
                } else { check(false, "Lab Fill sheet opens for retarget test") }
                opened.onError = oldError
            }
        } else if opened.storage.allowsLabLayerColorFill {
            check(false, "layered Lab Fill fixture has a window and selected root")
        }
        if ProcessInfo.processInfo.environment["GLIMS_REQUIRE_LAYERED_LAB_RECORDING"] == "1" {
            check(opened.storage.allowsLabLayerBrush && session.supportsLabLayerBrushEmptySelection,
                  "test adapter advertises guarded layered Lab Brush recording")
        }
        if opened.storage.allowsLabLayerBrush, let window = windowController.window {
            let state = ToolState.shared
            let oldTool = state.current, oldForeground = state.foreground, oldBrush = state.brush(for: .paintbrush)
            defer { state.foreground = oldForeground; state.update(.paintbrush) { $0 = oldBrush }; state.select(oldTool) }
            state.foreground = .red
            state.update(.paintbrush) { $0.size = 4; $0.opacity = 1; $0.hardness = 1; $0.pressureSize = true; $0.resource = nil }
            state.select(.paintbrush)
            let options = ToolOptionsPaletteController()
            _ = options.view
            options.retarget(to: flatDocument); options.retarget(to: opened)
            defer { options.retarget(to: nil) }
            func descendants(_ view: NSView) -> [NSView] {
                [view] + view.subviews.flatMap(descendants)
            }
            let optionViews = descendants(options.view)
            let optionText = optionViews.compactMap { ($0 as? NSTextField)?.stringValue }
            let pressure = optionViews.compactMap { $0 as? NSButton }.first { $0.title == "Pen pressure sets size" }
            check(optionText.contains(where: { $0.contains("foreground color") }) &&
                  !optionText.contains(where: { $0.contains("Select one Lab channel") }) &&
                  pressure?.isEnabled == session.supportsLabLayerBrushPressure &&
                  pressure?.state == (session.supportsLabLayerBrushPressure ? .on : .off),
                  "layered Brush options show foreground color and available pressure behavior")
            if session.supportsLabLayerBrushPressure, let pressure {
                pressure.performClick(nil)
                check(!state.brush(for: .paintbrush).pressureSize, "pressure option can be turned off")
                pressure.performClick(nil)
                check(state.brush(for: .paintbrush).pressureSize, "pressure option can be turned back on")
            }
            let oldError = opened.onError
            var errors: [String] = []
            opened.onError = { errors.append($0) }
            defer { opened.onError = oldError }
            let oldProjection = opened.onProjectionChange
            var brushDamage: [CGRect] = []
            opened.onProjectionChange = { rect in brushDamage.append(rect); oldProjection?(rect) }
            defer { opened.onProjectionChange = oldProjection }
            let before = pixel(session, image, x: 1, y: 1)
            var invalidBrush = state.brush(for: .paintbrush)
            invalidBrush.size = .nan
            opened.beginStroke(at: .init(x: 1.5, y: 1.5), brush: invalidBrush)
            drain("failed layered Brush begin")
            check(!opened.strokeIsActive && !opened.labBrushStrokeIsActive && !errors.isEmpty,
                  "a failed layered Brush begin releases gesture admission without mouse-up")
            if opened.strokeIsActive { opened.endStroke(); drain("clean up failed Brush begin") }
            errors.removeAll()
            opened.beginStroke(at: .init(x: 1.5, y: 1.5), brush: state.brush(for: .paintbrush))
            drain("Brush begin after failure")
            check(opened.labBrushStrokeIsActive && errors.isEmpty,
                  "a valid layered Brush begins after a failed begin")
            opened.cancelLabBrushStroke(); drain("cancel Brush after failed begin")
            check(pixel(session, image, x: 1, y: 1) == before,
                  "the recovery stroke cancels without changing pixels")
            if session.supportsLabLayerBrushEmptySelection {
                try opened.startRecording()
                opened.beginStroke(at: .init(x: 1.5, y: 1.5), brush: invalidBrush)
                drain("failed recorded layered Brush begin")
                try opened.stopRecording()
                let failureDeadline = Date().addingTimeInterval(15)
                while opened.recorder.pendingCount != 0 && Date() < failureDeadline {
                    EngineSmokeTestHost.pumpEvents(for: 0.02)
                }
                if let row = opened.recorder.records.first, case .failure = row.resolution {
                    check(!opened.strokeIsActive && opened.recorder.pendingCount == 0 && !errors.isEmpty,
                          "failed recorded Brush begin settles without mouse-up")
                } else { check(false, "failed recorded Brush begin settles without mouse-up") }
                _ = opened.clearRecording()
                errors.removeAll()
            }
            try opened.startRecording()
            let recordedFirst = EngineSession.StrokePoint(x: 1.5, y: 1.5, pressure: 0.8, timeMilliseconds: 1)
            opened.beginStroke(at: recordedFirst, brush: state.brush(for: .paintbrush))
            if session.supportsLabLayerBrushEmptySelection {
                check(opened.strokeIsActive && errors.isEmpty, "layered Lab Brush starts while recording")
                opened.continueStroke([.init(x: 2.5, y: 1.5, pressure: 0.6, timeMilliseconds: 2)])
                opened.endStroke(); drain("recorded layered Brush")
                try opened.stopRecording()
                let deadline = Date().addingTimeInterval(15)
                while opened.recorder.pendingCount != 0 && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                check(opened.recorder.pendingCount == 0, "Recorder settles the layered Brush before the deadline")
                if let row = opened.recorder.records.first, case .success(.completeLabLayerStroke(let value)) = row.resolution {
                    check(value.trace.first.nativeSample.point == recordedFirst && value.trace.batches.count == 1,
                          "Recorder retains the layered Brush samples and accepted batch")
                } else { check(false, "Recorder retains a completed layered Brush stroke") }
                let recordedPixel = pixel(session, image, x: 1, y: 1)
                check(recordedPixel != before, "recorded layered Brush changes the selected layer")
                let recordingURL = work.appendingPathComponent("layered-lab-brush.glims-recording")
                var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
                opened.saveRecording(to: recordingURL, checkpoint: try opened.recorderSaveCheckpoint()) { saved = $0 }
                drain("save layered Brush recording")
                guard let saved else { throw NSError(domain: "LayeredLabSmoke", code: 4) }
                _ = try saved.get()
                let savedFile = try RecorderFileCodec.decode(Data(contentsOf: recordingURL))
                if let row = savedFile.records.first, case .success(.completeLabLayerStroke, .layer) = row.outcome {
                    check(true, "layered Brush recording saves a bound versioned command")
                } else { check(false, "layered Brush recording saves a bound versioned command") }
                opened.undo(); drain("recorded layered Brush Undo")
                check(pixel(session, image, x: 1, y: 1) == before, "Undo restores the pre-recording layer")
                try opened.startReplay(); drain("live-bound layered Brush replay")
                let replayDeadline = Date().addingTimeInterval(15)
                while opened.recorder.isReplaying && Date() < replayDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                if case .finished = opened.replayStatus {
                    check(pixel(session, image, x: 1, y: 1) == recordedPixel,
                          "recorded layered Brush replays on its original bound layer")
                } else { check(false, "recorded layered Brush replays on its original bound layer") }
                opened.undo(); drain("live-bound layered Brush replay Undo")
                check(pixel(session, image, x: 1, y: 1) == before, "Undo restores the replayed layered Brush")
                _ = opened.clearRecording()
                let beforeCancel = try session.undoInfo(image)
                try opened.startRecording()
                opened.beginStroke(at: recordedFirst, brush: state.brush(for: .paintbrush))
                opened.continueStroke([.init(x: 2.5, y: 1.5, pressure: 0.6, timeMilliseconds: 2)])
                opened.cancelLabBrushStroke(); drain("cancel recorded layered Brush")
                try opened.stopRecording()
                let cancelDeadline = Date().addingTimeInterval(15)
                while opened.recorder.pendingCount != 0 && Date() < cancelDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                check(opened.recorder.pendingCount == 0, "Recorder settles the cancelled Brush before the deadline")
                if let row = opened.recorder.records.first, case .failure = row.resolution {
                    let afterCancel = try session.undoInfo(image)
                    check(pixel(session, image, x: 1, y: 1) == before && afterCancel == beforeCancel,
                          "cancelled recorded layered Brush restores pixels and history")
                } else { check(false, "cancelled recorded layered Brush settles as a failure") }
                _ = opened.clearRecording()
            } else {
                check(!opened.strokeIsActive && !errors.isEmpty && opened.recorder.records.isEmpty,
                      "older engines refuse layered Brush recording without starting a gesture")
                try opened.stopRecording()
                _ = opened.clearRecording()
            }
            errors.removeAll()
            opened.select(.rectangle(CGRect(x: 1, y: 1, width: 2, height: 2)), options: .init())
            drain("brush selection")
            if session.supportsLabLayerBrushEmptySelection {
                try opened.startRecording()
                opened.beginStroke(at: recordedFirst, brush: state.brush(for: .paintbrush))
                check(!opened.strokeIsActive && !errors.isEmpty && opened.recorder.records.isEmpty,
                      "Recorder refuses a layered Brush with an uncaptured selection")
                if opened.strokeIsActive { opened.cancelLabBrushStroke(); drain("cancel refused-selection Brush") }
                try opened.stopRecording(); _ = opened.clearRecording(); errors.removeAll()
            }
            let outside = pixel(session, image, x: 0, y: 0)
            let canvas = windowController.canvas
            func mouse(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent? {
                NSEvent.mouseEvent(with: type,
                    location: canvas.convert(CGPoint(x: point.x * canvas.scale, y: point.y * canvas.scale), to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
            }
            if let down = mouse(.leftMouseDown, CGPoint(x: 1.5, y: 1.5)),
               let drag = mouse(.leftMouseDragged, CGPoint(x: 2.5, y: 1.5)),
               let up = mouse(.leftMouseUp, CGPoint(x: 2.5, y: 1.5)) {
                brushDamage.removeAll()
                canvas.mouseDown(with: down); canvas.mouseDragged(with: drag); canvas.mouseUp(with: up)
                drain("layered Lab canvas Brush gesture")
                let painted = pixel(session, image, x: 1, y: 1)
                if !errors.isEmpty || painted == before || pixel(session, image, x: 0, y: 0) != outside {
                    print("BRUSH_DIAGNOSTIC errors=\(errors) before=\(String(describing: before)) painted=\(String(describing: painted)) outside=\(String(describing: outside)) outsideAfter=\(String(describing: pixel(session, image, x: 0, y: 0)))")
                }
                check(errors.isEmpty && painted != before && pixel(session, image, x: 0, y: 0) == outside,
                      "canvas Brush paints selected pixels and preserves outside pixels")
                check(brushDamage.contains(where: { $0.contains(CGPoint(x: 1, y: 1)) }),
                      "canvas receives brush damage for the painted pixel")
                let undo = EngineUndoManager(document: opened)
                check(undo.canUndo, "layered Lab Brush offers Undo")
                undo.undo(); drain("layered Lab Brush Undo")
                check(pixel(session, image, x: 1, y: 1) == before, "Undo restores the canvas Brush stroke")
                undo.redo(); drain("layered Lab Brush Redo")
                check(pixel(session, image, x: 1, y: 1) == painted, "Redo restores the canvas Brush stroke")
                undo.undo(); drain("restore canvas Brush pixels")
                undo.undo(); drain("restore canvas Brush selection")
            } else { check(false, "layered Lab Brush events can be created") }
            if session.supportsLabLayerBrushEmptySelection,
               let down = mouse(.leftMouseDown, CGPoint(x: 1.5, y: 1.5)),
               let drag = mouse(.leftMouseDragged, CGPoint(x: 2.5, y: 1.5)),
               let up = mouse(.leftMouseUp, CGPoint(x: 2.5, y: 1.5)) {
                try opened.startRecording()
                canvas.mouseDown(with: down); canvas.mouseDragged(with: drag); canvas.mouseUp(with: up)
                drain("recorded canvas Brush")
                try opened.stopRecording()
                let flushDeadline = Date().addingTimeInterval(15)
                while opened.recorder.pendingCount != 0 && Date() < flushDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                check(opened.recorder.pendingCount == 0, "Recorder settles the canvas Brush before the deadline")
                let canvasPixel = pixel(session, image, x: 1, y: 1)
                if let row = opened.recorder.records.first, case .success(.completeLabLayerStroke) = row.resolution {
                    check(canvasPixel != before, "canvas gesture records a complete layered Lab Brush stroke")
                } else { check(false, "canvas gesture records a complete layered Lab Brush stroke") }
                opened.undo(); drain("recorded canvas Brush Undo")
                check(pixel(session, image, x: 1, y: 1) == before,
                      "recorded canvas Brush Undo restores the original pixels")
                try opened.startReplay(); drain("recorded canvas Brush replay")
                let deadline = Date().addingTimeInterval(15)
                while opened.recorder.isReplaying && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                if case .finished = opened.replayStatus {
                    check(pixel(session, image, x: 1, y: 1) == canvasPixel,
                          "recorded canvas Brush replays the same pixels")
                } else { check(false, "recorded canvas Brush replays the same pixels") }
                opened.undo(); drain("recorded canvas replay Undo")
                check(pixel(session, image, x: 1, y: 1) == before,
                      "recorded canvas replay Undo restores the original pixels")
                _ = opened.clearRecording()
            }
            if let down = mouse(.leftMouseDown, CGPoint(x: 1.5, y: 1.5)),
               let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
                    isARepeat: false, keyCode: 53) {
                let undoBefore = try? session.undoInfo(image)
                canvas.mouseDown(with: down); drain("begin canvas Brush cancellation")
                if !opened.labBrushStrokeIsActive || pixel(session, image, x: 1, y: 1) == before {
                    print("BRUSH_CANCEL_DIAGNOSTIC active=\(opened.labBrushStrokeIsActive) errors=\(errors) before=\(String(describing: before)) after=\(String(describing: pixel(session, image, x: 1, y: 1)))")
                }
                check(opened.labBrushStrokeIsActive && pixel(session, image, x: 1, y: 1) != before,
                      "cancellation fixture begins a visible Brush stroke")
                brushDamage.removeAll()
                window.makeFirstResponder(canvas); canvas.keyDown(with: escape)
                drain("cancel canvas Brush with Escape")
                let undoAfter = try? session.undoInfo(image)
                check(undoBefore != nil && undoAfter != nil && !opened.strokeIsActive && pixel(session, image, x: 1, y: 1) == before &&
                      undoBefore?.undoCount == undoAfter?.undoCount && undoBefore?.redoCount == undoAfter?.redoCount,
                      "Escape restores the canvas Brush pixels and history")
                check(brushDamage.contains(where: { $0.contains(CGPoint(x: 1, y: 1)) }),
                      "Escape invalidates the restored canvas pixels")
                let rapidUndo = try? session.undoInfo(image)
                let entered = DispatchSemaphore(value: 0)
                let release = DispatchSemaphore(value: 0)
                opened.inputQueue.async { entered.signal(); _ = release.wait(timeout: .now() + 20) }
                let held = entered.wait(timeout: .now() + 3) == .success
                canvas.mouseDown(with: down)
                let accepted = opened.labBrushStrokeIsActive
                canvas.keyDown(with: escape)
                release.signal()
                drain("cancel queued canvas Brush immediately")
                let rapidAfter = try? session.undoInfo(image)
                check(held && accepted && rapidUndo != nil && rapidAfter != nil && !opened.strokeIsActive &&
                      pixel(session, image, x: 1, y: 1) == before && rapidUndo == rapidAfter,
                      "immediate Escape cancels a queued Brush begin without a history change")
            } else { check(false, "canvas Brush cancellation events can be created") }
            if session.supportsLabLayerBrushPressure {
                let cornerBefore = pixel(session, image, x: 0, y: 0)
                let brush = state.brush(for: .paintbrush)
                func pressureStroke(_ amount: Double, brush: EngineSession.Brush) {
                    opened.beginTabletStroke(at: .init(point: .init(x: 1.5, y: 1.5, pressure: amount,
                                                                   timeMilliseconds: 1),
                                                       rotationTurns: nil, tangentialPressure: nil), brush: brush)
                    opened.endStroke(); drain("pressure Brush gesture")
                }
                pressureStroke(0.25, brush: brush)
                let lowCorner = pixel(session, image, x: 0, y: 0)
                let undo = EngineUndoManager(document: opened)
                undo.undo(); drain("low-pressure Brush Undo")
                pressureStroke(1, brush: brush)
                let highCorner = pixel(session, image, x: 0, y: 0)
                check(lowCorner == cornerBefore && highCorner != cornerBefore,
                      "tablet sample pressure changes the layered Brush footprint")
                undo.undo(); drain("full-pressure Brush Undo")
                check(pixel(session, image, x: 0, y: 0) == cornerBefore,
                      "Undo restores the pressure Brush fixture")
                state.update(.paintbrush) { $0.pressureSize = false }
                pressureStroke(0.25, brush: state.brush(for: .paintbrush))
                check(pixel(session, image, x: 0, y: 0) == highCorner,
                      "turning pressure off keeps the full-size Brush footprint")
                undo.undo(); drain("fixed-size Brush Undo")
                state.update(.paintbrush) { $0.pressureSize = true }
            }
            guard opened.selectedLayerIDs.count == 1, let brushRoot = opened.selectedLayerIDs.first else {
                throw NSError(domain: "LayeredLabSmoke", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Missing selected Lab brush root"])
            }
            let target = try session.labLayerFillTarget(image, root: brushRoot)
            let sample = EngineSession.StrokeSampleV2(point: .init(x: 1.5, y: 1.5, pressure: 0.75,
                                                                  timeMilliseconds: 1),
                                                      rotationTurns: nil, tangentialPressure: nil)
            let captureBefore = pixel(session, image, x: 1, y: 1)
            let captureHistory = try session.undoInfo(image)
            if session.supportsLabLayerBrushCapture {
                for pressure in [false, true] where !pressure || session.supportsLabLayerBrushPressure {
                    var brush = state.brush(for: .paintbrush); brush.pressureSize = pressure
                    let live = try session.beginLabLayerStrokeCapturing(image: image, target: target,
                                                                        brush: brush, first: sample)
                    let painted = pixel(session, image, x: 1, y: 1)
                    try session.cancelLabLayerStroke(live.stroke)
                    check(live.facts != nil && painted != captureBefore &&
                          pixel(session, image, x: 1, y: 1) == captureBefore,
                          "captured layered Brush returns facts and cancels cleanly")
                    if let facts = live.facts {
                        let badDigest = facts.fingerprint == String(repeating: "0", count: 64)
                            ? String(repeating: "1", count: 64) : String(repeating: "0", count: 64)
                        let changed = EngineSession.StrokeCaptureFacts(brush: facts.brush, fingerprint: badDigest)
                        var refused = false
                        do {
                            let unexpected = try session.beginLabLayerStrokeCapturing(image: image, target: target,
                                brush: brush, first: sample, expected: changed)
                            try? session.cancelLabLayerStroke(unexpected.stroke)
                        } catch { refused = true }
                        check(refused && pixel(session, image, x: 1, y: 1) == captureBefore,
                              "changed layered Brush fingerprint refuses before painting")
                        let replay = try session.beginLabLayerStrokeCapturing(image: image, target: target,
                            brush: brush, first: sample, expected: facts)
                        check(replay.facts == facts && pixel(session, image, x: 1, y: 1) == painted,
                              "verified layered Brush reproduces captured pixels")
                        try session.cancelLabLayerStroke(replay.stroke)
                    }
                }
            } else {
                let brush = state.brush(for: .paintbrush)
                let live = try session.beginLabLayerStrokeCapturing(image: image, target: target,
                                                                    brush: brush, first: sample)
                try session.cancelLabLayerStroke(live.stroke)
                check(live.facts == nil && pixel(session, image, x: 1, y: 1) == captureBefore,
                      "older engine paints live without pretending to capture facts")
                let missing = EngineSession.StrokeCaptureFacts(brush: .init(name: "Unavailable", collection: nil,
                                                                            isInternal: false),
                                                               fingerprint: String(repeating: "0", count: 64))
                var refused = false
                do {
                    let unexpected = try session.beginLabLayerStrokeCapturing(image: image, target: target,
                        brush: brush, first: sample, expected: missing)
                    try? session.cancelLabLayerStroke(unexpected.stroke)
                } catch { refused = true }
                check(refused && pixel(session, image, x: 1, y: 1) == captureBefore,
                      "older engine refuses guarded replay before painting")
            }
            check(try session.undoInfo(image) == captureHistory,
                  "captured and refused Brush fixtures preserve Undo and Redo")
            if session.supportsLabLayerBrushCapture {
                var brush = state.brush(for: .paintbrush)
                brush.pressureSize = session.supportsLabLayerBrushPressure
                let captured = try session.beginLabLayerStrokeCapturing(image: image, target: target,
                                                                        brush: brush, first: sample)
                let expectedPixel = pixel(session, image, x: 1, y: 1)
                try session.cancelLabLayerStroke(captured.stroke)
                if let facts = captured.facts, let settings = RecorderStrokeCommand.Settings(brush) {
                    let trace = RecorderTabletStrokeTrace(first: try .init(native: sample), batches: [])
                    let command = RecorderLabLayerStrokeCommand(settings: settings, trace: trace, facts: facts)
                    var missingBindingRefused = false
                    do { try SemanticImageCommand.completeLabLayerStroke(command).apply(session: session, image: image, layer: 0) }
                    catch { missingBindingRefused = true }
                    check(missingBindingRefused && pixel(session, image, x: 1, y: 1) == captureBefore,
                          "semantic layered Brush refuses a missing layer binding")
                    if session.supportsLabLayerBrushEmptySelection {
                        let wrongTarget = EngineSession.LabLayerFillTarget(root: target.root, uuid: UUID())
                        var refused = false
                        do { try command.apply(session: session, image: image, target: wrongTarget) }
                        catch let failure as EngineSession.EngineError {
                            refused = failure.status == Int32(GLIMS_STATUS_INVALID_ARGUMENT.rawValue)
                        }
                        check(refused && pixel(session, image, x: 1, y: 1) == captureBefore,
                              "recorded layered Brush refuses a changed logical identity")
                        try session.selectLab(.all, image: image)
                        var selectionRefused = false
                        do { try SemanticImageCommand.completeLabLayerStroke(command).apply(session: session, image: image, labLayerTarget: target) }
                        catch { selectionRefused = true }
                        check(selectionRefused && pixel(session, image, x: 1, y: 1) == captureBefore,
                              "semantic layered Brush refuses an uncaptured selection")
                        try session.undo(image)
                        check(try session.selectionBounds(image: image) == nil, "Undo clears the semantic Brush test selection")
                        try SemanticImageCommand.completeLabLayerStroke(command).apply(session: session, image: image, labLayerTarget: target)
                        check(pixel(session, image, x: 1, y: 1) == expectedPixel,
                              "recorded layered Brush command reproduces the captured pixel")
                        try session.undo(image)
                        check(pixel(session, image, x: 1, y: 1) == captureBefore,
                              "one Undo restores recorded layered Brush pixels")

                        // Exercise the actual file installation and document
                        // replay path, not just the semantic operation.
                        let symbol = UUID()
                        let description = RecorderTargetDescription(name: "Lab layer", kind: .pixel, ancestors: [],
                            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: Double(opened.info.width), height: Double(opened.info.height)))
                        let file = RecorderFileValue(recordingID: UUID(), name: "Lab layer stroke",
                            origin: .init(imageLabel: "Lab.xcf", initialWidth: Int(opened.info.width), initialHeight: Int(opened.info.height)),
                            symbols: [.init(id: symbol, description: description)],
                            records: [.init(ordinal: 0, outcome: .success(.completeLabLayerStroke(command), .layer(symbol)))])
                        let prepared = try RecorderFileSemanticBridge.prepare(RecorderFileCodec.decode(RecorderFileCodec.encode(file)))
                        EngineSmokeTestHost.pumpEvents(for: 0.1); drain("before Recorder installation")
                        var installed: Result<Void, Error>?
                        opened.installRecording(prepared, checkpoint: try opened.recorderInstallCheckpoint(),
                                                choices: [symbol: .layer(target.root)]) { installed = $0 }
                        drain("Lab layer recording installation")
                        guard let installed else { throw NSError(domain: "LayeredLabSmoke", code: 3) }
                        try installed.get()
                        check(true, "recorded Lab layer file installs with an explicit root binding")
                        let savedError = opened.onError
                        var replayErrors: [String] = []
                        opened.onError = { replayErrors.append($0) }
                        if let other = opened.layers.first(where: { $0.id != target.root }) {
                            opened.selectLayer(other.id); drain("change Recorder layer selection")
                            try opened.startReplay(); drain("refused Recorder replay")
                            if case .failed = opened.replayStatus {
                                check(pixel(session, image, x: 1, y: 1) == captureBefore,
                                      "document replay refuses a different selected Lab layer")
                            } else { check(false, "document replay refuses a different selected Lab layer") }
                            opened.selectLayer(target.root); drain("restore Recorder layer selection")
                        }
                        try opened.startReplay(); drain("Lab layer Recorder replay")
                        let replayDeadline = Date().addingTimeInterval(15)
                        while opened.recorder.isReplaying && Date() < replayDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
                        if case .finished = opened.replayStatus {
                            check(pixel(session, image, x: 1, y: 1) == expectedPixel,
                                  "installed Lab layer recording replays through the document")
                        } else { check(false, "installed Lab layer recording replays through the document") }
                        opened.undo(); drain("Lab layer Recorder replay Undo")
                        check(pixel(session, image, x: 1, y: 1) == captureBefore,
                              "one document Undo restores the installed recording's pixels")
                        opened.onError = savedError
                        _ = opened.clearRecording()
                    } else {
                        var unavailable = false
                        do { try command.apply(session: session, image: image, target: target) }
                        catch let failure as EngineSession.EngineError {
                            unavailable = failure.status == Int32(GLIMS_STATUS_UNSUPPORTED.rawValue)
                        }
                        check(unavailable && pixel(session, image, x: 1, y: 1) == captureBefore,
                              "older engine refuses Recorder replay without a selection guard")
                    }
                } else { check(false, "recorded layered Brush has replayable settings and facts") }
            }
        }
        func outline(in view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            return view.subviews.lazy.compactMap { outline(in: $0) }.first
        }
        if ProcessInfo.processInfo.environment["GLIMS_REQUIRE_LAB_LIVE_PROPERTIES"] == "1",
           let selected = opened.selectedLayerIDs.first,
           let other = opened.layers.first(where: { $0.id != selected }),
           let identity = opened.labLayerIdentities[other.id], let list = outline(in: palette.view) {
            let oldError = opened.onError
            var errors: [String] = []
            opened.onError = { errors.append($0) }
            defer { opened.onError = oldError; _ = opened.clearRecording() }
            func displayedRow() -> LayerRowView? {
                guard let index = (0..<list.numberOfRows).first(where: {
                    (list.item(atRow: $0) as? LayerTree.Node)?.layer.id == other.id
                }) else { return nil }
                return list.view(atColumn: 0, row: index, makeIfNecessary: true) as? LayerRowView
            }
            _ = opened.clearRecording()
            try opened.startRecording()
            EngineSmokeTestHost.pumpEvents(for: 0.1)
            check(opened.acceptsLayerProperties && !opened.acceptsLayerCreate && !opened.acceptsLayerDelete &&
                  !opened.acceptsLayerDuplicate && !opened.acceptsLayerReorder && !opened.acceptsLayerHistory,
                  "recording admits guarded Lab properties but keeps structure and history disabled")
            let priorHistory = try session.undoInfo(image)
            var staleRefused = false
            opened.changeLayer(other.id, .init(opacity: 0.25), labIdentity: UUID()) {
                if case .failure = $0 { staleRefused = true }
            }
            let afterStale = try session.undoInfo(image)
            check(staleRefused && priorHistory == afterStale && opened.recorder.records.isEmpty,
                  "a stale displayed identity refuses before changing or recording a Lab property")
            if let row = displayedRow() {
                check(row.checkbox.isEnabled && row.context.labIdentity == identity,
                      "the nonselected Lab row exposes its captured identity while recording")
                row.checkbox.performClick(nil)
                drain("recorded nonselected Lab visibility")
            } else { check(false, "nonselected Lab row exists while recording") }
            if let row = displayedRow() {
                row.nameField.stringValue = "Recorded Lab layer"
                row.finishNameEditing()
                drain("recorded Lab rename")
            } else { check(false, "Lab row remains available for recorded rename") }
            let recordedOpacity = other.opacity == 0.375 ? 0.625 : 0.375
            opened.changeLayer(other.id, .init(opacity: recordedOpacity), labIdentity: identity)
            try opened.stopRecording()
            drain("recorded Lab opacity after Stop")
            let deadline = Date().addingTimeInterval(15)
            while opened.recorder.pendingCount != 0 && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
            let records = opened.recorder.records
            check(records.count == 3 && records.allSatisfy {
                if case .success(.layerProperties) = $0.resolution { return true }
                return false
            } && opened.selectedLayerIDs == [selected],
                  "Recorder captures visibility, rename and opacity on the nonselected Lab root")
            let edited = try session.layers(image).first(where: { $0.id == other.id })
            check(edited?.isVisible == !other.isVisible && edited?.name == "Recorded Lab layer" && edited?.opacity == recordedOpacity,
                  "recorded Lab properties changed only the captured root")
            let url = work.appendingPathComponent("layered-lab-live-properties.glims-recording")
            var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
            opened.saveRecording(to: url, checkpoint: try opened.recorderSaveCheckpoint()) { saved = $0 }
            drain("save captured Lab properties")
            guard let saved else { throw NSError(domain: "LayeredLabSmoke", code: 31) }
            _ = try saved.get()
            let file = try RecorderFileCodec.decode(Data(contentsOf: url))
            check(file.records.count == 3 && file.symbols.count == 1,
                  "captured Lab properties save with one explicit layer binding")
            for _ in 0..<3 { opened.undo(); drain("recorded Lab property Undo") }
            let restored = try session.layers(image).first(where: { $0.id == other.id })
            check(restored?.name == other.name && restored?.isVisible == other.isVisible && restored?.opacity == other.opacity,
                  "Undo restores all three recorded Lab properties")
            _ = opened.clearRecording()
            let prepared = try RecorderFileSemanticBridge.prepare(file)
            var installed: Result<Void, Error>?
            guard let symbol = file.symbols.first?.id else { throw NSError(domain: "LayeredLabSmoke", code: 32) }
            opened.installRecording(prepared, checkpoint: try opened.recorderInstallCheckpoint(),
                                    choices: [symbol: .layer(other.id)]) { installed = $0 }
            drain("install captured Lab properties")
            guard let installed else { throw NSError(domain: "LayeredLabSmoke", code: 33) }
            try installed.get()
            try opened.startReplay(); drain("replay captured Lab properties")
            let replayDeadline = Date().addingTimeInterval(15)
            while opened.recorder.isReplaying && Date() < replayDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
            let replayed = try session.layers(image).first(where: { $0.id == other.id })
            if case .finished = opened.replayStatus {
                check(replayed?.name == "Recorded Lab layer" && replayed?.isVisible == !other.isVisible &&
                      replayed?.opacity == recordedOpacity && opened.selectedLayerIDs == [selected],
                      "saved Lab properties replay on their bound nonselected root")
            } else { check(false, "saved Lab properties replay on their bound nonselected root") }
            for _ in 0..<3 { opened.undo(); drain("replayed Lab property Undo") }
            _ = opened.clearRecording()
            func views<T: NSView>(_ view: NSView, _ type: T.Type) -> [T] {
                ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views($0, type) }
            }
            if let selectedLayer = opened.layers.first(where: { $0.id == selected }),
               let opacity = views(palette.view, ClassicValueSlider.self).first(where: { $0.accessibilityTitle == "Layer opacity" }),
               let field = views(opacity, NSTextField.self).first(where: { $0.isEditable }) {
                try opened.startRecording()
                EngineSmokeTestHost.pumpEvents(for: 0.1)
                let value = selectedLayer.opacity == 0.5 ? 0.75 : 0.5
                check(opacity.isEnabled, "selected Lab opacity control is enabled while recording")
                field.stringValue = value == 0.5 ? "50" : "75"
                check(field.sendAction(field.action, to: field.target), "recorded Lab opacity field action is delivered")
                try opened.stopRecording(); drain("recorded Lab opacity field")
                let edited = try session.layers(image).first(where: { $0.id == selected })
                check(edited?.opacity == value && opened.recorder.records.count == 1,
                      "the real opacity control records its selected Lab layer")
                opened.undo(); drain("recorded opacity field Undo")
                let restored = try session.layers(image).first(where: { $0.id == selected })
                check(restored?.opacity == selectedLayer.opacity, "Undo restores the recorded opacity field edit")
            } else { check(false, "selected Lab opacity field exists while recording") }
            _ = opened.clearRecording()
            if let selectedLayer = opened.layers.first(where: { $0.id == selected }),
               let selectedIdentity = opened.labLayerIdentities[selected] {
                try opened.startRecording()
                var stoppedReentrantly = false
                let token = opened.addRecorderObserver {
                    if !stoppedReentrantly && opened.recorder.isRecording {
                        stoppedReentrantly = true
                        try? opened.stopRecording()
                    }
                }
                let value = selectedLayer.opacity == 0.25 ? 0.75 : 0.25
                opened.changeLayer(selected, .init(opacity: value), labIdentity: selectedIdentity)
                opened.removeRecorderObserver(token)
                drain("Lab property after reentrant Stop")
                let reentrantDeadline = Date().addingTimeInterval(15)
                while opened.recorder.pendingCount != 0 && Date() < reentrantDeadline {
                    EngineSmokeTestHost.pumpEvents(for: 0.02)
                }
                if let record = opened.recorder.records.first, case .success(.layerProperties) = record.resolution {
                    let reentrantLayer = try session.layers(image).first(where: { $0.id == selected })
                    check(stoppedReentrantly && !opened.recorder.isRecording && opened.recorder.pendingCount == 0 &&
                          reentrantLayer?.opacity == value,
                          "reentrant Stop retains and settles the accepted Lab property edit")
                } else { check(false, "reentrant Stop retains and settles the accepted Lab property edit") }
                opened.undo(); drain("reentrant Lab property Undo")
            } else { check(false, "selected Lab identity exists for reentrant recording") }
        } else if !session.supportsLabLayerSnapshot {
            try opened.startRecording()
            EngineSmokeTestHost.pumpEvents(for: 0.1)
            check(!opened.acceptsLayerProperties, "older engines keep Lab properties disabled while recording")
            try opened.stopRecording()
            _ = opened.clearRecording()
        }
        if let other = opened.layers.first(where: { !opened.selectedLayerIDs.contains($0.id) }),
           let list = outline(in: palette.view),
           let row = (0..<list.numberOfRows).first(where: { index in
               guard let node = list.item(atRow: index) as? LayerTree.Node else { return false }
               return node.layer.id == other.id
           }), let item = list.item(atRow: row) {
            check(palette.outlineView(list, shouldSelectItem: item), "palette permits a logical layer pick")
            list.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let deadline = Date().addingTimeInterval(15)
            while opened.pendingWork > 0 && Date() < deadline {
                EngineSmokeTestHost.pumpEvents(for: 0.02)
            }
            check(opened.selectedLayerIDs == [other.id] && (try? session.selectedLayers(image)) == [other.id],
                  "logical layer selection reaches the engine")
        } else {
            check(false, "fixture has a second selectable layer")
        }
        if let list = outline(in: palette.view), let first = opened.layers.first,
           let index = (0..<list.numberOfRows).first(where: { index in
               (list.item(atRow: index) as? LayerTree.Node)?.layer.id == first.id
           }), let row = list.view(atColumn: 0, row: index, makeIfNecessary: true) as? LayerRowView {
            check(row.checkbox.isEnabled, "logical layer visibility control is enabled")
            let initiallyVisible = first.isVisible
            row.checkbox.performClick(nil)
            drain("visibility edit")
            check(opened.layers.first(where: { $0.id == first.id })?.isVisible == !initiallyVisible,
                  "visibility control changes the captured logical layer")
            let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "")
            check(windowController.window?.validateMenuItem(undo) == true, "window Undo is available after the layer edit")
            check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                  "window responder handles Undo")
            drain("visibility Undo")
            check(opened.layers.first(where: { $0.id == first.id })?.isVisible == initiallyVisible,
                  "Undo restores logical visibility")
            let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "")
            check(windowController.window?.validateMenuItem(redo) == true, "window Redo is available after Undo")
            check(windowController.window?.tryToPerform(Selector(("redo:")), with: redo) == true,
                  "window responder handles Redo")
            drain("visibility Redo")
            check(opened.layers.first(where: { $0.id == first.id })?.isVisible == !initiallyVisible,
                  "Redo reapplies logical visibility")
            check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                  "window responder handles a second Undo")
            drain("second visibility Undo")
            check(opened.layers.first(where: { $0.id == first.id })?.isVisible == initiallyVisible,
                  "second Undo restores logical visibility")
        } else {
            check(false, "logical layer visibility control exists")
        }
        if let list = outline(in: palette.view), let first = opened.layers.first,
           let index = (0..<list.numberOfRows).first(where: { index in
               (list.item(atRow: index) as? LayerTree.Node)?.layer.id == first.id
           }), let row = list.view(atColumn: 0, row: index, makeIfNecessary: true) as? LayerRowView {
            if opened.storage.allowsLayerRename {
                check(row.nameField.isEditable, "logical layer name is editable when advertised")
                let originalName = first.name
                row.nameField.stringValue = "Retouched Lab"
                row.finishNameEditing()
                drain("layer rename")
                check(opened.layers.first(where: { $0.id == first.id })?.name == "Retouched Lab",
                      "palette rename reaches the logical layer")
                let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "")
                let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "")
                check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                      "window handles rename Undo")
                drain("rename Undo")
                check(opened.layers.first(where: { $0.id == first.id })?.name == originalName,
                      "Undo restores logical layer name")
                check(windowController.window?.tryToPerform(Selector(("redo:")), with: redo) == true,
                      "window handles rename Redo")
                drain("rename Redo")
                check(opened.layers.first(where: { $0.id == first.id })?.name == "Retouched Lab",
                      "Redo restores logical layer name")
                check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                      "window restores original layer name")
                drain("restore layer name")
                check(opened.layers.first(where: { $0.id == first.id })?.name == originalName,
                      "final Undo restores the original layer name")
            } else {
                check(!row.nameField.isEditable, "logical layer name stays disabled on older engines")
                var rejected = false
                opened.changeLayer(first.id, .init(name: "Must not change")) { result in
                    if case .failure = result { rejected = true }
                }
                drain("legacy rename refusal")
                check(rejected && opened.layers.first(where: { $0.id == first.id })?.name == first.name,
                      "older engine refuses rename without changing the layer")
            }
        } else {
            check(false, "logical layer name control exists")
        }
        // This standalone palette is not registered with PaletteCenter, so
        // mirror the normal retarget/reload after the selection and undo.
        palette.reload()
        EngineSmokeTestHost.pumpEvents(for: 0.05)
        func descendants<T: NSView>(_ view: NSView, as type: T.Type) -> [T] {
            ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { descendants($0, as: type) }
        }
        let duplicateMenu = NSMenuItem(title: "Duplicate Layer", action: #selector(DocumentWindowController.duplicateLayer(_:)), keyEquivalent: "")
        let duplicateButton = descendants(palette.view, as: NSButton.self).first { $0.accessibilityLabel() == "Duplicate Layers" }
        if opened.storage.allowsLayerDuplicate {
            check(windowController.validateMenuItem(duplicateMenu), "Layer menu enables logical duplication")
            check(duplicateButton?.isEnabled == true, "palette enables logical duplication")
            let originalIDs = opened.layers.map(\.id)
            duplicateButton?.performClick(nil)
            drain("logical layer duplicate")
            let copiedIDs = Set(opened.layers.map(\.id)).subtracting(originalIDs)
            check(opened.layers.count == originalIDs.count + 1 && Set(originalIDs).isSubset(of: Set(opened.layers.map(\.id))),
                  "palette duplicates one logical layer")
            check(copiedIDs.count == 1 && Set(opened.selectedLayerIDs) == copiedIDs,
                  "the palette follows the newly duplicated logical layer")
            let undo = EngineUndoManager(document: opened)
            check(undo.canUndo, "logical duplication offers Undo")
            undo.undo()
            drain("logical duplication Undo")
            check(opened.layers.map(\.id) == originalIDs, "Undo restores the original logical layers")
            check(undo.canRedo, "logical duplication offers Redo")
            undo.redo()
            drain("logical duplication Redo")
            check(opened.layers.count == originalIDs.count + 1 && Set(originalIDs).isSubset(of: Set(opened.layers.map(\.id))) &&
                  Set(opened.selectedLayerIDs) == copiedIDs, "Redo restores and selects the logical copy")
            undo.undo()
            drain("restore original layers")
            check(opened.layers.map(\.id) == originalIDs, "final Undo restores the original layer tree")
        } else {
            check(!windowController.validateMenuItem(duplicateMenu) && duplicateButton?.isEnabled == false,
                  "older engines keep logical duplication disabled")
        }
        palette.reload()
        let newMenu = NSMenuItem(title: "New Layer", action: #selector(DocumentWindowController.newLayer(_:)), keyEquivalent: "")
        let newButton = descendants(palette.view, as: NSButton.self).first { $0.accessibilityLabel() == "New Layer" }
        let deleteMenu = NSMenuItem(title: "Delete Layer", action: #selector(DocumentWindowController.deleteLayer(_:)), keyEquivalent: "")
        let deleteButton = descendants(palette.view, as: NSButton.self).first { $0.accessibilityLabel() == "Delete Layers" }
        if opened.storage.allowsLayerCreate && opened.storage.allowsLayerDuplicate && opened.storage.allowsLayerDelete,
           let owner = windowController.window {
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 90),
                                 styleMask: [.titled], backing: .buffered, defer: false)
            sheet.isReleasedWhenClosed = false
            defer {
                if owner.attachedSheet === sheet { owner.endSheet(sheet) }
                sheet.orderOut(nil)
                sheet.close()
            }
            let before = opened.layers.map(\.id)
            owner.beginSheet(sheet)
            let deadline = Date().addingTimeInterval(3)
            while owner.attachedSheet !== sheet && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
            check(owner.attachedSheet === sheet, "document sheet is attached before palette checks")
            // These controls still reflect the state from before the sheet.
            // Their action closures must recheck admission at dispatch time.
            newButton?.performClick(nil)
            duplicateButton?.performClick(nil)
            deleteButton?.performClick(nil)
            drain("stale palette buttons")
            check(opened.layers.map(\.id) == before, "stale palette buttons cannot change layers behind a sheet")
            palette.reload()
            check(!windowController.validateMenuItem(newMenu) && !windowController.validateMenuItem(duplicateMenu) &&
                  !windowController.validateMenuItem(deleteMenu),
                  "document menu refuses layer changes while a sheet is open")
            check(newButton?.isEnabled == false && duplicateButton?.isEnabled == false && deleteButton?.isEnabled == false,
                  "palette disables layer changes while a document sheet is open")
            for command in [EngineSession.LayerCommand.new, .duplicate, .delete] {
                let item = NSMenuItem(title: "", action: NSSelectorFromString("runLayerCommand:"), keyEquivalent: "")
                item.tag = Int(command.rawValue)
                _ = palette.perform(item.action!, with: item)
            }
            drain("blocked layer commands")
            check(opened.layers.map(\.id) == before, "stale palette actions cannot change layers behind a sheet")
            owner.endSheet(sheet)
            let detachDeadline = Date().addingTimeInterval(3)
            while owner.attachedSheet === sheet && Date() < detachDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
            check(owner.attachedSheet !== sheet, "document sheet detaches before palette menu checks")
            palette.reload()
            let newItem = NSMenuItem(title: "", action: NSSelectorFromString("runLayerCommand:"), keyEquivalent: "")
            newItem.tag = Int(EngineSession.LayerCommand.new.rawValue)
            _ = palette.perform(newItem.action!, with: newItem)
            drain("palette menu after sheet")
            check(opened.layers.count == before.count + 1, "palette menu creates a layer after the sheet closes")
            EngineUndoManager(document: opened).undo()
            drain("restore palette menu fixture")
            check(opened.layers.map(\.id) == before, "Undo restores the palette menu fixture")
        }
        if opened.storage.allowsLayerCreate {
            check(windowController.validateMenuItem(newMenu), "Layer menu enables logical layer creation")
            check(newButton?.isEnabled == true, "palette enables logical layer creation")
            let originalIDs = opened.layers.map(\.id)
            newButton?.performClick(nil)
            drain("new logical layer")
            check(opened.layers.count == 3 && Set(originalIDs).isSubset(of: Set(opened.layers.map(\.id))),
                  "palette creates one logical layer")
            let undo = EngineUndoManager(document: opened)
            check(undo.canUndo, "logical layer creation offers Undo")
            undo.undo()
            drain("new layer Undo")
            check(opened.layers.map(\.id) == originalIDs, "Undo restores the original layer tree")
            check(undo.canRedo, "logical layer creation offers Redo")
            undo.redo()
            drain("new layer Redo")
            check(opened.layers.count == 3, "Redo restores the new logical layer")
            undo.undo()
            drain("restore original layers after creation")
            check(opened.layers.map(\.id) == originalIDs, "final Undo removes the new logical layer")
        } else {
            check(!windowController.validateMenuItem(newMenu) && newButton?.isEnabled == false,
                  "older engines keep logical layer creation disabled")
        }
        palette.reload()
        if opened.storage.allowsLayerDelete {
            check(windowController.validateMenuItem(deleteMenu), "Layer menu enables logical layer deletion")
            check(deleteButton?.isEnabled == true, "palette enables logical layer deletion")
            let originalIDs = opened.layers.map(\.id)
            deleteButton?.performClick(nil)
            drain("delete logical layer")
            check(opened.layers.count == 1 && Set(opened.layers.map(\.id)).isSubset(of: Set(originalIDs)),
                  "palette deletes one logical layer")
            let undo = EngineUndoManager(document: opened)
            check(undo.canUndo, "logical deletion offers Undo")
            undo.undo()
            drain("logical deletion Undo")
            check(opened.layers.map(\.id) == originalIDs, "Undo restores both logical layers")
            check(undo.canRedo, "logical deletion offers Redo")
            undo.redo()
            drain("logical deletion Redo")
            check(opened.layers.count == 1, "Redo removes the same logical layer")
            undo.undo()
            drain("restore original layers after deletion")
            check(opened.layers.map(\.id) == originalIDs, "final Undo restores both logical layers")
        } else {
            check(!windowController.validateMenuItem(deleteMenu) && deleteButton?.isEnabled == false,
                  "older engines keep logical deletion disabled")
        }
        palette.reload()
        let backward = NSMenuItem(title: "Send Backward", action: #selector(DocumentWindowController.sendLayerBackward(_:)), keyEquivalent: "")
        let forward = NSMenuItem(title: "Bring Forward", action: #selector(DocumentWindowController.bringLayerForward(_:)), keyEquivalent: "")
        if opened.storage.allowsLayerReorder, let selected = opened.selectedLayerIDs.first {
            let originalIDs = opened.layers.map(\.id)
            let movingDown = originalIDs.first == selected
            let item = movingDown ? backward : forward
            check(windowController.validateMenuItem(item), "Layer menu enables logical reorder")
            if movingDown { windowController.sendLayerBackward(item) }
            else { windowController.bringLayerForward(item) }
            drain("logical reorder")
            check(opened.layers.map(\.id) == Array(originalIDs.reversed()) && opened.selectedLayerIDs == [selected],
                  "reorder changes logical order while retaining selection")
            let undo = EngineUndoManager(document: opened)
            check(undo.canUndo, "logical reorder offers Undo")
            undo.undo()
            drain("logical reorder Undo")
            check(opened.layers.map(\.id) == originalIDs, "Undo restores logical layer order")
            check(undo.canRedo, "logical reorder offers Redo")
            undo.redo()
            drain("logical reorder Redo")
            check(opened.layers.map(\.id) == Array(originalIDs.reversed()), "Redo restores logical layer order")
            undo.undo()
            drain("restore original layer order")
            check(opened.layers.map(\.id) == originalIDs, "final Undo restores original layer order")
        } else {
            check(!windowController.validateMenuItem(backward) && !windowController.validateMenuItem(forward),
                  "older engines keep logical reordering disabled")
        }
        palette.reload()
        var editedOpacity = -1.0 // No valid layer opacity can satisfy the saved-copy check until an edit runs.
        if let target = opened.activeLayer,
           let opacity = descendants(palette.view, as: ClassicValueSlider.self).first(where: { $0.accessibilityTitle == "Layer opacity" }),
           let field = descendants(opacity, as: NSTextField.self).first(where: { $0.isEditable }),
           let originalOpacity = opened.layers.first(where: { $0.id == target })?.opacity {
            check(opacity.isEnabled, "logical layer opacity control is enabled")
            editedOpacity = abs(originalOpacity - 0.5) < 0.0001 ? 0.75 : 0.5
            field.stringValue = editedOpacity == 0.5 ? "50" : "75"
            check(field.sendAction(field.action, to: field.target), "opacity field action is delivered")
            drain("opacity edit")
            check(abs((opened.layers.first(where: { $0.id == target })?.opacity ?? -1) - editedOpacity) < 0.0001,
                  "opacity field changes the captured logical layer")
            let manager = EngineUndoManager(document: opened)
            let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "")
            check(manager.canUndo, "document Undo is available after the opacity edit")
            check(windowController.window?.validateMenuItem(undo) == true, "window Undo is available after the opacity edit")
            check(windowController.window?.tryToPerform(Selector(("undo:")), with: undo) == true,
                  "window responder handles opacity Undo")
            drain("opacity Undo")
            check(abs((opened.layers.first(where: { $0.id == target })?.opacity ?? -1) - originalOpacity) < 0.0001,
                  "Undo restores logical layer opacity")
            let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "")
            check(manager.canRedo, "document Redo is available after opacity Undo")
            check(windowController.window?.validateMenuItem(redo) == true, "window Redo is available after opacity Undo")
            check(windowController.window?.tryToPerform(Selector(("redo:")), with: redo) == true,
                  "window responder handles opacity Redo")
            drain("opacity Redo")
            check(abs((opened.layers.first(where: { $0.id == target })?.opacity ?? -1) - editedOpacity) < 0.0001,
                  "Redo reapplies logical layer opacity")
        } else {
            check(false, "logical layer opacity field exists")
        }
        let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 1, height: 1))
        check(rendered.width == 1 && rendered.height == 1, "layered Lab canvas renders")
        let copy = work.appendingPathComponent("layered-copy.xcf")
        var copyFinished = false
        var copyError: Error?
        opened.saveCopy(to: copy) { error in copyError = error; copyFinished = true }
        let saveDeadline = Date().addingTimeInterval(30)
        while !copyFinished && Date() < saveDeadline { EngineSmokeTestHost.pumpEvents(for: 0.02) }
        guard copyFinished, copyError == nil else {
            throw copyError ?? NSError(domain: "LayeredLabSmoke", code: 2,
                                       userInfo: [NSLocalizedDescriptionKey: "Save copy did not finish"])
        }
        check(true, "document saves an XCF copy")
        let reopened = try session.openImage(path: copy.path)
        defer { try? session.closeImage(reopened) }
        check(try session.imageStorage(reopened).layout == .layeredLab,
              "saved XCF copy reopens as layered Lab")
        check(try session.layers(reopened).contains(where: { abs($0.opacity - editedOpacity) < 0.0001 }),
              "saved XCF copy retains the edited opacity")
    }
}
