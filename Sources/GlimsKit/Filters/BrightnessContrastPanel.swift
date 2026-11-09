import AppKit

/// A paired, normalized brightness/contrast draft for one captured preview.
@MainActor
final class BrightnessContrastPanel: FilterPreviewPanel, NSTextFieldDelegate {
    typealias Settings = EngineSession.BrightnessContrastSettings

    let brightnessField = NSTextField()
    let contrastField = NSTextField()
    let brightnessSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    let contrastSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let formatter = NumberFormatter()
    private var draft: Settings
    private var accepted: Settings
    private var generation = 0
    private var acceptedGeneration = 0
    private var pending: [Int: Settings] = [:]
    private var draftGeneration = 0
    private var latestReply: (generation: Int, result: Result<Void, Error>)?
    private var invalidFieldDuringCommit = false
    private var displayedBrightness = ""
    private var displayedContrast = ""
    private let writeSettings: @MainActor (Int32, Settings, @escaping @MainActor (Result<Void, Error>) -> Void) -> Void
    private(set) var lastError: String?

    private struct InputError: LocalizedError {
        var errorDescription: String? { "Enter a percentage from −100 to 100." }
    }

    init?(document: ImageDocument, filter: Int32,
          initialValues: [String: EngineSession.FilterValue],
          write: (@MainActor (Int32, Settings, @escaping @MainActor (Result<Void, Error>) -> Void) -> Void)? = nil) {
        guard case .number(let brightness)? = initialValues["brightness"],
              case .number(let contrast)? = initialValues["contrast"] else { return nil }
        let initial = Settings(brightness: brightness, contrast: contrast)
        guard initial.isValid else { return nil }
        draft = initial
        accepted = initial
        writeSettings = write ?? { [weak document] filter, value, reply in
            guard let document else { return reply(.failure(ImageDocument.DocumentError.closed)) }
            document.setBrightnessContrast(filter, value, completion: reply)
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 208),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Brightness and Contrast"
        panel.isFloatingPanel = true
        super.init(document: document, panel: panel, filter: filter)
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        buildContent(in: panel)
        display(initial)
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func showError(_ message: String) {
        guard filter != nil else { return }
        lastError = message.isEmpty ? nil : message
        statusField.stringValue = message
    }

    private func buildContent(in panel: NSPanel) {
        let pairs = [("Brightness", brightnessField, brightnessSlider),
                     ("Contrast", contrastField, contrastSlider)]
        var rows: [[NSView]] = []
        for (name, field, slider) in pairs {
            field.setAccessibilityLabel("\(name) percent")
            field.widthAnchor.constraint(equalToConstant: 78).isActive = true
            field.target = self
            field.action = #selector(fieldsChanged(_:))
            field.delegate = self
            slider.setAccessibilityLabel(name)
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let number = NSStackView(views: [field, NSTextField(labelWithString: "%")])
            number.spacing = 4
            rows.append([NSTextField(labelWithString: "\(name):"), slider, number])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        statusField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.textColor = .systemRed
        statusField.maximumNumberOfLines = 2
        statusField.lineBreakMode = .byTruncatingTail
        statusField.setAccessibilityLabel("Filter status")
        statusField.heightAnchor.constraint(equalToConstant: 34).isActive = true
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel brightness and contrast")
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(commit))
        applyButton.keyEquivalent = "\r"
        applyButton.setAccessibilityLabel("Apply brightness and contrast")
        let buttons = NSStackView(views: [NSView(), cancelButton, applyButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [grid, statusField, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
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
            statusField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        ])
        panel.setContentSize(NSSize(width: max(460, grid.fittingSize.width + 32),
                                    height: stack.fittingSize.height))
    }

    private func display(_ value: Settings) {
        brightnessSlider.doubleValue = value.brightness * 100
        contrastSlider.doubleValue = value.contrast * 100
        brightnessField.stringValue = formatter.string(from: NSNumber(value: value.brightness * 100)) ?? "0"
        contrastField.stringValue = formatter.string(from: NSNumber(value: value.contrast * 100)) ?? "0"
        displayedBrightness = brightnessField.stringValue
        displayedContrast = contrastField.stringValue
    }

    private func displayPreservingFieldDrafts(_ value: Settings) {
        FilterFieldDrafts.preserve([(brightnessField, displayedBrightness), (contrastField, displayedContrast)]) {
            display(value)
        }
    }

    private func percentage(in field: NSTextField) -> Double? {
        // Display rounding must not turn Apply on an untouched seed into a
        // parameter edit, or alter the other half of a paired write.
        if field === brightnessField, field.stringValue == displayedBrightness { return draft.brightness }
        if field === contrastField, field.stringValue == displayedContrast { return draft.contrast }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanner = Scanner(string: text)
        scanner.locale = Locale.current
        guard let value = scanner.scanDouble(), scanner.isAtEnd,
              value.isFinite, (-100...100).contains(value) else { return nil }
        return value / 100
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        guard filter != nil else { return }
        var value = draft
        if sender === brightnessSlider { value.brightness = sender.doubleValue / 100 }
        else if sender === contrastSlider { value.contrast = sender.doubleValue / 100 }
        else { return }
        guard value.isValid else { rejectField(); return }
        display(value)
        submit(value)
    }

    @objc func fieldsChanged(_ sender: Any?) {
        _ = commitFields()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        _ = commitFields()
    }

    @discardableResult
    private func commitFields() -> Bool {
        guard filter != nil else { return false }
        guard let brightness = percentage(in: brightnessField),
              let contrast = percentage(in: contrastField) else {
            rejectField()
            return false
        }
        submit(Settings(brightness: brightness, contrast: contrast))
        return true
    }

    private func rejectField() {
        invalidFieldDuringCommit = true
        generation += 1
        latestReply = (generation, .failure(InputError()))
        showError(InputError().localizedDescription)
        resolveLatestReply()
    }

    private func submit(_ value: Settings) {
        guard let filter, value.isValid else { return }
        guard value != draft else { return }
        draft = value
        display(value)
        generation += 1
        let request = generation
        pending[request] = value
        draftGeneration = request
        latestReply = nil
        showError("")
        writeSettings(filter, value) { [weak self] result in
            guard let self, self.filter == filter else { return }
            self.pending.removeValue(forKey: request)
            // An older accepted pair remains the engine's state if a newer
            // write fails. Do this before filtering replies for presentation.
            if case .success = result, request > self.acceptedGeneration {
                self.accepted = value
                self.acceptedGeneration = request
            }
            if case .failure = result, self.draftGeneration == request {
                if let previous = self.pending.keys.filter({ $0 > self.acceptedGeneration }).max(),
                   let value = self.pending[previous] {
                    self.draft = value
                    self.draftGeneration = previous
                } else {
                    self.draft = self.accepted
                    self.draftGeneration = self.acceptedGeneration
                }
                self.displayPreservingFieldDrafts(self.draft)
            }
            if self.generation == request { self.latestReply = (request, result) }
            self.resolveLatestReply()
        }
    }

    private func resolveLatestReply() {
        guard filter != nil, let reply = latestReply, reply.generation == generation else { return }
        // Refusals can be synchronous while an earlier accepted write is
        // still queued. Wait for those replies before choosing the rollback.
        guard !pending.keys.contains(where: { $0 < reply.generation }) else { return }
        latestReply = nil
        switch reply.result {
        case .success:
            showError("")
        case .failure(let error):
            if !(error is InputError) {
                draft = accepted
                draftGeneration = acceptedGeneration
                displayPreservingFieldDrafts(accepted)
            }
            showError(error.localizedDescription)
        }
    }

    /// Field focus loss queues the final complete pair before shared finish.
    @objc override func commit() {
        guard filter != nil else { return }
        invalidFieldDuringCommit = false
        window?.endEditing(for: nil)
        guard !invalidFieldDuringCommit, commitFields() else { return }
        super.commit()
    }
}
