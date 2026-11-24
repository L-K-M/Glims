import AppKit

/// The mask preview under Replace Color's controls. It draws the matched
/// area as a grayscale image; the canvas sampler owns clicks.
@MainActor
private final class ReplaceColorMaskView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var imageSize: CGSize = .zero { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.42, alpha: 1).setFill()
        bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext, let image else { return }
        let rect = NavigatorGeometry.thumbnailRect(imageSize: imageSize, in: bounds.insetBy(dx: 4, dy: 4))
        guard !rect.isEmpty else { return }
        NSColor.white.setFill()
        rect.fill()
        context.saveGState()
        // The view is flipped; CGImage draws bottom-up.
        context.translateBy(x: 0, y: rect.maxY + rect.minY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .medium
        context.draw(image, in: rect)
        context.restoreGState()
    }
}

/// Image > Adjust > Replace Color's utility panel. It stays modeless so the
/// canvas remains clickable: while it is open a canvas press samples a color
/// for the panel instead of running the current tool. Hand, Zoom and
/// scrolling keep working. OK commits the live filter as one undo step;
/// Cancel and Escape abort it and leave no trace.
@MainActor
final class ReplaceColorPanel: NativeFilterPanel, NSTextFieldDelegate {
    nonisolated static let operation = "glims:replace-color"
    /// The engine preview's long-side cap; the panel renders it at 160 pt.
    static let previewMax: Int32 = 256
    /// Mirrors GLIMS_REPLACE_COLOR_MAX_SAMPLES.
    static let maximumSamples = 8

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

    private let tools: CanvasToolController?
    private let fuzzinessSlider = NSSlider(value: 40, minValue: 0, maxValue: 200,
                                           target: nil, action: nil)
    private let fuzzinessField = NSTextField(string: "40")
    private let preview = ReplaceColorMaskView()
    private let hueSlider = NSSlider(value: 0, minValue: -180, maxValue: 180,
                                     target: nil, action: nil)
    private let saturationSlider = NSSlider(value: 0, minValue: -100, maxValue: 100,
                                            target: nil, action: nil)
    private let lightnessSlider = NSSlider(value: 0, minValue: -100, maxValue: 100,
                                           target: nil, action: nil)
    private let hueField = NSTextField()
    private let saturationField = NSTextField()
    private let lightnessField = NSTextField()
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private var actionButtons: [SampleAction: NSButton] = [:]

    private var samples: [EngineSession.ReplaceColorSettings.Sample] = []
    private var fuzzinessValue: Double = 40
    private var hueValue: Double = 0
    private var saturationValue: Double = 0
    private var lightnessValue: Double = 0
    private var action: SampleAction = .sample
    private var generation = 0
    private var samplerInstalled = false

    /// The last delivered mask preview, for the smoke test.
    private(set) var maskWidth = 0
    private(set) var maskHeight = 0
    private(set) var maskBytes: [UInt8] = []

    init?(document imageDocument: ImageDocument,
          operation: EngineSession.FilterOperation,
          properties: [EngineSession.FilterProperty],
          filter: Int32,
          initialValues: [String: EngineSession.FilterValue],
          tools: CanvasToolController?) {
        guard operation.name == Self.operation, operation.support == .supported,
              Self.matches(properties) else { return nil }
        self.tools = tools
        let decoded = EngineSession.ReplaceColorSettings(values: initialValues)
        fuzzinessValue = decoded.fuzziness
        samples = decoded.samples
        hueValue = decoded.hue
        saturationValue = decoded.saturation
        lightnessValue = decoded.lightness
        super.init(document: imageDocument, operation: operation, properties: properties,
                   filter: filter, initialValues: initialValues)
        tools?.canvasSampler = { [weak self] point, flags in
            self?.sample(at: point, flags: flags)
        }
        samplerInstalled = tools != nil
        preview.imageSize = CGSize(width: imageDocument.info.width, height: imageDocument.info.height)
        refreshPreview()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The full property contract this form drives: fuzziness, sample-count,
    /// the eight sample colors and subtract flags, and the three corrections.
    /// Anything else stays on the generic form.
    static func matches(_ properties: [EngineSession.FilterProperty]) -> Bool {
        guard properties.count == EngineSession.ReplaceColorSettings.propertyNames.count else { return false }
        let names = Set(properties.map(\.name))
        guard names.count == properties.count else { return false }
        for name in EngineSession.ReplaceColorSettings.propertyNames {
            guard let property = properties.first(where: { $0.name == name }) else { return false }
            let kind: EngineSession.FilterValueKind
            if name == "sample-count" { kind = .integer }
            else if name.hasPrefix("subtract-") { kind = .boolean }
            else if name.hasPrefix("sample-") { kind = .color }
            else { kind = .number }
            guard property.kind == kind else { return false }
        }
        return true
    }

    private var settings: EngineSession.ReplaceColorSettings {
        var value = EngineSession.ReplaceColorSettings()
        value.fuzziness = fuzzinessValue
        value.samples = samples
        value.hue = hueValue
        value.saturation = saturationValue
        value.lightness = lightnessValue
        return value
    }

    override func buildContent(in panel: NSPanel, properties: [EngineSession.FilterProperty]) {
        fuzzinessSlider.setAccessibilityLabel("Fuzziness")
        fuzzinessSlider.isContinuous = true
        fuzzinessSlider.target = self
        fuzzinessSlider.action = #selector(fuzzinessSliderChanged(_:))
        fuzzinessField.setAccessibilityLabel("Fuzziness value")
        fuzzinessField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        fuzzinessField.target = self
        fuzzinessField.action = #selector(fieldCommitted(_:))
        fuzzinessField.delegate = self
        registerBinding("fuzziness") { [weak self] value in
            guard let self, case .number(let number) = value else { return }
            self.fuzzinessValue = number
            self.fuzzinessSlider.doubleValue = number
            self.fuzzinessField.stringValue = String(Int(number.rounded()))
        }

        preview.widthAnchor.constraint(equalToConstant: 160).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 160).isActive = true
        preview.setAccessibilityLabel("Replace Color preview; click the canvas to sample")

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

        let pairs: [(String, String, String, NSSlider, NSTextField)] = [
            ("Hue", "Hue degrees", "°", hueSlider, hueField),
            ("Saturation", "Saturation percent", "%", saturationSlider, saturationField),
            ("Lightness", "Lightness percent", "%", lightnessSlider, lightnessField),
        ]
        var rows: [[NSView]] = []
        for (name, axName, unit, slider, field) in pairs {
            slider.setAccessibilityLabel(axName)
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            slider.widthAnchor.constraint(equalToConstant: 200).isActive = true
            field.setAccessibilityLabel(axName)
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
            field.target = self
            field.action = #selector(fieldCommitted(_:))
            field.delegate = self
            let number = NSStackView(views: [field, NSTextField(labelWithString: unit)])
            number.spacing = 4
            rows.append([NSTextField(labelWithString: name), slider, number])
            switch name {
            case "Hue":
                registerBinding("hue") { [weak self] value in
                    guard let self, case .number(let number) = value else { return }
                    self.hueValue = number
                    self.hueSlider.doubleValue = number
                    self.hueField.stringValue = Self.format(number)
                }
            case "Saturation":
                registerBinding("saturation") { [weak self] value in
                    guard let self, case .number(let number) = value else { return }
                    self.saturationValue = number
                    self.saturationSlider.doubleValue = number
                    self.saturationField.stringValue = Self.format(number)
                }
            case "Lightness":
                registerBinding("lightness") { [weak self] value in
                    guard let self, case .number(let number) = value else { return }
                    self.lightnessValue = number
                    self.lightnessSlider.doubleValue = number
                    self.lightnessField.stringValue = Self.format(number)
                }
            default:
                assertionFailure("Replace Color has no \(name) row")
            }
        }
        let toneGrid = NSGridView(views: rows)
        toneGrid.rowSpacing = 8
        toneGrid.columnSpacing = 8
        toneGrid.column(at: 0).xPlacement = .trailing

        let fuzzinessRow = NSStackView(views: [NSTextField(labelWithString: "Fuzziness"),
                                               fuzzinessSlider, fuzzinessField])
        fuzzinessRow.spacing = 8
        let eyedroppers = NSStackView(views: SampleAction.allCases.map { actionButtons[$0]! })
        eyedroppers.spacing = 8

        applyButton.keyEquivalent = "\r"
        applyButton.setAccessibilityLabel("Apply Replace Color")
        applyButton.target = self
        applyButton.action = #selector(apply)
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel Replace Color")
        let buttons = NSStackView(views: [NSView(), cancelButton, applyButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [fuzzinessRow, preview, eyedroppers, toneGrid,
                                        statusField, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusField.textColor = .systemRed
        statusField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        statusField.maximumNumberOfLines = 2
        statusField.lineBreakMode = .byTruncatingTail
        statusField.setAccessibilityLabel("Filter status")
        statusField.alignment = .left
        statusField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])
        panel.setContentSize(NSSize(width: max(360, stack.fittingSize.width + 32),
                                    height: stack.fittingSize.height))
        fuzzinessSlider.doubleValue = fuzzinessValue
        fuzzinessField.stringValue = String(Int(fuzzinessValue.rounded()))
        displayTone()
        updateOkEnabled()
        panel.center()
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: value)) ?? "0"
    }

    private func displayTone() {
        hueSlider.doubleValue = hueValue
        saturationSlider.doubleValue = saturationValue
        lightnessSlider.doubleValue = lightnessValue
        hueField.stringValue = Self.format(hueValue)
        saturationField.stringValue = Self.format(saturationValue)
        lightnessField.stringValue = Self.format(lightnessValue)
    }

    // MARK: Actions

    @objc private func fuzzinessSliderChanged(_ sender: NSSlider) {
        fuzzinessValue = sender.doubleValue
        fuzzinessField.stringValue = String(Int(fuzzinessValue.rounded()))
        writeFuzziness()
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func sliderChanged(_ sender: NSSlider) {
        let tone: Tone
        if sender === hueSlider { hueValue = sender.doubleValue; tone = .hue }
        else if sender === saturationSlider { saturationValue = sender.doubleValue; tone = .saturation }
        else if sender === lightnessSlider { lightnessValue = sender.doubleValue; tone = .lightness }
        else { return }
        displayTone()
        writeTone(tone)
    }

    @objc private func fieldCommitted(_ sender: Any?) {
        guard let field = sender as? NSTextField else { return }
        if field === fuzzinessField {
            let text = field.stringValue.trimmingCharacters(in: .whitespaces)
            if let value = Int(text), (0...200).contains(value) {
                fuzzinessValue = Double(value)
                fuzzinessSlider.doubleValue = fuzzinessValue
                writeFuzziness()
                refreshPreview()
            } else {
                field.stringValue = String(Int(fuzzinessValue.rounded()))
            }
        } else if field === hueField {
            commitNumber(field, range: -180...180) { self.hueValue = $0 }
        } else if field === saturationField {
            commitNumber(field, range: -100...100) { self.saturationValue = $0 }
        } else if field === lightnessField {
            commitNumber(field, range: -100...100) { self.lightnessValue = $0 }
        }
        updateOkEnabled()
    }

    private func commitNumber(_ field: NSTextField, range: ClosedRange<Double>,
                              assign: (Double) -> Void) {
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanner = Scanner(string: text)
        scanner.locale = Locale.current
        guard let value = scanner.scanDouble(), scanner.isAtEnd,
              value.isFinite, range.contains(value) else {
            field.stringValue = Self.format(settingsValue(for: field))
            return
        }
        assign(value)
        displayTone()
        writeTone(field === hueField ? .hue : field === saturationField ? .saturation : .lightness)
    }

    private func settingsValue(for field: NSTextField) -> Double {
        if field === hueField { return hueValue }
        if field === saturationField { return saturationValue }
        return lightnessValue
    }

    @objc private func eyedropperChanged(_ sender: NSButton) {
        guard let kind = actionButtons.first(where: { $0.value === sender })?.key else { return }
        action = kind
        for (other, button) in actionButtons where other != kind {
            button.state = .off
        }
        sender.state = .on
    }

    @objc override func apply() {
        guard settings.isValid else { return }
        super.apply()
    }

    /// The sampler stays while a commit is queued, so a failed commit
    /// leaves a working panel; it goes once the panel finishes.
    override func panelDidFinish() {
        clearSampler()
    }

    override func windowWillClose(_ notification: Notification) {
        clearSampler()
        super.windowWillClose(notification)
    }

    private func clearSampler() {
        guard samplerInstalled else { return }
        samplerInstalled = false
        tools?.canvasSampler = nil
    }

    // MARK: Property writes

    private func writeFuzziness() {
        setProperty("fuzziness", .number(fuzzinessValue))
    }

    private enum Tone { case hue, saturation, lightness }

    /// Writes only the correction that changed: each write renders a
    /// preview, so a slider drag costs one render per tick.
    private func writeTone(_ tone: Tone) {
        switch tone {
        case .hue: setProperty("hue", .number(hueValue))
        case .saturation: setProperty("saturation", .number(saturationValue))
        case .lightness: setProperty("lightness", .number(lightnessValue))
        }
    }

    private static func clamped(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private func writeSamples(touched: [Int]) {
        setProperty("sample-count", .integer(Int64(samples.count)))
        for index in touched where samples.indices.contains(index) {
            let sample = samples[index]
            setProperty("sample-\(index)",
                        .color(NSColor(srgbRed: CGFloat(Self.clamped(sample.red)),
                                       green: CGFloat(Self.clamped(sample.green)),
                                       blue: CGFloat(Self.clamped(sample.blue)),
                                       alpha: 1)))
            setProperty("subtract-\(index)", .boolean(sample.subtract))
        }
    }

    // MARK: Sampling

    /// Samples `imagePoint` (image pixels) into the list. Shift adds, Option
    /// subtracts, overriding the selected eyedropper.
    func sample(at imagePoint: CGPoint, flags: NSEvent.ModifierFlags) {
        let info = imageDocument.info
        let x = Int(floor(imagePoint.x)), y = Int(floor(imagePoint.y))
        guard x >= 0, y >= 0, x < info.width, y < info.height, filter != nil else { return }
        let kind: SampleAction = flags.contains(.shift) ? .add : flags.contains(.option) ? .subtract : action
        imageDocument.colorRangeSample(x: x, y: y) { [weak self] sampled in
            guard let self, let sampled else { return }
            self.addSample(sampled, kind: kind)
        }
    }

    private func addSample(_ sampled: EngineSession.SampledColor, kind: SampleAction) {
        let color = EngineSession.ReplaceColorSettings.Sample(red: sampled.red,
                                                              green: sampled.green,
                                                              blue: sampled.blue,
                                                              subtract: kind == .subtract)
        var touched: [Int] = []
        switch kind {
        case .sample:
            samples = [color]
            touched = [0]
        case .add, .subtract:
            // A full list refuses the pick audibly rather than ignoring it.
            guard samples.count < Self.maximumSamples else {
                NSSound.beep()
                return
            }
            samples.append(color)
            touched = [samples.count - 1]
        }
        writeSamples(touched: touched)
        updateOkEnabled()
        refreshPreview()
    }

    // MARK: Preview

    private func updateOkEnabled() {
        applyButton.isEnabled = settings.isValid
    }

    private func refreshPreview() {
        updateOkEnabled()
        generation &+= 1
        let expected = generation
        var cr = EngineSession.ColorRangeSettings()
        cr.mode = .sampled
        cr.fuzziness = fuzzinessValue
        cr.invert = false
        cr.samples = samples.map {
            .init(red: $0.red, green: $0.green, blue: $0.blue, subtract: $0.subtract)
        }
        guard cr.isValid else {
            maskWidth = 0
            maskHeight = 0
            maskBytes = []
            preview.image = nil
            return
        }
        imageDocument.colorRangePreview(settings: cr, maxSize: Self.previewMax) { [weak self] result in
            guard let self, expected == self.generation else { return }
            if let result {
                self.maskWidth = result.width
                self.maskHeight = result.height
                self.maskBytes = result.mask
            } else {
                self.maskWidth = 0
                self.maskHeight = 0
                self.maskBytes = []
            }
            self.preview.image = self.makeMaskImage()
        }
    }

    private func makeMaskImage() -> CGImage? {
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

    func controlTextDidEndEditing(_ notification: Notification) {
        fieldCommitted(notification.object)
    }
}
