import AppKit

@MainActor
extension EngineSmokeTest {
    /// Drives Image > Adjust's one-click commands through the real menu
    /// validation and the document commands, including a menu rebuild.
    static func exerciseEverydayAdjustments(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(12)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !document.recorder.isReplaying && !EngineActivity.shared.isBusy }
            spin(0.03)
        }
        var bytes = Data()
        for y in 0..<16 {
            for x in 0..<16 {
                if x < 8 { bytes.append(contentsOf: [200, 100, 40, 255]) }
                else { bytes.append(contentsOf: [60, 140, 220, 255]) }
            }
        }
        let image = try session.newImage(pixels: ClipboardImage(width: 16, height: 16, pixels: bytes, origin: .zero))
        let otherImage = try session.newImage(width: 8, height: 8)
        let document = try ImageDocument(session: session, image: image, name: "Everyday A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Everyday B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        controller.showWindow(nil); front.showWindow(nil)
        defer {
            for c in [controller, front] {
                c.window?.orderOut(nil)
                var stopped = false; c.canvas.stopRendering { stopped = true }; wait { stopped }
            }
            for doc in [document, other] {
                var closed = false; doc.closeImageWhenDrained { closed = true }; wait { closed }
            }
            documents.items.removeAll { $0 === document || $0 === other }
        }

        let operations = try session.filterOperations()
        let procedures = try session.procedures()
        NativeFilterCatalog.shared.install(operations)
        let menu = MainMenu.make()
        NSApp.mainMenu = menu
        func installMenus() {
            NativeFilterMenus.install(operations, in: menu)
            PlugInMenus.install(procedures, in: menu)
        }
        installMenus()
        guard let adjust = menu.item(withTitle: "Image")?.submenu?.item(withTitle: MainMenu.adjustTitle)?.submenu,
              let layerMenu = menu.item(withTitle: "Layer")?.submenu else {
            return check(false, "Image Adjust and Layer exist in the real application menu")
        }

        let expected: [(String, EngineSession.Adjustment, String, Selector)] = [
            ("Auto Levels", .autoLevels, "l", #selector(DocumentWindowController.autoLevels(_:))),
            ("Desaturate", .desaturate, "u", #selector(DocumentWindowController.desaturate(_:))),
            ("Equalize", .equalize, "", #selector(DocumentWindowController.equalize(_:))),
        ]
        installMenus()
        for (title, adjustment, key, selector) in expected {
            let matches = adjust.items.filter { $0.title == title }
            guard matches.count == 1, let item = matches.first, let action = item.action else {
                check(false, "\(title) appears exactly once after a menu rebuild")
                continue
            }
            check(item.tag == Int(adjustment.rawValue) && item.keyEquivalent == key && action == selector,
                  "\(title) keeps its adjustment tag and shortcut across a rebuild")
            check(controller.validateMenuItem(item), "\(title) validates on an RGB layer")
        }
        let transparency: [(String, EngineSession.Adjustment, Selector)] = [
            ("Add Transparency", .addAlpha, #selector(DocumentWindowController.addTransparency(_:))),
            ("Remove Transparency", .removeAlpha, #selector(DocumentWindowController.removeTransparency(_:))),
        ]
        for (title, adjustment, selector) in transparency {
            let matches = layerMenu.items.filter { $0.title == title }
            guard matches.count == 1, let item = matches.first, let action = item.action else {
                check(false, "\(title) appears exactly once in Layer")
                continue
            }
            check(item.tag == Int(adjustment.rawValue) && action == selector,
                  "\(title) keeps its adjustment tag")
            check(controller.validateMenuItem(item), "\(title) validates on an RGB layer")
        }

        // Desaturate through the document command: exact lightness, one undo.
        guard let layer = document.layers.last?.id else { return check(false, "the fixture has a layer") }
        document.selectLayer(layer)
        settle(document)
        let undoBefore = (try? session.undoInfo(image).undoCount) ?? -1
        var outcome: Result<Void, Error>?
        document.applyAdjustment(.desaturate, background: .black) { outcome = $0 }
        wait { outcome != nil }
        settle(document)
        if case .failure(let error)? = outcome { check(false, "Desaturate runs (\(error))") }
        let pixels = try session.copyPixels(image, merged: true).pixels
        func pixel(_ offset: Int) -> [UInt8] { [pixels[offset], pixels[offset + 1], pixels[offset + 2], pixels[offset + 3]] }
        check((try? session.undoInfo(image).undoCount) == undoBefore + 1
              && pixel(0) == [120, 120, 120, 255] && pixel((15 * 16 + 15) * 4) == [140, 140, 140, 255],
              "Desaturate maps HSL lightness exactly as one undo step (\(pixel(0)), \(pixel((15 * 16 + 15) * 4)))")
        document.undo()
        settle(document)
        check((try? session.undoInfo(image).undoCount) == undoBefore, "Undo removes Desaturate")

        // Auto Levels and Equalize through their menu items.
        var levels = Data()
        for y in 0..<8 {
            for x in 0..<8 {
                let v: UInt8 = (x + y).isMultiple(of: 2) ? 50 : 200
                levels.append(contentsOf: [v, v, v, 255])
            }
        }
        let levelsImage = try session.newImage(pixels: ClipboardImage(width: 8, height: 8, pixels: levels, origin: .zero))
        let levelsDoc = try ImageDocument(session: session, image: levelsImage, name: "Everyday Levels")
        documents.items.append(levelsDoc)
        defer {
            var closed = false; levelsDoc.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === levelsDoc }
        }
        levelsDoc.selectLayer(levelsDoc.layers.last?.id ?? 0)
        settle(levelsDoc)
        let levelsUndo = (try? session.undoInfo(levelsImage).undoCount) ?? -1
        var levelsOutcome: Result<Void, Error>?
        levelsDoc.applyAdjustment(.autoLevels, background: .black) { levelsOutcome = $0 }
        wait { levelsOutcome != nil }
        settle(levelsDoc)
        let levelsPixels = try session.copyPixels(levelsImage, merged: true).pixels
        check((try? session.undoInfo(levelsImage).undoCount) == levelsUndo + 1
              // GIMP's stretch leaves the dark end a few levels above 0
              // (3 on every engine set), as the conformance test allows.
              && levelsPixels[0] <= 5 && levelsPixels[4] == 255,
              "Auto Levels stretches the range as one undo step (\(levelsPixels[0]), \(levelsPixels[4]))")

        var equalized = Data()
        for y in 0..<4 {
            for x in 0..<4 {
                let v = UInt8((x + y * 4) * 255 / 15)
                equalized.append(contentsOf: [v, v, v, 255])
            }
        }
        let equalizeImage = try session.newImage(pixels: ClipboardImage(width: 4, height: 4, pixels: equalized, origin: .zero))
        let equalizeDoc = try ImageDocument(session: session, image: equalizeImage, name: "Everyday Equalize")
        documents.items.append(equalizeDoc)
        defer {
            var closed = false; equalizeDoc.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === equalizeDoc }
        }
        equalizeDoc.selectLayer(equalizeDoc.layers.last?.id ?? 0)
        settle(equalizeDoc)
        var equalizeOutcome: Result<Void, Error>?
        equalizeDoc.applyAdjustment(.equalize, background: .black) { equalizeOutcome = $0 }
        wait { equalizeOutcome != nil }
        settle(equalizeDoc)
        let equalizePixels = try session.copyPixels(equalizeImage, merged: true).pixels
        // Sixteen equal levels map to k/16 of the range; GIMP 3.0 applies
        // that in linear light, where sRGB of 1/16 is 71 and of 2/16 is 99.
        let linearEqualize = session.version.hasPrefix("3.0.")
        let equalizeFirst: UInt8 = linearEqualize ? 71 : 16, equalizeSecond: UInt8 = linearEqualize ? 99 : 32
        check(equalizePixels[0] == equalizeFirst && equalizePixels[4] == equalizeSecond
                && equalizePixels[15 * 4] == 255,
              "Equalize flattens the histogram (\(equalizePixels[0]), \(equalizePixels[4]), \(equalizePixels[15 * 4]))")

        // Add then Remove Transparency: the format state and the composite.
        let plain = try session.copyPixels(otherImage, merged: true).pixels
        var addOutcome: Result<Void, Error>?
        other.applyAdjustment(.addAlpha, background: .black) { addOutcome = $0 }
        wait { addOutcome != nil }
        settle(other)
        check(try session.copyPixels(otherImage, merged: true).pixels == plain,
              "Add Transparency keeps the pixels")
        check(other.adjustmentRefusal(.removeAlpha) == nil,
              "the layer now has transparency to remove")
        var removeOutcome: Result<Void, Error>?
        other.applyAdjustment(.removeAlpha, background: .black) { removeOutcome = $0 }
        wait { removeOutcome != nil }
        settle(other)
        check(try session.copyPixels(otherImage, merged: true).pixels == plain,
              "Remove Transparency restores the same composite on black")

        // A mask target refuses the layer-only commands in menu
        // validation, but Equalize still edits the mask itself, exactly as
        // upstream drawable_equalize_cmd_callback does.
        let mask = try session.addLayerMask(layer, image: image, source: .white, edit: true)
        try document.reload()
        settle(document)
        check(mask > 0 && document.isMaskTargetActive, "the mask becomes the paint target")
        for (title, adjustment, _, _) in expected where adjustment != .equalize {
            guard let item = adjust.item(withTitle: title) else { continue }
            check(!controller.validateMenuItem(item) && document.adjustmentRefusal(adjustment) != nil,
                  "\(title) is disabled on a mask")
        }
        if let equalizeItem = adjust.item(withTitle: "Equalize") {
            check(controller.validateMenuItem(equalizeItem) && document.adjustmentRefusal(.equalize) == nil,
                  "Equalize stays enabled on a mask")
        }
        try session.setLayerMask(layer, image: image, flags: .editing, values: [])
        try document.reload()
        settle(document)

        // A group refuses in menu validation.
        let group = try session.createGroup(image: image, index: 0, name: "Everyday group")
        try session.selectLayer(group, image: image)
        try document.reload()
        settle(document)
        check(document.activeLayer == group, "the group becomes the active layer")
        for (title, adjustment, _, _) in expected {
            guard let item = adjust.item(withTitle: title) else { continue }
            check(!controller.validateMenuItem(item) && document.adjustmentRefusal(adjustment) != nil,
                  "\(title) is disabled on a group")
        }
        try session.selectLayer(layer, image: image)
        try document.reload()
        settle(document)

        // Grayscale refuses Auto Levels and Desaturate but equalizes.
        let grayImage = try session.newImage(width: 8, height: 8)
        try session.convertMode(grayImage, to: .grayscale)
        let grayDoc = try ImageDocument(session: session, image: grayImage, name: "Everyday Gray")
        documents.items.append(grayDoc)
        defer {
            var closed = false; grayDoc.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === grayDoc }
        }
        grayDoc.selectLayer(grayDoc.layers.last?.id ?? 0)
        settle(grayDoc)
        check(grayDoc.adjustmentRefusal(.autoLevels) != nil && grayDoc.adjustmentRefusal(.desaturate) != nil
              && grayDoc.adjustmentRefusal(.equalize) == nil,
              "grayscale refuses Auto Levels and Desaturate but equalizes")
        var grayOutcome: Result<Void, Error>?
        grayDoc.applyAdjustment(.desaturate, background: .black) { grayOutcome = $0 }
        wait { grayOutcome != nil }
        if case .failure = grayOutcome { check(true, "Desaturate refuses a grayscale document") }
        else { check(false, "Desaturate refuses a grayscale document") }

        // Recorder captures the adjustment and its background.
        try document.startRecording()
        var recorded: Result<Void, Error>?
        document.applyAdjustment(.desaturate, background: .black) { recorded = $0 }
        try document.stopRecording()
        wait { recorded != nil }
        settle(document)
        guard document.recorder.records.count == 1,
              case .success(.adjustment(let adjustment, let background))? = document.recorder.records.first?.resolution,
              adjustment == .desaturate, background.red == 0, background.green == 0, background.blue == 0 else {
            return check(false, "the adjustment records its kind and background")
        }
        check(true, "the adjustment records its kind and background")

        // Saving must encode the adjustment with its captured context.
        // A `.none` binding would make the row unencodable and unreplayable.
        let recordingURL = work.appendingPathComponent("everyday-adjustment.glims-recording")
        var saved: Result<ImageDocument.RecorderSaveOutcome, Error>?
        document.saveRecording(to: recordingURL, checkpoint: try document.recorderSaveCheckpoint()) { saved = $0 }
        wait { saved != nil }
        settle(document)
        guard let savedResult = saved, (try? savedResult.get()) != nil,
              let savedData = try? Data(contentsOf: recordingURL),
              let savedFile = try? RecorderFileCodec.decode(savedData),
              savedFile.records.count == 1,
              case .success(.adjustment(let savedAdjustment, _), .context)? = savedFile.records.first?.outcome,
              savedAdjustment == .desaturate else {
            return check(false, "the recorded adjustment saves with its captured context")
        }
        check(true, "the recorded adjustment saves with its captured context")
    }
}
