import AppKit
import UniformTypeIdentifiers

/// The Soft Proof Setup sheet: chooses the ICC profile and the proof and
/// display intents used to preview this image on the window's own
/// display. The proof is view state only — it never changes the image,
/// its working profile or its saved simulation metadata. Gamut warnings
/// mark out-of-gamut colors in gray. Independent paper-white
/// and black-simulation controls remain separate from this view simulation.
///
/// Every file read and the 1×1 native preflight run inside the document's
/// counted off-main services; this controller performs only syntactic
/// path checks on the main thread, captures the display destination once
/// per Apply, and fences each asynchronous completion — service or open
/// panel — with a generation token, so a stale answer can never overwrite
/// a newer draft or deliver after the sheet is gone.
@MainActor
final class SoftProofController: NSWindowController, NSWindowDelegate {
    /// The document whose services own every engine and file interaction.
    let imageDocument: ImageDocument
    /// The proof already applied to this window, if any; its retained ICC
    /// bytes let the form revalidate changed intents or BPC with no path.
    let initialProof: CanvasSoftProof?

    let pathField = NSTextField()
    let chooseButton = NSButton(title: "Choose…", target: nil, action: nil)
    let proofIntentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let displayIntentPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let blackPointCompensationCheck =
        NSButton(checkboxWithTitle: "Black point compensation", target: nil, action: nil)
    let gamutWarningsCheck = NSButton(checkboxWithTitle: "Gamut warnings", target: nil, action: nil)
    let currentProofLabel = NSTextField(labelWithString: "None")
    let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    let statusMessage = NSTextField(wrappingLabelWithString: "")

    private(set) var lastError: String?
    /// True while a profile read or native preflight is in flight: the
    /// draft controls stay disabled but Cancel and close do not.
    private(set) var isApplying = false
    private(set) var isInvalidated = false
    /// The child ICC open panel while attached; nil at every other time.
    private(set) var openPanel: NSOpenPanel?

    private let destinationProvider: @MainActor () -> CanvasDisplayDestination
    private var onApply: (@MainActor (CanvasSoftProof) -> Void)?
    private var onDismiss: (@MainActor () -> Void)?
    private weak var ownerWindow: NSWindow?
    private var didPresent = false
    private var requestGeneration = 0

    init(document: ImageDocument, initial: CanvasSoftProof?,
         destination: @escaping @MainActor () -> CanvasDisplayDestination,
         onApply: @escaping @MainActor (CanvasSoftProof) -> Void,
         onDismiss: @escaping @MainActor () -> Void) {
        self.imageDocument = document
        self.initialProof = initial
        self.destinationProvider = destination
        self.onApply = onApply
        self.onDismiss = onDismiss
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 340),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Soft Proof Setup"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        panel.delegate = self

        let choices = EngineSession.ProfileIntent.conversionChoices
        proofIntentPopup.addItems(withTitles: choices.map(\.title))
        displayIntentPopup.addItems(withTitles: choices.map(\.title))
        // A fresh form defaults to the common proof/display pairing; an
        // existing proof keeps its own captured intents.
        if let index = choices.firstIndex(of: initial?.proofIntent ?? .relativeColorimetric) {
            proofIntentPopup.selectItem(at: index)
        }
        if let index = choices.firstIndex(of: initial?.displayIntent ?? .relativeColorimetric) {
            displayIntentPopup.selectItem(at: index)
        }
        blackPointCompensationCheck.state = (initial?.blackPointCompensation ?? false) ? .on : .off
        gamutWarningsCheck.state = (initial?.gamutWarnings ?? false) ? .on : .off
        currentProofLabel.stringValue = initial?.profileName ?? "None"
        buildContent(in: panel)
        panel.initialFirstResponder = pathField
        updateControls()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Attaches the sheet to `parent` once; an attached sheet on the
    /// parent or a second presentation of this controller is refused.
    func present(on parent: NSWindow) {
        guard !isInvalidated, !didPresent, let window, window.sheetParent == nil else { return }
        guard !imageDocument.isClosing else { return invalidate() }
        guard parent.attachedSheet == nil else {
            return showError("Close the current sheet before opening Soft Proof Setup.")
        }
        ownerWindow = parent
        didPresent = true
        parent.beginSheet(window) { [weak self] _ in self?.invalidate() }
    }

    func commitFieldEdit() { window?.endEditing(for: nil) }

    /// Ends every pending request and the child open panel, closes the
    /// sheet, clears the callbacks and reports dismissal exactly once.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        requestGeneration += 1
        isApplying = false
        openPanel?.cancel(nil)
        openPanel = nil
        onApply = nil
        commitFieldEdit()
        if let window {
            if let child = window.attachedSheet { window.endSheet(child) }
            window.sheetParent?.endSheet(window)
            window.orderOut(nil)
        }
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    // MARK: - Window delegate

    /// Cancel and close stay available while a proof request is in
    /// flight; invalidate fences its late completion.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        invalidate()
        return false
    }

    func windowWillClose(_ notification: Notification) { invalidate() }

    // MARK: - Draft actions

    @objc func apply(_ sender: Any?) {
        guard !isInvalidated, !isApplying, openPanel == nil else { return }
        guard !imageDocument.isClosing else { return invalidate() }
        commitFieldEdit()
        guard let proofIntent = selectedIntent(proofIntentPopup),
              let displayIntent = selectedIntent(displayIntentPopup) else {
            return showError("Choose both a proof intent and a display intent.")
        }
        let compensation = blackPointCompensationCheck.state == .on
        let warnings = gamutWarningsCheck.state == .on
        let rawPath = pathField.stringValue

        // An empty path reuses the retained profile bytes of the current
        // proof: only the rendering options change, so no file is read.
        if rawPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            guard let initial = initialProof else {
                return showError("Choose an ICC profile file (.icc or .icm).")
            }
            do {
                let candidate = try CanvasSoftProof(profileICC: initial.profileICC,
                                                    profileName: initial.profileName,
                                                    proofIntent: proofIntent,
                                                    displayIntent: displayIntent,
                                                    blackPointCompensation: compensation,
                                                    gamutWarnings: warnings)
                queueProofValidation(candidate)
            } catch {
                showError(String(describing: error))
            }
            return
        }

        switch ProfileForm.validatedICCPath(rawPath) {
        case .failure(let error):
            showError(error.localizedDescription)
        case .success(let path):
            queueProfileRead(at: URL(fileURLWithPath: path), proofIntent: proofIntent,
                             displayIntent: displayIntent, compensation: compensation, gamutWarnings: warnings)
        }
    }

    @objc func cancel(_ sender: Any?) {
        guard !isInvalidated else { return }
        invalidate()
    }

    /// The ICC open panel as a sheet on this sheet; the chosen path is
    /// stored as text only — reading it is the Apply path's off-main job.
    @objc func chooseFile(_ sender: Any?) {
        guard !isInvalidated, !isApplying, !imageDocument.isClosing,
              openPanel == nil, sheetIsCurrent, let window else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ProfileForm.iccContentTypes
        panel.prompt = "Choose"
        panel.message = "Choose an ICC color proof profile (.icc or .icm)."
        panel.isReleasedWhenClosed = false
        requestGeneration += 1
        openPanel = panel
        let generation = requestGeneration
        updateControls()
        panel.beginSheetModal(for: window) { [weak self, weak panel] response in
            guard let self, let panel, self.openPanel === panel else { return }
            // The URL is copied while the panel is certainly retained;
            // dropping our reference may release it before the guard ends.
            let chosenURL = panel.url
            self.openPanel = nil
            guard !self.isInvalidated, self.requestGeneration == generation else { return }
            guard !self.imageDocument.isClosing, self.sheetIsCurrent else { return self.invalidate() }
            if response == .OK, let url = chosenURL {
                self.pathField.stringValue = url.path
                self.lastError = nil
            }
            self.updateControls()
        }
    }

    // MARK: - Proof requests

    /// Admits one proof request: fences it with a fresh generation and
    /// marks the draft busy; the caller snapshots the display destination
    /// once, on the main actor, for the queued service call.
    private func beginProofRequest() -> Int? {
        guard !isInvalidated, !isApplying, openPanel == nil,
              !imageDocument.isClosing, sheetIsCurrent else { return nil }
        requestGeneration += 1
        isApplying = true
        lastError = nil
        updateControls()
        return requestGeneration
    }

    private func queueProfileRead(at url: URL, proofIntent: EngineSession.ProfileIntent,
                                  displayIntent: EngineSession.ProfileIntent,
                                  compensation: Bool, gamutWarnings: Bool) {
        guard let generation = beginProofRequest() else { return }
        let destination = destinationProvider()
        imageDocument.readSoftProofProfile(at: url, proofIntent: proofIntent,
                                      displayIntent: displayIntent,
                                      blackPointCompensation: compensation,
                                      destination: destination, gamutWarnings: gamutWarnings) { [weak self] result in
            self?.proofDidFinish(result, generation: generation)
        }
    }

    private func queueProofValidation(_ candidate: CanvasSoftProof) {
        guard let generation = beginProofRequest() else { return }
        let destination = destinationProvider()
        imageDocument.validateSoftProof(candidate, destination: destination) { [weak self] result in
            self?.proofDidFinish(result, generation: generation)
        }
    }

    private func proofDidFinish(_ result: Result<CanvasSoftProof, Error>, generation: Int) {
        guard !isInvalidated, requestGeneration == generation else { return }
        guard !imageDocument.isClosing, sheetIsCurrent else { return invalidate() }
        isApplying = false
        switch result {
        case .success(let proof): finishApplied(proof)
        case .failure(let error): showError(String(describing: error))
        }
    }

    /// Delivers a natively preflighted proof to the owner exactly once,
    /// then closes — only while this sheet is still the owner's attached,
    /// current sheet on a live imageDocument.
    private func finishApplied(_ proof: CanvasSoftProof) {
        guard let owner = ownerWindow, let window, owner.attachedSheet === window,
              let callback = onApply else { return invalidate() }
        onApply = nil
        callback(proof)
        invalidate()
    }

    // MARK: - Controls

    private var sheetIsCurrent: Bool {
        guard let owner = ownerWindow, let window else { return false }
        return owner.attachedSheet === window
    }

    private func selectedIntent(_ popup: NSPopUpButton) -> EngineSession.ProfileIntent? {
        let choices = EngineSession.ProfileIntent.conversionChoices
        let index = popup.indexOfSelectedItem
        return choices.indices.contains(index) ? choices[index] : nil
    }

    private func updateControls() {
        let editable = !isInvalidated && !isApplying && openPanel == nil
        pathField.isEnabled = editable
        chooseButton.isEnabled = editable
        proofIntentPopup.isEnabled = editable
        displayIntentPopup.isEnabled = editable
        blackPointCompensationCheck.isEnabled = editable
        gamutWarningsCheck.isEnabled = editable
        applyButton.isEnabled = editable
        cancelButton.isEnabled = !isInvalidated
        window?.standardWindowButton(.closeButton)?.isEnabled = !isInvalidated
        statusMessage.textColor = lastError == nil ? .secondaryLabelColor : .systemRed
        statusMessage.stringValue = lastError ?? (isApplying ? "Checking the proof profile…" : "")
    }

    private func showError(_ text: String) {
        lastError = text
        updateControls()
    }

    private func buildContent(in panel: NSPanel) {
        let note = NSTextField(wrappingLabelWithString:
            "Preview this image through a proof profile in this window. The image and its saved "
            + "color settings stay unchanged. Leave the ICC file path empty to reuse the proof profile shown below; "
            + "without one, choose an .icc or .icm file.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        pathField.placeholderString = "/full/path/to/profile.icc"
        pathField.setAccessibilityLabel("ICC profile file path")
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        chooseButton.target = self
        chooseButton.action = #selector(chooseFile(_:))
        chooseButton.setAccessibilityLabel("Choose an ICC profile file")
        proofIntentPopup.setAccessibilityLabel("Proof rendering intent")
        displayIntentPopup.setAccessibilityLabel("Display rendering intent")
        blackPointCompensationCheck.setAccessibilityLabel("Black point compensation")
        gamutWarningsCheck.setAccessibilityLabel("Gamut warnings")
        gamutWarningsCheck.setAccessibilityHelp("Marks colors outside the proof profile's gamut in gray.")
        gamutWarningsCheck.toolTip = "Marks colors outside the proof profile's gamut in gray."
        currentProofLabel.setAccessibilityLabel("Current proof profile")
        currentProofLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true
        applyButton.setAccessibilityLabel("Apply soft proof")
        cancelButton.setAccessibilityLabel("Cancel soft proof")

        let pathRow = NSStackView(views: [pathField, chooseButton])
        pathRow.orientation = .horizontal
        pathRow.spacing = 8
        pathRow.alignment = .centerY

        let rows: [[NSView]] = [
            [NSTextField(labelWithString: "Proof profile:"), currentProofLabel],
            [NSTextField(labelWithString: "ICC file:"), pathRow],
            [NSTextField(labelWithString: "Proof intent:"), proofIntentPopup],
            [NSTextField(labelWithString: "Display intent:"), displayIntentPopup],
            [NSGridCell.emptyContentView, blackPointCompensationCheck],
            [NSGridCell.emptyContentView, gamutWarningsCheck],
        ]
        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        proofIntentPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true
        displayIntentPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 170).isActive = true

        statusMessage.maximumNumberOfLines = 3
        statusMessage.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusMessage.setAccessibilityLabel("Soft proof status")
        statusMessage.heightAnchor.constraint(equalToConstant: 46).isActive = true

        applyButton.target = self
        applyButton.action = #selector(apply(_:))
        applyButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        let actions = NSStackView(views: [NSView(), cancelButton, applyButton])
        actions.spacing = 8

        let stack = NSStackView(views: [note, grid, statusMessage, actions])
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
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ] + [note, statusMessage, actions].map {
            $0.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32)
        })
        panel.setContentSize(NSSize(width: 540, height: stack.fittingSize.height))
    }
}
