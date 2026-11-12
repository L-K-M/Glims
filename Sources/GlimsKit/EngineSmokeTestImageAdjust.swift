import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseImageAdjust(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(12)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        var bytes = Data()
        for _ in 0..<8 {
            for x in 0..<9 {
                let gray: UInt8 = [32, 128, 224][x / 3]
                bytes.append(contentsOf: [gray, gray, gray, x.isMultiple(of: 2) ? 128 : 255])
            }
        }
        let image = try session.newImage(pixels: ClipboardImage(width: 9, height: 8, pixels: bytes, origin: .zero))
        let otherImage = try session.newImage(width: 8, height: 8)
        let document = try ImageDocument(session: session, image: image, name: "Adjust A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Adjust B")
        documents.items += [document, other]
        let controller = DocumentWindowController(document: document), front = DocumentWindowController(document: other)
        controller.showWindow(nil); front.showWindow(nil)
        defer {
            (controller.previewPanel as? NativeFilterPanel)?.cancel()
            for c in [controller, front] {
                c.window?.orderOut(nil)
                var stopped = false; c.canvas.stopRendering { stopped = true }; wait { stopped }
            }
            for doc in [document, other] {
                var closed = false; doc.closeImageWhenDrained { closed = true }; wait { closed }
            }
            documents.items.removeAll { $0 === document || $0 === other }
        }
        func settle() {
            document.inputQueue.sync {}; wait { document.pendingWork == 0 }; spin(0.03)
        }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        guard let menu = NSApp.mainMenu else { return check(false, "the application menu exists") }
        NativeFilterMenus.install(operations, in: menu)
        guard let adjust = menu.item(withTitle: "Image")?.submenu?.item(withTitle: MainMenu.adjustTitle)?.submenu else {
            return check(false, "Image Adjust exists in the real application menu")
        }
        let original = try session.copyPixels(image, merged: true).pixels
        let otherPixels = try session.copyPixels(otherImage, merged: true).pixels
        let specs = [("Threshold…", "gimp:threshold"), ("Posterize…", "glims:posterize"), ("Invert Perceptual…", "gegl:invert-gamma"),
                     ("Invert Linear…", "gegl:invert-linear")]
        for (title, name) in specs {
            guard let item = adjust.item(withTitle: title), let command = item.representedObject as? NativeFilterCommand,
                  let action = item.action else { check(false, "\(title) is available from the loaded catalog"); continue }
            check(command.operation.name == name && controller.validateMenuItem(item), "\(title) routes a supported native operation")
            let history = try session.undoInfo(image).undoCount
            NSApp.sendAction(action, to: controller, from: item)
            wait { controller.previewPanel != nil && document.pendingWork == 0 }
            guard let panel = controller.previewPanel as? NativeFilterPanel else {
                check(false, "\(title) opens its native form"); continue
            }
            check(panel.operation.name == name && document.filterPreviewIsOpen, "\(title) opens the captured document preview")
            front.window?.makeKeyAndOrderFront(nil)
            if name == "gimp:threshold" {
                panel.setProperty("low", .number(0.25)); panel.setProperty("high", .number(0.75)); settle()
            }
            let preview = try session.copyPixels(image, merged: true).pixels
            var colorsMatch = preview.count == bytes.count, alphaMatches = colorsMatch
            for i in stride(from: 0, to: min(preview.count, bytes.count), by: 4) {
                let input = Double(bytes[i]) / 255
                let expected: Double
                if name == "gimp:threshold" { expected = input >= 0.25 && input <= 0.75 ? 1 : 0 }
                else if name == "glims:posterize" { expected = (input * 2).rounded() / 2 }
                else if name == "gegl:invert-gamma" { expected = 1 - input }
                else {
                    let linear = input <= 0.04045 ? input / 12.92 : pow((input + 0.055) / 1.055, 2.4)
                    let inverted = 1 - linear
                    expected = inverted <= 0.0031308 ? inverted * 12.92 : 1.055 * pow(inverted, 1 / 2.4) - 0.055
                }
                let value = Int((expected * 255).rounded())
                for channel in 0..<3 { colorsMatch = colorsMatch && abs(Int(preview[i + channel]) - value) <= 2 }
                alphaMatches = alphaMatches && preview[i + 3] == bytes[i + 3]
            }
            check(colorsMatch && alphaMatches, "\(title) matches its independent grayscale/alpha oracle")
            check(try session.copyPixels(otherImage, merged: true).pixels == otherPixels,
                  "\(title) leaves the front second document unchanged")
            panel.cancel(); settle()
            check(try session.copyPixels(image, merged: true).pixels == original && session.undoInfo(image).undoCount == history,
                  "\(title) Cancel restores pixels without history")

            NSApp.sendAction(action, to: controller, from: item)
            wait { controller.previewPanel != nil && document.pendingWork == 0 }
            guard let accepted = controller.previewPanel as? NativeFilterPanel else {
                check(false, "\(title) can reopen"); continue
            }
            if name == "gimp:threshold" {
                accepted.setProperty("low", .number(0.25)); accepted.setProperty("high", .number(0.75)); settle()
            }
            accepted.commit(); wait { controller.previewPanel == nil && document.pendingWork == 0 }; settle()
            let applied = try session.copyPixels(image, merged: true).pixels
            let appliedHistory = try session.undoInfo(image).undoCount
            check(applied == preview && appliedHistory == history + 1,
                  "\(title) Apply retains its preview as one Undo step")
            let path = work.appendingPathComponent("adjust-\(name.replacingOccurrences(of: ":", with: "-" )).xcf")
            try session.save(image, to: path.path)
            let reopened = try session.openImage(path: path.path)
            check(try session.copyPixels(reopened, merged: true).pixels == applied,
                  "\(title) survives XCF reopening")
            try session.closeImage(reopened)
            try session.undo(image); try document.reload()
            check(try session.copyPixels(image, merged: true).pixels == original, "\(title) Undo restores original pixels")
            try session.redo(image); try document.reload()
            check(try session.copyPixels(image, merged: true).pixels == applied, "\(title) Redo restores applied pixels")
            try session.undo(image); try document.reload()
        }
    }
}
