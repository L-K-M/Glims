import AppKit

/// Captured-resource child panel. Accepted work and reference migration belong
/// to the document queue; closing a view cannot cancel or retarget that work.
@MainActor
final class ResourceMutationFormController: NSObject, NSWindowDelegate {
    private final class Reference { weak var value: ResourceMutationFormController?; init(_ value: ResourceMutationFormController) { self.value = value } }
    private static var forms: [Reference] = []
    static func documentStateChanged(_ document: ImageDocument) {
        forms.removeAll { $0.value == nil }
        for form in forms.compactMap(\.value) where form.document === document { form.updateControls() }
        ResourceManagementControls.documentStateChanged(document)
    }
    static func documentWindowClosing(_ document: ImageDocument) {
        for form in forms.compactMap(\.value) where form.document === document { form.invalidate() }
        ResourceManagementControls.documentWindowClosing(document)
    }
    let document: ImageDocument
    let source: ResourceDuplicateValidation.Source
    let isDelete: Bool
    let panel: NSPanel
    private weak var hostWindow: NSWindow?
    private let nameField = NSTextField(string: "")
    private let message = NSTextField(wrappingLabelWithString: "Loading resource capabilities…")
    private let applyButton = NSButton(title: "", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Refresh", target: nil, action: nil)
    private(set) var info: EngineSession.ResourceMutationInfo?
    private(set) var isInvalidated = false
    private(set) var isRunning = false
    private(set) var lastError: String?
    private var completed = false
    private var loading = false
    var onClosed: (() -> Void)?

    init(document: ImageDocument, source: ResourceDuplicateValidation.Source,
         delete: Bool, hostWindow: NSWindow?) {
        self.document = document; self.source = source; self.isDelete = delete; self.hostWindow = hostWindow
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 230),
                        styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        super.init()
        let verb = delete ? "Delete" : "Rename"
        panel.title = "\(verb) \(source.kind.singular.capitalized)"
        panel.isReleasedWhenClosed = false; panel.delegate = self
        let title = NSTextField(wrappingLabelWithString: delete
            ? "Delete “\(source.name)” permanently? This removes the saved resource. Image Undo cannot restore it."
            : "Rename “\(source.name)”")
        nameField.stringValue = source.name; nameField.isHidden = delete
        nameField.setAccessibilityLabel("Resource name")
        nameField.target = self; nameField.action = #selector(validateDraft(_:))
        NotificationCenter.default.addObserver(self, selector: #selector(validateDraft(_:)), name: NSControl.textDidChangeNotification, object: nameField)
        message.textColor = .secondaryLabelColor
        applyButton.title = verb; applyButton.target = self; applyButton.action = #selector(apply(_:))
        applyButton.setAccessibilityLabel("\(verb) saved resource")
        cancelButton.target = self; cancelButton.action = #selector(cancel(_:)); cancelButton.keyEquivalent = "\u{1b}"
        if !delete { applyButton.keyEquivalent = "\r" }
        refreshButton.target = self; refreshButton.action = #selector(refresh(_:))
        refreshButton.setAccessibilityLabel("Refresh resource capabilities")
        refreshButton.toolTip = "Read this resource again before retrying. The name draft is preserved."
        let buttons = NSStackView(views: [refreshButton, cancelButton, applyButton]); buttons.orientation = .horizontal
        let stack = NSStackView(views: [title, nameField, message, buttons]); stack.orientation = .vertical
        stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView { NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -18),
            nameField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            message.widthAnchor.constraint(equalTo: stack.widthAnchor)]) }
        Self.forms.removeAll { $0.value == nil }; Self.forms.append(Reference(self))
        loadInfo()
    }
    private func loadInfo() {
        guard !isInvalidated, !isRunning, !completed, !loading else { return }
        loading = true; info = nil; lastError = nil; updateControls()
        document.loadResourceMutationInfo(source: source) { [weak self] result in
            guard let self, !self.isInvalidated else { return }
            self.loading = false
            switch result {
            case .success(let info): self.info = info
            case .failure(let error): self.lastError = String(describing: error)
            }
            self.updateControls()
        }
    }
    @objc private func refresh(_ sender: Any?) { loadInfo() }
    func show() {
        guard !isInvalidated else { return }
        if let hostWindow, panel.parent == nil { hostWindow.addChildWindow(panel, ordered: .above) }
        panel.makeKeyAndOrderFront(nil)
        if !isDelete { panel.makeFirstResponder(nameField); nameField.selectText(nil) }
    }
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        NotificationCenter.default.removeObserver(self)
        panel.parent?.removeChildWindow(panel); panel.orderOut(nil)
        let callback = onClosed; onClosed = nil; callback?()
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { if isRunning { return false }; invalidate(); return true }
    func windowWillClose(_ notification: Notification) { invalidate() }
    @objc private func cancel(_ sender: Any?) { guard !isRunning else { return }; invalidate() }
    @objc private func validateDraft(_ sender: Any?) { lastError = nil; updateControls() }
    private func updateControls() {
        guard !isInvalidated else { return }
        let allowed = isDelete ? info?.canDelete == true : info?.canRename == true
        var gate = info?.reason ?? document.resourceMutationRefusal()
        if !isDelete && gate == nil {
            do { try EngineSession.validateResourceName(nameField.stringValue) }
            catch { gate = String(describing: error) }
        }
        message.stringValue = lastError ?? gate ?? (info == nil ? (loading ? "Loading resource capabilities…" : "Refresh to read resource capabilities again.") : "")
        applyButton.isEnabled = allowed && gate == nil && !isRunning && !completed
        cancelButton.isEnabled = !isRunning; cancelButton.title = completed ? "Done" : "Cancel"
        nameField.isEnabled = !isRunning && !completed
        refreshButton.isEnabled = !isRunning && !completed && !loading && !document.isClosing
    }
    @objc private func apply(_ sender: Any?) {
        guard !isInvalidated, !isRunning, !completed, let token = info?.guardToken,
              (isDelete ? info?.canDelete == true : info?.canRename == true),
              document.resourceMutationRefusal() == nil else { updateControls(); return }
        let action: ResourceMutationAction = isDelete ? .delete : .rename(nameField.stringValue)
        isRunning = true; lastError = nil; updateControls()
        let source = self.source
        document.mutateResource(source: source, guardToken: token, action: action, onCommitted: { outcome in
            guard let identity = outcome.renamedIdentity else { return nil }
            return ResourceReferenceMigration.renamed(source: source, identity: identity)
        }) { [weak self] result in
            guard let self, !self.isInvalidated else { return }
            self.isRunning = false
            switch result {
            case .success(let outcome):
                if let warning = outcome.warning { self.completed = true; self.lastError = warning; self.updateControls() }
                else { self.invalidate() }
            case .failure(let error): self.lastError = String(describing: error); self.updateControls()
            }
        }
    }
}
