import AppKit

/// A complete five-channel Levels draft for one captured native preview.
/// Switching channels changes the view; each write retains all 25 numbers,
/// both clamps and the transfer curve.
@MainActor
final class LevelsPanel: FilterPreviewPanel, NSTextFieldDelegate {
    typealias Settings = EngineSession.LevelsSettings
    let channelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let trcPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let clampInputButton = NSButton(checkboxWithTitle: "Clamp input", target: nil, action: nil)
    let clampOutputButton = NSButton(checkboxWithTitle: "Clamp output", target: nil, action: nil)
    let lowInputField = NSTextField()
    let highInputField = NSTextField()
    let gammaField = NSTextField()
    let lowOutputField = NSTextField()
    let highOutputField = NSTextField()
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let formatter = NumberFormatter()
    private var draft: Settings
    private var accepted: Settings
    private var selectedChannel = ChannelOption.value
    private var generation = 0
    private var acceptedGeneration = 0
    private var pending: [Int: Settings] = [:]
    private var draftGeneration = 0
    private var latestReply: (generation: Int, result: Result<Void, Error>)?
    private var invalidFieldDuringCommit = false
    private var displayed: [String] = Array(repeating: "", count: 5)
    private let writeSettings: @MainActor (Int32, Settings, @escaping @MainActor (Result<Void, Error>) -> Void) -> Void
    private(set) var lastError: String?

    private enum ChannelOption: Int, CaseIterable {
        case value, red, green, blue, alpha
        var title: String { ["Value", "Red", "Green", "Blue", "Alpha"][rawValue] }
    }
    private struct InputError: LocalizedError {
        var errorDescription: String? {
            "Enter input and output levels from 0 to 1, and gamma from 0.1 to 10. Equal or reversed endpoints are allowed."
        }
    }
    private var fields: [NSTextField] {
        [lowInputField, highInputField, gammaField, lowOutputField, highOutputField]
    }
    init?(document: ImageDocument, filter: Int32, settings: Settings,
          write: (@MainActor (Int32, Settings, @escaping @MainActor (Result<Void, Error>) -> Void) -> Void)? = nil) {
        guard settings.isValid else { return nil }
        draft = settings
        accepted = settings
        writeSettings = write ?? { [weak document] filter, value, reply in
            guard let document else { return reply(.failure(ImageDocument.DocumentError.closed)) }
            document.setLevels(filter, value, completion: reply)
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 470, height: 360),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Levels"
        panel.isFloatingPanel = true
        super.init(document: document, panel: panel, filter: filter)
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 6
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
        channelPopup.addItems(withTitles: ChannelOption.allCases.map(\.title))
        channelPopup.target = self
        channelPopup.action = #selector(channelChanged(_:))
        channelPopup.setAccessibilityLabel("Levels channel")
        trcPopup.addItems(withTitles: EngineSession.ColorTRC.conversionChoices.map(\.title))
        trcPopup.target = self
        trcPopup.action = #selector(optionsChanged(_:))
        trcPopup.setAccessibilityLabel("Levels transfer curve")
        let selectors = NSStackView(views: [NSTextField(labelWithString: "Channel:"), channelPopup,
                                          NSTextField(labelWithString: "Curve:"), trcPopup])
        selectors.spacing = 8
        var rows: [[NSView]] = []
        for (title, field) in zip(["Low input", "High input", "Gamma", "Low output", "High output"], fields) {
            field.setAccessibilityLabel(title)
            field.widthAnchor.constraint(equalToConstant: 160).isActive = true
            field.target = self
            field.action = #selector(fieldsChanged(_:))
            field.delegate = self
            rows.append([NSTextField(labelWithString: title), field])
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        for button in [clampInputButton, clampOutputButton] {
            button.target = self
            button.action = #selector(optionsChanged(_:))
        }
        let clamps = NSStackView(views: [clampInputButton, clampOutputButton])
        clamps.spacing = 16
        statusField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.textColor = .systemRed
        statusField.maximumNumberOfLines = 3
        statusField.heightAnchor.constraint(equalToConstant: 48).isActive = true
        statusField.setAccessibilityLabel("Filter status")
        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.keyEquivalent = "\u{1b}"
        let applyButton = NSButton(title: "Apply", target: self, action: #selector(commit))
        applyButton.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancelButton, applyButton])
        buttons.spacing = 8
        let stack = NSStackView(views: [selectors, grid, clamps, statusField, buttons])
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
        panel.setContentSize(NSSize(width: max(470, stack.fittingSize.width), height: stack.fittingSize.height))
    }
    private func shownChannel(in value: Settings) -> Settings.Channel {
        switch selectedChannel {
        case .value: return value.value
        case .red: return value.red
        case .green: return value.green
        case .blue: return value.blue
        case .alpha: return value.alpha
        }
    }
    private func replacingShownChannel(of value: Settings, with channel: Settings.Channel) -> Settings {
        var value = value
        switch selectedChannel {
        case .value: value.value = channel
        case .red: value.red = channel
        case .green: value.green = channel
        case .blue: value.blue = channel
        case .alpha: value.alpha = channel
        }
        return value
    }
    private func numbers(_ channel: Settings.Channel) -> [Double] {
        [channel.lowInput, channel.highInput, channel.gamma, channel.lowOutput, channel.highOutput]
    }
    private func display(_ value: Settings) {
        for (index, number) in numbers(shownChannel(in: value)).enumerated() {
            fields[index].stringValue = formatter.string(from: NSNumber(value: number)) ?? "0"
            displayed[index] = fields[index].stringValue
        }
        channelPopup.selectItem(at: selectedChannel.rawValue)
        trcPopup.selectItem(at: EngineSession.ColorTRC.conversionChoices.firstIndex(of: value.trc) ?? 0)
        clampInputButton.state = value.clampInput ? .on : .off
        clampOutputButton.state = value.clampOutput ? .on : .off
    }
    private func displayPreservingFieldDrafts(_ value: Settings) {
        FilterFieldDrafts.preserve(Array(zip(fields, displayed))) { display(value) }
    }
    private func parsedFields() -> [Double]? {
        let previous = numbers(shownChannel(in: draft))
        var values: [Double] = []
        for (index, field) in fields.enumerated() {
            let text = field.currentEditor()?.string ?? field.stringValue
            if text == displayed[index] { values.append(previous[index]); continue }
            let scanner = Scanner(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
            scanner.locale = Locale.current
            let bounds = index == 2 ? 0.1...10.0 : 0.0...1.0
            guard let value = scanner.scanDouble(), scanner.isAtEnd,
                  value.isFinite, bounds.contains(value) else { return nil }
            values.append(value)
        }
        return values
    }
    @objc func fieldsChanged(_ sender: Any?) { _ = commitFields() }
    func controlTextDidEndEditing(_ notification: Notification) { _ = commitFields() }
    @discardableResult
    private func commitFields() -> Bool {
        guard filter != nil else { return false }
        guard let n = parsedFields() else { rejectLocalInput(); return false }
        let value = replacingShownChannel(of: draft, with: .init(lowInput: n[0], highInput: n[1],
            gamma: n[2], lowOutput: n[3], highOutput: n[4]))
        guard value.isValid else { rejectLocalInput(); return false }
        submit(value)
        return true
    }
    @objc func channelChanged(_ sender: NSPopUpButton) {
        guard filter != nil, let channel = ChannelOption(rawValue: sender.indexOfSelectedItem),
              channel != selectedChannel else { return }
        invalidFieldDuringCommit = false
        window?.endEditing(for: nil)
        guard !invalidFieldDuringCommit, commitFields() else {
            sender.selectItem(at: selectedChannel.rawValue)
            return
        }
        selectedChannel = channel
        display(draft)
    }
    @objc func optionsChanged(_ sender: Any?) {
        guard filter != nil else { return }
        // Capture the requested controls before ending text editing: a
        // synchronous refusal may refresh them while fields are committed.
        let curveIndex = trcPopup.indexOfSelectedItem
        let clampInput = clampInputButton.state == .on
        let clampOutput = clampOutputButton.state == .on
        invalidFieldDuringCommit = false
        window?.endEditing(for: nil)
        guard !invalidFieldDuringCommit, commitFields(),
              EngineSession.ColorTRC.conversionChoices.indices.contains(curveIndex) else {
            displayPreservingFieldDrafts(draft)
            return
        }
        var value = draft
        value.trc = EngineSession.ColorTRC.conversionChoices[curveIndex]
        value.clampInput = clampInput
        value.clampOutput = clampOutput
        submit(value)
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
                // next channel edit immediately, even while an older write waits.
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
