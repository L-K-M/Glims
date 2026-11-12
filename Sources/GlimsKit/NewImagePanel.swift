import AppKit
import UniformTypeIdentifiers

/// Pixel dimensions accepted by the engine (libgimpbase/gimplimits.h).
struct NewImageSettings: Equatable {
    /// The kind of image to create.
    enum Kind: Equatable {
        case rgb, multichannel, cmyk, lab

        static func choices(supportsLab: Bool = false) -> [Kind] {
            supportsLab ? [.rgb, .multichannel, .cmyk, .lab] : [.rgb, .multichannel, .cmyk]
        }

        static func kind(at index: Int, supportsLab: Bool) -> Kind? {
            let choices = choices(supportsLab: supportsLab)
            guard choices.indices.contains(index) else { return nil }
            return choices[index]
        }

        var title: String {
            switch self {
            case .rgb: return "RGB"
            case .multichannel: return "Multichannel"
            case .cmyk: return "CMYK"
            case .lab: return "Lab (D50)"
            }
        }
    }

    /// Precisions offered for native ink-channel images.
    static let multichannelComponents: [EngineSession.ColorComponent] = [.u8, .u16, .float]

    /// Precisions offered for Lab documents.
    static let labComponents: [EngineSession.ColorComponent] = [.u8, .u16, .float]

    let width: Int
    let height: Int
    let kind: Kind
    let component: EngineSession.ColorComponent
    let channelCount: Int
    let profileICC: Data?

    /// RGB ignores dormant ink fields. CMYK has exactly four planes and keeps
    /// the selected immutable ICC bytes; Multichannel has a variable ink count.
    /// Lab always has three physical axes and no supplied source profile.
    init?(width: String, height: String, kind: Kind = .rgb,
          component: EngineSession.ColorComponent = .u8, channelCount: String = "4", profileICC: Data? = nil) {
        guard let w = Int(width.trimmingCharacters(in: .whitespacesAndNewlines)),
              let h = Int(height.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...524_288).contains(w), (1...524_288).contains(h) else { return nil }
        self.width = w
        self.height = h
        self.kind = kind
        switch kind {
        case .rgb:
            self.component = .u8
            self.channelCount = 4
            self.profileICC = nil
        case .multichannel:
            guard Self.multichannelComponents.contains(component),
                  let count = Int(channelCount.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...32).contains(count) else { return nil }
            self.component = component
            self.channelCount = count
            self.profileICC = nil
        case .cmyk:
            guard Self.multichannelComponents.contains(component), let profileICC,
                  PsdCmykProfile.isValidICCData(profileICC) else { return nil }
            self.component = component
            self.channelCount = 4
            self.profileICC = profileICC
        case .lab:
            guard Self.labComponents.contains(component) else { return nil }
            self.component = component
            self.channelCount = 3
            self.profileICC = nil
        }
    }
}

@MainActor
final class NewImagePanel: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let widthField = NSTextField(string: "1600")
    private let heightField = NSTextField(string: "1200")
    private let modePopup = NSPopUpButton()
    private let precisionPopup = NSPopUpButton()
    private let channelField = NSTextField(string: "4")
    private let profilePopup = NSPopUpButton()
    private let profileButton = NSButton(title: "Choose Profile…", target: nil, action: nil)
    private let profileNote = NSTextField(wrappingLabelWithString: "")
    private var selectedProfile: PsdCmykProfile?
    private var profileEntries: [PsdCmykProfileCatalogEntry] = []
    private var profileLoadStarted = false
    private var profileLoading = false
    private var channelRow: NSGridRow?
    private var profileRows: [NSGridRow] = []
    private let profileLoader: any PsdCmykProfileCatalogLoading
    private let supportsLab: Bool
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    var onCreate: ((NewImageSettings) -> Void)?
    var onClose: (() -> Void)?

    init(profileLoader: any PsdCmykProfileCatalogLoading = LivePsdCmykProfileCatalogLoader(),
         supportsLab: Bool = false) {
        self.profileLoader = profileLoader
        self.supportsLab = supportsLab
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 365),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "New Image"
        super.init(window: panel)
        panel.delegate = self
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(create(_:))
        createButton.keyEquivalent = "\r"
        for (field, label) in [(widthField, "Width in pixels"), (heightField, "Height in pixels"),
                               (channelField, "Ink channels")] {
            field.delegate = self
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 100).isActive = true
        }
        modePopup.addItems(withTitles: NewImageSettings.Kind.choices(supportsLab: supportsLab).map(\.title))
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        modePopup.setAccessibilityLabel("Image mode")
        precisionPopup.addItems(withTitles: ["8-bit", "16-bit", "32-bit float"])
        precisionPopup.setAccessibilityLabel("Precision")
        profilePopup.setAccessibilityLabel("CMYK source profile")
        profilePopup.widthAnchor.constraint(equalToConstant: 270).isActive = true
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))
        profileButton.target = self
        profileButton.action = #selector(chooseProfile(_:))
        rebuildProfiles()
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Width (px):"), widthField],
                                     [NSTextField(labelWithString: "Height (px):"), heightField],
                                     [NSTextField(labelWithString: "Mode:"), modePopup],
                                     [NSTextField(labelWithString: "Precision:"), precisionPopup],
                                     [NSTextField(labelWithString: "Ink channels:"), channelField],
                                     [NSTextField(labelWithString: "Source profile:"), profilePopup],
                                     [NSView(), profileButton]])
        grid.column(at: 0).xPlacement = .trailing
        channelRow = grid.row(at: 4)
        profileRows = [grid.row(at: 5), grid.row(at: 6)]
        let buttons = NSStackView(views: [cancel, createButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [grid, profileNote, errorLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView?.addSubview(stack)
        if let content = panel.contentView {
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
                stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
                errorLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
                profileNote.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
        }
        errorLabel.font = .systemFont(ofSize: 11)
        profileNote.font = .systemFont(ofSize: 11)
        panel.initialFirstResponder = widthField
        updateValidation()
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func create(_ sender: Any?) {
        guard let settings = currentSettings() else {
            updateValidation()
            return
        }
        onCreate?(settings)
        close()
    }

    @objc private func cancel(_ sender: Any?) { close() }
    @objc private func modeChanged(_ sender: Any?) {
        if kind == .cmyk { loadProfilesIfNeeded() }
        updateValidation()
    }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func controlTextDidChange(_ notification: Notification) { updateValidation() }

    private var kind: NewImageSettings.Kind? {
        NewImageSettings.Kind.kind(at: modePopup.indexOfSelectedItem, supportsLab: supportsLab)
    }

    private func currentSettings() -> NewImageSettings? {
        guard let kind else { return nil }
        let index = precisionPopup.indexOfSelectedItem
        let components = kind == .lab ? NewImageSettings.labComponents : NewImageSettings.multichannelComponents
        guard kind == .rgb || components.indices.contains(index) else { return nil }
        let component = components.indices.contains(index) ? components[index] : .u8
        return NewImageSettings(width: widthField.stringValue, height: heightField.stringValue,
                                kind: kind, component: component, channelCount: channelField.stringValue,
                                profileICC: selectedProfile?.iccData)
    }

    private func updateValidation() {
        let selectedKind = kind
        let multichannel = selectedKind == .multichannel
        let cmyk = selectedKind == .cmyk
        let lab = selectedKind == .lab
        precisionPopup.isEnabled = multichannel || cmyk || lab
        channelField.isEnabled = multichannel
        channelRow?.isHidden = lab
        if cmyk { channelField.stringValue = "4" }
        profilePopup.isEnabled = cmyk && !profileLoading
        profileButton.isEnabled = cmyk
        profileRows.forEach { $0.isHidden = !cmyk }
        profileNote.isHidden = !(cmyk || lab)
        if cmyk {
            profileNote.stringValue = "The source profile defines CMYK color. Preview uses relative colorimetric with black-point compensation."
        } else if lab {
            profileNote.stringValue = "Three physical axes: lightness (L*), a* and b*. The reference white is D50."
        } else {
            profileNote.stringValue = ""
        }
        let settings = currentSettings()
        createButton.isEnabled = settings != nil
        guard settings == nil else { errorLabel.stringValue = ""; return }
        let dimensionsValid = NewImageSettings(width: widthField.stringValue,
                                               height: heightField.stringValue) != nil
        if !dimensionsValid { errorLabel.stringValue = "Enter whole numbers from 1 to 524288." }
        else if cmyk {
            errorLabel.stringValue = profileLoading ? "Reading installed CMYK profiles…" : "Choose a valid CMYK source profile no larger than 4 MB."
        } else if lab {
            errorLabel.stringValue = "Choose 8-bit, 16-bit or 32-bit float Lab precision."
        } else if multichannel {
            errorLabel.stringValue = "Enter a whole number of ink channels from 1 to 32."
        } else {
            errorLabel.stringValue = "Choose an available image mode."
        }
    }

    private func rebuildProfiles() {
        profilePopup.removeAllItems()
        profilePopup.addItem(withTitle: "Choose a CMYK profile")
        var profiles = profileEntries.map(\.profile)
        if let selectedProfile, !profiles.contains(where: { $0.iccData == selectedProfile.iccData }) {
            profiles.append(selectedProfile)
        }
        for profile in profiles {
            let item = NSMenuItem(title: profile.displayName, action: nil, keyEquivalent: "")
            item.representedObject = profile.iccData
            item.toolTip = profile.displayName
            profilePopup.menu?.addItem(item)
            if profile.iccData == selectedProfile?.iccData { profilePopup.select(item) }
        }
    }

    private func loadProfilesIfNeeded() {
        guard !profileLoadStarted else { return }
        profileLoadStarted = true
        profileLoading = true
        let loader = profileLoader
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try loader.loadCatalog() }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.profileLoading = false
                if case .success(let entries) = result {
                    self.profileEntries = entries
                    if self.selectedProfile == nil { self.selectedProfile = entries.first?.profile }
                }
                self.rebuildProfiles()
                self.updateValidation()
            }
        }
    }

    @objc private func profileChanged(_ sender: Any?) {
        if let item = profilePopup.selectedItem, let data = item.representedObject as? Data {
            selectedProfile = try? PsdCmykProfile(displayName: item.title, iccData: data)
        } else { selectedProfile = nil }
        updateValidation()
    }

    @objc private func chooseProfile(_ sender: Any?) {
        guard kind == .cmyk, let window, window.attachedSheet == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose CMYK Source Profile"
        panel.allowedContentTypes = ["icc", "icm"].compactMap { UTType(filenameExtension: $0) }
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                let bytes = try ICCProfileFile.read(url)
                guard PsdCmykProfile.isValidICCData(bytes) else {
                    self.errorLabel.stringValue = "Choose a valid CMYK profile no larger than 4 MB."
                    return
                }
                self.selectedProfile = try PsdCmykProfile(displayName: url.deletingPathExtension().lastPathComponent, iccData: bytes)
                self.rebuildProfiles()
                self.updateValidation()
            } catch { self.errorLabel.stringValue = error.localizedDescription }
        }
    }
}
