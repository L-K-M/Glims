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
    private var staleTiles: Set<TileKey> = []
    private var failedTiles: Set<TileKey> = []
    private var renderingStopped = false
    private var renderInFlight = false
    /// Bumped on zoom changes; results of an older generation are dropped.
    private var generation = 0

    /// The current tool's handling of pointer and key events.
    private(set) lazy var tools = CanvasToolController(canvas: self)

    /// View ▸ Show Guides: whether the canvas draws the image's guides.
    /// Cached per window (the document window controller owns the toggle);
    /// flipping it is pure view state and just redraws.
    var showsGuides = true {
        didSet { needsDisplay = true }
    }
    var showsLayerBoundary = false {
        didSet { needsDisplay = true }
    }
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
        generation += 1
        tiles.removeAll()
        staleTiles.removeAll()
        failedTiles.removeAll()
        updateFrameSize()
        tools.canvasScaleDidChange()
        needsDisplay = true
        setNeedsRender()
    }

    /// The image's size changed (crop, undo of a crop): every tile is stale.
    func imageSizeDidChange() {
        generation += 1
        tiles.removeAll()
        staleTiles.removeAll()
        failedTiles.removeAll()
        updateFrameSize()
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
        renderQueue.async {
            let result = Result { try session.render(image, scale: scale, area: area) }
            DispatchQueue.main.async {
                self.renderInFlight = false
                if generation == self.generation, !self.renderingStopped {
                    switch result {
                    case .success(let image):
                        self.store(image, for: key)
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
        antsTimer?.invalidate()
        antsTimer = nil
        renderQueue.async { DispatchQueue.main.async { completion() } }
    }

    /// Renders every visible tile synchronously; used by the engine smoke
    /// test. Returns how many tiles were rendered.
    @discardableResult
    func renderVisibleTilesNow() throws -> Int {
        var count = 0
        while let key = nextTileToRender() {
            store(try document.session.render(document.image, scale: deviceScale, area: deviceRect(for: key)), for: key)
            count += 1
        }
        needsDisplay = true
        return count
    }

    private func store(_ image: CGImage, for key: TileKey) {
        tiles[key] = image
        staleTiles.remove(key)
        guard tiles.count > Self.maximumCachedTiles else { return }
        let visible = Set(visibleTileKeys())
        for evicted in tiles.keys where !visible.contains(evicted) {
            tiles[evicted] = nil
            staleTiles.remove(evicted)
            if tiles.count <= Self.maximumCachedTiles { break }
        }
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
        let columns = Int(floor(device.minX / size))...Int(floor((device.maxX - 1) / size))
        let rows = Int(floor(device.minY / size))...Int(floor((device.maxY - 1) / size))
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

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        backingDidChange()
        updateAntsTimer()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        backingDidChange()
    }

    /// The window or its screen changed: keep the zoom percent, drop the
    /// renders scheduled under the old layout, rebuild the frame and the
    /// overlays at the current backing factor, hold the image pixel that
    /// sat under the viewport centre and request fresh renders. Tiles are
    /// rendered at a backing-independent scale, so the cache survives and
    /// only the in-flight generation is invalidated.
    private func backingDidChange() {
        generation += 1
        let viewport = enclosingScrollView?.contentView.bounds ?? .zero
        let center = CanvasGeometry.imageCenter(scrollOffset: viewport.origin, viewportSize: viewport.size,
                                                zoomPercent: zoomPercent, backingFactor: lastBackingFactor)
        lastBackingFactor = backingScale
        updateFrameSize()
        tools.canvasScaleDidChange()
        needsDisplay = true
        if enclosingScrollView != nil {
            let target = CanvasGeometry.scrollOffset(preservingImageCenter: center, viewportSize: viewport.size,
                                                     canvasSize: frame.size,
                                                     zoomPercent: zoomPercent, backingFactor: backingScale)
            if target != viewport.origin { scroll(target) }
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
        if showsSelectionEdges { drawSelectionOutline() }
        if showsLayerBoundary { drawLayerBoundary() }
        drawVisiblePaths()
        if showsGuides { drawGuidesOverlay() }
        tools.drawOverlay(scale: scale)
    }

    /// Display-only bounds of the selected layer. Cached layer metadata
    /// supplies the geometry; this never changes the selection or tiles.
    private func drawLayerBoundary() {
        guard let layer = document.layers.first(where: { $0.id == document.activeLayer }) else { return }
        let rect = layer.bounds
        guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite),
              rect.width > 0, rect.height > 0 else { return }
        let path = NSBezierPath(rect: NSRect(x: rect.minX * scale, y: rect.minY * scale,
                                             width: rect.width * scale, height: rect.height * scale))
        path.lineWidth = 2
        NSColor.black.setStroke()
        path.stroke()
        path.lineWidth = 1
        path.setLineDash([4, 4], count: 2, phase: 0)
        NSColor.yellow.setStroke()
        path.stroke()
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

    func strokePoint(for event: NSEvent) -> EngineSession.StrokePoint {
        let point = imagePoint(for: event)
        let isTablet = event.subtype == .tabletPoint
        return EngineSession.StrokePoint(
            x: point.x, y: point.y,
            pressure: isTablet ? Double(event.pressure) : 1,
            xTilt: isTablet ? Double(event.tilt.x) : 0,
            yTilt: isTablet ? Double(event.tilt.y) : 0,
            timeMilliseconds: UInt32(truncatingIfNeeded: Int(event.timestamp * 1000)))
    }

    override func mouseDown(with event: NSEvent) {
        guard !document.isClosing else {
            document.onError?(ImageDocument.DocumentError.busy.localizedDescription)
            return
        }
        window?.makeFirstResponder(self)
        tools.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        tools.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        tools.mouseUp(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if tools.keyDown(with: event) { return }
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
}
