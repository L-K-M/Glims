import AppKit

/// Operations admitted by the facade's captured-source contracts.
enum SourceFilterOperation: String, Sendable {
    case bumpMap = "gegl:bump-map"
    case variableBlur = "gegl:variable-blur"
    case selectiveGaussianBlur = "gegl:gaussian-blur-selective"
    case negativeDarkroom = "gegl:negative-darkroom"
    case displace = "gegl:displace"
    case oilify = "gegl:oilify"

    var title: String {
        switch self {
        case .bumpMap: return "Bump Map"
        case .variableBlur: return "Variable Blur"
        case .selectiveGaussianBlur: return "Selective Gaussian Blur"
        case .negativeDarkroom: return "Negative Darkroom"
        case .displace: return "Displace"
        case .oilify: return "Oilify"
        }
    }

    var accessibilityName: String {
        switch self {
        case .bumpMap: return "Bump map"
        case .variableBlur: return "Variable blur"
        case .selectiveGaussianBlur: return "Selective Gaussian blur"
        case .negativeDarkroom: return "Negative darkroom"
        case .displace: return "Displace"
        case .oilify: return "Oilify"
        }
    }

    var sourceExplanation: String {
        if self == .displace {
            return "Preview uses snapshots of both maps. Apply changes the target pixels; Undo restores them. Set an axis amount to zero to disable it."
        }
        if self == .negativeDarkroom {
            return "Preview uses a snapshot of this source. Apply makes filtered pixels opaque; Undo restores them."
        }
        if self == .oilify {
            return "Preview uses snapshots of the optional maps. Apply changes the target pixels."
        }
        return "Preview uses a snapshot of this source. Apply changes the target pixels; Undo restores them."
    }

    var sourceLabel: String {
        switch self {
        case .bumpMap: return "Height map"
        case .variableBlur: return "Blur mask"
        case .selectiveGaussianBlur: return "Contrast reference"
        case .negativeDarkroom: return "Dodge/burn map"
        case .displace: return "Horizontal / radial map"
        case .oilify: return "Radius map"
        }
    }

    var secondSourceLabel: String? {
        switch self {
        case .displace: return "Vertical / angular map"
        case .oilify: return "Exponent map"
        default: return nil
        }
    }
}

/// One selectable source offered to a captured-source filter: the
/// engine's source ID and its display name.
@MainActor
struct FilterSourceChoice: Equatable {
    let id: Int32
    let name: String
}

/// The modeless source chooser presents the offered sources in role-specific
/// popups. Preview starts the owner's snapshot preview for the chosen
/// sources. Success closes the panel,
/// its failure keeps the selection and shows the error inline for a
/// manual retry. The panel is a nonmodal child window of the host, never
/// a sheet. All UI and callbacks run on the main actor; every async
/// completion captures `self` weakly, so no strong self cycles exist.
///
/// Refresh preserves the explicit selection — including a disabled
/// placeholder row when the selected source disappeared from the offered
/// rows — and never retargets the selection to another source. While a
/// preview runs, the popup, Preview, Cancel and window close are disabled
/// and the captured choices are immune to refreshes. An explicit invalidate
/// during that accepted work still closes the panel, and the late
/// completion then drops its result without touching the views.
@MainActor
final class FilterSourceChooserController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private weak var hostWindow: NSWindow?
    private let targetName: String
    private let preferredSource: Int32
    /// Cached identity lets the owner replace a chooser for another filter.
    let operation: SourceFilterOperation
    private let rows: () -> [FilterSourceChoice]
    private let refusal: () -> String?
    private enum PreviewHandler {
        case single((Int32, @escaping (Result<Void, Error>) -> Void) -> Void)
        case displace((Int32, Int32, @escaping (Result<Void, Error>) -> Void) -> Void)
        case oilify((Int32?, Int32?, @escaping (Result<Void, Error>) -> Void) -> Void)
    }
    private let previewHandler: PreviewHandler
    private var hasSecondSource: Bool { operation.secondSourceLabel != nil }
    private var mapsAreOptional: Bool { operation == .oilify }

    private let sourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let secondSourcePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let previewButton = NSButton(title: "Preview", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    /// The deduplicated positive-ID rows currently offered.
    private var currentRows: [FilterSourceChoice] = []
    /// Row IDs parallel to the popup's items. Zero represents None.
    private var installedIDs: [Int32] = []
    private var secondInstalledIDs: [Int32] = []
    /// The user's explicit selection; preserved across refreshes and never
    /// retargeted when its row disappears.
    private var selectionID: Int32?
    private var secondSelectionID: Int32?
    /// Choices captured when Preview was accepted, including absent maps.
    private var capturedPreviewID: Int32?
    private var capturedSecondPreviewID: Int32?
    private var previewRequest: UUID?
    /// Last known display name per ID, used for the disabled missing row.
    private var knownNames: [Int32: String] = [:]
    private var hasPopulated = false
    private(set) var isInvalidated = false
    private(set) var isRunning = false
    private var lastError: String?
    var onClosed: (() -> Void)?

    /// Retains the original single-source initializer and callback contract.
    convenience init(targetName: String, preferredSource: Int32, operation: SourceFilterOperation = .bumpMap,
                     rows: @escaping () -> [FilterSourceChoice],
                     refusal: @escaping () -> String?, hostWindow: NSWindow?,
                     preview: @escaping (Int32, @escaping (Result<Void, Error>) -> Void) -> Void) {
        self.init(targetName: targetName, preferredSource: preferredSource, operation: operation,
                  rows: rows, refusal: refusal, hostWindow: hostWindow, handler: .single(preview))
    }

    /// Displace requires two independently chosen IDs. Neither role inherits a
    /// current/preferred source, including when the catalog arrives later.
    convenience init(displaceTargetName: String, rows: @escaping () -> [FilterSourceChoice],
                     refusal: @escaping () -> String?, hostWindow: NSWindow?,
                     previewDisplace: @escaping (Int32, Int32, @escaping (Result<Void, Error>) -> Void) -> Void) {
        self.init(targetName: displaceTargetName, preferredSource: 0, operation: .displace,
                  rows: rows, refusal: refusal, hostWindow: hostWindow, handler: .displace(previewDisplace))
    }

    convenience init(oilifyTargetName: String, rows: @escaping () -> [FilterSourceChoice],
                     refusal: @escaping () -> String?, hostWindow: NSWindow?,
                     previewOilify: @escaping (Int32?, Int32?, @escaping (Result<Void, Error>) -> Void) -> Void) {
        self.init(targetName: oilifyTargetName, preferredSource: 0, operation: .oilify,
                  rows: rows, refusal: refusal, hostWindow: hostWindow, handler: .oilify(previewOilify))
    }

    private init(targetName: String, preferredSource: Int32, operation: SourceFilterOperation,
                 rows: @escaping () -> [FilterSourceChoice], refusal: @escaping () -> String?,
                 hostWindow: NSWindow?, handler: PreviewHandler) {
        self.targetName = targetName
        self.preferredSource = preferredSource
        self.operation = operation
        self.rows = rows
        self.refusal = refusal
        self.hostWindow = hostWindow
        self.previewHandler = handler
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 190),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "\(operation.title) \(hasSecondSource ? "Sources" : "Source")"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        buildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    private func buildContent() {
        let targetLabel = NSTextField(labelWithString: "Target: \(targetName)")
        targetLabel.setAccessibilityLabel("\(operation.accessibilityName) target")
        targetLabel.lineBreakMode = .byWordWrapping

        let explanation = NSTextField(labelWithString: operation.sourceExplanation)
        explanation.setAccessibilityLabel("\(operation.accessibilityName) source explanation")
        explanation.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        explanation.lineBreakMode = .byWordWrapping
        explanation.maximumNumberOfLines = 3

        sourcePopup.setAccessibilityLabel("\(operation.sourceLabel) source")
        sourcePopup.target = self
        sourcePopup.action = #selector(sourceChanged(_:))
        if let label = operation.secondSourceLabel {
            secondSourcePopup.setAccessibilityLabel("\(label) source")
            secondSourcePopup.target = self
            secondSourcePopup.action = #selector(sourceChanged(_:))
        }

        statusLabel.setAccessibilityLabel("\(operation.accessibilityName) source status")
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3

        previewButton.setAccessibilityLabel("Preview \(operation.title)")
        previewButton.keyEquivalent = "\r"
        previewButton.target = self
        previewButton.action = #selector(previewPressed(_:))
        cancelButton.setAccessibilityLabel("Cancel filter source")
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed(_:))

        var sourceRows: [[NSView]] = [[NSTextField(labelWithString: "\(operation.sourceLabel):"), sourcePopup]]
        if let label = operation.secondSourceLabel {
            sourceRows.append([NSTextField(labelWithString: "\(label):"), secondSourcePopup])
        }
        let grid = NSGridView(views: sourceRows)
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
        if hasSecondSource { secondSourcePopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true }
        panel.setContentSize(NSSize(width: hasSecondSource ? 480 : 420, height: hasSecondSource ? 300 : 260))
    }

    // MARK: Lifecycle

    /// Presents the panel as a nonmodal child of the host window (never a
    /// sheet). Only single-source filters initially choose the preferred
    /// source or the first offered row.
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
        if isInitialPopulation && !hasSecondSource {
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
        let keep = isRunning ? capturedPreviewID : selectionID
        installedIDs = installItems(in: sourcePopup, keeping: keep)
        if hasSecondSource {
            let second = isRunning ? capturedSecondPreviewID : secondSelectionID
            secondInstalledIDs = installItems(in: secondSourcePopup, keeping: second)
        }
    }

    private func installItems(in popup: NSPopUpButton, keeping keep: Int32?) -> [Int32] {
        popup.removeAllItems()
        var ids: [Int32] = []
        var items = currentRows
        if mapsAreOptional { items.insert(FilterSourceChoice(id: 0, name: "None"), at: 0) }
        var selectedIndex = mapsAreOptional ? 0 : -1
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
            popup.menu?.addItem(NSMenuItem(title: item.name, action: nil, keyEquivalent: ""))
            ids.append(item.id)
        }
        if selectedIndex >= 0 {
            popup.selectItem(at: selectedIndex)
            popup.item(at: selectedIndex)?.isEnabled = selectionIsValid(keep)
        } else {
            popup.select(nil)
        }
        return ids
    }

    private func selectionIsValid(_ id: Int32?) -> Bool {
        guard let id else { return mapsAreOptional }
        return currentRows.contains { $0.id == id }
    }

    @objc private func sourceChanged(_ sender: NSPopUpButton) {
        guard !isInvalidated, !isRunning else { return }
        let index = sender.indexOfSelectedItem
        if hasSecondSource && sender === secondSourcePopup {
            guard secondInstalledIDs.indices.contains(index) else { return }
            let id = secondInstalledIDs[index]
            secondSelectionID = id == 0 ? nil : id
        } else {
            guard sender === sourcePopup, installedIDs.indices.contains(index) else { return }
            let id = installedIDs[index]
            selectionID = id == 0 ? nil : id
        }
        lastError = nil
        updateControls()
    }

    // MARK: Actions

    /// Capture the valid choices before starting the request. The popups,
    /// Preview, Cancel and window close are disabled while it runs.
    @objc private func previewPressed(_ sender: Any?) {
        guard !isInvalidated, !isRunning, selectionIsValid(selectionID),
              !hasSecondSource || selectionIsValid(secondSelectionID), refusal() == nil else {
            updateControls()
            return
        }
        let send: (@escaping (Result<Void, Error>) -> Void) -> Void
        switch previewHandler {
        case .single(let action):
            guard let id = selectionID else { return }
            send = { reply in action(id, reply) }
        case .displace(let action):
            guard let id = selectionID, let second = secondSelectionID else { return }
            send = { reply in action(id, second, reply) }
        case .oilify(let action):
            send = { [radius = selectionID, exponent = secondSelectionID] reply in action(radius, exponent, reply) }
        }
        capturedPreviewID = selectionID
        capturedSecondPreviewID = secondSelectionID
        let request = UUID()
        previewRequest = request
        isRunning = true
        lastError = nil
        updateControls()
        send { [weak self] result in
            guard let self, !self.isInvalidated, self.previewRequest == request else { return }
            self.previewRequest = nil
            // Invalidated during the accepted work: the views are already
            // gone, so the late completion is dropped here.
            self.isRunning = false
            self.capturedPreviewID = nil
            self.capturedSecondPreviewID = nil
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
        let live = selectionIsValid(selectionID)
        let secondLive = selectionIsValid(secondSelectionID)
        let gate = refusal()
        sourcePopup.isEnabled = !isInvalidated && !isRunning
        secondSourcePopup.isEnabled = !isInvalidated && !isRunning
        previewButton.isEnabled = !isInvalidated && !isRunning && live
            && (!hasSecondSource || secondLive) && gate == nil
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
            statusLabel.stringValue = "\(name) is no longer available. Choose another \(operation.sourceLabel.lowercased()) source, then press Preview."
        } else if let label = operation.secondSourceLabel, let secondSelectionID, !secondLive {
            statusLabel.textColor = .secondaryLabelColor
            let name = knownNames[secondSelectionID] ?? "The selected source"
            statusLabel.stringValue = "\(name) is no longer available. Choose another \(label.lowercased()) source, then press Preview."
        } else if let gate {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = gate
        } else if currentRows.isEmpty && !mapsAreOptional {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = "No \(operation.sourceLabel.lowercased()) sources are available."
        } else {
            statusLabel.textColor = .secondaryLabelColor
            statusLabel.stringValue = hasSecondSource && (!live || !secondLive)
                ? "Choose both map sources, then press Preview." : ""
        }
    }
}
