import AppKit

/// The preview view under Select > Color Range's controls. It draws either
/// the weight mask or the projection thumbnail, and a click maps back to
/// image coordinates so both modes sample the same pixel.
@MainActor
private final class ColorRangePreviewView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var imageSize: CGSize = .zero
    var onSample: ((CGPoint) -> Void)?

    override var isFlipped: Bool { true }

    private var thumbnailRect: CGRect {
        NavigatorGeometry.thumbnailRect(imageSize: imageSize, in: bounds.insetBy(dx: 4, dy: 4))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.42, alpha: 1).setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = thumbnailRect
        guard !rect.isEmpty else { return }
        NSColor.white.setFill()
        rect.fill()
        guard let image else { return }
        context.saveGState()
        // The view is flipped; CGImage draws bottom-up.
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .medium
        context.draw(image, in: rect)
        context.restoreGState()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let imagePoint = NavigatorGeometry.imagePoint(point, thumbnail: thumbnailRect,
                                                            imageSize: imageSize) else { return }
        onSample?(imagePoint)
    }
}

/// Select > Color Range's utility panel. It stays modeless so the canvas
/// remains clickable: while it is open a canvas press samples a color for
/// the panel instead of running the current tool. Hand, Zoom and scrolling
/// keep working. OK replaces the selection as one command and closes;
/// Cancel and Escape close with no change.
@MainActor
final class ColorRangePanel: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// The engine preview's long-side cap; the panel renders it at 200 pt.
    static let previewMax: Int32 = 256
    /// Mirrors GLIMS_COLOR_RANGE_MAX_SAMPLES.
    private static let maximumSamples = 64

    private enum SampleAction: CaseIterable {
        case sample, add, subtract

        var symbolName: String {
            switch self {
            case .sample: return "eyedropper"
            case .add: return "eyedropper.full"
            case .subtract: return "eyedropper.halffull"
            }
        }

        var toolTip: String {
            switch self {
            case .sample: return "Sample Color"
            case .add: return "Add to Sample"
            case .subtract: return "Subtract from Sample"
            }
        }
    }

    private let imageDocument: ImageDocument
    private let tools: CanvasToolController

    /// Called once when the panel closes for any reason.
    var onClose: (() -> Void)?

    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let fuzzinessSlider = NSSlider(value: 40, minValue: 0, maxValue: 200,
                                           target: nil, action: nil)
    private let fuzzinessField = NSTextField(string: "40")
    private let preview = ColorRangePreviewView()
    private let selectionRadio = NSButton(radioButtonWithTitle: "Selection", target: nil, action: nil)
    private let imageRadio = NSButton(radioButtonWithTitle: "Image", target: nil, action: nil)
    private let invertCheckbox = NSButton(checkboxWithTitle: "Invert", target: nil, action: nil)
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var actionButtons: [SampleAction: NSButton] = [:]

    private var samples: [EngineSession.ColorRangeSettings.Sample] = []
    private var action: SampleAction = .sample
    private var showsMask = true
    private var finished = false
    private var generation = 0
    private var thumbnailGeneration = 0
    private var imageThumbnail: CGImage?

    /// The last delivered Selection preview, for the smoke test.
    private(set) var maskWidth = 0
    private(set) var maskHeight = 0
    private(set) var maskBytes: [UInt8] = []

    init(document: ImageDocument, tools: CanvasToolController) {
        self.imageDocument = document
        self.tools = tools
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 500),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Color Range"
        panel.isFloatingPanel = true
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
        tools.canvasSampler = { [weak self] point, flags in
            self?.sample(at: point, flags: flags)
        }
        preview.imageSize = CGSize(width: imageDocument.info.width, height: imageDocument.info.height)
        refreshPreview()
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var settings: EngineSession.ColorRangeSettings {
        var value = EngineSession.ColorRangeSettings()
        value.mode = EngineSession.ColorRangeSettings.Mode.allCases[modePopup.indexOfSelectedItem]
        value.fuzziness = fuzziness
        value.invert = invertCheckbox.state == .on
        value.samples = samples
        return value
    }

    private var fuzziness: Double {
        get { fuzzinessSlider.doubleValue }
        set {
            fuzzinessSlider.doubleValue = newValue
            fuzzinessField.stringValue = String(Int(newValue.rounded()))
        }
    }

    private func buildContent(in panel: NSPanel) {
        modePopup.removeAllItems()
        modePopup.addItems(withTitles: EngineSession.ColorRangeSettings.Mode.allCases.map(\.title))
        modePopup.selectItem(at: 0)
        modePopup.setAccessibilityLabel("Color range mode")
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))

        fuzzinessSlider.setAccessibilityLabel("Fuzziness")
        fuzzinessSlider.isContinuous = true
        fuzzinessSlider.target = self
        fuzzinessSlider.action = #selector(fuzzinessSliderChanged(_:))
        fuzzinessField.setAccessibilityLabel("Fuzziness value")
        fuzzinessField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        fuzzinessField.target = self
        fuzzinessField.action = #selector(fuzzinessFieldChanged(_:))
        fuzzinessField.delegate = self

        preview.widthAnchor.constraint(equalToConstant: 200).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 200).isActive = true
        preview.setAccessibilityLabel("Color range preview; click to sample")
        preview.onSample = { [weak self] point in self?.sample(at: point, flags: []) }

        selectionRadio.state = .on
        selectionRadio.setAccessibilityLabel("Selection preview")
        selectionRadio.target = self
        selectionRadio.action = #selector(previewModeChanged(_:))
        imageRadio.state = .off
        imageRadio.setAccessibilityLabel("Image preview")
        imageRadio.target = self
        imageRadio.action = #selector(previewModeChanged(_:))

        for kind in SampleAction.allCases {
            let button = NSButton(image: NSImage(systemSymbolName: kind.symbolName,
                                                 accessibilityDescription: nil) ?? NSImage(),
                                  target: self, action: #selector(eyedropperChanged(_:)))
            button.setButtonType(.pushOnPushOff)
            button.imagePosition = .imageOnly
            button.toolTip = kind.toolTip
            button.setAccessibilityLabel(kind.toolTip)
            actionButtons[kind] = button
        }
        actionButtons[.sample]?.state = .on

        invertCheckbox.setAccessibilityLabel("Invert color range")
        invertCheckbox.target = self
        invertCheckbox.action = #selector(invertChanged(_:))

        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel color range")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        okButton.keyEquivalent = "\r"
        okButton.setAccessibilityLabel("Apply color range")
        okButton.target = self
        okButton.action = #selector(commit)

        let fuzzinessRow = NSStackView(views: [NSTextField(labelWithString: "Fuzziness"),
                                               fuzzinessSlider, fuzzinessField])
        fuzzinessRow.spacing = 8
        let modeRow = NSStackView(views: [NSTextField(labelWithString: "Select:"), modePopup])
        modeRow.spacing = 8
        let previewRow = NSStackView(views: [selectionRadio, imageRadio])
        previewRow.spacing = 8
        let eyedroppers = NSStackView(views: SampleAction.allCases.map { actionButtons[$0]! })
        eyedroppers.spacing = 8
        let buttons = NSStackView(views: [NSView(), cancelButton, okButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [modeRow, fuzzinessRow, preview, previewRow,
                                        eyedroppers, invertCheckbox, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        panel.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            modeRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        panel.setContentSize(NSSize(width: max(360, stack.fittingSize.width + 32),
                                    height: stack.fittingSize.height))
        updatePreviewMode()
    }

    // MARK: Actions

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        let fixed = sender.indexOfSelectedItem != 0
        fuzzinessSlider.isEnabled = !fixed
        fuzzinessField.isEnabled = !fixed
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func fuzzinessSliderChanged(_ sender: NSSlider) {
        fuzziness = sender.doubleValue
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func fuzzinessFieldChanged(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if let value = Int(text), (0...200).contains(value) {
            fuzziness = Double(value)
        } else {
            sender.stringValue = String(Int(fuzziness.rounded()))
        }
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func previewModeChanged(_ sender: NSButton) {
        showsMask = sender === selectionRadio
        selectionRadio.state = showsMask ? .on : .off
        imageRadio.state = showsMask ? .off : .on
        if !showsMask, imageThumbnail == nil {
            requestImageThumbnail()
        }
        updatePreviewMode()
    }

    @objc private func eyedropperChanged(_ sender: NSButton) {
        guard let kind = actionButtons.first(where: { $0.value === sender })?.key else { return }
        action = kind
        for (other, button) in actionButtons where other != kind {
            button.state = .off
        }
        sender.state = .on
    }

    @objc private func invertChanged(_ sender: NSButton) {
        updateOkEnabled()
        refreshPreview()
    }

    @objc func commit() {
        let value = settings.engineSettings
        guard value.isValid, !finished else { return }
        imageDocument.selectColorRange(value)
        finish()
    }

    @objc func cancel() {
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        tools.canvasSampler = nil
        window?.orderOut(nil)
        onClose?()
    }

    // MARK: Sampling

    /// Samples `imagePoint` (image pixels) into the list. Shift adds, Option
    /// subtracts, overriding the selected eyedropper.
    func sample(at imagePoint: CGPoint, flags: NSEvent.ModifierFlags) {
        let info = imageDocument.info
        let x = Int(floor(imagePoint.x)), y = Int(floor(imagePoint.y))
        guard x >= 0, y >= 0, x < info.width, y < info.height else { return }
        let sampled: EngineSession.SampledColor
        do {
            sampled = try imageDocument.session.sampleColor(imageDocument.image, x: x, y: y)
        } catch {
            return
        }

        let kind: SampleAction
        if flags.contains(.shift) {
            kind = .add
        } else if flags.contains(.option) {
            kind = .subtract
        } else {
            kind = action
        }

        let color = EngineSession.ColorRangeSettings.Sample(red: sampled.red, green: sampled.green,
                                                            blue: sampled.blue,
                                                            subtract: kind == .subtract)
        switch kind {
        case .sample:
            samples = [color]
        case .add, .subtract:
            guard samples.count < Self.maximumSamples else { return }
            samples.append(color)
        }
        updateOkEnabled()
        refreshPreview()
    }

    // MARK: Preview

    private func updateOkEnabled() {
        okButton.isEnabled = settings.engineSettings.isValid
    }

    private func refreshPreview() {
        updateOkEnabled()
        generation &+= 1
        let expected = generation
        let value = settings.engineSettings
        guard value.isValid else {
            maskWidth = 0
            maskHeight = 0
            maskBytes = []
            updatePreviewMode()
            return
        }
        imageDocument.colorRangePreview(imageDocument.image, settings: value,
                                    maxSize: Self.previewMax) { [weak self] result in
            guard let self, expected == self.generation else { return }
            if let result {
                self.maskWidth = result.width
                self.maskHeight = result.height
                self.maskBytes = result.mask
            }
            self.updatePreviewMode()
        }
    }

    private func requestImageThumbnail() {
        thumbnailGeneration &+= 1
        let expected = thumbnailGeneration
        let session = imageDocument.session
        let image = imageDocument.image
        let info = imageDocument.info
        let scale = min(1.0, Double(Self.previewMax) / Double(max(info.width, info.height)))
        guard scale > 0, info.width > 0, info.height > 0 else { return }
        let area = CGRect(x: 0, y: 0,
                          width: max(1, (Double(info.width) * scale).rounded(.up)),
                          height: max(1, (Double(info.height) * scale).rounded(.up)))
        DispatchQueue.global(qos: .userInitiated).async {
            let rendered = try? session.render(image, scale: scale, area: area)
            DispatchQueue.main.async { [weak self] in
                guard let self, expected == self.thumbnailGeneration else { return }
                self.imageThumbnail = rendered
                self.updatePreviewMode()
            }
        }
    }

    private func maskImage() -> CGImage? {
        let count = maskWidth * maskHeight
        guard count > 0, maskBytes.count >= count else { return nil }
        let data = Data(maskBytes.prefix(count)) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: maskWidth, height: maskHeight, bitsPerComponent: 8,
                       bitsPerPixel: 8, bytesPerRow: maskWidth,
                       space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private func updatePreviewMode() {
        preview.image = showsMask ? maskImage() : imageThumbnail
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === fuzzinessField else { return }
        fuzzinessFieldChanged(fuzzinessField)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        finish()
    }
}
