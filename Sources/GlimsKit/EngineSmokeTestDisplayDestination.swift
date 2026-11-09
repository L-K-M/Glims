import AppKit

// MARK: - GLIMS_SMOKE_CASE=display-destination

/// A window whose backing density the test controls; its `colorSpace` is
/// set explicitly so the window has a known, distinct destination profile.
private final class DestinationWindow: NSWindow {
    var simulatedBackingFactor: CGFloat = 1
    override var backingScaleFactor: CGFloat { simulatedBackingFactor }
}

@MainActor
extension EngineSmokeTest {
    /// `GLIMS_SMOKE_CASE=display-destination` (the shared dispatcher wires
    /// this case in): the canvas's actual-window SDR destination-ICC render
    /// path. Two real NSWindows carry explicit, different backing color
    /// spaces (Display P3 and sRGB); every destination comes from the owning
    /// window's own `colorSpace`, never from a global screen. Checks what
    /// each assertion proves in the docs (docs/canvas-display-destination.md):
    /// owning-window snapshot, exact cached CGImage ICC tag, completed-tile
    /// invalidation and stale in-flight rejection on an ICC change at
    /// unchanged density, same-ICC density-change preservation, two-window
    /// independence, explicit sRGB fallback (detached and unusable window
    /// color space), read-only pixels/history/dirty, and close/drain.
    /// Physical monitor/LUT/HDR accuracy is explicitly unproved here.
    static func exerciseDisplayDestination(_ session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        _ = work
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
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
        let imageA = try session.newImage(width: 300, height: 200)
        let imageB = try session.newImage(width: 220, height: 160)
        let docA = try ImageDocument(session: session, image: imageA, name: "Destination A")
        let docB = try ImageDocument(session: session, image: imageB, name: "Destination B")
        documents.items += [docA, docB]
        func attach(_ document: ImageDocument, _ space: NSColorSpace) -> (DestinationWindow, EngineCanvasView) {
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
            return (window, canvas)
        }
        let (windowA, canvasA) = attach(docA, p3)
        let (windowB, canvasB) = attach(docB, srgb)
        check((windowA.colorSpace?.iccProfileData as Data?) == p3ICC
                && (windowB.colorSpace?.iccProfileData as Data?) == srgbICC,
              "both windows carry their explicit backing color spaces")
        check(canvasA.destination.kind == .windowProfile && canvasA.destination.icc == p3ICC,
              "window A snapshots its own owning-window P3 backing ICC bytes, not a global screen")
        check(canvasB.destination.kind == .windowProfile && canvasB.destination.icc == srgbICC
                && canvasB.destination != canvasA.destination,
              "window B snapshots its own sRGB window; the two destinations are independent")

        let pixelsBefore = try session.copyPixels(imageA, merged: true).pixels
        let undoBefore = docA.undoInfo.undoCount
        let dirtyBefore = docA.hasUnsavedChanges

        try canvasA.renderVisibleTilesNow()
        try canvasB.renderVisibleTilesNow()
        check(canvasA.renderedTileCount > 0 && canvasB.renderedTileCount > 0,
              "both windows render visible tiles through the destination path")
        check(canvasA.cachedTileICCData() == iccTag(p3ICC) && canvasA.cachedTileICCData() != iccTag(srgbICC),
              "A's cached CGImages carry the exact P3 destination tag, not the sRGB fallback tag")
        check(canvasB.cachedTileICCData() == iccTag(srgbICC),
              "B's cached CGImages carry the exact sRGB window tag")

        // ICC change at unchanged backing density, with one render in flight
        // under the old profile: the completed cache clears synchronously,
        // the old-generation result is discarded on arrival, and fresh tiles
        // render into the new destination.
        canvasA.imageDidChange(in: nil)
        canvasA.setNeedsRender()
        windowA.colorSpace = srgb
        canvasA.viewDidChangeBackingProperties()
        check(canvasA.destination.icc == srgbICC && canvasA.renderedTileCount == 0
                && canvasA.zoomPercent == 100 && canvasA.scale == 1,
              "an ICC change at unchanged density clears all completed tiles and keeps zoom/center")
        wait { canvasA.renderedTileCount > 0 }
        check(canvasA.cachedTileICCData() == iccTag(srgbICC),
              "the stale in-flight old-profile result never repopulates the cache; new tiles use the new ICC")

        // Same-ICC density change: cache, zoom and center semantics retained.
        let countAtDensity = canvasA.renderedTileCount
        windowA.simulatedBackingFactor = 2
        canvasA.viewDidChangeBackingProperties()
        check(canvasA.renderedTileCount == countAtDensity && canvasA.destination.icc == srgbICC
                && canvasA.zoomPercent == 100 && canvasA.scale == 0.5,
              "a same-ICC density change retains the cache and preserves center/zoom semantics")
        windowA.simulatedBackingFactor = 1
        canvasA.viewDidChangeBackingProperties()
        check(canvasB.destination.icc == srgbICC && canvasB.renderedTileCount > 0,
              "window B keeps its own destination and cache through A's profile and density changes")

        // Detached canvas: explicit sRGB fallback with the real sRGB tag.
        let imageC = try session.newImage(width: 120, height: 90)
        let docC = try ImageDocument(session: session, image: imageC, name: "Destination C")
        documents.items.append(docC)
        let canvasC = EngineCanvasView(document: docC)
        canvasC.frame = NSRect(x: 0, y: 0, width: 300, height: 220)
        check(canvasC.destination == .srgbFallback, "a detached canvas takes the explicit sRGB fallback")
        try canvasC.renderVisibleTilesNow()
        check(canvasC.renderedTileCount > 0 && canvasC.cachedTileICCData() == iccTag(srgbICC),
              "the detached fallback renders with the real sRGB CGImage tag, not a guessed profile")

        // A window whose backing color space is unusable is never overridden
        // with a guessed monitor profile.
        windowA.colorSpace = nil
        canvasA.viewDidChangeBackingProperties()
        check(canvasA.destination == .srgbFallback,
              "an unusable window colorSpace falls back to explicit sRGB, never a guessed monitor profile")
        windowA.colorSpace = p3
        canvasA.viewDidChangeBackingProperties()
        check(canvasA.destination.icc == p3ICC && canvasA.renderedTileCount == 0,
              "restoring a usable window profile re-snapshots and invalidates the cache again")

        check(try session.copyPixels(imageA, merged: true).pixels == pixelsBefore
                && docA.undoInfo.undoCount == undoBefore && docA.hasUnsavedChanges == dirtyBefore,
              "all destination renders and profile changes are read-only: no pixel, history or dirty change")

        canvasA.removeFromSuperview()
        check(canvasA.destination == .srgbFallback,
              "detaching the view from its window switches to the safe sRGB fallback and drops observers")
        for (canvas, document) in [(canvasA, docA), (canvasB, docB), (canvasC, docC)] {
            var closed = false
            canvas.stopRendering { document.closeImageWhenDrained { closed = true } }
            wait { closed }
            check(closed, "a window with a destination profile drains and closes safely")
        }
        windowA.close()
        windowB.close()
        documents.items.removeAll { $0 === docA || $0 === docB || $0 === docC }
    }
}
