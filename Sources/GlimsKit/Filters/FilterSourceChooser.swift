import AppKit

/// One selectable height-map source offered to the Bump Map filter: the
/// engine's source ID and its display name.
@MainActor
struct FilterSourceChoice: Equatable {
    let id: Int32
    let name: String
}

/// The modeless Bump Map source chooser: a popup of the offered sources
/// with a Preview/Cancel pair. Preview runs the owner's snapshot preview
/// for the selected source; its success invalidates (closes) the panel,
/// its failure keeps the selection and shows the error inline for a
/// manual retry. The panel is a nonmodal child window of the host, never
/// a sheet. All UI and callbacks run on the main actor; every async
/// completion captures `self` weakly, so no strong self cycles exist.
///
/// Refresh preserves the explicit selection — including a disabled
/// placeholder row when the selected source disappeared from the offered
/// rows — and never retargets the selection to another source. While a
/// preview runs, the popup, Preview, Cancel and window close are disabled
/// and the captured ID is immune to refreshes; an explicit invalidate
/// during that accepted work still closes the panel, and the late
/// completion then drops its result without touching the views.
@MainActor
final class FilterSourceChooserController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private weak var hostWindow: NSWindow?
    private let targetName: String
    private let preferredSource: Int32
    private let rows: () -> [FilterSourceChoice]
    private let refusal: () -> String?
    private let preview: (Int32, @escaping (Result<Void, Error>) -> Void) -> Void

    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    /// The deduplicated positive-ID rows currently offered.
    private var currentRows: [FilterSourceChoice] = []
    /// Row IDs parallel to the popup's items (including a disabled missing row).
    private var installedIDs: [Int32] = []
    /// The user's explicit selection; preserved across refreshes and never
    /// retargeted when its row disappears.
    private var selectionID: Int32?
    /// The ID captured when Preview was accepted; a refresh while running
    /// must not overwrite it.
    private var capturedPreviewID: Int32?
    private var previewRequest: UUID?
    /// Last known display name per ID, used for the disabled missing row.
    private var knownNames: [Int32: String] = [:]
    private var hasPopulated = false
    private(set) var isInvalidated = false
    private(set) var isRunning = false
    private var lastError: String?
    var onClosed: (() -> Void)?

    init(targetName: String, preferredSource: Int32,
         rows: @escaping () -> [FilterSourceChoice],
         refusal: @escaping () -> String?,
         hostWindow: NSWindow?,
         preview: @escaping (Int32, @escaping (Result<Void, Error>) -> Void) -> Void) {
        self.targetName = targetName
        self.preferredSource = preferredSource
        self.rows = rows
        self.refusal = refusal
        self.hostWindow = hostWindow
        self.preview = preview
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Bump Map Source"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    private func buildContent() {
        let targetLabel = NSTextField(labelWithString: "Target: \(targetName)")
        targetLabel.setAccessibilityLabel("Bump map target")
        targetLabel.lineBreakMode = .byWordWrapping

        let explanation = NSTextField(labelWithString:
            "Preview uses a snapshot of this source. Apply changes the target pixels; Undo restores them.")
        explanation.setAccessibilityLabel("Bump map source explanation")
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.lineBreakMode = .byWordWrapping
        explanation.maximumNumberOfLines = 3

        sourcePopup.setAccessibilityLabel("Height map source")
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged(_:))

        statusLabel.setAccessibilityLabel("Bump map source status")
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3

        previewButton.setAccessibilityLabel("Preview Bump Map")
        previewButton.keyEquivalent = "\r"
        previewButton.target = self
        previewButton.action = #selector(previewPressed(_:))
        cancelButton.setAccessibilityLabel("Cancel filter source")
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Height map:"), sourcePopup],
        ])
        grid.rowAlignment = .firstBaseline
        let buttons = NSStackView(views: [previewButton, cancelButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        let stack = NSStackView(views: [targetLabel, explanation, grid, statusLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
            sourcePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220),
            targetLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -28),
        ])
        panel.setContentSize(NSSize(width: 420, height: 260))
    }

    // MARK: Lifecycle

    /// Presents the panel as a nonmodal child of the host window (never a
    /// sheet). The first population establishes the initial selection: the
    /// preferred source when offered, else the first row.
    func show() {
        guard !isInvalidated else { return }
        if !hasPopulated { refresh() }
        if let hostWindow, panel.parent == nil {
            hostWindow.addChildWindow(panel, ordered: .above)
        }
        panel.makeKeyAndOrderFront(nil)
    }

    /// Re-reads the offered rows. The explicit selection is preserved —
    /// including a disabled placeholder row when its source vanished — and
    /// is never retargeted. While a preview runs, the captured selection is
    /// the one kept.
    func refresh() {
        guard !isInvalidated else { return }
        let fresh = Self.positiveDeduplicated(rows())
        for row in fresh { knownNames[row.id] = row.name }
        currentRows = fresh
        let isInitialPopulation = !hasPopulated
        hasPopulated = true
        if isInitialPopulation {
            if fresh.contains(where: { $0.id == preferredSource }) {
                selectionID = preferredSource
            } else {
                selectionID = fresh.first?.id
            }
        }
        installItems()
        updateControls()
    }

    /// Close cleanup, idempotent and allowed even while an accepted
    /// preview runs: the late completion then drops its result. Fires
    /// `onClosed` exactly once.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        previewRequest = nil
        panel.endEditing(for: nil)
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        let callback = onClosed
        onClosed = nil
        callback?()
    }

    // MARK: Popup

    private static func positiveDeduplicated(_ raw: [FilterSourceChoice]) -> [FilterSourceChoice] {
        var seen: Set<Int32> = []
        var out: [FilterSourceChoice] = []
        for row in raw where row.id > 0 && seen.insert(row.id).inserted {
            out.append(row)
        }
        return out
    }

    private func installItems() {
        let keep = isRunning ? (capturedPreviewID ?? selectionID) : selectionID
        sourcePopup.removeAllItems()
        installedIDs = []
        var items = currentRows
        var selectedIndex = -1
        if let keep {
            if let index = items.firstIndex(where: { $0.id == keep }) {
                selectedIndex = index
            } else {
                // The selected source is gone: keep it visible as a
                // disabled row so the selection is preserved, not retargeted.
                items.append(FilterSourceChoice(id: keep, name: knownNames[keep] ?? "Missing source"))
                selectedIndex = items.count - 1
            }
        }
        for item in items {
            // Distinct sources may share a display name. Add menu items
            // directly so NSPopUpButton cannot coalesce equal titles.
            sourcePopup.menu?.addItem(NSMenuItem(title: item.name, action: nil, keyEquivalent: ""))
            installedIDs.append(item.id)
        }
        if selectedIndex >= 0 {
            sourcePopup.selectItem(at: selectedIndex)
            let missing = !currentRows.contains(where: { $0.id == keep })
            sourcePopup.item(at: selectedIndex)?.isEnabled = !missing
        } else {
            sourcePopup.select(nil)
        }
    }

    private var selectionIsLive: Bool {
        guard let selectionID else { return false }
        return currentRows.contains { $0.id == selectionID }
    }

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        guard !isInvalidated, !isRunning else { return }
        let index = sourcePopup.indexOfSelectedItem
        guard installedIDs.indices.contains(index) else { return }
        selectionID = installedIDs[index]
        lastError = nil
        updateControls()
    }

    // MARK: Actions

    /// Preview: only a live selection with no refusal and no running work
    /// is accepted. The ID is captured before the callback; popup, Preview,
    /// Cancel and window close are disabled while it runs.
    @objc private func previewPressed(_ sender: Any?) {
        guard !isInvalidated, !isRunning, selectionIsLive, refusal() == nil,
              let id = selectionID else {
            updateControls()
            return
        }
        capturedPreviewID = id
        let request = UUID()
        previewRequest = request
        isRunning = true
        lastError = nil
        updateControls()
        preview(id) { [weak self] result in
            guard let self, !self.isInvalidated, self.previewRequest == request else { return }
            self.previewRequest = nil
            // Invalidated during the accepted work: the views are already
            // gone, so the late completion is dropped here.
            self.isRunning = false
            self.capturedPreviewID = nil
            switch result {
            case .success:
                self.invalidate()
            case .failure(let error):
                // Keep the selection; show the error, re-enable for a manual
                // retry (no native retry is attempted).
                self.lastError = error.localizedDescription
                self.updateControls()
            }
        }
    }

    /// Cancel and normal window close invalidate the chooser.
    @objc private func cancelPressed(_ sender: Any?) {
        guard !isInvalidated, !isRunning else { return }
        invalidate()
    }

    // MARK: Window delegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isRunning { return false }
        invalidate()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        invalidate()
    }

    // MARK: Control state

    private func updateControls() {
        let live = selectionIsLive
        let gate = refusal()
        sourcePopup.isEnabled = !isInvalidated && !isRunning
        previewButton.isEnabled = !isInvalidated && !isRunning && live && gate == nil
        cancelButton.isEnabled = !isInvalidated && !isRunning
        panel.standardWindowButton(.closeButton)?.isEnabled = !isInvalidated && !isRunning
        guard !isInvalidated else { return }
        if let lastError {
            statusLabel.textColor = .systemRed
            statusLabel.stringValue = lastError
        } else if isRunning {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "Previewing…"
        } else if let selectionID, !live {
            statusLabel.textColor = .secondaryLabelColor
            let name = knownNames[selectionID] ?? "The selected source"
            statusLabel.stringValue = "\(name) is no longer available. Choose another height map source, then press Preview."
        } else if let gate {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = gate
        } else if currentRows.isEmpty {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "No height map sources are available."
        } else {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = ""
        }
    }
}
