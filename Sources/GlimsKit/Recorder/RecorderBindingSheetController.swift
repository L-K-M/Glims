import AppKit

/// One document's explicit choices for a prepared recording. Native ownership
/// and role facts are checked again by ImageDocument when Load is accepted.
@MainActor
final class RecorderBindingSheetController: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {
    typealias Choice = ImageDocument.RecorderInstallChoice

    private struct Candidate {
        let choice: Choice
        let title: String
        var hasMask = false
        var inkMode: RecorderInkIdentity.Mode?
        var inkRole: RecorderInkIdentity.Role?
        var labIdentity: RecorderLabIdentity?
    }

    private let symbols: [RecorderFileValue.Symbol]
    private let maskOwners: Set<UUID>
    private let inkTargets: [UUID: RecorderInkIdentity]
    private let labTargets: [UUID: RecorderLabIdentity]
    private let layers: [Candidate]
    private let channels: [Candidate]
    private let quickMask: [Candidate]
    private var choices: [UUID: Choice] = [:]

    private let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 460),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
    private weak var parent: NSWindow?
    private let table = NSTableView()
    private let details = NSTextField(wrappingLabelWithString: "")
    private let popup = NSPopUpButton()
    private let progress = NSTextField(labelWithString: "")
    private let accept = NSButton(title: "Load Recording", target: nil, action: nil)

    init(file: RecorderFileValue, document: ImageDocument) throws {
        var required: Set<UUID> = [], masks: Set<UUID> = []
        var inks: [UUID: RecorderInkIdentity] = [:]
        var labs: [UUID: RecorderLabIdentity] = [:]
        for row in file.records {
            guard case .success(_, let binding) = row.outcome else { continue }
            required.formUnion(try RecorderFileCodec.referencedSymbols(binding))
            if case .context(let context) = binding {
                masks.formUnion(context.masks.filter(\.isPresent).map(\.owner))
            }
            if case .ink(let symbol, let identity) = binding { inks[symbol] = identity }
            if case .lab(let symbol, let identity) = binding { labs[symbol] = identity }
        }
        symbols = file.symbols.filter { required.contains($0.id) }
        maskOwners = masks
        inkTargets = inks
        labTargets = labs
        let layerRows = document.layers
        var paths: [Int32: String] = [:]
        var siblingCounts: [Int32: Int] = [:]
        layers = layerRows.enumerated().map { ordinal, row in
            let index = siblingCounts[row.parent, default: 0] + 1
            siblingCounts[row.parent] = index
            let component = "\(index). \(Self.label(row.name))"
            let full = paths[row.parent].map { Self.label($0, max: 64) + " / " + component } ?? component
            paths[row.id] = full
            return Candidate(choice: .layer(row.id), title: "\(ordinal + 1). \(full)",
                             hasMask: (document.maskStates[row.id]?.mask ?? 0) > 0)
        }
        if let axes = document.labAxes {
            channels = axes.axes.enumerated().map { index, axis in
                Candidate(choice: .channel(axis.id), title: "\(index + 1). \(Self.label(axis.name))",
                          labIdentity: try? RecorderLabIdentity(axis: axis, component: axes.component))
            }
        } else {
            channels = document.channels.filter { !$0.isQuickMask }.enumerated().map { index, row in
                var candidate = Candidate(choice: .channel(row.id), title: "\(index + 1). \(Self.label(row.name))")
                // Cached enumeration is in canonical ink-map order. These hints
                // only narrow the picker; installation re-reads identity natively.
                if document.colorInfo.mode == .cmyk {
                    let roles: [RecorderInkIdentity.Role] = [.cyan, .magenta, .yellow, .black]
                    if roles.indices.contains(index) {
                        candidate.inkMode = .cmyk
                        candidate.inkRole = roles[index]
                    }
                } else if document.colorInfo.mode == .multichannel {
                    candidate.inkMode = .multichannel
                    candidate.inkRole = .unspecified
                }
                return candidate
            }
        }
        if let mask = document.quickMaskState, mask.enabled, mask.channel > 0 {
            quickMask = [Candidate(choice: .quickMask(mask.channel), title: "Quick Mask")]
        } else { quickMask = [] }
        super.init()
        build(name: file.name, origin: file.origin, documentName: document.name)
    }

    func begin(on parent: NSWindow, completion: @escaping @MainActor ([UUID: Choice]?) -> Void) {
        self.parent = parent
        parent.beginSheet(window) { [weak self] response in
            guard let self else { return completion(nil) }
            self.parent = nil
            self.window.orderOut(nil)
            completion(response == .OK && self.isComplete ? self.choices : nil)
        }
        if symbols.isEmpty { window.makeFirstResponder(accept) }
        else {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            window.makeFirstResponder(table)
            refreshChoice()
        }
    }

    @objc func cancel() { finish(.cancel) }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        cancel()
        return false
    }

    private var isComplete: Bool {
        choices.count == symbols.count && Set(choices.values).count == choices.count
    }

    private func finish(_ response: NSApplication.ModalResponse) {
        guard let parent, parent.attachedSheet === window else { return }
        parent.endSheet(window, returnCode: response)
    }

    @objc private func load() {
        guard isComplete else { return }
        finish(.OK)
    }

    private func build(name: String, origin: RecorderFileValue.Origin, documentName: String) {
        window.title = "Bind Recording Targets"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let title = NSTextField(wrappingLabelWithString: "Load “\(Self.label(name))” into “\(Self.label(documentName))”?")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        let source = NSTextField(wrappingLabelWithString:
            "Recorded in \(Self.label(origin.imageLabel)) · \(origin.initialWidth) × \(origin.initialHeight) px")
        source.font = .systemFont(ofSize: 11)
        let instruction = NSTextField(wrappingLabelWithString: symbols.isEmpty
            ? "This recording does not require any target choices."
            : "Choose a different live target for each recorded target. No choice is made automatically.")
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        accept.target = self
        accept.action = #selector(load)
        accept.keyEquivalent = "\r"
        accept.identifier = NSUserInterfaceItemIdentifier("recorder-bind-load")
        let buttons = NSStackView(views: [cancel, accept])
        buttons.spacing = 8

        var views: [NSView] = [title, source, instruction]
        var fill: [NSView] = views
        if !symbols.isEmpty {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("target"))
            column.title = "Recorded target"
            column.resizingMask = .autoresizingMask
            table.addTableColumn(column)
            table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            table.allowsEmptySelection = false
            table.delegate = self
            table.dataSource = self
            table.identifier = NSUserInterfaceItemIdentifier("recorder-bind-symbols")
            table.setAccessibilityLabel("Recorded targets")
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 130).isActive = true
            details.font = .systemFont(ofSize: 11)
            details.maximumNumberOfLines = 3
            details.setAccessibilityLabel("Recorded target details")
            popup.target = self
            popup.action = #selector(choose(_:))
            popup.identifier = NSUserInterfaceItemIdentifier("recorder-bind-choice")
            popup.setAccessibilityLabel("Live target for selected recorded target")
            views += [scroll, details, popup, progress]
            fill += [scroll, details, popup]
        }
        views.append(buttons)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18)
        ])
        for view in fill { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        if symbols.isEmpty { window.setContentSize(NSSize(width: 560, height: 185)) }
        window.contentView = content
        accept.isEnabled = isComplete
    }

    func numberOfRows(in tableView: NSTableView) -> Int { symbols.count }

    func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("recorded-target-row")
        let label = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField
            ?? NSTextField(labelWithString: "")
        label.identifier = id
        label.lineBreakMode = .byTruncatingTail
        let symbol = symbols[row]
        label.stringValue = "\(row + 1). \(Self.label(symbol.description.name)) · \(role(symbol))"
            + (choices[symbol.id] == nil ? " · Choose" : " · Bound")
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) { refreshChoice() }

    @objc private func choose(_ sender: NSPopUpButton) {
        guard symbols.indices.contains(table.selectedRow) else { return }
        let row = table.selectedRow
        let symbol = symbols[row]
        choices[symbol.id] = sender.selectedItem?.representedObject as? Choice
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
        refreshChoice()
    }

    private func refreshChoice() {
        guard symbols.indices.contains(table.selectedRow) else { return }
        let symbol = symbols[table.selectedRow]
        let descriptor = symbol.description
        let ancestry = descriptor.ancestors.prefix(6).map { Self.label($0.name, max: 40) }.joined(separator: " / ")
        let bounds = descriptor.bounds
        details.stringValue = "\(role(symbol)) · \(bounds.width) × \(bounds.height) px"
            + (ancestry.isEmpty ? "" : "\nOriginal group: \(ancestry)")
        let candidates: [Candidate]
        if let ink = inkTargets[symbol.id] {
            candidates = channels.filter { $0.inkMode == ink.mode && $0.inkRole == ink.role }
            details.stringValue += "\nChoose the destination ink explicitly. Select it before replay."
        } else if let lab = labTargets[symbol.id] {
            candidates = channels.filter { $0.labIdentity.map { lab.permitsExplicitBinding(to: $0) } == true }
            details.stringValue += "\nChoose the matching Lab axis explicitly. Select it before replay."
        } else {
            switch descriptor.kind {
            case .channel: candidates = channels
            case .quickMask: candidates = quickMask
            default: candidates = maskOwners.contains(symbol.id) ? layers.filter(\.hasMask) : layers
            }
        }
        let assignedElsewhere = Set(choices.filter { $0.key != symbol.id }.values)
        let available = candidates.filter { !assignedElsewhere.contains($0.choice) }
        popup.removeAllItems()
        popup.addItem(withTitle: available.isEmpty ? "No unused live target" : "Choose a live target…")
        // AppKit can combine items added by title. The represented choice,
        // rather than an index derived from the displayed label, owns identity.
        for candidate in available {
            let item = NSMenuItem(title: candidate.title, action: nil, keyEquivalent: "")
            item.representedObject = candidate.choice
            popup.menu?.addItem(item)
        }
        let selected = choices[symbol.id]
        let index = popup.itemArray.firstIndex { ($0.representedObject as? Choice) == selected } ?? 0
        popup.selectItem(at: index)
        popup.isEnabled = !available.isEmpty
        progress.stringValue = "\(choices.count) of \(symbols.count) targets bound"
        accept.isEnabled = isComplete
    }

    private func role(_ symbol: RecorderFileValue.Symbol) -> String {
        if let ink = inkTargets[symbol.id] { return ink.targetTitle }
        if let lab = labTargets[symbol.id] { return lab.targetTitle }
        if maskOwners.contains(symbol.id) { return "Layer with mask" }
        switch symbol.description.kind {
        case .pixel: return "Pixel layer"
        case .group: return "Layer group"
        case .text: return "Text layer"
        case .link: return "Link layer"
        case .vector: return "Vector layer"
        case .channel: return "Channel"
        case .quickMask: return "Quick Mask"
        }
    }

    private static func label(_ value: String, max: Int = 90) -> String {
        let prefix = String(value.prefix(max))
        let singleLine = prefix.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\t", with: " ")
        return singleLine.isEmpty ? "Untitled" : singleLine
    }
}
