import AppKit

@MainActor
final class InkCurvesPanel: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    typealias Settings = EngineSession.InkCurvesSettings

    private struct NumericEntry: Equatable {
        var text: String
        var value: Int
    }

    private struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let graph = CurvesGraphView()
    let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    let sampleIndexField = NSTextField()
    let outputField = NSTextField()

    private let inkNameField = NSTextField(wrappingLabelWithString: "")
    private let hintField = NSTextField(wrappingLabelWithString: "Intensity: 0 = full ink; 1 = paper.")
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let indexFormatter = NumberFormatter()
    private let outputFormatter = NumberFormatter()
    private var contentStack: NSStackView?

    private let changed: (Settings) -> Void
    private let applyAction: (Settings) -> Void
    private let cancelAction: () -> Void

    private var lastValidSettings: Settings
    private var displayedIndex = NumericEntry(text: "0", value: 0)
    private var displayedOutputText = "0"
    private var numericValidationError: String?
    private var previewCurrent = false
    private var previewError: String?
    private var applying = false
    private var finished = false
    private var actionPending = false
    private var cancelInvoked = false
    private var suppressFieldEvents = false
    private var pendingGestureSamples: [Double]?
    private var gestureOwnedByGraph = false

    init(inkName: String,
         settings: Settings = .init(),
         changed: @escaping (Settings) -> Void,
         apply: @escaping (Settings) -> Void,
         cancel: @escaping () -> Void) {
        self.changed = changed
        self.applyAction = apply
        self.cancelAction = cancel
        let initialLast = settings.isValid ? settings : .init()
        self.lastValidSettings = initialLast
        self.numericValidationError = settings.isValid ? nil : "Enter sample index from 0 to 255 and output from 0 to 1."
        self.pendingGestureSamples = nil

        indexFormatter.locale = .current
        indexFormatter.numberStyle = .decimal
        indexFormatter.usesGroupingSeparator = false
        indexFormatter.minimumFractionDigits = 0
        indexFormatter.maximumFractionDigits = 0

        outputFormatter.locale = .current
        outputFormatter.numberStyle = .decimal
        outputFormatter.usesGroupingSeparator = false
        outputFormatter.minimumFractionDigits = 0
        outputFormatter.maximumFractionDigits = 6

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.title = "Ink Curves"

        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel, inkName: inkName)
        display(settings, samples: settings.samples)
        updateState()
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setPreviewState(current: Bool, error: String? = nil) {
        guard !finished else { return }
        previewCurrent = current
        previewError = error?.isEmpty == false ? error : nil
        updateState()
    }

    func setApplying(_ applying: Bool) {
        guard !finished else { return }
        self.applying = applying
        updateState()
    }

    func finish() {
        guard !finished else { return }
        finished = true
        actionPending = false
        window?.orderOut(nil)
    }

    func cancel() {
        guard !applying, !finished, !cancelInvoked else { return }
        finished = true
        cancelInvoked = true
        actionPending = false
        window?.orderOut(nil)
        cancelAction()
    }

    @objc func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard !applying else { return false }
        if !finished { cancel() }
        return false
    }

    func controlTextDidChange(_ obj: Notification) {
        guard !suppressFieldEvents, !finished, !applying, !actionPending else { return }
        _ = validateNumericFieldsAndPublish()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !suppressFieldEvents, !finished, !applying, !actionPending else { return }
        _ = validateNumericFieldsAndPublish()
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == NSSelectorFromString("insertNewline:") {
            requestApply()
            return true
        }
        if commandSelector == NSSelectorFromString("cancelOperation:") {
            cancel()
            return true
        }
        return false
    }

    private func buildContent(in panel: NSPanel, inkName: String) {
        inkNameField.stringValue = inkName
        inkNameField.font = NSFont.systemFont(ofSize: NSFont.labelFontSize)
        inkNameField.setAccessibilityLabel("Ink")
        inkNameField.lineBreakMode = .byWordWrapping

        hintField.font = NSFont.systemFont(ofSize: max(11, NSFont.smallSystemFontSize))
        hintField.textColor = .secondaryLabelColor
        hintField.setAccessibilityLabel("Hint")
        hintField.lineBreakMode = .byWordWrapping

        statusField.font = NSFont.systemFont(ofSize: max(11, NSFont.smallSystemFontSize))
        statusField.setAccessibilityLabel("Status")
        statusField.lineBreakMode = .byWordWrapping

        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.widthAnchor.constraint(equalToConstant: 480).isActive = true
        graph.heightAnchor.constraint(equalToConstant: 250).isActive = true
        graph.setAccessibilityLabel("Curves graph")
        graph.state = EngineSession.CurveState(kind: .free, points: [], samples: lastValidSettings.samples)

        graph.onBeginEdit = { [weak self] in
            guard let self, !self.finished, !self.applying, !self.actionPending,
                  self.validateNumericFieldsAndPublish() else { return false }
            self.gestureOwnedByGraph = true
            self.pendingGestureSamples = nil
            self.updateState()
            return true
        }
        graph.onStateEdit = { [weak self] _, _, samples in
            guard let self, !self.finished else { return }
            self.pendingGestureSamples = samples
            self.numericValidationError = nil
            self.previewCurrent = false
            self.previewError = nil
            self.refreshOutputField(for: samples, index: self.displayedIndex.value)
            self.updateState()
        }
        graph.onEndInteraction = { [weak self] _ in
            guard let self, !self.finished else { return }
            self.gestureOwnedByGraph = self.graph.isInteracting
            if self.graph.isInteracting { self.updateState(); return }
            if let samples = self.pendingGestureSamples {
                self.pendingGestureSamples = nil
                self.commitSamples(samples)
            } else {
                self.updateState()
            }
        }

        for field in [sampleIndexField, outputField] {
            field.delegate = self
            field.target = self
            field.action = #selector(fieldAction(_:))
            field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 90).isActive = true
        }
        sampleIndexField.setAccessibilityLabel("Sample index")
        outputField.setAccessibilityLabel("Output")

        let indexLabel = NSTextField(labelWithString: "Index:")
        let outputLabel = NSTextField(labelWithString: "Output:")
        for label in [indexLabel, outputLabel] {
            label.font = NSFont.systemFont(ofSize: NSFont.labelFontSize)
            label.setAccessibilityLabel(label.stringValue)
        }

        let numeric = NSStackView(views: [indexLabel, sampleIndexField, outputLabel, outputField])
        numeric.orientation = .horizontal
        numeric.alignment = .firstBaseline
        numeric.spacing = 8

        for button in [resetButton, cancelButton, applyButton] {
            button.font = NSFont.systemFont(ofSize: max(11, NSFont.systemFontSize))
        }
        resetButton.target = self
        resetButton.action = #selector(resetPressed(_:))
        resetButton.setAccessibilityLabel("Reset")

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel")

        applyButton.target = self
        applyButton.action = #selector(applyPressed(_:))
        applyButton.keyEquivalent = "\r"
        applyButton.setAccessibilityLabel("Apply")

        let buttons = NSStackView(views: [NSView(), resetButton, cancelButton, applyButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [inkNameField, hintField, graph, numeric, statusField, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentStack = stack

        for label in [inkNameField, hintField, statusField] {
            label.preferredMaxLayoutWidth = 488
        }

        let content = NSView()
        panel.contentView = content
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 520),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            inkNameField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            hintField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            statusField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            statusField.heightAnchor.constraint(equalToConstant: 36),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])

        resizeToFitContent()
    }

    private func resizeToFitContent() {
        guard let stack = contentStack else { return }
        window?.setContentSize(NSSize(width: 520, height: max(360, stack.fittingSize.height)))
    }

    private func display(_ settings: Settings, samples: [Double]) {
        let index = min(255, max(0, displayedIndex.value))
        displayedIndex = NumericEntry(text: indexFormatter.string(from: NSNumber(value: index)) ?? "\(index)", value: index)
        sampleIndexField.stringValue = displayedIndex.text
        refreshOutputField(for: samples, index: index)
        if !graph.isInteracting {
            graph.state = EngineSession.CurveState(kind: .free, points: [], samples: samples)
        }
    }

    private func refreshOutputField(for samples: [Double], index: Int) {
        let safeIndex = min(max(index, 0), samples.count - 1)
        let value = samples.indices.contains(safeIndex) ? samples[safeIndex] : 0
        displayedOutputText = outputFormatter.string(from: NSNumber(value: value)) ?? "0"
        outputField.stringValue = displayedOutputText
    }

    @objc private func fieldAction(_ sender: NSTextField) {
        guard !finished, !applying, !actionPending, !suppressFieldEvents else { return }
        _ = validateNumericFieldsAndPublish()
    }

    @objc private func resetPressed(_ sender: Any?) {
        guard !finished, !applying, !actionPending else { return }
        actionPending = true
        defer { actionPending = false; updateState() }
        suppressFieldEvents = true
        window?.endEditing(for: nil)
        suppressFieldEvents = false
        let identity = Settings()
        numericValidationError = nil
        previewCurrent = false
        previewError = nil
        pendingGestureSamples = nil
        gestureOwnedByGraph = false
        lastValidSettings = identity
        displayedIndex = NumericEntry(text: "0", value: 0)
        display(identity, samples: identity.samples)
        graph.state = EngineSession.CurveState(kind: .free, points: [], samples: identity.samples)
        updateState()
        changed(identity)
    }

    @objc private func cancelPressed(_ sender: Any?) { cancel() }

    @objc private func applyPressed(_ sender: Any?) { requestApply() }

    private func requestApply() {
        guard !finished, !applying, !actionPending else { return }
        guard validateNumericFieldsAndPublish() else { return }
        guard !finished, !applying else { return }
        suppressFieldEvents = true
        window?.endEditing(for: nil)
        suppressFieldEvents = false
        guard validateNumericFieldsAndPublish(), canApply else { return }
        actionPending = true
        applying = true
        defer { actionPending = false; updateState() }
        updateState()
        applyAction(lastValidSettings)
    }

    @discardableResult
    private func validateNumericFieldsAndPublish() -> Bool {
        guard !finished, !applying else { return false }
        if graph.isInteracting || gestureOwnedByGraph || pendingGestureSamples != nil {
            updateState()
            return false
        }
        switch parseFields() {
        case .success(let parsed):
            let settings = Settings(samples: parsed.samples)
            let needsPreview = settings != lastValidSettings || previewError != nil
            numericValidationError = nil
            displayedIndex = parsed.indexEntry
            lastValidSettings = settings
            display(settings, samples: settings.samples)
            if needsPreview {
                previewCurrent = false
                previewError = nil
                actionPending = true
                updateState()
                changed(settings)
                actionPending = false
            }
            updateState()
            return !finished && !applying
        case .failure(let error):
            numericValidationError = error.message
            updateState()
            return false
        }
    }

    private struct ParsedFields {
        var samples: [Double]
        var indexEntry: NumericEntry
    }

    private func parseFields() -> Result<ParsedFields, ParseError> {
        let indexText = (sampleIndexField.currentEditor()?.string ?? sampleIndexField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let outputText = (outputField.currentEditor()?.string ?? outputField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let index: Int
        if indexText == displayedIndex.text {
            index = displayedIndex.value
        } else {
            let scanner = Scanner(string: indexText)
            scanner.locale = indexFormatter.locale
            var parsedIndex: Double = 0
            guard scanner.scanDouble(&parsedIndex), scanner.isAtEnd, parsedIndex.isFinite,
                  parsedIndex.rounded(.towardZero) == parsedIndex, (0.0...255.0).contains(parsedIndex) else {
                return .failure(ParseError(message: "Enter sample index from 0 to 255."))
            }
            index = Int(parsedIndex)
        }

        let currentSamples = lastValidSettings.samples
        guard currentSamples.indices.contains(index) else {
            return .failure(ParseError(message: "Enter sample index from 0 to 255."))
        }

        var samples = currentSamples
        // Selecting another sample only changes the readout. Compare against
        // the last text actually displayed, not the newly selected value.
        if outputText != displayedOutputText {
            let scanner = Scanner(string: outputText)
            scanner.locale = outputFormatter.locale
            var value: Double = 0
            guard scanner.scanDouble(&value), scanner.isAtEnd, value.isFinite, (0.0...1.0).contains(value) else {
                return .failure(ParseError(message: "Enter output from 0 to 1."))
            }
            samples[index] = value
        }

        let settings = Settings(samples: samples)
        guard settings.isValid else {
            return .failure(ParseError(message: "Enter sample index from 0 to 255 and output from 0 to 1."))
        }
        let entry = NumericEntry(text: indexFormatter.string(from: NSNumber(value: index)) ?? "\(index)", value: index)
        return .success(ParsedFields(samples: samples, indexEntry: entry))
    }

    private func commitSamples(_ samples: [Double]) {
        let settings = Settings(samples: samples)
        guard settings.isValid, !finished, !applying else { updateState(); return }
        numericValidationError = nil
        lastValidSettings = settings
        previewCurrent = false
        previewError = nil
        display(settings, samples: samples)
        actionPending = true
        updateState()
        changed(settings)
        actionPending = false
        updateState()
    }

    private var canApply: Bool {
        guard !finished, !applying, !actionPending, numericValidationError == nil,
              !graph.isInteracting, !gestureOwnedByGraph, pendingGestureSamples == nil,
              previewCurrent, previewError == nil else { return false }
        if case .success = parseFields() { return true }
        return false
    }

    private func updateState() {
        let editable = !applying && !finished
        for field in [sampleIndexField, outputField] { field.isEditable = editable; field.isEnabled = editable }
        resetButton.isEnabled = editable
        cancelButton.isEnabled = !finished && !cancelInvoked && !applying && !actionPending
        applyButton.isEnabled = canApply

        if let numericValidationError {
            statusField.stringValue = numericValidationError
            statusField.textColor = .systemRed
        } else if let previewError {
            statusField.stringValue = previewError
            statusField.textColor = .systemRed
        } else if applying {
            statusField.stringValue = "Applying ink curves…"
            statusField.textColor = .secondaryLabelColor
        } else if !previewCurrent || graph.isInteracting || gestureOwnedByGraph || pendingGestureSamples != nil {
            statusField.stringValue = "Updating preview…"
            statusField.textColor = .secondaryLabelColor
        } else {
            statusField.stringValue = ""
            statusField.textColor = .secondaryLabelColor
        }

        window?.standardWindowButton(.closeButton)?.isEnabled = !applying && !finished && !actionPending
    }
}
