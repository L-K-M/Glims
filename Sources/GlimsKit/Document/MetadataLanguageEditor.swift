import AppKit

/// Edits one existing language entry. Keys come only from the owned typed
/// map; local drafts never reconstruct or replace the whole native map.
@MainActor
final class MetadataLanguageEditorController: NSObject, NSWindowDelegate {
    let document: ImageDocument
    let tag: String
    let panel: NSPanel
    var onClose: (() -> Void)?
    private let languages = NSPopUpButton(frame: .zero, pullsDown: false)
    private let editor = NSTextView(frame: .zero)
    private let applyButton = NSButton(title: "Apply Selected Language", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let message = NSTextField(wrappingLabelWithString: "")
    private var values: [EngineSession.MetadataLanguageValue] = []
    private var drafts: [String: String] = [:]
    private var dirtyKeys: Set<String> = []
    private var selectedLanguage: String?
    private var generation = 0
    private var lastStateVersion = -1
    private var reading = false
    private var applying = false
    private var invalidated = false
    private var updatingEditor = false
    private(set) var lastError: String?

    init(document: ImageDocument, tag: String) {
        self.document = document
        self.tag = tag
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 340),
                        styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        panel.title = "Metadata Language — \(tag)"
        panel.delegate = self
        let note = NSTextField(wrappingLabelWithString:
            "Choose an existing language and edit its text. Apply changes only the selected language as one Undo step. "
            + "Other unapplied language drafts are kept until Close. Languages cannot be added or removed here.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        languages.setAccessibilityLabel("Metadata language")
        languages.target = self
        languages.action = #selector(languageChanged(_:))
        editor.isRichText = false
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.allowsUndo = true
        editor.delegate = self
        editor.setAccessibilityLabel("Metadata language text")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 590, height: 180))
        scroll.borderType = .bezelBorder
        scroll.hasVerticalScroller = true
        editor.minSize = NSSize(width: 0, height: 180)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.frame = scroll.contentView.bounds
        scroll.documentView = editor
        scroll.widthAnchor.constraint(equalToConstant: 590).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        applyButton.target = self
        applyButton.action = #selector(apply(_:))
        applyButton.setAccessibilityLabel("Apply metadata language")
        applyButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(close(_:))
        closeButton.setAccessibilityLabel("Close metadata language editor")
        closeButton.keyEquivalent = "\u{1b}"
        message.setAccessibilityLabel("Metadata language error")
        message.maximumNumberOfLines = 3
        let actions = NSStackView(views: [applyButton, closeButton])
        actions.spacing = 8
        let stack = NSStackView(views: [note, languages, scroll, actions, message])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            note.widthAnchor.constraint(equalToConstant: 590),
            message.widthAnchor.constraint(equalToConstant: 590),
        ])
        panel.contentView = content
        content.setFrameSize(stack.fittingSize)
        panel.initialFirstResponder = languages
        updateControls()
    }

    func present(on parent: NSWindow) {
        guard !invalidated, panel.sheetParent == nil else { return }
        parent.beginSheet(panel) { [weak self] _ in self?.invalidate() }
        reload()
    }

    func commitFieldEdit() { panel.endEditing(for: nil) }

    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        generation += 1
        editor.delegate = nil
        panel.endEditing(for: nil)
        if let parent = panel.sheetParent { parent.endSheet(panel) }
        panel.orderOut(nil)
        let completion = onClose
        onClose = nil
        completion?()
    }

    func documentStateDidChange() {
        guard !invalidated else { return }
        if !applying && document.stateVersion != lastStateVersion { reload() }
        updateControls()
    }

    private var selectedIsPresent: Bool {
        guard let selectedLanguage else { return false }
        return values.contains { $0.language == selectedLanguage }
    }

    private var writeRefusal: String? {
        MetadataSheetLogic.writeAdmission(isClosing: document.isClosing,
            isSavingForClose: document.isSavingForClose, isTransferringClipboard: document.isTransferringClipboard,
            pluginRunning: PlugInCommands.isRunning, engineBusy: EngineActivity.shared.isBusy,
            filterPreviewOpen: document.filterPreviewIsOpen)
    }

    private func updateControls() {
        let available = !invalidated && !reading && !applying
        languages.isEnabled = available && !values.isEmpty
        editor.isEditable = available && selectedIsPresent
        applyButton.isEnabled = available && selectedIsPresent && writeRefusal == nil
        closeButton.isEnabled = !invalidated
        if lastError == nil {
            message.textColor = .secondaryLabelColor
            message.stringValue = reading ? "Reading languages…" : (writeRefusal ?? "")
        }
    }

    private func showError(_ text: String) {
        lastError = text
        message.textColor = .systemRed
        message.stringValue = text
    }

    private func clearError() { lastError = nil; message.stringValue = "" }

    private func synchronizeEditor() {
        updatingEditor = true
        editor.string = selectedLanguage.flatMap { drafts[$0] } ?? ""
        // NSTextView's local Undo must never cross a language switch.
        editor.undoManager?.removeAllActions()
        updatingEditor = false
    }

    private func reload() {
        guard !invalidated, !applying else { return }
        generation += 1
        let request = generation
        lastStateVersion = document.stateVersion
        reading = true
        updateControls()
        document.readMetadataLanguages(tag) { [weak self] result in
            guard let self, !self.invalidated, request == self.generation else { return }
            self.reading = false
            switch result {
            case .failure(let error):
                // Keep the draft visible, but stale keys may not be applied.
                self.values = []
                self.showError(String(describing: error))
            case .success(let values):
                self.values = values
                for value in values where !self.dirtyKeys.contains(value.language) {
                    self.drafts[value.language] = value.text
                }
                self.languages.removeAllItems()
                self.languages.addItems(withTitles: values.map(\.language))
                if self.selectedLanguage == nil { self.selectedLanguage = values.first?.language }
                if let selected = self.selectedLanguage, values.contains(where: { $0.language == selected }) {
                    self.languages.selectItem(withTitle: selected)
                } else {
                    self.languages.select(nil)
                    self.showError(values.isEmpty ? "This tag has no editable language entries."
                        : "The selected language no longer exists. Choose another language; its draft is retained.")
                }
                self.synchronizeEditor()
            }
            self.updateControls()
        }
    }

    @objc private func languageChanged(_ sender: Any?) {
        guard !invalidated, !reading, !applying,
              let key = languages.selectedItem?.title, values.contains(where: { $0.language == key }) else { return }
        selectedLanguage = key
        clearError()
        synchronizeEditor()
        updateControls()
    }

    @objc private func apply(_ sender: Any?) {
        guard !invalidated, !reading, !applying, selectedIsPresent,
              let key = selectedLanguage, writeRefusal == nil else { return }
        commitFieldEdit()
        let text = drafts[key] ?? ""
        guard !text.isEmpty, !text.utf8.contains(0) else {
            return showError("Enter nonempty text without NUL characters for this language.")
        }
        applying = true
        clearError()
        updateControls()
        document.editMetadataLanguage(tag, language: key, text: text) { [weak self] result in
            guard let self, !self.invalidated else { return }
            self.applying = false
            switch result {
            case .success:
                self.dirtyKeys.remove(key)
                self.reload()
            case .failure(let error): self.showError(String(describing: error))
            }
            self.updateControls()
        }
    }

    @objc private func close(_ sender: Any?) { invalidate() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        invalidate()
        return false
    }

    func windowWillClose(_ notification: Notification) { invalidate() }
}

extension MetadataLanguageEditorController: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        guard !invalidated, !updatingEditor, !reading, !applying,
              selectedIsPresent, let key = selectedLanguage else { return }
        drafts[key] = editor.string
        if values.first(where: { $0.language == key })?.text == editor.string { dirtyKeys.remove(key) }
        else { dirtyKeys.insert(key) }
        updateControls()
    }
}
