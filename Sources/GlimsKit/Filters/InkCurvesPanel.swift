import AppKit

@MainActor
final class SampledCurvesPanel: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    typealias InkSettings = EngineSession.InkCurvesSettings

    private enum Domain {
        case ink(name: String)
        case lab(axis: EngineSession.LabAxis)

        var title: String {
            switch self {
            case .ink: return "Ink Curves"
            case .lab: return "Lab Curves"
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

        var xRange: (Double, Double) {
            switch self {
            case .ink: return (0, 1)
            case .lab(let axis):
                let r = axis.role.nominalRange
                return (r.lowerBound, r.upperBound)
            }
        }

        var yRange: (Double, Double) { xRange }

        var hint: String {
            switch self {
            case .ink:
                return "Intensity: 0 = full ink; 1 = paper. Index and Output edit freehand sample values."
            case .lab(let axis):
                switch axis.role {
                case .lightness:
                    return "L*: 0 = black, 100 = white. Index and Output edit sample values."
                case .a:
                    return "a*: -128 = green, 127 = red. Index and Output edit sample values."
                case .b:
                    return "b*: -128 = blue, 127 = yellow. Index and Output edit sample values."
                }
            }
        }

        var smoothHint: String {
            switch self {
            case .ink:
                return "Intensity: 0 = full ink; 1 = paper. Click or drag points; arrow keys move them and Delete removes them."
            case .lab(let axis):
                switch axis.role {
                case .lightness:
                    return "L*: 0 = black, 100 = white. Click or drag points; arrow keys move them and Delete removes them."
                case .a:
                    return "a*: -128 = green, 127 = red. Click or drag points; arrow keys move them and Delete removes them."
                case .b:
                    return "b*: -128 = blue, 127 = yellow. Click or drag points; arrow keys move them and Delete removes them."
                }
            }
        }
    }

    private struct NumericEntry: Equatable {
        var text: String
        var value: Int
    }

    private struct DraftString {
        var displayed: String
    }

    private struct ParseError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private enum CurveMode {
        case smooth, freehand
    }

    private struct NeutralSettings: Equatable {
        var samples: [Double]

        static let identitySamples = (0..<256).map { Double($0) / 255 }

        init(samples: [Double] = NeutralSettings.identitySamples) {
            self.samples = samples
        }

        var isValid: Bool {
            samples.count == 256 && samples.allSatisfy { $0.isFinite && (0.0...1.0).contains($0) }
        }

        static func identity() -> NeutralSettings { NeutralSettings(samples: identitySamples) }
    }

    let graph = CurvesGraphView()
    let resetButton = NSButton(title: "Reset", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    let sampleIndexField = NSTextField()
    let outputField = NSTextField()
    let inputField = NSTextField()
    let modePopup = NSPopUpButton()
    let pointTypePopup = NSPopUpButton()

    private let headingField = NSTextField(wrappingLabelWithString: "")
    private let hintField = NSTextField(wrappingLabelWithString: "")
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let indexFormatter = NumberFormatter()
    private let sampleOutputFormatter = NumberFormatter()
    private let pointFormatter = NumberFormatter()
    private let countLabel = NSTextField(labelWithString: "")
    private var contentStack: NSStackView?

    private let domain: Domain
    private let changedNeutral: (NeutralSettings) -> Void
    private let applyNeutral: (NeutralSettings) -> Void
    private let cancelAction: () -> Void

    private var curveState: EngineSession.CurveState
    private var lastValidSettings: NeutralSettings
    private var displayedIndex = NumericEntry(text: "0", value: 0)
    private var selectedIndex = 0
    private var displayedSampleOutputText = "0"
    private var inputDraft = DraftString(displayed: "0")
    private var pointOutputDraft = DraftString(displayed: "0")
    private var numericValidationError: String?
    private var previewCurrent = false
    private var previewError: String?
    private var applying = false
    private var finished = false
    private var actionPending = false
    private var cancelInvoked = false
    private var suppressFieldEvents = false
    private var pendingGestureState: EngineSession.CurveState?
    private var gestureOwnedByGraph = false
    private var pendingGestureError: String?
    private var gestureSelection: Int?

    convenience init(inkName: String,
                     settings: InkSettings = .init(),
                     changed: @escaping (InkSettings) -> Void,
                     apply: @escaping (InkSettings) -> Void,
                     cancel: @escaping () -> Void) {
        self.init(domain: .ink(name: inkName),
                  initial: NeutralSettings(samples: settings.samples),
                  initialValid: settings.isValid,
                  changed: { changed(InkSettings(samples: $0.samples)) },
                  apply: { apply(InkSettings(samples: $0.samples)) },
                  cancel: cancel)
    }

    convenience init(labAxis: EngineSession.LabAxis,
                     settings: EngineSession.LabCurvesSettings = .init(),
                     changed: @escaping (EngineSession.LabCurvesSettings) -> Void,
                     apply: @escaping (EngineSession.LabCurvesSettings) -> Void,
                     cancel: @escaping () -> Void) {
        self.init(domain: .lab(axis: labAxis),
                  initial: NeutralSettings(samples: settings.samples),
                  initialValid: settings.isValid,
                  changed: { changed(EngineSession.LabCurvesSettings(samples: $0.samples)) },
                  apply: { apply(EngineSession.LabCurvesSettings(samples: $0.samples)) },
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
        let initialLast = initialValid ? initial : .identity()
        self.lastValidSettings = initialLast
        self.curveState = EngineSession.CurveState(kind: .free, points: [], samples: initialLast.samples)
        self.numericValidationError = nil

        indexFormatter.locale = .current
        indexFormatter.numberStyle = .decimal
        indexFormatter.usesGroupingSeparator = false
        indexFormatter.minimumFractionDigits = 0
        indexFormatter.maximumFractionDigits = 0

        sampleOutputFormatter.locale = .current
        sampleOutputFormatter.numberStyle = .decimal
        sampleOutputFormatter.usesGroupingSeparator = false
        sampleOutputFormatter.minimumFractionDigits = 0
        sampleOutputFormatter.maximumFractionDigits = 6

        pointFormatter.locale = .current
        pointFormatter.numberStyle = .decimal
        pointFormatter.usesGroupingSeparator = false
        pointFormatter.minimumFractionDigits = 0
        pointFormatter.maximumFractionDigits = 8

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 500),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.title = domain.title

        super.init(window: panel)
        numericValidationError = initialValid ? nil : validationMessageForDomain()
        panel.delegate = self
        buildContent(in: panel)
        displayState()
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

    private func physicalToNormalized(_ value: Double, range: (Double, Double)) -> Double {
        let span = range.1 - range.0
        if span == 0 { return 0 }
        return min(1, max(0, (value - range.0) / span))
    }

    private func normalizedToPhysical(_ value: Double, range: (Double, Double)) -> Double {
        range.0 + (range.1 - range.0) * min(1, max(0, value))
    }

    private func formatPhysical(_ value: Double) -> String {
        pointFormatter.string(from: NSNumber(value: value)) ?? "0"
    }

    private func validationMessageForDomain() -> String {
        switch domain {
        case .ink:
            return "Enter sample index from 0 to 255 and output from 0 to 1."
        case .lab(let axis):
            let r = axis.role.nominalRange
            return "Enter sample index from 0 to 255 and output from \(formatPhysical(r.lowerBound)) to \(formatPhysical(r.upperBound))."
        }
    }

    private func invalidIndexMessage() -> String {
        "Enter sample index from 0 to 255."
    }

    private func invalidOutputMessage() -> String {
        switch domain {
        case .ink:
            return "Enter output from 0 to 1."
        case .lab(let axis):
            let r = axis.role.nominalRange
            return "Enter output from \(formatPhysical(r.lowerBound)) to \(formatPhysical(r.upperBound))."
        }
    }

    private func invalidPointIndexMessage() -> String { "Enter an existing point index." }
    private func invalidPointXMessage() -> String {
        switch domain {
        case .ink:
            return "Enter input X from 0 to 1 between neighboring points."
        case .lab(let axis):
            let r = axis.role.nominalRange
            return "Enter input X from \(formatPhysical(r.lowerBound)) to \(formatPhysical(r.upperBound)) between neighboring points."
        }
    }
    private func invalidPointYMessage() -> String {
        switch domain {
        case .ink:
            return "Enter output Y from 0 to 1."
        case .lab(let axis):
            let r = axis.role.nominalRange
            return "Enter output Y from \(formatPhysical(r.lowerBound)) to \(formatPhysical(r.upperBound))."
        }
    }

    private func buildContent(in panel: NSPanel) {
        headingField.stringValue = domain.heading
        headingField.font = NSFont.systemFont(ofSize: NSFont.labelFontSize)
        headingField.setAccessibilityLabel(domain.headingAccessibilityLabel)
        headingField.lineBreakMode = .byWordWrapping

        hintField.font = NSFont.systemFont(ofSize: max(11, NSFont.smallSystemFontSize))
        hintField.textColor = .secondaryLabelColor
        hintField.setAccessibilityLabel("Hint")
        hintField.lineBreakMode = .byWordWrapping

        statusField.font = NSFont.systemFont(ofSize: max(11, NSFont.smallSystemFontSize))
        statusField.setAccessibilityLabel("Status")
        statusField.lineBreakMode = .byWordWrapping

        modePopup.addItems(withTitles: ["Smooth", "Freehand"])
        modePopup.selectItem(withTitle: "Freehand")
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        modePopup.setAccessibilityLabel("Curve mode")

        pointTypePopup.addItems(withTitles: ["Smooth point", "Corner point"])
        pointTypePopup.target = self
        pointTypePopup.action = #selector(pointTypeChanged(_:))
        pointTypePopup.setAccessibilityLabel("Point type")

        countLabel.font = NSFont.systemFont(ofSize: max(11, NSFont.smallSystemFontSize))
        countLabel.textColor = .secondaryLabelColor

        graph.translatesAutoresizingMaskIntoConstraints = false
        graph.widthAnchor.constraint(equalToConstant: 480).isActive = true
        graph.heightAnchor.constraint(equalToConstant: 250).isActive = true
        graph.setAccessibilityLabel("Curves graph")
        graph.state = curveState

        graph.onBeginEdit = { [weak self] in
            guard let self, !self.finished, !self.applying, !self.actionPending,
                  self.validateNumericFieldsAndPublish() else { return false }
            self.gestureOwnedByGraph = true
            self.pendingGestureState = nil
            self.pendingGestureError = nil
            self.gestureSelection = self.selectedIndex
            self.updateState()
            return true
        }
        graph.onStateEdit = { [weak self] kind, points, samples in
            guard let self, !self.finished, self.gestureOwnedByGraph else { return }
            do {
                self.pendingGestureState = try self.stagedState(kind: kind, points: points, samples: samples)
            } catch {
                self.pendingGestureError = String(describing: error)
            }
        }
        graph.onSelectionChanged = { [weak self] selected in
            guard let self, !self.finished, !self.applying,
                  !self.gestureOwnedByGraph, self.curveState.kind == .smooth else { return }
            self.selectedIndex = selected ?? self.selectedIndex
            self.displayState(preserveInvalidEditors: true)
        }
        graph.onEndInteraction = { [weak self] selected in
            guard let self, !self.finished, !self.graph.isInteracting else { return }
            self.gestureOwnedByGraph = false
            let staged = self.pendingGestureState
            let error = self.pendingGestureError
            self.pendingGestureState = nil
            self.pendingGestureError = nil
            if let error {
                self.selectedIndex = self.gestureSelection ?? self.selectedIndex
                self.displayState()
                self.numericValidationError = error
                self.updateState()
            } else if let staged {
                self.commitGestureState(staged, selectedIndex: selected)
            } else {
                if let selected { self.selectedIndex = selected }
                self.displayState(preserveInvalidEditors: true)
                self.updateState()
            }
            self.gestureSelection = nil
        }

        for field in [sampleIndexField, outputField, inputField] {
            field.delegate = self
            field.target = self
            field.action = #selector(fieldAction(_:))
            field.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        }
        sampleIndexField.setAccessibilityLabel("Point or sample index")
        inputField.setAccessibilityLabel("Curve input")
        outputField.setAccessibilityLabel("Curve output")

        let indexLabel = NSTextField(labelWithString: "Index:")
        let inputLabel = NSTextField(labelWithString: "Input:")
        let outputLabel = NSTextField(labelWithString: "Output:")
        for label in [indexLabel, inputLabel, outputLabel] {
            label.font = NSFont.systemFont(ofSize: NSFont.labelFontSize)
            label.setAccessibilityLabel(label.stringValue)
        }

        let numeric = NSStackView(views: [indexLabel, sampleIndexField, inputLabel, inputField, outputLabel, outputField])
        numeric.orientation = .horizontal
        numeric.alignment = .firstBaseline
        numeric.spacing = 8

        let modeLabel = NSTextField(labelWithString: "Curve mode:")
        let typeLabel = NSTextField(labelWithString: "Point type:")
        let controls = NSStackView(views: [modeLabel, modePopup, typeLabel, pointTypePopup, countLabel])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8

        for button in [resetButton, cancelButton, applyButton] {
            button.font = NSFont.systemFont(ofSize: max(11, NSFont.smallSystemFontSize))
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

        let stack = NSStackView(views: [headingField, hintField, controls, graph, numeric, statusField, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentStack = stack

        for label in [headingField, hintField, statusField] {
            label.preferredMaxLayoutWidth = 528
        }

        let content = NSView()
        panel.contentView = content
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 560),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            headingField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            hintField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            statusField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            statusField.heightAnchor.constraint(equalToConstant: 36),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
        ])

        resizeToFitContent()
    }

    private func resizeToFitContent() {
        guard let stack = contentStack else { return }
        window?.setContentSize(NSSize(width: 560, height: max(420, stack.fittingSize.height)))
    }

    private var curveMode: CurveMode { curveState.kind == .smooth ? .smooth : .freehand }
    private var isInteracting: Bool { graph.isInteracting || gestureOwnedByGraph || pendingGestureState != nil }
    private var hasInvalidDraft: Bool { numericValidationError != nil }

    private func stagedState(kind: EngineSession.CurveKind, points: [EngineSession.CurvePoint], samples: [Double]) throws -> EngineSession.CurveState {
        if kind == .smooth {
            let calculated = try InkCurveSampler.samples(points: points, previousSamples: curveState.samples)
            return EngineSession.CurveState(kind: .smooth, points: points, samples: calculated)
        }
        guard NeutralSettings(samples: samples).isValid else {
            throw ParseError(message: "Enter 256 sample values from 0 to 1.")
        }
        return EngineSession.CurveState(kind: .free, points: [], samples: samples)
    }

    private func displayState(preserveInvalidEditors: Bool = false) {
        modePopup.selectItem(withTitle: curveState.kind == .smooth ? "Smooth" : "Freehand")
        if preserveInvalidEditors && numericValidationError != nil {
            if curveState.points.indices.contains(selectedIndex) {
                pointTypePopup.selectItem(at: curveState.points[selectedIndex].kind == .corner ? 1 : 0)
            }
            return
        }
        if curveMode == .freehand {
            hintField.stringValue = domain.hint
            let index = min(255, max(0, displayedIndex.value))
            selectedIndex = index
            displayedIndex = NumericEntry(text: indexFormatter.string(from: NSNumber(value: index)) ?? "\(index)", value: index)
            if !(preserveInvalidEditors && sampleIndexField.currentEditor() != nil && numericValidationError != nil) {
                sampleIndexField.stringValue = displayedIndex.text
            }
            refreshFreehandOutputField(for: curveState.samples, index: index, preserveInvalidEditor: preserveInvalidEditors)
            let xNorm = Double(index) / 255.0
            inputField.stringValue = formatPhysical(normalizedToPhysical(xNorm, range: domain.xRange))
            inputField.isEditable = false
            inputDraft = DraftString(displayed: inputField.stringValue)
            pointTypePopup.isEnabled = false
            countLabel.stringValue = "256 samples"
        } else {
            hintField.stringValue = domain.smoothHint
            let count = curveState.points.count
            if count == 0 {
                selectedIndex = 0
                sampleIndexField.stringValue = ""
                inputField.stringValue = ""
                outputField.stringValue = ""
                inputDraft = DraftString(displayed: "")
                pointOutputDraft = DraftString(displayed: "")
                pointTypePopup.isEnabled = false
                countLabel.stringValue = "0 points"
            } else {
                selectedIndex = min(max(selectedIndex, 0), count - 1)
                displayedIndex = NumericEntry(text: indexFormatter.string(from: NSNumber(value: selectedIndex)) ?? "\(selectedIndex)", value: selectedIndex)
                if !(preserveInvalidEditors && sampleIndexField.currentEditor() != nil && numericValidationError != nil) {
                    sampleIndexField.stringValue = displayedIndex.text
                }
                let point = curveState.points[selectedIndex]
                if !(preserveInvalidEditors && inputField.currentEditor() != nil && numericValidationError != nil) {
                    let text = formatPhysical(normalizedToPhysical(point.x, range: domain.xRange))
                    inputField.stringValue = text
                    inputDraft = DraftString(displayed: text)
                }
                if !(preserveInvalidEditors && outputField.currentEditor() != nil && numericValidationError != nil) {
                    let text = formatPhysical(normalizedToPhysical(point.y, range: domain.yRange))
                    outputField.stringValue = text
                    pointOutputDraft = DraftString(displayed: text)
                }
                pointTypePopup.selectItem(at: point.kind == .corner ? 1 : 0)
                pointTypePopup.isEnabled = true
                countLabel.stringValue = count == 1 ? "1 point" : "\(count) points"
            }
        }
        if !graph.isInteracting && !gestureOwnedByGraph {
            graph.state = curveState
            graph.defaultPointKind = curveState.kind == .smooth && curveState.points.indices.contains(selectedIndex) ? curveState.points[selectedIndex].kind : .smooth
            graph.selectedPoint = curveState.kind == .smooth && !curveState.points.isEmpty ? selectedIndex : nil
        }
    }

    private func refreshFreehandOutputField(for samples: [Double], index: Int, preserveInvalidEditor: Bool) {
        let safeIndex = min(max(index, 0), max(samples.count - 1, 0))
        let value = samples.indices.contains(safeIndex) ? samples[safeIndex] : 0
        let physical = normalizedToPhysical(value, range: domain.yRange)
        displayedSampleOutputText = sampleOutputFormatter.string(from: NSNumber(value: physical)) ?? "0"
        if !(preserveInvalidEditor && outputField.currentEditor() != nil && numericValidationError != nil) {
            outputField.stringValue = displayedSampleOutputText
        }
    }

    @objc private func fieldAction(_ sender: NSTextField) {
        guard !finished, !applying, !actionPending, !suppressFieldEvents else { return }
        _ = validateNumericFieldsAndPublish()
    }

    @objc private func resetPressed(_ sender: Any?) {
        guard !finished, !applying, !actionPending else { return }
        _ = endEditingIfNeeded(blocking: false)
        actionPending = true
        defer { actionPending = false; updateState() }
        let identity = NeutralSettings.identity()
        numericValidationError = nil
        previewCurrent = false
        previewError = nil
        pendingGestureState = nil
        pendingGestureError = nil
        gestureOwnedByGraph = false
        selectedIndex = 0
        lastValidSettings = identity
        displayedIndex = NumericEntry(text: "0", value: 0)
        displayedSampleOutputText = formatPhysical(normalizedToPhysical(0, range: domain.yRange))
        let defaultX = formatPhysical(normalizedToPhysical(0, range: domain.xRange))
        let defaultY = formatPhysical(normalizedToPhysical(0, range: domain.yRange))
        inputDraft = DraftString(displayed: defaultX)
        pointOutputDraft = DraftString(displayed: defaultY)
        if curveMode == .smooth {
            curveState = EngineSession.CurveState(kind: .smooth,
                                                  points: [.init(x: 0, y: 0), .init(x: 1, y: 1)],
                                                  samples: identity.samples)
        } else {
            curveState = EngineSession.CurveState(kind: .free, points: [], samples: identity.samples)
        }
        displayState()
        updateState()
        changedNeutral(identity)
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        guard !finished, !applying, !actionPending else { return }
        let targetSmooth = sender.indexOfSelectedItem == 0
        if (targetSmooth && curveMode == .smooth) || (!targetSmooth && curveMode == .freehand) { return }
        if !endEditingIfNeeded(blocking: true) { displayState(preserveInvalidEditors: true); updateState(); return }
        if isInteracting { displayState(preserveInvalidEditors: true); updateState(); return }
        let previousSamples = curveState.samples
        if targetSmooth {
            let points = ninePointSamples(from: previousSamples)
            guard let samples = try? InkCurveSampler.samples(points: points, previousSamples: previousSamples) else {
                numericValidationError = "Unable to calculate smooth curve."
                displayState(preserveInvalidEditors: true)
                updateState()
                return
            }
            curveState = EngineSession.CurveState(kind: .smooth, points: points, samples: samples)
            selectedIndex = 0
        } else {
            curveState = EngineSession.CurveState(kind: .free, points: [], samples: previousSamples)
            selectedIndex = min(displayedIndex.value, 255)
        }
        numericValidationError = nil
        pendingGestureState = nil
        pendingGestureError = nil
        gestureOwnedByGraph = false
        let needsPreview = lastValidSettings.samples != curveState.samples
        lastValidSettings = NeutralSettings(samples: curveState.samples)
        displayState()
        updateState()
        publishSettings(lastValidSettings, needsPreview: needsPreview)
    }

    @objc private func pointTypeChanged(_ sender: NSPopUpButton) {
        guard !finished, !applying, !actionPending, curveMode == .smooth else { return }
        let desired: EngineSession.CurvePointKind = sender.indexOfSelectedItem == 1 ? .corner : .smooth
        if !endEditingIfNeeded(blocking: true) { displayState(preserveInvalidEditors: true); updateState(); return }
        guard !isInteracting, curveState.points.indices.contains(selectedIndex) else { return }
        guard curveState.points[selectedIndex].kind != desired else { return }
        var points = curveState.points
        points[selectedIndex].kind = desired
        let previous = curveState.samples
        guard let samples = try? InkCurveSampler.samples(points: points, previousSamples: previous) else {
            numericValidationError = "Unable to calculate smooth curve."
            displayState(preserveInvalidEditors: true)
            updateState()
            return
        }
        curveState = EngineSession.CurveState(kind: .smooth, points: points, samples: samples)
        numericValidationError = nil
        let needsPreview = lastValidSettings.samples != samples
        lastValidSettings = NeutralSettings(samples: samples)
        displayState()
        publishSettings(lastValidSettings, needsPreview: needsPreview)
    }

    @objc private func cancelPressed(_ sender: Any?) { cancel() }
    @objc private func applyPressed(_ sender: Any?) { requestApply() }

    private func requestApply() {
        guard !finished, !applying, !actionPending else { return }
        guard validateNumericFieldsAndPublish() else { return }
        guard !finished, !applying else { return }
        if !endEditingIfNeeded(blocking: true) { return }
        guard validateNumericFieldsAndPublish(), canApply else { return }
        actionPending = true
        applying = true
        defer { actionPending = false; updateState() }
        updateState()
        applyNeutral(lastValidSettings)
    }

    @discardableResult
    private func endEditingIfNeeded(blocking: Bool) -> Bool {
        if blocking && !validateNumericFieldsAndPublish() { return false }
        suppressFieldEvents = true
        window?.endEditing(for: nil)
        suppressFieldEvents = false
        if blocking && numericValidationError != nil { return false }
        return !blocking || numericValidationError == nil
    }

    @discardableResult
    private func validateNumericFieldsAndPublish() -> Bool {
        guard !finished, !applying else { return false }
        if isInteracting {
            updateState()
            return false
        }
        switch parseFields() {
        case .success(let parsed):
            numericValidationError = nil
            displayedIndex = parsed.indexEntry
            selectedIndex = parsed.indexEntry.value
            if let state = parsed.state {
                let needsPreview = NeutralSettings(samples: state.samples) != lastValidSettings
                curveState = state
                lastValidSettings = NeutralSettings(samples: state.samples)
                displayState(preserveInvalidEditors: false)
                if needsPreview {
                    publishSettings(lastValidSettings, needsPreview: true)
                } else {
                    updateState()
                }
            } else {
                displayState(preserveInvalidEditors: false)
                updateState()
            }
            return !finished && !applying && numericValidationError == nil
        case .failure(let error):
            numericValidationError = error.message
            updateState()
            return false
        }
    }

    private struct ParsedFields {
        var indexEntry: NumericEntry
        var state: EngineSession.CurveState?
    }

    private func parseFields() -> Result<ParsedFields, ParseError> {
        if curveMode == .freehand { return parseFreehandFields() }
        return parseSmoothFields()
    }

    private func parseFreehandFields() -> Result<ParsedFields, ParseError> {
        let indexText = (sampleIndexField.currentEditor()?.string ?? sampleIndexField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let outputText = (outputField.currentEditor()?.string ?? outputField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let index: Int
        if indexText == displayedIndex.text {
            index = displayedIndex.value
        } else {
            guard let parsedIndex = parseWholeIndex(indexText, range: 0...255) else {
                return .failure(ParseError(message: invalidIndexMessage()))
            }
            index = parsedIndex
        }

        let currentSamples = curveState.samples
        guard currentSamples.indices.contains(index) else {
            return .failure(ParseError(message: invalidIndexMessage()))
        }

        var samples = currentSamples
        if outputText != displayedSampleOutputText {
            guard let physical = parsePhysical(outputText, range: domain.yRange) else {
                return .failure(ParseError(message: invalidOutputMessage()))
            }
            samples[index] = physicalToNormalized(physical, range: domain.yRange)
        }

        let settings = NeutralSettings(samples: samples)
        guard settings.isValid else {
            return .failure(ParseError(message: validationMessageForDomain()))
        }
        let entry = NumericEntry(text: indexFormatter.string(from: NSNumber(value: index)) ?? "\(index)", value: index)
        let state = samples == currentSamples && index == selectedIndex ? nil : EngineSession.CurveState(kind: .free, points: [], samples: samples)
        return .success(ParsedFields(indexEntry: entry, state: state))
    }

    private func parseSmoothFields() -> Result<ParsedFields, ParseError> {
        let count = curveState.points.count
        guard count > 0 else {
            let entry = displayedIndex
            return .success(ParsedFields(indexEntry: entry, state: nil))
        }

        let indexText = (sampleIndexField.currentEditor()?.string ?? sampleIndexField.stringValue)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let index: Int
        if indexText == displayedIndex.text {
            index = selectedIndex
        } else {
            guard let parsedIndex = parseWholeIndex(indexText, range: 0...(count - 1)) else {
                return .failure(ParseError(message: invalidPointIndexMessage()))
            }
            index = parsedIndex
        }
        guard curveState.points.indices.contains(index) else {
            return .failure(ParseError(message: invalidPointIndexMessage()))
        }

        var points = curveState.points
        let xText = (inputField.currentEditor()?.string ?? inputField.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)
        let yText = (outputField.currentEditor()?.string ?? outputField.stringValue).trimmingCharacters(in: .whitespacesAndNewlines)

        let editedIndex = selectedIndex
        if xText != inputDraft.displayed {
            guard let xPhysical = parsePhysical(xText, range: domain.xRange) else {
                return .failure(ParseError(message: invalidPointXMessage()))
            }
            points[editedIndex].x = physicalToNormalized(xPhysical, range: domain.xRange)
        }
        if yText != pointOutputDraft.displayed {
            guard let yPhysical = parsePhysical(yText, range: domain.yRange) else {
                return .failure(ParseError(message: invalidPointYMessage()))
            }
            points[editedIndex].y = physicalToNormalized(yPhysical, range: domain.yRange)
        }
        let changedPoint = points != curveState.points
        let entry = NumericEntry(text: indexFormatter.string(from: NSNumber(value: index)) ?? "\(index)", value: index)
        if !changedPoint { return .success(ParsedFields(indexEntry: entry, state: nil)) }

        guard EngineSession.CurveState.validPoints(points) else {
            return .failure(ParseError(message: invalidPointXMessage()))
        }
        let previous = curveState.samples
        guard let samples = try? InkCurveSampler.samples(points: points, previousSamples: previous) else {
            return .failure(ParseError(message: "Unable to calculate smooth curve."))
        }
        let state = EngineSession.CurveState(kind: .smooth, points: points, samples: samples)
        return .success(ParsedFields(indexEntry: entry, state: state))
    }

    private func parseWholeIndex(_ text: String, range: ClosedRange<Int>) -> Int? {
        let scanner = Scanner(string: text)
        scanner.locale = indexFormatter.locale ?? .current
        var value: Double = 0
        guard scanner.scanDouble(&value), scanner.isAtEnd, value.isFinite,
              value.rounded(.towardZero) == value else { return nil }
        guard value >= Double(range.lowerBound), value <= Double(range.upperBound) else { return nil }
        return Int(value)
    }

    private func parsePhysical(_ text: String, range: (Double, Double)) -> Double? {
        let scanner = Scanner(string: text)
        scanner.locale = pointFormatter.locale ?? .current
        var value: Double = 0
        guard scanner.scanDouble(&value), scanner.isAtEnd, value.isFinite else { return nil }
        let lo = min(range.0, range.1)
        let hi = max(range.0, range.1)
        guard value >= lo, value <= hi else { return nil }
        return value
    }

    private func ninePointSamples(from samples: [Double]) -> [EngineSession.CurvePoint] {
        (0..<9).map { i in
            let sample = i * 255 / 8
            return .init(x: Double(sample) / 255, y: samples[sample])
        }
    }

    private func commitGestureState(_ staged: EngineSession.CurveState, selectedIndex: Int?) {
        guard staged.isValid, !finished, !applying else { updateState(); return }
        curveState = staged
        if curveState.kind == .smooth {
            if let selectedIndex, curveState.points.indices.contains(selectedIndex) {
                self.selectedIndex = selectedIndex
            } else if curveState.points.isEmpty {
                self.selectedIndex = 0
            } else {
                self.selectedIndex = min(self.selectedIndex, curveState.points.count - 1)
            }
        }
        numericValidationError = nil
        let needsPreview = lastValidSettings.samples != curveState.samples
        lastValidSettings = NeutralSettings(samples: curveState.samples)
        displayState()
        publishSettings(lastValidSettings, needsPreview: needsPreview)
    }

    private func publishSettings(_ settings: NeutralSettings, needsPreview: Bool) {
        guard needsPreview else { updateState(); return }
        previewCurrent = false
        previewError = nil
        actionPending = true
        updateState()
        changedNeutral(settings)
        actionPending = false
        updateState()
    }

    private var canApply: Bool {
        guard !finished, !applying, !actionPending, numericValidationError == nil,
              !isInteracting, previewCurrent, previewError == nil else { return false }
        if case .success = parseFields() { return true }
        return false
    }

    private func updateState() {
        let editable = !applying && !finished
        for field in [sampleIndexField, outputField, inputField] { field.isEditable = editable; field.isEnabled = editable }
        resetButton.isEnabled = editable
        cancelButton.isEnabled = !finished && !cancelInvoked && !applying && !actionPending
        modePopup.isEnabled = editable && !hasInvalidDraft && !isInteracting
        pointTypePopup.isEnabled = editable && !hasInvalidDraft && !isInteracting && curveMode == .smooth && !curveState.points.isEmpty
        if curveMode == .freehand { inputField.isEditable = false }
        if curveMode == .smooth && curveState.points.isEmpty {
            sampleIndexField.isEnabled = false
            inputField.isEnabled = false
            outputField.isEnabled = false
        }
        applyButton.isEnabled = canApply

        if let numericValidationError {
            statusField.stringValue = numericValidationError
            statusField.textColor = .systemRed
        } else if let previewError {
            statusField.stringValue = previewError
            statusField.textColor = .systemRed
        } else if applying {
            statusField.stringValue = applyingStatusText()
            statusField.textColor = .secondaryLabelColor
        } else if !previewCurrent || isInteracting {
            statusField.stringValue = "Updating preview…"
            statusField.textColor = .secondaryLabelColor
        } else {
            statusField.stringValue = ""
            statusField.textColor = .secondaryLabelColor
        }

        window?.standardWindowButton(.closeButton)?.isEnabled = !applying && !finished && !actionPending
    }

    private func applyingStatusText() -> String {
        switch domain {
        case .ink: return "Applying ink curves…"
        case .lab: return "Applying Lab curves…"
        }
    }
}

typealias InkCurvesPanel = SampledCurvesPanel
