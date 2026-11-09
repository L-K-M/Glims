import AppKit

/// Shared chooser controls: cached capability validation and generation-checked
/// background reads; no native call while AppKit validates or draws a control.
@MainActor
final class ResourceManagementControls: NSStackView {
    typealias Source = ResourceDuplicateValidation.Source
    private final class Reference { weak var value: ResourceManagementControls?; init(_ value: ResourceManagementControls) { self.value = value } }
    private static var instances: [Reference] = []
    static func documentStateChanged(_ document: ImageDocument) {
        instances.removeAll { $0.value == nil }
        for controls in instances.compactMap(\.value) where controls.document() === document { controls.update() }
    }
    static func documentWindowClosing(_ document: ImageDocument) {
        for controls in instances.compactMap(\.value) where controls.document() === document { controls.invalidate() }
    }
    private let document: () -> ImageDocument?
    private let source: () -> Source?
    private let hostWindow: () -> NSWindow?
    private let changed: (ResourceCatalogChanges.Change) -> Void
    private let renameButton = NSButton(title: "Rename…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete…", target: nil, action: nil)
    private let retryButton = NSButton(title: "Retry", target: nil, action: nil)
    private var captured: Source?
    private var info: EngineSession.ResourceMutationInfo?
    private var generation = 0
    private var loading = false
    private var invalidated = false
    private var readFailed = false
    private(set) var form: ResourceMutationFormController?

    init(document: @escaping () -> ImageDocument?, source: @escaping () -> Source?,
         hostWindow: @escaping () -> NSWindow?,
         onCatalogChanged: @escaping (ResourceCatalogChanges.Change) -> Void) {
        self.document = document; self.source = source; self.hostWindow = hostWindow; self.changed = onCatalogChanged
        super.init(frame: .zero)
        orientation = .horizontal; spacing = 6
        renameButton.target = self; renameButton.action = #selector(rename(_:))
        deleteButton.target = self; deleteButton.action = #selector(delete(_:))
        renameButton.setAccessibilityLabel("Rename selected resource")
        deleteButton.setAccessibilityLabel("Delete selected resource")
        retryButton.target = self; retryButton.action = #selector(retry(_:))
        retryButton.setAccessibilityLabel("Retry resource capabilities")
        addArrangedSubview(renameButton); addArrangedSubview(deleteButton); addArrangedSubview(retryButton)
        Self.instances.removeAll { $0.value == nil }; Self.instances.append(Reference(self))
        ResourceCatalogChanges.observe(owner: self) { [weak self] change in
            guard let self, !self.invalidated else { return }
            self.changed(change)
            self.generation += 1; self.captured = nil; self.info = nil; self.loading = false; self.readFailed = false
            self.update()
        }
        updateButtons()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    func update() {
        guard !invalidated else { return }
        let next = source()
        if next != captured {
            generation += 1; captured = next; info = nil; loading = false; readFailed = false
        }
        updateButtons()
        guard !loading, info == nil, let captured, let document = document(), !document.isClosing else { return }
        loading = true; let ticket = generation
        document.loadResourceMutationInfo(source: captured) { [weak self] result in
            guard let self, !self.invalidated, self.generation == ticket, self.captured == captured else { return }
            self.loading = false
            switch result {
            case .success(let info): self.info = info; self.readFailed = false
            case .failure(let error): self.info = .init(flags: 0, guardToken: nil, reason: String(describing: error)); self.readFailed = true
            }
            self.updateButtons()
        }
    }
    private func updateButtons() {
        let gate = document()?.resourceMutationRefusal()
        let available = !invalidated && captured != nil && document()?.isClosing == false && gate == nil
        renameButton.isEnabled = available && info?.canRename == true
        deleteButton.isEnabled = available && info?.canDelete == true
        retryButton.isHidden = !readFailed
        retryButton.isEnabled = available && !loading
        let hint = captured == nil ? "Select a saved resource." : (gate ?? info?.reason ?? (info == nil ? "Checking the selected resource…" : nil))
        renameButton.toolTip = hint; deleteButton.toolTip = hint
    }
    @objc private func retry(_ sender: Any?) {
        guard !invalidated, !loading, readFailed else { return }
        generation += 1; info = nil; readFailed = false; update()
    }
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true; generation += 1; form?.invalidate(); form = nil; updateButtons()
    }
    @objc private func rename(_ sender: Any?) { show(delete: false) }
    @objc private func delete(_ sender: Any?) { show(delete: true) }
    private func show(delete: Bool) {
        guard !invalidated, let document = document(), !document.isClosing,
              let selected = source(), selected == captured,
              (delete ? info?.canDelete == true : info?.canRename == true),
              document.resourceMutationRefusal() == nil else { update(); return }
        if let form, !form.isInvalidated { form.show(); return }
        let created = ResourceMutationFormController(document: document, source: selected,
                                                      delete: delete, hostWindow: hostWindow())
        created.onClosed = { [weak self] in self?.form = nil }
        form = created; created.show()
    }
}
