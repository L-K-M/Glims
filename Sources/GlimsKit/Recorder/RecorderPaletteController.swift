import AppKit
import RigiUI

/// The front image's supported semantic commands. Recorder notifications have
/// their own removable subscription; image state and error callbacks stay owned
/// by the document window and its callers.
@MainActor
final class RecorderPaletteController: NSViewController, PaletteContent, NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.recorder"), title: "Recorder",
        contentSize: NSSize(width: 330, height: 460),
        sizing: .resizable(minimumContentSize: NSSize(width: 310, height: 430)),
        frameAutosaveName: "Glims.palette.recorder")

    private weak var document: ImageDocument?
    private var observerToken: UUID?
    private var observationGeneration = UUID()
    private let currentDocument: @MainActor () -> ImageDocument?
    private let performAction: @MainActor (RecorderPaletteAction, ImageDocument) throws -> Void
    private let table = NSTableView()
    private let documentLabel = NSTextField(labelWithString: "")
    private let recordingLabel = NSTextField(labelWithString: "")
    private let pendingLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private var actionButtons: [RecorderPaletteAction: NSButton] = [:]
    private var displayed = RecorderPalettePresentation(document: nil)
    private var actionError: String?

    init(currentDocument: @escaping @MainActor () -> ImageDocument? = {
        (NSApp.mainWindow?.windowController as? DocumentWindowController)?.imageDocument
    }, performAction: @escaping @MainActor (RecorderPaletteAction, ImageDocument) throws -> Void = {
        try $0.perform(on: $1)
    }) {
        self.currentDocument = currentDocument
        self.performAction = performAction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        let token = observerToken
        let target = document
        Task { @MainActor [weak target] in
            if let token { target?.removeRecorderObserver(token) }
        }
    }

    override func loadView() {
        documentLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        documentLabel.lineBreakMode = .byTruncatingTail
        documentLabel.setAccessibilityLabel("Recorder image")
        recordingLabel.font = .systemFont(ofSize: 11)
        recordingLabel.lineBreakMode = .byTruncatingTail
        recordingLabel.setAccessibilityLabel("Recording name and save state")
        let coverage = NSTextField(wrappingLabelWithString: RecorderPalettePresentation.coverage)
        coverage.font = .systemFont(ofSize: 11)
        coverage.setAccessibilityLabel("Supported Recorder actions")
        let policy = NSTextField(wrappingLabelWithString: RecorderPalettePresentation.replayPolicy)
        policy.font = .systemFont(ofSize: 11)
        policy.setAccessibilityLabel("Recorder replay behavior")
        pendingLabel.font = .systemFont(ofSize: 11)
        pendingLabel.setAccessibilityLabel("Recorder pending commands")
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setAccessibilityLabel("Recorder status")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = true
        table.setAccessibilityLabel("Recorded commands in acceptance order")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 60).isActive = true

        for action in RecorderPaletteAction.allCases {
            let button = NSButton(title: action.title, target: self, action: #selector(buttonPressed(_:)))
            button.tag = action.rawValue
            button.setAccessibilityLabel("Recorder \(action.title)")
            actionButtons[action] = button
        }
        let firstRow = NSStackView(views: [RecorderPaletteAction.record, .stop, .replay].compactMap { actionButtons[$0] })
        let secondRow = NSStackView(views: [RecorderPaletteAction.cancelReplay, .clear].compactMap { actionButtons[$0] })
        let fileRow = NSStackView(views: [RecorderPaletteAction.saveRecording, .loadRecording].compactMap { actionButtons[$0] })
        let recordingHeader = NSStackView(views: [recordingLabel])
        if let nameButton = actionButtons[.nameRecording] { recordingHeader.addArrangedSubview(nameButton) }
        recordingLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        firstRow.spacing = 6
        secondRow.spacing = 6
        fileRow.spacing = 6
        let stack = NSStackView(views: [documentLabel, recordingHeader, coverage, policy, scroll, pendingLabel, statusLabel, firstRow, secondRow, fileRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let fullWidthViews: [NSView] = [documentLabel, recordingHeader, coverage, policy, scroll, pendingLabel, statusLabel]
        for child in fullWidthViews {
            child.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
        }
        view = stack
        reload()
    }

    var paletteInitialFirstResponder: NSView? {
        for action in RecorderPaletteAction.allCases {
            if let button = actionButtons[action], button.isEnabled { return button }
        }
        return table
    }

    var paletteMenu: NSMenu? {
        let menu = NSMenu(title: "Recorder")
        for action in RecorderPaletteAction.allCases {
            let item = NSMenuItem(title: action.title, action: #selector(menuPressed(_:)), keyEquivalent: "")
            item.tag = action.rawValue
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard menuItem.action == #selector(menuPressed(_:)),
              let action = RecorderPaletteAction(rawValue: menuItem.tag) else { return true }
        guard document === currentDocument() else { return false }
        return RecorderPalettePresentation(document: document).canPerform(action)
    }

    func retarget(to target: ImageDocument?) {
        if document === target { reload(); return }
        if let observerToken { document?.removeRecorderObserver(observerToken) }
        observerToken = nil
        observationGeneration = UUID()
        document = target
        actionError = nil
        if let target {
            let generation = observationGeneration
            observerToken = target.addRecorderObserver(scope: .presentation) { [weak self, weak target] in
                guard let self, let target, self.observationGeneration == generation,
                      self.document === target else { return }
                let current = self.currentDocument()
                guard current === target else { self.retarget(to: current); return }
                self.reload()
            }
        }
        reload()
        if isViewLoaded { table.deselectAll(nil) }
    }

    /// Each command resolves the front document again. A stale palette click
    /// refreshes its target and asks for another explicit click.
    func perform(_ action: RecorderPaletteAction) {
        let current = currentDocument()
        guard document === current else {
            retarget(to: current)
            actionError = "The active image changed. Choose the Recorder command again."
            reload()
            return
        }
        let presentation = RecorderPalettePresentation(document: current)
        guard let current, presentation.canPerform(action) else {
            actionError = presentation.refusal(for: action) ?? "Open an image to use Recorder."
            reload()
            return
        }
        actionError = nil
        do {
            try performAction(action, current)
        } catch { actionError = RecorderPalettePresentation.message(for: error) }
        reload()
    }

    func reload() {
        displayed = RecorderPalettePresentation(document: document, actionError: actionError)
        guard isViewLoaded else { return }
        documentLabel.stringValue = displayed.documentName
        documentLabel.toolTip = displayed.documentName
        recordingLabel.stringValue = displayed.recordingName
        recordingLabel.toolTip = displayed.recordingName
        pendingLabel.stringValue = displayed.pendingText
        statusLabel.stringValue = displayed.status
        statusLabel.toolTip = displayed.status
        for action in RecorderPaletteAction.allCases {
            actionButtons[action]?.isEnabled = displayed.canPerform(action)
            actionButtons[action]?.toolTip = displayed.refusal(for: action) ?? Self.help(for: action)
        }
        table.reloadData()
        if let focused = view.window?.firstResponder as? NSButton, !focused.isEnabled,
           actionButtons.values.contains(where: { $0 === focused }) {
            view.window?.makeFirstResponder(paletteInitialFirstResponder)
        }
    }

    @objc private func buttonPressed(_ sender: NSButton) {
        guard let action = RecorderPaletteAction(rawValue: sender.tag) else { return }
        perform(action)
    }

    @objc private func menuPressed(_ sender: NSMenuItem) {
        guard let action = RecorderPaletteAction(rawValue: sender.tag) else { return }
        perform(action)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { displayed.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard displayed.rows.indices.contains(row) else { return nil }
        let text = displayed.rows[row].text
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 11)
        field.lineBreakMode = .byTruncatingTail
        field.setAccessibilityLabel(text)
        field.toolTip = text
        return field
    }

    private static func help(for action: RecorderPaletteAction) -> String {
        switch action {
        case .record: return "Start a new recording, replacing this image's recorded commands."
        case .stop: return "Stop recording. Accepted commands remain pending until they finish."
        case .replay: return "Replay supported commands in this image with their normal Undo behavior. Earlier changes remain if a later command fails."
        case .cancelReplay: return "Stop replay after any command already running."
        case .clear: return "Remove the recorded commands without editing the image."
        case .nameRecording: return "Change the recording's name without renaming a file."
        case .saveRecording: return "Save this recording and its original target descriptions."
        case .loadRecording: return "Load a recording and choose its targets in this image."
        }
    }
}
