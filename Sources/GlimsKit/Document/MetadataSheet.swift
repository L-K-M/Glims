import AppKit

/// Pure logic behind Image ▸ Metadata…: the domain table, the full-tag
/// catalog search, the dotted-name rule for adding a registered tag, the
/// read-only (normalization-protected) tag list, the cached admission
/// policy, the descriptor-driven write gates (facade slot 128), the
/// ordered value-draft edits and the per-action capture. No AppKit state
/// and no engine calls, so the rules are unit-testable without an
/// engine.
enum MetadataSheetLogic {
    /// A local validation refusal shown in the sheet's error row.
    struct Rejection: Error, Equatable {
        let message: String
    }

    /// What one accepted sheet action asks the document to do.
    enum Action: Equatable {
        /// Replace the tag's whole value list (requires ≥ 1 value).
        case setValues
        /// Erase the tag.
        case removeTag
    }

    /// The explicit snapshot of one accepted action: the image, the tag,
    /// the action and the ordered value array captured by value at the
    /// moment the action was accepted — never re-read from a stale row
    /// index or the front document.
    struct Capture: Equatable {
        let image: Int32
        let tag: String
        let action: Action
        /// The ordered value-array snapshot; empty for `removeTag`.
        let values: [String]
    }

    /// The domain popup's entries, in display order.
    static let domains: [(EngineSession.MetadataDomain, String)] = [
        (.exif, "EXIF"), (.iptc, "IPTC"), (.xmp, "XMP"),
    ]

    static func domainTitle(_ domain: EngineSession.MetadataDomain) -> String {
        domains.first { $0.0 == domain }?.1 ?? "EXIF"
    }

    /// The native dotted-name prefix of `domain` (`Exif.`/`Iptc.`/`Xmp.`).
    static func domainPrefix(_ domain: EngineSession.MetadataDomain) -> String {
        switch domain {
        case .exif: return "Exif."
        case .iptc: return "Iptc."
        case .xmp: return "Xmp."
        }
    }

    /// Full-catalog search: case-insensitive substring over the
    /// complete tag list, order preserved, never truncated. An empty
    /// query returns the whole catalog.
    static func filterTags(_ tags: [String], query: String) -> [String] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return tags }
        return tags.filter { $0.lowercased().contains(needle) }
    }

    /// The dotted-name rule for Add Tag: non-empty, valid UTF-8, no NUL
    /// (mirroring the facade's own bridge validation), with the prefix
    /// of the chosen domain — the native registry then validates the
    /// tag's registration and type and reports NOT_FOUND itself.
    static func validateNewTagName(_ text: String, domain: EngineSession.MetadataDomain) -> Result<String, Rejection> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .failure(Rejection(message: "Enter a dotted tag name, for example \(domainPrefix(domain))Image.Artist."))
        }
        guard !trimmed.utf8.contains(0) else {
            return .failure(Rejection(message: "A tag name cannot contain a NUL character."))
        }
        let prefix = domainPrefix(domain)
        guard trimmed.hasPrefix(prefix) else {
            return .failure(Rejection(message: "In the \(domainTitle(domain)) domain, tag names start with \"\(prefix)\"."))
        }
        guard trimmed.count > prefix.count else {
            return .failure(Rejection(message: "The tag name after \"\(prefix)\" is empty."))
        }
        return .success(trimmed)
    }

    /// The tags `gimp_image_set_metadata` rewrites from the image's own
    /// state on every metadata change, so the facade refuses SET and
    /// REMOVE on them with UNSUPPORTED (source-verified list from
    /// `app/core/gimpimage-metadata.c`, `gimp_image_metadata_update_*` —
    /// recorded in docs/image-metadata.md). They are shown read-only.
    static let protectedTags: Set<String> = [
        "Exif.Image.ImageWidth", "Exif.Image.ImageLength", "Exif.Image.BitsPerSample",
        "Exif.Image.XResolution", "Exif.Image.YResolution", "Exif.Image.ResolutionUnit",
        "Exif.Photo.ColorSpace",
        "Exif.Photo.PixelXDimension", "Exif.Photo.PixelYDimension", "Xmp.exif.ColorSpace",
        "Exif.Iop.InteroperabilityIndex", "Exif.Nikon3.ColorSpace", "Exif.Canon.ColorSpace",
    ]

    static func isProtected(_ tag: String) -> Bool { protectedTags.contains(tag) }

    static let protectedNote = "This tag is read-only: the engine rewrites it from the image's own "
        + "state on every metadata change, so edits to it are refused."

    /// Language-alternative (XMP LangAlt) values are read as the native
    /// labeled fragments, not as plain text or a lossless language/value
    /// structure. Edits are refused; the sheet shows them read-only.
    static let langAltNote = "This text can have different versions for different languages. "
        + "Language alternatives are read-only."

    // MARK: Descriptor-driven gates (facade slot 128 policy)

    /// The gates the native tag descriptor puts on the selected tag's
    /// controls. `canSet` and `canRemove` are independent: an absent XMP
    /// container admits REMOVE (a native no-op) but not SET. `canAddValue`
    /// additionally needs a multiple-value kind. `isReadOnly` marks tags
    /// whose descriptor admits no edit at all (LangAlt, protected). The
    /// policy bits describe the tag's format only: a real accepted write
    /// can still fail (BUSY, copy preservation, native validation), and
    /// that native refusal is then reported unchanged. `refusal` is the
    /// actionable reason shown while writes are disabled.
    struct DescriptorGates: Equatable {
        let canSet: Bool
        let canRemove: Bool
        let canAddValue: Bool
        let isReadOnly: Bool
        let refusal: String?
    }

    /// The read-only reason for language-alternative tags: Glims can show
    /// them but cannot safely change them yet, so the controls stay
    /// read-only.
    static let langAltReadOnlyReason = "This text can have different versions for different languages. "
        + "Language alternatives are read-only."

    /// Computes the descriptor gates for the selected tag. Fails closed:
    /// without a successfully read descriptor AND values list for the same
    /// current selection, no write is enabled — never a stale descriptor
    /// or a hardcoded permissive policy. When the descriptor is known it
    /// is authoritative for the format policy; the local protected list
    /// stays only as the conservative fallback while it is not.
    static func writeGates(descriptor: EngineSession.MetadataTagInfo?,
                           valuesReady: Bool,
                           locallyProtected: Bool) -> DescriptorGates {
        guard valuesReady, let info = descriptor else {
            return DescriptorGates(canSet: false, canRemove: false, canAddValue: false,
                                   isReadOnly: locallyProtected,
                                   refusal: valuesReady
                                       ? "The tag descriptor is still loading or could not be read; writes stay disabled."
                                       : "The tag's values are still loading or could not be read; writes stay disabled.")
        }
        let langAlt = info.valueKind == .langAlt
        let canSet = !langAlt && info.formatPolicy.contains(.supportsSet)
        let canRemove = !langAlt && info.formatPolicy.contains(.supportsRemove)
        // A single-value kind (or a tag the native registry says holds one
        // value) cannot gain a second value; LangAlt stays read-only
        // despite its native multiple-value flag.
        let multipleAllowed = !langAlt && info.valueKind != .single && info.supportsMultiple
        let readOnly = langAlt || (!canSet && !canRemove)
        let refusal: String?
        if langAlt {
            refusal = langAltReadOnlyReason
        } else if !canSet && canRemove {
            refusal = "The tag's format policy does not allow setting it from here (a new XMP "
                + "container needs a chosen array type); Remove Tag remains available."
        } else if readOnly {
            refusal = locallyProtected ? protectedNote : "The engine's descriptor admits no edits to this tag."
        } else {
            refusal = nil
        }
        return DescriptorGates(canSet: canSet, canRemove: canRemove,
                               canAddValue: canSet && multipleAllowed,
                               isReadOnly: readOnly, refusal: refusal)
    }

    /// A queued read's completion may land only for the same tag and the
    /// still-current generation; anything older, for another tag, or after
    /// a close is stale and must not update the sheet.
    static func readIsCurrent(tag: String, generation: Int, selectedTag: String?, currentGeneration: Int) -> Bool {
        tag == selectedTag && generation == currentGeneration
    }

    /// The compact descriptor title: the native label (falling back to the
    /// dotted tag name) plus the native type name.
    static func descriptorTitle(tag: String, info: EngineSession.MetadataTagInfo) -> String {
        let label = info.label.isEmpty ? tag : info.label
        return info.typeName.isEmpty ? label : "\(label) — \(info.typeName)"
    }

    /// The descriptor's presence line for the selected tag.
    static func descriptorPresenceText(_ info: EngineSession.MetadataTagInfo) -> String {
        info.present ? "Present on this image." : "Not present on this image yet."
    }

    /// Cached admission for a write (Apply / Remove Tag / Add Tag). Reads
    /// only cached state — never the engine — so menu validation and the
    /// sheet's gates make no native call. Image metadata is image-level:
    /// pixel/alpha locks and layer/mask/channel target types are NOT
    /// part of this gate.
    static func writeAdmission(isClosing: Bool, isSavingForClose: Bool, isTransferringClipboard: Bool,
                               pluginRunning: Bool, engineBusy: Bool, filterPreviewOpen: Bool) -> String? {
        if isClosing { return ImageDocument.DocumentError.closed.localizedDescription }
        if isSavingForClose || isTransferringClipboard { return ImageDocument.DocumentError.busy.localizedDescription }
        if engineBusy, !pluginRunning { return "Wait for the current image operation to finish." }
        if filterPreviewOpen { return "Apply or cancel the filter preview first." }
        if pluginRunning { return "Finish or cancel the running plug-in first." }
        return nil
    }

    /// A SET commits the whole ordered value array and requires at least
    /// one value — an empty list is not a SET (the backend refuses it);
    /// a single empty string is still one value. Use Remove Tag to
    /// erase. Empty strings, duplicates, newlines and order pass through
    /// exactly as captured; nothing is split, joined, trimmed or
    /// deduplicated.
    static func validateSetValues(_ values: [String]) -> Result<[String], Rejection> {
        guard !values.isEmpty else {
            return .failure(Rejection(message: "An empty value list is not a set: the backend requires at least one "
                            + "value (a single empty string is still a value). Use Remove Tag to erase the tag."))
        }
        return .success(values)
    }

    /// Draft edits are pure array operations on the ordered value list:
    /// Add appends one empty string (a real value), Remove deletes the
    /// explicit selected index (nil when out of range), Replace writes
    /// the editor's text — newlines included — at the explicit index.
    static func addValue(to values: [String]) -> [String] { values + [""] }

    static func removeValue(at index: Int, from values: [String]) -> [String]? {
        guard index >= 0, index < values.count else { return nil }
        var copy = values
        copy.remove(at: index)
        return copy
    }

    static func replaceValue(at index: Int, with text: String, in values: [String]) -> [String]? {
        guard index >= 0, index < values.count else { return nil }
        var copy = values
        copy[index] = text
        return copy
    }
}

/// Image ▸ Metadata…: the per-document metadata sheet. The owning window
/// controller retains this controller for the sheet's lifetime and captures
/// its own document at open, so two documents keep independent sheets and
/// every action acts on the captured document — never on the front one.
///
/// Reads (tag catalog per domain, ordered values of the selected tag) and
/// writes (Apply = SET of the whole captured value array, Remove Tag,
/// Add Tag by dotted name) are all asynchronous counted document work
/// through ImageDocument's input queue — no native call on the main
/// thread, and close drains them before the image is destroyed. The full
/// tag list of the chosen EXIF/IPTC/XMP domain is searched locally, never
/// truncated. Values are separate list rows plus a multiline editor for
/// the selected value; Add Value / Remove Value edit a LOCAL draft and
/// Apply commits the captured whole value array, preserving every empty
/// string, duplicate, newline and the order exactly. A successful change
/// reloads; a refusal (UNSUPPORTED, NOT_FOUND, INVALID_ARGUMENT, BUSY)
/// is shown unchanged in the persistent error row and never updates the
/// rows or the draft as if accepted. Normalization-protected tags are
/// read-only. The selected tag's native descriptor (facade slot 128) is
/// read as counted queued work alongside its values: its label, type
/// name, presence and description are shown compactly, and its own
/// valueKind/supportsMultiple/formatPolicy gate SET and REMOVE
/// separately — a pending or failed descriptor or values read fails
/// closed with an actionable reason, LangAlt is visibly read-only before
/// any native edit could fail, and an absent XMP container keeps Remove
/// Tag enabled while Apply stays disabled. The policy bits describe the
/// format only; a real accepted write can still refuse natively and is
/// then shown unchanged. The descriptor refreshes after Apply/Remove and
/// Undo/Redo without ever overwriting a dirty local draft. Close
/// discards the unapplied draft; applied changes stay and are undoable
/// — closing never implies a rollback. Late callbacks after invalidation
/// or a newer selection/generation do nothing.
@MainActor
final class MetadataSheetController: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSTextViewDelegate {
    let document: ImageDocument
    private(set) var panel: NSPanel
    private weak var hostWindow: NSWindow?

    private let domainPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let searchField = NSTextField(string: "")
    private let addTagField = NSTextField(string: "")
    private let addTagButton = NSButton(title: "Add Tag", target: nil, action: nil)
    private let tagTable = NSTableView(frame: .zero)
    private let valuesTable = NSTableView(frame: .zero)
    private let valueEditor = NSTextView(frame: .zero)
    private let addValueButton = NSButton(title: "Add Value", target: nil, action: nil)
    private let removeValueButton = NSButton(title: "Remove Value", target: nil, action: nil)
    private let applyButton = NSButton(title: "Apply", target: nil, action: nil)
    private let removeTagButton = NSButton(title: "Remove Tag", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private let noteLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let descriptorTitleLabel = NSTextField(labelWithString: "")
    private let descriptorPresenceLabel = NSTextField(labelWithString: "")
    private let descriptorDescriptionText = NSTextView(frame: .zero)
    private let hintLabel = NSTextField(labelWithString:
        "Values are separate rows; edit the selected one in the text field. Apply commits the whole "
        + "list in order — one undo step. Close discards only unapplied draft edits; applied changes stay undoable.")

    /// The full tag catalog of the current domain as last loaded; the
    /// table shows `MetadataSheetLogic.filterTags` of it, never truncated.
    private var allTags: [String] = []
    /// The selected tag by NAME (never a stale row index), preserved
    /// across asynchronous reloads when still present.
    private(set) var selectedTag: String?
    /// The local draft: the ordered value array of `selectedTag`.
    private var draft: [String] = []
    private var draftIsDirty = false
    private(set) var selectedValueIndex: Int?
    /// Bumped on every tag-list load request; a completion from an older
    /// generation is dropped, so it cannot overwrite a newer list.
    private var tagLoadGeneration = 0
    /// Bumped on every tag selection change; a values completion from an
    /// older generation — or for another tag — is dropped, so it cannot
    /// clobber a newer selection's draft.
    private var valuesGeneration = 0
    private var valuesAreLoading = false
    /// True only when the values read succeeded for the current selection
    /// and generation; a pending or failed values read leaves it false, so
    /// writes fail closed instead of falling back to stale info.
    private var valuesReady = false
    /// Bumped on every tag selection change together with
    /// `valuesGeneration`; a descriptor completion from an older
    /// generation — or for another tag — is dropped, so it cannot land on
    /// a newer selection.
    private var descriptorGeneration = 0
    private var descriptorIsLoading = false
    private var descriptorReadError: String?
    /// The last successfully read descriptor of the CURRENTLY selected
    /// tag; nil while pending, failed, or after a selection/domain/close
    /// invalidation. It holds format facts only — it never rewrites the
    /// local draft.
    private(set) var tagDescriptor: EngineSession.MetadataTagInfo?
    private var updatingTagRows = false
    private var lastDocumentStateVersion = -1
    /// The undo signature the tag list was last loaded against; a change
    /// (e.g. undo/redo of a metadata edit) triggers one refresh.
    private var lastUndoSignature: EngineSession.UndoInfo?
    /// Set while the editor is written programmatically, so its
    /// textDidChange does not write the draft back.
    private var updatingEditor = false
    private var isApplying = false
    /// Set on close; late callbacks then do nothing.
    private var isInvalidated = false
    /// The last validation or native refusal shown in the error row.
    private(set) var lastError: String?
    /// The snapshot of the last accepted action, for inspection.
    private(set) var lastCapture: MetadataSheetLogic.Capture?

    init(document: ImageDocument, hostWindow: NSWindow) {
        self.document = document
        self.hostWindow = hostWindow
        self.panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 470),
                             styleMask: [.titled, .closable, .utilityWindow],
                             backing: .buffered, defer: false)
        super.init()
        panel.title = "Metadata"
        buildContent()
        updateControlStates()
        loadTags()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var domain: EngineSession.MetadataDomain {
        let index = domainPopup.indexOfSelectedItem
        return MetadataSheetLogic.domains[min(max(index, 0), MetadataSheetLogic.domains.count - 1)].0
    }

    private var filteredRows: [String] {
        MetadataSheetLogic.filterTags(allTags, query: searchField.stringValue)
    }

    // MARK: Layout

    private func buildContent() {
        domainPopup.addItems(withTitles: MetadataSheetLogic.domains.map(\.1))
        domainPopup.setAccessibilityLabel("Metadata domain")
        domainPopup.target = self
        domainPopup.action = #selector(domainChanged(_:))

        searchField.setAccessibilityLabel("Filter tags")
        searchField.placeholderString = "Filter tags"
        searchField.delegate = self
        searchField.widthAnchor.constraint(equalToConstant: 150).isActive = true

        addTagField.setAccessibilityLabel("New tag name")
        addTagField.placeholderString = "Exif.Image.Artist"
        addTagField.delegate = self
        addTagField.widthAnchor.constraint(equalToConstant: 170).isActive = true
        addTagButton.setAccessibilityLabel("Add tag")
        addTagButton.target = self
        addTagButton.action = #selector(addTag(_:))

        tagTable.dataSource = self
        tagTable.delegate = self
        tagTable.allowsMultipleSelection = false
        tagTable.allowsEmptySelection = true
        tagTable.usesAlternatingRowBackgroundColors = true
        tagTable.setAccessibilityLabel("Metadata tag list")
        tagTable.headerView = nil
        let tagColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("tag"))
        tagColumn.title = "Tag"
        tagTable.addTableColumn(tagColumn)
        let tagScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 270, height: 210))
        tagScroll.documentView = tagTable
        tagScroll.hasVerticalScroller = true
        tagScroll.hasHorizontalScroller = false
        tagScroll.borderType = .bezelBorder
        tagTable.frame = NSRect(x: 0, y: 0, width: 270, height: 210)

        valuesTable.dataSource = self
        valuesTable.delegate = self
        valuesTable.allowsMultipleSelection = false
        valuesTable.allowsEmptySelection = true
        valuesTable.usesAlternatingRowBackgroundColors = true
        valuesTable.setAccessibilityLabel("Metadata value list")
        valuesTable.headerView = nil
        let valueColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("value"))
        valueColumn.title = "Values"
        valuesTable.addTableColumn(valueColumn)
        let valuesScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 330, height: 100))
        valuesScroll.documentView = valuesTable
        valuesScroll.hasVerticalScroller = true
        valuesScroll.hasHorizontalScroller = false
        valuesScroll.borderType = .bezelBorder
        valuesTable.frame = NSRect(x: 0, y: 0, width: 330, height: 100)

        let editorScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 330, height: 100))
        editorScroll.hasVerticalScroller = true
        editorScroll.hasHorizontalScroller = false
        editorScroll.borderType = .bezelBorder
        valueEditor.minSize = NSSize(width: 330, height: 100)
        valueEditor.maxSize = NSSize(width: 10000, height: 10000)
        valueEditor.isRichText = false
        valueEditor.allowsUndo = true
        valueEditor.delegate = self
        valueEditor.setAccessibilityLabel("Selected metadata value editor")
        editorScroll.documentView = valueEditor
        valueEditor.frame = NSRect(x: 0, y: 0, width: 330, height: 100)

        addValueButton.setAccessibilityLabel("Add metadata value")
        removeValueButton.setAccessibilityLabel("Remove metadata value")
        applyButton.setAccessibilityLabel("Apply metadata values")
        removeTagButton.setAccessibilityLabel("Remove metadata tag")
        closeButton.setAccessibilityLabel("Close metadata sheet")
        noteLabel.setAccessibilityLabel("Metadata note")
        messageLabel.setAccessibilityLabel("Metadata message")
        hintLabel.setAccessibilityLabel("Metadata hint")
        for (button, action) in [(addValueButton, #selector(addValue(_:))),
                                 (removeValueButton, #selector(removeValue(_:))),
                                 (applyButton, #selector(apply(_:))),
                                 (removeTagButton, #selector(removeTag(_:))),
                                 (closeButton, #selector(close(_:)))] {
            button.target = self
            button.action = action
        }
        applyButton.keyEquivalent = "\r"
        closeButton.keyEquivalent = "\u{1b}"
        for label in [noteLabel, messageLabel, hintLabel] {
            label.lineBreakMode = .byWordWrapping
            label.maximumNumberOfLines = 2
        }
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        noteLabel.maximumNumberOfLines = 3

        // The native descriptor of the selected tag: compact wrapping
        // title/presence lines plus the description in a fixed-height
        // scrolling text, so a long native description never reflows or
        // resizes the sheet under the pointer.
        descriptorTitleLabel.setAccessibilityLabel("Metadata tag descriptor")
        descriptorPresenceLabel.setAccessibilityLabel("Metadata tag presence")
        descriptorDescriptionText.setAccessibilityLabel("Metadata tag description")
        descriptorTitleLabel.lineBreakMode = .byWordWrapping
        descriptorTitleLabel.maximumNumberOfLines = 2
        descriptorPresenceLabel.lineBreakMode = .byWordWrapping
        descriptorPresenceLabel.maximumNumberOfLines = 1
        descriptorPresenceLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptorDescriptionText.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        descriptorDescriptionText.isRichText = false
        descriptorDescriptionText.isEditable = false
        descriptorDescriptionText.isSelectable = true
        descriptorDescriptionText.drawsBackground = false
        descriptorDescriptionText.isHorizontallyResizable = false
        descriptorDescriptionText.isVerticallyResizable = true
        descriptorDescriptionText.textContainer?.widthTracksTextView = true
        descriptorDescriptionText.textContainer?.containerSize =
            NSSize(width: 584, height: CGFloat.greatestFiniteMagnitude)
        descriptorDescriptionText.minSize = NSSize(width: 584, height: 48)
        descriptorDescriptionText.maxSize = NSSize(width: 584, height: CGFloat.greatestFiniteMagnitude)
        let descriptorScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 48))
        descriptorScroll.hasVerticalScroller = true
        descriptorScroll.hasHorizontalScroller = false
        descriptorScroll.autohidesScrollers = true
        descriptorScroll.borderType = .bezelBorder
        descriptorScroll.documentView = descriptorDescriptionText
        descriptorDescriptionText.frame = NSRect(x: 0, y: 0, width: 584, height: 48)
        let descriptorBox = NSStackView(views: [descriptorTitleLabel, descriptorPresenceLabel, descriptorScroll])
        descriptorBox.orientation = .vertical
        descriptorBox.alignment = .leading
        descriptorBox.spacing = 2

        let topRow = NSStackView(views: [
            NSTextField(labelWithString: "Domain:"), domainPopup,
            searchField, addTagField, addTagButton,
        ])
        topRow.orientation = .horizontal
        topRow.spacing = 8
        let rightColumn = NSStackView(views: [valuesScroll, editorScroll])
        rightColumn.orientation = .vertical
        rightColumn.spacing = 6
        let middleRow = NSStackView(views: [tagScroll, rightColumn])
        middleRow.orientation = .horizontal
        middleRow.spacing = 8
        let buttonRow = NSStackView(views: [addValueButton, removeValueButton, applyButton,
                                             removeTagButton, closeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8
        let stack = NSStackView(views: [hintLabel, topRow, middleRow, descriptorBox, buttonRow,
                                        noteLabel, messageLabel])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])
        panel.contentView!.setFrameSize(stack.fittingSize)
        panel.minSize = panel.frame.size
        panel.initialFirstResponder = searchField
    }

    // MARK: Queued loads (reads are counted document work, off the main thread)

    /// Requests a reload of the current domain's full tag catalog. Each
    /// request bumps the generation; only the newest completion lands.
    private func loadTags() {
        guard !isInvalidated else { return }
        tagLoadGeneration += 1
        let generation = tagLoadGeneration
        let owner = document
        let selectedDomain = domain
        owner.readMetadataTags(selectedDomain) { [weak self] result in
            guard let self, !self.isInvalidated, generation == self.tagLoadGeneration else { return }
            switch result {
            case .success(let tags):
                self.lastUndoSignature = self.document.undoInfo
                self.allTags = tags
                self.updatingTagRows = true
                defer { self.updatingTagRows = false }
                self.tagTable.reloadData()
                // Preserve the selection by name, never by row index.
                if let selected = self.selectedTag, tags.contains(selected) {
                    if let row = self.filteredRows.firstIndex(of: selected) {
                        self.tagTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    }
                } else if !self.draftIsDirty {
                    self.selectedTag = nil
                    self.valuesGeneration += 1
                    self.descriptorGeneration += 1
                    self.valuesAreLoading = false
                    self.descriptorIsLoading = false
                    self.valuesReady = false
                    self.tagDescriptor = nil
                    self.draft = []
                    self.selectedValueIndex = nil
                    self.valuesTable.reloadData()
                    self.synchronizeEditor()
                    self.tagTable.deselectAll(nil)
                }
                self.updateControlStates()
            case .failure(let error):
                self.refuse(String(describing: error))
            }
        }
    }

    /// Requests the ordered values of `tag`; the completion is dropped
    /// when a newer selection (generation), another tag or a close happened
    /// meanwhile.
    private func loadValues(for tag: String) {
        valuesGeneration += 1
        valuesAreLoading = true
        valuesReady = false
        updateControlStates()
        let generation = valuesGeneration
        let owner = document
        owner.readMetadataValues(tag) { [weak self] result in
            guard let self, !self.isInvalidated,
                  MetadataSheetLogic.readIsCurrent(tag: tag, generation: generation,
                                                   selectedTag: self.selectedTag,
                                                   currentGeneration: self.valuesGeneration) else { return }
            self.valuesAreLoading = false
            defer { self.updateControlStates() }
            switch result {
            case .success(let values):
                self.valuesReady = true
                self.draft = values
                self.draftIsDirty = false
                self.valuesTable.reloadData()
                if !values.isEmpty {
                    self.selectedValueIndex = 0
                    self.valuesTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                    self.synchronizeEditor()
                } else {
                    self.selectedValueIndex = nil
                    self.valuesTable.deselectAll(nil)
                    self.synchronizeEditor()
                }
                if let failure = self.descriptorReadError { self.refuse(failure) }
                else { self.clearMessage() }
                self.updateControlStates()
            case .failure(let error):
                self.refuse(String(describing: error))
            }
        }
    }

    /// Requests the read-only descriptor of `tag` (facade slot 128) as
    /// counted queued document work, exactly like `loadValues(for:)`. The
    /// completion is dropped when a newer selection (generation), another
    /// tag or a close happened meanwhile. It refreshes format facts only —
    /// presence, kind, policy, label, description, type name — and never
    /// touches the local draft, dirty or not. A failed query keeps writes
    /// disabled (the descriptor stays nil) and shows the native error.
    private func loadDescriptor(for tag: String) {
        descriptorReadError = nil
        descriptorGeneration += 1
        descriptorIsLoading = true
        updateControlStates()
        let generation = descriptorGeneration
        let owner = document
        owner.readMetadataTagInfo(tag) { [weak self] result in
            guard let self, !self.isInvalidated,
                  MetadataSheetLogic.readIsCurrent(tag: tag, generation: generation,
                                                   selectedTag: self.selectedTag,
                                                   currentGeneration: self.descriptorGeneration) else { return }
            self.descriptorIsLoading = false
            switch result {
            case .success(let info):
                self.tagDescriptor = info
            case .failure(let error):
                self.tagDescriptor = nil
                let failure = String(describing: error)
                self.descriptorReadError = failure
                self.refuse(failure)
            }
            self.updateControlStates()
        }
    }

    // MARK: Reload, error and close routing (called by the owning window)

    /// The document's cached state changed: refresh the tag catalog only
    /// when the undo signature moved (a metadata edit's undo/redo), and
    /// only the control gates otherwise — the draft is never clobbered.
    func documentStateDidChange() {
        guard !isInvalidated else { return }
        if lastDocumentStateVersion != document.stateVersion, !isApplying {
            lastDocumentStateVersion = document.stateVersion
            loadTags()
            if let tag = selectedTag {
                // An undo/redo of a metadata edit moved the undo signature:
                // refresh the descriptor's presence/policy even while a
                // dirty local draft is kept — only format facts refresh,
                // the draft is never overwritten to refresh them.
                if lastUndoSignature != document.undoInfo { loadDescriptor(for: tag) }
                if !draftIsDirty { loadValues(for: tag) }
            }
        }
        updateControlStates()
    }

    /// A native refusal the document reports: show it in the persistent
    /// error row too, keeping the draft so the values can be corrected.
    func showError(_ message: String) {
        guard !isInvalidated else { return }
        refuse(message)
    }

    /// Commits an in-flight field/text edit (the window's endPendingEdits):
    /// the editor's text lands in the draft before any queued write.
    func commitFieldEdit() {
        panel.endEditing(for: nil)
    }

    /// Close cleanup: no later callback may update or reopen the sheet.
    /// Idempotent: the window's sheet completion and the sheet's own
    /// close path may both run.
    func invalidate() {
        guard !isInvalidated else { return }
        isInvalidated = true
        tagLoadGeneration += 1
        valuesGeneration += 1
        descriptorGeneration += 1
        valuesAreLoading = false
        descriptorIsLoading = false
        valuesReady = false
        tagDescriptor = nil
        tagTable.dataSource = nil
        tagTable.delegate = nil
        valuesTable.dataSource = nil
        valuesTable.delegate = nil
        valueEditor.delegate = nil
        panel.endEditing(for: nil)
    }

    // MARK: Controls

    private func synchronizeEditor() {
        guard let index = selectedValueIndex, index >= 0, index < draft.count else {
            updatingEditor = true
            valueEditor.string = ""
            updatingEditor = false
            return
        }
        updatingEditor = true
        // The full multiline text, newlines included — never split or joined.
        valueEditor.string = draft[index]
        updatingEditor = false
    }

    private var selectedTagIsProtected: Bool {
        guard let tag = selectedTag else { return false }
        return MetadataSheetLogic.isProtected(tag)
    }

    /// Cached admission only — no native call here. Draft controls stay
    /// editable while busy (edits are local); only the write actions gate
    /// on the cached admission.
    private var writeRefusal: String? {
        MetadataSheetLogic.writeAdmission(isClosing: document.isClosing,
                                          isSavingForClose: document.isSavingForClose,
                                          isTransferringClipboard: document.isTransferringClipboard,
                                          pluginRunning: PlugInCommands.isRunning,
                                          engineBusy: EngineActivity.shared.isBusy,
                                          filterPreviewOpen: document.filterPreviewIsOpen)
    }

    private func updateControlStates() {
        let canWrite = !isInvalidated && !isApplying && !valuesAreLoading && writeRefusal == nil
        let canNavigate = !isInvalidated && !isApplying
        let hasSelection = selectedTag != nil
        let protectedTag = selectedTagIsProtected
        // The descriptor and the values must BOTH have been read
        // successfully for the SAME currently selected tag (valid
        // generation) before any write is enabled; a pending or failed
        // read fails closed with an actionable reason — never a stale
        // descriptor or a hardcoded permissive policy.
        let descriptorKnown = !descriptorIsLoading && tagDescriptor != nil
        let gates = MetadataSheetLogic.writeGates(descriptor: descriptorKnown ? tagDescriptor : nil,
                                                  valuesReady: valuesReady && !valuesAreLoading,
                                                  locallyProtected: protectedTag)
        domainPopup.isEnabled = canNavigate
        searchField.isEnabled = canNavigate
        addTagField.isEnabled = canNavigate
        tagTable.isEnabled = canNavigate
        addTagButton.isEnabled = canWrite
        addValueButton.isEnabled = !isInvalidated && hasSelection && !isApplying && !valuesAreLoading
            && gates.canAddValue
        removeValueButton.isEnabled = !isInvalidated && hasSelection && !gates.isReadOnly && !isApplying && !valuesAreLoading
            && selectedValueIndex != nil
        valueEditor.isEditable = !isInvalidated && hasSelection && !gates.isReadOnly && !isApplying && !valuesAreLoading
        valuesTable.isEnabled = !isInvalidated && hasSelection && !gates.isReadOnly && !isApplying && !valuesAreLoading
        applyButton.isEnabled = canWrite && hasSelection && gates.canSet
        removeTagButton.isEnabled = canWrite && hasSelection && gates.canRemove
        closeButton.isEnabled = !isInvalidated
        updateDescriptorDisplay()
        if let tag = selectedTag, descriptorKnown, tagDescriptor?.valueKind == .langAlt {
            // LangAlt is visibly read-only from the descriptor itself,
            // before any native edit could fail.
            noteLabel.textColor = .secondaryLabelColor
            noteLabel.stringValue = MetadataSheetLogic.langAltNote + " (\(tag))"
        } else if protectedTag, let tag = selectedTag {
            noteLabel.textColor = .secondaryLabelColor
            noteLabel.stringValue = MetadataSheetLogic.protectedNote + " (\(tag))"
        } else if hasSelection, let refusal = gates.refusal {
            noteLabel.textColor = .secondaryLabelColor
            noteLabel.stringValue = refusal
        } else if domain == .xmp {
            noteLabel.textColor = .secondaryLabelColor
            noteLabel.stringValue = MetadataSheetLogic.langAltNote
        } else {
            noteLabel.stringValue = ""
        }
    }

    /// Shows the native descriptor of the selected tag — label, type name,
    /// presence and description — or the pending state while it loads.
    /// Format facts only; the local draft is never touched here.
    private func updateDescriptorDisplay() {
        guard let tag = selectedTag else {
            descriptorTitleLabel.stringValue = ""
            descriptorPresenceLabel.stringValue = ""
            descriptorDescriptionText.string = ""
            return
        }
        if let info = tagDescriptor, !descriptorIsLoading {
            descriptorTitleLabel.stringValue = MetadataSheetLogic.descriptorTitle(tag: tag, info: info)
            descriptorPresenceLabel.stringValue = MetadataSheetLogic.descriptorPresenceText(info)
            descriptorDescriptionText.string = info.description
        } else {
            descriptorTitleLabel.stringValue = tag
            descriptorPresenceLabel.stringValue = descriptorIsLoading ? "Reading tag descriptor…" : ""
            descriptorDescriptionText.string = ""
        }
    }

    private func refuse(_ message: String) {
        lastError = message
        messageLabel.textColor = .systemRed
        messageLabel.stringValue = message
    }

    private func clearMessage() {
        lastError = nil
        messageLabel.textColor = .labelColor
        messageLabel.stringValue = ""
    }

    // MARK: Actions

    @objc private func domainChanged(_ sender: Any?) {
        guard !isInvalidated, !isApplying else { return }
        valuesGeneration += 1
        descriptorGeneration += 1
        valuesAreLoading = false
        descriptorIsLoading = false
        valuesReady = false
        tagDescriptor = nil
        clearMessage()
        selectedTag = nil
        draft = []
        draftIsDirty = false
        selectedValueIndex = nil
        allTags = []
        tagTable.reloadData()
        valuesTable.reloadData()
        synchronizeEditor()
        loadTags()
        updateControlStates()
    }

    /// Add Tag by explicit dotted name: a tag already in the catalog is
    /// only selected (no write). A registered absent tag starts a local
    /// draft; no image change or undo occurs until Apply. The queued read
    /// validates registration/type (NOT_FOUND otherwise).
    @objc private func addTag(_ sender: Any?) {
        guard !isInvalidated, !isApplying, !valuesAreLoading, writeRefusal == nil else { return }
        panel.endEditing(for: nil)
        switch MetadataSheetLogic.validateNewTagName(addTagField.stringValue, domain: domain) {
        case .failure(let rejection):
            refuse(rejection.message)
            return
        case .success(let name):
            if allTags.contains(name) {
                if let row = filteredRows.firstIndex(of: name) {
                    tagTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                    selectTag(name)
                }
                return
            }
            clearMessage()
            // Validate registration without writing an empty native value.
            // The field becomes a local draft; Apply commits the actual text.
            isApplying = true
            updateControlStates()
            let owner = document
            owner.readMetadataValues(name) { [weak self] valuesResult in
                guard let self, !self.isInvalidated else { return }
                switch valuesResult {
                case .failure(let error):
                    self.isApplying = false
                    self.refuse(String(describing: error))
                    self.updateControlStates()
                case .success(let values):
                    // Preserve the previous selection/draft until both
                    // queries validate the captured new name successfully.
                    owner.readMetadataTagInfo(name) { [weak self] descriptorResult in
                        guard let self, !self.isInvalidated else { return }
                        self.isApplying = false
                        defer { self.updateControlStates() }
                        switch descriptorResult {
                        case .failure(let error):
                            self.refuse(String(describing: error))
                        case .success(let info):
                            self.valuesGeneration += 1
                            self.descriptorGeneration += 1
                            self.valuesAreLoading = false
                            self.descriptorIsLoading = false
                            self.descriptorReadError = nil
                            self.tagDescriptor = info
                            self.valuesReady = true
                            self.selectedTag = name
                            self.draft = values.isEmpty ? [""] : values
                            self.draftIsDirty = values.isEmpty
                            self.selectedValueIndex = 0
                            self.valuesTable.reloadData()
                            self.valuesTable.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                            self.synchronizeEditor()
                            self.loadTags()
                            self.messageLabel.textColor = .labelColor
                            self.messageLabel.stringValue = info.formatPolicy.contains(.supportsSet)
                                ? "New tag \(name). Enter a value, then choose Apply."
                                : "The tag's format is read-only here."
                        }
                    }
                }
            }
        }
    }

    /// Selects `tag` by name: bumps the values generation so a pending
    /// load for an older selection cannot clobber this one's draft, then
    /// loads the tag's ordered values.
    private func selectTag(_ tag: String) {
        guard selectedTag != tag else { return }
        selectedTag = tag
        draft = []
        draftIsDirty = false
        selectedValueIndex = nil
        // Invalidate the old selection's descriptor and its result: only
        // reads of the SAME currently selected tag at a valid generation
        // may land and enable writes.
        tagDescriptor = nil
        descriptorGeneration += 1
        descriptorIsLoading = false
        valuesReady = false
        valuesTable.reloadData()
        synchronizeEditor()
        loadValues(for: tag)
        loadDescriptor(for: tag)
        updateControlStates()
    }

    @objc private func addValue(_ sender: Any?) {
        guard !isInvalidated, !isApplying, !valuesAreLoading, selectedTag != nil,
              !selectedTagIsProtected else { return }
        panel.endEditing(for: nil)
        draft = MetadataSheetLogic.addValue(to: draft)
        draftIsDirty = true
        let row = draft.count - 1
        selectedValueIndex = row
        valuesTable.reloadData()
        valuesTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        synchronizeEditor()
        clearMessage()
        updateControlStates()
    }

    @objc private func removeValue(_ sender: Any?) {
        guard !isInvalidated, !isApplying, !valuesAreLoading, !selectedTagIsProtected,
              let index = selectedValueIndex,
              let updated = MetadataSheetLogic.removeValue(at: index, from: draft) else { return }
        draft = updated
        draftIsDirty = true
        if draft.isEmpty {
            selectedValueIndex = nil
            valuesTable.deselectAll(nil)
        } else {
            let row = min(index, draft.count - 1)
            selectedValueIndex = row
            valuesTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        valuesTable.reloadData()
        synchronizeEditor()
        clearMessage()
        updateControlStates()
    }

    /// Apply: commits the pending editor text, then captures the document,
    /// image, selected tag, action and the WHOLE ordered value-array
    /// snapshot before the one queued SET. An empty draft is refused
    /// locally with the Remove Tag explanation — never sent. On success
    /// the rows reload (only after a successful change); on refusal the
    /// native error stays visible and the draft is preserved untouched.
    @objc private func apply(_ sender: Any?) {
        guard !isInvalidated, !isApplying, !valuesAreLoading, let tag = selectedTag,
              !selectedTagIsProtected, writeRefusal == nil else { return }
        panel.endEditing(for: nil)
        switch MetadataSheetLogic.validateSetValues(draft) {
        case .failure(let rejection):
            refuse(rejection.message)
            return
        case .success(let values):
            clearMessage()
            let capture = MetadataSheetLogic.Capture(image: document.image, tag: tag,
                                                     action: .setValues, values: values)
            lastCapture = capture
            isApplying = true
            updateControlStates()
            let owner = document
            owner.editMetadata(tag, .set, values: capture.values) { [weak self] result in
                guard let self, !self.isInvalidated else { return }
                self.isApplying = false
                switch result {
                case .success:
                    self.draftIsDirty = false
                    self.loadTags()
                    self.loadValues(for: tag)
                    // Refresh the descriptor's presence/policy after Apply.
                    self.loadDescriptor(for: tag)
                case .failure(let error):
                    self.refuse(String(describing: error))
                }
                self.updateControlStates()
            }
        }
    }

    /// Remove Tag: the explicit selected tag only — never a stale row
    /// index — erased as one queued REMOVE (no values).
    @objc private func removeTag(_ sender: Any?) {
        guard !isInvalidated, !isApplying, !valuesAreLoading, let tag = selectedTag,
              !selectedTagIsProtected, writeRefusal == nil else { return }
        clearMessage()
        let capture = MetadataSheetLogic.Capture(image: document.image, tag: tag,
                                                 action: .removeTag, values: [])
        lastCapture = capture
        isApplying = true
        updateControlStates()
        let owner = document
        owner.editMetadata(tag, .remove, values: []) { [weak self] result in
            guard let self, !self.isInvalidated else { return }
            self.isApplying = false
            switch result {
            case .success:
                self.selectedTag = nil
                self.draft = []
                self.draftIsDirty = false
                self.selectedValueIndex = nil
                self.descriptorGeneration += 1
                self.descriptorIsLoading = false
                self.valuesReady = false
                self.tagDescriptor = nil
                self.valuesTable.reloadData()
                self.synchronizeEditor()
                self.loadTags()
            case .failure(let error):
                self.refuse(String(describing: error))
            }
            self.updateControlStates()
        }
    }

    /// Close ends the sheet; the unapplied local draft is discarded.
    /// Already applied changes stay and remain undoable.
    @objc private func close(_ sender: Any?) {
        guard !isInvalidated else { return }
        hostWindow?.endSheet(panel)
    }

    // MARK: Field and editor delegates

    func controlTextDidChange(_ notification: Notification) {
        guard !isInvalidated else { return }
        if notification.object as? NSTextField === searchField {
            guard !isApplying else { return }
            updatingTagRows = true
            defer { updatingTagRows = false }
            tagTable.reloadData()
            if let selected = selectedTag, let row = filteredRows.firstIndex(of: selected) {
                tagTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            }
        }
        updateControlStates()
    }

    func textDidChange(_ notification: Notification) {
        guard !isInvalidated, !updatingEditor, !isApplying, !valuesAreLoading,
              let index = selectedValueIndex,
              let updated = MetadataSheetLogic.replaceValue(at: index, with: valueEditor.string, in: draft) else { return }
        draft = updated
        draftIsDirty = true
        valuesTable.reloadData()
        updateControlStates()
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === tagTable ? filteredRows.count : draft.count
    }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? {
        if tableView === tagTable {
            let rows = filteredRows
            guard row >= 0, row < rows.count else { return nil }
            return rows[row]
        }
        guard row >= 0, row < draft.count else { return nil }
        // The row shows the value's text as-is; the editor holds the full
        // multiline form. Newlines are display content, never a value
        // separator: one row is exactly one value.
        return draft[row]
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isInvalidated else { return }
        if notification.object as? NSTableView === tagTable {
            guard !updatingTagRows, !isApplying else { return }
            let row = tagTable.selectedRow
            let rows = filteredRows
            guard row >= 0, row < rows.count else {
                valuesGeneration += 1
                descriptorGeneration += 1
                valuesAreLoading = false
                descriptorIsLoading = false
                valuesReady = false
                tagDescriptor = nil
                selectedTag = nil
                draft = []
                draftIsDirty = false
                selectedValueIndex = nil
                valuesTable.reloadData()
                synchronizeEditor()
                updateControlStates()
                return
            }
            selectTag(rows[row])
            return
        }
        let row = valuesTable.selectedRow
        guard row >= 0, row < draft.count else {
            selectedValueIndex = nil
            synchronizeEditor()
            updateControlStates()
            return
        }
        selectedValueIndex = row
        synchronizeEditor()
        updateControlStates()
    }
}
