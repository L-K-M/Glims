import AppKit
import RigiUI

/// The Channels palette body: the image's color components on top, the
/// flat channel list below them, and the channel commands at the foot.
/// The view is pure presentation over an immutable `Snapshot`: it renders
/// what it is given and reports every user gesture as a semantic `Action`
/// for the palette controller to run. It never reads the engine, never
/// starts work of its own, and never edits itself, so a snapshot update
/// can never fire an action and a click can never land on a channel the
/// snapshot no longer names.
///
/// Component semantics follow the engine's: a component's Eye is display
/// (it tints the composite), its Edit toggle is the paint-write bit. The
/// channel list's Eye shows a channel in the composite; picking a row's
/// thumbnail makes that channel the active channel, marked by the
/// thumbnail's ring and the row's highlight. Both come from the
/// snapshot's `activeChannel`, never from a row's own selected flag,
/// which can lag while an edit settles.
///
/// Editing affordances follow the native commands' own refusals: the
/// live Quick Mask row keeps its Eye and its attribute edit but cannot be
/// deleted or renamed (its Edit form's name field is the controller's to
/// disable). Everything that changes the image is disabled while
/// `acceptsEdits` is false or no component model has been read, and the
/// list itself stays readable either way. Target picks (selecting a
/// channel, returning to the layers) need only `acceptsEdits`: whether
/// channels can be created is a document decision the view does not make.
@MainActor
final class ChannelsPaletteView: NSView {

    // MARK: Interface

    /// Everything the palette shows at once. The controller builds one
    /// from its document state and hands it over; the view keeps no other
    /// state than the thumbnails it was given.
    struct Snapshot: Equatable {
        /// The image's component model and display/edit bits; nil while no
        /// image is open or its model could not be read.
        let components: EngineSession.ComponentState?
        /// The flat channel list, the Quick Mask's row included.
        let channels: [EngineSession.Channel]
        /// The active channel's id; nil while the layers are the target
        /// OR several channels are selected (an ambiguous target — the
        /// footer's single-id commands disable then).
        let activeChannel: Int32?
        /// Whether any channel is selected, even when no single one is
        /// the active target: Return to Layers stays available then.
        let hasSelectedChannels: Bool
        /// The Quick Mask state; nil when the image has none to toggle.
        let quickMask: EngineSession.QuickMaskState?
        /// False while the document is busy or closing: the list stays
        /// readable but nothing is offered for editing.
        let acceptsEdits: Bool
        let multichannel: Bool

        init(components: EngineSession.ComponentState? = nil,
             channels: [EngineSession.Channel] = [],
             activeChannel: Int32? = nil,
             hasSelectedChannels: Bool = false,
             quickMask: EngineSession.QuickMaskState? = nil,
             acceptsEdits: Bool = false,
             multichannel: Bool = false) {
            self.components = components
            self.channels = channels
            self.activeChannel = activeChannel
            self.hasSelectedChannels = hasSelectedChannels
            self.quickMask = quickMask
            self.acceptsEdits = acceptsEdits
            self.multichannel = multichannel
        }
    }

    /// What a gesture means. The controller maps these onto its document
    /// services; the view knows nothing about how they run.
    enum Action: Equatable {
        case setComponentActive(EngineSession.Components, Bool)
        case setComponentVisible(EngineSession.Components, Bool)
        case selectChannel(Int32)
        case setChannelVisible(Int32, Bool)
        case editChannel(Int32)
        case newChannel
        case duplicateChannel(Int32)
        case deleteChannel(Int32)
        case channelToSelection(Int32, EngineSession.SelectOperation)
        case setQuickMask(Bool)
        case returnToLayers
    }

    /// Where every gesture goes.
    var onAction: ((Action) -> Void)?

    /// The smallest and the intended palette body size, for the palette
    /// definition that hosts this view.
    static let minimumContentSize = NSSize(width: 240, height: 320)
    static let defaultContentSize = NSSize(width: 260, height: 380)

    // MARK: Component rows

    /// One component a row can stand for. The order is the display order;
    /// `shown(for:)` is the whole component model rule, so the palette
    /// and its tests agree on which rows exist.
    enum ComponentID: CaseIterable {
        case red, green, blue, gray, indexed, alpha

        /// The single bit the row's toggles act on.
        var bit: EngineSession.Components {
            switch self {
            case .red: return .red
            case .green: return .green
            case .blue: return .blue
            case .gray: return .gray
            case .indexed: return .indexed
            case .alpha: return .alpha
            }
        }

        var title: String {
            switch self {
            case .red: return "Red"
            case .green: return "Green"
            case .blue: return "Blue"
            case .gray: return "Gray"
            case .indexed: return "Indexed"
            case .alpha: return "Alpha"
            }
        }

        /// The rows for a component model: the mode's color components
        /// that the image supports, then Alpha when the bits carry it.
        static func shown(for state: EngineSession.ComponentState) -> [ComponentID] {
            let primaries: [ComponentID]
            switch state.mode {
            case .rgb: primaries = [.red, .green, .blue]
            case .grayscale: primaries = [.gray]
            case .indexed: primaries = [.indexed]
            case .multichannel: primaries = []
            }
            var rows = primaries.filter { state.supported.contains($0.bit) }
            if state.supported.contains(alpha.bit) { rows.append(.alpha) }
            return rows
        }
    }

    // MARK: Rows

    /// One component's row: the Eye for the display bit, the Edit toggle
    /// for the paint-write bit, and the component's name. A toggle that
    /// the palette refuses (the row went stale) shows the snapshot's state
    /// again, the way a Layers row reverts a refused visibility change.
    @MainActor
    final class ComponentRow: NSStackView {
        let component: ComponentID
        let eyeToggle: ClassicToolbarButton
        let editToggle: ClassicToolbarButton
        let nameLabel: NSTextField
        /// Reports the toggle; returns whether the palette took it.
        var onEye: ((ComponentID, Bool) -> Bool)?
        var onEdit: ((ComponentID, Bool) -> Bool)?
        private var shownVisible: Bool
        private var shownActive: Bool

        init(component: ComponentID, state: EngineSession.ComponentState, canEdit: Bool) {
            self.component = component
            let visible = state.visible.contains(component.bit)
            let active = state.active.contains(component.bit)
            self.shownVisible = visible
            self.shownActive = active

            let eyeToggle = ChannelsPaletteView.toggleButton(
                symbolNames: [visible ? "eye" : "eye.slash"],
                toolTip: "Shows or hides the \(component.title) channel in the composite image.")
            eyeToggle.state = visible ? .on : .off
            eyeToggle.isEnabled = canEdit
            self.eyeToggle = eyeToggle

            let editToggle = ChannelsPaletteView.toggleButton(
                symbolNames: ["paintbrush.pointed", "paintbrush", "pencil"],
                toolTip: "Painting writes the \(component.title) channel while this is on.")
            editToggle.state = active ? .on : .off
            editToggle.isEnabled = canEdit
            self.editToggle = editToggle

            let nameLabel = NSTextField(labelWithString: component.title)
            nameLabel.font = .systemFont(ofSize: 12)
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            self.nameLabel = nameLabel

            super.init(frame: .zero)

            eyeToggle.target = self
            eyeToggle.action = #selector(toggleEye(_:))
            editToggle.target = self
            editToggle.action = #selector(toggleEdit(_:))
            applyEyeAccessibility()

            orientation = .horizontal
            alignment = .centerY
            spacing = 2
            edgeInsets = NSEdgeInsets(top: 1, left: 2, bottom: 1, right: 4)
            addArrangedSubview(eyeToggle)
            addArrangedSubview(editToggle)
            addArrangedSubview(nameLabel)
            heightAnchor.constraint(equalToConstant: ChannelsPaletteView.rowHeight).isActive = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        private func applyEyeAccessibility() {
            eyeToggle.setAccessibilityLabel("\(shownVisible ? "Hide" : "Show") \(component.title)")
        }

        @objc private func toggleEye(_ sender: NSButton) {
            let visible = sender.state == .on
            if let onEye, onEye(component, visible) {
                shownVisible = visible
                sender.image = ChannelsPaletteView.symbol([visible ? "eye" : "eye.slash"])
                applyEyeAccessibility()
            } else {
                sender.state = shownVisible ? .on : .off
            }
        }

        @objc private func toggleEdit(_ sender: NSButton) {
            let active = sender.state == .on
            if let onEdit, onEdit(component, active) {
                shownActive = active
            } else {
                sender.state = shownActive ? .on : .off
            }
        }
    }

    /// One channel's row in the flat list: the Eye, the thumbnail that
    /// picks the channel as the active channel, and the name. The row
    /// keeps the channel id it was made for, so a click on a row that a
    /// reload removed reports that id and is refused, never retargeted at
    /// whatever sits in its place now.
    @MainActor
    final class ChannelRow: NSStackView {
        let channelID: Int32
        /// The row stands for the live Quick Mask; native commands refuse
        /// deleting and renaming it.
        let isQuickMaskRow: Bool
        let eyeToggle: ClassicToolbarButton
        let thumbnail: ThumbnailButton
        let nameLabel: NSTextField
        /// The active-target highlight behind the row and the ring on its
        /// thumbnail, driven together from the snapshot's active channel.
        var isTarget = false {
            didSet {
                thumbnail.isActiveTarget = isTarget
                needsDisplay = true
            }
        }
        /// All selected rows remain visible even when the paint target is
        /// ambiguous. The thumbnail ring still means exactly one target.
        var isSelected = false { didSet { needsDisplay = true } }
        /// Reports the toggle; returns whether the palette took it.
        var onEye: ((Int32, Bool) -> Bool)?
        /// Reports a pick of this row's channel.
        var onPick: ((Int32) -> Void)?
        private var shownVisible: Bool

        init(channel: EngineSession.Channel, canEdit: Bool, canPick: Bool) {
            self.channelID = channel.id
            self.isQuickMaskRow = channel.isQuickMask
            self.shownVisible = channel.isVisible
            let name = channel.isQuickMask ? "Quick Mask" : channel.name

            let eyeToggle = ChannelsPaletteView.toggleButton(
                symbolNames: [channel.isVisible ? "eye" : "eye.slash"],
                toolTip: channel.isQuickMask
                    ? "Shows or hides the Quick Mask overlay in the composite image."
                    : "Shows or hides \(name) in the composite image.")
            eyeToggle.state = channel.isVisible ? .on : .off
            eyeToggle.isEnabled = canEdit
            self.eyeToggle = eyeToggle

            let thumbnail = ThumbnailButton(kind: .layer)
            thumbnail.isActiveTarget = false
            thumbnail.isDimmed = !channel.isVisible
            thumbnail.setAccessibilityLabel("\(name) channel")
            thumbnail.setAccessibilityHelp("Make \(name) the active channel.")
            self.thumbnail = thumbnail

            let nameLabel = NSTextField(labelWithString: name)
            nameLabel.font = .systemFont(ofSize: 12)
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            self.nameLabel = nameLabel

            super.init(frame: .zero)

            eyeToggle.target = self
            eyeToggle.action = #selector(toggleEye(_:))
            applyEyeAccessibility(name: name)
            thumbnail.target = self
            thumbnail.action = #selector(pickChannel(_:))
            thumbnail.isEnabled = canPick

            orientation = .horizontal
            alignment = .centerY
            spacing = 2
            edgeInsets = NSEdgeInsets(top: 1, left: 2, bottom: 1, right: 4)
            addArrangedSubview(eyeToggle)
            addArrangedSubview(thumbnail)
            addArrangedSubview(nameLabel)
            heightAnchor.constraint(equalToConstant: ChannelsPaletteView.rowHeight).isActive = true
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

        private func applyEyeAccessibility(name: String) {
            eyeToggle.setAccessibilityLabel("\(shownVisible ? "Hide" : "Show") \(name)")
        }

        @objc private func toggleEye(_ sender: NSButton) {
            let visible = sender.state == .on
            if let onEye, onEye(channelID, visible) {
                shownVisible = visible
                sender.image = ChannelsPaletteView.symbol([visible ? "eye" : "eye.slash"])
                applyEyeAccessibility(name: nameLabel.stringValue)
            } else {
                sender.state = shownVisible ? .on : .off
            }
        }

        @objc private func pickChannel(_ sender: Any?) {
            onPick?(channelID)
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard isSelected || isTarget else { return }
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.2).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
        }
    }

    // MARK: Subviews

    /// The row height the Layers palette uses.
    static let rowHeight: CGFloat = LayerRowView.rowHeight

    private(set) var snapshot = Snapshot()
    private(set) var componentRows: [ComponentRow] = []
    private(set) var channelRows: [ChannelRow] = []

    private let componentStack = NSStackView()
    private let rule = ClassicRuleView()
    private let listStack: NSStackView
    private let scrollView = NSScrollView()
    let quickMaskButton: ClassicToolbarButton
    let returnToLayersButton: ClassicToolbarButton
    let selectionPopup: ClassicPopUp
    private lazy var buttonBar = ClassicPaletteButtonBar(
        items: [FooterCommand.new, .duplicate, .edit].map(barItem),
        trailingItems: [barItem(.delete)])
    /// The footer strip; the palette menu mirrors its commands.
    var paletteButtonBar: ClassicPaletteButtonBar { buttonBar }

    /// Rendered thumbnails by channel id. They arrive one by one from the
    /// controller's counted worker and outlive the rows they were made
    /// for only until the next snapshot drops the channel.
    private var thumbnails: [Int32: NSImage] = [:]

    // MARK: Setup

    override init(frame frameRect: NSRect = .zero) {
        let listStack = ChannelListStack()
        self.listStack = listStack
        self.quickMaskButton = ClassicToolbarButton(image: ChannelsPaletteView.symbol(
            ["square.dashed", "rectangle.dashed", "eye"]), target: nil, action: nil)
        self.returnToLayersButton = ClassicToolbarButton(title: "Return to Layers",
                                                         target: nil, action: nil)
        self.selectionPopup = ClassicPopUp(width: 96)
        super.init(frame: frameRect)
        setUp()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

    private func setUp() {
        componentStack.orientation = .vertical
        componentStack.alignment = .leading
        componentStack.spacing = 0

        scrollView.documentView = listStack
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        listStack.translatesAutoresizingMaskIntoConstraints = false
        listStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true
        // The list is the only section that grows and shrinks with the
        // palette; bounded scrolling keeps the commands reachable.
        scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
        scrollView.setContentHuggingPriority(.defaultLow - 1, for: .vertical)
        scrollView.setContentCompressionResistancePriority(.defaultLow - 1, for: .vertical)

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0

        quickMaskButton.setButtonType(.toggle)
        quickMaskButton.imagePosition = .imageOnly
        quickMaskButton.toolTip = "Shows or hides the Quick Mask."
        quickMaskButton.setAccessibilityLabel("Quick Mask")
        quickMaskButton.widthAnchor.constraint(equalToConstant: 26).isActive = true
        quickMaskButton.heightAnchor.constraint(equalToConstant: ClassicChrome.controlHeight).isActive = true
        quickMaskButton.target = self
        quickMaskButton.action = #selector(toggleQuickMask(_:))

        returnToLayersButton.toolTip = "Returns the paint target to the layers."
        returnToLayersButton.setAccessibilityLabel("Return to Layers")
        returnToLayersButton.heightAnchor.constraint(equalToConstant: ClassicChrome.controlHeight).isActive = true
        returnToLayersButton.target = self
        returnToLayersButton.action = #selector(returnToLayers(_:))

        let quickRow = NSStackView(views: [quickMaskButton, returnToLayersButton])
        quickRow.orientation = .horizontal
        quickRow.alignment = .centerY
        quickRow.spacing = 6
        quickRow.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

        selectionPopup.addItems(withTitles: Self.selectionOperationNames)
        selectionPopup.toolTip = "Converts the active channel to a selection."
        selectionPopup.setAccessibilityLabel("Channel to Selection")
        selectionPopup.target = self
        selectionPopup.action = #selector(selectionOperationChosen(_:))
        let conversionLabel = NSTextField(labelWithString: "To Selection")
        conversionLabel.font = .systemFont(ofSize: 11)
        let conversionRow = NSStackView(views: [conversionLabel, selectionPopup])
        conversionRow.orientation = .horizontal
        conversionRow.alignment = .centerY
        conversionRow.spacing = 6
        conversionRow.edgeInsets = NSEdgeInsets(top: 2, left: 6, bottom: 2, right: 6)

        let content = NSStackView(views: [componentStack, rule, scrollView,
                                          quickRow, conversionRow, buttonBar])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 4
        content.detachesHiddenViews = true
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            componentStack.widthAnchor.constraint(equalTo: content.widthAnchor),
            rule.widthAnchor.constraint(equalTo: content.widthAnchor),
            scrollView.widthAnchor.constraint(equalTo: content.widthAnchor),
            quickRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            conversionRow.widthAnchor.constraint(equalTo: content.widthAnchor),
            buttonBar.widthAnchor.constraint(equalTo: content.widthAnchor),
        ])

        update(Snapshot())
    }

    /// The menu's four conversion operations in display order; the
    /// pop-up's item index maps onto `EngineSession.SelectOperation`.
    static let selectionOperationNames = ["Replace", "Add", "Subtract", "Intersect"]
    static let selectionOperations: [EngineSession.SelectOperation] =
        [.replace, .add, .subtract, .intersect]

    // MARK: Updates

    /// Replaces everything the palette shows. Updates never emit actions.
    func update(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        rebuildComponentRows()
        rebuildChannelRows()
        refreshControls()
    }

    /// Sets one channel's thumbnail. The `CGImage` is wrapped on the main
    /// thread; nothing here reads or renders engine content.
    func setThumbnail(_ image: CGImage, for channelID: Int32) {
        let shown = NSImage(cgImage: image,
                            size: NSSize(width: image.width, height: image.height))
        thumbnails[channelID] = shown
        channelRows.first { $0.channelID == channelID }?.thumbnail.thumbnail = shown
    }

    /// Sets several thumbnails, as one delivery from the controller's
    /// counted worker does.
    func setThumbnails(_ images: [Int32: CGImage]) {
        for (id, image) in images {
            setThumbnail(image, for: id)
        }
    }

    /// The active channel that still exists in the snapshot. The raw row
    /// flags can lag, so the ring and highlight follow this and nothing
    /// else; nil means the layers are the target.
    var effectiveActiveChannel: Int32? {
        Self.effectiveActiveChannel(in: snapshot)
    }

    static func effectiveActiveChannel(in snapshot: Snapshot) -> Int32? {
        guard let id = snapshot.activeChannel,
              snapshot.channels.contains(where: { $0.id == id }) else { return nil }
        return id
    }

    // MARK: Row rebuilding

    private func rebuildComponentRows() {
        for row in componentRows {
            componentStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        guard let components = snapshot.components else {
            componentRows = []
            return
        }
        let canEdit = self.canEdit
        componentRows = ComponentID.shown(for: components).map { component in
            let row = ComponentRow(component: component, state: components, canEdit: canEdit)
            row.onEye = { [weak self] in self?.setComponent($0, visible: $1) ?? false }
            row.onEdit = { [weak self] in self?.setComponent($0, active: $1) ?? false }
            componentStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: componentStack.widthAnchor).isActive = true
            return row
        }
    }

    private func rebuildChannelRows() {
        for row in channelRows {
            listStack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        let ids = Set(snapshot.channels.map(\.id))
        thumbnails = thumbnails.filter { ids.contains($0.key) }

        let canEdit = self.canEdit
        let canPick = snapshot.acceptsEdits
        let active = effectiveActiveChannel
        channelRows = snapshot.channels.map { channel in
            let row = ChannelRow(channel: channel, canEdit: canEdit, canPick: canPick)
            row.thumbnail.thumbnail = thumbnails[channel.id]
            row.isTarget = channel.id == active
            row.isSelected = channel.isSelected
            row.onEye = { [weak self] in self?.setChannel($0, visible: $1) ?? false }
            row.onPick = { [weak self] in self?.pickChannel($0) }
            listStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            return row
        }
    }

    // MARK: Gesture handling

    /// Whether anything may change the image: a component model was read
    /// and the document takes edits.
    private var canEdit: Bool {
        snapshot.acceptsEdits && snapshot.components != nil
    }

    /// Reports an action to the controller.
    private func emit(_ action: Action) {
        guard ChannelMenuPolicy.permits(action, multichannel: snapshot.multichannel) else { return }
        onAction?(action)
    }

    private func setComponent(_ component: ComponentID, visible: Bool) -> Bool {
        guard canEdit else { return false }
        emit(.setComponentVisible(component.bit, visible))
        return true
    }

    private func setComponent(_ component: ComponentID, active: Bool) -> Bool {
        guard canEdit else { return false }
        emit(.setComponentActive(component.bit, active))
        return true
    }

    /// A row's eye, for the channel id the row was made for. A row whose
    /// channel the snapshot no longer names is refused, so a stale click
    /// can never act on the channel that took its place.
    private func setChannel(_ id: Int32, visible: Bool) -> Bool {
        guard canEdit, snapshot.channels.contains(where: { $0.id == id }) else { return false }
        emit(.setChannelVisible(id, visible))
        return true
    }

    private func pickChannel(_ id: Int32) {
        guard snapshot.acceptsEdits, snapshot.channels.contains(where: { $0.id == id }) else { return }
        emit(.selectChannel(id))
    }

    @objc private func toggleQuickMask(_ sender: NSButton) {
        let shown = snapshot.quickMask?.enabled ?? false
        guard canEdit, snapshot.quickMask != nil else {
            sender.state = shown ? .on : .off
            return
        }
        emit(.setQuickMask(sender.state == .on))
    }

    @objc private func returnToLayers(_ sender: Any?) {
        guard snapshot.acceptsEdits,
              effectiveActiveChannel != nil || snapshot.hasSelectedChannels else { return }
        emit(.returnToLayers)
    }

    @objc private func selectionOperationChosen(_ sender: ClassicPopUp) {
        guard canEdit, let id = effectiveActiveChannel,
              Self.selectionOperations.indices.contains(sender.indexOfSelectedItem) else { return }
        emit(.channelToSelection(id, Self.selectionOperations[sender.indexOfSelectedItem]))
    }

    // MARK: Footer

    /// The palette's commands. New saves the selection as a channel; the
    /// rest act on the active channel, whatever the snapshot names now.
    private enum FooterCommand: String, CaseIterable {
        case new, duplicate, edit, delete

        var title: String {
            switch self {
            case .new: return "New Channel (Save Selection)"
            case .duplicate: return "Duplicate Channel"
            case .edit: return "Edit Channel Attributes…"
            case .delete: return "Delete Channel"
            }
        }

        var symbolNames: [String] {
            switch self {
            case .new: return ["plus"]
            case .duplicate: return ["plus.square.on.square"]
            case .edit: return ["slider.horizontal.3", "pencil"]
            case .delete: return ["trash"]
            }
        }
    }

    private func barItem(_ command: FooterCommand) -> ClassicPaletteButtonBar.Item {
        ClassicPaletteButtonBar.Item(id: command.rawValue, title: command.title,
                                     image: Self.symbol(command.symbolNames)) { [weak self] in
            self?.runFooter(command)
        }
    }

    private func runFooter(_ command: FooterCommand) {
        switch command {
        case .new:
            guard canEdit else { return }
            emit(.newChannel)
        case .duplicate:
            guard canEdit, let id = effectiveActiveChannel else { return }
            emit(.duplicateChannel(id))
        case .edit:
            // The live Quick Mask takes attribute edits too; only its name
            // is fixed, and the edit form's name field is the one to
            // disable for it.
            guard canEdit, let id = effectiveActiveChannel else { return }
            emit(.editChannel(id))
        case .delete:
            guard canEdit, let id = effectiveActiveChannel,
                  let channel = snapshot.channels.first(where: { $0.id == id }),
                  !channel.isQuickMask else { return }
            emit(.deleteChannel(id))
        }
    }

    /// Where the footer stands right now, applied after every reload.
    private func refreshControls() {
        componentStack.isHidden = snapshot.components == nil || snapshot.multichannel
        rule.isHidden = componentStack.isHidden

        let quick = snapshot.quickMask
        quickMaskButton.state = (quick?.enabled ?? false) ? .on : .off
        quickMaskButton.isEnabled = canEdit && quick != nil && !snapshot.multichannel

        let active = effectiveActiveChannel
        // Return to Layers works with any channel selected (also a
        // multi-selection); the single-id commands need exactly one.
        returnToLayersButton.isEnabled = snapshot.acceptsEdits && !snapshot.multichannel && (active != nil || snapshot.hasSelectedChannels)
        selectionPopup.isEnabled = canEdit && active != nil && !snapshot.multichannel

        buttonBar.setEnabled(canEdit && !snapshot.multichannel, forItem: FooterCommand.new.rawValue)
        buttonBar.setEnabled(canEdit && active != nil && !snapshot.multichannel, forItem: FooterCommand.duplicate.rawValue)
        buttonBar.setEnabled(canEdit && active != nil, forItem: FooterCommand.edit.rawValue)
        let activeChannel = active.flatMap { id in snapshot.channels.first { $0.id == id } }
        buttonBar.setEnabled(canEdit && !snapshot.multichannel && activeChannel.map { !$0.isQuickMask } ?? false,
                             forItem: FooterCommand.delete.rawValue)
    }

    // MARK: Shared control look

    /// A small icon toggle in the palette's chrome look: the classic
    /// bezel reads raised while the toggle is on.
    static func toggleButton(symbolNames: [String], toolTip: String) -> ClassicToolbarButton {
        let button = ClassicToolbarButton(image: symbol(symbolNames), target: nil, action: nil)
        button.setButtonType(.toggle)
        button.imagePosition = .imageOnly
        button.toolTip = toolTip
        button.widthAnchor.constraint(equalToConstant: 26).isActive = true
        button.heightAnchor.constraint(equalToConstant: ClassicChrome.controlHeight).isActive = true
        return button
    }

    /// The first available SF Symbol, as a template glyph like the
    /// palette button bars use.
    static func symbol(_ names: [String]) -> NSImage {
        let image = names.lazy
            .compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
            .first ?? NSImage()
        image.isTemplate = true
        return image
    }

    /// The list's document view: flipped so the first channel row sits at
    /// the top and the list grows downward.
    private final class ChannelListStack: NSStackView {
        override var isFlipped: Bool { true }
    }
}
