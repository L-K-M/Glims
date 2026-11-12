import AppKit

/// The compact form for the owned `glims:selective-color` operation.
///
/// A Colors popup chooses which of the nine ranges the four CMYK rows
/// display; a Method popup writes the `relative` boolean. Every one of
/// the 37 properties keeps its own bound row — switching the viewed
/// range only swaps which rows are visible, so a range change writes
/// nothing, adds no history and never disturbs the other ranges, while
/// peer acknowledgements still track every property through the shared
/// `setProperty` transport. Native values are -1...1; the rows show
/// percentages -100...100 through `FilterNumberRow`'s display scale.
@MainActor
final class SelectiveColorPanel: NativeFilterPanel {
    static let operation = "glims:selective-color"
    static let relativeProperty = "relative"

    /// The nine selectable ranges, in the adjustment's display order; the raw
    /// value is the engine property prefix.
    enum ColorRange: String, CaseIterable {
        case red, yellow, green, cyan, blue, magenta, white, neutral, black

        var title: String {
            switch self {
            case .red: return "Reds"
            case .yellow: return "Yellows"
            case .green: return "Greens"
            case .cyan: return "Cyans"
            case .blue: return "Blues"
            case .magenta: return "Magentas"
            case .white: return "Whites"
            case .neutral: return "Neutrals"
            case .black: return "Blacks"
            }
        }
    }

    /// The four CMYK correction channels each range offers; the raw
    /// value is the engine property suffix.
    enum Channel: String, CaseIterable {
        case cyan, magenta, yellow, black

        var title: String { rawValue.capitalized }
    }

    static func propertyName(_ range: ColorRange, _ channel: Channel) -> String {
        "\(range.rawValue)-\(channel.rawValue)"
    }

    /// The full property contract this form drives: every range/channel
    /// number plus the `relative` boolean. The dedicated layout is only
    /// built when the catalog describes exactly this set — anything else
    /// stays on the generic form.
    static func matches(_ properties: [EngineSession.FilterProperty]) -> Bool {
        let names = Set(properties.map(\.name))
        let channels = ColorRange.allCases.flatMap { range in
            Channel.allCases.map { propertyName(range, $0) }
        }
        // Exactly the owned contract: a catalog that grows or shrinks a
        // property falls back to the generic form rather than hiding it.
        guard properties.count == channels.count + 1, names.count == properties.count,
              names.isSuperset(of: channels), names.contains(relativeProperty) else { return false }
        return properties.allSatisfy { property in
            property.name == relativeProperty ? property.kind == .boolean : property.kind == .number
        }
    }

    /// The property rows of every range, ready before `super.init` runs
    /// `buildContent`, which dynamic-dispatches to this class's override.
    private var propertiesByName: [String: EngineSession.FilterProperty] = [:]
    private(set) var selectedRange = ColorRange.red
    /// Every view of a range's four rows — labels included — so hidden
    /// grid rows collapse and the window never changes size on a switch.
    private var rangeRows: [ColorRange: [NSView]] = [:]
    private var settingsGrid: NSGridView?
    /// Each channel property's bound number row, by property name.
    private(set) var channelRows: [String: FilterNumberRow] = [:]
    let colorsPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let methodPopup = NSPopUpButton(frame: .zero, pullsDown: false)

    /// The bound row of one range's channel, for tests and the layout.
    func channelRow(_ range: ColorRange, _ channel: Channel) -> FilterNumberRow? {
        channelRows[Self.propertyName(range, channel)]
    }

    init?(document imageDocument: ImageDocument,
          operation: EngineSession.FilterOperation,
          properties: [EngineSession.FilterProperty],
          filter: Int32,
          initialValues: [String: EngineSession.FilterValue]) {
        guard operation.name == Self.operation, operation.support == .supported,
              Self.matches(properties) else { return nil }
        propertiesByName = Dictionary(uniqueKeysWithValues: properties.map { ($0.name, $0) })
        super.init(document: imageDocument, operation: operation, properties: properties,
                   filter: filter, initialValues: initialValues)
    }

    /// The compact layout: a Colors row, one hidden-unless-selected
    /// four-row block per range and a Method row — every property bound
    /// through `control(for:)` exactly like the generic form.
    override func buildContent(in panel: NSPanel, properties: [EngineSession.FilterProperty]) {
        var rows: [[NSView]] = []

        colorsPopup.addItems(withTitles: ColorRange.allCases.map(\.title))
        colorsPopup.selectItem(at: selectedRange.ordinal)
        colorsPopup.target = self
        colorsPopup.action = #selector(colorsChanged(_:))
        colorsPopup.setAccessibilityLabel("Colors")
        rows.append([Self.label("Colors:"), colorsPopup])

        for range in ColorRange.allCases {
            var views: [NSView] = []
            for channel in Channel.allCases {
                guard let property = propertiesByName[Self.propertyName(range, channel)] else { continue }
                let label = Self.label("\(channel.title):")
                label.toolTip = property.blurb.isEmpty ? nil : property.blurb
                let row = control(for: property, displayScale: 100, unit: "%")
                channelRows[property.name] = row as? FilterNumberRow
                views += [label, row]
                rows.append([label, row])
            }
            rangeRows[range] = views
        }

        methodPopup.addItems(withTitles: ["Relative", "Absolute"])
        methodPopup.target = self
        methodPopup.action = #selector(methodChanged(_:))
        methodPopup.setAccessibilityLabel("Method")
        if let relative = propertiesByName[Self.relativeProperty] {
            methodPopup.toolTip = relative.blurb.isEmpty ? nil : relative.blurb
            registerBinding(relative.name) { [weak methodPopup] value in
                if case .boolean(let flag) = value { methodPopup?.selectItem(at: flag ? 0 : 1) }
            }
        }
        rows.append([Self.label("Method:"), methodPopup])

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        settingsGrid = grid
        updateRangeVisibility()

        statusField.textColor = .systemRed
        statusField.font = .systemFont(ofSize: NSFont.systemFontSize(for: .small))
        statusField.maximumNumberOfLines = 2
        statusField.lineBreakMode = .byTruncatingTail
        statusField.setAccessibilityLabel("Filter status")
        statusField.alignment = .left

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        let apply = NSButton(title: "Apply", target: self, action: #selector(apply))
        apply.keyEquivalent = "\r"
        let buttons = NSStackView(views: [NSView(), cancel, apply])
        buttons.orientation = .horizontal
        buttons.spacing = 8

        let stack = NSStackView(views: [grid, statusField, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        statusField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true

        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])
        panel.setContentSize(NSSize(width: max(420, grid.fittingSize.width + 32),
                                    height: stack.fittingSize.height))
        panel.center()
    }

    private static func label(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.alignment = .right
        return label
    }

    /// Choosing a range commits the active field's typed text first —
    /// its acknowledged write goes through the shared transport — then
    /// only swaps visible rows. No write, no history, values retained.
    @objc func colorsChanged(_ sender: NSPopUpButton) {
        guard filter != nil, ColorRange.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        let range = ColorRange.allCases[sender.indexOfSelectedItem]
        guard range != selectedRange else { return }
        window?.endEditing(for: nil)
        selectedRange = range
        updateRangeVisibility()
        window?.recalculateKeyViewLoop()
    }

    private func updateRangeVisibility() {
        for (index, range) in ColorRange.allCases.enumerated() {
            let hidden = range != selectedRange
            // Hiding only the cell views leaves every row's height in
            // NSGridView. Collapse the rows as well as hiding controls.
            for row in 0..<Channel.allCases.count {
                settingsGrid?.row(at: 1 + index * Channel.allCases.count + row).isHidden = hidden
            }
            for view in rangeRows[range] ?? [] { view.isHidden = hidden }
        }
    }

    /// Method commits the active field first as well, then writes the
    /// `relative` boolean through the same property transport.
    @objc func methodChanged(_ sender: NSPopUpButton) {
        guard filter != nil else { return }
        window?.endEditing(for: nil)
        setProperty(Self.relativeProperty, .boolean(sender.indexOfSelectedItem == 0))
    }
}

private extension SelectiveColorPanel.ColorRange {
    var ordinal: Int { Self.allCases.firstIndex(of: self)! }
}

extension NativeFilterPanel {
    /// The dedicated compact editor when `operation` is the owned
    /// selective-color operation and its property contract is complete;
    /// the generic property form otherwise.
    static func parameterPanel(document: ImageDocument,
                               operation: EngineSession.FilterOperation,
                               properties: [EngineSession.FilterProperty],
                               filter: Int32,
                               initialValues: [String: EngineSession.FilterValue]) -> NativeFilterPanel? {
        if NativeFilterMenuLayout.usesSelectiveColorEditor(operation),
           let panel = SelectiveColorPanel(document: document, operation: operation,
                                           properties: properties, filter: filter,
                                           initialValues: initialValues) {
            return panel
        }
        return NativeFilterPanel(document: document, operation: operation,
                                 properties: properties, filter: filter,
                                 initialValues: initialValues)
    }
}
