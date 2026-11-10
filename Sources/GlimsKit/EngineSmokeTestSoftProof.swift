import AppKit

private final class ProofSmokeFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() { lock.lock(); marked = true; lock.unlock() }
    var isMarked: Bool { lock.lock(); defer { lock.unlock() }; return marked }
}

@MainActor
extension EngineSmokeTest {
    static func exerciseSoftProof(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        @discardableResult func wait(_ condition: () -> Bool) -> Bool {
            let limit = Date().addingTimeInterval(15)
            while !condition() && Date() < limit { spin(0.01) }
            return condition()
        }
        let oldRenderGate = DispatchSemaphore(value: 0), newRenderGate = DispatchSemaphore(value: 0)
        let cancelReadGate = DispatchSemaphore(value: 0), closeReadGate = DispatchSemaphore(value: 0)
        var owned: [DocumentWindowController] = []
        defer {
            for gate in [oldRenderGate, newRenderGate, cancelReadGate, closeReadGate] { gate.signal() }
            for controller in owned {
                controller.softProofController?.invalidate()
                if let sheet = controller.window?.attachedSheet { controller.window?.endSheet(sheet, returnCode: .abort) }
                controller.window?.orderOut(nil)
                var stopped = false
                controller.canvas.stopRendering { stopped = true }
                wait { stopped }
            }
            for controller in owned {
                let document = controller.imageDocument
                if !document.isClosing { document.closeImageWhenDrained() }
                wait { (try? session.info(document.image)) == nil }
            }
            documents.items.removeAll { document in owned.contains { $0.imageDocument === document } }
        }
        func attach(_ image: Int32, name: String) throws -> DocumentWindowController {
            do {
                let document = try ImageDocument(session: session, image: image, name: name)
                documents.items.append(document)
                let controller = DocumentWindowController(document: document)
                owned.append(controller)
                controller.showWindow(nil)
                return controller
            } catch { try? session.closeImage(image); throw error }
        }
        func settle(_ document: ImageDocument) {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            spin(0.03)
        }
        func bytes(_ image: CGImage) -> Data? { image.dataProvider?.data as Data? }
        func iccTag(_ data: Data) -> Data? {
            CGColorSpace(iccData: data as CFData)?.copyICCData() as Data?
        }
        func cacheHasExpectedICC(_ canvas: EngineCanvasView) -> Bool {
            guard canvas.renderedTileCount > 0, let destination = canvas.destination.profileICC,
                  let expected = iccTag(destination), let actual = canvas.cachedTileICCData() else { return false }
            return actual == expected
        }
        func choose(_ popup: NSPopUpButton, _ intent: EngineSession.ProfileIntent) {
            popup.selectItem(at: EngineSession.ProfileIntent.conversionChoices.firstIndex(of: intent)!)
        }
        guard let gray = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let grayICC = gray.copyICCData() as Data?,
              let p3 = CGColorSpace(name: CGColorSpace.displayP3), let p3Space = NSColorSpace(cgColorSpace: p3) else {
            return check(false, "the proof fixture has generated gray-gamma2.2 and P3 ICC profiles")
        }
        let profileURL = work.appendingPathComponent("generated-proof-gray-gamma22.icc")
        let invalidURL = work.appendingPathComponent("invalid-proof.icc")
        let oversizedURL = work.appendingPathComponent("oversized-proof.icc")
        try grayICC.write(to: profileURL)
        try Data("This is not an ICC profile".utf8).write(to: invalidURL)
        try Data(repeating: 0, count: CanvasSoftProof.maximumICCBytes + 1).write(to: oversizedURL)
        let width = 48, height = 32
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let i = (y * width + x) * 4
            pixels[i] = UInt8((x * 17 + y * 5) % 256)
            pixels[i + 1] = UInt8((x * 3 + y * 29) % 256)
            pixels[i + 2] = UInt8((x * 31 + y * 7) % 256)
            pixels[i + 3] = [0, 64, 128, 255][x % 4]
        } }
        let a = try attach(session.newImage(pixels: ClipboardImage(width: width, height: height,
            pixels: Data(pixels), origin: .zero)), name: "Proof A")
        let b = try attach(session.newImage(width: 32, height: 24), name: "Proof B")
        let document = a.imageDocument, other = b.imageDocument
        let image = document.image, otherImage = other.image
        a.window?.colorSpace = p3Space
        b.window?.colorSpace = NSColorSpace.sRGB
        a.canvas.viewDidChangeBackingProperties()
        b.canvas.viewDidChangeBackingProperties()
        let infoBefore = try session.info(image), colorBefore = try session.colorInfo(image)
        let undoBefore = try session.undoInfo(image), sourceBefore = try session.copyPixels(image, merged: false).pixels
        let otherInfo = try session.info(otherImage), otherUndo = try session.undoInfo(otherImage)
        let otherPixels = try session.copyPixels(otherImage, merged: true).pixels
        func nativeStateIsIntact() -> Bool {
            (try? session.info(image)) == infoBefore && (try? session.colorInfo(image)) == colorBefore
                && (try? session.undoInfo(image)) == undoBefore
                && (try? session.copyPixels(image, merged: false).pixels) == sourceBefore
                && (try? session.info(otherImage)) == otherInfo && (try? session.undoInfo(otherImage)) == otherUndo
                && (try? session.copyPixels(otherImage, merged: true).pixels) == otherPixels
        }
        let viewMenu = MainMenu.make().items.first { $0.title == "View" }?.submenu
        guard let setup = viewMenu?.items.first(where: { $0.title == "Soft Proof Setup…" }),
              let toggle = viewMenu?.items.first(where: { $0.title == "Soft Proof" }) else {
            return check(false, "View offers Soft Proof and Soft Proof Setup")
        }
        check(setup.action == #selector(DocumentWindowController.showSoftProofSetup(_:))
                && toggle.action == #selector(DocumentWindowController.toggleSoftProof(_:)) && a.validateMenuItem(setup),
              "the actual View menu routes proof setup and toggle to the document window")
        func open(_ owner: DocumentWindowController) -> SoftProofController? {
            owner.window?.makeKeyAndOrderFront(nil)
            if let action = setup.action { NSApp.sendAction(action, to: owner, from: setup) }
            wait { owner.softProofController != nil }
            return owner.softProofController
        }
        func apply(_ form: SoftProofController, document: ImageDocument) {
            form.applyButton.performClick(nil)
            wait { form.isInvalidated || (!form.isApplying && form.lastError != nil) }
            settle(document)
        }
        guard let first = open(a) else { return check(false, "the View action opens its actual owned proof form") }
        check(first.window?.sheetParent === a.window && first.imageDocument === document && first.initialProof == nil
                && first.proofIntentPopup.titleOfSelectedItem == EngineSession.ProfileIntent.relativeColorimetric.title
                && first.displayIntentPopup.titleOfSelectedItem == EngineSession.ProfileIntent.relativeColorimetric.title
                && first.blackPointCompensationCheck.state == .off,
              "the owned form starts with relative intents and black point compensation off")
        first.pathField.stringValue = profileURL.path
        choose(first.proofIntentPopup, .perceptual)
        first.blackPointCompensationCheck.state = .on
        b.window?.makeKeyAndOrderFront(nil)
        apply(first, document: document)
        guard let proof = a.canvas.softProof, first.isInvalidated else {
            return check(false, "a generated gray proof passes actual asynchronous native preflight: \(first.lastError ?? "no result")")
        }
        check(proof.profileICC == grayICC && proof.proofIntent == .perceptual
                && proof.displayIntent == .relativeColorimetric && proof.blackPointCompensation
                && b.canvas.softProof == nil && a.softProofController == nil,
              "Apply changes only its captured window while another window is front")
        check(nativeStateIsIntact(), "proof setup leaves native pixels, working profile, dirty state and history unchanged")
        func oracleMatches(_ proof: CanvasSoftProof) throws -> Bool {
            let destination = a.canvas.destination
            guard let destinationICC = destination.profileICC else { return false }
            let area = CGRect(x: 0, y: 0, width: width, height: height)
            let actual = try CanvasDisplayDestination.render(session, image: image, scale: 1, area: area,
                                                             destination: destination, proof: proof)
            let expected = try session.render(image, scale: 1, area: area, destinationICC: destinationICC, proof: proof)
            let unproofed = try session.render(image, scale: 1, area: area, destinationICC: destinationICC)
            guard let actualBytes = bytes(actual), let expectedBytes = bytes(expected), let ordinaryBytes = bytes(unproofed),
                  let actualTag = actual.colorSpace?.copyICCData() as Data?,
                  let expectedTag = iccTag(destinationICC) else { return false }
            return actualBytes.count == width * height * 4
                && actualBytes.enumerated().contains(where: { $0.offset % 4 < 3 && $0.element != 0 })
                && actualBytes == expectedBytes && actualBytes != ordinaryBytes && actualTag == expectedTag
        }
        check(try oracleMatches(proof), "actual window proof settings match the native colored-alpha oracle and differ from unproofed display pixels")
        wait { a.canvas.renderedTileCount > 0 && !a.canvas.hasPendingRender && b.canvas.renderedTileCount > 0 && !b.canvas.hasPendingRender }
        check(cacheHasExpectedICC(a.canvas) && cacheHasExpectedICC(b.canvas)
                && a.canvas.destination != b.canvas.destination,
              "actual cached tiles keep each owning window's distinct destination ICC")
        first.pathField.stringValue = invalidURL.path
        choose(first.proofIntentPopup, .saturation)
        first.blackPointCompensationCheck.state = .off
        check(a.canvas.softProof == proof, "changing closed form controls cannot mutate the captured applied proof value")
        if let action = toggle.action { NSApp.sendAction(action, to: a, from: toggle) }
        _ = a.validateMenuItem(toggle)
        check(a.canvas.softProof == nil && toggle.state == .off && b.canvas.softProof == nil,
              "the real View toggle disables only A's proof")
        if let action = toggle.action { NSApp.sendAction(action, to: a, from: toggle) }
        _ = a.validateMenuItem(toggle)
        check(a.canvas.softProof == proof && toggle.state == .on, "the View toggle restores A's exact saved proof settings")

        // The file is gone: changing only options must use retained ICC bytes.
        try FileManager.default.removeItem(at: profileURL)
        guard let reuse = open(a) else { return check(false, "the applied proof opens for pathless option editing") }
        check(reuse.initialProof == proof && reuse.pathField.stringValue.isEmpty,
              "reopened setup retains the applied profile without requiring its deleted file")
        choose(reuse.proofIntentPopup, .absoluteColorimetric)
        choose(reuse.displayIntentPopup, .perceptual)
        reuse.blackPointCompensationCheck.state = .off
        wait { a.canvas.renderedTileCount > 0 && !a.canvas.hasPendingRender }
        let enteredOld = ProofSmokeFlag(), enteredNew = ProofSmokeFlag()
        a.canvas.enqueueRenderBarrier { DispatchQueue.main.async { enteredOld.mark() }; oldRenderGate.wait() }
        guard wait({ enteredOld.isMarked }) else { return check(false, "the old-proof render barrier starts") }
        a.canvas.imageDidChange(in: nil)
        a.canvas.setNeedsRender()
        check(a.canvas.hasPendingRender, "an old-proof tile is captured and pending behind the render barrier")
        a.canvas.enqueueRenderBarrier { DispatchQueue.main.async { enteredNew.mark() }; newRenderGate.wait() }
        apply(reuse, document: document)
        guard let updated = a.canvas.softProof, reuse.isInvalidated, updated != proof else {
            return check(false, "pathless options validate against the retained profile: \(reuse.lastError ?? "no result")")
        }
        check(updated.profileICC == grayICC && updated.proofIntent == .absoluteColorimetric
                && updated.displayIntent == .perceptual && !updated.blackPointCompensation
                && a.canvas.renderedTileCount == 0,
              "new options retain exact ICC bytes and invalidate the existing canvas cache")
        oldRenderGate.signal()
        guard wait({ enteredNew.isMarked }) else { return check(false, "the old tile finishes before the new-render barrier") }
        check(a.canvas.renderedTileCount == 0 && a.canvas.hasPendingRender && a.canvas.softProof == updated,
              "the completed stale old-proof tile cannot repopulate the new proof cache")
        newRenderGate.signal()
        wait { a.canvas.renderedTileCount > 0 && !a.canvas.hasPendingRender }
        check(try oracleMatches(updated) && cacheHasExpectedICC(a.canvas),
              "fresh proof tiles use the new captured options and the exact owning-window ICC")
        try grayICC.write(to: profileURL)

        guard let invalid = open(a) else { return check(false, "setup opens for invalid profile checks") }
        invalid.pathField.stringValue = "relative.icc"
        invalid.applyButton.performClick(nil)
        check(!invalid.isApplying && invalid.lastError != nil && document.pendingWork == 0,
              "invalid path syntax fails before any document work is queued")
        invalid.pathField.stringValue = invalidURL.path
        apply(invalid, document: document)
        check(!invalid.isInvalidated && invalid.lastError != nil && invalid.window?.sheetParent === a.window
                && invalid.pathField.stringValue == invalidURL.path && a.canvas.softProof == updated && nativeStateIsIntact(),
              "invalid ICC contents retain the open draft and existing proof without native image changes")
        invalid.pathField.stringValue = oversizedURL.path
        apply(invalid, document: document)
        check(!invalid.isInvalidated && invalid.lastError != nil && invalid.pathField.stringValue == oversizedURL.path
                && a.canvas.softProof == updated && nativeStateIsIntact(),
              "oversized ICC input fails while preserving the draft, applied proof and native image")
        invalid.cancelButton.performClick(nil)
        wait { invalid.isInvalidated && a.softProofController == nil }

        guard let cancelled = open(a) else { return check(false, "setup opens for cancellation during a read") }
        let cancelEntered = ProofSmokeFlag()
        document.inputQueue.async { DispatchQueue.main.async { cancelEntered.mark() }; cancelReadGate.wait() }
        guard wait({ cancelEntered.isMarked }) else { return check(false, "the profile read is held on its counted queue") }
        cancelled.pathField.stringValue = profileURL.path
        cancelled.applyButton.performClick(nil)
        check(cancelled.isApplying && document.pendingWork > 0 && !cancelled.applyButton.isEnabled
                && !cancelled.pathField.isEnabled && cancelled.cancelButton.isEnabled,
              "pending native preflight disables the draft while keeping Cancel available")
        cancelled.cancelButton.performClick(nil)
        wait { cancelled.isInvalidated && a.softProofController == nil }
        cancelReadGate.signal()
        settle(document)
        check(cancelled.isInvalidated && a.window?.attachedSheet == nil && a.canvas.softProof == updated
                && b.canvas.softProof == nil && nativeStateIsIntact(),
              "Cancel discards a late counted preflight result without changing either window or native image")

        let closing = try attach(session.newImage(width: 16, height: 16), name: "Proof closing")
        let closingDocument = closing.imageDocument, closingImage = closingDocument.image
        guard let closingForm = open(closing) else { return check(false, "a fresh window owns the closing-read fixture") }
        let closeEntered = ProofSmokeFlag()
        closingDocument.inputQueue.async { DispatchQueue.main.async { closeEntered.mark() }; closeReadGate.wait() }
        guard wait({ closeEntered.isMarked }) else { return check(false, "the closing profile read can be held") }
        closingForm.pathField.stringValue = profileURL.path
        closingForm.applyButton.performClick(nil)
        closing.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: closing.window))
        closing.window?.orderOut(nil)
        wait { closingDocument.isClosing }
        check(closing.closeStarted && closingDocument.isClosing && closingDocument.pendingWork > 0
                && closingForm.isInvalidated && (try? session.info(closingImage)) != nil,
              "closing invalidates the form while counted preflight keeps its native image alive")
        closeReadGate.signal()
        wait { (try? session.info(closingImage)) == nil && closingDocument.pendingWork == 0 }
        settle(document)
        check((try? session.info(closingImage)) == nil && closing.softProofController == nil
                && closing.canvas.softProof == nil && a.canvas.softProof == updated && b.canvas.softProof == nil,
              "close drains the late read, destroys its image and never reapplies or redirects its proof")

        if let path = ProcessInfo.processInfo.environment["GLIMS_PROOF_CMYK_PROFILE"], !path.isEmpty {
            guard let cmyk = open(a) else { return check(false, "the optional CMYK profile opens in actual setup") }
            cmyk.pathField.stringValue = path
            apply(cmyk, document: document)
            guard let proof = a.canvas.softProof, cmyk.isInvalidated,
                  CGColorSpace(iccData: proof.profileICC as CFData)?.model == .cmyk else {
                return check(false, "the optional supplied profile is a native-preflighted CMYK proof: \(cmyk.lastError ?? "no result")")
            }
            check(try oracleMatches(proof), "the optional local CMYK proof renders actual colored-alpha pixels equal to native output")
        } else { print("skip optional CMYK UI profile: GLIMS_PROOF_CMYK_PROFILE is not set") }
        check(nativeStateIsIntact(), "all proof UI, rendering, errors and cancellation leave native pixels/profile/dirty/history unchanged")
    }
}
