import AppKit
import CoreGraphics
import RigiUI

/// Image > Adjust > Variations' sheet content and behavior. The accumulated
/// math lives in `VariationsModel`; this class owns the AppKit controls,
/// keeps the thumbnails current off the main thread and applies the final
/// settings through the document on OK.
@MainActor
final class VariationsForm {
    enum ThumbnailAction: Equatable {
        case original
        case currentPick
        case apply(VariationsModel.Direction)
    }

    /// The dialog's accumulated corrections. A click mutates it; every
    /// thumbnail shows what its own click would produce.
    var model = VariationsModel()
    /// Reports whether OK is usable (the settings are not identity).
    var onValidityChanged: ((Bool) -> Void)?

    private(set) var view: NSStackView
    private let originalButton: NSButton
    private let currentPickButton: NSButton
    private let lighterButton: NSButton
    private let darkerButton: NSButton
    private let lessSaturationButton: NSButton
    private let moreSaturationButton: NSButton
    private let colorButtons: [(VariationsModel.Direction, NSButton)]
    private let shadowRadio: NSButton
    private let midtoneRadio: NSButton
    private let highlightRadio: NSButton
    private let saturationRadio: NSButton
    private let rangeGroup: RadioGroup
    private let stepSlider: ClassicValueSlider
    private let clippingCheckbox: NSButton

    private var actions: [ObjectIdentifier: ThumbnailAction] = [:]
    private var previews: [ObjectIdentifier: EngineSession.VariationsPreview] = [:]
    private weak var document: ImageDocument?
    private var image: Int32 = 0
    private var layer: Int32 = 0
    private var generation = 0
    private let thumbnailSize: Int32 = 96

    init() {
        originalButton = Self.makeThumbnailButton("Original")
        currentPickButton = Self.makeThumbnailButton("Current Pick")
        lighterButton = Self.makeThumbnailButton("Lighter")
        darkerButton = Self.makeThumbnailButton("Darker")
        lessSaturationButton = Self.makeThumbnailButton("Less Saturation")
        moreSaturationButton = Self.makeThumbnailButton("More Saturation")
        colorButtons = [
            (.moreGreen, Self.makeThumbnailButton("More Green")),
            (.moreYellow, Self.makeThumbnailButton("More Yellow")),
            (.moreRed, Self.makeThumbnailButton("More Red")),
            (.moreMagenta, Self.makeThumbnailButton("More Magenta")),
            (.moreBlue, Self.makeThumbnailButton("More Blue")),
            (.moreCyan, Self.makeThumbnailButton("More Cyan")),
        ]

        shadowRadio = NSButton(radioButtonWithTitle: "Shadows", target: nil, action: nil)
        midtoneRadio = NSButton(radioButtonWithTitle: "Midtones", target: nil, action: nil)
        highlightRadio = NSButton(radioButtonWithTitle: "Highlights", target: nil, action: nil)
        saturationRadio = NSButton(radioButtonWithTitle: "Saturation", target: nil, action: nil)
        midtoneRadio.state = .on
        rangeGroup = RadioGroup([shadowRadio, midtoneRadio, highlightRadio, saturationRadio])

        stepSlider = ClassicValueSlider(title: "Fine to Coarse",
                                        range: 0...Double(VariationsModel.steps.count - 1),
                                        value: Double(VariationsModel.defaultStepIndex),
                                        unit: "", fractionDigits: 0)

        clippingCheckbox = NSButton(checkboxWithTitle: "Show Clipping", target: nil, action: nil)

        let saturationCenter = NSTextField(labelWithString: "Current Pick")
        saturationCenter.alignment = .center
        let grid = NSGridView(views: [
            [originalButton, NSGridCell.emptyContentView, colorButtons[0].1,
             NSGridCell.emptyContentView, lighterButton],
            [NSGridCell.emptyContentView, colorButtons[5].1, currentPickButton,
             colorButtons[1].1, NSGridCell.emptyContentView],
            [NSGridCell.emptyContentView, colorButtons[4].1, colorButtons[3].1,
             colorButtons[2].1, darkerButton],
            [lessSaturationButton, NSGridCell.emptyContentView, saturationCenter,
             NSGridCell.emptyContentView, moreSaturationButton],
        ])
        let radios = NSStackView(views: [shadowRadio, midtoneRadio, highlightRadio, saturationRadio])
        radios.orientation = .horizontal
        radios.spacing = 12
        let controls = NSStackView(views: [stepSlider, clippingCheckbox])
        controls.orientation = .horizontal
        controls.spacing = 16
        controls.alignment = .firstBaseline

        view = NSStackView(views: [grid, radios, controls])
        view.orientation = .vertical
        view.spacing = 12
        view.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        view.setFrameSize(NSSize(width: 480, height: 600))

        let thumbnailActions: [(NSButton, ThumbnailAction)] = [
            (originalButton, .original),
            (currentPickButton, .currentPick),
            (lighterButton, .apply(.lighter)),
            (darkerButton, .apply(.darker)),
            (lessSaturationButton, .apply(.lessSaturation)),
            (moreSaturationButton, .apply(.moreSaturation)),
        ] + colorButtons.map { ($0.1, ThumbnailAction.apply($0.0)) }
        for (button, action) in thumbnailActions {
            button.target = self
            button.action = #selector(click(_:))
            actions[ObjectIdentifier(button)] = action
        }
        clippingCheckbox.target = self
        clippingCheckbox.action = #selector(clippingChanged(_:))
        rangeGroup.onChange = { [weak self] in self?.rangeChanged() }
        stepSlider.onChange = { [weak self] value, _ in
            guard let self else { return }
            self.model.stepIndex = min(max(Int(value.rounded()), 0), VariationsModel.steps.count - 1)
            self.reloadThumbnails()
        }

        updateModeVisibility()
    }

    /// Starts rendering the thumbnails for one layer of `document`.
    func attach(to document: ImageDocument, layer: Int32) {
        self.document = document
        self.image = document.image
        self.layer = layer
        reloadThumbnails()
    }

    func present(on window: NSWindow, dismiss: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = "Variations"
        alert.informativeText = "Click a thumbnail to add one correction to the chosen range. "
            + "Lighter and Darker change the whole tonal range; Saturation switches the ring "
            + "to saturation steps. Original starts over."
        alert.accessoryView = view
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        onValidityChanged = { [weak ok = alert.buttons.first] valid in ok?.isEnabled = valid }
        onValidityChanged?(!model.isIdentity)
        alert.beginSheetModal(for: window) { response in
            dismiss()
            guard response == .alertFirstButtonReturn else { return }
            self.document?.applyVariations(self.model.settings)
        }
    }

    private static func makeThumbnailButton(_ title: String) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.imagePosition = .imageTop
        button.imageScaling = .scaleProportionallyDown
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.widthAnchor.constraint(equalToConstant: 92).isActive = true
        button.heightAnchor.constraint(equalToConstant: 116).isActive = true
        return button
    }

    private func rangeChanged() {
        if saturationRadio.state == .on {
            model.mode = .saturation
        } else {
            model.mode = .color
            if shadowRadio.state == .on { model.range = .shadows }
            else if highlightRadio.state == .on { model.range = .highlights }
            else { model.range = .midtones }
        }
        updateModeVisibility()
        reloadThumbnails()
    }

    private func updateModeVisibility() {
        let saturation = model.mode == .saturation
        for (_, button) in colorButtons { button.isHidden = saturation }
        lessSaturationButton.isHidden = !saturation
        moreSaturationButton.isHidden = !saturation
    }

    private func reloadThumbnails() {
        guard document != nil else { return }
        generation += 1
        let expected = generation
        request(originalButton, settings: EngineSession.VariationsSettings(), generation: expected)
        request(currentPickButton, settings: model.settings, generation: expected)
        if model.mode == .saturation {
            request(lessSaturationButton,
                    settings: model.settings(afterClick: .lessSaturation), generation: expected)
            request(moreSaturationButton,
                    settings: model.settings(afterClick: .moreSaturation), generation: expected)
        } else {
            for (direction, button) in colorButtons {
                request(button, settings: model.settings(afterClick: direction), generation: expected)
            }
            request(lighterButton, settings: model.settings(afterClick: .lighter), generation: expected)
            request(darkerButton, settings: model.settings(afterClick: .darker), generation: expected)
        }
    }

    private func request(_ button: NSButton, settings: EngineSession.VariationsSettings,
                         generation expected: Int) {
        document?.variationsPreview(image, layer: layer, settings: settings,
                                    maxSize: thumbnailSize) { [weak self] preview in
            guard let self, expected == self.generation else { return }
            guard let preview else { return }
            self.previews[ObjectIdentifier(button)] = preview
            button.image = self.renderedImage(preview)
        }
    }

    /// Builds the thumbnail image, overlaying a vivid color on clipped
    /// pixels when Show Clipping is on.
    private func renderedImage(_ preview: EngineSession.VariationsPreview) -> NSImage {
        let source = preview.image
        let size = NSSize(width: source.width, height: source.height)
        guard clippingCheckbox.state == .on, source.width > 0, source.height > 0,
              preview.clipping.count == source.width * source.height,
              let context = CGContext(data: nil, width: source.width, height: source.height,
                                      bitsPerComponent: 8, bytesPerRow: source.width * 4,
                                      space: CGColorSpace.sRGB,
                                      bitmapInfo: CGBitmapInfo(rawValue:
                                          CGImageAlphaInfo.premultipliedLast.rawValue
                                          | CGBitmapInfo.byteOrder32Big.rawValue)) else {
            return NSImage(cgImage: source, size: size)
        }
        context.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard let bytes = context.data else { return NSImage(cgImage: source, size: size) }
        let pixels = bytes.bindMemory(to: UInt8.self, capacity: source.width * source.height * 4)
        for index in 0..<source.width * source.height where preview.clipping[index] == 255 {
            pixels[index * 4 + 0] = 255
            pixels[index * 4 + 1] = 0
            pixels[index * 4 + 2] = 255
            pixels[index * 4 + 3] = 255
        }
        guard let marked = context.makeImage() else { return NSImage(cgImage: source, size: size) }
        return NSImage(cgImage: marked, size: size)
    }

    @objc private func click(_ sender: NSButton) {
        guard let action = actions[ObjectIdentifier(sender)] else { return }
        switch action {
        case .original:
            model.reset()
        case .currentPick:
            return
        case .apply(let direction):
            model.apply(direction)
        }
        onValidityChanged?(!model.isIdentity)
        reloadThumbnails()
    }

    @objc private func clippingChanged(_: NSButton) {
        for button in [originalButton, currentPickButton, lighterButton, darkerButton,
                       lessSaturationButton, moreSaturationButton] + colorButtons.map { $0.1 } {
            guard let preview = previews[ObjectIdentifier(button)] else { continue }
            button.image = renderedImage(preview)
        }
    }
}
