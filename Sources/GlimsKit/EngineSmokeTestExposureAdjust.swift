import AppKit

@MainActor
extension EngineSmokeTest {
    /// GLIMS_SMOKE_CASE=exposure-adjust. The missing Adjust placement is one
    /// explicit RED; its existing installed Filter > Color action independently
    /// exercises the generic form while that placement is still absent.
    static func exerciseExposureAdjust(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        var count = 0
        func expect(_ condition: Bool, _ message: String) {
            count += 1
            check(condition, "exposure adjust: \(message)")
        }
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.005) }
            return condition()
        }
        func require(_ condition: Bool, _ message: String) throws {
            if !condition { throw NSError(domain: "ExposureAdjustFixture", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        var raw = Data()
        let colors: [[UInt8]] = [[40, 70, 110], [90, 45, 130], [160, 80, 30], [30, 150, 100]]
        let alphas: [UInt8] = [0, 96, 160, 255]
        for y in 0..<9 {
            for x in 0..<12 { raw.append(contentsOf: colors[(x + 3 * y) % 4] + [alphas[(x + y) % 4]]) }
        }
        let fixture = ClipboardImage(width: 12, height: 9, pixels: raw, origin: .zero)
        let image = try session.newImage(pixels: fixture)
        let otherImage = try session.newImage(pixels: fixture)
        let document = try ImageDocument(session: session, image: image, name: "Exposure A")
        let other = try ImageDocument(session: session, image: otherImage, name: "Exposure B")
        documents.items += [document, other]
        let owner = DocumentWindowController(document: document)
        let front = DocumentWindowController(document: other)
        owner.showWindow(nil)
        front.showWindow(nil)
        var errors: [String] = []
        let originalError = document.onError
        document.onError = { message in originalError?(message); errors.append(message) }
        defer {
            (owner.previewPanel as? NativeFilterPanel)?.cancel()
            for controller in [owner, front] {
                controller.window?.orderOut(nil)
                var stopped = false
                controller.canvas.stopRendering { stopped = true }
                expect(wait { stopped }, "teardown drains \(controller === owner ? "A" : "B") canvas")
            }
            for item in [document, other] where !item.isClosing {
                var closed = false
                item.closeImageWhenDrained { closed = true }
                expect(wait { closed }, "teardown closes \(item.name)")
            }
            document.onError = originalError
            documents.items.removeAll { $0 === document || $0 === other }
            print("     exposure-adjust checks: \(count)")
        }
        func settle() throws {
            try require(wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Exposure work failed to drain")
            spin(0.03)
        }
        func descendants(_ view: NSView?) -> [NSView] {
            guard let view else { return [] }
            return [view] + view.subviews.flatMap { descendants($0) }
        }
        func button(_ panel: NativeFilterPanel, _ title: String) -> NSButton? {
            descendants(panel.window?.contentView).compactMap { $0 as? NSButton }.first { $0.title == title }
        }
        func menuItems(_ menu: NSMenu) -> [NSMenuItem] {
            menu.items.flatMap { [$0] + ($0.submenu.map(menuItems) ?? []) }
        }
        let operations = try session.filterOperations()
        NativeFilterCatalog.shared.install(operations)
        guard let operation = operations.first(where: { $0.name == "gegl:exposure" }),
              let menu = NSApp.mainMenu, let layer = document.activeLayer else {
            return expect(false, "loaded Exposure operation, main menu and captured layer exist")
        }
        expect(operation.support == .supported, "loaded Exposure needs only the existing generic parameter editor")
        NativeFilterMenus.install(operations, in: menu)
        guard let adjust = menu.item(withTitle: "Image")?.submenu?.item(withTitle: MainMenu.adjustTitle)?.submenu else {
            return expect(false, "the actual Image Adjust submenu exists")
        }
        let adjustItem = adjust.items.first { ($0.representedObject as? NativeFilterCommand)?.operation.name == operation.name }
        expect(adjustItem?.title == "Exposure…", "Image > Adjust installs the supported Exposure action (placement RED)")
        let colorMenu = menu.item(withTitle: "Filter")?.submenu?.item(withTitle: "Color")?.submenu
        let colorItem = colorMenu.flatMap { submenu in
            menuItems(submenu).first { ($0.representedObject as? NativeFilterCommand)?.operation.name == operation.name }
        }
        expect(colorItem != nil, "the existing installed Filter Color Exposure action remains available")
        guard let item = adjustItem ?? colorItem, let action = item.action else {
            return expect(false, "an installed Exposure action drives the real form")
        }
        let properties = try session.filterOperationProperties(operation.name)
        guard let exposureProperty = properties.first(where: { $0.name == "exposure" }),
              let blackProperty = properties.first(where: { $0.name == "black-level" }) else {
            return expect(false, "Exposure and black-level numeric properties exist")
        }
        expect(exposureProperty.kind == .number && blackProperty.kind == .number && owner.validateMenuItem(item),
               "idle menu admission uses the two loaded numeric property descriptors")
        func row(_ panel: NativeFilterPanel, _ property: EngineSession.FilterProperty) -> FilterNumberRow? {
            descendants(panel.window?.contentView).compactMap { $0 as? FilterNumberRow }.first {
                let label = $0.field.accessibilityLabel() ?? ""
                return label == property.label || label.hasPrefix(property.label + ", ")
            }
        }
        func enter(_ panel: NativeFilterPanel, _ property: EngineSession.FilterProperty, _ value: Double) throws {
            guard let control = row(panel, property), let action = control.field.action else {
                throw NSError(domain: "ExposureAdjustFixture", code: 2)
            }
            control.field.stringValue = control.formatter.string(from: NSNumber(value: value)) ?? String(value)
            try require(NSApp.sendAction(action, to: control.field.target, from: control.field), "numeric field action was not handled")
            try settle()
        }
        func open() throws -> NativeFilterPanel {
            front.window?.makeKeyAndOrderFront(nil)
            try require(NSApp.sendAction(action, to: owner, from: item), "installed Exposure action was not handled")
            try require(wait { owner.previewPanel != nil && document.pendingWork == 0 }, "Exposure form did not open")
            guard let panel = owner.previewPanel as? NativeFilterPanel else {
                throw NSError(domain: "ExposureAdjustFixture", code: 3)
            }
            return panel
        }
        func click(_ panel: NativeFilterPanel, _ title: String) throws {
            guard let control = button(panel, title) else { throw NSError(domain: "ExposureAdjustFixture", code: 4) }
            control.performClick(nil)
            try require(wait { owner.previewPanel == nil && document.pendingWork == 0 }, "Exposure \(title) did not finish")
            try settle()
        }
        func mathMatches(_ output: Data, stops: Double) -> Bool {
            guard output.count == raw.count else { return false }
            for index in stride(from: 0, to: raw.count, by: 4) {
                guard output[index + 3] == raw[index + 3] else { return false }
                if raw[index + 3] == 0 { continue }
                for channel in 0..<3 {
                    let encoded = Double(raw[index + channel]) / 255
                    let linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
                    let exposed = min(1, max(0, linear * pow(2, stops)))
                    let result = exposed <= 0.0031308 ? 12.92 * exposed : 1.055 * pow(exposed, 1 / 2.4) - 0.055
                    if abs(Int(output[index + channel]) - Int((result * 255).rounded())) > 3 { return false }
                }
            }
            return true
        }
        func directReference(_ stops: Double) throws -> Data {
            let reference = try session.newImage(pixels: fixture)
            defer { try? session.closeImage(reference) }
            let target = try session.layers(reference)[0].id
            let filter = try session.beginFilter(image: reference, drawable: target, operation: "gegl:exposure")
            try session.setFilterProperty(filter, "black-level", to: .number(0))
            try session.setFilterProperty(filter, "exposure", to: .number(stops))
            try session.commitFilter(filter)
            return try session.copyPixels(reference, merged: true).pixels
        }
        // Authentic GEGL common/exposure.c uses linear RGBA float, gain =
        // 1/max(2^-stops-black, 1e-6), output=(input-black)*gain; alpha is copied.
        // black=0 therefore doubles linear RGB at +1 stop. This math above and
        // the separate raw native caller never use a production preview helper.
        let original = try session.copyPixels(image, merged: true).pixels
        let otherPixels = try session.copyPixels(otherImage, merged: true).pixels
        let otherUndo = try session.undoInfo(otherImage)
        let baseline = try session.undoInfo(image).undoCount
        let panel = try open()
        expect(panel.operation.name == operation.name && panel.imageDocument === document && document.filterPreviewIsOpen,
               "installed action opens A's existing modeless generic preview")
        expect(row(panel, exposureProperty) != nil && row(panel, blackProperty) != nil,
               "actual generic numeric controls cover Exposure and Black level")
        front.window?.makeKeyAndOrderFront(nil)
        try enter(panel, blackProperty, 0)
        try enter(panel, exposureProperty, 1)
        let preview = try session.copyPixels(image, merged: true).pixels
        expect(mathMatches(preview, stops: 1), "+1-stop preview matches independent linear-RGB/unchanged-alpha math")
        expect(try preview == directReference(1), "preview pixels match a separate direct native Exposure call")
        expect(try session.copyPixels(otherImage, merged: true).pixels == otherPixels && session.undoInfo(otherImage) == otherUndo,
               "front B retains its pixels and history while A's form changes")
        let firstFilter = panel.filter
        let beforeSecondAction = try session.undoInfo(image)
        let disabled = !owner.validateMenuItem(item)
        _ = NSApp.sendAction(action, to: owner, from: item)
        try settle()
        expect(try disabled && owner.previewPanel === panel && panel.filter == firstFilter
                && session.undoInfo(image) == beforeSecondAction,
               "active-preview admission refuses a second Exposure without replacing its session")
        try click(panel, "Cancel")
        expect(try session.copyPixels(image, merged: true).pixels == original && session.undoInfo(image).undoCount == baseline
                && session.effects(on: layer, image: image).isEmpty, "real Cancel restores pixels, effects and original history")

        let accepted = try open()
        try enter(accepted, blackProperty, 0)
        try enter(accepted, exposureProperty, 1)
        try click(accepted, "Apply")
        let applied = try session.copyPixels(image, merged: true).pixels
        let effects = try session.effects(on: layer, image: image)
        expect(try applied == preview && session.undoInfo(image).undoCount == baseline + 1
                && effects.count == 1 && effects[0].operation == operation.name, "real Apply commits one Exposure effect and one Undo step")
        document.undo(); try settle()
        expect(try session.copyPixels(image, merged: true).pixels == original, "document Undo restores original pixels")
        document.redo(); try settle()
        expect(try session.copyPixels(image, merged: true).pixels == applied, "document Redo restores Exposure pixels")
        guard let effect = try session.effects(on: layer, image: image).first(where: { $0.operation == operation.name }) else {
            return expect(false, "the committed Exposure effect can be edited")
        }
        let committedIDs = try session.effects(on: layer, image: image).map(\.id)
        func edit() throws -> NativeFilterPanel {
            owner.editEffectParameters(effect.id, on: layer, operationName: operation.name)
            try require(wait { owner.previewPanel != nil && document.pendingWork == 0 }, "Exposure effect editor did not open")
            guard let edited = owner.previewPanel as? NativeFilterPanel else { throw NSError(domain: "ExposureAdjustFixture", code: 5) }
            return edited
        }
        let editing = try edit()
        guard let filter = editing.filter else { throw NSError(domain: "ExposureAdjustFixture", code: 6) }
        expect(try session.filterProperty(filter, "exposure") == .number(1), "effect edit opens with its committed Exposure value")
        try enter(editing, exposureProperty, 2)
        let editedPreview = try session.copyPixels(image, merged: true).pixels
        expect(try mathMatches(editedPreview, stops: 2) && editedPreview == directReference(2), "effect-edit preview replaces the setting rather than stacking exposure")
        try click(editing, "Cancel")
        expect(try session.copyPixels(image, merged: true).pixels == applied && session.undoInfo(image).undoCount == baseline + 1
                && session.effects(on: layer, image: image).map(\.id) == committedIDs, "effect-edit Cancel preserves pixels, row identity and history")

        let changed = try edit()
        guard let control = row(changed, exposureProperty), let panelWindow = changed.window else { throw NSError(domain: "ExposureAdjustFixture", code: 7) }
        panelWindow.makeKeyAndOrderFront(nil)
        panelWindow.makeFirstResponder(control.field)
        spin(0.03)
        guard let editor = control.field.currentEditor() else { return expect(false, "actual Exposure field editor becomes active") }
        editor.string = control.formatter.string(from: NSNumber(value: 0.5)) ?? "0.5"
        try click(changed, "Apply")
        let replacement = try session.copyPixels(image, merged: true).pixels
        expect(try mathMatches(replacement, stops: 0.5) && replacement == directReference(0.5), "Apply commits the last unsubmitted field through the actual form")
        expect(try session.effects(on: layer, image: image).map(\.id) == committedIDs
                && session.undoInfo(image).undoCount == baseline + 2, "effect-edit Apply retains row identity and adds one Undo step")
        document.undo(); try settle()
        expect(try session.copyPixels(image, merged: true).pixels == applied, "one Undo restores the previous committed Exposure setting")
        document.redo(); try settle()
        expect(try session.copyPixels(image, merged: true).pixels == replacement, "Redo restores the edited Exposure setting")
        let xcf = work.appendingPathComponent("exposure-adjust-controls.xcf")
        try session.save(image, to: xcf.path)
        let reopened = try session.openImage(path: xcf.path)
        let restored = try session.copyPixels(reopened, merged: true).pixels
        let restoredLayer = try session.layers(reopened)[0].id
        let restoredEffects = try session.effects(on: restoredLayer, image: reopened)
        try session.closeImage(reopened)
        expect(restored == replacement && restoredEffects.count == 1 && restoredEffects[0].operation == operation.name,
               "XCF reopening retains edited Exposure pixels and one native effect")
        let beforeGate = try session.undoInfo(image)
        let saveGate = document.beginCloseSave()
        let blocked = !owner.validateMenuItem(item)
        _ = NSApp.sendAction(action, to: owner, from: item)
        try settle()
        document.cancelCloseSave()
        expect(try saveGate && blocked && owner.previewPanel == nil && session.undoInfo(image) == beforeGate
                && session.copyPixels(image, merged: true).pixels == replacement, "close-save admission blocks Exposure without any new preview or mutation")
        expect(try session.copyPixels(otherImage, merged: true).pixels == otherPixels && session.undoInfo(otherImage) == otherUndo,
               "all Apply/edit/Undo/Redo and admission paths retain B's state")
        expect(errors.isEmpty || errors.allSatisfy { $0 == ImageDocument.DocumentError.busy.localizedDescription },
               "successful generic operations report no unexpected native errors")
    }
}
