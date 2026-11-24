import AppKit

/// The Clone tool's pattern chooser: the Fill sheet's pattern picker in a
/// small panel with Choose and Cancel. It edits the one current pattern
/// (`ToolState.patternStore`), which Edit ▸ Fill and Clone's Pattern
/// source share, as an editor's defined pattern is shared by its fill and
/// its pattern stamp.
///
/// The panel captures the document at open, so a retarget cannot redirect
/// its catalog load. Choosing writes only the pattern choice; Cancel,
/// closing the window, a retarget, the palette going away and the
/// document closing write nothing.
@MainActor
final class ClonePatternChooser {
    static let shared = ClonePatternChooser()

    private var panel: ClonePatternChooserPanel?
    var isOpen: Bool { panel != nil }

    private init() {}

    func open(document: ImageDocument) {
        close()
        let panel = ClonePatternChooserPanel(document: document)
        panel.onClosed = { [weak self, weak panel] in
            guard let self, self.panel === panel else { return }
            self.panel = nil
        }
        self.panel = panel
        panel.showWindow(nil)
        panel.window?.makeKeyAndOrderFront(nil)
        panel.load()
    }

    /// Closes and releases the chooser without writing a choice.
    func close() {
        panel?.dismiss()
    }

    /// The open panel, for the smoke test.
    var openPanel: ClonePatternChooserPanel? { panel }
}

@MainActor
final class ClonePatternChooserPanel: NSWindowController, NSWindowDelegate {
    let picker: PatternFillPicker
    var onClosed: (() -> Void)?
    private var closed = false

    init(document: ImageDocument) {
        picker = PatternFillPicker(document: document, currentIdentity: ToolState.shared.patternStore.identity)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 320),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Pattern"
        super.init(window: panel)
        panel.delegate = self
        picker.onAbandoned = { [weak self] in self?.dismiss() }
        buildContent(in: panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func buildContent(in panel: NSPanel) {
        let note = NSTextField(wrappingLabelWithString: "Edit ▸ Fill uses the same pattern.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let choose = NSButton(title: "Choose", target: self, action: #selector(choose(_:)))
        choose.keyEquivalent = "\r"
        let buttons = NSStackView(views: [cancel, choose])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [picker.view, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        panel.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            note.leadingAnchor.constraint(equalTo: picker.view.leadingAnchor),
        ])
    }

    func load() {
        picker.load()
    }

    /// Writes the highlighted pattern, or the current one if it still
    /// resolves, and closes. With neither, nothing is written and the panel
    /// stays open.
    @objc func choose(_ sender: Any?) {
        guard !closed else { return }
        guard let identity = picker.model.pendingIdentity() else {
            NSSound.beep()
            return
        }
        ToolState.shared.patternStore.set(identity)
        dismiss()
        ToolState.shared.notifyChange()
    }

    @objc private func cancel(_ sender: Any?) {
        dismiss()
    }

    func dismiss() {
        guard !closed else { return }
        closed = true
        picker.invalidate()
        window?.orderOut(nil)
        onClosed?()
    }

    func windowWillClose(_ notification: Notification) {
        dismiss()
    }
}
