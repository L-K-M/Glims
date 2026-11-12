import AppKit
import UniformTypeIdentifiers

/// The modeless Batch window: one saved `.glimsrecording` replayed over a
/// chosen set of input images, each result written into one output folder
/// as native XCF or an exported PNG/JPEG/TIFF.
///
/// The window owns a single `RecorderBatchService` for its lifetime and
/// keeps it through completion, so accepted native work — including work
/// draining after Cancel — always finishes. The window cannot close while
/// a run is live: the close request cancels first and the window closes
/// itself once the service reports completion. `onRunStateChange` fires on
/// every `isRunning` edge so the app can gate termination on the drain.
///
/// File pickers are sheets scoped to this window; at most one is pending
/// at a time (`openPanel` tracks it) and `windowShouldClose` dismisses a
/// pending picker before deciding. The controller only stores the chosen
/// URLs — it never reads file contents on the main thread; the service
/// loads the recording and opens inputs on its own queues. Symbol matching
/// is an explicit user choice in the Target matching popup and defaults to
/// refusing recorded targets (`requireNoTargets`).
///
/// Every per-file outcome — saved path, failure or cancellation, including
/// cleanup warnings — lands in a selectable log, never in a per-file modal
/// alert, and the summary line always states the saved/failed/cancelled
/// counts, so a partial success cannot pass as complete.
@MainActor
final class RecorderBatchWindowController: NSWindowController, NSWindowDelegate {
    /// The content type saved recordings use, the same identifier the
    /// interactive Recorder file sheets use.
    private static let recordingType = UTType(exportedAs: "ch.lkmc.glims.recording", conformingTo: .json)

    /// One run per window; retained through completion.
    private let service: RecorderBatchService

    /// Fired when `isRunning` changes so the owner can gate application
    /// termination until the service has drained.
    var onRunStateChange: (() -> Void)?

    // The controls stay internal (not private) so the native integration
    // fixture and the owner can drive and read the window directly; there
    // are no test-only switches.
    let recordingField = NSTextField(labelWithString: "None chosen")
    let chooseRecordingButton = NSButton(title: "Choose…", target: nil, action: nil)
    let inputsCountField = NSTextField(labelWithString: "No input images chosen")
    let chooseInputsButton = NSButton(title: "Choose…", target: nil, action: nil)
    let inputsView = NSTextView()
    let outputFolderField = NSTextField(labelWithString: "None chosen")
    let chooseFolderButton = NSButton(title: "Choose…", target: nil, action: nil)
    let policyPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let policyNote = NSTextField(wrappingLabelWithString: "")
    let outputKindPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let exportForm = ExportOptionsForm()
    let statusField = NSTextField(wrappingLabelWithString: "")
    let progressIndicator = NSProgressIndicator()
    let resultsView = NSTextView()
    let runButton = NSButton(title: "Run Batch", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    /// The file picker currently attached as a sheet on this window, if
    /// any; `windowShouldClose` cancels it before deciding.
    private(set) var openPanel: NSOpenPanel?
    /// The items the last finished run produced; empty before it.
    private(set) var items: [RecorderBatchService.Item] = []
    /// The last refusal shown in the status line; nil while clean.
    private(set) var lastError: String?

    private(set) var recordingURL: URL?
    private(set) var inputURLs: [URL] = []
    private(set) var outputDirectory: URL?
    /// Set when a close request arrives during a run: the window closes
    /// itself once the service completes.
    private var closeAfterRun = false
    /// The deduplicated input count the service accepted into the run,
    /// taken from progress, so the summary stays honest when Cancel stops
    /// the run early.
    private var runTotal = 0

    var isRunning: Bool { service.isRunning }
    var resultsText: String { resultsView.string }
    var statusText: String { statusField.stringValue }

    init(session: EngineSession) {
        service = RecorderBatchService(session: session)
        let panel = BatchPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                               styleMask: [.titled, .closable, .miniaturizable, .resizable],
                               backing: .buffered, defer: false)
        panel.title = "Batch"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self
        panel.appearance = EditorPreferences.shared.chromeAppearance
        buildContent(in: panel)
        updateControls()
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: - Run and cancel

    /// Requests cancellation of the running Batch. Work the engine already
    /// accepted still drains; the service's completion ends the run.
    @objc func cancel() {
        guard service.isRunning else { return }
        service.cancel()
        showStatus("Cancelling — accepted work still finishes before the Batch stops.")
    }

    /// Validates every choice — including the export form's own commit
    /// gate when an export format is selected — then starts the service.
    /// A refused validation or a thrown start changes no state: the window
    /// stays usable with all choices editable.
    @objc func runBatch(_ sender: Any?) {
        guard !isRunning, openPanel == nil else { return }
        guard let recording = recordingURL else {
            return showStatus("Choose a saved .glimsrecording file first.", isError: true)
        }
        guard !inputURLs.isEmpty else {
            return showStatus("Choose at least one input image.", isError: true)
        }
        guard let directory = outputDirectory else {
            return showStatus("Choose an output folder.", isError: true)
        }
        let output: RecorderBatchService.Output
        if outputIsNative {
            output = .native
        } else {
            // The form's gate re-checks its numeric fields, shows the
            // readable refusal inline and returns false, which must
            // prevent the run.
            guard exportForm.commitEditing() else {
                return showStatus(exportForm.lastError ?? "Correct the export options.", isError: true)
            }
            output = .exported(exportForm.settings)
        }
        do {
            items = []
            resultsView.string = ""
            runTotal = 0
            try service.start(recording: recording, inputs: inputURLs, directory: directory,
                              output: output, matching: selectedPolicy,
                              progress: { [weak self] progress in self?.showProgress(progress) },
                              completion: { [weak self] result in self?.runDidFinish(result) })
        } catch {
            return showStatus(error.localizedDescription, isError: true)
        }
        closeAfterRun = false
        progressIndicator.isIndeterminate = true
        progressIndicator.startAnimation(nil)
        showStatus("Loading the recording…")
        updateControls()
        onRunStateChange?()
    }

    // MARK: - Pickers

    @objc func chooseRecording(_ sender: Any?) {
        guard !isRunning, openPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Recording"
        panel.prompt = "Choose"
        panel.message = "Choose a saved .glimsrecording file."
        panel.allowedContentTypes = [Self.recordingType]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        presentPicker(panel) { [weak self] urls in
            guard let self, let url = urls.first else { return }
            self.selectRecording(url)
        }
    }

    @objc func chooseInputs(_ sender: Any?) {
        guard !isRunning, openPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Input Images"
        panel.prompt = "Choose"
        panel.message = "Choose image files or folders. Folders include their visible files, without subfolders; files the editor cannot open are reported individually."
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        presentPicker(panel) { [weak self] urls in self?.selectInputs(urls) }
    }

    @objc func chooseOutputFolder(_ sender: Any?) {
        guard !isRunning, openPanel == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose Output Folder"
        panel.prompt = "Choose"
        panel.message = "Choose the folder the edited images are written into."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        presentPicker(panel) { [weak self] urls in
            guard let self, let url = urls.first else { return }
            self.selectOutputDirectory(url)
        }
    }

    /// Runs one picker as a sheet on this window and keeps it tracked, so
    /// a close request can dismiss it. The completion verifies the panel
    /// is still the tracked one before applying a choice.
    private func presentPicker(_ panel: NSOpenPanel,
                               choose: @escaping @MainActor ([URL]) -> Void) {
        guard let window, openPanel == nil else { return }
        openPanel = panel
        updateControls()
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self, let panel, self.openPanel === panel else { return }
            self.openPanel = nil
            self.updateControls()
            guard response == .OK else { return }
            choose(panel.urls)
        }
    }

    // MARK: - Choices (callable from the pickers and the fixture)

    func selectRecording(_ url: URL) {
        guard !isRunning else { return }
        recordingURL = url
        recordingField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        recordingField.toolTip = url.path
        clearError()
    }

    func selectInputs(_ urls: [URL]) {
        guard !isRunning else { return }
        inputURLs = urls
        inputsCountField.stringValue = urls.isEmpty ? "No input files or folders chosen"
            : "\(urls.count) file or folder selection\(urls.count == 1 ? "" : "s")"
        inputsView.string = urls.map(\.lastPathComponent).joined(separator: "\n")
        clearError()
    }

    func selectOutputDirectory(_ url: URL) {
        guard !isRunning else { return }
        outputDirectory = url
        outputFolderField.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
        outputFolderField.toolTip = url.path
        clearError()
    }

    private var selectedPolicy: RecorderBatchBindings.Policy {
        let all = RecorderBatchBindings.Policy.allCases
        let index = policyPopup.indexOfSelectedItem
        return all.indices.contains(index) ? all[index] : .requireNoTargets
    }

    private var outputIsNative: Bool { outputKindPopup.indexOfSelectedItem != 1 }

    @objc private func policyChanged(_ sender: NSPopUpButton) {
        policyNote.stringValue = Self.note(for: selectedPolicy)
    }

    @objc private func outputKindChanged(_ sender: NSPopUpButton) {
        updateControls()
    }

    // MARK: - Service callbacks

    private func showProgress(_ progress: RecorderBatchService.Progress) {
        runTotal = max(runTotal, progress.total)
        if progress.total > 0 {
            progressIndicator.isIndeterminate = false
            progressIndicator.stopAnimation(nil)
            progressIndicator.maxValue = Double(progress.total)
            progressIndicator.doubleValue = Double(progress.completed)
        }
        showStatus("\(progress.completed) of \(progress.total) · \(progress.message)")
    }

    private func runDidFinish(_ result: Result<[RecorderBatchService.Item], Error>) {
        progressIndicator.isIndeterminate = false
        progressIndicator.stopAnimation(nil)
        switch result {
        case .success(let finished):
            items = finished
            showResults(finished)
        case .failure(let error):
            items = []
            let reason = error.localizedDescription
            resultsView.string = "Batch did not finish: \(reason)"
            showStatus(reason, isError: true)
        }
        updateControls()
        onRunStateChange?()
        if closeAfterRun { close() }
    }

    /// The per-file log: one line per input with its saved path, failure
    /// reason or cancellation, plus any cleanup warnings. The headline
    /// always reports all three counts, so partial success is explicit.
    private func showResults(_ finished: [RecorderBatchService.Item]) {
        var saved = 0, failed = 0, cancelled = 0
        var lines: [String] = []
        for item in finished {
            let name = item.source.lastPathComponent
            switch item.outcome {
            case .saved(let url, let warning):
                saved += 1
                var line = "\(name) — Saved to \((url.path as NSString).abbreviatingWithTildeInPath)"
                if let warning, !warning.isEmpty { line += "\n    Warning: \(warning)" }
                lines.append(line)
            case .failed(let reason):
                failed += 1
                lines.append("\(name) — Failed: \(reason)")
            case .cancelled(let warning):
                cancelled += 1
                var line = "\(name) — Cancelled"
                if let warning, !warning.isEmpty { line += "\n    Warning: \(warning)" }
                lines.append(line)
            }
        }
        let headline = service.cancellationRequested ? "Batch cancelled:" : "Batch finished:"
        let processed = finished.count == runTotal ? "all \(runTotal)"
            : "\(finished.count) of \(runTotal)"
        let summary = "\(headline) \(saved) saved, \(failed) failed, \(cancelled) cancelled "
            + "(\(processed) inputs processed)."
        resultsView.string = ([summary, ""] + lines).joined(separator: "\n")
        resultsView.scrollToBeginningOfDocument(nil)
        showStatus(summary, isError: failed > 0)
    }

    // MARK: - Window delegate

    /// A pending picker is dismissed first. During a run the close request
    /// cancels the Batch and the window closes on completion instead.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        dismissPendingPicker()
        guard service.isRunning else { return true }
        closeAfterRun = true
        cancel()
        return false
    }

    func windowWillClose(_ notification: Notification) {
        dismissPendingPicker()
    }

    private func dismissPendingPicker() {
        guard let panel = openPanel else { return }
        openPanel = nil
        panel.cancel(nil)
        if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        updateControls()
    }

    // MARK: - Status and controls

    private func showStatus(_ text: String, isError: Bool = false) {
        lastError = isError ? text : nil
        statusField.stringValue = text
        statusField.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    /// After a refused start, fixing a choice restores the neutral hint.
    private func clearError() {
        guard lastError != nil else { return }
        showStatus("Choose a recording, input images and an output folder.")
    }

    /// Running fences the choice controls and Run; Cancel stays enabled so
    /// it can drain the run, and progress/results stay readable.
    private func updateControls() {
        let idle = !isRunning && openPanel == nil
        chooseRecordingButton.isEnabled = idle
        chooseInputsButton.isEnabled = idle
        chooseFolderButton.isEnabled = idle
        policyPopup.isEnabled = idle
        outputKindPopup.isEnabled = idle
        setEnabled(exportForm, idle && !outputIsNative)
        runButton.isEnabled = idle
        cancelButton.isEnabled = isRunning
    }

    /// Recursively enables or disables every control in the export form
    /// while keeping the section visible — inapplicable controls are
    /// disabled, not hidden (docs/design.md, rule 8).
    private func setEnabled(_ root: NSView, _ enabled: Bool) {
        for view in root.subviews {
            if let control = view as? NSControl { control.isEnabled = enabled }
            setEnabled(view, enabled)
        }
    }

    private static func title(for policy: RecorderBatchBindings.Policy) -> String {
        switch policy {
        case .requireNoTargets: return "Refuse recorded targets"
        case .matchingNamesAndKinds: return "Match by name and kind"
        case .matchingPathsAndKinds: return "Match by name, kind and full path"
        }
    }

    private static func note(for policy: RecorderBatchBindings.Policy) -> String {
        switch policy {
        case .requireNoTargets:
            return "Only recordings whose commands need no specific layer, channel or mask target can run. No targets are matched automatically."
        case .matchingNamesAndKinds:
            return "Each recorded target must match exactly one same-named target of the same kind in each image."
        case .matchingPathsAndKinds:
            return "Each recorded target must match exactly one same-named target of the same kind with the same full group path in each image."
        }
    }

    private static func scrollable(_ text: NSTextView, in scroll: NSScrollView) {
        text.isEditable = false
        text.isSelectable = true
        text.isRichText = false
        text.font = .systemFont(ofSize: 11)
        text.textContainerInset = NSSize(width: 4, height: 4)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.minSize = NSSize(width: 0, height: scroll.contentSize.height)
        text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.textContainer?.widthTracksTextView = true
        text.textContainer?.containerSize = NSSize(width: scroll.contentSize.width,
                                                   height: .greatestFiniteMagnitude)
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .bezelBorder
    }

    // MARK: - Layout

    private func buildContent(in panel: NSPanel) {
        let margin: CGFloat = 20

        let intro = NSTextField(wrappingLabelWithString:
            "Replay a saved recording on each input image. Every image is processed privately; its result appears in the log below.")
        intro.font = .systemFont(ofSize: 11)
        intro.textColor = .secondaryLabelColor
        intro.preferredMaxLayoutWidth = 580
        intro.setAccessibilityLabel("Batch description")

        recordingField.lineBreakMode = .byTruncatingMiddle
        recordingField.isSelectable = true
        recordingField.setAccessibilityLabel("Chosen .glimsrecording file")
        recordingField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        chooseRecordingButton.target = self
        chooseRecordingButton.action = #selector(chooseRecording(_:))
        chooseRecordingButton.setAccessibilityLabel("Choose a .glimsrecording file")
        let recordingRow = NSStackView(views: [recordingField, chooseRecordingButton])
        recordingRow.spacing = 8
        recordingRow.alignment = .centerY

        inputsCountField.setAccessibilityLabel("Input image count")
        chooseInputsButton.target = self
        chooseInputsButton.action = #selector(chooseInputs(_:))
        chooseInputsButton.setAccessibilityLabel("Choose input image files or folders")
        let inputsHead = NSStackView(views: [inputsCountField, chooseInputsButton])
        inputsHead.spacing = 8
        inputsHead.alignment = .centerY
        inputsView.setAccessibilityLabel("Input image names")
        let inputsScroll = NSScrollView()
        Self.scrollable(inputsView, in: inputsScroll)
        inputsScroll.heightAnchor.constraint(equalToConstant: 66).isActive = true
        let inputsCell = NSStackView(views: [inputsHead, inputsScroll])
        inputsCell.orientation = .vertical
        inputsCell.alignment = .leading
        inputsCell.spacing = 6
        inputsScroll.widthAnchor.constraint(equalTo: inputsCell.widthAnchor).isActive = true

        outputFolderField.lineBreakMode = .byTruncatingMiddle
        outputFolderField.isSelectable = true
        outputFolderField.setAccessibilityLabel("Chosen output folder")
        outputFolderField.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        chooseFolderButton.target = self
        chooseFolderButton.action = #selector(chooseOutputFolder(_:))
        chooseFolderButton.setAccessibilityLabel("Choose an output folder")
        let folderRow = NSStackView(views: [outputFolderField, chooseFolderButton])
        folderRow.spacing = 8
        folderRow.alignment = .centerY

        policyPopup.addItems(withTitles: RecorderBatchBindings.Policy.allCases.map { Self.title(for: $0) })
        policyPopup.selectItem(at: 0)
        policyPopup.target = self
        policyPopup.action = #selector(policyChanged(_:))
        policyPopup.setAccessibilityLabel("Target matching policy")
        policyNote.font = .systemFont(ofSize: 11)
        policyNote.textColor = .secondaryLabelColor
        policyNote.maximumNumberOfLines = 3
        policyNote.preferredMaxLayoutWidth = 360
        policyNote.stringValue = Self.note(for: selectedPolicy)
        policyNote.setAccessibilityLabel("Target matching policy description")
        let policyCell = NSStackView(views: [policyPopup, policyNote])
        policyCell.orientation = .vertical
        policyCell.alignment = .leading
        policyCell.spacing = 4
        policyNote.widthAnchor.constraint(equalTo: policyCell.widthAnchor).isActive = true

        outputKindPopup.addItems(withTitles: ["XCF — native document", "Exported image (PNG, JPEG, TIFF)"])
        outputKindPopup.selectItem(at: 0)
        outputKindPopup.target = self
        outputKindPopup.action = #selector(outputKindChanged(_:))
        outputKindPopup.setAccessibilityLabel("Output kind")

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Recording (.glimsrecording):"), recordingRow],
            [NSTextField(labelWithString: "Input images:"), inputsCell],
            [NSTextField(labelWithString: "Output folder:"), folderRow],
            [NSTextField(labelWithString: "Target matching:"), policyCell],
            [NSTextField(labelWithString: "Output:"), outputKindPopup],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.columnSpacing = 12
        grid.rowSpacing = 10
        grid.row(at: 1).yPlacement = .top
        grid.row(at: 3).yPlacement = .top

        statusField.font = .systemFont(ofSize: 11)
        statusField.maximumNumberOfLines = 2
        statusField.preferredMaxLayoutWidth = 580
        statusField.setAccessibilityLabel("Batch status")
        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.doubleValue = 0
        progressIndicator.isIndeterminate = false
        progressIndicator.setAccessibilityLabel("Batch progress")
        showStatus("Choose a recording, input images and an output folder.")

        let resultsLabel = NSTextField(labelWithString: "Results:")
        resultsView.setAccessibilityLabel("Batch results")
        let resultsScroll = NSScrollView()
        Self.scrollable(resultsView, in: resultsScroll)
        resultsScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true

        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Cancel the running Batch")
        runButton.target = self
        runButton.action = #selector(runBatch(_:))
        runButton.keyEquivalent = "\r"
        runButton.setAccessibilityLabel("Run the Batch")
        let buttons = NSStackView(views: [NSView(), cancelButton, runButton])
        buttons.spacing = 12

        let stack = NSStackView(views: [intro, grid, exportForm, statusField, progressIndicator,
                                      resultsLabel, resultsScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(14, after: grid)
        stack.setCustomSpacing(14, after: progressIndicator)
        stack.setCustomSpacing(4, after: resultsLabel)
        stack.setCustomSpacing(14, after: resultsScroll)

        let content = NSView()
        panel.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ] + [intro, grid, exportForm, statusField, progressIndicator,
             resultsLabel, resultsScroll, buttons].map {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * margin)
        })

        let fitted = stack.fittingSize
        let size = NSSize(width: max(620, fitted.width), height: max(420, fitted.height))
        panel.setContentSize(size)
        panel.minSize = NSSize(width: 480, height: 380)
        panel.initialFirstResponder = chooseRecordingButton
    }
}

/// An auxiliary utility window: it can become key for its own controls but
/// never becomes main, so it does not retarget the document palettes.
private final class BatchPanel: NSPanel {
    override var canBecomeMain: Bool { false }
}
