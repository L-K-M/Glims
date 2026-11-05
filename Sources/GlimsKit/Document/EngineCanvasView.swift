import AppKit

/// The document canvas: shows the engine's composited image at the current
/// zoom and turns pointer input into paint strokes.
///
/// The image is drawn from a cache of square tiles in device pixels. Missing
/// or stale visible tiles are rendered one at a time on a background queue,
/// nearest the viewport centre first, and each is drawn as soon as it
/// arrives. A large image therefore appears progressively, as in GIMP's own
/// display, and panning shows cached tiles at once while new ones fill in.
@MainActor
final class EngineCanvasView: NSView {
    private static let surround = NSColor(calibratedWhite: 0.42, alpha: 1)
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
    private var staleTiles: Set<TileKey> = []
    private var renderInFlight = false
    /// Bumped on zoom changes; results of an older generation are dropped.
    private var generation = 0

    init(document: ImageDocument) {
        self.document = document
        super.init(frame: .zero)
        updateFrameSize()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var scale: Double { Double(zoomPercent) / 100 }
    private var backingScale: Double { Double(window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2) }
    private var deviceScale: Double { scale * backingScale }

    func setZoom(percent: Int) {
        zoomPercent = percent
        generation += 1
        tiles.removeAll()
        staleTiles.removeAll()
        updateFrameSize()
        needsDisplay = true
        setNeedsRender()
    }

    private func updateFrameSize() {
        setFrameSize(NSSize(width: (Double(document.info.width) * scale).rounded(.up),
                            height: (Double(document.info.height) * scale).rounded(.up)))
    }

    /// Called when the image changed (`rect` in image pixels): the tiles
    /// under it go stale and are re-rendered, still drawn until replaced.
    func imageDidChange(in rect: CGRect? = nil) {
        let device = rect.map { CGRect(x: $0.minX * deviceScale, y: $0.minY * deviceScale,
                                       width: $0.width * deviceScale, height: $0.height * deviceScale) }
        for key in tiles.keys where device.map({ deviceRect(for: key).intersects($0) }) ?? true {
            staleTiles.insert(key)
        }
        setNeedsRender()
    }

    /// Renders whatever visible tiles are missing or stale.
    func setNeedsRender() {
        guard !renderInFlight, let key = nextTileToRender() else { return }
        renderInFlight = true
        let area = deviceRect(for: key)
        let session = document.session, image = document.image, scale = deviceScale, generation = generation
        renderQueue.async {
            let result = try? session.render(image, scale: scale, area: area)
            DispatchQueue.main.async {
                self.renderInFlight = false
                if generation == self.generation, let result {
                    self.store(result, for: key)
                    self.setNeedsDisplay(self.viewRect(for: key))
                }
                self.setNeedsRender()
            }
        }
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
        CGSize(width: (Double(document.info.width) * deviceScale).rounded(.up),
               height: (Double(document.info.height) * deviceScale).rounded(.up))
    }

    private func deviceRect(for key: TileKey) -> CGRect {
        let size = Double(Self.tileSize)
        let full = CGRect(x: Double(key.column) * size, y: Double(key.row) * size, width: size, height: size)
        return full.intersection(CGRect(origin: .zero, size: deviceImageSize))
    }

    private func viewRect(for key: TileKey) -> CGRect {
        let device = deviceRect(for: key)
        return CGRect(x: device.minX / backingScale, y: device.minY / backingScale,
                      width: device.width / backingScale, height: device.height / backingScale)
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
        visibleTileKeys().first { tiles[$0] == nil || staleTiles.contains($0) }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setNeedsRender()
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.surround.setFill()
        dirtyRect.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.interpolationQuality = .none
        for (key, image) in tiles {
            let rect = viewRect(for: key)
            guard rect.intersects(dirtyRect) else { continue }
            context.saveGState()
            // The view is flipped; CGImage draws bottom-up.
            context.translateBy(x: rect.minX, y: rect.maxY)
            context.scaleBy(x: 1, y: -1)
            context.draw(image, in: CGRect(origin: .zero, size: rect.size))
            context.restoreGState()
        }
    }

    // MARK: Painting

    private func strokePoint(for event: NSEvent) -> EngineSession.StrokePoint {
        let location = convert(event.locationInWindow, from: nil)
        let isTablet = event.subtype == .tabletPoint
        return EngineSession.StrokePoint(
            x: Double(location.x) / scale, y: Double(location.y) / scale,
            pressure: isTablet ? Double(event.pressure) : 1,
            xTilt: isTablet ? Double(event.tilt.x) : 0,
            yTilt: isTablet ? Double(event.tilt.y) : 0,
            timeMilliseconds: UInt32(truncatingIfNeeded: Int(event.timestamp * 1000)))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        document.beginStroke(at: strokePoint(for: event))
    }

    override func mouseDragged(with event: NSEvent) {
        document.continueStroke([strokePoint(for: event)])
    }

    override func mouseUp(with event: NSEvent) {
        document.continueStroke([strokePoint(for: event)])
        document.endStroke()
    }
}
