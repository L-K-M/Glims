import AppKit
import RigiUI

/// Pointer updates are scoped to the canvas's own document. A nil position
/// clears the readout when the pointer leaves the canvas or it detaches.
extension Notification.Name {
    static let glimsCanvasPointerChanged = Notification.Name("ch.lkmc.Glims.canvasPointerChanged")
    /// Posted by a document after it re-reads its selection.
    static let glimsSelectionChanged = Notification.Name("ch.lkmc.Glims.selectionChanged")
}

@MainActor
final class InfoPaletteController: NSViewController, PaletteContent {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.info"), title: "Info",
        contentSize: NSSize(width: 240, height: 170),
        sizing: .resizable(minimumContentSize: NSSize(width: 200, height: 144)),
        frameAutosaveName: "Glims.palette.info")

    private weak var document: ImageDocument?
    private let coordinateLabel = NSTextField(labelWithString: "X: —    Y: —")
    private let colorLabel = NSTextField(labelWithString: "sRGB: —")
    private let hsbLabel = NSTextField(labelWithString: "HSB: —")
    private let alphaLabel = NSTextField(labelWithString: "Alpha: —")
    private let sizeLabel = NSTextField(labelWithString: "W: —    H: —")
    private var timer: Timer?
    private var waitingPosition: InfoPointerSampling.Position?
    private lazy var sampling = InfoPointerSampling(read: { [weak self] position, completion in
        guard let document = self?.document else { return completion(.failure(ImageDocument.DocumentError.closed)) }
        document.sampleInfoColor(x: position.x, y: position.y, completion: completion)
    }, publish: { [weak self] position, result in
        guard let self, self.canDisplay, self.document != nil else { return }
        switch result {
        case .success(let sample):
            self.colorLabel.stringValue = "sRGB: R \(Self.percent(sample.red))  G \(Self.percent(sample.green))  B \(Self.percent(sample.blue))"
            self.hsbLabel.stringValue = Self.hsbText(red: sample.red, green: sample.green, blue: sample.blue)
            self.alphaLabel.stringValue = "Alpha: \(Self.percent(sample.alpha))"
        case .failure:
            self.colorLabel.stringValue = "sRGB: unavailable"
            self.hsbLabel.stringValue = "HSB: —"
            self.alphaLabel.stringValue = "Alpha: —"
        }
    })

    override func loadView() {
        let stack = NSStackView(views: [coordinateLabel, colorLabel, hsbLabel, alphaLabel, sizeLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for label in [coordinateLabel, colorLabel, hsbLabel, alphaLabel, sizeLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        view = stack
        refreshSelectionSize()
        NotificationCenter.default.addObserver(self, selector: #selector(pointerChanged(_:)),
                                               name: .glimsCanvasPointerChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged(_:)),
                                               name: .glimsSelectionChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        clear()
    }

    func retarget(to target: ImageDocument?) {
        defer { refreshSelectionSize() }
        guard document !== target else { return }
        document = target
        clear()
    }

    @objc private func selectionChanged(_ note: Notification) {
        guard let target = note.object as? ImageDocument, target === document else { return }
        refreshSelectionSize()
    }

    private func refreshSelectionSize() {
        guard isViewLoaded else { return }
        sizeLabel.stringValue = Self.sizeText(document?.selectionBounds)
    }

    func reload() {}

    private var canDisplay: Bool {
        isViewLoaded && view.window?.isVisible == true && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty
    }

    @objc private func pointerChanged(_ note: Notification) {
        guard let target = note.object as? ImageDocument, target === document else { return }
        guard canDisplay, let position = note.userInfo?["position"] as? InfoPointerSampling.Position else {
            clear()
            return
        }
        coordinateLabel.stringValue = "X: \(position.x)    Y: \(position.y)"
        colorLabel.stringValue = "sRGB: sampling…"
        hsbLabel.stringValue = "HSB: —"
        alphaLabel.stringValue = "Alpha: —"
        sampling.invalidate()
        waitingPosition = position
        guard timer == nil else { return }
        let next = Timer(timeInterval: 0.06, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.timer = nil
                guard self.canDisplay, let position = self.waitingPosition else { return self.clear() }
                self.waitingPosition = nil
                self.sampling.request(position)
            }
        }
        timer = next
        RunLoop.main.add(next, forMode: .common)
    }

    private func clear() {
        timer?.invalidate()
        timer = nil
        waitingPosition = nil
        sampling.invalidate()
        if isViewLoaded {
            coordinateLabel.stringValue = "X: —    Y: —"
            colorLabel.stringValue = "sRGB: —"
            hsbLabel.stringValue = "HSB: —"
            alphaLabel.stringValue = "Alpha: —"
        }
    }

    /// Photoshop's HSB readout of the encoded sRGB sample: hue in whole
    /// degrees (0 for neutral colors), saturation and brightness as
    /// percentages with the sRGB line's precision.
    static func hsbText(red: Double, green: Double, blue: Double) -> String {
        guard red.isFinite, green.isFinite, blue.isFinite else { return "HSB: —" }
        let r = min(max(red, 0), 1), g = min(max(green, 0), 1), b = min(max(blue, 0), 1)
        let high = max(r, g, b), low = min(r, g, b), range = high - low
        var hue = 0.0
        if range > 0 {
            if high == r { hue = (g - b) / range }
            else if high == g { hue = 2 + (b - r) / range }
            else { hue = 4 + (r - g) / range }
            hue = (hue * 60).truncatingRemainder(dividingBy: 360)
            if hue < 0 { hue += 360 }
        }
        let degrees = Int((hue + 0.5).rounded(.down)) % 360
        let saturation = high > 0 ? range / high : 0
        return "HSB: H \(degrees)°  S \(percent(saturation))  B \(percent(high))"
    }

    /// The selection's bounding box in pixels, as Photoshop's Info
    /// palette shows it; dashes when nothing is selected.
    static func sizeText(_ bounds: CGRect?) -> String {
        guard let bounds, bounds.width.isFinite, bounds.height.isFinite else { return "W: —    H: —" }
        return "W: \(Int(bounds.width.rounded()))    H: \(Int(bounds.height.rounded()))"
    }

    private static func percent(_ component: Double) -> String {
        let scaled = component * 100
        guard scaled.isFinite else { return "—" }
        return String(format: "%.1f%%", scaled)
    }
}
