import AppKit
import RigiUI

/// Both are scoped to one document (the notification object): the image's
/// pixels changed, or its window's viewport (scroll, zoom, view rotation,
/// window size) moved.
extension Notification.Name {
    static let glimsNavigatorImageChanged = Notification.Name("ch.lkmc.Glims.navigatorImageChanged")
    static let glimsNavigatorViewportChanged = Notification.Name("ch.lkmc.Glims.navigatorViewportChanged")
}

/// The window a Navigator drives. View-only: nothing here edits the image,
/// its history or its settings.
@MainActor
protocol NavigatorViewport: AnyObject {
    /// The viewport's four corners in image pixels, in order around it. A
    /// rotated view gives a rotated quadrilateral.
    var navigatorVisibleCorners: [CGPoint] { get }
    var navigatorZoomPercent: Int { get }
    func navigatorCenter(on imagePoint: CGPoint)
    func navigatorZoom(to percent: Int)
}

extension DocumentWindowController: NavigatorViewport {
    var navigatorVisibleCorners: [CGPoint] {
        let clip = scrollView.contentView
        let bounds = clip.bounds
        let scale = canvas.scale
        guard scale > 0 else { return [] }
        return [CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
                CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)].map {
            let point = canvas.convert($0, from: clip)
            return CGPoint(x: point.x / scale, y: point.y / scale)
        }
    }

    var navigatorZoomPercent: Int { canvas.zoomPercent }

    func navigatorCenter(on imagePoint: CGPoint) {
        guard !closeStarted, !imageDocument.isClosing, imagePoint.x.isFinite, imagePoint.y.isFinite else { return }
        center(on: imagePoint)
    }

    func navigatorZoom(to percent: Int) {
        guard !closeStarted, !imageDocument.isClosing else { return }
        zoom(to: ZoomLadder.clamped(percent))
    }
}

/// The Navigator's pure mapping between the palette's thumbnail, the image
/// and the zoom slider.
enum NavigatorGeometry {
    /// The long edge, in pixels, the thumbnail is rendered at.
    static let thumbnailPixels = 480.0

    /// The render scale for an image of `size`: never enlarged.
    static func renderScale(imageSize: CGSize) -> Double {
        let long = max(imageSize.width, imageSize.height)
        guard long.isFinite, long > 0 else { return 0 }
        return min(1, thumbnailPixels / long)
    }

    /// The image's thumbnail fitted and centered in `bounds`.
    static func thumbnailRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// The image pixel under `point` in a top-left-origin thumbnail view,
    /// held inside the image.
    static func imagePoint(_ point: CGPoint, thumbnail: CGRect, imageSize: CGSize) -> CGPoint? {
        guard thumbnail.width > 0, thumbnail.height > 0, point.x.isFinite, point.y.isFinite else { return nil }
        let x = (point.x - thumbnail.minX) / thumbnail.width * imageSize.width
        let y = (point.y - thumbnail.minY) / thumbnail.height * imageSize.height
        return CGPoint(x: min(max(x, 0), imageSize.width), y: min(max(y, 0), imageSize.height))
    }

    static func viewPoint(_ point: CGPoint, thumbnail: CGRect, imageSize: CGSize) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return thumbnail.origin }
        return CGPoint(x: thumbnail.minX + point.x / imageSize.width * thumbnail.width,
                       y: thumbnail.minY + point.y / imageSize.height * thumbnail.height)
    }

    private static var minimumZoom: Double { Double(ZoomLadder.steps[0]) }
    private static var maximumZoom: Double { Double(ZoomLadder.steps[ZoomLadder.steps.count - 1]) }

    /// The slider runs 0 ... 1 over the zoom range on a logarithmic scale,
    /// so each ladder step moves it a similar distance.
    static func sliderValue(zoomPercent: Int) -> Double {
        let percent = min(max(Double(zoomPercent), minimumZoom), maximumZoom)
        return log(percent / minimumZoom) / log(maximumZoom / minimumZoom)
    }

    static func zoomPercent(sliderValue: Double) -> Int {
        let value = sliderValue.isFinite ? min(max(sliderValue, 0), 1) : 0
        return ZoomLadder.clamped(Int((minimumZoom * pow(maximumZoom / minimumZoom, value)).rounded()))
    }

    /// A typed zoom: digits with an optional trailing percent sign.
    static func typedZoom(_ text: String) -> Int? {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") { trimmed.removeLast() }
        guard let value = Int(trimmed.trimmingCharacters(in: .whitespaces)), value > 0 else { return nil }
        return ZoomLadder.clamped(value)
    }
}

/// Draws the thumbnail and the viewport box; a click or drag centers the
/// window's view on that point.
@MainActor
final class NavigatorThumbnailView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var imageSize: CGSize = .zero { didSet { needsDisplay = true } }
    var viewportCorners: [CGPoint] = [] { didSet { needsDisplay = true } }
    var onNavigate: ((CGPoint) -> Void)?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var thumbnailRect: CGRect {
        NavigatorGeometry.thumbnailRect(imageSize: imageSize, in: bounds.insetBy(dx: 6, dy: 6))
    }

    /// The viewport box in this view's coordinates.
    var viewportBox: [CGPoint] {
        let rect = thumbnailRect
        return viewportCorners.map { NavigatorGeometry.viewPoint($0, thumbnail: rect, imageSize: imageSize) }
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.42, alpha: 1).setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = thumbnailRect
        guard !rect.isEmpty else { return }
        NSColor.white.setFill()
        rect.fill()
        if let image {
            context.saveGState()
            // The view is flipped; CGImage draws bottom-up.
            context.translateBy(x: 0, y: rect.maxY + rect.minY)
            context.scaleBy(x: 1, y: -1)
            context.interpolationQuality = .medium
            context.draw(image, in: rect)
            context.restoreGState()
        }
        let box = viewportBox
        guard box.count == 4 else { return }
        context.saveGState()
        context.clip(to: rect.insetBy(dx: -1, dy: -1))
        context.addLines(between: box)
        context.closePath()
        context.setStrokeColor(NSColor.systemRed.cgColor)
        context.setLineWidth(1.5)
        context.strokePath()
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) { navigate(event) }
    override func mouseDragged(with event: NSEvent) { navigate(event) }

    private func navigate(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let imagePoint = NavigatorGeometry.imagePoint(point, thumbnail: thumbnailRect, imageSize: imageSize)
        else { return }
        onNavigate?(imagePoint)
    }
}

/// Window ▸ Navigator: the front image's thumbnail with the visible area
/// boxed, and zoom controls, as in Photoshop 4. View-only.
@MainActor
final class NavigatorPaletteController: NSViewController, PaletteContent {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.navigator"), title: "Navigator",
        contentSize: NSSize(width: 240, height: 210),
        sizing: .resizable(minimumContentSize: NSSize(width: 200, height: 150)),
        frameAutosaveName: "Glims.palette.navigator")

    /// Coalesces pixel changes during a stroke into one thumbnail render.
    private static let refreshDelay: TimeInterval = 0.25

    private let viewportFor: (ImageDocument) -> NavigatorViewport?
    private weak var document: ImageDocument?
    let thumbnailView = NavigatorThumbnailView()
    let zoomField = NSTextField(string: "")
    let zoomSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    let zoomOutButton = NSButton()
    let zoomInButton = NSButton()
    /// Completed thumbnail renders, for the smoke test.
    private(set) var renderCount = 0
    private var renderGeneration = 0
    private var renderInFlight = false
    private var renderPending = false
    private var refreshTimer: Timer?
    /// A coalesced refresh or a render is scheduled or running.
    var isRefreshing: Bool { refreshTimer != nil || renderInFlight || renderPending }
    private let renderQueue = DispatchQueue(label: "ch.lkmc.Glims.navigator.render", qos: .utility)

    init(viewport: @escaping (ImageDocument) -> NavigatorViewport?) {
        viewportFor = viewport
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func loadView() {
        configure(zoomOutButton, symbol: "minus.magnifyingglass", label: "Zoom Out", action: #selector(zoomOut(_:)))
        configure(zoomInButton, symbol: "plus.magnifyingglass", label: "Zoom In", action: #selector(zoomIn(_:)))
        zoomSlider.target = self
        zoomSlider.action = #selector(sliderMoved(_:))
        zoomSlider.isContinuous = true
        zoomSlider.controlSize = .small
        zoomSlider.setAccessibilityLabel("Zoom")
        zoomField.target = self
        zoomField.action = #selector(zoomTyped(_:))
        zoomField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        zoomField.controlSize = .small
        zoomField.alignment = .right
        zoomField.setAccessibilityLabel("Zoom percent")
        zoomField.widthAnchor.constraint(equalToConstant: 52).isActive = true

        let controls = NSStackView(views: [zoomField, zoomOutButton, zoomSlider, zoomInButton])
        controls.orientation = .horizontal
        controls.spacing = 4
        controls.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        thumbnailView.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
        thumbnailView.setAccessibilityElement(true)
        thumbnailView.setAccessibilityRole(.image)
        thumbnailView.setAccessibilityLabel("Image overview; click to show that area")
        thumbnailView.onNavigate = { [weak self] point in
            guard let self, let document = self.document else { return }
            self.viewportFor(document)?.navigatorCenter(on: point)
        }
        let stack = NSStackView(views: [thumbnailView, controls])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 6
        view = stack
        NotificationCenter.default.addObserver(self, selector: #selector(imageChanged(_:)),
                                               name: .glimsNavigatorImageChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(viewportChanged(_:)),
                                               name: .glimsNavigatorViewportChanged, object: nil)
        refreshAll()
    }

    private func configure(_ button: NSButton, symbol: String, label: String, action: Selector) {
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        button.imagePosition = .imageOnly
        button.toolTip = label
        button.target = self
        button.action = action
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshAll()
    }

    func retarget(to target: ImageDocument?) {
        guard document !== target else {
            if refreshViewport() { requestThumbnail() }
            return
        }
        document = target
        renderGeneration += 1
        thumbnailView.image = nil
        refreshAll()
    }

    private var canDisplay: Bool {
        isViewLoaded && view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
    }

    private func refreshAll() {
        refreshViewport()
        requestThumbnail()
    }

    /// Returns whether the image size changed, which needs a new thumbnail.
    @discardableResult
    private func refreshViewport() -> Bool {
        guard isViewLoaded else { return false }
        let viewport = document.flatMap(viewportFor)
        let enabled = viewport != nil
        for control in [zoomField, zoomSlider, zoomOutButton, zoomInButton] as [NSControl] { control.isEnabled = enabled }
        guard let document, let viewport else {
            thumbnailView.imageSize = .zero
            thumbnailView.viewportCorners = []
            zoomField.stringValue = ""
            return false
        }
        let size = CGSize(width: document.info.width, height: document.info.height)
        let resized = thumbnailView.imageSize != size
        if resized {
            thumbnailView.imageSize = size
            // A render started at the old size must not land afterwards.
            renderGeneration += 1
        }
        thumbnailView.viewportCorners = viewport.navigatorVisibleCorners
        let zoom = viewport.navigatorZoomPercent
        if zoomField.currentEditor() == nil { zoomField.stringValue = "\(zoom)%" }
        zoomSlider.doubleValue = NavigatorGeometry.sliderValue(zoomPercent: zoom)
        return resized
    }

    @objc private func viewportChanged(_ note: Notification) {
        guard (note.object as? ImageDocument) === document, canDisplay else { return }
        if refreshViewport() { requestThumbnail() }
    }

    @objc private func imageChanged(_ note: Notification) {
        guard (note.object as? ImageDocument) === document, canDisplay, refreshTimer == nil else { return }
        let timer = Timer(timeInterval: Self.refreshDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTimer = nil
                self?.requestThumbnail()
            }
        }
        refreshTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    /// One render at a time; a request during a render runs once after it.
    private func requestThumbnail() {
        guard canDisplay, let document, !document.isClosing else { return }
        guard !renderInFlight else { renderPending = true; return }
        let size = CGSize(width: document.info.width, height: document.info.height)
        let scale = NavigatorGeometry.renderScale(imageSize: size)
        guard scale > 0 else { return }
        let area = CGRect(x: 0, y: 0, width: max(1, (size.width * scale).rounded(.up)),
                          height: max(1, (size.height * scale).rounded(.up)))
        let session = document.session, image = document.image, generation = renderGeneration
        renderInFlight = true
        renderQueue.async {
            let result = Result { try session.render(image, scale: scale, area: area) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.renderInFlight = false
                    if generation == self.renderGeneration {
                        // A failed render (a closing image) leaves no stale picture.
                        self.thumbnailView.image = try? result.get()
                        self.renderCount += 1
                    }
                    if self.renderPending {
                        self.renderPending = false
                        self.requestThumbnail()
                    }
                }
            }
        }
    }

    private func zoom(to percent: Int) {
        guard let document, let viewport = viewportFor(document) else { return NSSound.beep() }
        viewport.navigatorZoom(to: percent)
        refreshViewport()
    }

    @objc private func zoomOut(_ sender: Any?) {
        guard let document, let viewport = viewportFor(document) else { return NSSound.beep() }
        zoom(to: ZoomLadder.zoomOut(from: viewport.navigatorZoomPercent))
    }

    @objc private func zoomIn(_ sender: Any?) {
        guard let document, let viewport = viewportFor(document) else { return NSSound.beep() }
        zoom(to: ZoomLadder.zoomIn(from: viewport.navigatorZoomPercent))
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        zoom(to: NavigatorGeometry.zoomPercent(sliderValue: sender.doubleValue))
    }

    /// The field is still editing while its action runs, so the refresh
    /// leaves it alone; show the applied zoom here.
    @objc private func zoomTyped(_ sender: NSTextField) {
        if let percent = NavigatorGeometry.typedZoom(sender.stringValue) {
            zoom(to: percent)
        } else {
            NSSound.beep()
        }
        let current = document.flatMap(viewportFor)?.navigatorZoomPercent
        sender.stringValue = current.map { "\($0)%" } ?? ""
    }
}
