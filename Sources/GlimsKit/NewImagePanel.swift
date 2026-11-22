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

    /// What an RGB image's one layer holds, as in Photoshop's New dialog.
    enum Contents: Int, CaseIterable, Equatable {
        case white, backgroundColor, transparent

        var title: String {
            switch self {
            case .white: return "White"
            case .backgroundColor: return "Background Color"
            case .transparent: return "Transparent"
            }
        }
    }

    /// Precisions offered for native ink-channel images.
    static let multichannelComponents: [EngineSession.ColorComponent] = [.u8, .u16, .float]

    /// Precisions offered for Lab documents.
    static let labComponents: [EngineSession.ColorComponent] = [.u8, .u16, .float]

    let width: Int
    let height: Int
    /// The resolution the new image is created with, in pixels per inch.
    /// File > New defaults to 72 ppi, which the engine's own template does
    /// not: creation sets it cleanly, with no undo step.
    let resolutionX: Double
    let resolutionY: Double
    let kind: Kind
    let component: EngineSession.ColorComponent
    let channelCount: Int
    let profileICC: Data?
    /// Always white for the component modes, which have no contents choice.
    let contents: Contents

    /// RGB ignores dormant ink fields. CMYK has exactly four planes and keeps
    /// the selected immutable ICC bytes; Multichannel has a variable ink count.
    /// Lab always has three physical axes and no supplied source profile.
    init?(width: String, height: String, kind: Kind = .rgb,
          component: EngineSession.ColorComponent = .u8, channelCount: String = "4", profileICC: Data? = nil,
          contents: Contents = .white,
          sizeUnit: ImageSizeModel.SizeUnit = .pixels,
          resolution: String = "72",
          resolutionUnit: ImageSizeModel.ResolutionUnit = .pixelsPerInch) {
        let resolutionValue = Double(resolution.trimmingCharacters(in: .whitespacesAndNewlines))
        guard let resolutionValue, resolutionValue.isFinite, resolutionValue > 0 else { return nil }
        let ppi = resolutionValue * resolutionUnit.pixelsPerInchPerUnit
        guard ImageSizeModel.isValidResolution(ppi) else { return nil }
        guard let w = Self.pixels(width, unit: sizeUnit, resolution: ppi),
              let h = Self.pixels(height, unit: sizeUnit, resolution: ppi) else { return nil }
        self.width = w
        self.height = h
        self.resolutionX = ppi
        self.resolutionY = ppi
        self.kind = kind
        self.contents = kind == .rgb ? contents : .white
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

    /// One width or height text as a whole pixel dimension. Pixels stay
    /// strict integers; the length units round at the chosen resolution.
    private static func pixels(_ text: String, unit: ImageSizeModel.SizeUnit, resolution: Double) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if unit == .pixels {
            guard let value = Int(trimmed), (1...524_288).contains(value) else { return nil }
            return value
        }
        guard let value = Double(trimmed) else { return nil }
        return unit.pixels(value, resolution: resolution)
    }

    /// The engine's contents for this image, with `background` (the tool
    /// background color) captured for Background Color.
    func engineContents(background: NSColor) throws -> EngineSession.NewImageContents {
        switch contents {
        case .white: return .white
        case .transparent: return .transparent
        case .backgroundColor: return .color(try EngineSession.recorderColor(background))
        }
    }
}

@MainActor
final class NewImagePanel: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let widthField = NSTextField(string: "1600")
    private let heightField = NSTextField(string: "1200")
    private let widthLabel = NSTextField(labelWithString: "Width (px):")
    private let heightLabel = NSTextField(labelWithString: "Height (px):")
    private let sizeUnitPopup = NSPopUpButton()
    private let resolutionField = NSTextField(string: "72")
    private let resolutionUnitPopup = NSPopUpButton()
    private let modePopup = NSPopUpButton()
    private let precisionPopup = NSPopUpButton()
    private let channelField = NSTextField(string: "4")
    private let contentsPopup = NSPopUpButton()
    private var contentsRow: NSGridRow?
    private let supportsContents: Bool
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
    private let supportsResolution: Bool
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    var onCreate: ((NewImageSettings) -> Void)?
    var onClose: (() -> Void)?

    init(profileLoader: any PsdCmykProfileCatalogLoading = LivePsdCmykProfileCatalogLoader(),
         supportsLab: Bool = false, supportsContents: Bool = false, supportsResolution: Bool = true) {
        self.profileLoader = profileLoader
        self.supportsLab = supportsLab
        self.supportsContents = supportsContents
        self.supportsResolution = supportsResolution
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 395),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "New Image"
        super.init(window: panel)
        panel.delegate = self
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(create(_:))
        createButton.keyEquivalent = "\r"
        for (field, label) in [(widthField, "Width"), (heightField, "Height"),
                               (channelField, "Ink channels"), (resolutionField, "Resolution")] {
            field.delegate = self
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 100).isActive = true
        }
        sizeUnitPopup.setAccessibilityLabel("Width and height unit")
        sizeUnitPopup.target = self
        sizeUnitPopup.action = #selector(sizeUnitChanged(_:))
        for unit in ImageSizeModel.SizeUnit.allCases {
            sizeUnitPopup.addItem(withTitle: unit.title)
        }
        sizeUnitPopup.selectItem(at: 0)
        resolutionUnitPopup.setAccessibilityLabel("Resolution unit")
        resolutionUnitPopup.target = self
        resolutionUnitPopup.action = #selector(resolutionUnitChanged(_:))
        for unit in ImageSizeModel.ResolutionUnit.allCases {
            resolutionUnitPopup.addItem(withTitle: unit.title)
        }
        resolutionUnitPopup.selectItem(at: 0)
        modePopup.addItems(withTitles: NewImageSettings.Kind.choices(supportsLab: supportsLab).map(\.title))
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        modePopup.setAccessibilityLabel("Image mode")
        precisionPopup.addItems(withTitles: ["8-bit", "16-bit", "32-bit float"])
        precisionPopup.setAccessibilityLabel("Precision")
        contentsPopup.addItems(withTitles: NewImageSettings.Contents.allCases.map(\.title))
        contentsPopup.setAccessibilityLabel("Contents")
        profilePopup.setAccessibilityLabel("CMYK source profile")
        profilePopup.widthAnchor.constraint(equalToConstant: 270).isActive = true
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))
        profileButton.target = self
        profileButton.action = #selector(chooseProfile(_:))
        rebuildProfiles()
        let grid = NSGridView(views: [[widthLabel, widthField],
                                     [heightLabel, heightField],
                                     [NSTextField(labelWithString: "Width/Height unit:"), sizeUnitPopup],
                                     [NSTextField(labelWithString: "Resolution:"), resolutionField],
                                     [NSTextField(labelWithString: "Resolution unit:"), resolutionUnitPopup],
                                     [NSTextField(labelWithString: "Mode:"), modePopup],
                                     [NSTextField(labelWithString: "Precision:"), precisionPopup],
                                     [NSTextField(labelWithString: "Ink channels:"), channelField],
                                     [NSTextField(labelWithString: "Source profile:"), profilePopup],
                                     [NSView(), profileButton],
                                     [NSTextField(labelWithString: "Contents:"), contentsPopup]])
        grid.column(at: 0).xPlacement = .trailing
        channelRow = grid.row(at: 7)
        profileRows = [grid.row(at: 8), grid.row(at: 9)]
        contentsRow = grid.row(at: 10)
        let resolutionRows = [grid.row(at: 2), grid.row(at: 3), grid.row(at: 4)]
        resolutionRows.forEach { $0.isHidden = !supportsResolution }
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
    @objc private func sizeUnitChanged(_ sender: Any?) { updateValidation() }
    @objc private func resolutionUnitChanged(_ sender: Any?) { updateValidation() }
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
                                profileICC: selectedProfile?.iccData, contents: contents,
                                sizeUnit: sizeUnit, resolution: resolutionText,
                                resolutionUnit: effectiveResolutionUnit)
    }

    /// The resolution controls are hidden on adapters without the slots, so
    /// their text cannot contribute a value; the settings keep the default.
    private var resolutionText: String {
        supportsResolution ? resolutionField.stringValue : String(ImageSizeModel.defaultResolution)
    }

    private var effectiveResolutionUnit: ImageSizeModel.ResolutionUnit {
        supportsResolution ? resolutionUnit : .pixelsPerInch
    }

    private var sizeUnit: ImageSizeModel.SizeUnit {
        let cases = ImageSizeModel.SizeUnit.allCases
        guard cases.indices.contains(sizeUnitPopup.indexOfSelectedItem) else { return .pixels }
        return cases[sizeUnitPopup.indexOfSelectedItem]
    }

    private var resolutionUnit: ImageSizeModel.ResolutionUnit {
        let cases = ImageSizeModel.ResolutionUnit.allCases
        guard cases.indices.contains(resolutionUnitPopup.indexOfSelectedItem) else { return .pixelsPerInch }
        return cases[resolutionUnitPopup.indexOfSelectedItem]
    }

    /// The Contents choice, White when the adapter or the mode has none.
    private var contents: NewImageSettings.Contents {
        guard supportsContents, kind == .rgb else { return .white }
        return NewImageSettings.Contents(rawValue: contentsPopup.indexOfSelectedItem) ?? .white
    }

    private func updateValidation() {
        widthLabel.stringValue = "Width (\(sizeUnit.title)):"
        heightLabel.stringValue = "Height (\(sizeUnit.title)):"
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
        contentsRow?.isHidden = !(supportsContents && selectedKind == .rgb)
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
                                               height: heightField.stringValue,
                                               sizeUnit: sizeUnit, resolution: resolutionText,
                                               resolutionUnit: effectiveResolutionUnit) != nil
        if !dimensionsValid { errorLabel.stringValue = "Enter whole pixel numbers or valid lengths, and a resolution from 0.005 to 1048576." }
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
