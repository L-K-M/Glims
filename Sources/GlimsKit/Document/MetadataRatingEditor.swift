import AppKit

/// Edits the fixed XMP rating while preserving unrecognized source text.
@MainActor
final class MetadataRatingEditor: NSWindowController, NSWindowDelegate {
    static let fixedTag = "Xmp.xmp.Rating"
    private static let staleMessage = "The document changed. Close and reopen this editor before applying."
    let imageDocument: ImageDocument
    let sourceText: String
    let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let initialValues: [String]
    private let initialStateVersion: Int
    private var descriptor: EngineSession.MetadataTagInfo?
    private var stale = false
    private var readGeneration = 0
    private var writeRequest: UUID?
    private(set) var lastError: String?
    private(set) var isReading = false
    private(set) var isWriting = false
    private(set) var isInvalidated = false
    var onApplied: (([String]) -> Void)?
    var onClosed: (() -> Void)?

    init?(document: ImageDocument, values: [String]) {
        guard values.count <= 1 else { return nil }
        imageDocument = document
        initialValues = values
        sourceText = values.first ?? "No value"
        initialStateVersion = document.stateVersion
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 240),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "XMP Rating"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        popup.addItems(withTitles: ["Choose a value"] + MetadataRatingValue.allCases.map(\.title))
        if let value = MetadataRatingValue(values: values),
           let index = MetadataRatingValue.allCases.firstIndex(of: value) {
            popup.selectItem(at: index + 1)
        } else { popup.selectItem(at: 0) }
        buildContent(in: panel)
        panel.initialFirstResponder = popup
        updateControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var selectedValue: MetadataRatingValue? {
        let index = popup.indexOfSelectedItem - 1
        return MetadataRatingValue.allCases.indices.contains(index) ? MetadataRatingValue.allCases[index] : nil
    }

    private func buildContent(in panel: NSPanel) {
        let note = NSTextField(wrappingLabelWithString:
            "Choose a rating. Not specified removes the tag. Other original values stay unchanged until you choose a value.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        popup.setAccessibilityLabel("XMP rating value")
        popup.target = self
        popup.action = #selector(popupChanged(_:))
        let original = NSTextView(frame: NSRect(x: 0, y: 0, width: 448, height: 54))
        original.string = sourceText
        original.isEditable = false
        original.isSelectable = true
        original.isRichText = false
        original.drawsBackground = false
        original.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        original.minSize = NSSize(width: 0, height: 54)
        original.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        original.isVerticallyResizable = true
        original.isHorizontallyResizable = false
        original.autoresizingMask = [.width]
        original.textContainer?.widthTracksTextView = true
        original.setAccessibilityLabel("Original XMP rating value")
        let scroll = NSScrollView()
        scroll.documentView = original
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 54).isActive = true
        message.maximumNumberOfLines = 3
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.setAccessibilityLabel("XMP rating error")
        message.heightAnchor.constraint(equalToConstant: 46).isActive = true
        applyButton.target = self
        applyButton.action = #selector(apply(_:))
        applyButton.keyEquivalent = "\r"
        applyButton.setAccessibilityLabel("Apply XMP rating")
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel XMP rating")
        let actions = NSStackView(views: [NSView(), cancelButton, applyButton])
        actions.spacing = 8
        let stack = NSStackView(views: [note, popup, NSTextField(labelWithString: "Original value:"), scroll, message, actions])
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
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ] + [note, scroll, message, actions].map {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        })
        panel.setContentSize(NSSize(width: 480, height: stack.fittingSize.height))
    }

    func present(on parent: NSWindow) {
        guard !isInvalidated, let window, window.sheetParent == nil else { return }
        guard parent.attachedSheet == nil else {
            return showError("Close the current sheet before opening this editor.")
        }
        documentStateDidChange()
        guard !isInvalidated else { return }
        parent.beginSheet(window) { [weak self] _ in self?.invalidate() }
        loadDescriptor()
    }

    func commitFieldEdit() { window?.endEditing(for: nil) }

    func documentStateDidChange() {
        guard !isInvalidated else { return }
        guard !imageDocument.isClosing else { return invalidate() }
        if !isWriting, imageDocument.stateVersion != initialStateVersion {
            stale = true
            lastError = Self.staleMessage
            readGeneration += 1
            isReading = false
        }
        updateControls()
    }

    private var writeRefusal: String? {
        MetadataSheetLogic.writeAdmission(isClosing: imageDocument.isClosing,
            isSavingForClose: imageDocument.isSavingForClose, isTransferringClipboard: imageDocument.isTransferringClipboard,
            pluginRunning: PlugInCommands.isRunning, engineBusy: EngineActivity.shared.isBusy,
            filterPreviewOpen: imageDocument.filterPreviewIsOpen)
    }

    private func policyAllows(_ value: MetadataRatingValue, info: EngineSession.MetadataTagInfo) -> Bool {
        MetadataSheetLogic.ratingActionAllowed(value, descriptor: info, capturedValues: initialValues)
    }

    private func updateControls() {
        let available = !isInvalidated && !isWriting
        let allowed = selectedValue.flatMap { value in descriptor.map { policyAllows(value, info: $0) } } ?? false
        popup.isEnabled = available && !isReading
        applyButton.isEnabled = available && !isReading && !stale && allowed && writeRefusal == nil
        cancelButton.isEnabled = available
        window?.standardWindowButton(.closeButton)?.isEnabled = available
        message.textColor = lastError == nil ? .secondaryLabelColor : .systemRed
        message.stringValue = lastError ?? (isWriting ? "Applying…" : (isReading ? "Reading…" : (writeRefusal ?? "")))
    }

    private func showError(_ text: String) {
        lastError = text
        updateControls()
    }

    /// Each Apply obtains its own queued descriptor before admitting the write.
    private func loadDescriptor(applying value: MetadataRatingValue? = nil) {
        documentStateDidChange()
        guard !isInvalidated, !isWriting, !stale else { return }
        readGeneration += 1
        let request = readGeneration
        isReading = true
        descriptor = nil
        lastError = nil
        updateControls()
        imageDocument.readMetadataTagInfo(Self.fixedTag) { [weak self] result in
            guard let self, !self.isInvalidated, request == self.readGeneration else { return }
            self.isReading = false
            self.documentStateDidChange()
            guard !self.isInvalidated, !self.stale else { return }
            switch result {
            case .failure(let error): self.showError(String(describing: error))
            case .success(let info):
                guard MetadataSheetLogic.ratingDescriptorMatches(info, values: self.initialValues) else {
                    return self.showError("The tag descriptor does not match the captured XMP rating values.")
                }
                self.descriptor = info
                if let value { self.write(value, info: info) }
                else { self.updateControls() }
            }
        }
    }

    @objc private func popupChanged(_ sender: Any?) {
        guard !isInvalidated else { return }
        if !stale { lastError = nil }
        updateControls()
    }

    @objc func apply(_ sender: Any?) {
        guard !isInvalidated, !isWriting, !isReading else { return }
        documentStateDidChange()
        guard !isInvalidated, !stale else { return }
        if let refusal = writeRefusal { return showError(refusal) }
        guard let value = selectedValue else { return showError("Choose a value before applying.") }
        loadDescriptor(applying: value)
    }

    private func write(_ value: MetadataRatingValue, info: EngineSession.MetadataTagInfo) {
        if let refusal = writeRefusal { return showError(refusal) }
        guard policyAllows(value, info: info) else {
            return showError(value == .unspecified
                ? "The tag's format policy does not allow removing it from here."
                : "The tag's format policy does not allow setting it from here.")
        }
        let values = value.values
        let request = UUID()
        writeRequest = request
        isWriting = true
        lastError = nil
        updateControls()
        imageDocument.editMetadata(Self.fixedTag, value == .unspecified ? .remove : .set, values: values) { [weak self] result in
            guard let self, !self.isInvalidated, self.writeRequest == request else { return }
            guard !self.imageDocument.isClosing else { return self.invalidate() }
            self.writeRequest = nil
            self.isWriting = false
            switch result {
            case .success:
                let callback = self.onApplied
                self.onApplied = nil
                callback?(values)
                self.invalidate()
            case .failure(let error):
                self.showError(String(describing: error))
                self.documentStateDidChange()
            }
        }
    }

    @objc func cancel(_ sender: Any?) {
        guard !isInvalidated, !isWriting else { return }
        invalidate()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        readGeneration += 1
        writeRequest = nil
        isReading = false
        isWriting = false
        onApplied = nil
        commitFieldEdit()
        if let window {
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
        let callback = onClosed
        onClosed = nil
        callback?()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !isWriting else { return false }
        invalidate()
        return false
    }

    func windowWillClose(_ notification: Notification) { invalidate() }
}
