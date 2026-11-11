import AppKit

@MainActor
extension EngineSmokeTest {
    /// Exercises the asynchronous preview service against an independently
    /// constructed image transformed through the native commit API. No canvas
    /// or window is needed for these pixel and document-lifetime assertions.
    static func exerciseTransformPixelPreview(_ session: EngineSession, work: URL,
                                              documents: DocumentList) throws {
        struct SourceState: Equatable {
            let pixels: Data
            let layers: [EngineSession.Layer]
            let selected: [Int32]
            let channels: [Int32]
            let masks: [Int32: EngineSession.MaskState]
            let color: EngineSession.ColorInfo
            let undo: EngineSession.UndoInfo
            let history: EngineSession.History
            let info: EngineSession.ImageInfo
        }
        var owned: [ImageDocument] = []
        var loose: [Int32] = []
        var releases: [DispatchSemaphore] = []
        func require(_ condition: Bool, _ message: String) throws {
            guard condition else {
                throw NSError(domain: "TransformPixelPreviewFixture", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: message])
            }
        }
        func wait(_ description: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(20)
            while !condition() && Date() < deadline { spin(0.005) }
            try require(condition(), "Transform preview timed out: \(description)")
        }
        func drain(_ document: ImageDocument) throws {
            try wait("document work drains") {
                document.pendingWork == 0 && !EngineActivity.shared.isBusy
            }
        }
        func bytes(_ image: CGImage) throws -> Data {
            guard let data = image.dataProvider?.data else {
                throw NSError(domain: "TransformPixelPreviewFixture", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Rendered image has no pixel data"])
            }
            return data as Data
        }
        let size = CGSize(width: 160, height: 150)
        let area = CGRect(origin: .zero, size: size)
        let original = CGRect(x: 20, y: 20, width: 100, height: 100)
        // Analytic trapezoid, independent of the canvas's homography solver:
        // (20,20),(120,20),(120,120),(20,120) ->
        // (40,20),(100,20),(120,120),(20,120).
        let matrix = ProjectiveTransform(h00: 0.6, h01: -0.28, h02: 33.6,
            h10: 0, h11: 0.52, h12: 9.6, h20: 0, h21: -0.004, h22: 1.08)
        var pattern: [UInt8] = []
        for y in 0..<100 { for x in 0..<100 {
            pattern.append(contentsOf: [UInt8(x * 2), UInt8(y * 2), UInt8((x + y) % 256), 255])
        } }
        let input = ClipboardImage(width: 100, height: 100, pixels: Data(pattern), origin: .zero)
        func seed(maskedGroup: Bool = false) throws -> (image: Int32, layer: Int32) {
            let image = try session.newImage(width: Int(size.width), height: Int(size.height))
            loose.append(image) // Also owns partial construction on failure.
            let layer = try session.pastePixels(image, pixels: input, at: original.origin)
            var target = layer
            if maskedGroup {
                let outer = try session.createGroup(image: image, index: 0, name: "Preview outer")
                let inner = try session.createGroup(image: image, parent: outer, index: 0, name: "Preview inner")
                try session.reparentLayer(layer, image: image, toParent: inner, index: 0)
                try session.addLayerMask(layer, image: image, source: .grayscale, edit: false)
                target = outer
            }
            try session.selectLayer(target, image: image)
            return (image, target)
        }
        func attach(_ image: Int32, name: String) throws -> ImageDocument {
            let document = try ImageDocument(session: session, image: image, name: name)
            owned.append(document)
            loose.removeAll { $0 == image }
            documents.items.append(document)
            return document
        }
        func state(_ image: Int32) throws -> SourceState {
            let layers = try session.layers(image)
            let masks = try Dictionary(uniqueKeysWithValues: layers.filter(\.hasMask).map {
                ($0.id, try session.layerMask($0.id, image: image))
            })
            return try SourceState(pixels: bytes(session.render(image, scale: 1, area: area)),
                layers: layers, selected: session.selectedLayers(image),
                channels: session.selectedItems(.channel, image: image),
                masks: masks, color: session.colorInfo(image),
                undo: session.undoInfo(image), history: session.history(image), info: session.info(image))
        }
        func request(_ layer: Int32, destination: CanvasDisplayDestination = .srgbFallback,
                     proof: CanvasSoftProof? = nil, maximumEdge: Int = 1536) -> TransformPixelPreview.Request {
            .init(layer: layer, original: original, matrix: matrix, interpolation: .none,
                  imageSize: size, sourceRevision: 0, destination: destination,
                  proof: proof, maximumEdge: maximumEdge)
        }
        func preview(_ document: ImageDocument, _ request: TransformPixelPreview.Request) throws -> CGImage {
            var outcome: Result<CGImage, Error>?
            var callbacks = 0
            document.renderTransformPreview(request) { outcome = $0; callbacks += 1 }
            try wait("preview callback") { outcome != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy }
            try require(callbacks == 1, "Preview completion must fire exactly once")
            return try outcome!.get()
        }
        func matches(_ actual: CGImage, _ expected: CGImage) throws -> Bool {
            try actual.width == expected.width && actual.height == expected.height
                && actual.bytesPerRow == expected.bytesPerRow && bytes(actual) == bytes(expected)
                && (actual.colorSpace?.copyICCData() as Data?) == (expected.colorSpace?.copyICCData() as Data?)
        }
        defer {
            releases.forEach { $0.signal() }
            for document in owned where !document.isClosing { document.closeImageWhenDrained() }
            try? wait("owned documents close") {
                owned.allSatisfy { $0.pendingWork == 0 && (try? session.info($0.image)) == nil }
                    && !EngineActivity.shared.isBusy
            }
            check(owned.allSatisfy { $0.pendingWork == 0 && (try? session.info($0.image)) == nil },
                  "transform preview fixture closes every owned document")
            documents.items.removeAll { document in owned.contains { $0 === document } }
            for image in loose { try? session.closeImage(image) }
            check(loose.allSatisfy { (try? session.info($0)) == nil },
                  "transform preview fixture closes its independent oracle images")
        }

        let source = try seed()
        let document = try attach(source.image, name: "Pixel preview")
        try drain(document)
        let before = try state(source.image)
        let oracle = try seed()
        let oracleBefore = try bytes(session.render(oracle.image, scale: 1, area: area))
        try require(oracleBefore == before.pixels, "Independent source and oracle fixtures must start equal")
        try session.transformLayer(oracle.layer, image: oracle.image, matrix: matrix,
                                   expectedBounds: original, interpolation: .none)
        let expected = try session.render(oracle.image, scale: 1, area: area)
        check(try bytes(expected) != before.pixels, "preview oracle contains an actual visible projective transform")
        let first = try preview(document, request(source.layer))
        check(try matches(first, expected), "full-size pixel preview exactly matches independently committed perspective pixels")
        check(try state(source.image) == before,
              "pixel preview preserves source pixels, layer IDs/tree, selections, dirty state and complete Undo history")
        for repetition in 1...3 {
            let repeated = try preview(document, request(source.layer))
            check(try matches(repeated, expected) && state(source.image) == before,
                  "pixel preview repetition \(repetition) does not accumulate transforms or source edits")
        }
        let affineOracle = try seed()
        let affine = ProjectiveTransform(affine: CGAffineTransform(a: 0.85, b: 0.1, c: -0.05, d: 1, tx: 9, ty: 3))
        try session.transformLayer(affineOracle.layer, image: affineOracle.image, matrix: affine,
                                   expectedBounds: original, interpolation: .linear)
        let affineExpected = try session.render(affineOracle.image, scale: 1, area: area)
        let affinePreview = try preview(document, .init(layer: source.layer, original: original,
            matrix: affine, interpolation: .linear, imageSize: size, sourceRevision: 0))
        check(try matches(affinePreview, affineExpected) && bytes(affineExpected) != before.pixels,
              "affine pixel preview honors linear interpolation and matches an independent native commit")

        guard let displaySpace = CGColorSpace(name: CGColorSpace.displayP3),
              let displayICC = displaySpace.copyICCData() as Data?,
              let destination = CanvasDisplayDestination(validatedWindowICC: displayICC, colorSpaceModel: .rgb),
              let grayICC = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)?.copyICCData() as Data? else {
            throw NSError(domain: "TransformPixelPreviewFixture", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Preview fixture cannot create RGB and grayscale ICC profiles"])
        }
        let expectedDisplay = try session.render(oracle.image, scale: 1, area: area, destinationICC: displayICC)
        let display = try preview(document, request(source.layer, destination: destination))
        check(try matches(display, expectedDisplay) && bytes(expectedDisplay) != bytes(expected),
              "pixel preview converts to the requested display ICC and retains its exact color-space tag")
        let proof = try CanvasSoftProof(profileICC: grayICC, profileName: "Preview grayscale proof",
            proofIntent: .perceptual, blackPointCompensation: true)
        let expectedProof = try session.render(oracle.image, scale: 1, area: area,
                                              destinationICC: displayICC, proof: proof)
        let proofed = try preview(document, request(source.layer, destination: destination, proof: proof))
        check(try matches(proofed, expectedProof) && bytes(expectedProof) != bytes(expectedDisplay),
              "pixel preview preserves the requested soft proof and cannot silently return ordinary display pixels")
        let bounded = try preview(document, request(source.layer, destination: destination, proof: proof, maximumEdge: 96))
        let boundedExpected = try session.render(oracle.image, scale: 0.6,
            area: CGRect(x: 0, y: 0, width: 96, height: 90), destinationICC: displayICC, proof: proof)
        check(try bounded.width == 96 && bounded.height == 90 && matches(bounded, boundedExpected),
              "bounded preview respects the longest-edge cap and exactly matches the scaled native proof oracle")
        let viewportRequest = TransformPixelPreview.Request(layer: source.layer, original: original,
            matrix: matrix, interpolation: .none, imageSize: size, sourceRevision: 0,
            destination: destination, proof: proof, maximumEdge: 4096,
            viewport: CGRect(x: 23.25, y: 17.75, width: 73.5, height: 81.25), displayScale: 2)
        let viewportExpected = try session.render(oracle.image, scale: viewportRequest.renderScale,
            area: viewportRequest.renderArea, destinationICC: displayICC, proof: proof)
        let viewportPreview = try preview(document, viewportRequest)
        check(viewportRequest.renderScale == 2
              && viewportRequest.renderArea == CGRect(x: 46, y: 35, width: 148, height: 163),
              "fractional nonzero viewport rounds outward in 2x display pixels")
        check(try viewportPreview.width == 148 && viewportPreview.height == 163
              && matches(viewportPreview, viewportExpected),
              "viewport preview renders exact native 2x pixels at its offset instead of enlarging a whole-image thumbnail")
        check(try state(source.image) == before,
              "display conversion, proofing and bounded previews leave the native source unchanged")

        // Exercise real native work through the presentation coordinator. A
        // Cancel while the input queue is held must reject its late pixels.
        let cancelHold = DispatchSemaphore(value: 0)
        releases.append(cancelHold)
        document.inputQueue.async { cancelHold.wait() }
        var cancelledFailures: [Error] = []
        var cancelledCallbacks = 0
        let presentation = TransformPixelPreview(render: { request, completion in
            document.renderTransformPreview(request) {
                cancelledCallbacks += 1
                completion($0)
            }
        }, changed: {}, failed: { cancelledFailures.append($0) })
        presentation.update(request(source.layer))
        check(document.pendingWork > 0, "native Cancel fixture has an admitted preview waiting behind input")
        presentation.update(nil)
        cancelHold.signal()
        try drain(document)
        check(try cancelledCallbacks == 1 && cancelledFailures.isEmpty
              && presentation.image == nil && presentation.displayedRequest == nil && !presentation.isPending
              && state(source.image) == before,
              "Cancel discards real late preview pixels, drains its read and preserves source state")

        // A nested group with a nonuniform mask catches flattening or wrong
        // clone-layer correspondence that an ordinary single-layer fixture misses.
        let grouped = try seed(maskedGroup: true)
        let groupedDocument = try attach(grouped.image, name: "Masked group pixel preview")
        try drain(groupedDocument)
        let groupBefore = try state(grouped.image)
        let groupOracle = try seed(maskedGroup: true)
        try require(try bytes(session.render(groupOracle.image, scale: 1, area: area)) == groupBefore.pixels,
                    "Independent masked-group fixtures must start equal")
        try session.transformLayer(groupOracle.layer, image: groupOracle.image, matrix: matrix,
                                   expectedBounds: original, interpolation: .none)
        let groupExpected = try session.render(groupOracle.image, scale: 1, area: area)
        let groupPreview = try preview(groupedDocument, request(grouped.layer))
        check(try bytes(groupExpected) != groupBefore.pixels && matches(groupPreview, groupExpected),
              "masked nested-group preview matches the independent native group transform")
        check(try state(grouped.image) == groupBefore,
              "masked group preview preserves source ancestry, mask ownership, selected IDs and history")

        // Cached admission still sees one selected layer. Fresh native
        // selection must not preview an edit that Apply would refuse.
        if let background = try session.layers(source.image).first(where: { $0.id != source.layer }) {
            try session.selectLayers([source.layer, background.id], image: source.image)
            let multiple = try state(source.image)
            var refused: Result<CGImage, Error>?
            document.renderTransformPreview(request(source.layer)) { refused = $0 }
            try wait("fresh multi-selection refusal") { refused != nil && document.pendingWork == 0 }
            if case .failure? = refused {
                check(try state(source.image) == multiple, "multi-selection preview refuses without pixels, selection or history changes")
            } else { check(false, "multi-selection preview refuses instead of warping only its primary layer") }
            try session.selectLayer(source.layer, image: source.image)
            try document.reload()
        } else { check(false, "multi-selection preview fixture has its independent background layer") }

        // The document cache still reports the original rectangle. Admission
        // must validate the native geometry behind the queue before cloning.
        try session.moveLayer(source.layer, image: source.image, by: CGSize(width: 5, height: 0))
        let moved = try state(source.image)
        var stale: Result<CGImage, Error>?
        document.renderTransformPreview(request(source.layer)) { stale = $0 }
        try wait("stale bounds refusal") { stale != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        var refusedStaleTarget = false
        if case .failure(let error)? = stale,
           case .targetChanged? = error as? ImageDocument.DocumentError { refusedStaleTarget = true }
        check(refusedStaleTarget, "preview refuses a stale expected rectangle despite the document's stale cache")
        check(try state(source.image) == moved, "stale preview refusal leaves the intervening native edit intact")

        let gatedSeed = try seed()
        let gated = try attach(gatedSeed.image, name: "Deferred target refresh")
        try drain(gated)
        guard let background = gated.layers.first(where: { $0.id != gatedSeed.layer }) else {
            throw ImageDocument.DocumentError.noLayer
        }
        EngineActivity.shared.beginTransformPreview()
        var gateHeld = true
        defer { if gateHeld { EngineActivity.shared.endTransformPreview() } }
        var acknowledged: Result<ImageDocument.MoveSelectionOwnership, Error>?
        var acknowledgedSelection: [Int32] = []
        gated.selectMoveHit(background, expected: gated.floatingState, revision: gated.moveTargetRevision) {
            acknowledged = $0
            acknowledgedSelection = gated.selectedLayerIDs
        }
        var targetWorkerFinished = false
        gated.inputQueue.async { DispatchQueue.main.async { targetWorkerFinished = true } }
        try wait("target worker before deferred native refresh") { targetWorkerFinished }
        check(acknowledged == nil && gated.pendingWork > 0,
              "target selection waits for reconciled caches and retains close ownership behind the preview gate")
        var gatedClosed = false
        gated.closeImageWhenDrained { gatedClosed = true }
        check(!gatedClosed, "close cannot overtake a deferred target refresh")
        gateHeld = false
        EngineActivity.shared.endTransformPreview()
        try wait("gated target refresh and close") { gatedClosed && gated.pendingWork == 0 }
        var acceptedAcknowledgement = false
        if case .success? = acknowledged { acceptedAcknowledgement = true }
        check(acceptedAcknowledgement && acknowledgedSelection == [background.id]
              && (try? session.info(gated.image)) == nil,
              "deferred target acknowledgement sees reconciled caches before close releases every lifetime hold")

        let croppedSeed = try seed()
        let cropped = try attach(croppedSeed.image, name: "Ordered selection crop")
        try drain(cropped)
        let cropHold = DispatchSemaphore(value: 0)
        releases.append(cropHold)
        cropped.inputQueue.async { cropHold.wait() }
        let cropBounds = CGRect(x: 10, y: 15, width: 70, height: 60)
        cropped.select(.rectangle(cropBounds), options: .init())
        cropped.cropToSelection()
        cropped.select(.rectangle(CGRect(x: 1, y: 1, width: 5, height: 5)), options: .init())
        cropHold.signal()
        try drain(cropped)
        check(cropped.info.width == 70 && cropped.info.height == 60,
              "Crop to Selection resolves behind earlier selection input and before a later selection")

        // A counted read already admitted ahead of close must keep the source
        // alive until its callback and private clone work have drained.
        let closingSeed = try seed()
        let closing = try attach(closingSeed.image, name: "Close queued pixel preview")
        try drain(closing)
        let hold = DispatchSemaphore(value: 0)
        releases.append(hold)
        closing.inputQueue.async { hold.wait() }
        var closeResult: Result<CGImage, Error>?
        var closeCallbacks = 0
        var events: [String] = []
        closing.renderTransformPreview(request(closingSeed.layer)) {
            closeResult = $0; closeCallbacks += 1; events.append("preview")
        }
        check(closing.pendingWork > 0, "queued transform preview is counted as document work")
        var closed = false
        closing.closeImageWhenDrained { closed = true; events.append("close") }
        check(!closed && (try? session.info(closing.image)) != nil,
              "close waits while an admitted preview is held behind input")
        hold.signal()
        try wait("queued preview and close") { closed && closing.pendingWork == 0 && !EngineActivity.shared.isBusy }
        check(closeCallbacks == 1 && events == ["preview", "close"] && (try? session.info(closing.image)) == nil,
              "queued preview completes once before the source closes and leaves no pending read")
        var refusedClosedOwner = false
        if case .failure(let error)? = closeResult,
           case .closed? = error as? ImageDocument.DocumentError { refusedClosedOwner = true }
        check(refusedClosedOwner, "an admitted preview drains but returns a closed-owner refusal instead of late pixels")
        var late: Result<CGImage, Error>?
        closing.renderTransformPreview(request(closingSeed.layer)) { late = $0 }
        try wait("closed document refuses late preview") { late != nil }
        var refusedLateRead = false
        if case .failure(let error)? = late,
           case .closed? = error as? ImageDocument.DocumentError { refusedLateRead = true }
        check(refusedLateRead && closing.pendingWork == 0,
              "a late preview on a closed document refuses without scheduling native work")

        try measureTransformPixelPreview24MP(session, documents: documents)
    }

    /// Optional characterization of real 24 MP native work. Routine fixture
    /// matrices do not create this image unless GLIMS_PREVIEW_PERF=1 is set.
    /// The timed interval includes clone creation, transform, viewport render,
    /// clone destruction and callback drain, but excludes fixture construction.
    static func measureTransformPixelPreview24MP(_ session: EngineSession, documents: DocumentList) throws {
        guard ProcessInfo.processInfo.environment["GLIMS_PREVIEW_PERF"] == "1" else { return }
        func wait(_ description: String, _ condition: () -> Bool) throws {
            let deadline = Date().addingTimeInterval(60)
            while !condition() && Date() < deadline { spin(0.005) }
            guard condition() else {
                throw NSError(domain: "TransformPixelPreviewPerformance", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Timed out: \(description)"])
            }
        }
        let image = try session.newImage(width: 6000, height: 4000)
        var owner: ImageDocument?
        var heartbeat: Timer?
        defer {
            heartbeat?.invalidate()
            if let owner {
                if !owner.isClosing { owner.closeImageWhenDrained() }
                try? wait("24 MP document close") {
                    owner.pendingWork == 0 && !EngineActivity.shared.isBusy && (try? session.info(image)) == nil
                }
                documents.items.removeAll { $0 === owner }
            } else {
                try? session.closeImage(image)
            }
            check((try? session.info(image)) == nil, "24 MP preview timing closes its owned image")
        }
        guard let layer = try session.layers(image).first else {
            throw NSError(domain: "TransformPixelPreviewPerformance", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "24 MP image has no ordinary layer"])
        }
        // Native fills make a nonuniform 24 MP source without allocating a
        // 96 MB Swift pixel array or a per-pixel append loop.
        try session.selectLayer(layer.id, image: image)
        try session.fill(image: image, at: .zero, mode: .selection,
                         color: NSColor(srgbRed: 0.1, green: 0.3, blue: 0.7, alpha: 1))
        try session.select(.rectangle(CGRect(x: 2400, y: 1600, width: 1200, height: 800)), image: image)
        try session.fill(image: image, at: CGPoint(x: 2600, y: 1800), mode: .selection,
                         color: NSColor(srgbRed: 0.9, green: 0.5, blue: 0.1, alpha: 1))
        try session.select(.none, image: image)
        let document = try ImageDocument(session: session, image: image, name: "24 MP preview timing")
        owner = document
        documents.items.append(document)
        try wait("24 MP fixture setup") { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        let viewport = CGRect(x: 2200, y: 1450, width: 800, height: 600)
        guard let originalViewport = try session.render(image, scale: 1, area: viewport).dataProvider?.data as Data?,
              originalViewport.count == 800 * 600 * 4 else {
            throw NSError(domain: "TransformPixelPreviewPerformance", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "24 MP source viewport has no complete pixel buffer"])
        }
        let beforeInfo = try session.info(image), beforeLayers = try session.layers(image)
        let beforeHistory = try session.history(image), beforeUndo = try session.undoInfo(image)
        let beforeSelected = try session.selectedLayers(image)
        let transforms: [(String, ProjectiveTransform)] = [
            ("affine", ProjectiveTransform(affine: CGAffineTransform(a: 0.98, b: 0.01, c: -0.01, d: 0.98, tx: 40, ty: 30))),
            ("projective", ProjectiveTransform(h00: 1, h01: 0, h02: 0,
                h10: 0, h11: 1, h12: 0, h20: 0, h21: 0.00001, h22: 1))
        ]
        for (name, matrix) in transforms {
            let request = TransformPixelPreview.Request(layer: layer.id, original: layer.bounds,
                matrix: matrix, interpolation: .linear, imageSize: CGSize(width: 6000, height: 4000),
                sourceRevision: 0, maximumEdge: 4096, viewport: viewport, displayScale: 1)
            var outcome: Result<CGImage, Error>?
            var callbacks = 0
            var ticks = 0
            var worstLateness = 0.0
            let interval = 0.010
            var lastTick = DispatchTime.now()
            let timer = Timer(timeInterval: interval, repeats: true) { _ in
                let now = DispatchTime.now()
                let gap = Double(now.uptimeNanoseconds - lastTick.uptimeNanoseconds) / 1e6
                worstLateness = max(worstLateness, gap - interval * 1000)
                lastTick = now
                ticks += 1
            }
            heartbeat = timer
            RunLoop.main.add(timer, forMode: .common)
            let started = DispatchTime.now()
            document.renderTransformPreview(request) { outcome = $0; callbacks += 1 }
            try wait("24 MP \(name) preview") {
                outcome != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy
            }
            let finished = DispatchTime.now()
            // Include a blocked final callback even if the timer has not yet
            // fired again when the completion condition becomes true.
            let finalGap = Double(finished.uptimeNanoseconds - lastTick.uptimeNanoseconds) / 1e6
            worstLateness = max(worstLateness, finalGap - interval * 1000)
            timer.invalidate()
            heartbeat = nil
            let elapsed = Double(finished.uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
            let elapsedText = String(format: "%.1f", elapsed)
            let latenessText = String(format: "%.1f", worstLateness)
            print("     24 MP \(name) preview: \(elapsedText) ms; viewport 800x600 at 1x; main-thread lateness \(latenessText) ms; \(ticks) heartbeat ticks")
            guard let outcome else {
                throw NSError(domain: "TransformPixelPreviewPerformance", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "24 MP preview callback missing"])
            }
            let pixels = try outcome.get()
            let rendered = pixels.dataProvider?.data as Data?
            check(callbacks == 1 && pixels.width == 800 && pixels.height == 600
                  && rendered?.count == 800 * 600 * 4 && rendered != originalViewport,
                  "24 MP \(name) preview returns a changed viewport exactly once")
            check((ticks > 0 || elapsed < interval * 1000)
                  && worstLateness < maximumMainThreadStallMilliseconds,
                  "24 MP \(name) preview keeps the main loop within the existing \(Int(maximumMainThreadStallMilliseconds)) ms stall limit")
        }
        let afterViewport = try session.render(image, scale: 1, area: viewport).dataProvider?.data as Data?
        check(try afterViewport == originalViewport && session.info(image) == beforeInfo
              && session.layers(image) == beforeLayers && session.history(image) == beforeHistory
              && session.undoInfo(image) == beforeUndo && session.selectedLayers(image) == beforeSelected,
              "24 MP preview measurements preserve source viewport pixels, layer tree, selection and Undo history")
    }
}
