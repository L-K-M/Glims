import AppKit

/// Pixel dimensions accepted by the engine (libgimpbase/gimplimits.h).
struct NewImageSettings: Equatable {
    /// The kind of image to create.
    enum Kind: Equatable {
        case rgb, multichannel
    }

    /// Precisions offered for multichannel images.
    static let multichannelComponents: [EngineSession.ColorComponent] = [.u8, .u16, .float]

    let width: Int
    let height: Int
    let kind: Kind
    let component: EngineSession.ColorComponent
    let channelCount: Int

    /// `component` and `channelCount` apply to multichannel images only;
    /// RGB images always store the defaults and ignore dormant field errors.
    init?(width: String, height: String, kind: Kind = .rgb,
          component: EngineSession.ColorComponent = .u8, channelCount: String = "4") {
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
        case .multichannel:
            guard Self.multichannelComponents.contains(component),
                  let count = Int(channelCount.trimmingCharacters(in: .whitespacesAndNewlines)),
                  (1...32).contains(count) else { return nil }
            self.component = component
            self.channelCount = count
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
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    var onCreate: ((NewImageSettings) -> Void)?
    var onClose: (() -> Void)?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
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
        modePopup.addItems(withTitles: ["RGB", "Multichannel"])
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        modePopup.setAccessibilityLabel("Image mode")
        precisionPopup.addItems(withTitles: ["8-bit", "16-bit", "32-bit float"])
        precisionPopup.setAccessibilityLabel("Precision")
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Width (px):"), widthField],
                                     [NSTextField(labelWithString: "Height (px):"), heightField],
                                     [NSTextField(labelWithString: "Mode:"), modePopup],
                                     [NSTextField(labelWithString: "Precision:"), precisionPopup],
                                     [NSTextField(labelWithString: "Ink channels:"), channelField]])
        grid.column(at: 0).xPlacement = .trailing
        let buttons = NSStackView(views: [cancel, createButton])
        buttons.orientation = .horizontal
        let stack = NSStackView(views: [grid, errorLabel, buttons])
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
            ])
        }
        errorLabel.font = .systemFont(ofSize: 11)
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
    @objc private func modeChanged(_ sender: Any?) { updateValidation() }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func controlTextDidChange(_ notification: Notification) { updateValidation() }

    private var kind: NewImageSettings.Kind {
        modePopup.indexOfSelectedItem == 1 ? .multichannel : .rgb
    }

    private func currentSettings() -> NewImageSettings? {
        let index = precisionPopup.indexOfSelectedItem
        let component = NewImageSettings.multichannelComponents.indices.contains(index)
            ? NewImageSettings.multichannelComponents[index] : .u8
        return NewImageSettings(width: widthField.stringValue, height: heightField.stringValue,
                                kind: kind, component: component, channelCount: channelField.stringValue)
    }

    private func updateValidation() {
        let multichannel = kind == .multichannel
        precisionPopup.isEnabled = multichannel
        channelField.isEnabled = multichannel
        let settings = currentSettings()
        createButton.isEnabled = settings != nil
        guard settings == nil else { errorLabel.stringValue = ""; return }
        let dimensionsValid = NewImageSettings(width: widthField.stringValue,
                                               height: heightField.stringValue) != nil
        errorLabel.stringValue = dimensionsValid
            ? "Enter a whole number of ink channels from 1 to 32."
            : "Enter whole numbers from 1 to 524288."
    }
}
