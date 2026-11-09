import AppKit

@MainActor
final class CurvesPanel: FilterPreviewPanel, NSTextFieldDelegate {
    typealias Settings = EngineSession.CurvesSettings
    typealias Patch = CurvesDraft.Patch
    let graph = CurvesGraphView()
    let histogramView = InputHistogramView()
    private let histogramLogButton = NSButton(checkboxWithTitle: "Log scale", target: nil, action: nil)
    private var inputHistogram: FilterInputHistogram?
    let channelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let trcPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let pointKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let indexField = NSTextField()
    let inputField = NSTextField()
    let outputField = NSTextField()
    private let countLabel = NSTextField(labelWithString: "")
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let deleteButton = NSButton(title: "Delete point", target: nil, action: nil)
    private let addButton = NSButton(title: "Add point", target: nil, action: nil)
    private let formatter = NumberFormatter()
    private var store: CurvesDraft
    private var channel = EngineSession.CurveChannel.value
    private var index = 0
    private var displayed = ["", "", ""]
    private var invalidFieldDuringCommit = false
    private var latestRequest = 0
    private var localError = false
    private let write: @MainActor (Int32, Patch, @escaping @MainActor (Result<Settings, Error>) -> Void) -> Void
    private(set) var lastError: String?

    init?(document: ImageDocument, filter: Int32, settings: Settings,
          write: (@MainActor (Int32, Patch, @escaping @MainActor (Result<Settings, Error>) -> Void) -> Void)? = nil) {
        guard settings.isValid else { return nil }
        store = CurvesDraft(settings)
        self.write = write ?? { [weak document] filter, patch, reply in
            guard let document else { return reply(.failure(ImageDocument.DocumentError.closed)) }
            document.setCurves(filter, patch: patch, completion: reply)
        }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 530, height: 530),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Curves"
        panel.isFloatingPanel = true
        super.init(document: document, panel: panel, filter: filter)
        inputHistogram = FilterInputHistogram(document: document, filter: filter, view: histogramView,
                                               isActive: { [weak self] in self?.filter == filter })
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.maximumFractionDigits = 8
        buildContent(panel)
        display()
        inputHistogram?.refreshIfNeeded()
        panel.center()
    }
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func showError(_ message: String) {
        guard filter != nil else { return }
        lastError = message.isEmpty ? nil : message
        statusField.stringValue = message
    }
    private var state: EngineSession.CurveState { store.settings[channel] }
    private var fields: [NSTextField] { [indexField, inputField, outputField] }
    private func buildContent(_ panel: NSPanel) {
        channelPopup.addItems(withTitles: EngineSession.CurveChannel.allCases.map(\.title))
        trcPopup.addItems(withTitles: EngineSession.ColorTRC.conversionChoices.map(\.title))
        modePopup.addItems(withTitles: ["Smooth", "Freehand"])
        pointKindPopup.addItems(withTitles: ["Smooth point", "Corner point"])
        for (control, label, selector) in [
            (channelPopup, "Curves channel", #selector(channelChanged(_:))),
            (trcPopup, "Curves transfer curve", #selector(trcChanged(_:))),
            (modePopup, "Curve mode", #selector(modeChanged(_:))),
            (pointKindPopup, "Control point type", #selector(pointTypeChanged(_:)))
        ] {
            control.target = self; control.action = selector; control.setAccessibilityLabel(label)
        }
        let top = NSStackView(views: [NSTextField(labelWithString: "Channel:"), channelPopup,
                                     NSTextField(labelWithString: "Curve:"), trcPopup])
        top.spacing = 8
        histogramLogButton.target = self
        histogramLogButton.action = #selector(histogramScaleChanged(_:))
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshHistogram(_:)))
        let histogramOptions = NSStackView(views: [NSTextField(labelWithString: "Input histogram"), histogramLogButton, refresh])
        histogramOptions.spacing = 8
        histogramView.translatesAutoresizingMaskIntoConstraints = false
        histogramView.widthAnchor.constraint(equalToConstant: 480).isActive = true
        histogramView.heightAnchor.constraint(equalToConstant: 110).isActive = true
        histogramView.toolTip = "Before filters; weighted by the selection and source transparency."
        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.widthAnchor.constraint(equalToConstant: 480).isActive = true
        graph.heightAnchor.constraint(equalToConstant: 250).isActive = true
        graph.onBeginEdit = { [weak self] in self?.endFields() ?? false }
        graph.onSelectionChanged = { [weak self] selected in
            guard let self else { return }
            self.index = selected ?? 0
            self.displayFields()
        }
        graph.onEndInteraction = { [weak self] selected in
            guard let self, self.filter != nil else { return }
            if let selected { self.index = selected }
            self.displayPreservingDrafts()
        }
        graph.onStateEdit = { [weak self] kind, points, samples in
            guard let self, self.filter != nil else { return }
            let edit: EngineSession.CurveEdit = kind == .smooth
                ? .smooth(channel: self.channel, points: points)
                : .free(channel: self.channel, samples: samples)
            self.submit(.curve(edit))
        }
        for (field, label) in zip(fields, ["Point or sample index", "Curve input", "Curve output"]) {
            field.widthAnchor.constraint(equalToConstant: 90).isActive = true
            field.target = self; field.action = #selector(fieldsChanged(_:)); field.delegate = self
            field.setAccessibilityLabel(label)
        }
        let numeric = NSStackView(views: [NSTextField(labelWithString: "Index:"), indexField,
            NSTextField(labelWithString: "Input:"), inputField, NSTextField(labelWithString: "Output:"), outputField])
        numeric.spacing = 6
        addButton.target = self; addButton.action = #selector(addPoint(_:))
        deleteButton.target = self; deleteButton.action = #selector(deletePoint(_:))
        let reset = NSButton(title: "Reset channel", target: self, action: #selector(resetChannel(_:)))
        let tools = NSStackView(views: [modePopup, pointKindPopup, addButton, deleteButton, reset])
        tools.spacing = 8
        let help = NSTextField(wrappingLabelWithString:
            "Click to add or select a point; drag to shape the curve. Arrow keys move a selected point; Delete removes it. Freehand also supports individual sample edits. Switching to Smooth creates nine points from the current samples.")
        help.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        help.textColor = .secondaryLabelColor
        help.widthAnchor.constraint(equalToConstant: 480).isActive = true
        statusField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusField.textColor = .systemRed
        statusField.heightAnchor.constraint(equalToConstant: 36).isActive = true
        statusField.widthAnchor.constraint(equalToConstant: 480).isActive = true
        statusField.setAccessibilityLabel("Filter status")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Apply", target: self, action: #selector(commit))
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [countLabel, NSView(), cancel, apply])
        buttons.spacing = 8
        let stack = NSStackView(views: [top, histogramOptions, histogramView, graph, numeric, tools, help, statusField, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView(); panel.contentView = content; content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            buttons.widthAnchor.constraint(equalTo: graph.widthAnchor)
        ])
        panel.setContentSize(stack.fittingSize)
    }
    private func display() {
        channelPopup.selectItem(at: Int(channel.rawValue) - 1)
        trcPopup.selectItem(at: EngineSession.ColorTRC.conversionChoices.firstIndex(of: store.settings.trc) ?? 0)
        modePopup.selectItem(at: state.kind == .smooth ? 0 : 1)
        // Mode conversion samples the last accepted native table.
        modePopup.isEnabled = store.pending.isEmpty
        if !graph.isInteracting { graph.state = state }
        let channels: [EngineSession.HistogramChannel] = [.value, .red, .green, .blue, .alpha]
        inputHistogram?.show(channel: channels[Int(channel.rawValue) - 1], trc: store.settings.trc)
        displayFields()
    }
    private func displayFields() {
        let shown = graph.isInteracting ? graph.state : state
        if graph.isInteracting, let selected = graph.selectedPoint { index = selected }
        let smooth = shown.kind == .smooth
        let count = smooth ? shown.points.count : shown.samples.count
        index = min(max(index, 0), max(count - 1, 0))
        graph.selectedPoint = smooth && count > 0 ? index : nil
        indexField.stringValue = String(index)
        inputField.isEditable = smooth && count > 0
        outputField.isEnabled = count > 0
        indexField.isEnabled = count > 0
        let x = count == 0 ? 0 : (smooth ? shown.points[index].x : Double(index) / 255)
        let y = count == 0 ? 0 : (smooth ? shown.points[index].y : shown.samples[index])
        inputField.stringValue = formatter.string(from: NSNumber(value: x)) ?? "0"
        outputField.stringValue = formatter.string(from: NSNumber(value: y)) ?? "0"
        displayed = fields.map(\.stringValue)
        pointKindPopup.isEnabled = smooth && count > 0
        pointKindPopup.selectItem(at: smooth && count > 0 && shown.points[index].kind == .corner ? 1 : 0)
        addButton.isEnabled = smooth && shown.points.count < 65_536
        deleteButton.isEnabled = smooth && count > 0
        countLabel.stringValue = "\(count) \(smooth ? "points" : "samples")"
    }
    private func displayPreservingDrafts() {
        FilterFieldDrafts.preserve(Array(zip(fields, displayed))) { display() }
    }
    private func number(_ field: NSTextField) -> Double? {
        let scanner = Scanner(string: (field.currentEditor()?.string ?? field.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines))
        scanner.locale = Locale.current
        guard let number = scanner.scanDouble(), scanner.isAtEnd, number.isFinite else { return nil }
        return number
    }
    @discardableResult
    private func commitFields() -> Bool {
        guard filter != nil else { return false }
        if zip(fields, displayed).allSatisfy({ ($0.0.currentEditor()?.string ?? $0.0.stringValue) == $0.1 }) { return true }
        let count = state.kind == .smooth ? state.points.count : state.samples.count
        guard count > 0, let indexValue = number(indexField), indexValue.rounded() == indexValue,
              indexValue >= 0, indexValue < Double(count), let y = number(outputField), (0...1).contains(y) else {
            return rejectInput()
        }
        let selected = Int(indexValue)
        // Selecting an index changes only the view. Commit edits to the old
        // selection first when its values were also changed.
        let valuesChanged = [inputField, outputField].enumerated().contains {
            ($0.element.currentEditor()?.string ?? $0.element.stringValue) != displayed[$0.offset + 1]
        }
        if valuesChanged {
            if state.kind == .smooth {
                guard let x = number(inputField), (0...1).contains(x) else { return rejectInput() }
                var points = state.points; points[index].x = x; points[index].y = y
                guard EngineSession.CurveState.validPoints(points) else { return rejectInput() }
                submit(.curve(.smooth(channel: channel, points: points)))
            } else {
                var samples = state.samples; samples[index] = y
                submit(.curve(.free(channel: channel, samples: samples)))
            }
        }
        index = selected
        displayFields()
        return true
    }
    private func rejectInput() -> Bool {
        invalidFieldDuringCommit = true; localError = true
        showError("Enter an existing whole index and input/output values from 0 to 1. Inputs must stay ordered.")
        return false
    }
    @objc func fieldsChanged(_ sender: Any?) { _ = commitFields() }
    func controlTextDidEndEditing(_ notification: Notification) { _ = commitFields() }
    private func endFields() -> Bool {
        invalidFieldDuringCommit = false
        window?.endEditing(for: nil)
        return !invalidFieldDuringCommit && commitFields()
    }
    @objc func channelChanged(_ sender: NSPopUpButton) {
        let selected = sender.indexOfSelectedItem
        guard endFields(), let next = EngineSession.CurveChannel(rawValue: UInt32(max(selected, 0) + 1)) else {
            sender.selectItem(at: Int(channel.rawValue) - 1); return
        }
        channel = next; index = 0; localError = false; showError(""); display()
    }
    @objc func trcChanged(_ sender: NSPopUpButton) {
        let selected = sender.indexOfSelectedItem
        guard endFields(), EngineSession.ColorTRC.conversionChoices.indices.contains(selected) else {
            displayPreservingDrafts(); return
        }
        let trc = EngineSession.ColorTRC.conversionChoices[selected]
        if trc != store.settings.trc { submit(.trc(trc)) }
    }
    @objc func modeChanged(_ sender: NSPopUpButton) {
        let selected = sender.indexOfSelectedItem
        guard endFields() else { displayPreservingDrafts(); return }
        // Ending a numeric edit can enqueue a Smooth patch. Its old sample
        // table cannot be used for conversion before Core returns the result.
        guard store.pending.isEmpty else { displayPreservingDrafts(); return }
        if selected == 1 && state.kind != .free {
            submit(.curve(.free(channel: channel, samples: state.samples)))
        } else if selected == 0 && state.kind != .smooth {
            let points = (0..<9).map { i -> EngineSession.CurvePoint in
                let sample = i * 255 / 8
                return .init(x: Double(sample) / 255, y: state.samples[sample])
            }
            submit(.curve(.smooth(channel: channel, points: points)))
        }
    }
    @objc func pointTypeChanged(_ sender: NSPopUpButton) {
        let selected = sender.indexOfSelectedItem
        guard endFields(), state.kind == .smooth, state.points.indices.contains(index) else { return }
        var points = state.points; points[index].kind = selected == 0 ? .smooth : .corner
        submit(.curve(.smooth(channel: channel, points: points)))
    }
    @objc func addPoint(_ sender: Any?) {
        guard endFields(), state.kind == .smooth, state.points.count < 65_536 else { return }
        var points = state.points
        let next = points.firstIndex { $0.x > 0.5 } ?? points.count
        points.insert(.init(x: 0.5, y: 0.5), at: next); index = next
        submit(.curve(.smooth(channel: channel, points: points)))
    }
    @objc func deletePoint(_ sender: Any?) {
        guard endFields(), state.kind == .smooth, state.points.indices.contains(index) else { return }
        var points = state.points; points.remove(at: index)
        submit(.curve(.smooth(channel: channel, points: points)))
    }
    @objc func resetChannel(_ sender: Any?) {
        guard endFields() else { return }
        index = 0; submit(.curve(.reset(channel: channel)))
    }
    private func submit(_ patch: Patch) {
        guard let filter else { return }
        if case .curve(let edit) = patch, !edit.isValid { _ = rejectInput(); return }
        localError = false
        let request = store.submit(patch); latestRequest = request
        showError(""); display()
        write(filter, patch) { [weak self] result in
            guard let self, self.filter == filter else { return }
            self.store.receive(request, result: result)
            self.displayPreservingDrafts()
            if self.store.pending.isEmpty { self.inputHistogram?.refreshIfNeeded() }
            if request == self.latestRequest && !self.localError {
                switch result {
                case .success: self.showError("")
                case .failure(let error): self.showError(error.localizedDescription)
                }
            }
        }
    }
    @objc func refreshHistogram(_ sender: Any?) { inputHistogram?.refresh() }
    @objc func histogramScaleChanged(_ sender: NSButton) { histogramView.logarithmic = sender.state == .on }
    @objc override func commit() {
        guard endFields() else { return }
        super.commit()
    }
}
