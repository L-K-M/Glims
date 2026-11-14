import AppKit

// MARK: - GLIMS_SMOKE_CASE=display-destination

/// A window whose backing density the test controls; its `colorSpace` is
/// set explicitly so the window has a known, distinct destination profile.
private final class DestinationWindow: NSWindow {
    var simulatedBackingFactor: CGFloat = 1
    override var backingScaleFactor: CGFloat { simulatedBackingFactor }
}

/// A flag the render-queue barriers mark from a `DispatchQueue.main.async`
/// callback. NSLock-guarded, so no unchecked shared mutable state crosses
/// threads; condition-polled on main, a marked callback is the proof that
/// the barrier was entered (never a fixed sleep).
private final class MainFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var marked = false
    func mark() { lock.lock(); marked = true; lock.unlock() }
    var isMarked: Bool { lock.lock(); defer { lock.unlock() }; return marked }
}

@MainActor
extension EngineSmokeTest {
    /// `GLIMS_SMOKE_CASE=display-destination` (the shared dispatcher wires
    /// this case in): the canvas's actual-window SDR destination-ICC render
    /// path. Two real NSWindows carry explicit, different backing color
    /// spaces (Display P3 and sRGB); every destination comes from the owning
    /// window's own `colorSpace`, never from a global screen. Checks what
    /// each assertion proves in the docs (docs/canvas-display-destination.md):
    /// owning-window snapshot, exact cached CGImage ICC tag, deterministic
    /// stale in-flight rejection on an ICC change at unchanged density (two
    /// render-queue gates with Main-delivered entered callbacks), same-ICC
    /// density-change center preservation, two-window independence, explicit
    /// sRGB fallback (detached and unusable window color space), fresh native
    /// read-only pixels/history/dirty, and guaranteed drain/close teardown.
    /// Physical monitor/LUT/HDR accuracy is explicitly unproved here.
    static func exerciseDisplayDestination(_ session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        _ = work
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
            return condition()
        }
        // The two queue gates and the owned-fixture tracking are installed up
        // front. The defer signals BOTH gates unconditionally FIRST — before
        // any drain/close — so a thrown check or early return can never
        // strand a barrier on the serial render queue; it then owns all
        // teardown (no duplicate normal-path cleanup below).
        let gate1 = DispatchSemaphore(value: 0)
        let gate2 = DispatchSemaphore(value: 0)
        var ownedCanvases: [EngineCanvasView] = []
        var ownedWindows: [NSWindow] = []
        var ownedDocs: [ImageDocument] = []
        defer {
            gate1.signal()
            gate2.signal()
            for canvas in ownedCanvases {
                var drained = false
                canvas.stopRendering { drained = true }
                wait { drained }
            }
            for document in ownedDocs where !document.isClosing {
                var closed = false
                document.closeImageWhenDrained { closed = true }
                wait { closed }
            }
            for window in ownedWindows { window.close() }
            documents.items.removeAll { doc in ownedDocs.contains { $0 === doc } }
        }
        let p3 = NSColorSpace(cgColorSpace: CGColorSpace(name: CGColorSpace.displayP3)!)!
        let srgb = NSColorSpace.sRGB
        guard let p3ICC = p3.iccProfileData as Data?, let srgbICC = srgb.iccProfileData as Data?,
              p3ICC != srgbICC else {
            return check(false, "the two fixture color spaces carry distinct RGB ICC data")
        }
        // The tag the wrapper puts on a CGImage built from ICC bytes.
        func iccTag(_ icc: Data) -> Data? {
            guard let space = CGColorSpace(iccData: icc as CFData) else { return nil }
            return space.copyICCData() as Data?
        }
        func newDocument(width: Int, height: Int, name: String) throws -> ImageDocument {
            let image = try session.newImage(width: width, height: height)
            do {
                let document = try ImageDocument(session: session, image: image, name: name)
                ownedDocs.append(document)
                documents.items.append(document)
                return document
            } catch {
                try? session.closeImage(image)
                throw error
            }
        }
        let docA = try newDocument(width: 1200, height: 900, name: "Destination A")
        let docB = try newDocument(width: 220, height: 160, name: "Destination B")
        let imageA = docA.image
        // Baseline precedes attachment, which starts automatic rendering.
        let infoBefore = try session.info(imageA)
        let undoBefore = try session.undoInfo(imageA)
        let pixelsBefore = try session.copyPixels(imageA, merged: true).pixels
        func attach(_ document: ImageDocument, _ space: NSColorSpace) -> (DestinationWindow, NSScrollView, EngineCanvasView) {
            let window = DestinationWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 320),
                                           styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.colorSpace = space
            let canvas = EngineCanvasView(document: document)
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 320))
            scroll.contentView = CanvasClipView()
            scroll.documentView = canvas
            window.contentView = scroll
            window.contentView?.layoutSubtreeIfNeeded()
            canvas.viewDidMoveToWindow()
            ownedWindows.append(window)
            ownedCanvases.append(canvas)
            return (window, scroll, canvas)
        }
        let (windowA, scrollA, canvasA) = attach(docA, p3)
        let (windowB, _, canvasB) = attach(docB, srgb)
        check(canvasA.isAccessibilityElement() && canvasA.accessibilityRole() == .image &&
              canvasA.accessibilityLabel() == "Image canvas",
              "the image canvas is exposed with a meaningful accessibility identity")
        check(canvasA.acceptsFirstResponder && windowA.makeFirstResponder(canvasA) &&
              windowA.firstResponder === canvasA,
              "the accessible canvas continues to accept keyboard focus")
        check((windowA.colorSpace?.iccProfileData as Data?) == p3ICC
                && (windowB.colorSpace?.iccProfileData as Data?) == srgbICC,
              "both windows carry their explicit backing color spaces")
        check(canvasA.destination.kind == .windowProfile && canvasA.destination.icc == p3ICC,
              "window A snapshots its own owning-window P3 backing ICC bytes, not a global screen")
        check(canvasB.destination.kind == .windowProfile && canvasB.destination.icc == srgbICC
                && canvasB.destination != canvasA.destination,
              "window B snapshots its own sRGB window; the two destinations are independent")

        try canvasA.renderVisibleTilesNow()
        try canvasB.renderVisibleTilesNow()
        check(canvasA.renderedTileCount > 0 && canvasB.renderedTileCount > 0,
              "both windows render visible tiles through the destination path")
        check(canvasA.cachedTileICCData() == iccTag(p3ICC) && canvasA.cachedTileICCData() != iccTag(srgbICC),
              "A's cached CGImages carry the exact P3 destination tag, not the sRGB fallback tag")
        check(canvasB.cachedTileICCData() == iccTag(srgbICC),
              "B's cached CGImages carry the exact sRGB window tag")
        // Fully settle the initial automatic rendering, so no unrelated old
        // queued result can contaminate the gated proof below.
        check(wait { canvasA.renderedTileCount > 0 && !canvasA.hasPendingRender
                        && canvasB.renderedTileCount > 0 && !canvasB.hasPendingRender },
              "initial automatic rendering fully settles with no render in flight on either window")

        // Deterministic old-profile rejection at unchanged density. gate1
        // blocks the serial render queue; the old-profile (P3) tile request
        // is value-captured and queued behind gate1; gate2 is queued after
        // that request, so no fresh request can execute until it opens.
        let entered1 = MainFlag()
        canvasA.enqueueRenderBarrier {
            DispatchQueue.main.async { entered1.mark() }
            gate1.wait()
        }
        check(wait { entered1.isMarked }, "gate1's entered callback is delivered on Main")
        canvasA.imageDidChange(in: nil)
        canvasA.setNeedsRender()
        check(canvasA.hasPendingRender,
              "the old-profile tile request is value-captured and pending behind gate1")
        let entered2 = MainFlag()
        canvasA.enqueueRenderBarrier {
            DispatchQueue.main.async { entered2.mark() }
            gate2.wait()
        }
        // Switch the actual owning window to profile B while the old request
        // is still queued and gate1 remains closed.
        windowA.colorSpace = srgb
        canvasA.viewDidChangeBackingProperties()
        check(canvasA.destination.kind == .windowProfile && canvasA.destination.icc == srgbICC
                && canvasA.renderedTileCount == 0 && canvasA.zoomPercent == 100 && canvasA.scale == 1,
              "the window switch re-snapshots B and synchronously clears the completed cache, keeping zoom")
        gate1.signal()
        // The old render executes, then its completion is enqueued to Main;
        // only then does the serial queue reach gate2, whose entered callback
        // is enqueued to Main AFTER that completion — so entered2 proves the
        // old completion already ran on Main while fresh work is blocked.
        check(wait { entered2.isMarked },
              "gate2 is entered only after the old-profile completion ran on Main")
        check(canvasA.renderedTileCount == 0 && canvasA.destination.icc == srgbICC
                && canvasA.hasPendingRender,
              "the stale old-profile result never repopulates the cache; a fresh request is pending behind gate2")
        gate2.signal()
        check(wait { canvasA.renderedTileCount > 0 && !canvasA.hasPendingRender },
              "fresh tiles complete once gate2 opens")
        check(canvasA.cachedTileICCData() == iccTag(srgbICC),
              "the fresh tiles carry the exact new destination ICC tag, not the old profile")

        // Center/density: a genuinely nonzero viewport offset on the
        // 1200x900 image in the 400x320 viewport, then a simulated backing
        // density change 1 -> 2 at unchanged ICC.
        let clipA = scrollA.contentView
        clipA.bounds.origin = CGPoint(x: 400, y: 300)
        let viewport = clipA.bounds
        check(abs(viewport.origin.x - 400) < 0.5 && abs(viewport.origin.y - 300) < 0.5
                && abs(viewport.size.width - 400) < 0.5 && abs(viewport.size.height - 320) < 0.5,
              "the viewport offset (400,300) is established, not clamped or a no-op")
        check(wait { !canvasA.hasPendingRender }, "rendering settles at the new viewport offset")
        let centerBefore = CanvasGeometry.imageCenter(scrollOffset: viewport.origin, viewportSize: viewport.size,
                                                      zoomPercent: canvasA.zoomPercent,
                                                      backingFactor: Double(windowA.simulatedBackingFactor))
        check(abs(centerBefore.x - 600) < 1 && abs(centerBefore.y - 460) < 1,
              "the image-space center at viewport (400,300) in a 400x320 viewport is about (600,460)")
        let countAtDensity = canvasA.renderedTileCount
        let iccAtDensity = canvasA.cachedTileICCData()
        windowA.simulatedBackingFactor = 2
        canvasA.viewDidChangeBackingProperties()
        let viewportAfter = clipA.bounds
        let centerAfter = CanvasGeometry.imageCenter(scrollOffset: viewportAfter.origin,
                                                     viewportSize: viewportAfter.size,
                                                     zoomPercent: canvasA.zoomPercent,
                                                     backingFactor: Double(windowA.simulatedBackingFactor))
        check(abs(centerAfter.x - centerBefore.x) <= 1 && abs(centerAfter.y - centerBefore.y) <= 1
                && viewportAfter.origin != viewport.origin
                && canvasA.zoomPercent == 100 && canvasA.scale == 0.5
                && canvasA.renderedTileCount == countAtDensity
                && canvasA.cachedTileICCData() == iccAtDensity,
              "backing density 1->2 preserves the image-space center, zoom 100, the cache and its same ICC tag")
        windowA.simulatedBackingFactor = 1
        canvasA.viewDidChangeBackingProperties()
        check(canvasB.destination.icc == srgbICC && canvasB.renderedTileCount > 0,
              "window B keeps its own destination and cache through A's profile and density changes")

        // Detached canvas: explicit sRGB fallback with the real sRGB tag.
        let docC = try newDocument(width: 120, height: 90, name: "Destination C")
        let canvasC = EngineCanvasView(document: docC)
        ownedCanvases.append(canvasC)
        canvasC.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
        check(canvasC.destination == .srgbFallback, "a detached canvas takes the explicit sRGB fallback")
        try canvasC.renderVisibleTilesNow()
        check(canvasC.renderedTileCount > 0 && canvasC.cachedTileICCData() == iccTag(srgbICC),
              "the detached fallback renders with the real sRGB CGImage tag, not a guessed profile")

        // AppKit may resolve a nil assignment to the screen's actual color
        // space. Follow the getter's result rather than assuming nil means
        // the window has no usable destination.
        windowA.colorSpace = nil
        canvasA.viewDidChangeBackingProperties()
        check(canvasA.destination == CanvasDisplayDestination.snapshot(window: windowA),
              "resetting the window color space follows AppKit's actual getter result")
        windowA.colorSpace = .genericGray
        canvasA.viewDidChangeBackingProperties()
        check(windowA.colorSpace?.cgColorSpace?.model == .monochrome && canvasA.destination == .srgbFallback,
              "a non-RGB owning-window profile takes the explicit sRGB fallback")
        windowA.colorSpace = p3
        canvasA.viewDidChangeBackingProperties()
        check(canvasA.destination.icc == p3ICC && canvasA.renderedTileCount == 0,
              "restoring a usable window profile re-snapshots and invalidates the cache again")
        check(wait { !canvasA.hasPendingRender && canvasA.renderedTileCount > 0
                        && !canvasB.hasPendingRender && !canvasC.hasPendingRender },
              "all canvas requests settle before the final native read-only comparison")

        // Fresh native read-only proof: re-read the engine APIs now and
        // compare pixels, undo/redo counts and the native dirty flag.
        let infoAfter = try session.info(imageA)
        let undoAfter = try session.undoInfo(imageA)
        let pixelsAfter = try session.copyPixels(imageA, merged: true).pixels
        check(infoAfter == infoBefore && undoAfter == undoBefore && pixelsAfter == pixelsBefore,
              "fresh native reads agree: rendering changed no pixel, undo/redo count or dirty flag")

        canvasA.removeFromSuperview()
        check(canvasA.destination == .srgbFallback,
              "detaching the view from its window switches to the safe sRGB fallback and drops observers")
        // Teardown (drain, close, remove) is owned solely by the defer above.
    }
}
