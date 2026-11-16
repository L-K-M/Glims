import AppKit
import RigiUI

/// Pointer updates are scoped to the canvas's own document. A nil position
/// clears the readout when the pointer leaves the canvas or it detaches.
extension Notification.Name {
    static let glimsCanvasPointerChanged = Notification.Name("ch.lkmc.Glims.canvasPointerChanged")
}

@MainActor
final class InfoPaletteController: NSViewController, PaletteContent {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.info"), title: "Info",
        contentSize: NSSize(width: 240, height: 126),
        sizing: .resizable(minimumContentSize: NSSize(width: 200, height: 100)),
        frameAutosaveName: "Glims.palette.info")

    private weak var document: ImageDocument?
    private let coordinateLabel = NSTextField(labelWithString: "X: —    Y: —")
    private let colorLabel = NSTextField(labelWithString: "sRGB: —")
    private let alphaLabel = NSTextField(labelWithString: "Alpha: —")
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
            self.alphaLabel.stringValue = "Alpha: \(Self.percent(sample.alpha))"
        case .failure:
            self.colorLabel.stringValue = "sRGB: unavailable"
            self.alphaLabel.stringValue = "Alpha: —"
        }
    })

    override func loadView() {
        let stack = NSStackView(views: [coordinateLabel, colorLabel, alphaLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for label in [coordinateLabel, colorLabel, alphaLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        view = stack
        NotificationCenter.default.addObserver(self, selector: #selector(pointerChanged(_:)),
                                               name: .glimsCanvasPointerChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        clear()
    }

    func retarget(to target: ImageDocument?) {
        guard document !== target else { return }
        document = target
        clear()
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
            alphaLabel.stringValue = "Alpha: —"
        }
    }

    private static func percent(_ component: Double) -> String {
        let scaled = component * 100
        guard scaled.isFinite else { return "—" }
        return String(format: "%.1f%%", scaled)
    }
}
