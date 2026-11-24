import AppKit

/// The preview view under the blend panels. It draws the delivered CGImage
/// fitted into the view; both panels render their engine preview into one.
@MainActor
internal final class BlendPreviewView: NSView {
    var image: CGImage? { didSet { needsDisplay = true } }
    var imageSize: CGSize = .zero

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
}

/// One entry in a blend panel's Channel pop-up: a built-in channel kind or
/// a named saved channel.
struct BlendChannelChoice: Equatable {
    let title: String
    let kind: EngineSession.ChannelKind
    let item: Int32
}

/// Image > Blend With Image's utility panel. It blends one channel (or the
/// composite color) of an open image into the active layer or saved channel
/// of this document, limited by the current selection, as one undo step.
/// The panel is modeless like Color Range's; OK commits and closes, Cancel
/// and Escape close with no change.
@MainActor
final class BlendImagePanel: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// The engine previews' long-side cap; the panel renders it at 200 pt.
    static let previewMax: Int32 = 256

    private let imageDocument: ImageDocument
    var onClose: (() -> Void)?

    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let layerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let channelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let invertCheckbox = NSButton(checkboxWithTitle: "Invert", target: nil, action: nil)
    private let targetLabel = NSTextField(labelWithString: "Target:")
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let opacitySlider = NSSlider(value: 100, minValue: 0, maxValue: 100,
                                         target: nil, action: nil)
    private let opacityField = NSTextField(string: "100")
    private let scaleField = NSTextField(string: "1")
    private let offsetField = NSTextField(string: "0")
    private let maskPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let maskLayerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let maskChannelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let maskInvertCheckbox = NSButton(checkboxWithTitle: "Invert Mask",
                                              target: nil, action: nil)
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let preview = BlendPreviewView()

    private var sourceDocuments: [ImageDocument] = []
    private var sourceLayers: [(title: String, id: Int32)] = []
    private var sourceChannels: [BlendChannelChoice] = []
    private var maskDocuments: [ImageDocument] = []
    private var maskLayers: [(title: String, id: Int32)] = []
    private var maskChannels: [BlendChannelChoice] = []
    private var generation = 0
    private var finished = false
    /// Watches other document windows closing; removed in `finish`.
    private var documentCloseObserver: NSObjectProtocol?

    /// The last delivered preview, for diagnostics and the smoke test.
    private(set) var previewWidth = 0
    private(set) var previewHeight = 0
    private(set) var previewBytes: [UInt8] = []

    init(document: ImageDocument) {
        self.imageDocument = document
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 620),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Blend With Image"
        panel.isFloatingPanel = true
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
        preview.imageSize = CGSize(width: document.info.width, height: document.info.height)
        reloadSourceDocuments()
        reloadMaskDocuments()
        // A document window closing elsewhere takes its document out of the
        // pop-ups. The reload waits a turn because the closing window's own
        // controller marks its document closing in the same notification.
        documentCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] notification in
            MainActor.assumeIsolated {
                guard (notification.object as? NSWindow)?.windowController is DocumentWindowController
                else { return }
                DispatchQueue.main.async { self?.documentsChanged() }
            }
        }
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Settings

    /// The panel's current settings, rebuilt from the controls.
    var settings: EngineSession.BlendImageSettings {
        var value = EngineSession.BlendImageSettings()
        value.source = sourceRef(inverted: invertCheckbox.state == .on)
        value.mask = maskPopup.indexOfSelectedItem > 0
            ? maskRef(inverted: maskInvertCheckbox.state == .on) : .noMask
        value.mode = EngineSession.BlendMode.allCases[modePopup.indexOfSelectedItem]
        value.opacity = opacitySlider.doubleValue / 100
        value.scale = Double(scaleField.stringValue.trimmingCharacters(in: .whitespaces)) ?? .nan
        value.offset = Double(offsetField.stringValue.trimmingCharacters(in: .whitespaces)) ?? .nan
        return value
    }

    private func sourceRef(inverted: Bool) -> EngineSession.ChannelRef {
        guard let document = sourceDocuments[safe: sourcePopup.indexOfSelectedItem],
              !document.isClosing else { return .noMask }
        let layer = sourceLayers[safe: layerPopup.indexOfSelectedItem]?.id ?? 0
        let channel = sourceChannels[safe: channelPopup.indexOfSelectedItem]
        return EngineSession.ChannelRef(image: document.image, layer: layer,
                                       kind: channel?.kind ?? .composite,
                                       item: channel?.item ?? 0, invert: inverted)
    }

    private func maskRef(inverted: Bool) -> EngineSession.ChannelRef {
        guard let document = maskDocuments[safe: maskPopup.indexOfSelectedItem - 1],
              !document.isClosing else { return .noMask }
        let layer = maskLayers[safe: maskLayerPopup.indexOfSelectedItem]?.id ?? 0
        let channel = maskChannels[safe: maskChannelPopup.indexOfSelectedItem]
        return EngineSession.ChannelRef(image: document.image, layer: layer,
                                       kind: channel?.kind ?? .composite,
                                       item: channel?.item ?? 0, invert: inverted)
    }

    // MARK: Building

    private func buildContent(in panel: NSPanel) {
        configurePopUp(sourcePopup, label: "Blend source document", action: #selector(sourceDocumentChanged(_:)))
        configurePopUp(layerPopup, label: "Blend source layer", action: #selector(sourceLayerChanged(_:)))
        configurePopUp(channelPopup, label: "Blend source channel", action: #selector(sourceChannelChanged(_:)))
        configurePopUp(modePopup, label: "Blend mode", action: #selector(modeChanged(_:)))
        configurePopUp(maskPopup, label: "Blend mask document", action: #selector(maskDocumentChanged(_:)))
        configurePopUp(maskLayerPopup, label: "Blend mask layer", action: #selector(maskLayerChanged(_:)))
        configurePopUp(maskChannelPopup, label: "Blend mask channel", action: #selector(maskChannelChanged(_:)))

        modePopup.addItems(withTitles: EngineSession.BlendMode.allCases.map(\.title))
        modePopup.selectItem(at: 0)

        invertCheckbox.setAccessibilityLabel("Invert the blend source")
        invertCheckbox.target = self
        invertCheckbox.action = #selector(sourceInvertChanged(_:))
        targetLabel.setAccessibilityLabel("Blend target")

        opacitySlider.setAccessibilityLabel("Blend opacity")
        opacitySlider.isContinuous = true
        opacitySlider.target = self
        opacitySlider.action = #selector(opacitySliderChanged(_:))
        opacityField.setAccessibilityLabel("Blend opacity percent")
        opacityField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        opacityField.target = self
        opacityField.action = #selector(opacityFieldChanged(_:))
        opacityField.delegate = self

        scaleField.setAccessibilityLabel("Blend scale for Add and Subtract")
        scaleField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        scaleField.target = self
        scaleField.action = #selector(scaleFieldChanged(_:))
        offsetField.setAccessibilityLabel("Blend offset for Add and Subtract")
        offsetField.widthAnchor.constraint(equalToConstant: 56).isActive = true
        offsetField.target = self
        offsetField.action = #selector(offsetFieldChanged(_:))

        maskInvertCheckbox.setAccessibilityLabel("Invert the blend mask")
        maskInvertCheckbox.target = self
        maskInvertCheckbox.action = #selector(maskInvertChanged(_:))

        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel blending with another image")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        okButton.keyEquivalent = "\r"
        okButton.setAccessibilityLabel("Blend with the chosen image")
        okButton.target = self
        okButton.action = #selector(commit)

        preview.widthAnchor.constraint(equalToConstant: 200).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 200).isActive = true
        preview.setAccessibilityLabel("Blend preview")

        let sourceRow = row("Source:", sourcePopup)
        let layerRow = row("Layer:", layerPopup)
        let channelRow = row("Channel:", channelPopup)
        let modeRow = row("Mode:", modePopup)
        let opacityRow = row("Opacity:", opacitySlider, opacityField)
        let scaleRow = row("Scale:", scaleField)
        let offsetRow = row("Offset:", offsetField)
        let maskRow = row("Mask:", maskPopup)
        let maskLayerRow = row("Mask Layer:", maskLayerPopup)
        let maskChannelRow = row("Mask Channel:", maskChannelPopup)
        let buttons = NSStackView(views: [NSView(), cancelButton, okButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [sourceRow, layerRow, channelRow, invertCheckbox,
                                        targetLabel, modeRow, opacityRow, scaleRow, offsetRow,
                                        maskRow, maskLayerRow, maskChannelRow, maskInvertCheckbox,
                                        preview, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
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
            sourceRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])
        panel.setContentSize(NSSize(width: max(400, stack.fittingSize.width + 32),
                                    height: stack.fittingSize.height))
        updateModeEnabled()
    }

    private func row(_ title: String, _ first: NSView, _ second: NSView? = nil) -> NSStackView {
        var views: [NSView] = [NSTextField(labelWithString: title), first]
        if let second { views.append(second) }
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }

    private func configurePopUp(_ popup: NSPopUpButton, label: String, action: Selector) {
        popup.setAccessibilityLabel(label)
        popup.target = self
        popup.action = action
    }

    // MARK: Pop-up loading

    private func openSourceDocuments() -> [ImageDocument] {
        let size = CGSize(width: imageDocument.info.width, height: imageDocument.info.height)
        var documents = NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
            .map(\.imageDocument)
            .filter { !$0.isClosing && $0.info.width == Int(size.width) && $0.info.height == Int(size.height) }
        if let front = (NSApp.mainWindow?.windowController as? DocumentWindowController)?.imageDocument,
           let index = documents.firstIndex(where: { $0 === front }) {
            documents.insert(documents.remove(at: index), at: 0)
        }
        return documents
    }

    private func layerChoices(for document: ImageDocument) -> [(title: String, id: Int32)] {
        [("Merged", 0)] + document.layers.map { ($0.name, $0.id) }
    }

    private static func channelChoices(for document: ImageDocument) -> [BlendChannelChoice] {
        let builtIn = EngineSession.ChannelKind.allCases
            .filter { $0 != .none && $0 != .saved }
            .map { BlendChannelChoice(title: $0.title, kind: $0, item: 0) }
        let saved = document.channels.map {
            BlendChannelChoice(title: $0.name, kind: .saved, item: $0.id)
        }
        return builtIn + saved
    }

    private func fill(_ popup: NSPopUpButton, with titles: [String], keeping index: Int? = nil) {
        popup.removeAllItems()
        // NSPopUpButton.addItems(withTitles:) coalesces duplicate titles,
        // and two open documents may share a name; one item per entry keeps
        // the pop-up's indices aligned with the lists they index.
        for title in titles {
            popup.menu?.addItem(NSMenuItem(title: title, action: nil, keyEquivalent: ""))
        }
        guard !titles.isEmpty else { return }
        popup.selectItem(at: max(0, min(index ?? 0, titles.count - 1)))
    }

    private func reloadSourceDocuments() {
        let previous = sourceDocuments[safe: sourcePopup.indexOfSelectedItem]
        sourceDocuments = openSourceDocuments()
        fill(sourcePopup, with: sourceDocuments.map { $0.name },
             keeping: previous.flatMap { previous in sourceDocuments.firstIndex(where: { $0 === previous }) })
        reloadSourceLayers()
    }

    private func reloadSourceLayers() {
        let document = sourceDocuments[safe: sourcePopup.indexOfSelectedItem]
        let previous = sourceLayers[safe: layerPopup.indexOfSelectedItem]?.id
        sourceLayers = document.map(layerChoices) ?? []
        fill(layerPopup, with: sourceLayers.map { $0.title },
             keeping: previous.flatMap { id in sourceLayers.firstIndex(where: { $0.id == id }) })
        reloadSourceChannels()
    }

    private func reloadSourceChannels() {
        let document = sourceDocuments[safe: sourcePopup.indexOfSelectedItem]
        sourceChannels = document.map(Self.channelChoices) ?? []
        fill(channelPopup, with: sourceChannels.map { $0.title })
        updateOkEnabled()
        refreshPreview()
    }

    private func reloadMaskDocuments() {
        let previous = maskDocuments[safe: maskPopup.indexOfSelectedItem - 1]
        maskDocuments = openSourceDocuments()
        // Keep the mask document itself; "None" when it is gone.
        let kept = previous.flatMap { previous in maskDocuments.firstIndex(where: { $0 === previous }) }
        fill(maskPopup, with: ["None"] + maskDocuments.map { $0.name }, keeping: kept.map { $0 + 1 } ?? 0)
        reloadMaskLayers()
    }

    /// Rebuilds the document pop-ups without the documents that are
    /// closing. Internal for the smoke test, which cannot close a window
    /// mid-run without tearing its fixtures down.
    func documentsChanged() {
        guard !finished else { return }
        reloadSourceDocuments()
        reloadMaskDocuments()
    }

    /// The source pop-up's documents and item titles, for the smoke test.
    var sourceDocumentChoices: [ImageDocument] { sourceDocuments }
    var sourceItemTitles: [String] { sourcePopup.itemTitles }

    private func reloadMaskLayers() {
        let document = maskDocuments[safe: maskPopup.indexOfSelectedItem - 1]
        let previous = maskLayers[safe: maskLayerPopup.indexOfSelectedItem]?.id
        maskLayers = document.map(layerChoices) ?? []
        fill(maskLayerPopup, with: maskLayers.map { $0.title },
             keeping: previous.flatMap { id in maskLayers.firstIndex(where: { $0.id == id }) })
        reloadMaskChannels()
    }

    private func reloadMaskChannels() {
        let document = maskDocuments[safe: maskPopup.indexOfSelectedItem - 1]
        maskChannels = document.map(Self.channelChoices) ?? []
        fill(maskChannelPopup, with: maskChannels.map { $0.title })
        updateMaskEnabled()
        updateOkEnabled()
        refreshPreview()
    }

    // MARK: Actions

    @objc private func sourceDocumentChanged(_ sender: NSPopUpButton) {
        reloadSourceLayers()
    }

    @objc private func sourceLayerChanged(_ sender: NSPopUpButton) {
        reloadSourceChannels()
    }

    @objc private func sourceChannelChanged(_ sender: NSPopUpButton) {
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func sourceInvertChanged(_ sender: NSButton) {
        refreshPreview()
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        updateModeEnabled()
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func opacitySliderChanged(_ sender: NSSlider) {
        opacityField.stringValue = String(Int(sender.doubleValue.rounded()))
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func opacityFieldChanged(_ sender: NSTextField) {
        let text = sender.stringValue.trimmingCharacters(in: .whitespaces)
        if let value = Double(text), value >= 0, value <= 100 {
            opacitySlider.doubleValue = value
        } else {
            sender.stringValue = String(Int(opacitySlider.doubleValue.rounded()))
        }
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func scaleFieldChanged(_ sender: NSTextField) {
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func offsetFieldChanged(_ sender: NSTextField) {
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func maskDocumentChanged(_ sender: NSPopUpButton) {
        reloadMaskLayers()
    }

    @objc private func maskLayerChanged(_ sender: NSPopUpButton) {
        reloadMaskChannels()
    }

    @objc private func maskChannelChanged(_ sender: NSPopUpButton) {
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func maskInvertChanged(_ sender: NSButton) {
        refreshPreview()
    }

    @objc func commit() {
        let value = settings
        guard value.validationError == nil, !finished else { return }
        // Close first: while the panel is open the window controller holds
        // the document's filter-preview gate, which refuses every edit.
        finish()
        imageDocument.blendImage(value)
    }

    @objc func cancel() {
        finish()
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        if let documentCloseObserver {
            NotificationCenter.default.removeObserver(documentCloseObserver)
        }
        documentCloseObserver = nil
        window?.orderOut(nil)
        onClose?()
    }

    // MARK: Convenience for the smoke test

    func selectSource(document target: ImageDocument) {
        guard let index = sourceDocuments.firstIndex(where: { $0 === target }) else { return }
        sourcePopup.selectItem(at: index)
        sourceDocumentChanged(sourcePopup)
    }

    func selectLayer(_ layer: Int32) {
        guard let index = sourceLayers.firstIndex(where: { $0.id == layer }) else { return }
        layerPopup.selectItem(at: index)
        sourceLayerChanged(layerPopup)
    }

    func selectChannel(kind: EngineSession.ChannelKind, item: Int32 = 0) {
        guard let index = sourceChannels.firstIndex(where: { $0.kind == kind && $0.item == item }) else { return }
        channelPopup.selectItem(at: index)
        sourceChannelChanged(channelPopup)
    }

    func selectMode(_ mode: EngineSession.BlendMode) {
        let index = EngineSession.BlendMode.allCases.firstIndex(of: mode) ?? 0
        modePopup.selectItem(at: index)
        modeChanged(modePopup)
    }

    func setOpacity(_ opacity: Double) {
        opacitySlider.doubleValue = opacity * 100
        opacityField.stringValue = String(Int((opacity * 100).rounded()))
        updateOkEnabled()
        refreshPreview()
    }

    // MARK: Preview

    private func updateModeEnabled() {
        let additive = modePopup.indexOfSelectedItem == EngineSession.BlendMode.allCases.firstIndex(of: .add)
            || modePopup.indexOfSelectedItem == EngineSession.BlendMode.allCases.firstIndex(of: .subtract)
        scaleField.isEnabled = additive
        offsetField.isEnabled = additive
    }

    private func updateMaskEnabled() {
        let enabled = maskPopup.indexOfSelectedItem > 0
        maskLayerPopup.isEnabled = enabled
        maskChannelPopup.isEnabled = enabled
        maskInvertCheckbox.isEnabled = enabled
    }

    private func updateOkEnabled() {
        okButton.isEnabled = settings.validationError == nil
    }

    private func refreshPreview() {
        updateOkEnabled()
        generation &+= 1
        let expected = generation
        let value = settings
        targetLabel.stringValue = "Target: \(targetName())"
        guard value.validationError == nil, let target = imageDocument.activeDrawable else {
            previewWidth = 0
            previewHeight = 0
            previewBytes = []
            preview.image = nil
            return
        }
        imageDocument.blendImagePreview(target: target, settings: value,
                                        maxSize: Self.previewMax) { [weak self] result in
            guard let self, expected == self.generation else { return }
            self.previewWidth = result?.width ?? 0
            self.previewHeight = result?.height ?? 0
            self.previewBytes = result?.rgba ?? []
            // The preview covers the target layer, whose shape can differ
            // from the canvas's.
            if let result { self.preview.imageSize = CGSize(width: result.width, height: result.height) }
            self.preview.image = result.flatMap { Self.makeImage(rgba: $0.rgba, width: $0.width, height: $0.height) }
        }
    }

    private func targetName() -> String {
        if imageDocument.isMaskTargetActive, let layer = imageDocument.activeLayer,
           let row = imageDocument.layers.first(where: { $0.id == layer }) {
            return "\(row.name) Mask"
        }
        if let channel = imageDocument.activeChannel,
           let row = imageDocument.channels.first(where: { $0.id == channel }) {
            return row.name
        }
        if let layer = imageDocument.activeLayer,
           let row = imageDocument.layers.first(where: { $0.id == layer }) {
            return row.name
        }
        return "No target"
    }

    private static func makeImage(rgba: [UInt8], width: Int, height: Int) -> CGImage? {
        let count = width * height * 4
        guard width > 0, height > 0, rgba.count >= count else { return nil }
        let data = Data(rgba.prefix(count)) as CFData
        guard let provider = CGDataProvider(data: data),
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: space,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true,
                       intent: .defaultIntent)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard (notification.object as? NSTextField) === opacityField else { return }
        opacityFieldChanged(opacityField)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        finish()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
