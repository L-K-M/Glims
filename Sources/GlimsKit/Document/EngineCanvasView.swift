import AppKit

/// The document canvas: shows the engine's composited image at the current
/// zoom and turns pointer input into paint strokes.
///
/// A zoom percent counts physical pixels: at 100% one image pixel is one
/// device pixel on any screen. The render scale is the percent alone,
/// while pointer input, layout and overlays use `scale`, which also
/// divides by the window's backing factor.
///
/// The image is drawn from a cache of square tiles in device pixels. Missing
/// or stale visible tiles are rendered one at a time on a background queue,
/// nearest the viewport centre first, and each is drawn as soon as it
/// arrives. A large image therefore appears progressively, as in GIMP's own
/// display, and panning shows cached tiles at once while new ones fill in.
@MainActor
final class EngineCanvasView: NSView {
    var surroundColor = EditorPreferences.shared.surround.color {
        didSet { needsDisplay = true }
    }
    /// Transparent pixels show over light checks (GIMP's "Light checks"),
    /// so they read apart from the surround and from tiles still rendering,
    /// which stay the surround's gray.
    static let transparencyChecks: NSColor = {
        let check: CGFloat = 8
        let pattern = NSImage(size: NSSize(width: check * 2, height: check * 2), flipped: false) { rect in
            NSColor(calibratedWhite: 1, alpha: 1).setFill()
            rect.fill()
            NSColor(calibratedWhite: 0.8, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: check, height: check).fill()
            NSRect(x: check, y: check, width: check, height: check).fill()
            return true
        }
        return NSColor(patternImage: pattern)
    }()
    /// Tile edge in device pixels.
    static let tileSize = 256
    /// Cached tiles kept across panning (about 64 MB of pixels).
    static let maximumCachedTiles = 256

    private struct TileKey: Hashable {
        let column: Int
        let row: Int
    }

    let document: ImageDocument
    private let renderQueue = DispatchQueue(label: "ch.lkmc.Glims.canvas.render", qos: .userInteractive)

    private(set) var zoomPercent = ZoomLadder.actualPixels
    private var tiles: [TileKey: CGImage] = [:]
    var renderedTileCount: Int { tiles.count }
    private(set) var renderMetrics = CanvasRenderMetrics()
    /// The owning controller installs a weak capture. Published only from
    /// accepted tile/cache changes on the main actor.
    var onRenderMetricsChange: ((CanvasRenderMetrics) -> Void)?
    private var staleTiles: Set<TileKey> = []
    private var failedTiles: Set<TileKey> = []
    private var renderingStopped = false
    private var renderInFlight = false
    /// Bumped on zoom changes; results of an older generation are dropped.
    private var generation = 0
    /// The current display destination: an immutable main-actor snapshot of
    /// the owning window's actual backing color space, refreshed on window,
    /// backing and screen-profile changes. Read-only seam for tests.
    private(set) var destination = CanvasDisplayDestination.srgbFallback
    private(set) var softProof: CanvasSoftProof?
    private var transformSourceRevision: UInt64 = 0
    private lazy var transformPixels = TransformPixelPreview(render: { [weak self] request, completion in
        guard let self else { return completion(.failure(ImageDocument.DocumentError.closed)) }
        self.document.renderTransformPreview(request, completion: completion)
    }, changed: { [weak self] in self?.needsDisplay = true }, failed: { [weak self] error in
        self?.tools.onStatus?("Transform preview unavailable: \(error.localizedDescription)")
    })
    var transformPreviewImage: CGImage? { transformPixels.image }
    var transformPreviewRequest: TransformPixelPreview.Request? { transformPixels.displayedRequest }
    var transformPreviewIsPending: Bool { transformPixels.isPending }
    private var inkLevelsPreviewToken: UInt64?
    private var inkLevelsPreviewSettings = EngineSession.InkLevelsSettings()
    var onInkLevelsPreviewChange: ((Bool, String?) -> Void)?
    private lazy var inkLevelsPixels: InkLevelsPixelPreview = InkLevelsPixelPreview(render: { [weak self] request, completion in
        guard let self else { return completion(.failure(ImageDocument.DocumentError.closed)) }
        self.document.renderInkLevelsPreview(request, completion: completion)
    }, changed: { [weak self] in
        guard let self else { return }
        self.needsDisplay = true
        self.onInkLevelsPreviewChange?(self.inkLevelsPixels.isCurrent, nil)
    }, failed: { [weak self] error in
        self?.onInkLevelsPreviewChange?(false, error.localizedDescription)
    })
    var inkLevelsPreviewImage: CGImage? { inkLevelsPixels.image }
    var inkLevelsPreviewIsCurrent: Bool { inkLevelsPixels.isCurrent }
    /// Destination observer tokens for the owning window and its associated
    /// screen; swapped on window changes and removed on detach/close. The
    /// blocks hold `self` weakly, so no observer retain cycle.
    private var destinationObservers: [NSObjectProtocol] = []

    /// The current tool's handling of pointer and key events.
    private(set) lazy var tools = CanvasToolController(canvas: self)
    private var hintLifecycleObservers: [NSObjectProtocol] = []

    deinit {
        for token in hintLifecycleObservers { NotificationCenter.default.removeObserver(token) }
    }

    /// This window's guide-drag gesture (ruler-created and Move-tool),
    /// view-only until the release commits exactly one guide action.
    private(set) lazy var guideDrag = GuideDragController(canvas: self)

    /// Trackpad pinch: publishes a new integer zoom percent, anchored at
    /// the event's window point. Set by the owning window controller,
    /// whose closure captures the controller weakly.
    var onTrackpadZoom: ((Int, CGPoint) -> Void)?
    /// Trackpad rotate: applies an absolute view rotation in canvas
    /// degrees (positive = clockwise, the flipped canvas's positive
    /// frameRotation), anchored the same way.
    var onTrackpadRotate: ((Double, CGPoint) -> Void)?
    /// The controller owns the exact view angle. NSView.frameRotation's
    /// getter rounds through AppKit's affine representation, which must
    /// not accumulate into the next relative gesture message.
    var trackpadRotationDegrees: (() -> Double)?
    /// One pinch gesture's fractional zoom; rebased on .began and whenever
    /// the view's integer zoom changed outside the gesture.
    private var zoomGesture = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: ZoomLadder.actualPixels)
    /// Option-scroll zoom's own fractional zoom accumulator.
    private var optionScrollZoomAccumulator = TrackpadNavigationLogic.ZoomAccumulator(publishedPercent: ZoomLadder.actualPixels)
    /// Relative rotation is rebased from the current view for every event.
    private var rotationGesture = TrackpadNavigationLogic.RotationAccumulator(baseDegrees: 0)

    /// View ▸ Show Guides: whether the canvas draws the image's guides.
    /// Cached per window (the document window controller owns the toggle);
    /// flipping it is pure view state and just redraws.
    var showsGuides = true {
        didSet { needsDisplay = true }
    }
    /// View ▸ Show Grid: whether the canvas draws the image's cached
    /// grid. Cached per window, default OFF; flipping it is pure view
    /// state — no pixels, dirty flag, history, selection, export or print
    /// change — and just redraws.
    var showsGrid = false {
        didSet { needsDisplay = true }
    }
    /// View ▸ Show Layer Boundary: whether the canvas draws the dashed
    /// outline of the current cached paint-target bounds. Cached per
    /// window (the document window controller owns the toggle), default
    /// OFF; flipping it is pure view state and just redraws.
    var showsLayerBoundary = false {
        didSet { needsDisplay = true }
    }
    /// View ▸ Snap To's cached per-window state, every entry OFF by
    /// default. Pure view state: flipping an entry changes only what the
    /// Move tool snaps to and what the canvas draws during a move — never
    /// image pixels, the dirty flag, history, selection, export or print —
    /// and just redraws.
    var snapTo = SnapToViewState() {
        didSet { needsDisplay = true }
    }
    /// View ▸ Show Selection Edges: whether the canvas draws the marching
    /// ants. Cached per window (the document window controller owns the
    /// toggle), default ON; hiding only stops the outline drawing and its
    /// timer — the native selection, its cached bounds/admission and every
    /// painting/selection command stay exactly as they are.
    var showsSelectionEdges = true {
        didSet {
            needsDisplay = true
            updateAntsTimer()
        }
    }
    /// Guide overlay lines: a saturated blue with a white underlay, so the
    /// line reads on light and dark images alike.
    static let guideColor = NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.95, alpha: 1)

    /// The selection outline in image pixels, drawn as marching ants.
    var selectionOutline: [EngineSession.Segment] = [] {
        didSet {
            selectionPath = nil
            needsDisplay = true
            updateAntsTimer()
        }
    }
    // Animation changes only the dash phase. Join the boundary again only
    // when the selection or the view's image scale changes.
    private var selectionPath: NSBezierPath?
    private var selectionPathScale: Double = 0
    private var antsPhase: CGFloat = 0
    private var antsTimer: Timer?

    init(document: ImageDocument) {
        self.document = document
        lastBackingFactor = Self.fallbackBackingFactor
        super.init(frame: .zero)
        TabletEraserProximity.shared.start()
        updateFrameSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// View points per image pixel: the zoom in the window's points, for
    /// pointer input, layout and overlays.
    var scale: Double { CanvasGeometry.pointScale(zoomPercent: zoomPercent, backingFactor: backingScale) }
    private static var fallbackBackingFactor: Double { Double(NSScreen.main?.backingScaleFactor ?? 2) }
    private var backingScale: Double { Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }
    /// Device pixels per image pixel: the zoom percent alone, independent
    /// of the backing factor, so cached tiles stay valid when the window
    /// moves between screens; a backing change only re-maps them to points.
    private var deviceScale: Double { CanvasGeometry.renderScale(zoomPercent: zoomPercent) }
    /// The backing factor the layout was last built for. The window
    /// already reports the new one when a change arrives, so the old
    /// viewport centre is computed with this cache.
    private var lastBackingFactor: Double

    func setZoom(percent: Int) {
        zoomPercent = percent
        advanceRenderGeneration(clearingTiles: true)
        updateFrameSize()
        tools.canvasScaleDidChange()
        needsDisplay = true
        setNeedsRender()
    }

    /// The image's size changed (crop, undo of a crop): every tile is stale.
    func imageSizeDidChange() {
        invalidateTransformPixelPreview()
        advanceRenderGeneration(clearingTiles: true)
        updateFrameSize()
        needsDisplay = true
        setNeedsRender()
    }

    func setSoftProof(_ proof: CanvasSoftProof?) {
        guard softProof != proof, !renderingStopped, !document.isClosing else { return }
        softProof = proof
        advanceRenderGeneration(clearingTiles: true)
        needsDisplay = true
        setNeedsRender()
    }

    private func updateFrameSize() {
        setFrameSize(CanvasGeometry.viewSize(imageSize: CGSize(width: Double(document.info.width),
                                                               height: Double(document.info.height)),
                                            zoomPercent: zoomPercent, backingFactor: backingScale))
    }

    /// Called when the image changed (`rect` in image pixels): the tiles
    /// under it go stale and are re-rendered, still drawn until replaced.
    func imageDidChange(in rect: CGRect? = nil) {
        invalidateTransformPixelPreview()
        let device = rect.map { CGRect(x: $0.minX * deviceScale, y: $0.minY * deviceScale,
                                       width: $0.width * deviceScale, height: $0.height * deviceScale) }
        for key in tiles.keys where device.map({ deviceRect(for: key).intersects($0) }) ?? true {
            staleTiles.insert(key)
        }
        failedTiles = failedTiles.filter { key in
            !(device.map { deviceRect(for: key).intersects($0) } ?? true)
        }
        setNeedsRender()
    }

    /// Renders whatever visible tiles are missing or stale.
    func setNeedsRender() {
        guard !renderingStopped, !document.isClosing, !renderInFlight, let key = nextTileToRender() else { return }
        renderInFlight = true
        let area = deviceRect(for: key)
        let session = document.session, image = document.image, scale = deviceScale, generation = generation
        // The immutable destination snapshot travels with the queued tile;
        // a destination change bumps the generation, so this result is
        // discarded on arrival instead of repopulating the cleared cache.
        let destination = self.destination
        let proof = self.softProof
        renderQueue.async {
            let started = DispatchTime.now().uptimeNanoseconds
            let result = Result {
                try CanvasDisplayDestination.render(session, image: image, scale: scale, area: area,
                                                    destination: destination, proof: proof)
            }
            let finished = DispatchTime.now().uptimeNanoseconds
            DispatchQueue.main.async {
                self.renderInFlight = false
                if generation == self.generation, !self.renderingStopped {
                    switch result {
                    case .success(let image):
                        self.store(image, for: key, elapsedSeconds:
                            CanvasRenderMetrics.elapsedSeconds(start: started, end: finished))
                        self.setNeedsDisplay(self.viewRect(for: key))
                    case .failure(let error):
                        // Retry when the image or zoom changes, not in
                        // an unbounded background loop for the same bad tile.
                        self.failedTiles.insert(key)
                        self.document.onError?("The image could not be drawn: \(error)")
                    }
                }
                self.setNeedsRender()
            }
        }
    }

    /// Drains any in-flight read before the engine image is destroyed.
    func stopRendering(completion: @escaping @MainActor () -> Void) {
        renderingStopped = true
        transformPixels.update(nil)
        inkLevelsPreviewToken = nil
        inkLevelsPixels.update(nil)
        onInkLevelsPreviewChange = nil
        onRenderMetricsChange = nil
        tools.cancelFloatingShape()
        tools.stopHintEvents()
        hintLifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        hintLifecycleObservers = []
        removeDestinationObservers()
        antsTimer?.invalidate()
        antsTimer = nil
        renderQueue.async { DispatchQueue.main.async { completion() } }
    }

    /// Renders every visible tile synchronously; used by the engine smoke
    /// test. Returns how many tiles were rendered. Follows the same
    /// destination policy as the queued path.
    @discardableResult
    func renderVisibleTilesNow() throws -> Int {
        refreshDisplayDestination()
        var count = 0
        while let key = nextTileToRender() {
            let started = DispatchTime.now().uptimeNanoseconds
            let image = try CanvasDisplayDestination.render(document.session, image: document.image,
                scale: deviceScale, area: deviceRect(for: key), destination: destination, proof: softProof)
            let finished = DispatchTime.now().uptimeNanoseconds
            store(image, for: key, elapsedSeconds:
                CanvasRenderMetrics.elapsedSeconds(start: started, end: finished))
            count += 1
        }
        needsDisplay = true
        return count
    }

    /// Test seam: the ICC bytes of one cached tile, when any. Every tile
    /// cached since the last destination change carries the destination it
    /// was rendered into, exactly tagged on its `CGImage`.
    func cachedTileICCData() -> Data? {
        return tiles.values.first?.colorSpace?.copyICCData() as Data?
    }

    /// Test seam: read-only view of the existing single in-flight tile
    /// admission, so the smoke can prove a render request is pending without
    /// touching the queue. No behavior change, no native call.
    var hasPendingRender: Bool { renderInFlight }

    /// Test seam: enqueues a barrier closure onto the existing private serial
    /// render queue, ordered after work already queued and before anything
    /// queued later. The smoke uses it to gate tile execution
    /// deterministically; normal rendering never calls it. The closure runs
    /// off the main actor, so it must not touch AppKit or view state — it may
    /// only dispatch a callback to main and wait on a semaphore.
    func enqueueRenderBarrier(_ barrier: @escaping @Sendable () -> Void) {
        renderQueue.async { barrier() }
    }

    private func store(_ image: CGImage, for key: TileKey, elapsedSeconds: TimeInterval?) {
        tiles[key] = image
        staleTiles.remove(key)
        if tiles.count > Self.maximumCachedTiles {
            let visible = Set(visibleTileKeys())
            for evicted in tiles.keys where !visible.contains(evicted) {
                tiles[evicted] = nil
                staleTiles.remove(evicted)
                if tiles.count <= Self.maximumCachedTiles { break }
            }
        }
        publishRenderMetrics(lastTileSeconds: elapsedSeconds)
    }

    private func advanceRenderGeneration(clearingTiles: Bool) {
        generation += 1
        if clearingTiles {
            tiles.removeAll()
            staleTiles.removeAll()
            failedTiles.removeAll()
        }
        publishRenderMetrics(lastTileSeconds: nil)
    }

    private func publishRenderMetrics(lastTileSeconds: TimeInterval?) {
        let bytes = tiles.values.reduce(UInt64(0)) { total, image in
            total + CanvasRenderMetrics.pixelPayloadBytes(bytesPerRow: image.bytesPerRow, height: image.height)
        }
        let updated = CanvasRenderMetrics(cachedPixelBytes: bytes, lastTileSeconds: lastTileSeconds)
        guard updated != renderMetrics else { return }
        renderMetrics = updated
        onRenderMetricsChange?(updated)
    }

    // MARK: Tile geometry

    /// The scaled image's size in device pixels.
    private var deviceImageSize: CGSize {
        CanvasGeometry.renderedImageSize(imageSize: CGSize(width: Double(document.info.width),
                                                           height: Double(document.info.height)),
                                         zoomPercent: zoomPercent)
    }

    private func deviceRect(for key: TileKey) -> CGRect {
        CanvasGeometry.tileRect(column: key.column, row: key.row,
                                tileSize: Self.tileSize, renderedImageSize: deviceImageSize)
    }

    private func viewRect(for key: TileKey) -> CGRect {
        CanvasGeometry.viewRect(renderRect: deviceRect(for: key), backingFactor: backingScale)
    }

    /// Visible tiles, nearest the viewport centre first.
    private func visibleTileKeys() -> [TileKey] {
        let visible = visibleRect.intersection(bounds)
        guard !visible.isEmpty else { return [] }
        let size = Double(Self.tileSize)
        let device = CGRect(x: visible.minX * backingScale, y: visible.minY * backingScale,
                            width: visible.width * backingScale, height: visible.height * backingScale)
            .intersection(CGRect(origin: .zero, size: deviceImageSize))
        guard !device.isEmpty else { return [] }
        guard let columns = CanvasGeometry.tileIndexRange(minimum: device.minX, maximum: device.maxX, tileSize: Self.tileSize),
              let rows = CanvasGeometry.tileIndexRange(minimum: device.minY, maximum: device.maxY, tileSize: Self.tileSize) else { return [] }
        let center = CGPoint(x: device.midX / size, y: device.midY / size)
        return rows.flatMap { row in columns.map { TileKey(column: $0, row: row) } }
            .sorted {
                hypot(Double($0.column) + 0.5 - center.x, Double($0.row) + 0.5 - center.y)
                    < hypot(Double($1.column) + 0.5 - center.x, Double($1.row) + 0.5 - center.y)
            }
    }

    private func nextTileToRender() -> TileKey? {
        visibleTileKeys().first { !failedTiles.contains($0) && (tiles[$0] == nil || staleTiles.contains($0)) }
    }

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        // Releases can go to a field editor in this same key window. Start
        // from the current physical flags instead of stale canvas key state.
        tools.resetHintModifiers()
        tools.hintModifiersChanged(NSEvent.modifierFlags)
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        tools.cancelFloatingShape()
        tools.cancelPickedMove()
        tools.cancelSpringTools()
        tools.resetHintModifiers()
        return true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hintLifecycleObservers.forEach { NotificationCenter.default.removeObserver($0) }
        hintLifecycleObservers = []
        tools.resetHintModifiers()
        if let window, !renderingStopped {
            let center = NotificationCenter.default
            let scopes: [(Notification.Name, AnyObject?)] = [
                (NSWindow.didResignKeyNotification, window),
                (NSApplication.didResignActiveNotification, nil)
            ]
            for (name, object) in scopes {
                hintLifecycleObservers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.tools.resetHintModifiers() }
                })
            }
        }
        swapDestinationObservers()
        if window == nil {
            tools.cancelFloatingShape()
            tools.cancelPickedMove()
            tools.cancelSpringTools()
        }
        backingDidChange()
        updateAntsTimer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        backingDidChange()
    }

    // MARK: Display destination

    /// Re-snapshots the owning window's actual backing destination. An ICC
    /// identity change clears every completed tile (and the stale/failed
    /// bookkeeping) and bumps the generation, so in-flight renders for the
    /// old profile are discarded on arrival; identical ICC bytes keep the
    /// cache and the existing center/zoom semantics. Idempotent, so the
    /// view callbacks and the notifications may both fire.
    private func refreshDisplayDestination() {
        let updated = CanvasDisplayDestination.snapshot(window: window)
        guard updated.invalidatesCache(comparedTo: destination) else { return }
        destination = updated
        advanceRenderGeneration(clearingTiles: true)
        needsDisplay = true
    }

    /// (Re)registers the destination observers for the current owning
    /// window and its specifically associated screen: the window's backing
    /// properties (which carry the old/new color space per TN2313), screen
    /// moves, and the screen's profile change. Tokens are swapped on window
    /// changes and removed on detach/close; blocks capture self weakly.
    private func swapDestinationObservers() {
        removeDestinationObservers()
        guard let window else { return }
        window.displaysWhenScreenProfileChanges = true
        let center = NotificationCenter.default
        destinationObservers = [
            center.addObserver(forName: NSWindow.didResignKeyNotification, object: window,
                               queue: .main) { [weak self] _ in
                self?.tools.cancelFloatingShape()
                self?.tools.cancelPickedMove()
                self?.tools.cancelSpringTools()
            },
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: NSApp,
                               queue: .main) { [weak self] _ in
                self?.tools.cancelFloatingShape()
                self?.tools.cancelPickedMove()
                self?.tools.cancelSpringTools()
            },
            center.addObserver(forName: NSWindow.didChangeBackingPropertiesNotification, object: window,
                               queue: .main) { [weak self] _ in self?.destinationDidChange() },
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: window,
                               queue: .main) { [weak self] _ in self?.destinationDidChange() },
            center.addObserver(forName: NSScreen.colorSpaceDidChangeNotification, object: nil,
                               queue: .main) { [weak self] note in
                guard let screen = note.object as? NSScreen, screen === self?.window?.screen else { return }
                self?.destinationDidChange()
            },
        ]
    }

    private func removeDestinationObservers() {
        for token in destinationObservers { NotificationCenter.default.removeObserver(token) }
        destinationObservers.removeAll()
    }

    /// A backing color-space, screen or profile change arrived: re-read the
    /// actual window snapshot and schedule fresh tiles with it.
    private func destinationDidChange() {
        refreshDisplayDestination()
        setNeedsRender()
    }

    /// The window or its screen changed: keep the zoom percent, drop the
    /// renders scheduled under the old layout, rebuild the frame and the
    /// overlays at the current backing factor, hold the image pixel that
    /// sat under the viewport centre and request fresh renders. Tiles are
    /// rendered at a backing-independent scale, so the cache survives and
    /// only the in-flight generation is invalidated. A destination ICC
    /// change additionally clears the completed cache (refresh first).
    private func backingDidChange() {
        refreshDisplayDestination()
        advanceRenderGeneration(clearingTiles: false)
        let clip = enclosingScrollView?.contentView
        let viewport = clip?.bounds ?? .zero
        let viewCenter = convert(CGPoint(x: viewport.midX, y: viewport.midY), from: clip)
        let oldScale = CanvasGeometry.pointScale(zoomPercent: zoomPercent, backingFactor: lastBackingFactor)
        let center = CGPoint(x: viewCenter.x / oldScale, y: viewCenter.y / oldScale)
        lastBackingFactor = backingScale
        updateFrameSize()
        tools.canvasScaleDidChange()
        needsDisplay = true
        if let scrollView = enclosingScrollView, let clip {
            let point = convert(CGPoint(x: center.x * scale, y: center.y * scale), to: scrollView.documentView)
            let target = CGRect(x: point.x - clip.bounds.width / 2, y: point.y - clip.bounds.height / 2,
                                width: clip.bounds.width, height: clip.bounds.height)
            clip.scroll(to: clip.constrainBoundsRect(target).origin)
            scrollView.reflectScrolledClipView(clip)
        }
        setNeedsRender()
    }

    // MARK: Selection outline

    /// Black and white dashes, the classic marching ants.
    static func strokeMarchingAnts(_ path: NSBezierPath, phase: CGFloat) {
        path.lineWidth = 1
        NSColor.white.setStroke()
        path.setLineDash(nil, count: 0, phase: 0)
        path.stroke()
        NSColor.black.setStroke()
        path.setLineDash([4, 4], count: 2, phase: phase)
        path.stroke()
    }

    private func updateAntsTimer() {
        let animate = window != nil && showsSelectionEdges && !selectionOutline.isEmpty
        if animate, antsTimer == nil {
            // Selector-based, so the tick runs as a main-thread method.
            antsTimer = Timer.scheduledTimer(timeInterval: 0.15, target: self, selector: #selector(antsTick),
                                             userInfo: nil, repeats: true)
        } else if !animate {
            antsTimer?.invalidate()
            antsTimer = nil
        }
    }

    @objc private func antsTick() {
        antsPhase = (antsPhase + 1).truncatingRemainder(dividingBy: 8)
        setNeedsDisplay(visibleRect)
    }

    private func drawSelectionOutline() {
        guard !selectionOutline.isEmpty else { return }
        if selectionPath == nil || selectionPathScale != scale {
            selectionPath = SelectionContour.outlinePath(for: selectionOutline, scale: scale)
            selectionPathScale = scale
        }
        if let selectionPath { Self.strokeMarchingAnts(selectionPath, phase: antsPhase) }
    }

    override func draw(_ dirtyRect: NSRect) {
        // Attaching to a window can happen before the scroll view has a
        // visible rectangle. The first draw is the first reliable chance
        // to request tiles; viewDidMoveToWindow alone leaves a gray canvas.
        setNeedsRender()
        refreshTransformPixelPreview()
        refreshInkLevelsPixelPreview()
        surroundColor.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        for (key, image) in tiles {
            let rect = viewRect(for: key)
            guard rect.intersects(dirtyRect) else { continue }
            Self.transparencyChecks.setFill()
            rect.intersection(dirtyRect).fill()
            context.saveGState()
            // The view is flipped; CGImage draws bottom-up.
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
        if let image = transformPixels.image, let request = transformPixels.displayedRequest {
            // Replace the whole composite, including its transparent pixels.
            // Painting a warped target over the old composite would leave the
            // original layer visible beneath it and break masks/blend modes.
            drawPreview(image, area: request.renderArea, renderScale: request.renderScale,
                        dirtyRect: dirtyRect, context: context)
        }
        if let image = inkLevelsPixels.image, let request = inkLevelsPixels.displayedRequest {
            drawPreview(image, area: request.renderArea, renderScale: request.renderScale,
                        dirtyRect: dirtyRect, context: context)
        }
        // The grid draws between the image and the selection/path/guide
        // overlays: on top of the pixels, under everything else.
        if showsGrid { drawGridOverlay() }
        if showsSelectionEdges { drawSelectionOutline() }
        if showsLayerBoundary { drawLayerBoundary() }
        drawVisiblePaths()
        if showsGuides { drawGuidesOverlay() }
        drawGuideGhost()
        tools.drawOverlay(scale: scale)
    }

    private func drawPreview(_ image: CGImage, area: CGRect, renderScale: Double,
                             dirtyRect: CGRect, context: CGContext) {
        context.saveGState()
        context.clip(to: bounds)
        Self.transparencyChecks.setFill()
        let rect = CGRect(x: area.minX / renderScale * scale, y: area.minY / renderScale * scale,
                          width: Double(image.width) / renderScale * scale,
                          height: Double(image.height) / renderScale * scale)
        rect.intersection(dirtyRect).fill()
        context.interpolationQuality = renderScale < deviceScale ? .low : .none
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: rect.size))
        context.restoreGState()
    }

    func setInkLevelsPreview(token: UInt64?, settings: EngineSession.InkLevelsSettings = .init()) {
        inkLevelsPreviewToken = token
        inkLevelsPreviewSettings = settings
        refreshInkLevelsPixelPreview(retryFailure: true)
        needsDisplay = true
    }

    private func refreshInkLevelsPixelPreview(retryFailure: Bool = false) {
        guard !renderingStopped, !document.isClosing, document.filterPreviewIsOpen,
              let token = inkLevelsPreviewToken, !visibleRect.intersection(bounds).isEmpty else {
            inkLevelsPixels.update(nil)
            return
        }
        let size = CGSize(width: document.info.width, height: document.info.height)
        let viewport = CGRect(x: visibleRect.minX / scale, y: visibleRect.minY / scale,
                              width: visibleRect.width / scale, height: visibleRect.height / scale)
            .intersection(CGRect(origin: .zero, size: size))
        inkLevelsPixels.update(.init(token: token, settings: inkLevelsPreviewSettings,
            imageSize: size, destination: destination, proof: softProof,
            viewport: viewport, displayScale: deviceScale), retryFailure: retryFailure)
    }

    /// Projection-only changes do not necessarily reload document state.
    /// Their own generation prevents an old clone from repainting new pixels.
    func invalidateTransformPixelPreview() {
        transformSourceRevision &+= 1
        transformPixels.update(nil)
        needsDisplay = true
    }

    func refreshTransformPixelPreview() {
        guard !renderingStopped, !document.isClosing, document.acceptsEdits,
              !tools.transformCommitIsPending, ToolState.shared.current == .transform,
              !document.hasMultipleSelectedLayers, !document.isMaskTargetActive, !document.isChannelTargetActive,
              !visibleRect.intersection(bounds).isEmpty,
              let session = tools.transformSession, !session.isIdentity,
              tools.transformPreview?.projectiveMatrix == session.projectiveMatrix,
              document.activeDrawable == session.layer else {
            transformPixels.update(nil)
            return
        }
        transformPixels.update(.init(layer: session.layer, original: session.original,
            matrix: session.projectiveMatrix, interpolation: ToolState.shared.transformInterpolation,
            imageSize: CGSize(width: document.info.width, height: document.info.height),
            sourceRevision: transformSourceRevision, destination: destination, proof: softProof, maximumEdge: 4096,
            viewport: CGRect(x: visibleRect.minX / scale, y: visibleRect.minY / scale,
                             width: visibleRect.width / scale, height: visibleRect.height / scale)
                .intersection(CGRect(x: 0, y: 0, width: document.info.width, height: document.info.height)),
            displayScale: deviceScale))
    }

    /// The guide being dragged, as a dashed ghost line clipped to the
    /// displayed image. View-only: drawn over the cached tiles, never into
    /// them, and invisible to export, print and the engine — printing draws
    /// an immutable PrintSnapshot, not this view.
    private func drawGuideGhost() {
        guard let gesture = guideDrag.gesture else { return }
        let imageSize = CGSize(width: Double(document.info.width), height: Double(document.info.height))
        guard let (from, to) = GuideDragLogic.lineEndpoints(orientation: gesture.orientation,
                                                            position: gesture.position, imageSize: imageSize,
                                                            zoomPercent: zoomPercent, backingFactor: backingScale)
        else { return }
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CanvasGeometry.imageViewRect(imageSize: imageSize, zoomPercent: zoomPercent,
                                                        backingFactor: backingScale)).addClip()
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = 3
        NSColor.white.setStroke()
        path.stroke()
        path.lineWidth = 1
        path.setLineDash([6, 4], count: 2, phase: 0)
        NSColor.systemOrange.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The image's cached display grid, drawn between the image tiles and
    /// the selection/path/guide overlays. A pure canvas overlay built by
    /// the bounded `GridOverlayPlanner` from cached metadata only — it
    /// touches neither the rendered tiles nor any pixel path, and
    /// printing draws an immutable PrintSnapshot rendered from the
    /// engine, never this view, so the grid cannot leak into print.
    /// Image coordinates map straight to view points (the view is
    /// flipped like the bitmap, so y is never mirrored), which keeps the
    /// grid aligned across zoom, backing changes and scroll.
    private func drawGridOverlay() {
        let grid = document.grid
        let imageSize = CGSize(width: Double(document.info.width), height: Double(document.info.height))
        let imageRect = CanvasGeometry.imageViewRect(imageSize: imageSize, zoomPercent: zoomPercent,
                                                     backingFactor: backingScale)
        // Clip to the visible image FIRST: the planner only ever walks
        // the visible range, never the whole image.
        let visible = visibleRect.intersection(bounds).intersection(imageRect)
        guard !visible.isEmpty else { return }
        let visibleImage = CGRect(x: visible.minX / scale, y: visible.minY / scale,
                                  width: visible.width / scale, height: visible.height / scale)
        let plan = GridOverlayPlanner.plan(grid: grid, imageSize: imageSize,
                                           visibleImageRect: visibleImage,
                                           deviceScale: deviceScale, viewScale: scale)
        guard !plan.isSuppressed else { return }
        // One device pixel in view points: the engine strokes the grid at
        // a 1-device-px hairline; dots and crosshair arms scale with it.
        let device = scale / deviceScale
        guard device.isFinite, device > 0 else { return }
        let dash = GridOverlayPlanner.dashLengthDevicePixels * device
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: imageRect).addClip()
        func stroke(_ path: NSBezierPath, color: NSColor, dashed: Bool, phase: CGFloat) {
            path.lineWidth = device
            if dashed { path.setLineDash([dash, dash], count: 2, phase: phase) }
            color.setStroke()
            path.stroke()
        }
        let foreground = grid.foreground
        let background = grid.background
        switch plan.style {
        case .dots, .intersections:
            for point in plan.points {
                let p = CGPoint(x: point.x * scale, y: point.y * scale)
                if plan.style == .dots {
                    // One 1-device-px mark at the intersection.
                    foreground.setFill()
                    NSRect(x: p.x, y: p.y, width: device, height: device).fill()
                } else {
                    // A crosshair with the engine's arm reach (CROSSHAIR).
                    let arm = GridOverlayPlanner.crosshairDevicePixels * device
                    let path = NSBezierPath()
                    path.move(to: CGPoint(x: p.x, y: p.y - arm))
                    path.line(to: CGPoint(x: p.x, y: p.y + arm + device))
                    path.move(to: CGPoint(x: p.x - arm, y: p.y))
                    path.line(to: CGPoint(x: p.x + arm + device, y: p.y))
                    stroke(path, color: foreground, dashed: false, phase: 0)
                }
            }
        case .onOffDash, .doubleDash, .solid:
            func linePath(_ line: GridOverlayPlanner.Line) -> NSBezierPath {
                let path = NSBezierPath()
                if line.isVertical {
                    path.move(to: CGPoint(x: line.coordinate * scale, y: line.from * scale))
                    path.line(to: CGPoint(x: line.coordinate * scale, y: line.to * scale))
                } else {
                    path.move(to: CGPoint(x: line.from * scale, y: line.coordinate * scale))
                    path.line(to: CGPoint(x: line.to * scale, y: line.coordinate * scale))
                }
                return path
            }
            let dashed = plan.style != .solid
            for line in plan.verticalLines + plan.horizontalLines {
                let path = linePath(line)
                if plan.style == .doubleDash {
                    // Interleaved foreground/background dashes: the
                    // background pass shifted by one dash length, both
                    // phases anchored to image coordinates.
                    stroke(path, color: background, dashed: true, phase: CGFloat(line.dashPhase))
                    stroke(path, color: foreground, dashed: true, phase: CGFloat(line.dashPhase) + CGFloat(dash))
                } else {
                    stroke(path, color: foreground, dashed: dashed, phase: CGFloat(line.dashPhase))
                }
            }
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// View ▸ Show Layer Boundary: a dashed outline exactly one physical
    /// pixel wide around the current cached paint-target bounds (an
    /// ordinary or floating layer's own bounds, the owner layer's bounds
    /// while a mask is being edited, the image bounds for a channel). The
    /// rect is resolved from the document's caches on every draw — nil
    /// clears the outline instead of showing a remembered unrelated layer
    /// — and cached metadata supplies all the geometry, so this never
    /// changes the selection, the tiles or any pixel path; printing draws
    /// an immutable PrintSnapshot, never this view.
    private func drawLayerBoundary() {
        guard let boundary = document.cachedPaintTargetBounds else { return }
        let device = LayerBoundaryGeometry.deviceLineWidth(zoomPercent: zoomPercent, backingFactor: backingScale)
        guard device.isFinite, device > 0 else { return }
        let viewRect = LayerBoundaryGeometry.viewRect(for: boundary, zoomPercent: zoomPercent,
                                                      backingFactor: backingScale)
        guard let rect = LayerBoundaryGeometry.strokeRect(for: viewRect, backingFactor: backingScale) else { return }
        NSGraphicsContext.saveGraphicsState()
        // Clip to the canvas frame: a floating selection's bounds can reach
        // past the image edge into the surround, and the outline stays
        // inside the visible canvas.
        NSBezierPath(rect: bounds).addClip()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = device
        // White underlay so the dashes read on dark images too, then the
        // black dash pass, both one physical pixel wide.
        NSColor.white.setStroke()
        path.setLineDash(nil, count: 0, phase: 0)
        path.stroke()
        let dash = 4 * device
        path.setLineDash([dash, dash], count: 2, phase: 0)
        NSColor.black.setStroke()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The image's ordinary guides as full-width/full-height lines in view
    /// points, clipped to the displayed image. A pure canvas overlay: it
    /// touches neither the rendered tiles nor any pixel path — printing
    /// draws an immutable PrintSnapshot rendered from the engine, never
    /// this view, so guides cannot leak into printed output.
    private func drawGuidesOverlay() {
        let guides = document.guides
        guard !guides.isEmpty else { return }
        let imageSize = CGSize(width: Double(document.info.width), height: Double(document.info.height))
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: CanvasGeometry.imageViewRect(imageSize: imageSize, zoomPercent: zoomPercent,
                                                        backingFactor: backingScale)).addClip()
        for guide in guides {
            guard let (from, to) = CanvasGeometry.guideLineEndpoints(orientation: guide.orientation,
                                                                    position: guide.position,
                                                                    imageSize: imageSize,
                                                                    zoomPercent: zoomPercent,
                                                                    backingFactor: backingScale) else { continue }
            let path = NSBezierPath()
            path.move(to: from)
            path.line(to: to)
            path.lineWidth = 3
            NSColor.white.setStroke()
            path.stroke()
            path.lineWidth = 1
            Self.guideColor.setStroke()
            path.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Visible paths as thin lines, as GIMP shows them with any tool. The
    /// Path tool draws the active path itself, with its anchors.
    private func drawVisiblePaths() {
        let editing = ToolState.shared.current == .path ? document.activePath : nil
        for path in document.paths where path.isVisible && path.id != editing {
            guard let shape = document.pathShapes[path.id] else { continue }
            let outline = NSBezierPath(cgPath: shape.cgPath(scale: scale))
            outline.lineWidth = 1
            PathTool.pathColor.setStroke()
            outline.stroke()
        }
    }

    // MARK: Events

    /// The pointer's position in image pixels.
    func imagePoint(for event: NSEvent) -> CGPoint {
        CanvasGeometry.imagePoint(viewPoint: convert(event.locationInWindow, from: nil),
                                  zoomPercent: zoomPercent, backingFactor: backingScale)
    }

    /// The image-pixel point under a canvas view point — the same mapping
    /// pointer input uses. The pixel rulers convert their own corners into
    /// canvas coordinates and then through this, so their image-pixel
    /// range matches the canvas exactly.
    func imagePoint(at viewPoint: CGPoint) -> CGPoint {
        CanvasGeometry.imagePoint(viewPoint: viewPoint, zoomPercent: zoomPercent, backingFactor: backingScale)
    }

    func strokePoint(for event: NSEvent) -> EngineSession.StrokePoint? {
        guard TabletEraserProximity.isMouseEvent(event) || event.type == .tabletPoint,
              !TabletEraserProximity.isProximityEvent(event),
              let time = TabletStrokeInput.milliseconds(event.timestamp) else { return nil }
        let point = imagePoint(for: event)
        let isTablet = TabletEraserProximity.isTabletPoint(event)
        let value = EngineSession.StrokePoint(
            x: point.x, y: point.y,
            pressure: isTablet ? Double(event.pressure) : 1,
            xTilt: isTablet ? Double(event.tilt.x) : 0,
            yTilt: isTablet ? Double(event.tilt.y) : 0,
            timeMilliseconds: time)
        return [value.x, value.y, value.pressure, value.xTilt, value.yTilt].allSatisfy(\.isFinite) ? value : nil
    }

    func tabletStrokePoint(for event: NSEvent, capture: TabletStrokeInput.Capture) -> EngineSession.StrokeSampleV2? {
        guard let point = strokePoint(for: event) else { return nil }
        let device = TabletEraserProximity.isTabletPoint(event) ? UInt(exactly: event.deviceID) : nil
        let matching = device == capture.deviceID
        return TabletStrokeInput.sample(point: point, capture: capture, deviceID: device,
            rotationDegrees: matching && capture.capabilities.rotation ? Double(event.rotation) : nil,
            tangentialPressure: matching && capture.capabilities.tangentialPressure ? Double(event.tangentialPressure) : nil)
    }

    override func mouseDown(with event: NSEvent) {
        guard !TabletEraserProximity.isProximityEvent(event) else { return }
        guard !document.isClosing else {
            document.onError?(ImageDocument.DocumentError.busy.localizedDescription)
            return
        }
        window?.makeFirstResponder(self)
        tools.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !TabletEraserProximity.isProximityEvent(event) else { return }
        tools.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        guard !TabletEraserProximity.isProximityEvent(event) else { return }
        tools.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Escape cancels an in-progress guide drag before anything else.
        if guideDrag.keyDown(with: event) {
            tools.cancelSpringTools()
            return
        }
        if tools.keyDown(with: event) { return }
        if event.keyCode == 53,
           event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let owner = window?.windowController as? DocumentWindowController,
           owner.screenMode != .windowed, owner.canChangeScreenMode {
            // Native Spaces handle Escape themselves. The owned borderless
            // presentation needs the equivalent idle canvas route explicitly.
            owner.cancelOperation(nil)
            return
        }
        if event.keyCode == 51, event.modifierFlags.intersection([.command, .option, .control]).isEmpty,
           let controller = window?.windowController as? DocumentWindowController {
            controller.deleteBackward(nil)
            return
        }
        super.keyDown(with: event)
    }

    override func keyUp(with event: NSEvent) {
        if !tools.keyUp(with: event) { super.keyUp(with: event) }
    }

    override func flagsChanged(with event: NSEvent) {
        tools.selectionModifiersChanged(event.modifierFlags)
        tools.transformModifiersChanged(event.modifierFlags)
        tools.hintModifiersChanged(event.modifierFlags)
        super.flagsChanged(with: event)
    }

    // MARK: Trackpad pinch and rotate (view-only navigation)

    /// The guards for trackpad view navigation: the event must belong to
    /// this canvas's visible owning window, and no interaction the
    /// navigation must not disturb may be pending. Engine work (a running
    /// plug-in, a filter preview) does NOT block view-only navigation.
    private func trackpadNavigationAllowed(for event: NSEvent) -> Bool {
        guard let window, window.isVisible, event.windowNumber == window.windowNumber,
              !document.isClosing, !tools.hasPendingInteraction,
              !guideDrag.isActive, !document.strokeIsActive else { return false }
        return true
    }

    /// Drops any half-finished gesture state (guards failed, unmatched
    /// window): both accumulators restart from the view's current zoom
    /// and rotation.
    private func resetTrackpadGestures() {
        zoomGesture.rebase(to: zoomPercent)
        rotationGesture.rebase(to: trackpadRotationDegrees?() ?? Double(frameRotation))
    }

    /// Trackpad pinch-zoom. Per Apple's Event Overview the magnification is
    /// relative per message (new zoom = current * (1 + magnification)), so
    /// the fractional percent accumulates and is published as an integer
    /// only when it changes; .cancelled clears without a new delta, .ended
    /// may apply its delta and then clears.
    override func magnify(with event: NSEvent) {
        guard trackpadNavigationAllowed(for: event) else { resetTrackpadGestures(); return }
        let point = event.locationInWindow
        guard point.x.isFinite, point.y.isFinite else { return }
        if event.phase == .began || zoomGesture.publishedPercent != zoomPercent {
            // A new gesture, or the zoom changed outside it (menu, status
            // bar): rebase. An own publication matches zoomPercent, so the
            // fractional remainder is not dropped.
            zoomGesture.rebase(to: zoomPercent)
        }
        switch event.phase {
        case .cancelled:
            zoomGesture.clear()
        case .ended:
            if let percent = zoomGesture.apply(magnification: Double(event.magnification)) {
                onTrackpadZoom?(percent, point)
            }
            zoomGesture.clear()
        default:
            if let percent = zoomGesture.apply(magnification: Double(event.magnification)) {
                onTrackpadZoom?(percent, point)
            }
        }
    }

    /// Trackpad rotate. A positive event rotation is counterclockwise, so
    /// the canvas delta is MINUS it (the flipped canvas's positive
    /// frameRotation is clockwise).
    override func rotate(with event: NSEvent) {
        guard trackpadNavigationAllowed(for: event) else { resetTrackpadGestures(); return }
        let point = event.locationInWindow
        guard point.x.isFinite, point.y.isFinite else { return }
        // Rotation events are relative. Read the current angle even for a
        // phase-none event or a menu change between events; the view also
        // normalizes angles, so retaining an old absolute base would drift.
        rotationGesture.rebase(to: trackpadRotationDegrees?() ?? Double(frameRotation))
        switch event.phase {
        case .cancelled:
            rotationGesture.cancel()
        case .ended:
            if let degrees = rotationGesture.apply(eventRotationDegrees: Double(event.rotation)) {
                onTrackpadRotate?(degrees, point)
            }
            rotationGesture.finish()
        default:
            if let degrees = rotationGesture.apply(eventRotationDegrees: Double(event.rotation)) {
                onTrackpadRotate?(degrees, point)
            }
        }
    }

    // MARK: Option-scroll view zoom

    func handleOptionScroll(_ event: NSEvent) -> Bool {
        guard OptionScrollZoom.isAdmitted(event.modifierFlags) else {
            optionScrollZoomAccumulator.rebase(to: zoomPercent)
            return false
        }
        guard trackpadNavigationAllowed(for: event) else {
            optionScrollZoomAccumulator.rebase(to: zoomPercent)
            return true
        }
        let point = event.locationInWindow
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        let usableDelta = point.x.isFinite && point.y.isFinite ? Double(delta) : nil
        let percent = OptionScrollZoom.apply(
            delta: usableDelta, precise: event.hasPreciseScrollingDeltas, currentPercent: zoomPercent,
            began: event.phase.contains(.began) || event.momentumPhase.contains(.began),
            ended: event.phase.contains(.ended) || event.momentumPhase.contains(.ended),
            cancelled: event.phase.contains(.cancelled) || event.momentumPhase.contains(.cancelled),
            to: &optionScrollZoomAccumulator)
        if let percent { onTrackpadZoom?(percent, point) }
        return true
    }
}
