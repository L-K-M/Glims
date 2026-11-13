import AppKit

@MainActor
final class InkLevelsPanel: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    typealias Settings = EngineSession.InkLevelsSettings

    private enum Domain {
        case ink(name: String)
        case lab(axis: EngineSession.LabAxis)

        var title: String {
            switch self {
            case .ink: return "Ink Levels"
            case .lab: return "Lab Levels"
            }
        }

        var heading: String {
            switch self {
            case .ink(let name): return name
            case .lab(let axis): return axis.name
            }
        }

        var headingAccessibilityLabel: String {
            switch self {
            case .ink: return "Ink"
            case .lab: return "Lab axis"
            }
        }

        var hint: String {
            switch self {
            case .ink:
                return "Intensity: 0 = full ink; 1 = paper."
            case .lab(let axis):
                switch axis.role {
                case .lightness:
                    return "L*: 0 = black, 100 = white."
                case .a:
                    return "a*: -128 = green, 127 = red."
                case .b:
                    return "b*: -128 = blue, 127 = yellow."
                }
            }
        }

        func physicalRange(for field: Field) -> ClosedRange<Double> {
            if field == .gamma { return 0.1...10.0 }
            switch self {
            case .ink:
                return 0.0...1.0
            case .lab(let axis):
                let range = axis.role.nominalRange
                return range.lowerBound...range.upperBound
            }
        }

        var endpointRangeDescription: String {
            switch self {
            case .ink:
                return "0 to 1"
            case .lab(let axis):
                let range = axis.role.nominalRange
                return "\(formatBound(range.lowerBound)) to \(formatBound(range.upperBound))"
            }
        }

        private func formatBound(_ value: Double) -> String {
            if value.rounded(.towardZero) == value, value >= -128, value <= 127 {
                return String(Int(value))
            }
            return String(value)
        }

        var applyingStatus: String {
            switch self {
            case .ink: return "Applying ink levels…"
            case .lab: return "Applying Lab levels…"
            }
        }

        var invalidSettingsMessage: String {
            switch self {
            case .ink:
                return "Enter levels endpoints from 0 to 1 and gamma from 0.1 to 10."
            case .lab(let axis):
                let range = axis.role.nominalRange
                return "Enter levels endpoints from \(formatBound(range.lowerBound)) to \(formatBound(range.upperBound)) and gamma from 0.1 to 10."
            }
        }
    }

    private enum Field: Int, CaseIterable {
        case lowInput, highInput, gamma, lowOutput, highOutput

        var title: String {
            switch self {
            case .lowInput: return "Low input"
            case .highInput: return "High input"
            case .gamma: return "Gamma"
            case .lowOutput: return "Low output"
            case .highOutput: return "High output"
            }
        }
    }

    private struct NeutralSettings: Equatable {
        var value: EngineSession.LevelsSettings.Channel = .init()
        var clampInput = false
        var clampOutput = false

        var isValid: Bool { value.isValid }
    }

    private struct NumericEntry {
        var text: String
        var value: Double
    }

    private struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let lowInputField = NSTextField()
    let highInputField = NSTextField()
    let gammaField = NSTextField()
    let lowOutputField = NSTextField()
    let highOutputField = NSTextField()
    let clampInputButton = NSButton(checkboxWithTitle: "Clamp input", target: nil, action: nil)
    let clampOutputButton = NSButton(checkboxWithTitle: "Clamp output", target: nil, action: nil)
    let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let applyButton = NSButton(title: "Apply", target: nil, action: nil)

    private let headingField = NSTextField(wrappingLabelWithString: "")
    private let hintField = NSTextField(wrappingLabelWithString: "")
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let formatter: NumberFormatter
    private var contentStack: NSStackView?

    private let domain: Domain
    private let changedNeutral: (NeutralSettings) -> Void
    private let applyNeutral: (NeutralSettings) -> Void
    private let cancelAction: () -> Void

    private var lastValidSettings: NeutralSettings
    private var displayedEntries: [NumericEntry]
    private var numericValidationError: String?
    private var previewCurrent = false
    private var previewError: String?
    private var applying = false
    private var finished = false
    private var actionPending = false
    private var cancelInvoked = false
    private var suppressFieldEvents = false

    private var fields: [NSTextField] {
        [lowInputField, highInputField, gammaField, lowOutputField, highOutputField]
    }

    convenience init(inkName: String,
                     settings: Settings = .init(),
                     changed: @escaping (Settings) -> Void,
                     apply: @escaping (Settings) -> Void,
                     cancel: @escaping () -> Void) {
        self.init(domain: .ink(name: inkName),
                  initial: NeutralSettings(value: settings.value,
                                           clampInput: settings.clampInput,
                                           clampOutput: settings.clampOutput),
                  initialValid: settings.isValid,
                  changed: { changed(Settings(value: $0.value, clampInput: $0.clampInput, clampOutput: $0.clampOutput)) },
                  apply: { apply(Settings(value: $0.value, clampInput: $0.clampInput, clampOutput: $0.clampOutput)) },
                  cancel: cancel)
    }

    convenience init(labAxis: EngineSession.LabAxis,
                     settings: EngineSession.LabLevelsSettings = .init(),
                     changed: @escaping (EngineSession.LabLevelsSettings) -> Void,
                     apply: @escaping (EngineSession.LabLevelsSettings) -> Void,
                     cancel: @escaping () -> Void) {
        self.init(domain: .lab(axis: labAxis),
                  initial: NeutralSettings(value: settings.value,
                                           clampInput: settings.clampInput,
                                           clampOutput: settings.clampOutput),
                  initialValid: settings.isValid,
                  changed: { changed(EngineSession.LabLevelsSettings(value: $0.value, clampInput: $0.clampInput, clampOutput: $0.clampOutput)) },
                  apply: { apply(EngineSession.LabLevelsSettings(value: $0.value, clampInput: $0.clampInput, clampOutput: $0.clampOutput)) },
                  cancel: cancel)
    }

    private init(domain: Domain,
                 initial: NeutralSettings,
                 initialValid: Bool,
                 changed: @escaping (NeutralSettings) -> Void,
                 apply: @escaping (NeutralSettings) -> Void,
                 cancel: @escaping () -> Void) {
        self.domain = domain
        self.changedNeutral = changed
        self.applyNeutral = apply
        self.cancelAction = cancel
        let initialLast = initialValid ? initial : .init()
        self.lastValidSettings = initialLast
        self.numericValidationError = initialValid ? nil : domain.invalidSettingsMessage

        let formatter = NumberFormatter()
        formatter.locale = .current
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
        self.formatter = formatter
        self.displayedEntries = Self.makeEntries(for: initial.value, domain: domain, formatter: formatter)

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 320),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.title = domain.title

        super.init(window: panel)
        panel.delegate = self
        buildContent(in: panel)
        display(initial)
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
        _ = validateAndPublish()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !suppressFieldEvents, !finished, !applying, !actionPending else { return }
        _ = validateAndPublish()
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

    private func buildContent(in panel: NSPanel) {
        headingField.stringValue = domain.heading
        headingField.font = NSFont.systemFont(ofSize: NSFont.labelFontSize)
        headingField.setAccessibilityLabel(domain.headingAccessibilityLabel)
        headingField.lineBreakMode = .byWordWrapping

        hintField.stringValue = domain.hint
        hintField.font = NSFont.systemFont(ofSize: max(11, NSFont.smallSystemFontSize))
        hintField.textColor = .secondaryLabelColor
        hintField.setAccessibilityLabel("Hint")
        hintField.lineBreakMode = .byWordWrapping

        statusField.font = NSFont.systemFont(ofSize: max(11, NSFont.smallSystemFontSize))
        statusField.setAccessibilityLabel("Status")
        statusField.lineBreakMode = .byWordWrapping

        for (index, field) in fields.enumerated() {
            let item = Field(rawValue: index) ?? .lowInput
            field.delegate = self
            field.target = self
            field.action = #selector(fieldAction(_:))
            field.setAccessibilityLabel(item.title)
            field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        }

        for button in [resetButton, cancelButton, applyButton] {
            button.font = NSFont.systemFont(ofSize: max(11, NSFont.systemFontSize))
        }
        for button in [clampInputButton, clampOutputButton] {
            button.target = self
            button.action = #selector(optionsChanged(_:))
            button.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            button.setAccessibilityLabel(button.title)
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

        var rows: [[NSView]] = []
        for (index, title) in Field.allCases.map(\.title).enumerated() {
            let label = NSTextField(labelWithString: title)
            label.font = NSFont.systemFont(ofSize: NSFont.labelFontSize)
            label.setAccessibilityLabel(title)
            label.lineBreakMode = .byWordWrapping
            rows.append([label, fields[index]])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .fill
        grid.translatesAutoresizingMaskIntoConstraints = false

        let clamps = NSStackView(views: [clampInputButton, clampOutputButton])
        clamps.orientation = .horizontal
        clamps.alignment = .firstBaseline
        clamps.spacing = 16

        let buttons = NSStackView(views: [NSView(), resetButton, cancelButton, applyButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 8

        let stack = NSStackView(views: [headingField, hintField, grid, clamps, statusField, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentStack = stack
        for label in [headingField, hintField, statusField] {
            label.preferredMaxLayoutWidth = 428
        }

        let content = NSView()
        panel.contentView = content
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 460),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            headingField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            hintField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            statusField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            grid.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])

        resizeToFitContent()
    }

    private func resizeToFitContent() {
        guard let stack = contentStack else { return }
        window?.setContentSize(NSSize(width: 460, height: max(260, stack.fittingSize.height)))
    }

    private func display(_ settings: NeutralSettings) {
        for (index, value) in Self.values(of: settings.value).enumerated() {
            let field = Field(rawValue: index) ?? .lowInput
            let physical = Self.physicalValue(for: value, field: field, domain: domain)
            let text = formatter.string(from: NSNumber(value: physical)) ?? "0"
            displayedEntries[index] = NumericEntry(text: text, value: value)
            fields[index].stringValue = text
        }
        clampInputButton.state = settings.clampInput ? .on : .off
        clampOutputButton.state = settings.clampOutput ? .on : .off
    }

    @objc private func fieldAction(_ sender: NSTextField) {
        guard !finished, !applying, !actionPending, !suppressFieldEvents else { return }
        _ = validateAndPublish()
    }

    @objc private func optionsChanged(_ sender: Any?) {
        guard !finished, !applying, !actionPending else { return }
        _ = validateAndPublish()
    }

    @objc private func resetPressed(_ sender: Any?) {
        guard !finished, !applying, !actionPending else { return }
        actionPending = true
        defer { actionPending = false; updateState() }
        // Reset explicitly discards an unfinished field draft.
        suppressFieldEvents = true
        window?.endEditing(for: nil)
        suppressFieldEvents = false
        let identity = NeutralSettings()
        display(identity)
        numericValidationError = nil
        previewCurrent = false
        previewError = nil
        lastValidSettings = identity
        updateState()
        changedNeutral(identity)
    }

    @objc private func cancelPressed(_ sender: Any?) { cancel() }

    @objc private func applyPressed(_ sender: Any?) { requestApply() }

    private func requestApply() {
        guard !finished, !applying, !actionPending else { return }
        // Read the live field editor before ending editing. Invalid text must
        // never let Return apply the previously valid model.
        guard validateAndPublish() else { return }
        guard !finished, !applying else { return }
        suppressFieldEvents = true
        window?.endEditing(for: nil)
        suppressFieldEvents = false
        guard validateAndPublish(), canApply else { return }
        actionPending = true
        applying = true
        defer { actionPending = false; updateState() }
        updateState()
        applyNeutral(lastValidSettings)
    }

    @discardableResult
    private func validateAndPublish() -> Bool {
        guard !finished, !applying else { return false }
        switch parseFields() {
        case .success(let settings):
            let needsPreview = settings != lastValidSettings || previewError != nil
            numericValidationError = nil
            lastValidSettings = settings
            if needsPreview {
                previewCurrent = false
                previewError = nil
                actionPending = true
                updateState()
                changedNeutral(settings)
                actionPending = false
            }
            updateState()
            return !finished && !applying
        case .failure(let error):
            numericValidationError = error.message
            // Leave the text, last valid model and preview image untouched.
            updateState()
            return false
        }
    }

    private func parseFields() -> Result<NeutralSettings, ParseError> {
        var values = Self.values(of: lastValidSettings.value)
        for item in Field.allCases {
            let index = item.rawValue
            let field = fields[index]
            let text = field.currentEditor()?.string ?? field.stringValue
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayed = displayedEntries[index]
            if trimmed == displayed.text {
                values[index] = displayed.value
                continue
            }
            let scanner = Scanner(string: trimmed)
            scanner.locale = formatter.locale
            let physicalRange = domain.physicalRange(for: item)
            guard let parsed = scanner.scanDouble(), scanner.isAtEnd,
                  parsed.isFinite, physicalRange.contains(parsed) else {
                return .failure(ParseError(message: invalidMessage(for: item)))
            }
            values[index] = Self.normalizedValue(forPhysical: parsed, field: item, domain: domain)
        }
        let channel = EngineSession.LevelsSettings.Channel(lowInput: values[0], highInput: values[1],
                                                           gamma: values[2], lowOutput: values[3], highOutput: values[4])
        let settings = NeutralSettings(value: channel,
                                       clampInput: clampInputButton.state == .on,
                                       clampOutput: clampOutputButton.state == .on)
        guard settings.isValid else {
            return .failure(ParseError(message: domain.invalidSettingsMessage))
        }
        return .success(settings)
    }

    private func invalidMessage(for field: Field) -> String {
        if field == .gamma {
            return "Enter gamma from 0.1 to 10."
        }
        return "Enter \(field.title.lowercased()) from \(domain.endpointRangeDescription)."
    }

    private var canApply: Bool {
        guard !finished, !applying, !actionPending, numericValidationError == nil,
              previewCurrent, previewError == nil else { return false }
        if case .success = parseFields() { return true }
        return false
    }

    private func updateState() {
        let editable = !applying && !finished
        for field in fields { field.isEditable = editable; field.isEnabled = editable }
        for button in [clampInputButton, clampOutputButton, resetButton] { button.isEnabled = editable }
        cancelButton.isEnabled = !finished && !cancelInvoked && !applying && !actionPending
        applyButton.isEnabled = canApply

        if let numericValidationError {
            statusField.stringValue = numericValidationError
            statusField.textColor = .systemRed
        } else if let previewError {
            statusField.stringValue = previewError
            statusField.textColor = .systemRed
        } else if applying {
            statusField.stringValue = domain.applyingStatus
            statusField.textColor = .secondaryLabelColor
        } else if !previewCurrent {
            statusField.stringValue = "Updating preview…"
            statusField.textColor = .secondaryLabelColor
        } else {
            statusField.stringValue = ""
            statusField.textColor = .secondaryLabelColor
        }

        window?.standardWindowButton(.closeButton)?.isEnabled = !applying && !finished && !actionPending
        resizeToFitContent()
    }

    private static func values(of channel: EngineSession.LevelsSettings.Channel) -> [Double] {
        [channel.lowInput, channel.highInput, channel.gamma, channel.lowOutput, channel.highOutput]
    }

    private static func makeEntries(for channel: EngineSession.LevelsSettings.Channel, domain: Domain, formatter: NumberFormatter) -> [NumericEntry] {
        values(of: channel).enumerated().map { index, value in
            let field = Field(rawValue: index) ?? .lowInput
            let physical = physicalValue(for: value, field: field, domain: domain)
            return NumericEntry(text: formatter.string(from: NSNumber(value: physical)) ?? "0", value: value)
        }
    }

    private static func physicalValue(for normalized: Double, field: Field, domain: Domain) -> Double {
        if field == .gamma { return normalized }
        if case .ink = domain { return normalized }
        let range = domain.physicalRange(for: field)
        let span = range.upperBound - range.lowerBound
        return range.lowerBound + span * normalized
    }

    private static func normalizedValue(forPhysical physical: Double, field: Field, domain: Domain) -> Double {
        if field == .gamma { return physical }
        if case .ink = domain { return physical }
        let range = domain.physicalRange(for: field)
        let span = range.upperBound - range.lowerBound
        guard span != 0 else { return 0 }
        return (physical - range.lowerBound) / span
    }
}
