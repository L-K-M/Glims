import AppKit
import UniformTypeIdentifiers

/// The native Image ▸ Color Profile sheets: Assign… and Convert… share
/// one form. It offers the built-in profile or an ICC file chosen with an
/// open panel, plus — for Convert only — the rendering intent and black
/// point compensation. The sheet reads only the document's cached color
/// state: no engine call and no file read happen on the main thread; the
/// chosen profile's path is validated as a string here and the engine
/// checks the file off the main thread inside the document's exclusive
/// job. The document and window are captured when the sheet opens, like
/// FillForm's — a retarget cannot redirect the operation — and the form's
/// control binding is retained per sheet, never globally.
@MainActor
enum ProfileForm {

    enum Kind {
        case assign, convert

        var title: String {
            switch self {
            case .assign: return "Assign Color Profile"
            case .convert: return "Convert to Color Profile"
            }
        }

        var applyTitle: String {
            switch self {
            case .assign: return "Assign"
            case .convert: return "Convert"
            }
        }

        /// Assign reinterprets the existing pixel values in the new
        /// profile; Convert changes them so the appearance is preserved.
        var informativeText: String {
            switch self {
            case .assign:
                return "Assignment does not change the pixel values: the image's existing colors are "
                    + "reinterpreted in the chosen profile. Choose the built-in profile to discard an "
                    + "embedded profile without converting."
            case .convert:
                return "Conversion changes the pixel values so the image keeps its appearance in the "
                    + "destination profile. The rendering intent and black-point compensation apply to "
                    + "this conversion only. Choose the built-in profile to convert to the image's default."
            }
        }
    }

    /// Where the destination profile comes from.
    enum Source: String, Codable, CaseIterable {
        case builtin, iccFile

        var title: String {
            switch self {
            case .builtin: return "Built-in profile"
            case .iccFile: return "ICC file…"
            }
        }
    }

    /// What the sheet captured on Apply: the chosen source and ICC path,
    /// and — used by Convert only — the intent and BPC. Codable so the
    /// captured form state is a plain value.
    struct Settings: Equatable, Codable {
        var source: Source
        var iccPath: String
        var intent: EngineSession.ProfileIntent
        var blackPointCompensation: Bool
    }

    /// A user-facing refusal of the form's own input, before anything
    /// queues: a missing, relative or non-ICC path.
    struct InputError: LocalizedError, Equatable {
        let message: String
        var errorDescription: String? { message }
    }

    /// The ICC file types the open panel offers.
    static let iccContentTypes: [UTType] = {
        [UTType(filenameExtension: "icc"), UTType(filenameExtension: "icm")].compactMap { $0 }
    }()

    /// Whether an image in `mode` may run Convert: indexed images may
    /// not — their native palette conversion ignores intent and BPC —
    /// while Assign stays allowed on them.
    static func convertAllowed(mode: EngineSession.ColorMode) -> Bool {
        mode != .indexed && !mode.usesNativeChannels
    }

    /// The one-line cached profile state the form shows: the effective
    /// profile's label, and whether it is embedded or the built-in
    /// fallback; "None" when there is no profile.
    static func currentProfileSummary(_ colorInfo: EngineSession.ColorInfo) -> String {
        guard !colorInfo.profileLabel.isEmpty else { return "None" }
        return "\(colorInfo.profileLabel) (\(colorInfo.hasEmbeddedProfile ? "embedded in the image" : "built-in default"))"
    }

    /// Validates an ICC path as a string only — existence and profile
    /// validity are the engine's to check off the main thread. Returns
    /// the absolute path to pass on, or a user-facing reason.
    static func validatedICCPath(_ raw: String) -> Result<String, InputError> {
        guard !raw.utf8.contains(0) else {
            return .failure(InputError(message: "The profile path contains invalid text."))
        }
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            return .failure(InputError(message: "Choose an ICC profile file (.icc or .icm)."))
        }
        if !path.hasPrefix("/") {
            return .failure(InputError(message: "The profile path must be a full path, for example /Users/you/display.icc."))
        }
        let ext = (path as NSString).pathExtension.lowercased()
        if ext != "icc" && ext != "icm" {
            return .failure(InputError(message: "ICC color profiles use the .icc or .icm extension."))
        }
        return .success(path)
    }

    /// Builds the captured settings, validating the ICC path when the
    /// source is a file. The built-in profile carries no path.
    static func makeSettings(source: Source, iccPath: String, intent: EngineSession.ProfileIntent,
                             blackPointCompensation: Bool) -> Result<Settings, InputError> {
        switch source {
        case .builtin:
            return .success(Settings(source: .builtin, iccPath: "", intent: intent,
                                     blackPointCompensation: blackPointCompensation))
        case .iccFile:
            return validatedICCPath(iccPath).map {
                Settings(source: .iccFile, iccPath: $0, intent: intent,
                         blackPointCompensation: blackPointCompensation)
            }
        }
    }

    /// The facade path for captured settings: nil is the built-in (or,
    /// for Assign, discarding an embedded profile).
    static func profilePath(_ settings: Settings) -> String? {
        settings.source == .iccFile ? settings.iccPath : nil
    }

    /// Image ▸ Color Profile ▸ Assign… / Convert…: one sheet seeded from
    /// the document's cached color state.
    static func present(_ kind: Kind, for document: ImageDocument, on window: NSWindow) {
        guard document.acceptsEdits, window.attachedSheet == nil else {
            if !document.acceptsEdits {
                document.onError?(document.isClosing
                    ? ImageDocument.DocumentError.closed.localizedDescription
                    : ImageDocument.DocumentError.busy.localizedDescription)
            }
            return
        }
        let info = document.colorInfo
        guard !info.mode.usesNativeChannels else {
            document.onError?("Profile changes are not available for this channel document.")
            return
        }
        if kind == .convert, !convertAllowed(mode: info.mode) {
            document.onError?(ImageDocument.DocumentError.indexedProfileConversion.localizedDescription)
            return
        }

        let source = NSPopUpButton(frame: .zero, pullsDown: false)
        source.addItems(withTitles: Source.allCases.map(\.title))
        source.selectItem(at: 0)
        source.setAccessibilityLabel("Destination profile")

        let pathField = NSTextField(string: "")
        pathField.setAccessibilityLabel("ICC profile file path")
        pathField.placeholderString = "/full/path/to/profile.icc"
        pathField.isEnabled = false

        let choose = NSButton(title: "Choose…", target: nil, action: nil)
        choose.isEnabled = false
        choose.setAccessibilityLabel("Choose an ICC profile file")

        let sync = ProfileFormSync(source: source, pathField: pathField, choose: choose)
        source.target = sync
        source.action = #selector(ProfileFormSync.sourceChanged(_:))
        choose.target = sync
        choose.action = #selector(ProfileFormSync.chooseFile(_:))

        let pathStack = NSStackView(views: [pathField, choose])
        pathStack.orientation = .horizontal
        pathStack.spacing = 8
        pathStack.alignment = .centerY

        var rows: [[NSView]] = [
            [NSTextField(labelWithString: "Current profile:"), NSTextField(labelWithString: currentProfileSummary(info))],
            [NSTextField(labelWithString: "Profile:"), source],
            [NSTextField(labelWithString: "ICC file:"), pathStack],
        ]
        if kind == .convert {
            let choices = EngineSession.ProfileIntent.conversionChoices
            let intent = NSPopUpButton(frame: .zero, pullsDown: false)
            intent.addItems(withTitles: choices.map(\.title))
            intent.selectItem(at: choices.firstIndex(of: .perceptual) ?? 0)
            intent.setAccessibilityLabel("Rendering intent")
            let bpc = NSButton(checkboxWithTitle: "Black point compensation", target: nil, action: nil)
            bpc.state = .on
            bpc.setAccessibilityLabel("Black point compensation")
            sync.intent = intent
            sync.bpc = bpc
            rows += [
                [NSTextField(labelWithString: "Intent:"), intent],
                [NSGridCell.emptyContentView, bpc],
            ]
        }

        let grid = NSGridView(views: rows)
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        source.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        pathField.widthAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true
        grid.setFrameSize(grid.fittingSize)

        let alert = NSAlert()
        alert.messageText = kind.title
        alert.informativeText = kind.informativeText
        alert.accessoryView = grid
        alert.addButton(withTitle: kind.applyTitle)
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = source
        sync.sheetWindow = alert.window

        alert.beginSheetModal(for: window) { [sync, document] response in
            sync.sheetWindow?.endEditing(for: nil)
            guard response == .alertFirstButtonReturn else { return }
            guard document.acceptsEdits else {
                document.onError?(document.isClosing
                    ? ImageDocument.DocumentError.closed.localizedDescription
                    : ImageDocument.DocumentError.busy.localizedDescription)
                return
            }
            let sourceIndex = sync.source?.indexOfSelectedItem ?? 0
            guard Source.allCases.indices.contains(sourceIndex) else {
                document.onError?("Choose a destination profile.")
                return
            }
            let intentChoices = EngineSession.ProfileIntent.conversionChoices
            let intentIndex = kind == .convert ? (sync.intent?.indexOfSelectedItem ?? 0) : 0
            let intent = intentChoices.indices.contains(intentIndex)
                ? intentChoices[intentIndex] : .perceptual
            let settings = makeSettings(source: Source.allCases[sourceIndex],
                                        iccPath: sync.pathField?.stringValue ?? "",
                                        intent: intent,
                                        blackPointCompensation: kind == .convert && sync.bpc?.state == .on)
            guard case .success(let captured) = settings else {
                if case .failure(let reason) = settings { document.onError?(reason.localizedDescription) }
                return
            }
            let path = profilePath(captured)
            switch kind {
            case .assign:
                document.assignProfile(path: path) { result in
                    if case .failure(let error) = result { document.onError?(error.localizedDescription) }
                }
            case .convert:
                convert(captured, document: document, on: window, policy: .preserveEditableLayers)
            }
        }
    }

    private static func convert(_ settings: Settings, document: ImageDocument, on window: NSWindow,
                                policy: EngineSession.ProfileConversionPolicy) {
        document.convertProfile(path: profilePath(settings), intent: settings.intent,
                                blackPointCompensation: settings.blackPointCompensation,
                                policy: policy) { result in
            guard case .failure(let error) = result else { return }
            guard policy == .preserveEditableLayers,
                  let engineError = error as? EngineSession.EngineError,
                  engineError.requiresRasterization else {
                document.onError?(error.localizedDescription)
                return
            }
            // The result arrives before the exclusive job's counters and
            // engine-wide gate drain. Wait before admitting another action
            // or showing a sheet; closing may have been requested meanwhile.
            EngineActivity.shared.whenIdle {
                guard !document.isClosing else { return }
                guard document.acceptsEdits, window.attachedSheet == nil else {
                    document.onError?(ImageDocument.DocumentError.busy.localizedDescription)
                    return
                }
                let confirmation = NSAlert()
                confirmation.messageText = "Rasterize editable layers?"
                confirmation.informativeText = "Converting this profile will turn editable text, vector, and linked layers into pixel layers. You can undo the conversion."
                confirmation.addButton(withTitle: "Rasterize and Convert")
                confirmation.addButton(withTitle: "Cancel")
                confirmation.beginSheetModal(for: window) { response in
                    guard response == .alertFirstButtonReturn else { return }
                    guard document.acceptsEdits else {
                        document.onError?(document.isClosing
                            ? ImageDocument.DocumentError.closed.localizedDescription
                            : ImageDocument.DocumentError.busy.localizedDescription)
                        return
                    }
                    convert(settings, document: document, on: window, policy: .rasterizeEditableLayers)
                }
            }
        }
    }

}

/// The per-sheet control binding, retained by the sheet's completion
/// closure — never stored globally, so two documents' sheets cannot
/// rewire each other.
@MainActor
private final class ProfileFormSync: NSObject {
    weak var source: NSPopUpButton?
    weak var pathField: NSTextField?
    weak var choose: NSButton?
    weak var intent: NSPopUpButton?
    weak var bpc: NSButton?
    weak var sheetWindow: NSWindow?

    init(source: NSPopUpButton, pathField: NSTextField, choose: NSButton) {
        self.source = source
        self.pathField = pathField
        self.choose = choose
        super.init()
    }

    @objc func sourceChanged(_ sender: NSPopUpButton) {
        let selected = sender.indexOfSelectedItem
        let file = ProfileForm.Source.allCases.indices.contains(selected)
            ? ProfileForm.Source.allCases[selected] == .iccFile
            : sender.titleOfSelectedItem == ProfileForm.Source.iccFile.title
        pathField?.isEnabled = file
        choose?.isEnabled = file
    }

    /// Opens the ICC file panel as a sheet on the form's own sheet and
    /// stores the chosen full path — no file is read here.
    @objc func chooseFile(_ sender: Any?) {
        guard let sheetWindow else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = ProfileForm.iccContentTypes
        panel.prompt = "Choose"
        panel.message = "Choose an ICC color profile (.icc or .icm)."
        panel.beginSheetModal(for: sheetWindow) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.pathField?.stringValue = url.path
        }
    }
}
