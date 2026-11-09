import AppKit

/// Edits one camera-local civil time without inventing a zone or missing parts.
@MainActor
final class MetadataCaptureDateEditor: NSWindowController, NSWindowDelegate {
    static let fixedTag = MetadataSheetLogic.captureDateTag
    private static let staleMessage = "The document changed. Close and reopen this editor before applying."

    let imageDocument: ImageDocument
    let sourceText: String
    let yearField = NSTextField()
    let monthField = NSTextField()
    let dayField = NSTextField()
    let hourField = NSTextField()
    let minuteField = NSTextField()
    let secondField = NSTextField()
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private let initialDate: MetadataCaptureDate?
    private let initialStateVersion: Int
    private var stale = false
    private var writeRequest: UUID?
    private(set) var lastError: String?
    private(set) var isWriting = false
    private(set) var isInvalidated = false
    var onApplied: (([String]) -> Void)?
    var onClosed: (() -> Void)?

    init?(document: ImageDocument, values: [String]) {
        guard values.count <= 1 else { return nil }
        self.imageDocument = document
        sourceText = values.first ?? "No value"
        initialDate = values.first.flatMap { MetadataCaptureDate(metadataText: $0) }
        initialStateVersion = document.stateVersion
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 300),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Capture Date and Time"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
        if let date = initialDate {
            yearField.stringValue = String(date.year)
            monthField.stringValue = String(date.month)
            dayField.stringValue = String(date.day)
            hourField.stringValue = String(date.hour)
            minuteField.stringValue = String(date.minute)
            secondField.stringValue = String(date.second)
        }
        // Absent or malformed source values deliberately leave every field blank.
        panel.initialFirstResponder = yearField
        updateControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var fields: [NSTextField] {
        [yearField, monthField, dayField, hourField, minuteField, secondField]
    }

    private func buildContent(in panel: NSPanel) {
        let names = ["Year", "Month", "Day", "Hour", "Minute", "Second"]
        for (name, field) in zip(names, fields) {
            field.setAccessibilityLabel("Capture \(name.lowercased())")
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
        }
        let note = NSTextField(wrappingLabelWithString:
            "Enter the local capture time. Time-zone offset and subseconds remain unchanged.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let originalLabel = NSTextField(labelWithString: "Original value:")
        let original = NSTextView(frame: NSRect(x: 0, y: 0, width: 508, height: 54))
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
        original.setAccessibilityLabel("Original capture date and time")
        let sourceScroll = NSScrollView()
        sourceScroll.documentView = original
        sourceScroll.hasVerticalScroller = true
        sourceScroll.autohidesScrollers = true
        sourceScroll.borderType = .bezelBorder
        sourceScroll.heightAnchor.constraint(equalToConstant: 54).isActive = true

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Year:"), yearField,
             NSTextField(labelWithString: "Month:"), monthField,
             NSTextField(labelWithString: "Day:"), dayField],
            [NSTextField(labelWithString: "Hour:"), hourField,
             NSTextField(labelWithString: "Minute:"), minuteField,
             NSTextField(labelWithString: "Second:"), secondField]
        ])
        grid.columnSpacing = 8
        grid.rowSpacing = 10
        message.maximumNumberOfLines = 3
        message.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        message.setAccessibilityLabel("Capture date error")
        message.heightAnchor.constraint(equalToConstant: 46).isActive = true
        applyButton.target = self
        applyButton.action = #selector(apply(_:))
        applyButton.keyEquivalent = "\r"
        applyButton.setAccessibilityLabel("Apply capture date and time")
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel capture date and time")
        let actions = NSStackView(views: [NSView(), cancelButton, applyButton])
        actions.spacing = 8
        let stack = NSStackView(views: [note, originalLabel, sourceScroll, grid, message, actions])
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
            note.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            sourceScroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        ])
        panel.setContentSize(NSSize(width: max(540, grid.fittingSize.width + 32),
                                    height: stack.fittingSize.height))
    }

    func present(on parent: NSWindow) {
        guard !isInvalidated, let window, window.sheetParent == nil else { return }
        guard parent.attachedSheet == nil else {
            showError("Close the current sheet before opening this editor.")
            return
        }
        documentStateDidChange()
        parent.beginSheet(window) { [weak self] _ in self?.invalidate() }
    }

    func commitFieldEdit() { window?.endEditing(for: nil) }

    func documentStateDidChange() {
        guard !isInvalidated else { return }
        if !isWriting, imageDocument.stateVersion != initialStateVersion {
            stale = true
            lastError = Self.staleMessage
        }
        updateControls()
    }

    private var writeRefusal: String? {
        MetadataSheetLogic.writeAdmission(isClosing: imageDocument.isClosing,
            isSavingForClose: imageDocument.isSavingForClose, isTransferringClipboard: imageDocument.isTransferringClipboard,
            pluginRunning: PlugInCommands.isRunning, engineBusy: EngineActivity.shared.isBusy,
            filterPreviewOpen: imageDocument.filterPreviewIsOpen)
    }

    private func updateControls() {
        let available = !isInvalidated && !isWriting
        fields.forEach { $0.isEnabled = available }
        applyButton.isEnabled = available && !stale && writeRefusal == nil
        cancelButton.isEnabled = available
        window?.standardWindowButton(.closeButton)?.isEnabled = available
        message.textColor = lastError == nil ? .secondaryLabelColor : .systemRed
        message.stringValue = lastError ?? (isWriting ? "Applying…" : (writeRefusal ?? ""))
    }

    private func showError(_ text: String) {
        lastError = text
        updateControls()
    }

    private func integer(in field: NSTextField, maxDigits: Int) -> Int? {
        let bytes = field.stringValue.utf8
        guard !bytes.isEmpty, bytes.count <= maxDigits,
              bytes.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int(field.stringValue)
    }

    @objc func apply(_ sender: Any?) {
        guard !isInvalidated, !isWriting else { return }
        commitFieldEdit()
        documentStateDidChange()
        guard !stale else { return }
        if let refusal = writeRefusal { return showError(refusal) }
        guard let year = integer(in: yearField, maxDigits: 4),
              let month = integer(in: monthField, maxDigits: 2),
              let day = integer(in: dayField, maxDigits: 2),
              let hour = integer(in: hourField, maxDigits: 2),
              let minute = integer(in: minuteField, maxDigits: 2),
              let second = integer(in: secondField, maxDigits: 2),
              let date = MetadataCaptureDate(year: year, month: month, day: day,
                                              hour: hour, minute: minute, second: second) else {
            return showError("Enter all six fields using numbers only, with a valid date and time and a year from 1 to 9999.")
        }
        let text = date.metadataText
        if initialDate?.metadataText == text {
            finishApplied(text)
            return
        }
        let request = UUID()
        writeRequest = request
        isWriting = true
        lastError = nil
        updateControls()
        imageDocument.editMetadata(Self.fixedTag, .set, values: [text]) { [weak self] result in
            guard let self, !self.isInvalidated, self.writeRequest == request else { return }
            self.writeRequest = nil
            self.isWriting = false
            switch result {
            case .success: self.finishApplied(text)
            case .failure(let error):
                self.showError(String(describing: error))
                self.documentStateDidChange()
            }
        }
    }

    private func finishApplied(_ text: String) {
        let callback = onApplied
        onApplied = nil
        callback?([text])
        invalidate()
    }

    @objc func cancel(_ sender: Any?) {
        guard !isInvalidated, !isWriting else { return }
        invalidate()
    }

    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        writeRequest = nil
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
