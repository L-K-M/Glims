import AppKit
import RigiUI

/// The Layers palette: the front document's layer tree, top of the stack
/// first. Selecting a row makes that layer or group the paint, metadata
/// and filter target; selecting a committed effect's subrow picks its
/// parent layer and offers the effect's own commands. Groups open and
/// close with the disclosure triangle; dragging a row reorders it
/// inside its parent or moves it into a group. Each row carries a
/// visibility checkbox, a lock badge when locks apply, and a name that
/// edits in place. The button bar adds a layer or a group, duplicates
/// and deletes.
@MainActor
final class LayersPaletteController: NSViewController, PaletteContent, PaletteEditScope.Content,
                                     NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuItemValidation,
                                     NSMenuDelegate {
    typealias Target = ImageDocument

    static let definition = PaletteDefinition(
        kind: PaletteKind("ch.lkmc.Glims.layers"),
        title: "Layers",
        contentSize: NSSize(width: 260, height: 300),
        sizing: .resizable(minimumContentSize: NSSize(width: 260, height: 186)),
        frameAutosaveName: "Glims.palette.layers")

    /// The pasteboard type drags inside the outline write: the layer id.
    private static let dragType = NSPasteboard.PasteboardType("ch.lkmc.Glims.layerID")

    private weak var document: ImageDocument?
    private let outline = NSOutlineView()
    private var reloading = false
    private var snapshot = LayerListSnapshot(document: nil, layers: [])
    private let opacityControl = ClassicValueSlider(title: "Opacity", range: 0...100,
                                                     value: 100, unit: "%", fractionDigits: 1)
    @MainActor
    private struct OpacityTarget {
        weak var document: ImageDocument?
        let owner: ObjectIdentifier
        let layer: Int32
        init(_ document: ImageDocument, _ layer: Int32) {
            self.document = document; owner = ObjectIdentifier(document); self.layer = layer
        }
        func matches(_ other: OpacityTarget?) -> Bool {
            guard let other else { return false }
            return document === other.document && other.owner == owner && other.layer == layer
        }
        var isAvailable: Bool {
            guard let document else { return false }
            return document.acceptsLayerProperties && !document.targetCommandIsPending
                && document.layers.contains { $0.id == layer }
        }
    }
    private var opacityTarget: OpacityTarget?
    private var opacityTrackingTarget: OpacityTarget?
    private var opacityWrite: UUID?
    private var opacityWriteTarget: OpacityTarget?
    private var syncingOpacity = false
    private var targetGeneration = 0
    private var opacityCommittedValue = 100.0
    private var opacityCommittedText = "100.0"
    private var opacityMouseUpMonitor: Any?

    /// Which document the outline's rows currently show, for expansion
    /// memory; groups reopen after a reload and after a retarget back.
    private var displayedDocument: ObjectIdentifier?
    /// The expanded groups in the displayed tree, tracked from the
    /// outline's expand and collapse notifications: `isItemExpanded`
    /// reports false for an item a collapsed ancestor hides, so sampling
    /// the outline would forget groups nested inside collapsed parents.
    private var expandedGroupIDs = Set<Int32>()
    private var expansionByDocument: [ObjectIdentifier: Set<Int32>] = [:]
    /// The ordered selection the outline last applied (primary first);
    /// a new selection inside a collapsed group opens its parents, an
    /// unchanged one does not.
    private var lastSyncedSelectionIDs: [Int32] = []
    /// The effect row the user last picked, by explicit ids: it stays
    /// selected across reloads while its parent is still the paint
    /// target — a retarget, removal, new pick or mask/channel pick
    /// ends it.
    private var selectedEffect: (drawable: Int32, effect: Int32)?
    /// Whether the picked effect row's parent must still be opened to
    /// show it — like a layer selection inside a collapsed group.
    private var effectSelectionIsNew = false
    /// Layer and mask thumbnails, bounded small and read off the main
    /// thread. Keys carry the document's state version, so a result read
    /// for an older state can never land on a newer row.
    private static let thumbnailMaxSize: Int32 = 32
    private struct ThumbnailKey: Hashable {
        let image: Int32
        let drawable: Int32
        let version: Int
    }
    private var thumbnailCache: [ThumbnailKey: NSImage] = [:]
    /// Rows asking for the same drawable while its read is in flight;
    /// a reload replaces the rows but the queued read still serves them.
    private var thumbnailWaiters: [ThumbnailKey: [(NSImage?) -> Void]] = [:]
    private final class ThumbnailRequest: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
    private var thumbnailRequests: [ThumbnailKey: ThumbnailRequest] = [:]
    /// The per-row menu, rebuilt in `menuNeedsUpdate` for the effect row
    /// under the right-click; stays empty elsewhere so nothing pops.
    private lazy var rowMenu: NSMenu = {
        let menu = NSMenu(title: "Effect")
        menu.delegate = self
        return menu
    }()
    private lazy var buttonBar = ClassicPaletteButtonBar(
        items: [Self.item("new", "New Layer", ["plus"]) { $0.layerCommand(.new) },
                Self.item("group", "New Layer Group", ["folder.badge.plus", "folder", "plus"]) { $0.createGroup() },
                Self.item("duplicate", "Duplicate Layers", ["plus.square.on.square"]) {
                    if $0.hasMultipleSelectedLayers { $0.duplicateSelectedLayers() }
                    else { $0.layerCommand(.duplicate) }
                }]
            .map(bind),
        trailingItems: [bind(Self.item("delete", "Delete Layers", ["trash"]) { $0.layerCommand(.delete) })])
    /// The floating-selection footer (Anchor / New Layer / Discard),
    /// shown only while the shown document has an active floating
    /// selection; its state comes from the cached readiness only.
    private let floatingBar = FloatingSelectionBar()

    /// A button bar command before it knows the palette's document.
    private struct Command {
        let id: String
        let title: String
        let image: NSImage
        let run: (ImageDocument) -> Void
    }

    private static func item(_ id: String, _ title: String, _ symbols: [String],
                             _ run: @escaping (ImageDocument) -> Void) -> Command {
        let image = symbols.lazy.compactMap { NSImage(systemSymbolName: $0, accessibilityDescription: title) }
            .first ?? NSImage()
        image.isTemplate = true
        return Command(id: id, title: title, image: image, run: run)
    }

    private func bind(_ command: Command) -> ClassicPaletteButtonBar.Item {
        ClassicPaletteButtonBar.Item(id: command.id, title: command.title, image: command.image) { [weak self] in
            guard let document = self?.document,
                  !document.colorInfo.mode.usesNativeChannels ||
                    (document.storage.layout == .layeredLab &&
                     ((command.id == "duplicate" && document.acceptsLayerDuplicate) ||
                      (command.id == "new" && document.acceptsLayerCreate) ||
                      (command.id == "delete" && document.acceptsLayerDelete))) else { return }
            command.run(document)
        }
    }

    override func loadView() {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.headerView = nil
        outline.usesAlternatingRowBackgroundColors = false
        outline.indentationPerLevel = 12
        outline.dataSource = self
        outline.delegate = self
        // Native Shift/Command multi-selection: the selected rows map to
        // the document's ordered selected-layer list, primary first.
        outline.allowsMultipleSelection = true
        outline.target = self
        outline.doubleAction = #selector(editNameOfClickedRow(_:))
        outline.rowHeight = LayerRowView.rowHeight
        outline.setAccessibilityLabel("Layers")
        // Built per right-click for the row under it; empty on a layer
        // row means no menu, like before.
        outline.menu = rowMenu
        outline.registerForDraggedTypes([Self.dragType])
        outline.setDraggingSourceOperationMask(.move, forLocal: true)
        outline.setDraggingSourceOperationMask([], forLocal: false)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        opacityControl.accessibilityTitle = "Layer opacity"
        opacityControl.isEnabled = false
        opacityControl.onChange = { [weak self] value, phase in self?.opacityChanged(value, phase: phase) }
        let opacityRow = NSStackView(views: [opacityControl])
        opacityRow.orientation = .horizontal
        opacityRow.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        opacityRow.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        // Rigi may suppress its release callback if readiness disabled the
        // control during a drag. After the mouse-up has dispatched, discard
        // that uncommitted local presentation; this never writes native state.
        opacityMouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            DispatchQueue.main.async {
                guard let self, self.opacityTrackingTarget != nil else { return }
                self.opacityTrackingTarget = nil
                self.syncOpacity()
            }
            return event
        }
        let stack = NSStackView(views: [opacityRow, scroll, floatingBar, buttonBar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        opacityRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        floatingBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        buttonBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        view = stack
    }

    deinit {
        if let opacityMouseUpMonitor { NSEvent.removeMonitor(opacityMouseUpMonitor) }
    }

    private var opacityField: NSTextField? {
        func field(in root: NSView) -> NSTextField? {
            if let field = root as? NSTextField, field.isEditable { return field }
            return root.subviews.lazy.compactMap { field(in: $0) }.first
        }
        return field(in: opacityControl)
    }

    private func finishOpacityField() {
        guard let field = opacityField, field.currentEditor() != nil else { return }
        // End only this control's field, while its old explicit owner remains
        // bound. Never finish a field belonging to another grouped palette.
        field.window?.endEditing(for: field)
    }

    private func currentOpacityTarget() -> OpacityTarget? {
        guard let document, document.selectedLayerIDs.count == 1,
              let id = document.selectedLayerIDs.first,
              document.layers.contains(where: { $0.id == id }) else { return nil }
        return OpacityTarget(document, id)
    }

    private func syncOpacity() {
        guard isViewLoaded, !syncingOpacity else { return }
        syncingOpacity = true
        defer { syncingOpacity = false }
        if let tracking = opacityTrackingTarget {
            // A drag's local value and explicit owner survive asynchronous
            // reloads/retargets. The release commits to that owner only.
            opacityControl.isEnabled = opacityWrite == nil && tracking.isAvailable
            return
        }
        var next = currentOpacityTarget()
        if !(opacityTarget?.matches(next) ?? (next == nil)) {
            finishOpacityField()
            next = currentOpacityTarget()
            opacityTarget = next
        }
        opacityControl.isEnabled = opacityWrite == nil && next?.isAvailable == true
        // An accepted write owns the displayed value until its counted
        // completion reconciles the actual cache. Other targets still show
        // their own cache even while this palette's single write drains.
        if opacityWrite != nil, opacityWriteTarget?.matches(next) == true { return }
        let value = next.flatMap { target in
            target.document?.layers.first { $0.id == target.layer }?.opacity
        }.map { $0 * 100 } ?? 100
        guard let field = opacityField else { return }
        if opacityControl.value != opacityCommittedValue {
            opacityCommittedValue = opacityControl.value
            opacityCommittedText = field.stringValue
        }
        let editor = field.currentEditor()
        let raw = editor?.string
        let hasDraft = raw.map { $0 != opacityCommittedText } ?? false
        let selection = editor?.selectedRange
        let allSelected = selection == NSRange(location: 0, length: (raw as NSString?)?.length ?? 0)
        // Advance Rigi's silent baseline even under a draft. An explicit
        // commit equal to the old baseline must emit after external changes.
        opacityControl.value = value
        opacityCommittedValue = opacityControl.value
        opacityCommittedText = field.stringValue
        if let editor, let selection {
            let text = hasDraft ? raw ?? opacityCommittedText : opacityCommittedText
            editor.string = text
            let count = (text as NSString).length, start = min(selection.location, (text as NSString).length)
            editor.selectedRange = allSelected ? NSRange(location: 0, length: count)
                : NSRange(location: start, length: min(selection.length, count - start))
        }
    }

    private func opacityChanged(_ percent: Double, phase: ClassicValueSlider.Phase) {
        if phase == .tracking {
            guard opacityWrite == nil, opacityControl.isEnabled, let target = opacityTarget else { return }
            if opacityTrackingTarget == nil { opacityTrackingTarget = target }
            return
        }
        let captured = opacityTrackingTarget ?? opacityTarget
        opacityTrackingTarget = nil
        guard opacityWrite == nil, percent.isFinite, let captured, captured.isAvailable,
              let owner = captured.document,
              let layer = owner.layers.first(where: { $0.id == captured.layer }) else {
            syncOpacity(); return
        }
        let opacity = min(max(percent, 0), 100) / 100
        guard abs(layer.opacity - opacity) > 0.000000000001 else { syncOpacity(); return }
        let token = UUID()
        opacityWrite = token
        opacityWriteTarget = captured
        opacityControl.isEnabled = false
        owner.changeLayer(captured.layer, .init(opacity: opacity)) { [weak self] _ in
            guard let self, self.opacityWrite == token else { return }
            self.opacityWrite = nil
            self.opacityWriteTarget = nil
            // Never assign the old owner's value to a newly aimed row.
            self.syncOpacity()
        }
    }

    /// The title bar triangle's menu: the layer commands, on the document
    /// the palette shows, as its buttons are, so they work while that
    /// document's window is minimized. Layer Properties… opens the document
    /// window's dialog and goes there through the responder chain.
    var paletteMenu: NSMenu? {
        let menu = NSMenu(title: "Layers")
        let commands: [(String, EngineSession.LayerCommand)] = [
            ("New Layer", .new), ("Duplicate Layer", .duplicate), ("Delete Layer", .delete),
        ]
        for (title, command) in commands {
            menu.addItem(commandItem(title, command))
        }
        let group = NSMenuItem(title: "New Layer Group", action: #selector(newLayerGroup(_:)), keyEquivalent: "")
        group.target = self
        menu.addItem(group)
        menu.addItem(.separator())
        let mask = NSMenuItem(title: "Mask", action: nil, keyEquivalent: "")
        mask.submenu = NSMenu(title: "Mask")
        for (title, action) in [("Add Layer Mask…", #selector(addLayerMask(_:))),
                                ("Apply Mask", #selector(applyLayerMask(_:))),
                                ("Delete Mask", #selector(deleteLayerMask(_:))),
                                ("Enable Mask", #selector(toggleMaskEnabled(_:))),
                                ("Edit Mask", #selector(toggleMaskEditing(_:))),
                                ("Show Mask", #selector(toggleMaskShowing(_:)))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            mask.submenu?.addItem(item)
        }
        mask.submenu?.addItem(.separator())
        let toSelection = NSMenuItem(title: "Mask to Selection", action: nil, keyEquivalent: "")
        toSelection.submenu = NSMenu(title: "Mask to Selection")
        let operations: [(String, EngineSession.SelectOperation)] = [
            ("Replace Selection", .replace), ("Add to Selection", .add),
            ("Subtract from Selection", .subtract), ("Intersect with Selection", .intersect),
        ]
        for (title, operation) in operations {
            let item = NSMenuItem(title: title, action: #selector(maskToSelection(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(operation.rawValue)
            toSelection.submenu?.addItem(item)
        }
        mask.submenu?.addItem(toSelection)
        menu.addItem(mask)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Layer Properties…", action: #selector(DocumentWindowController.layerProperties(_:)),
                     keyEquivalent: "")
        for (title, tag) in [("Rasterize Layer…", 0), ("Restore Layer Source…", 1)] {
            let item = NSMenuItem(title: title, action: #selector(runSourceCommand(_:)), keyEquivalent: "")
            item.target = self
            item.tag = tag
            item.representedObject = document
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(commandItem("Bring Forward", .raise))
        menu.addItem(commandItem("Send Backward", .lower))
        menu.addItem(commandItem("Layer to Image Size", .fitToImage))
        menu.addItem(commandItem("Trim Layer to Content", .trimToContent))
        menu.addItem(.separator())
        for (lock, title) in EngineSession.LayerLocks.menuOrder {
            let item = NSMenuItem(title: "Lock \(title)", action: #selector(toggleLock(_:)), keyEquivalent: "")
            item.target = self
            item.tag = Int(lock.rawValue)
            menu.addItem(item)
        }
        // While the shown document has an active floating selection, its
        // resolution commands join the palette menu; validation reads
        // only the cached floating state.
        if let document, document.floatingState.isActive {
            menu.addItem(.separator())
            let floating = NSMenuItem(title: "Floating Selection", action: nil, keyEquivalent: "")
            floating.submenu = NSMenu(title: "Floating Selection")
            for (title, command) in [("Anchor", EngineSession.FloatingCommand.anchor),
                                     ("New Layer", .toLayer), ("Discard", .discard)] {
                let item = NSMenuItem(title: title, action: #selector(runFloatingCommand(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(command.rawValue)
                floating.submenu?.addItem(item)
            }
            menu.addItem(floating)
        }
        // While an effect row is selected its stack commands live here
        // too, next to the row's own right-click menu.
        if let document, let selected = selectedEffect,
           let effect = document.layerEffects[selected.drawable]?
                .first(where: { $0.id == selected.effect }) {
            let item = EffectItem(document: document, drawable: selected.drawable, effect: effect)
            let submenu = NSMenuItem(title: "Filter: \(effect.name)", action: nil, keyEquivalent: "")
            submenu.submenu = NSMenu(title: effect.name)
            effectMenuItems(for: item).forEach { submenu.submenu?.addItem($0) }
            menu.addItem(.separator())
            menu.addItem(submenu)
        }
        return menu
    }

    private func commandItem(_ title: String, _ command: EngineSession.LayerCommand) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runLayerCommand(_:)), keyEquivalent: "")
        item.target = self
        item.tag = Int(command.rawValue)
        return item
    }

    private func sourceAction(_ item: NSMenuItem) -> Selector {
        item.tag == 0 ? #selector(DocumentWindowController.rasterizeLayer(_:))
            : #selector(DocumentWindowController.restoreLayerSource(_:))
    }

    private func sourceWindow(for captured: ImageDocument) -> DocumentWindowController? {
        NSApp.windows.compactMap { $0.windowController as? DocumentWindowController }
            .first { $0.imageDocument === captured && !$0.closeStarted }
    }

    /// Consent belongs to the window for the document this menu captured.
    /// A front-document switch cannot redirect the palette's source command.
    @objc private func runSourceCommand(_ sender: NSMenuItem) {
        guard let captured = sender.representedObject as? ImageDocument,
              document === captured, let owner = sourceWindow(for: captured),
              validateMenuItem(sender) else { return }
        owner.window?.deminiaturize(nil)
        owner.showWindow(nil)
        NSApp.sendAction(sourceAction(sender), to: owner, from: sender)
    }

    @objc private func runLayerCommand(_ sender: NSMenuItem) {
        guard let command = EngineSession.LayerCommand(rawValue: UInt32(sender.tag)) else { return }
        guard document?.colorInfo.mode.usesNativeChannels != true ||
              (document?.storage.layout == .layeredLab &&
               ((command == .duplicate && document?.acceptsLayerDuplicate == true) ||
                (command == .new && document?.acceptsLayerCreate == true) ||
                (command == .delete && document?.acceptsLayerDelete == true))) else { return }
        if command == .duplicate, document?.hasMultipleSelectedLayers == true {
            document?.duplicateSelectedLayers()
        } else {
            document?.layerCommand(command)
        }
    }

    @objc private func newLayerGroup(_ sender: NSMenuItem) {
        guard document?.colorInfo.mode.usesNativeChannels != true else { return }
        document?.createGroup()
    }

    @objc private func toggleLock(_ sender: NSMenuItem) {
        document?.toggleLocks(document?.activeLayer ?? 0, EngineSession.LayerLocks(rawValue: UInt32(sender.tag)))
    }

    /// The Floating Selection submenu's commands: Anchor / New Layer /
    /// Discard on the shown document, with its cached expected floating
    /// id.
    @objc private func runFloatingCommand(_ sender: NSMenuItem) {
        guard let command = EngineSession.FloatingCommand(rawValue: UInt32(sender.tag)) else { return }
        document?.resolveFloatingSelection(command, completion: { _ in })
    }

    // MARK: Mask commands

    @objc private func addLayerMask(_ sender: Any?) {
        guard let document, let window = view.window else { return }
        AddMaskForm.present(for: document, on: window)
    }

    @objc private func applyLayerMask(_ sender: Any?) { document?.applyMask() }
    @objc private func deleteLayerMask(_ sender: Any?) { document?.deleteMask() }
    @objc private func toggleMaskEnabled(_ sender: Any?) { document?.toggleMaskEnabled() }
    @objc private func toggleMaskEditing(_ sender: Any?) { document?.toggleMaskEditing() }
    @objc private func toggleMaskShowing(_ sender: Any?) { document?.toggleMaskShowing() }

    @objc private func maskToSelection(_ sender: NSMenuItem) {
        guard let operation = EngineSession.SelectOperation(rawValue: UInt32(sender.tag)) else { return }
        document?.maskToSelection(operation)
    }

    // MARK: Effect rows

    /// The context menu items one effect row offers: parameter editing,
    /// properties, enable, the stack moves, remove and merge. Enabled
    /// state mirrors the engine's guards; the document still validates
    /// each run.
    private func effectMenuItems(for item: EffectItem) -> [NSMenuItem] {
        func entry(_ title: String, _ action: Selector, tag: Int = 0,
                   enabled: Bool = true, toolTip: String? = nil) -> NSMenuItem {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
            menuItem.target = self
            menuItem.representedObject = item
            menuItem.tag = tag
            menuItem.isEnabled = enabled
            menuItem.toolTip = toolTip
            return menuItem
        }
        let editSupported = NativeFilterMenuLayout.supportsParameterEditor(
            NativeFilterCatalog.shared.operation(named: item.effect.operation))
        let editReason = NativeFilterMenuLayout.unavailableReason(
            NativeFilterCatalog.shared.operation(named: item.effect.operation)?.support ?? .needsConfig)
        let enable = entry("Enable", #selector(toggleEffectEnabled(_:)))
        enable.state = item.effect.isEnabled ? .on : .off
        var items = [
            entry("Edit Parameters…", #selector(editParametersOfItem(_:)),
                  enabled: editSupported,
                  toolTip: editSupported ? nil : "\(item.effect.name) \(editReason ?? "cannot be edited") — not supported yet."),
            entry("Properties…", #selector(propertiesOfItem(_:))),
            .separator(),
            enable,
        ]
        items.append(.separator())
        for (title, command) in [("Move Up", EngineSession.EffectCommand.raise),
                                 ("Move Down", .lower),
                                 ("Move to Top", .toTop),
                                 ("Move to Bottom", .toBottom)] {
            items.append(entry(title, #selector(runEffectCommand(_:)), tag: Int(command.rawValue)))
        }
        items.append(.separator())
        items.append(entry("Remove", #selector(runEffectCommand(_:)), tag: Int(EngineSession.EffectCommand.remove.rawValue)))
        items.append(entry("Merge", #selector(runEffectCommand(_:)), tag: Int(EngineSession.EffectCommand.merge.rawValue),
                           toolTip: "Bake the filter into the layer's pixels; the layer keeps no other filters editable after it."))
        return items
    }

    /// Whether the effect-row menu item can run now: the document takes
    /// edits and the effect is still on its drawable; per-command rules
    /// (position, mergeable, editable) apply on top.
    private func validateEffectItem(_ menuItem: NSMenuItem, _ item: EffectItem) -> Bool {
        guard let document, item.document === document, document.acceptsEdits,
              let stack = document.layerEffects[item.drawable],
              let index = stack.firstIndex(where: { $0.id == item.effect.id }) else { return false }
        let effect = stack[index]
        switch menuItem.action {
        case #selector(editParametersOfItem(_:)):
            return NativeFilterMenuLayout.supportsParameterEditor(
                NativeFilterCatalog.shared.operation(named: effect.operation))
        case #selector(toggleEffectEnabled(_:)):
            menuItem.state = effect.isEnabled ? .on : .off
            return true
        case #selector(runEffectCommand(_:)):
            guard let command = EngineSession.EffectCommand(rawValue: UInt32(menuItem.tag)) else { return false }
            return EffectCommands.enabled(command, at: index, of: stack.count, effect: effect,
                                          layer: document.layers.first { $0.id == item.drawable },
                                          locks: document.layerLocks[item.drawable]?.effective ?? [])
        default:
            return true
        }
    }

    /// Applies a row's change to the effect it was made for, and only
    /// while that effect is still on its drawable in the document the
    /// palette shows. Returns false when refused, so the row shows the
    /// effect's authoritative state again.
    private func commitEffectChange(_ item: EffectItem, _ change: EngineSession.EffectChange) -> Bool {
        guard let document, item.document === document, document.acceptsEdits,
              document.canChangeEffect(item.effect.id, on: item.drawable) else { return false }
        document.changeEffect(item.effect.id, on: item.drawable, change)
        return true
    }

    /// The row's Edit Parameters command and double-click: the generic
    /// form drives a live edit session on the effect's own stack
    /// position — the document window owns the nonmodal preview
    /// lifecycle, the palette only routes it there.
    private func editEffectParameters(_ item: EffectItem) {
        guard let document, item.document === document, document.acceptsEdits,
              document.canChangeEffect(item.effect.id, on: item.drawable),
              NativeFilterMenuLayout.supportsParameterEditor(
                NativeFilterCatalog.shared.operation(named: item.effect.operation))
        else { return }
        documentWindowController(for: document)?
            .editEffectParameters(item.effect.id, on: item.drawable, operationName: item.effect.operation)
    }

    /// The document window that owns `document`: the nonmodal parameter
    /// form lives on it, not on the palette.
    private func documentWindowController(for document: ImageDocument) -> DocumentWindowController? {
        NSApp.windows.lazy.compactMap { $0.windowController as? DocumentWindowController }
            .first { $0.imageDocument === document }
    }

    @objc private func editParametersOfItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? EffectItem else { return }
        editEffectParameters(item)
    }

    @objc private func propertiesOfItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? EffectItem,
              let document, item.document === document,
              let window = view.window else { return }
        EffectPropertiesForm.present(item: item, in: document, on: window)
    }

    @objc private func toggleEffectEnabled(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? EffectItem,
              let document, item.document === document,
              let current = document.layerEffects[item.drawable]?
                  .first(where: { $0.id == item.effect.id }) else { return }
        var change = EngineSession.EffectChange()
        change.isEnabled = !current.isEnabled
        _ = commitEffectChange(item, change)
    }

    @objc private func runEffectCommand(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? EffectItem,
              let command = EngineSession.EffectCommand(rawValue: UInt32(sender.tag)),
              let document, item.document === document, document.acceptsEdits,
              document.canChangeEffect(item.effect.id, on: item.drawable) else { return }
        document.effectCommand(command, effect: item.effect.id, on: item.drawable)
    }

    // MARK: Row context menu

    /// Rebuilds the outline's menu for the row under the right-click:
    /// an effect row gets its commands, anything else leaves the menu
    /// empty so nothing pops.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard menu === rowMenu, let document, outline.clickedRow >= 0,
              let item = outline.item(atRow: outline.clickedRow),
              let effect = snapshot.effect(for: item, for: document,
                                           currentEffects: document.layerEffects) else { return }
        effectMenuItems(for: effect).forEach { menu.addItem($0) }
    }

    /// Uses only the palette's captured document cache, never the front window.
    private func layerBatchAdmission(_ document: ImageDocument) -> Bool {
        let ids = document.selectedLayerIDs
        return document.acceptsEdits && !document.targetCommandIsPending
            && !document.floatingState.isActive && !ids.isEmpty
            && (ids.count == 1 || (ids.count <= 256
                && ids.allSatisfy { document.layerSources[$0]?.kind == .pixel }))
    }

    private func duplicateAdmission(_ document: ImageDocument) -> Bool {
        if document.storage.layout == .layeredLab {
            return document.acceptsLayerDuplicate && document.selectedLayerIDs.count == 1 &&
                !document.targetCommandIsPending && !document.floatingState.isActive
        }
        return layerBatchAdmission(document)
    }

    private func createAdmission(_ document: ImageDocument) -> Bool {
        if document.storage.layout == .layeredLab {
            return document.acceptsLayerCreate && document.selectedLayerIDs.count <= 1 &&
                !document.targetCommandIsPending && !document.floatingState.isActive
        }
        return document.acceptsEdits && !document.colorInfo.mode.usesNativeChannels && !document.floatingState.isActive
    }

    private func deleteAdmission(_ document: ImageDocument) -> Bool {
        if document.storage.layout == .layeredLab {
            return document.acceptsLayerDelete && document.selectedLayerIDs.count == 1 &&
                !document.targetCommandIsPending && !document.floatingState.isActive
        }
        return layerBatchAdmission(document)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if document?.colorInfo.mode.usesNativeChannels == true {
            guard menuItem.action == #selector(runLayerCommand(_:)),
                  (menuItem.tag == Int(EngineSession.LayerCommand.duplicate.rawValue) ||
                   menuItem.tag == Int(EngineSession.LayerCommand.new.rawValue) ||
                   menuItem.tag == Int(EngineSession.LayerCommand.delete.rawValue)),
                  document?.storage.layout == .layeredLab else { return false }
        }
        if let item = menuItem.representedObject as? EffectItem {
            return validateEffectItem(menuItem, item)
        }
        switch menuItem.action {
        case #selector(runSourceCommand(_:)):
            guard let captured = menuItem.representedObject as? ImageDocument,
                  document === captured, let owner = sourceWindow(for: captured) else { return false }
            let probe = NSMenuItem(title: menuItem.title, action: sourceAction(menuItem), keyEquivalent: "")
            let enabled = owner.validateMenuItem(probe)
            menuItem.title = probe.title
            menuItem.toolTip = probe.toolTip
            return enabled
        case #selector(runFloatingCommand(_:)):
            // Cached-state validation only: eligibility includes the
            // floating state, the target's cached pixel/source kind, and
            // busy/preview/closing/pending-target readiness. New Layer
            // is unavailable for mask/channel attachments and explains
            // why in its tooltip.
            guard let document, let command = EngineSession.FloatingCommand(rawValue: UInt32(menuItem.tag)) else {
                return false
            }
            let readiness = document.floatingResolutionReadiness(command)
            menuItem.toolTip = command == .toLayer
                ? (readiness.allowed ? FloatingControlsLogic.newLayerTooltip : readiness.reason)
                : readiness.reason
            return readiness.allowed
        case #selector(runLayerCommand(_:)):
            guard let document,
                  let command = EngineSession.LayerCommand(rawValue: UInt32(menuItem.tag)) else { return false }
            if command == .new && document.storage.layout == .layeredLab {
                return createAdmission(document)
            }
            if command == .duplicate || command == .delete {
                let verb = command == .duplicate ? "Duplicate" : "Delete"
                menuItem.title = "\(verb) \(document.hasMultipleSelectedLayers ? "Layers" : "Layer")"
                let admitted = command == .duplicate ? duplicateAdmission(document) : deleteAdmission(document)
                if document.storage.layout == .layeredLab {
                    menuItem.toolTip = admitted ? nil : "Select one logical layer to \(verb.lowercased())."
                } else {
                    menuItem.toolTip = admitted ? nil
                        : "Select ordinary pixel layers for a batch. \(verb) groups or editable sources individually."
                }
                return admitted
            }
            guard document.acceptsEdits else { return false }
            if command == .fitToImage {
                menuItem.title = document.hasMultipleSelectedLayers ? "Layers to Image Size" : "Layer to Image Size"
                if document.hasMultipleSelectedLayers {
                    let reason = document.fitSelectedLayersRefusal()
                    menuItem.toolTip = reason
                    return reason == nil
                }
            }
            // While more than one layer is selected, every single-layer
            // command but New Layer is disabled with the reason; New
            // Layer creates and selects a fresh row, which is safe.
            if LayerSelectionPolicy.gates(command) {
                if let reason = LayerSelectionPolicy.refusal(count: document.selectedLayerIDs.count,
                                                             action: LayerSelectionPolicy.actionTitle(for: command)) {
                    menuItem.toolTip = reason
                    return false
                }
                menuItem.toolTip = nil
            }
            // The resize commands are pixel-only, like Apply Mask: the
            // engine refuses groups and editable text, link and vector
            // layers, so those never offer them.
            if menuItem.tag == Int(EngineSession.LayerCommand.fitToImage.rawValue)
                || menuItem.tag == Int(EngineSession.LayerCommand.trimToContent.rawValue) {
                guard let active = document.activeLayer else { return false }
                return document.layers.first(where: { $0.id == active })?.kind == .pixel
                    && document.layerLocks[active]?.effective
                        .isDisjoint(with: [.pixels, .position]) != false
            }
            return menuItem.tag == Int(EngineSession.LayerCommand.new.rawValue) || document.activeLayer != nil
        case #selector(newLayerGroup(_:)):
            return document?.acceptsEdits == true
        case #selector(toggleLock(_:)):
            guard let document, let active = document.activeLayer else { return false }
            if document.hasMultipleSelectedLayers,
               let reason = LayerSelectionPolicy.refusal(count: document.selectedLayerIDs.count, action: "Lock") {
                menuItem.toolTip = reason
                return false
            }
            let lock = EngineSession.LayerLocks(rawValue: UInt32(menuItem.tag))
            let sources = snapshot.tree.nodesByID[active]
                .map { snapshot.tree.lockSources(for: $0, states: document.layerLocks) }
            menuItem.state = sources?.local.contains(lock) == true ? .on : .off
            menuItem.toolTip = DocumentWindowController.lockNote(lock, sources: sources)
            return document.acceptsEdits
        case #selector(addLayerMask(_:)), #selector(applyLayerMask(_:)),
             #selector(deleteLayerMask(_:)), #selector(maskToSelection(_:)),
             #selector(toggleMaskEnabled(_:)), #selector(toggleMaskEditing(_:)),
             #selector(toggleMaskShowing(_:)):
            // The active-layer mask commands are single-layer commands:
            // disabled with the reason while a multi-selection stands.
            guard let document, document.acceptsEdits, let active = document.activeLayer else { return false }
            if document.hasMultipleSelectedLayers,
               let reason = LayerSelectionPolicy.refusal(count: document.selectedLayerIDs.count,
                                                         action: menuItem.title) {
                menuItem.toolTip = reason
                return false
            }
            switch menuItem.action {
            case #selector(addLayerMask(_:)):
                return document.layers.first(where: { $0.id == active })?.hasMask == false
            case #selector(applyLayerMask(_:)):
                // Apply is raster-only; the engine refuses groups and
                // text, link and vector layers, so they never offer it.
                guard let layer = document.layers.first(where: { $0.id == active }) else { return false }
                return layer.hasMask && layer.kind == .pixel
            case #selector(deleteLayerMask(_:)), #selector(maskToSelection(_:)):
                return document.layers.first(where: { $0.id == active })?.hasMask == true
            default:
                guard let mask = document.maskStates[active] else { return false }
                switch menuItem.action {
                case #selector(toggleMaskEnabled(_:)):
                    menuItem.state = mask.enabled ? .on : .off
                case #selector(toggleMaskEditing(_:)):
                    menuItem.state = mask.editing ? .on : .off
                default:
                    menuItem.state = mask.showing ? .on : .off
                }
                return true
            }
        default:
            return true
        }
    }

    func retarget(to target: ImageDocument?) {
        PaletteEditScope.track(self)
        // Only a real target change forgets the synced selection: this
        // also runs for every state change of the shown document, and
        // resetting then would reopen its collapsed ancestors each time.
        if target !== document {
            targetGeneration += 1
            let generation = targetGeneration
            finishOpacityField()
            // A field-end callback can itself retarget the palette.
            guard generation == targetGeneration else { return }
            lastSyncedSelectionIDs = []
            selectedEffect = nil
            effectSelectionIsNew = false
        }
        document = target
        reload()
    }

    func reload() {
        syncOpacity()
        // Cancel obsolete reads before rebuilding rows. Workers consult
        // only this synchronized token; document and view state stays on
        // the main actor.
        for key in Array(thumbnailRequests.keys)
        where key.image != document?.image || key.version != document?.stateVersion {
            thumbnailRequests.removeValue(forKey: key)?.cancel()
            thumbnailWaiters.removeValue(forKey: key)?.forEach { $0(nil) }
        }
        let editable = document?.acceptsEdits == true && document?.colorInfo.mode.usesNativeChannels != true
        // While a floating selection is active the structural layer
        // commands are gated resolve-first, so their buttons go quiet too.
        let floatingActive = document?.floatingState.isActive == true
        // Duplicate and Delete admit bounded ordinary-pixel batches.
        buttonBar.setEnabled(document.map(createAdmission) == true, forItem: "new")
        buttonBar.setEnabled(editable && !floatingActive, forItem: "group")
        buttonBar.setEnabled(document.map(duplicateAdmission) == true, forItem: "duplicate")
        buttonBar.setEnabled(document.map(deleteAdmission) == true, forItem: "delete")
        // The floating-selection footer appears only while the shown
        // document's cached floating state is active; its buttons read
        // the cached readiness, never the engine.
        if let document, document.floatingState.isActive {
            floatingBar.update(document: document)
            floatingBar.isHidden = false
        } else {
            floatingBar.isHidden = true
        }

        // Reloading the rows would end a rename being typed and commit it
        // half done; the list catches up when the rename ends.
        guard !isRenaming else { return }

        reloading = true
        defer { reloading = false }
        let shown = document.map { ObjectIdentifier($0) }
        if shown != displayedDocument {
            if let previous = displayedDocument {
                expansionByDocument[previous] = expandedGroupIDs
            }
            expandedGroupIDs = shown.flatMap { expansionByDocument[$0] } ?? []
        }
        displayedDocument = shown

        snapshot = LayerListSnapshot(document: document, layers: document?.layers ?? [],
                                     effects: document?.layerEffects ?? [:])
        outline.reloadData()
        for id in expandedGroupIDs {
            if let node = snapshot.tree.nodesByID[id] { outline.expandItem(node) }
        }

        // An effect selection stands while its parent is still the paint
        // target and the effect is still on the stack; a retarget,
        // removal, new pick or mask/channel pick ends it.
        if let document, let selected = selectedEffect,
           document.activeLayer != selected.drawable
                || document.isMaskTargetActive || document.isChannelTargetActive
                || document.layerEffects[selected.drawable]?
                    .contains(where: { $0.id == selected.effect }) != true {
            selectedEffect = nil
            effectSelectionIsNew = false
        }

        // Re-apply the document's ordered multi-selection to the fresh
        // rows: every selected layer's row, primary included. All of
        // this runs under `reloading`, so the outline's selection change
        // fires no delegate mutation and a programmatic reload never
        // clears the native selection — rows that no longer resolve are
        // simply not re-selected, and the document reconciles them on
        // its next reload.
        var selectedItems: [Any] = []
        if document != nil, let selected = selectedEffect,
           let node = snapshot.tree.nodesByID[selected.drawable],
           let row = snapshot.effects(of: node).first(where: { $0.effect.id == selected.effect }) {
            if effectSelectionIsNew {
                // The row's parent and its group ancestors open once so
                // the picked effect can be seen.
                outline.expandItem(node)
                expandedGroupIDs.insert(node.id)
                var parent = node.parent
                while let group = parent {
                    outline.expandItem(group)
                    expandedGroupIDs.insert(group.id)
                    parent = group.parent
                }
                effectSelectionIsNew = false
            }
            selectedItems = [row]
        } else if let document {
            selectedItems = document.selectedLayerIDs.compactMap { snapshot.tree.nodesByID[$0] }
        }
        if let document, document.selectedLayerIDs != lastSyncedSelectionIDs {
            // A selection that landed inside a collapsed group opens its
            // parents once so the rows can be seen; opened ones count as
            // expanded like a user's own expansion.
            for item in selectedItems {
                guard let node = item as? LayerTree.Node else { continue }
                var parent = node.parent
                while let group = parent {
                    outline.expandItem(group)
                    expandedGroupIDs.insert(group.id)
                    parent = group.parent
                }
            }
        }
        let selectedRows = selectedItems.compactMap { outline.row(forItem: $0) }.filter { $0 >= 0 }
        if selectedRows.isEmpty {
            outline.deselectAll(nil)
        } else {
            outline.selectRowIndexes(IndexSet(selectedRows), byExtendingSelection: false)
        }
        lastSyncedSelectionIDs = document?.selectedLayerIDs ?? []
    }

    /// Whether a layer name in the list is being edited.
    private var isRenaming: Bool {
        LayerRowView.isRenaming(in: outline)
    }

    // MARK: Expansion tracking

    /// The groups a collapse is currently hiding: AppKit consults
    /// shouldCollapseItem for a collapsed item's descendants too, parent
    /// first, and their expansion is meant to survive, so a group stops
    /// counting as expanded only when nothing collapsing contains it.
    private var collapsingIDs = Set<Int32>()
    private var suppressingCollapseSelection = false
    private var collapseSelectionGeneration = 0

    private func restoreVisibleSelection() {
        guard !reloading, let document else { return }
        var items: [Any] = []
        if let selected = selectedEffect, let node = snapshot.tree.nodesByID[selected.drawable],
           let effect = snapshot.effects(of: node).first(where: { $0.effect.id == selected.effect }) {
            items = [effect]
        } else {
            items = document.selectedLayerIDs.compactMap { snapshot.tree.nodesByID[$0] }
        }
        let rows = items.map { outline.row(forItem: $0) }.filter { $0 >= 0 }
        reloading = true
        defer { reloading = false }
        outline.selectRowIndexes(IndexSet(rows), byExtendingSelection: false)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? LayerTree.Node else { return }
        if !reloading { expandedGroupIDs.insert(node.id) }
        // A group nested inside this node keeps its tracked expansion
        // while the node is collapsed, but expandItem cannot mark it
        // until the node expands again.
        for child in node.children where expandedGroupIDs.contains(child.id) {
            outline.expandItem(child)
        }
        restoreVisibleSelection()
    }

    func outlineView(_ outlineView: NSOutlineView, shouldCollapseItem item: Any) -> Bool {
        guard !reloading, let node = item as? LayerTree.Node else { return true }
        var ancestor = node.parent
        while let parent = ancestor {
            if collapsingIDs.contains(parent.id) { return true }
            ancestor = parent.parent
        }
        suppressingCollapseSelection = true
        collapseSelectionGeneration += 1
        expandedGroupIDs.remove(node.id)
        collapsingIDs.insert(node.id)
        return true
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard let node = notification.userInfo?["NSObject"] as? LayerTree.Node else { return }
        collapsingIDs.remove(node.id)
        guard collapsingIDs.isEmpty else { return }
        let generation = collapseSelectionGeneration
        // Selection notifications can follow didCollapse in the same
        // AppKit operation. Keep suppression through that whole turn.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.collapsingIDs.isEmpty,
                  self.collapseSelectionGeneration == generation else { return }
            self.suppressingCollapseSelection = false
            self.restoreVisibleSelection()
        }
    }

    // MARK: PaletteEditScope

    /// The document the palette's name and opacity fields belong to.
    var editTarget: ImageDocument? { document }

    /// The outline's double-click: edit a layer row's name in place;
    /// open an effect row's parameters.
    @objc private func editNameOfClickedRow(_ sender: NSOutlineView) {
        guard sender.clickedRow >= 0, let document else { return }
        if let effect = snapshot.effect(for: sender.item(atRow: sender.clickedRow), for: document,
                                        currentEffects: document.layerEffects) {
            editEffectParameters(effect)
            return
        }
        guard let row = sender.view(atColumn: 0, row: sender.clickedRow, makeIfNecessary: true) as? LayerRowView
        else { return }
        row.startEditingName()
    }

    /// Applies a row's change to the layer it was made for, and only while
    /// that layer is still in the document the palette shows. Returns false
    /// when the change was refused, so the row shows the layer's
    /// authoritative state again.
    private func commitLayerChange(_ context: LayerRowView.Context, _ change: EngineSession.LayerChange) -> Bool {
        guard let document, document.acceptsLayerProperties,
              (document.acceptsEdits || change.isLimitedLayerPropertyChange),
              (change.name == nil || document.acceptsLayerRename),
              LayerRowView.canChange(context, document: document, layers: document.layers) else { return false }
        document.changeLayer(context.layerID, change)
        return true
    }

    /// The text of one row, also used by the engine smoke test.
    static func title(for layer: EngineSession.Layer) -> String {
        let indent = String(repeating: "    ", count: layer.depth)
        let eye = layer.isVisible ? "●" : "○"
        return "\(indent)\(eye) \(layer.name)\(Self.detailsSuffix(for: layer))"
    }

    /// The trailing row details: kind, mask, filter count, and the
    /// temporary floating-selection marker for the native floating row.
    static func detailsSuffix(for layer: EngineSession.Layer, floating: Bool = false) -> String {
        var details: [String] = []
        switch layer.kind {
        case .group: details.append("group")
        case .text: details.append("text")
        case .link: details.append("linked")
        case .vector: details.append("vector")
        case .pixel: break
        }
        if layer.hasMask { details.append("mask") }
        if layer.filterCount > 0 { details.append("\(layer.filterCount) filter\(layer.filterCount == 1 ? "" : "s")") }
        if floating { details.append("floating selection") }
        return details.isEmpty ? "" : "  (\(details.joined(separator: ", ")))"
    }

    // MARK: Outline data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil { return snapshot.tree.roots.count }
        guard let node = item as? LayerTree.Node else { return 0 }
        return snapshot.displayedChildren(of: node).count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil { return snapshot.tree.roots[index] }
        guard let node = item as? LayerTree.Node else { return NSNull() }
        return snapshot.displayedChildren(of: node)[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        guard let node = item as? LayerTree.Node else { return false }
        // A layer's committed effects show as its subrows; a group keeps
        // its layer children on top of them.
        if !snapshot.effects(of: node).isEmpty { return true }
        return node.layer.kind == .group && !node.children.isEmpty
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let document else { return nil }
        if let effect = snapshot.effect(for: item, for: document,
                                        currentEffects: document.layerEffects) {
            let isSelected = selectedEffect?.drawable == effect.drawable
                && selectedEffect?.effect == effect.effect.id
            let rowView = EffectRowView(item: effect, isSelected: isSelected) { [weak self] item, change in
                self?.commitEffectChange(item, change) ?? false
            }
            rowView.eye.isEnabled = document.acceptsEdits
            return rowView
        }
        guard let layer = snapshot.layer(for: item, for: document, currentLayers: document.layers),
              let node = item as? LayerTree.Node else { return nil }
        let locks = snapshot.tree.lockSources(for: node, states: document.layerLocks)
        let mask = document.maskStates[layer.id]
        let target: ThumbnailButton.Target = document.activeLayer == layer.id
            ? (document.isMaskTargetActive ? .mask : .layer) : .none
        // The native floating layer shows as a temporary row, labelled so.
        let isFloating = document.floatingState.isActive && document.floatingState.floating == layer.id
        let rowView = LayerRowView(layer: layer,
                                   context: LayerRowView.Context(document: document, layerID: layer.id),
                                   details: Self.detailsSuffix(for: layer, floating: isFloating),
                                   locks: locks, mask: mask, activeTarget: target) { [weak self] context, change in
            self?.commitLayerChange(context, change) ?? false
        }
        rowView.checkbox.isEnabled = document.acceptsLayerProperties
        rowView.nameField.isEditable = document.acceptsLayerRename
        rowView.layerThumb.isEnabled = document.acceptsLayerSelection
        rowView.maskThumb?.isEnabled = document.acceptsEdits
        rowView.onThumbnail = { [weak self, weak rowView] pick, option in
            guard let self, let rowView else { return }
            self.thumbnailPicked(pick, option, row: rowView)
        }
        rowView.onEditEnded = { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        }
        if document.storage.layout != .layeredLab {
            requestThumbnails(layer: layer, mask: mask, into: rowView, document: document)
        }
        return rowView
    }

    /// A row thumbnail's click, with the stale guards every row edit
    /// takes: the document must still be the palette's target and the
    /// layer still in it.
    private func thumbnailPicked(_ pick: LayerRowView.ThumbnailPick, _ option: Bool,
                                 row: LayerRowView) {
        guard let document, document.acceptsLayerSelection,
              LayerRowView.canChange(row.context, document: document, layers: document.layers)
        else { return }
        switch (pick, option) {
        case (.layer, _):
            document.selectLayer(row.context.layerID)
        case (.mask, true):
            guard document.acceptsEdits else { return }
            // Option-click is View Mask, a display flag on that layer.
            document.toggleMaskShowing(row.context.layerID)
        case (.mask, false):
            guard document.acceptsEdits else { return }
            document.editMask(row.context.layerID)
        }
    }

    /// Reads `drawable`'s bounded thumbnail off the main thread and hands
    /// it to `apply` only while the document and state version it was
    /// read for still stand — a retarget, reload or removal makes the
    /// result stale and it is dropped, never painted onto a newer row.
    private func requestThumbnails(layer: EngineSession.Layer, mask: EngineSession.MaskState?,
                                   into row: LayerRowView, document: ImageDocument) {
        let version = document.stateVersion
        loadThumbnail(document: document, drawable: layer.id, version: version) { image in
            row.layerThumb.thumbnail = image
        }
        if let mask, mask.mask != 0 {
            loadThumbnail(document: document, drawable: mask.mask, version: version) { image in
                row.maskThumb?.thumbnail = image
            }
        }
    }

    private func loadThumbnail(document: ImageDocument, drawable: Int32, version: Int,
                               apply: @escaping (NSImage?) -> Void) {
        let key = ThumbnailKey(image: document.image, drawable: drawable, version: version)
        if let cached = thumbnailCache[key] { return apply(cached) }
        if thumbnailWaiters[key] != nil {
            thumbnailWaiters[key]?.append(apply)
            return
        }
        thumbnailWaiters[key] = [apply]
        let request = ThumbnailRequest()
        thumbnailRequests[key] = request
        let maxSize = Self.thumbnailMaxSize
        let owner = ObjectIdentifier(document)
        // Count the read in the document's input queue, so close, Quit
        // and exclusive engine operations drain it before destruction.
        let accepted = document.run(effect: .readsPixels) { [weak self] session, imageID in
            guard !request.isCancelled else { return }
            let cgImage = try? session.drawableThumbnail(drawable, image: imageID,
                                                         maxSize: maxSize)
            DispatchQueue.main.async {
                guard let self, self.thumbnailRequests[key] === request else { return }
                self.thumbnailRequests.removeValue(forKey: key)
                let waiters = self.thumbnailWaiters.removeValue(forKey: key) ?? []
                guard let document = self.document,
                      ObjectIdentifier(document) == owner, document.stateVersion == version
                else { return waiters.forEach { $0(nil) } }
                let image = cgImage.map {
                    NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height))
                }
                if let image {
                    if self.thumbnailCache.count > 512 { self.thumbnailCache.removeAll() }
                    self.thumbnailCache[key] = image
                }
                waiters.forEach { $0(image) }
            }
        }
        if !accepted {
            thumbnailRequests.removeValue(forKey: key)?.cancel()
            thumbnailWaiters.removeValue(forKey: key)?.forEach { $0(nil) }
        }
    }

    // MARK: Selection

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        guard let document else { return false }
        if let effect = snapshot.effect(for: item, for: document,
                                        currentEffects: document.layerEffects) {
            guard document.acceptsEdits else {
                // The pick is refused; asking the document still shows why.
                document.selectLayer(effect.drawable)
                return false
            }
            return true
        }
        guard let layer = snapshot.layer(for: item, for: document,
                                         currentLayers: document.layers) else { return false }
        guard document.acceptsLayerSelection else {
            // The pick is refused; asking the document still shows why.
            document.selectLayer(layer.id)
            return false
        }
        return true
    }

    /// The outline's selection changed — a user click, Shift-range or
    /// Command-toggle, or a programmatic change outside a reload. Maps
    /// the actual selected row ids through the snapshot and asks the
    /// document for the ordered selection. Stale rows (a layer gone
    /// since the snapshot was built) and an emptied selection refuse:
    /// nothing is sent to the engine and the list refreshes, which
    /// re-applies the native selection — the native selection is never
    /// cleared as a side effect.
    func outlineViewSelectionDidChange(_ notification: Notification) {
        // AppKit adjusts visible selected rows while a group collapses.
        // It is not a layer pick; rebuilding rows here also invalidates
        // the item objects the outline is still collapsing.
        guard !reloading, !suppressingCollapseSelection, collapsingIDs.isEmpty, let document else { return }
        let rows = outline.selectedRowIndexes
        // A single effect-row pick keeps its existing meaning: the
        // parent layer becomes the paint home and the effect stays
        // marked. Effect rows never join a layer multi-selection.
        if rows.count == 1, let item = outline.item(atRow: rows.first!),
           let effect = snapshot.effect(for: item, for: document,
                                        currentEffects: document.layerEffects) {
            selectedEffect = (effect.drawable, effect.effect.id)
            effectSelectionIsNew = true
            document.selectLayer(effect.drawable)
            lastSyncedSelectionIDs = document.selectedLayerIDs
            // A refused pick leaves the active layer elsewhere; the
            // effect selection cannot stand without its parent target.
            if document.activeLayer != effect.drawable {
                selectedEffect = nil
                effectSelectionIsNew = false
                reload()
            }
            return
        }
        var rowIDs: [Int32] = []
        var stale = false
        for row in rows {
            guard let item = outline.item(atRow: row) else { stale = true; continue }
            if snapshot.effect(for: item, for: document,
                               currentEffects: document.layerEffects) != nil { continue }
            if let layer = snapshot.layer(for: item, for: document, currentLayers: document.layers) {
                rowIDs.append(layer.id)
            } else {
                stale = true
            }
        }
        selectedEffect = nil
        effectSelectionIsNew = false
        guard !stale, let ordered = LayerSelectionPolicy.resolveSelection(
            previous: document.selectedLayerIDs, rowIDs: rowIDs) else {
            // Refused: refresh the rows from the document's authoritative
            // selection; the engine's selection is left untouched.
            reload()
            return
        }
        document.selectLayers(ordered)
        lastSyncedSelectionIDs = document.selectedLayerIDs
        // A refused pick (floating selection resolve-first, closing,
        // busy) leaves the document's selection elsewhere; the list
        // shows the native selection again.
        if document.selectedLayerIDs != ordered { reload() }
    }

    // MARK: Drag and drop

    func outlineView(_ outlineView: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        guard let document, document.acceptsEdits,
              let layer = snapshot.layer(for: item, for: document, currentLayers: document.layers)
        else { return nil }
        let writer = NSPasteboardItem()
        writer.setString("\(layer.id)", forType: Self.dragType)
        return writer
    }

    /// Where the drop lands, as the document's `moveLayer` understands it:
    /// a parent id (0: the top level) and a raw index among its children.
    /// Drops onto a group go to its first child; positions inside a
    /// parent's effect prefix are not layer positions and are refused.
    private func dropTarget(item: Any?, childIndex index: Int) -> (parent: Int32, index: Int32)? {
        if index == NSOutlineViewDropOnItemIndex {
            guard let node = item as? LayerTree.Node, node.layer.kind == .group else { return nil }
            return (node.id, 0)
        }
        guard let node = item as? LayerTree.Node else {
            return item == nil ? (0, Int32(index)) : nil
        }
        return LayerListSnapshot.layerChildIndex(forDisplayedIndex: index,
                                                 effectCount: snapshot.effects(of: node).count)
            .map { (node.id, Int32($0)) }
    }

    private func draggedID(_ info: NSDraggingInfo) -> Int32? {
        info.draggingPasteboard.string(forType: Self.dragType).flatMap(Int32.init)
    }

    func outlineView(_ outlineView: NSOutlineView, validateDrop info: NSDraggingInfo,
                     proposedItem item: Any?, proposedChildIndex index: Int) -> NSDragOperation {
        // Drag-drop reorder is a single-layer structural command: no
        // drop is offered while a multi-selection stands.
        guard let document, document.acceptsEdits, !document.hasMultipleSelectedLayers,
              let dragged = draggedID(info),
              let target = dropTarget(item: item, childIndex: index),
              snapshot.tree.resolveDrop(item: dragged, ontoParent: target.parent, at: target.index) != .invalid
        else { return [] }
        return .move
    }

    func outlineView(_ outlineView: NSOutlineView, acceptDrop info: NSDraggingInfo,
                     item: Any?, childIndex index: Int) -> Bool {
        guard let document, document.acceptsEdits, !document.hasMultipleSelectedLayers,
              let dragged = draggedID(info),
              let target = dropTarget(item: item, childIndex: index) else { return false }
        document.moveLayer(dragged, toParent: target.parent, atIndex: target.index)
        if let node = item as? LayerTree.Node { outline.expandItem(node) }
        return true
    }
}
