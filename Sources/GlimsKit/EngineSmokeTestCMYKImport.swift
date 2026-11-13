import AppKit
import CGlimsEngine
import RigiUI

/// Only this focused smoke process installs the proxy. Every image and every
/// import still belongs to the real adapter; faults affect one returned ID.
private enum CMYKImportSmokeProxy {
    private static let lock = NSLock()
    private static var original: GlimsEngineAPI?
    private static var table: UnsafeMutablePointer<GlimsEngineAPI>?
    private static var result: Int32 = 0
    private static var results: [Int32] = []
    private static var calls = 0
    private static var opens = 0
    private static var cancelImport = false
    private static var attempts = 0
    private static var busyRemaining = 0
    private static var failAdoption = false
    private static var observer: (@MainActor (Int) -> Void)?

    private static func locked<T>(_ body: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body()
    }

    static func install(_ pointer: UnsafePointer<GlimsEngineAPI>) throws -> UnsafePointer<GlimsEngineAPI> {
        let api = try EngineLibrary.copyAPI(pointer)
        guard api.image_import_native_cmyk_psd != nil else {
            throw NSError(domain: "CMYKImportSmoke", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "The real producer has no slot 198"])
        }
        return locked {
            precondition(table == nil, "One proxy installation per smoke process")
            original = api
            let owned = UnsafeMutablePointer<GlimsEngineAPI>.allocate(capacity: 1)
            owned.initialize(to: api)
            owned.pointee.image_import_native_cmyk_psd = { engine, path, output, error in
                let state = CMYKImportSmokeProxy.locked { (CMYKImportSmokeProxy.original!, CMYKImportSmokeProxy.cancelImport) }
                let status: GlimsStatus
                if state.1 { output?.pointee = 0; error?.pointee = nil; status = GLIMS_STATUS_CANCELLED }
                else { status = state.0.image_import_native_cmyk_psd!(engine, path, output, error) }
                CMYKImportSmokeProxy.locked {
                    CMYKImportSmokeProxy.calls += 1
                    if status == GLIMS_STATUS_OK, let id = output?.pointee, id > 0 {
                        CMYKImportSmokeProxy.result = id; CMYKImportSmokeProxy.results.append(id)
                    }
                }
                return status
            }
            owned.pointee.image_open = { engine, path, output, error in
                let api = CMYKImportSmokeProxy.locked {
                    CMYKImportSmokeProxy.opens += 1
                    return CMYKImportSmokeProxy.original!
                }
                return api.image_open(engine, path, output, error)
            }
            owned.pointee.image_info = { engine, image, output in
                let blocked = CMYKImportSmokeProxy.locked { CMYKImportSmokeProxy.failAdoption && image == CMYKImportSmokeProxy.result && CMYKImportSmokeProxy.result > 0 }
                if blocked { return GLIMS_STATUS_FAILED }
                return CMYKImportSmokeProxy.locked { CMYKImportSmokeProxy.original! }.image_info(engine, image, output)
            }
            owned.pointee.image_close = { engine, image in
                let state: (GlimsEngineAPI, Bool, Int, (@MainActor (Int) -> Void)?) = CMYKImportSmokeProxy.locked {
                    guard image == CMYKImportSmokeProxy.result, CMYKImportSmokeProxy.result > 0 else { return (CMYKImportSmokeProxy.original!, false, 0, nil) }
                    CMYKImportSmokeProxy.attempts += 1
                    let busy = CMYKImportSmokeProxy.busyRemaining > 0
                    if busy { CMYKImportSmokeProxy.busyRemaining -= 1 } else { CMYKImportSmokeProxy.failAdoption = false }
                    return (CMYKImportSmokeProxy.original!, busy, CMYKImportSmokeProxy.attempts, CMYKImportSmokeProxy.observer)
                }
                let status = state.1 ? GLIMS_STATUS_BUSY : state.0.image_close(engine, image)
                if let callback = state.3 {
                    DispatchQueue.main.async { callback(state.2) }
                }
                return status
            }
            // The session copies the table, but the retained pointer also stays
            // valid through stop. This process-only allocation dies at exit.
            table = owned
            return UnsafePointer(owned)
        }
    }

    static func arm(busy: Int = 0, adoptionFailure: Bool = false, cancelled: Bool = false,
                    onAttempt: (@MainActor (Int) -> Void)? = nil) {
        locked {
            result = 0; calls = 0; opens = 0; attempts = 0; cancelImport = cancelled
            busyRemaining = busy; failAdoption = adoptionFailure; observer = onAttempt
        }
    }

    static var snapshot: (result: Int32, calls: Int, attempts: Int) {
        locked { (result, calls, attempts) }
    }
    static var openCalls: Int { locked { opens } }
    static var allResults: [Int32] { locked { results } }
    static func stopFaults() { locked { busyRemaining = 0; failAdoption = false; cancelImport = false; observer = nil } }
}

@MainActor
extension EngineSmokeTest {
    static func installCMYKImportSmokeAPI(_ pointer: UnsafePointer<GlimsEngineAPI>) throws -> UnsafePointer<GlimsEngineAPI> {
        try CMYKImportSmokeProxy.install(pointer)
    }

    static func exerciseCMYKImport(session: EngineSession, work: URL, documents: DocumentList) throws {
        func expect(_ value: Bool, _ message: String) { check(value, "cmyk-import: \(message)") }
        func require(_ value: Bool, _ message: String) throws {
            guard value else { throw NSError(domain: "CMYKImportSmoke", code: 2,
                userInfo: [NSLocalizedDescriptionKey: message]) }
        }
        func wait(_ ready: () -> Bool, _ message: String, seconds: TimeInterval = 15) throws {
            let deadline = Date().addingTimeInterval(seconds)
            while !ready() && Date() < deadline { EngineSmokeTestHost.pumpEvents(for: 0.01) }
            try require(ready(), message)
        }
        func gone(_ image: Int32) -> Bool {
            do { _ = try session.info(image); return false }
            catch let error as EngineSession.EngineError { return error.isNotFound }
            catch { return false }
        }
        func buttons(_ view: NSView?) -> [NSButton] {
            guard let view else { return [] }
            return ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap { buttons($0) }
        }
        func cancel(_ controller: DocumentWindowController) -> NSButton? {
            buttons(controller.window?.attachedSheet?.contentView).first { $0.title == "Cancel" }
        }
        func pixels(_ image: Int32) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 16, height: 12))
            guard let data = rendered.dataProvider?.data as Data? else { throw NSError(domain: "CMYKImportSmoke", code: 3) }
            return data
        }
        func serialized(_ image: Int32) throws -> Data {
            let url = work.appendingPathComponent("ink-snapshot-\(UUID().uuidString).psd")
            try session.export(image, to: url.path)
            return try Data(contentsOf: url)
        }
        var owners: [AppController] = [], controllers: [DocumentWindowController] = []
        var adopted: [ImageDocument] = [], loose: [Int32] = []
        let oldMenu = NSApp.mainMenu, oldTool = ToolState.shared.current
        let priorPalettes = Dictionary(uniqueKeysWithValues: NSApp.windows.filter { $0 is ClassicPaletteWindow }
            .map { (ObjectIdentifier($0), $0.isVisible) })
        func retain(_ owner: AppController) {
            for controller in owner.documents where !controllers.contains(where: { $0 === controller }) {
                controllers.append(controller); adopted.append(controller.imageDocument)
                documents.items.append(controller.imageDocument)
            }
        }
        defer {
            CMYKImportSmokeProxy.stopFaults()
            owners.forEach(retain)
            for controller in controllers {
                cancel(controller)?.performClick(nil)
                if let window = controller.window, let sheet = window.attachedSheet {
                    window.endSheet(sheet, returnCode: .cancel); sheet.orderOut(nil)
                }
            }
            controllers.filter { !$0.closeStarted }.forEach { $0.closeDiscardingChanges() }
            do { try wait({ adopted.allSatisfy { $0.pendingWork == 0 && gone($0.image) }
                             && !EngineActivity.shared.isBusy }, "All owned document work and closes drain") }
            catch { expect(false, "document cleanup: \(error)") }
            for id in Set(loose + CMYKImportSmokeProxy.allResults) where !gone(id) {
                do { try session.closeImage(id) } catch { expect(false, "remaining native cleanup: \(error)") }
            }
            documents.items.removeAll { item in adopted.contains { $0 === item } }
            for window in NSApp.windows where window is ClassicPaletteWindow {
                if let visible = priorPalettes[ObjectIdentifier(window)] {
                    if visible { window.orderFront(nil) } else { window.orderOut(nil) }
                } else { window.close() }
            }
            NSApp.mainMenu = oldMenu; ToolState.shared.select(oldTool)
            expect(controllers.allSatisfy { $0.window?.attachedSheet == nil }, "all owned sheets are dismissed")
            expect(Set(loose + adopted.map(\.image) + CMYKImportSmokeProxy.allResults).allSatisfy(gone),
                   "all owned native images are closed")
        }
        try require(NSApp.isRunning && session.supportsNativeCMYKPSDImport, "Hosted real slot198 producer required")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.mainMenu = MainMenu.make()
        guard let menuItem = NSApp.mainMenu?.item(withTitle: "File")?.submenu?.items.first(where: {
            $0.action == #selector(AppController.openNativeCMYKPSD(_:))
        }), let menuAction = menuItem.action,
              let icc = NSColorSpace.genericCMYK.iccProfileData else { throw NSError(domain: "CMYKImportSmoke", code: 4) }
        expect(menuItem.title == "Open CMYK PSD…", "actual File menu exposes the explicit preserving import selector")
        expect(!AppController().validateMenuItem(menuItem), "preserving File item is disabled without a running engine")

        func imported(_ url: URL, owner: AppController) throws -> DocumentWindowController {
            var result: Result<DocumentWindowController, Error>?
            owner.importNativeCMYKPSD(from: url) { result = $0 }
            try wait({ result != nil && !EngineActivity.shared.isBusy }, "Preserving import callback settles")
            let controller = try result!.get()
            retain(owner)
            return controller
        }
        func revert(_ controller: DocumentWindowController, owner: AppController) throws -> DocumentWindowController {
            guard let window = controller.window else { throw NSError(domain: "CMYKImportSmoke", code: 5) }
            window.makeKeyAndOrderFront(nil); window.makeMain()
            controller.revertDocument(nil)
            try wait({ window.attachedSheet != nil }, "Actual Revert confirmation appears")
            guard let button = buttons(window.attachedSheet?.contentView).first(where: { $0.title == "Revert" }) else {
                throw NSError(domain: "CMYKImportSmoke", code: 6)
            }
            button.performClick(nil)
            try wait({ !owner.documents.contains(where: { $0 === controller }) && gone(controller.imageDocument.image)
                       && !EngineActivity.shared.isBusy }, "Actual Revert replaces and closes its old document")
            retain(owner)
            guard let next = owner.documents.last else { throw NSError(domain: "CMYKImportSmoke", code: 7) }
            return next
        }
        func failFixture(_ message: String) -> NSError {
            NSError(domain: "CMYKImportSmoke", code: 20, userInfo: [NSLocalizedDescriptionKey: message])
        }
        func readU16BE(_ data: Data, at offset: Int, _ label: String) throws -> Int {
            guard offset >= 0, data.count >= offset + 2 else { throw failFixture("\(label): truncated UInt16") }
            return Int(data[offset]) << 8 | Int(data[offset + 1])
        }
        func readU32BE(_ data: Data, at offset: Int, _ label: String) throws -> Int {
            guard offset >= 0, data.count >= offset + 4 else { throw failFixture("\(label): truncated UInt32") }
            return (Int(data[offset]) << 24) | (Int(data[offset + 1]) << 16)
                | (Int(data[offset + 2]) << 8) | Int(data[offset + 3])
        }
        func checkedAdd(_ a: Int, _ b: Int, _ label: String) throws -> Int {
            let (sum, overflow) = a.addingReportingOverflow(b)
            guard !overflow else { throw failFixture("\(label): overflow") }
            return sum
        }
        func checkedMul(_ a: Int, _ b: Int, _ label: String) throws -> Int {
            let (product, overflow) = a.multipliedReportingOverflow(by: b)
            guard !overflow else { throw failFixture("\(label): overflow") }
            return product
        }
        func appendU16BE(_ value: Int, to data: inout Data, _ label: String) throws {
            guard value >= 0, value <= 0xFFFF else { throw failFixture("\(label): value \(value) outside UInt16") }
            data.append(UInt8((value >> 8) & 0xFF))
            data.append(UInt8(value & 0xFF))
        }
        func literalPackBitsRow(_ row: Data, _ label: String) throws -> Data {
            guard row.count <= 0xFFFF else { throw failFixture("\(label): row length exceeds UInt16") }
            var encoded = Data()
            encoded.reserveCapacity(2 + row.count + (row.count + 127) / 128)
            try appendU16BE(row.count + (row.count + 127) / 128, to: &encoded, "\(label) byte count")
            var offset = 0
            while offset < row.count {
                let count = min(128, row.count - offset)
                encoded.append(UInt8(count - 1))
                encoded.append(row[(row.startIndex + offset)..<(row.startIndex + offset + count)])
                offset += count
            }
            // Keep the declared count and payload in exact agreement for bounds checks.
            let declared = Int(encoded[0]) << 8 | Int(encoded[1])
            guard encoded.count == declared + 2 else { throw failFixture("\(label): encoded length mismatch") }
            return encoded
        }
        func makePackBitsRLEPSD(from raw: Data, label: String) throws -> Data {
            guard raw.count >= 26 else { throw failFixture("\(label): RAW PSD too small") }
            guard raw[0] == 0x38, raw[1] == 0x42, raw[2] == 0x50, raw[3] == 0x53 else {
                throw failFixture("\(label): missing PSD signature")
            }
            guard try readU16BE(raw, at: 4, "\(label) version") == 1 else { throw failFixture("\(label): unsupported PSD version") }
            let channels = try readU16BE(raw, at: 12, "\(label) channels")
            let height = try readU32BE(raw, at: 14, "\(label) height")
            let width = try readU32BE(raw, at: 18, "\(label) width")
            let depth = try readU16BE(raw, at: 22, "\(label) depth")
            let colorMode = try readU16BE(raw, at: 24, "\(label) color mode")
            guard channels == 4 else { throw failFixture("\(label): expected 4 channels, got \(channels)") }
            guard colorMode == 4 else { throw failFixture("\(label): expected CMYK color mode, got \(colorMode)") }
            guard depth == 8 || depth == 16 else { throw failFixture("\(label): unsupported depth \(depth)") }
            guard width > 0, height > 0 else { throw failFixture("\(label): invalid dimensions") }

            var offset = 26
            let colorDataLen = try readU32BE(raw, at: offset, "\(label) color data length"); offset = try checkedAdd(offset, 4, "\(label) color data offset")
            let colorDataEnd = try checkedAdd(offset, colorDataLen, "\(label) color data end")
            guard raw.count >= colorDataEnd else { throw failFixture("\(label): truncated color data section") }
            let resourcesLen = try readU32BE(raw, at: colorDataEnd, "\(label) resources length"); offset = try checkedAdd(colorDataEnd, 4, "\(label) resources offset")
            let resourcesEnd = try checkedAdd(offset, resourcesLen, "\(label) resources end")
            guard raw.count >= resourcesEnd else { throw failFixture("\(label): truncated resources section") }
            let layerMaskLen = try readU32BE(raw, at: resourcesEnd, "\(label) layer/mask length"); offset = try checkedAdd(resourcesEnd, 4, "\(label) layer/mask offset")
            let layerMaskEnd = try checkedAdd(offset, layerMaskLen, "\(label) layer/mask end")
            guard raw.count >= layerMaskEnd else { throw failFixture("\(label): truncated layer/mask section") }
            let imageOffset = layerMaskEnd
            let imageHeaderEnd = try checkedAdd(imageOffset, 2, "\(label) image data header")
            guard raw.count >= imageHeaderEnd else { throw failFixture("\(label): truncated image data header") }
            let compression = try readU16BE(raw, at: imageOffset, "\(label) compression")
            guard compression == 0 else { throw failFixture("\(label): expected RAW compression, got \(compression)") }

            let bytesPerSample = depth / 8
            let rowBytes = try checkedMul(width, bytesPerSample, "\(label) row bytes")
            let planeBytes = try checkedMul(rowBytes, height, "\(label) plane bytes")
            let imageBytes = try checkedMul(planeBytes, channels, "\(label) image bytes")
            let payloadOffset = try checkedAdd(imageOffset, 2, "\(label) image payload offset")
            let payloadEnd = try checkedAdd(payloadOffset, imageBytes, "\(label) image payload end")
            guard raw.count == payloadEnd else {
                throw failFixture("\(label): RAW payload size mismatch (expected \(payloadEnd), got \(raw.count))")
            }

            var result = Data()
            result.reserveCapacity(raw.count)
            result.append(raw[0..<imageOffset])
            result.append(0); result.append(1) // PackBits/RLE

            var rowLengths = Data()
            rowLengths.reserveCapacity(channels * height * 2)
            var encodedRows = Data()
            encodedRows.reserveCapacity(imageBytes)
            for channel in 0..<channels {
                for row in 0..<height {
                    let start = try checkedAdd(payloadOffset, try checkedAdd(try checkedMul(channel, planeBytes, "\(label) channel offset"),
                                                                             try checkedMul(row, rowBytes, "\(label) row offset"),
                                                                             "\(label) sample offset"), "\(label) sample start")
                    let end = try checkedAdd(start, rowBytes, "\(label) sample end")
                    let encoded = try literalPackBitsRow(raw[start..<end], "\(label) ch\(channel) row\(row)")
                    let count = try readU16BE(encoded, at: 0, "\(label) ch\(channel) row\(row) byte count")
                    try appendU16BE(count, to: &rowLengths, "\(label) ch\(channel) row\(row) table")
                    encodedRows.append(encoded.dropFirst(2))
                }
            }
            result.append(rowLengths)
            result.append(encodedRows)
            // Preserve every section before image data unchanged (header, color, ICC/resources, layer/mask).
            expect(result.starts(with: raw[0..<imageOffset]), "RLE fixture preserves header/ICC/sections for \(label)")
            return result
        }

        struct ImportFixture {
            let label: String
            let component: EngineSession.ColorComponent
            let url: URL
            let sourceBytes: Data
            let rawOriginal: Data
            let originalPixels: Data
        }
        var fixtures: [ImportFixture] = []
        var exampleURL: URL?
        for component in [EngineSession.ColorComponent.u8, .u16] {
            let source = try session.newCmykImage(width: 16, height: 12, component: component, profileICC: icc)
            loose.append(source)
            let originalChannels = try session.channels(source)
            for (index, channel) in originalChannels.enumerated() {
                try session.channelCommand(.select, channel: channel.id, image: source)
                try session.editInk(source, channel: channel.id,
                                    settings: .init(operation: .fill, intensity: Double(index + 1) / 5, opacity: 1))
            }
            let rawURL = work.appendingPathComponent("preserved-\(component.rawValue)-raw.psd")
            try session.export(source, to: rawURL.path)
            let rawOriginal = try Data(contentsOf: rawURL)
            let originalPixels = try pixels(source)
            expect(rawOriginal.range(of: icc) != nil && rawOriginal.count > icc.count,
                   "\(component)/RAW: source fixture contains exact embedded profile and real ink samples")

            let rleURL = work.appendingPathComponent("preserved-\(component.rawValue)-rle.psd")
            let rleBytes = try makePackBitsRLEPSD(from: rawOriginal, label: "\(component)/RAW->RLE")
            try rleBytes.write(to: rleURL)

            fixtures.append(.init(label: "\(component.rawValue)-raw", component: component,
                                  url: rawURL, sourceBytes: rawOriginal, rawOriginal: rawOriginal, originalPixels: originalPixels))
            fixtures.append(.init(label: "\(component.rawValue)-rle", component: component,
                                  url: rleURL, sourceBytes: rleBytes, rawOriginal: rawOriginal, originalPixels: originalPixels))
            if component == .u8 { exampleURL = rleURL } // Prefer RLE for downstream tests.
        }
        for fixture in fixtures {
            let component = fixture.component
            let label = fixture.label
            let url = fixture.url
            let sourceBytes = fixture.sourceBytes
            let rawOriginal = fixture.rawOriginal
            let originalPixels = fixture.originalPixels
            let owner = AppController(session: session); owners.append(owner)
            expect(owner.validateMenuItem(menuItem), "\(label): actual File item is enabled for the live producer")

            // A real ordinary PSD import at this path is an RGB appearance document.
            let appearanceID = try session.openImage(path: url.path); loose.append(appearanceID)
            let appearance = try ImageDocument(session: session, image: appearanceID, name: "Appearance \(label)", openedFrom: url)
            owner.open(appearance); retain(owner)
            try wait({ appearance.pendingWork == 0 && !EngineActivity.shared.isBusy }, "\(label): Appearance import settles")
            let appearancePixels = try pixels(appearanceID)
            expect(appearance.colorInfo.mode == .rgb && appearance.fileState.importStrategy == .appearance,
                   "\(label): same-path ordinary Open is an RGB appearance import")
            CMYKImportSmokeProxy.arm()
            var controller = try imported(url, owner: owner)
            var document = controller.imageDocument
            expect(owner.documents.count == 2 && document !== appearance && document.image != appearanceID,
                   "\(label): preserving import does not reuse the same-path appearance document")
            expect(document.colorInfo.mode == .cmyk && document.colorInfo.component == component && document.channels.count == 4,
                   "\(label): imported document exposes four native CMYK inks at source depth")
            expect(document.fileState.importStrategy == .nativeCMYKPSD && document.fileState.nativeURL == nil
                   && document.fileState.importedSourceURL == url && document.hasUnsavedChanges
                   && document.fileState.saveRoute == .askForFile && document.fileState.revertSource == .nativeCMYKPSD(url),
                   "\(label): preserving import is unsaved with its typed foreign identity")
            expect(try serialized(document.image) == rawOriginal && pixels(document.image) == originalPixels,
                   "\(label): exported native samples/profile (engine exports RAW) and displayed composite match the source exactly")
            expect(try Data(contentsOf: url) == sourceBytes,
                   "\(label): source fixture bytes remain unchanged for input comparisons")
            expect(document.undoInfo.undoCount == 0 && document.undoInfo.redoCount == 0,
                   "\(label): imported native image begins with empty history")
            let repeatController = try imported(url, owner: owner)
            expect(repeatController === controller && owner.documents.count == 2 && CMYKImportSmokeProxy.snapshot.calls == 1,
                   "\(label): second preserving import focuses the existing document without another native import")
            expect(NSApp.keyWindow === controller.window, "\(label): repeated preserving import brings its window forward")

            guard let channel = document.channels.first?.id else {
                throw NSError(domain: "CMYKImportSmoke", code: 10)
            }
            document.selectChannel(channel)
            try wait({ document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "\(label): Ink target selection settles")
            var edit: Result<Void, Error>?
            expect(document.editInk(.init(operation: .fill, intensity: 0.95, opacity: 1), channel: channel) { edit = $0 },
                   "\(label): supported scalar Fill is accepted on imported CMYK")
            try wait({ edit != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "\(label): Imported ink edit settles")
            try edit!.get()
            expect(try serialized(document.image) != rawOriginal && document.undoInfo.undoCount == 1,
                   "\(label): imported ink edit changes actual samples with one Undo")
            CMYKImportSmokeProxy.arm()
            controller = try revert(controller, owner: owner); document = controller.imageDocument
            expect(CMYKImportSmokeProxy.snapshot.calls == 1 && CMYKImportSmokeProxy.openCalls == 0
                   && document.colorInfo.mode == .cmyk && document.fileState.importStrategy == .nativeCMYKPSD,
                   "\(label): actual Revert uses preserving import and remains native CMYK")
            expect(try serialized(document.image) == rawOriginal && pixels(document.image) == originalPixels
                   && document.undoInfo.undoCount == 0, "\(label): Revert restores exact source samples/profile/history (RAW engine export)")
            expect(try pixels(appearanceID) == appearancePixels && Data(contentsOf: url) == sourceBytes,
                   "\(label): preserving edits and Revert leave appearance document and source file unchanged")

            let saved = work.appendingPathComponent("preserved-\(label).xcf")
            var savedDone = false, saveError: Error?
            document.save(to: saved) { error in
                saveError = error
                if error == nil { document.noteSaved(to: saved) }
                savedDone = true
            }
            try wait({ savedDone && document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "\(label): Native Save settles")
            try require(saveError == nil, "Native Save failed (\(label)): \(String(describing: saveError))")
            expect(!document.hasUnsavedChanges && document.fileState.importStrategy == nil
                   && document.fileState.revertSource == .native(saved), "\(label): native Save replaces preserving import identity")
            CMYKImportSmokeProxy.arm()
            controller = try revert(controller, owner: owner); document = controller.imageDocument
            expect(CMYKImportSmokeProxy.snapshot.calls == 0 && CMYKImportSmokeProxy.openCalls == 1
                   && document.colorInfo.mode == .cmyk && document.fileState.nativeURL == saved && !document.hasUnsavedChanges,
                   "\(label): saved XCF Revert switches to ordinary native Open while retaining CMYK")
            expect(try serialized(document.image) == rawOriginal, "\(label): XCF Save/Revert retains exact native inks/profile (RAW engine export)")
        }
        guard let exampleURL else { throw NSError(domain: "CMYKImportSmoke", code: 8) }
        let failureOwner = AppController(session: session); owners.append(failureOwner)
        let malformed = work.appendingPathComponent("malformed-import.psd")
        try Data("This is not a PSD".utf8).write(to: malformed)
        for cancelled in [false, true] {
            CMYKImportSmokeProxy.arm(cancelled: cancelled)
            var outcome: Result<DocumentWindowController, Error>?
            failureOwner.importNativeCMYKPSD(from: cancelled ? exampleURL : malformed) { outcome = $0 }
            try wait({ outcome != nil && !EngineActivity.shared.isBusy }, "Failed/cancelled import settles")
            if case .failure(let error) = outcome! {
                expect(!cancelled || (error as? EngineSession.EngineError)?.status == Int32(GLIMS_STATUS_CANCELLED.rawValue),
                       "cancelled import preserves the native cancellation status")
            } else { expect(false, "invalid/cancelled import must fail") }
            expect(failureOwner.documents.isEmpty && CMYKImportSmokeProxy.snapshot.result == 0,
                   "\(cancelled ? "cancelled" : "invalid") import creates no image window")
            expect(CMYKImportSmokeProxy.openCalls == 0, "failed preserving import never falls back to ordinary Open")
        }
        CMYKImportSmokeProxy.arm()
        _ = try imported(exampleURL, owner: failureOwner)
        expect(failureOwner.documents.count == 1, "a cancelled request releases its same-path reservation for retry")

        let disguised = work.appendingPathComponent("CMYK content named.xcf")
        try FileManager.default.copyItem(at: exampleURL, to: disguised)
        let disguisedController = try imported(disguised, owner: failureOwner)
        expect(disguisedController.imageDocument.fileState.nativeURL == nil
               && disguisedController.imageDocument.fileState.importStrategy == .nativeCMYKPSD
               && disguisedController.imageDocument.fileState.revertSource == .nativeCMYKPSD(disguised)
               && disguisedController.imageDocument.hasUnsavedChanges,
               "preserving import treats PSD content with an XCF suffix as foreign and unsaved")

        // Dispatch the installed File item into the real controller and cancel
        // the actual modal NSOpenPanel; the timer also bounds a missing panel.
        CMYKImportSmokeProxy.arm()
        let countBeforePanel = failureOwner.documents.count
        var cancelledPanel = false, panelTimedOut = false
        let deadline = Date().addingTimeInterval(10)
        let timer = Timer(timeInterval: 0.02, repeats: true) { timer in
            if let panel = NSApp.modalWindow as? NSOpenPanel {
                cancelledPanel = true; panel.cancel(nil); timer.invalidate()
            } else if Date() >= deadline {
                panelTimedOut = true; NSApp.abortModal(); timer.invalidate()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        let dispatched = NSApp.sendAction(menuAction, to: failureOwner, from: menuItem)
        timer.invalidate()
        expect(dispatched && cancelledPanel && !panelTimedOut, "actual File action presents an Open panel that Cancel dismisses")
        expect(NSApp.modalWindow == nil && failureOwner.documents.count == countBeforePanel
               && CMYKImportSmokeProxy.snapshot.calls == 0 && !EngineActivity.shared.isBusy,
               "Open-panel Cancel changes no documents and submits no native work")

        // A dirty sentinel prevents accidental termination and makes the pending
        // file-operation lifetime visible through the real Save confirmation.
        for quitting in [false, true] {
            let owner = AppController(session: session); owners.append(owner)
            let sentinelID = try session.newImage(width: 16, height: 12); loose.append(sentinelID)
            let sentinel = try ImageDocument(session: session, image: sentinelID, name: "Unsaved import sentinel")
            sentinel.noteUnsavedConvertedCopy()
            owner.open(sentinel); retain(owner)
            guard let controller = owner.documents.first else { throw NSError(domain: "CMYKImportSmoke", code: 9) }
            try wait({ sentinel.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Sentinel settles")
            let oldObserver = sentinel.onStateChange
            var requested = false, reply: NSApplication.TerminateReply?
            var callbackCount = 0, outcome: Result<DocumentWindowController, Error>?
            var firstBusyHeld: Bool?
            sentinel.onStateChange = {
                oldObserver?()
                guard !requested, EngineActivity.shared.isBusy else { return }
                requested = true
                if quitting { reply = owner.applicationShouldTerminate(NSApp) }
                else { owner.closeAllDocuments(nil) }
            }
            CMYKImportSmokeProxy.arm(busy: 2, adoptionFailure: !quitting) { attempt in
                if attempt == 1 {
                    firstBusyHeld = callbackCount == 0 && controller.window?.attachedSheet == nil && !sentinel.isClosing
                }
            }
            owner.importNativeCMYKPSD(from: exampleURL) { callbackCount += 1; outcome = $0 }
            try wait({ firstBusyHeld != nil }, "Discarded imported result reaches first BUSY cleanup")
            sentinel.onStateChange = oldObserver
            expect(requested && (!quitting || reply == .terminateLater),
                   "\(quitting ? "Quit" : "Close All") observes an accepted import transaction")
            expect(firstBusyHeld == true, "\(quitting ? "Quit" : "adoption failure") holds completion and Save prompt during BUSY cleanup")
            try wait({ outcome != nil && cancel(controller) != nil && !EngineActivity.shared.isBusy },
                     "Result cleanup completes before dirty-sentinel Save confirmation")
            let result = CMYKImportSmokeProxy.snapshot
            expect(result.result > 0 && gone(result.result) && result.attempts == 3,
                   "\(quitting ? "Quit" : "adoption failure") retries two BUSY closes and destroys the native result")
            if case .failure = outcome! { expect(callbackCount == 1, "discarded import completes exactly once with failure") }
            else { expect(false, "discarded import must not publish a document") }
            expect(owner.documents.count == 1 && owner.documents.first === controller,
                   "discarded result creates no document window")
            cancel(controller)?.performClick(nil)
            try wait({ controller.window?.attachedSheet == nil }, "Cancel dirty-sentinel close")
            expect(!sentinel.isClosing && NSApp.isRunning && owner.validateMenuItem(menuItem),
                   "Cancel keeps the sentinel and restores the active import command")
        }
    }
}
