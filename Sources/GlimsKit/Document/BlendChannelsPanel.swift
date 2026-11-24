import AppKit

/// Image > Blend Channels' utility panel. It blends one single channel of
/// one open image (the backdrop) with one single channel of another (the
/// source), limited by an optional mask, as one undo step, and puts the
/// result into a new saved channel, a new selection or a new grayscale
/// document. The panel is modeless like Color Range's; OK commits and
/// closes, Cancel and Escape close with no change.
@MainActor
final class BlendChannelsPanel: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    /// The engine previews' long-side cap; the panel renders it at 200 pt.
    static let previewMax: Int32 = 256

    private let imageDocument: ImageDocument
    var onClose: (() -> Void)?

    private let firstDocumentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let firstLayerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let firstChannelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let firstInvertCheckbox = NSButton(checkboxWithTitle: "Invert", target: nil, action: nil)
    private let secondDocumentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let secondLayerPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let secondChannelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let secondInvertCheckbox = NSButton(checkboxWithTitle: "Invert", target: nil, action: nil)
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
    private let resultPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let nameField = NSTextField(string: "Alpha 1")
    private let okButton = NSButton(title: "OK", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let preview = BlendPreviewView()

    private var firstDocuments: [ImageDocument] = []
    private var firstLayers: [(title: String, id: Int32)] = []
    private var firstChannels: [BlendChannelChoice] = []
    private var secondDocuments: [ImageDocument] = []
    private var secondLayers: [(title: String, id: Int32)] = []
    private var secondChannels: [BlendChannelChoice] = []
    private var maskDocuments: [ImageDocument] = []
    private var maskLayers: [(title: String, id: Int32)] = []
    private var maskChannels: [BlendChannelChoice] = []
    private var generation = 0
    private var finished = false
    /// Watches other document windows closing; removed in `finish`.
    private var documentCloseObserver: NSObjectProtocol?

    /// The last delivered gray preview, for diagnostics and the smoke test.
    private(set) var previewWidth = 0
    private(set) var previewHeight = 0
    private(set) var previewBytes: [UInt8] = []

    init(document: ImageDocument) {
        self.imageDocument = document
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Blend Channels"
        panel.isFloatingPanel = true
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
        preview.imageSize = CGSize(width: document.info.width, height: document.info.height)
        reloadFirstDocuments()
        reloadSecondDocuments()
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
    var settings: EngineSession.BlendChannelsSettings {
        var value = EngineSession.BlendChannelsSettings()
        value.first = ref(documents: firstDocuments, documentPopup: firstDocumentPopup,
                          layers: firstLayers, layerPopup: firstLayerPopup,
                          channels: firstChannels, channelPopup: firstChannelPopup,
                          inverted: firstInvertCheckbox.state == .on)
        value.second = ref(documents: secondDocuments, documentPopup: secondDocumentPopup,
                           layers: secondLayers, layerPopup: secondLayerPopup,
                           channels: secondChannels, channelPopup: secondChannelPopup,
                           inverted: secondInvertCheckbox.state == .on)
        value.mask = maskPopup.indexOfSelectedItem > 0
            ? ref(documents: maskDocuments, documentPopup: maskPopup,
                  layers: maskLayers, layerPopup: maskLayerPopup,
                  channels: maskChannels, channelPopup: maskChannelPopup,
                  inverted: maskInvertCheckbox.state == .on, offset: -1)
            : .noMask
        value.mode = EngineSession.BlendMode.allCases[modePopup.indexOfSelectedItem]
        value.opacity = opacitySlider.doubleValue / 100
        value.scale = Double(scaleField.stringValue.trimmingCharacters(in: .whitespaces)) ?? .nan
        value.offset = Double(offsetField.stringValue.trimmingCharacters(in: .whitespaces)) ?? .nan
        switch resultPopup.indexOfSelectedItem {
        case 0: value.destination = .newChannel(nameField.stringValue)
        case 1: value.destination = .newSelection
        default: value.destination = .newImage
        }
        value.destinationImage = imageDocument.image
        return value
    }

    private func ref(documents: [ImageDocument], documentPopup: NSPopUpButton,
                     layers: [(title: String, id: Int32)], layerPopup: NSPopUpButton,
                     channels: [BlendChannelChoice], channelPopup: NSPopUpButton,
                     inverted: Bool, offset: Int = 0) -> EngineSession.ChannelRef {
        guard let document = documents[safe: documentPopup.indexOfSelectedItem + offset],
              !document.isClosing else { return .noMask }
        let layer = layers[safe: layerPopup.indexOfSelectedItem]?.id ?? 0
        let channel = channels[safe: channelPopup.indexOfSelectedItem]
        return EngineSession.ChannelRef(image: document.image, layer: layer,
                                       kind: channel?.kind ?? .composite,
                                       item: channel?.item ?? 0, invert: inverted)
    }

    // MARK: Building

    private func buildContent(in panel: NSPanel) {
        configurePopUp(firstDocumentPopup, label: "First input document",
                       action: #selector(firstDocumentChanged(_:)))
        configurePopUp(firstLayerPopup, label: "First input layer",
                       action: #selector(firstLayerChanged(_:)))
        configurePopUp(firstChannelPopup, label: "First input channel",
                       action: #selector(firstChannelChanged(_:)))
        configurePopUp(secondDocumentPopup, label: "Second input document",
                       action: #selector(secondDocumentChanged(_:)))
        configurePopUp(secondLayerPopup, label: "Second input layer",
                       action: #selector(secondLayerChanged(_:)))
        configurePopUp(secondChannelPopup, label: "Second input channel",
                       action: #selector(secondChannelChanged(_:)))
        configurePopUp(modePopup, label: "Blend mode", action: #selector(modeChanged(_:)))
        configurePopUp(maskPopup, label: "Blend mask document",
                       action: #selector(maskDocumentChanged(_:)))
        configurePopUp(maskLayerPopup, label: "Blend mask layer",
                       action: #selector(maskLayerChanged(_:)))
        configurePopUp(maskChannelPopup, label: "Blend mask channel",
                       action: #selector(maskChannelChanged(_:)))
        configurePopUp(resultPopup, label: "Blend result destination",
                       action: #selector(resultChanged(_:)))

        modePopup.addItems(withTitles: EngineSession.BlendMode.allCases.map(\.title))
        modePopup.selectItem(at: 0)
        resultPopup.addItems(withTitles: [EngineSession.BlendChannelsDestination.newChannel("").title,
                                          EngineSession.BlendChannelsDestination.newSelection.title,
                                          EngineSession.BlendChannelsDestination.newImage.title])
        resultPopup.selectItem(at: 0)

        firstInvertCheckbox.setAccessibilityLabel("Invert the first input")
        firstInvertCheckbox.target = self
        firstInvertCheckbox.action = #selector(firstInvertChanged(_:))
        secondInvertCheckbox.setAccessibilityLabel("Invert the second input")
        secondInvertCheckbox.target = self
        secondInvertCheckbox.action = #selector(secondInvertChanged(_:))

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

        nameField.setAccessibilityLabel("New channel name")
        nameField.widthAnchor.constraint(equalToConstant: 96).isActive = true
        nameField.target = self
        nameField.action = #selector(nameFieldChanged(_:))

        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel blending channels")
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        okButton.keyEquivalent = "\r"
        okButton.setAccessibilityLabel("Blend the chosen channels")
        okButton.target = self
        okButton.action = #selector(commit)

        preview.widthAnchor.constraint(equalToConstant: 200).isActive = true
        preview.heightAnchor.constraint(equalToConstant: 200).isActive = true
        preview.setAccessibilityLabel("Blend channels preview")

        let stack = NSStackView(views: [
            labeled("First:", firstDocumentPopup),
            row("Layer:", firstLayerPopup), row("Channel:", firstChannelPopup), firstInvertCheckbox,
            labeled("Second:", secondDocumentPopup),
            row("Layer:", secondLayerPopup), row("Channel:", secondChannelPopup), secondInvertCheckbox,
            row("Mode:", modePopup),
            row("Opacity:", opacitySlider, opacityField),
            row("Scale:", scaleField), row("Offset:", offsetField),
            row("Mask:", maskPopup),
            row("Mask Layer:", maskLayerPopup), row("Mask Channel:", maskChannelPopup),
            maskInvertCheckbox,
            row("Result:", resultPopup), row("Name:", nameField),
            preview,
            NSStackView(views: [NSView(), cancelButton, okButton]),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
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
            firstDocumentPopup.widthAnchor.constraint(equalToConstant: 220),
            secondDocumentPopup.widthAnchor.constraint(equalToConstant: 220),
        ])
        panel.setContentSize(NSSize(width: max(420, stack.fittingSize.width + 32),
                                    height: stack.fittingSize.height))
        nameField.stringValue = Self.defaultChannelName(for: imageDocument)
        updateModeEnabled()
        updateResultEnabled()
        updateMaskEnabled()
    }

    private func labeled(_ title: String, _ popup: NSPopUpButton) -> NSStackView {
        let stack = NSStackView(views: [NSTextField(labelWithString: title), popup])
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
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

    private func openDocuments() -> [ImageDocument] {
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
            .filter { $0 != .none && $0 != .saved && $0 != .composite }
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

    private func reloadFirstDocuments() {
        let previous = firstDocuments[safe: firstDocumentPopup.indexOfSelectedItem]
        firstDocuments = openDocuments()
        fill(firstDocumentPopup, with: firstDocuments.map { $0.name },
             keeping: previous.flatMap { previous in firstDocuments.firstIndex(where: { $0 === previous }) })
        reloadFirstLayers()
    }

    private func reloadFirstLayers() {
        let document = firstDocuments[safe: firstDocumentPopup.indexOfSelectedItem]
        let previous = firstLayers[safe: firstLayerPopup.indexOfSelectedItem]?.id
        firstLayers = document.map(layerChoices) ?? []
        fill(firstLayerPopup, with: firstLayers.map { $0.title },
             keeping: previous.flatMap { id in firstLayers.firstIndex(where: { $0.id == id }) })
        reloadFirstChannels()
    }

    private func reloadFirstChannels() {
        let document = firstDocuments[safe: firstDocumentPopup.indexOfSelectedItem]
        firstChannels = document.map(Self.channelChoices) ?? []
        fill(firstChannelPopup, with: firstChannels.map { $0.title })
        updateOkEnabled()
        refreshPreview()
    }

    private func reloadSecondDocuments() {
        let previous = secondDocuments[safe: secondDocumentPopup.indexOfSelectedItem]
        secondDocuments = openDocuments()
        fill(secondDocumentPopup, with: secondDocuments.map { $0.name },
             keeping: previous.flatMap { previous in secondDocuments.firstIndex(where: { $0 === previous }) })
        reloadSecondLayers()
    }

    private func reloadSecondLayers() {
        let document = secondDocuments[safe: secondDocumentPopup.indexOfSelectedItem]
        let previous = secondLayers[safe: secondLayerPopup.indexOfSelectedItem]?.id
        secondLayers = document.map(layerChoices) ?? []
        fill(secondLayerPopup, with: secondLayers.map { $0.title },
             keeping: previous.flatMap { id in secondLayers.firstIndex(where: { $0.id == id }) })
        reloadSecondChannels()
    }

    private func reloadSecondChannels() {
        let document = secondDocuments[safe: secondDocumentPopup.indexOfSelectedItem]
        secondChannels = document.map(Self.channelChoices) ?? []
        fill(secondChannelPopup, with: secondChannels.map { $0.title })
        updateOkEnabled()
        refreshPreview()
    }

    private func reloadMaskDocuments() {
        let previous = maskDocuments[safe: maskPopup.indexOfSelectedItem - 1]
        maskDocuments = openDocuments()
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
        reloadFirstDocuments()
        reloadSecondDocuments()
        reloadMaskDocuments()
    }

    /// The Second pop-up's documents and item titles, for the smoke test.
    var secondDocumentChoices: [ImageDocument] { secondDocuments }
    var secondItemTitles: [String] { secondDocumentPopup.itemTitles }

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

    private static func defaultChannelName(for document: ImageDocument) -> String {
        let names = Set(document.channels.map { $0.name })
        var index = 1
        while names.contains("Alpha \(index)") { index += 1 }
        return "Alpha \(index)"
    }

    // MARK: Actions

    @objc private func firstDocumentChanged(_ sender: NSPopUpButton) {
        reloadFirstLayers()
    }

    @objc private func firstLayerChanged(_ sender: NSPopUpButton) {
        reloadFirstChannels()
    }

    @objc private func firstChannelChanged(_ sender: NSPopUpButton) {
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func firstInvertChanged(_ sender: NSButton) {
        refreshPreview()
    }

    @objc private func secondDocumentChanged(_ sender: NSPopUpButton) {
        reloadSecondLayers()
    }

    @objc private func secondLayerChanged(_ sender: NSPopUpButton) {
        reloadSecondChannels()
    }

    @objc private func secondChannelChanged(_ sender: NSPopUpButton) {
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func secondInvertChanged(_ sender: NSButton) {
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

    @objc private func resultChanged(_ sender: NSPopUpButton) {
        updateResultEnabled()
        updateOkEnabled()
        refreshPreview()
    }

    @objc private func nameFieldChanged(_ sender: NSTextField) {
        updateOkEnabled()
        refreshPreview()
    }

    @objc func commit() {
        let value = settings
        guard value.validationError == nil, !finished else { return }
        // Close first: while the panel is open the window controller holds
        // the document's filter-preview gate, which refuses every edit.
        finish()
        imageDocument.blendChannels(value)
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

    func selectFirst(document target: ImageDocument, layer: Int32 = 0,
                     kind: EngineSession.ChannelKind, item: Int32 = 0) {
        guard let index = firstDocuments.firstIndex(where: { $0 === target }) else { return }
        firstDocumentPopup.selectItem(at: index)
        firstDocumentChanged(firstDocumentPopup)
        guard let layerIndex = firstLayers.firstIndex(where: { $0.id == layer }) else { return }
        firstLayerPopup.selectItem(at: layerIndex)
        firstLayerChanged(firstLayerPopup)
        guard let channelIndex = firstChannels.firstIndex(where: { $0.kind == kind && $0.item == item }) else { return }
        firstChannelPopup.selectItem(at: channelIndex)
        firstChannelChanged(firstChannelPopup)
    }

    func selectSecond(document target: ImageDocument, layer: Int32 = 0,
                      kind: EngineSession.ChannelKind, item: Int32 = 0) {
        guard let index = secondDocuments.firstIndex(where: { $0 === target }) else { return }
        secondDocumentPopup.selectItem(at: index)
        secondDocumentChanged(secondDocumentPopup)
        guard let layerIndex = secondLayers.firstIndex(where: { $0.id == layer }) else { return }
        secondLayerPopup.selectItem(at: layerIndex)
        secondLayerChanged(secondLayerPopup)
        guard let channelIndex = secondChannels.firstIndex(where: { $0.kind == kind && $0.item == item }) else { return }
        secondChannelPopup.selectItem(at: channelIndex)
        secondChannelChanged(secondChannelPopup)
    }

    func selectResult(_ destination: EngineSession.BlendChannelsDestination) {
        let index: Int
        switch destination {
        case .newChannel: index = 0
        case .newSelection: index = 1
        case .newImage: index = 2
        }
        resultPopup.selectItem(at: index)
        if case .newChannel(let name) = destination { nameField.stringValue = name }
        resultChanged(resultPopup)
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
        let index = modePopup.indexOfSelectedItem
        let add = EngineSession.BlendMode.allCases.firstIndex(of: .add) ?? -1
        let subtract = EngineSession.BlendMode.allCases.firstIndex(of: .subtract) ?? -1
        scaleField.isEnabled = index == add || index == subtract
        offsetField.isEnabled = index == add || index == subtract
    }

    private func updateResultEnabled() {
        nameField.isEnabled = resultPopup.indexOfSelectedItem == 0
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
        preview.imageSize = CGSize(width: imageDocument.info.width, height: imageDocument.info.height)
        guard value.validationError == nil else {
            previewWidth = 0
            previewHeight = 0
            previewBytes = []
            preview.image = nil
            return
        }
        imageDocument.blendChannelsPreview(settings: value,
                                           maxSize: Self.previewMax) { [weak self] result in
            guard let self, expected == self.generation else { return }
            self.previewWidth = result?.width ?? 0
            self.previewHeight = result?.height ?? 0
            self.previewBytes = result?.gray ?? []
            self.preview.image = result.flatMap { Self.makeGrayImage(gray: $0.gray, width: $0.width, height: $0.height) }
        }
    }

    private static func makeGrayImage(gray: [UInt8], width: Int, height: Int) -> CGImage? {
        let count = width * height
        guard width > 0, height > 0, gray.count >= count else { return nil }
        let data = Data(gray.prefix(count)) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                       bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                       bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
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
