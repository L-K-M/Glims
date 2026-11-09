import AppKit

/// A color balance draft over all three tonal ranges for one captured preview.
///
/// The popup only chooses which range the fields and sliders display. The
/// draft itself always holds every range and the preserve flag, so every
/// write is the complete settings and a range change alone never writes.
@MainActor
final class ColorBalancePanel: FilterPreviewPanel, NSTextFieldDelegate {
    typealias Settings = EngineSession.ColorBalanceSettings

    let cyanRedField = NSTextField()
    let magentaGreenField = NSTextField()
    let yellowBlueField = NSTextField()
    let cyanRedSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    let magentaGreenSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    let yellowBlueSlider = NSSlider(value: 0, minValue: -100, maxValue: 100, target: nil, action: nil)
    let rangePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let preserveCheckbox = NSButton(checkboxWithTitle: "Preserve Lightness", target: nil, action: nil)
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let formatter = NumberFormatter()
    private var draft: Settings
    private var accepted: Settings
    private var selectedRange = RangeOption.midtones
    private var generation = 0
    private var acceptedGeneration = 0
    private var pending: [Int: Settings] = [:]
    private var draftGeneration = 0
    private var latestReply: (generation: Int, result: Result<Void, Error>)?
    private var invalidFieldDuringCommit = false
    private var displayedCyanRed = ""
    private var displayedMagentaGreen = ""
    private var displayedYellowBlue = ""
    private let writeSettings: @MainActor (Int32, Settings, @escaping @MainActor (Result<Void, Error>) -> Void) -> Void
    private(set) var lastError: String?

    private enum RangeOption: Int, CaseIterable {
        case shadows = 0, midtones, highlights

        var title: String {
            switch self {
            case .shadows: return "Shadows"
            case .midtones: return "Midtones"
            case .highlights: return "Highlights"
            }
        }
    }

    private struct InputError: LocalizedError {
        var errorDescription: String? { "Enter a percentage from −100 to 100." }
    }

    init?(document: ImageDocument, filter: Int32, settings: Settings,
          write: (@MainActor (Int32, Settings, @escaping @MainActor (Result<Void, Error>) -> Void) -> Void)? = nil) {
        guard settings.isValid else { return nil }
        draft = settings
        accepted = settings
        writeSettings = write ?? { [weak document] filter, value, reply in
            guard let document else { return reply(.failure(ImageDocument.DocumentError.closed)) }
            document.setColorBalance(filter, value, completion: reply)
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 244),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Color Balance"
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
        let pairs = [("Cyan ↔ Red", "Cyan red", cyanRedField, cyanRedSlider),
                     ("Magenta ↔ Green", "Magenta green", magentaGreenField, magentaGreenSlider),
                     ("Yellow ↔ Blue", "Yellow blue", yellowBlueField, yellowBlueSlider)]
        var rows: [[NSView]] = []
        for (name, axName, field, slider) in pairs {
            field.setAccessibilityLabel("\(axName) percent")
            field.widthAnchor.constraint(equalToConstant: 78).isActive = true
            field.target = self
            field.action = #selector(fieldsChanged(_:))
            field.delegate = self
            slider.setAccessibilityLabel(axName)
            slider.isContinuous = true
            slider.target = self
            slider.action = #selector(sliderChanged(_:))
            slider.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let number = NSStackView(views: [field, NSTextField(labelWithString: "%")])
            number.spacing = 4
            rows.append([NSTextField(labelWithString: name), slider, number])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 12
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing

        rangePopup.removeAllItems()
        rangePopup.addItems(withTitles: RangeOption.allCases.map(\.title))
        rangePopup.selectItem(at: RangeOption.midtones.rawValue)
        rangePopup.setAccessibilityLabel("Tonal range")
        rangePopup.target = self
        rangePopup.action = #selector(rangeChanged(_:))
        preserveCheckbox.setAccessibilityLabel("Preserve lightness")
        preserveCheckbox.target = self
        preserveCheckbox.action = #selector(preserveChanged(_:))
        let options = NSStackView(views: [NSTextField(labelWithString: "Range:"), rangePopup,
                                          NSView(), preserveCheckbox])
        options.spacing = 8

        statusField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.textColor = .systemRed
        statusField.maximumNumberOfLines = 2
        statusField.lineBreakMode = .byTruncatingTail
        statusField.setAccessibilityLabel("Filter status")
        statusField.heightAnchor.constraint(equalToConstant: 34).isActive = true

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel color balance")
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(commit))
        applyButton.keyEquivalent = "\r"
        applyButton.setAccessibilityLabel("Apply color balance")
        let buttons = NSStackView(views: [NSView(), cancelButton, applyButton])
        buttons.spacing = 8

        let stack = NSStackView(views: [grid, options, statusField, buttons])
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
        case .shadows: return value.shadows
        case .midtones: return value.midtones
        case .highlights: return value.highlights
        }
    }

    private func replacingShownRange(of value: Settings, with range: Settings.Range) -> Settings {
        var value = value
        switch selectedRange {
        case .shadows: value.shadows = range
        case .midtones: value.midtones = range
        case .highlights: value.highlights = range
        }
        return value
    }

    private func display(_ value: Settings) {
        let range = shownRange(in: value)
        cyanRedSlider.doubleValue = range.cyanRed * 100
        magentaGreenSlider.doubleValue = range.magentaGreen * 100
        yellowBlueSlider.doubleValue = range.yellowBlue * 100
        cyanRedField.stringValue = formatter.string(from: NSNumber(value: range.cyanRed * 100)) ?? "0"
        magentaGreenField.stringValue = formatter.string(from: NSNumber(value: range.magentaGreen * 100)) ?? "0"
        yellowBlueField.stringValue = formatter.string(from: NSNumber(value: range.yellowBlue * 100)) ?? "0"
        displayedCyanRed = cyanRedField.stringValue
        displayedMagentaGreen = magentaGreenField.stringValue
        displayedYellowBlue = yellowBlueField.stringValue
        preserveCheckbox.state = value.preserveLuminosity ? .on : .off
        rangePopup.selectItem(at: selectedRange.rawValue)
    }

    private func percentage(in field: NSTextField) -> Double? {
        // Display rounding must not turn Apply on an untouched seed into a
        // parameter edit, or alter the other ranges of a full-settings write.
        let shown = shownRange(in: draft)
        if field === cyanRedField, field.stringValue == displayedCyanRed { return shown.cyanRed }
        if field === magentaGreenField, field.stringValue == displayedMagentaGreen { return shown.magentaGreen }
        if field === yellowBlueField, field.stringValue == displayedYellowBlue { return shown.yellowBlue }
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let scanner = Scanner(string: text)
        scanner.locale = Locale.current
        guard let value = scanner.scanDouble(), scanner.isAtEnd,
              value.isFinite, (-100...100).contains(value) else { return nil }
        return value / 100
    }

    @objc func sliderChanged(_ sender: NSSlider) {
        guard filter != nil else { return }
        var range = shownRange(in: draft)
        if sender === cyanRedSlider { range.cyanRed = sender.doubleValue / 100 }
        else if sender === magentaGreenSlider { range.magentaGreen = sender.doubleValue / 100 }
        else if sender === yellowBlueSlider { range.yellowBlue = sender.doubleValue / 100 }
        else { return }
        let value = replacingShownRange(of: draft, with: range)
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

    @objc func preserveChanged(_ sender: NSButton) {
        guard filter != nil else { return }
        let requested = sender.state == .on
        invalidFieldDuringCommit = false
        window?.endEditing(for: nil)
        guard !invalidFieldDuringCommit, commitFields() else {
            sender.state = requested ? .off : .on
            return
        }
        var value = draft
        value.preserveLuminosity = requested
        submit(value)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        _ = commitFields()
    }

    @discardableResult
    private func commitFields() -> Bool {
        guard filter != nil else { return false }
        guard let cyanRed = percentage(in: cyanRedField),
              let magentaGreen = percentage(in: magentaGreenField),
              let yellowBlue = percentage(in: yellowBlueField) else {
            rejectLocalInput()
            return false
        }
        submit(replacingShownRange(of: draft,
                                   with: .init(cyanRed: cyanRed, magentaGreen: magentaGreen,
                                               yellowBlue: yellowBlue)))
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
                let fields = [self.cyanRedField, self.magentaGreenField, self.yellowBlueField]
                let invalidText = fields.compactMap { field -> (NSTextField, String)? in
                    self.percentage(in: field) == nil ? (field, field.stringValue) : nil
                }
                if let previous = self.pending.keys.filter({ $0 > self.acceptedGeneration }).max(),
                   let value = self.pending[previous] {
                    self.draft = value
                    self.draftGeneration = previous
                } else {
                    self.draft = self.accepted
                    self.draftGeneration = self.acceptedGeneration
                }
                self.display(self.draft)
                for (field, text) in invalidText { field.stringValue = text }
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
                display(accepted)
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
