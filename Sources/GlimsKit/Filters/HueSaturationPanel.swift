import AppKit

/// A complete Hue/Saturation draft for one captured preview.
///
/// The popup only chooses which range the fields and sliders display. The
/// draft itself always holds all seven ranges and overlap, so every
/// write is the complete settings and a range change alone never writes.
@MainActor
final class HueSaturationPanel: FilterPreviewPanel, NSTextFieldDelegate {
    typealias Settings = EngineSession.HueSaturationSettings

    let hueField = NSTextField()
    let saturationField = NSTextField()
    let lightnessField = NSTextField()
    let hueSlider = NSSlider(value: 0, minValue: -180, maxValue: 180, target: nil, action: nil)
    let saturationSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    let lightnessSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    let rangePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let overlapField = NSTextField()
    let overlapSlider = NSSlider(value: 0, minValue: 0, maxValue: 100, target: nil, action: nil)
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let formatter = NumberFormatter()
    private var draft: Settings
    private var accepted: Settings
    private var selectedRange = RangeOption.master
    private var generation = 0
    private var acceptedGeneration = 0
    private var pending: [Int: Settings] = [:]
    private var draftGeneration = 0
    private var latestReply: (generation: Int, result: Result<Void, Error>)?
    private var invalidFieldDuringCommit = false
    private var displayedHue = ""
    private var displayedSaturation = ""
    private var displayedLightness = ""
    private var displayedOverlap = ""
    private let writeSettings: @MainActor (Int32, Settings, @escaping @MainActor (Result<Void, Error>) -> Void) -> Void
    private(set) var lastError: String?

    private enum RangeOption: Int, CaseIterable {
        case master = 0, red, yellow, green, cyan, blue, magenta

        var title: String {
            switch self {
            case .master: return "Master"
            case .red: return "Red"
            case .yellow: return "Yellow"
            case .green: return "Green"
            case .cyan: return "Cyan"
            case .blue: return "Blue"
            case .magenta: return "Magenta"
            }
        }
    }

    private struct InputError: LocalizedError {
        var errorDescription: String? {
            "Enter hue from −180 to 180 degrees, saturation and lightness from −100 to 100%, and overlap from 0 to 100%."
        }
    }

    init?(document: ImageDocument, filter: Int32, settings: Settings,
          write: (@MainActor (Int32, Settings, @escaping @MainActor (Result<Void, Error>) -> Void) -> Void)? = nil) {
        guard settings.isValid else { return nil }
        draft = settings
        accepted = settings
        writeSettings = write ?? { [weak document] filter, value, reply in
            guard let document else { return reply(.failure(ImageDocument.DocumentError.closed)) }
            document.setHueSaturation(filter, value, completion: reply)
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 280),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Hue/Saturation"
        panel.isFloatingPanel = true
        super.init(document: document, panel: panel, filter: filter)
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 4
        buildContent(in: panel)
        display(settings)
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
        let pairs = [("Hue", "Hue degrees", "°", hueField, hueSlider),
                     ("Saturation", "Saturation percent", "%", saturationField, saturationSlider),
                     ("Lightness", "Lightness percent", "%", lightnessField, lightnessSlider),
                     ("Overlap", "Overlap percent", "%", overlapField, overlapSlider)]
        var rows: [[NSView]] = []
        for (name, axName, unit, field, slider) in pairs {
            field.setAccessibilityLabel(axName)
            field.widthAnchor.constraint(equalToConstant: 78).isActive = true
            field.target = self
            field.action = #selector(fieldsChanged(_:))
            field.delegate = self
            slider.setAccessibilityLabel(axName)
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let number = NSStackView(views: [field, NSTextField(labelWithString: unit)])
            number.spacing = 4
            rows.append([NSTextField(labelWithString: name), slider, number])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        rangePopup.removeAllItems()
        rangePopup.addItems(withTitles: RangeOption.allCases.map(\.title))
        rangePopup.selectItem(at: RangeOption.master.rawValue)
        rangePopup.setAccessibilityLabel("Color range")
        rangePopup.target = self
        rangePopup.action = #selector(rangeChanged(_:))
        let options = NSStackView(views: [NSTextField(labelWithString: "Range:"), rangePopup])
        options.spacing = 8

        statusField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.textColor = .systemRed
        statusField.maximumNumberOfLines = 2
        statusField.lineBreakMode = .byTruncatingTail
        statusField.setAccessibilityLabel("Filter status")
        statusField.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel hue saturation")
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(commit))
        applyButton.keyEquivalent = "\r"
        applyButton.setAccessibilityLabel("Apply hue saturation")
        let buttons = NSStackView(views: [NSView(), cancelButton, applyButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [options, grid, statusField, buttons])
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
            options.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            statusField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        ])
        panel.setContentSize(NSSize(width: max(460, grid.fittingSize.width + 32),
                                    height: stack.fittingSize.height))
    }

    private func shownRange(in value: Settings) -> Settings.Range {
        switch selectedRange {
        case .master: return value.master
        case .red: return value.red
        case .yellow: return value.yellow
        case .green: return value.green
        case .cyan: return value.cyan
        case .blue: return value.blue
        case .magenta: return value.magenta
        }
    }

    private func replacingShownRange(of value: Settings, with range: Settings.Range) -> Settings {
        var value = value
        switch selectedRange {
        case .master: value.master = range
        case .red: value.red = range
        case .yellow: value.yellow = range
        case .green: value.green = range
        case .cyan: value.cyan = range
        case .blue: value.blue = range
        case .magenta: value.magenta = range
        }
        return value
    }

    private func display(_ value: Settings) {
        let range = shownRange(in: value)
        hueSlider.doubleValue = range.hue * 180
        saturationSlider.doubleValue = range.saturation * 100
        lightnessSlider.doubleValue = range.lightness * 100
        hueField.stringValue = formatter.string(from: NSNumber(value: range.hue * 180)) ?? "0"
        saturationField.stringValue = formatter.string(from: NSNumber(value: range.saturation * 100)) ?? "0"
        lightnessField.stringValue = formatter.string(from: NSNumber(value: range.lightness * 100)) ?? "0"
        displayedHue = hueField.stringValue
        displayedSaturation = saturationField.stringValue
        displayedLightness = lightnessField.stringValue
        overlapSlider.doubleValue = value.overlap * 100
        overlapField.stringValue = formatter.string(from: NSNumber(value: value.overlap * 100)) ?? "0"
        displayedOverlap = overlapField.stringValue
        rangePopup.selectItem(at: selectedRange.rawValue)
    }

    private func displayPreservingFieldDrafts(_ value: Settings) {
        FilterFieldDrafts.preserve([(hueField, displayedHue), (saturationField, displayedSaturation), (lightnessField, displayedLightness), (overlapField, displayedOverlap)]) {
            display(value)
        }
    }

    private func normalizedValue(in field: NSTextField) -> Double? {
        // Display rounding must not turn Apply on an untouched seed into a
        // parameter edit, or alter the other ranges of a full-settings write.
        let shown = shownRange(in: draft)
        if field === hueField, field.stringValue == displayedHue { return shown.hue }
        if field === saturationField, field.stringValue == displayedSaturation { return shown.saturation }
        if field === lightnessField, field.stringValue == displayedLightness { return shown.lightness }
        if field === overlapField, field.stringValue == displayedOverlap { return draft.overlap }
        let divisor = field === hueField ? 180.0 : 100.0
        let lower = field === overlapField ? 0.0 : -divisor
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanner = Scanner(string: text)
        scanner.locale = Locale.current
        guard let value = scanner.scanDouble(), scanner.isAtEnd,
              value.isFinite, (lower...divisor).contains(value) else { return nil }
        return value / divisor
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        guard filter != nil else { return }
        var value = draft
        var range = shownRange(in: value)
        if sender === hueSlider { range.hue = sender.doubleValue / 180 }
        else if sender === saturationSlider { range.saturation = sender.doubleValue / 100 }
        else if sender === lightnessSlider { range.lightness = sender.doubleValue / 100 }
        else if sender === overlapSlider { value.overlap = sender.doubleValue / 100 }
        else { return }
        value = replacingShownRange(of: value, with: range)
        guard value.isValid else { rejectLocalInput(); return }
        display(value)
        submit(value)
    }

    @objc func fieldsChanged(_ sender: Any?) {
        _ = commitFields()
    }

    @objc func rangeChanged(_ sender: NSPopUpButton) {
        guard filter != nil else { return }
        let requested = sender.indexOfSelectedItem
        guard let option = RangeOption(rawValue: requested), option != selectedRange else { return }
        // Commit the old range's text before the fields switch meaning.
        invalidFieldDuringCommit = false
        window?.endEditing(for: nil)
        guard !invalidFieldDuringCommit, commitFields() else {
            // Keep the typed text and the previous range; only the popup
            // selection goes back, and nothing is written.
            sender.selectItem(at: selectedRange.rawValue)
            return
        }
        selectedRange = option
        display(draft)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        _ = commitFields()
    }

    @discardableResult
    private func commitFields() -> Bool {
        guard filter != nil else { return false }
        guard let hue = normalizedValue(in: hueField),
              let saturation = normalizedValue(in: saturationField),
              let lightness = normalizedValue(in: lightnessField),
              let overlap = normalizedValue(in: overlapField) else {
            rejectLocalInput()
            return false
        }
        var value = replacingShownRange(of: draft,
                                        with: .init(hue: hue, saturation: saturation,
                                                    lightness: lightness))
        value.overlap = overlap
        submit(value)
        return true
    }

    /// A local refusal is view-level: it keeps the typed text and the draft,
    /// so no later acknowledgement can overwrite what the user is editing.
    private func rejectLocalInput() {
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
            // An older accepted write stays the engine's state when a newer
            // write fails. Record it before filtering replies for display.
            if case .success = result, request > self.acceptedGeneration {
                self.accepted = value
                self.acceptedGeneration = request
            }
            if case .failure = result, self.draftGeneration == request {
                // A rejected full-value write must stop being the base for the
                // next range edit immediately, even while an older write waits.
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
        // A refusal can land while older accepted writes are still queued;
        // wait for every earlier acknowledgement before choosing a rollback.
        guard !pending.keys.contains(where: { $0 < reply.generation }) else { return }
        latestReply = nil
        switch reply.result {
        case .success:
            showError("")
        case .failure(let error):
            if error is InputError {
                showError(error.localizedDescription)
            } else {
                draft = accepted
                draftGeneration = acceptedGeneration
                displayPreservingFieldDrafts(accepted)
                showError(error.localizedDescription)
            }
        }
    }

    /// Field focus loss queues the final complete settings on the counted
    /// queue before the shared finish; an invalid form blocks Apply and the
    /// base keeps a second Apply from racing the commit.
    @objc override func commit() {
        guard filter != nil else { return }
        invalidFieldDuringCommit = false
        window?.endEditing(for: nil)
        guard !invalidFieldDuringCommit, commitFields() else { return }
        super.commit()
    }
}
