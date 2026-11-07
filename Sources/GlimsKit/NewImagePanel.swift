import AppKit

/// Pixel dimensions accepted by the engine (libgimpbase/gimplimits.h).
struct NewImageSettings: Equatable {
    let width: Int
    let height: Int

    init?(width: String, height: String) {
        guard let w = Int(width.trimmingCharacters(in: .whitespacesAndNewlines)),
              let h = Int(height.trimmingCharacters(in: .whitespacesAndNewlines)),
              (1...524_288).contains(w), (1...524_288).contains(h) else { return nil }
        self.width = w
        self.height = h
    }
}

@MainActor
final class NewImagePanel: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let widthField = NSTextField(string: "1600")
    private let heightField = NSTextField(string: "1200")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private let createButton = NSButton(title: "Create", target: nil, action: nil)
    var onCreate: ((NewImageSettings) -> Void)?
    var onClose: (() -> Void)?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 180),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "New Image"
        super.init(window: panel)
        panel.delegate = self
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        createButton.target = self
        createButton.action = #selector(create(_:))
        createButton.keyEquivalent = "\r"
        for (field, label) in [(widthField, "Width in pixels"), (heightField, "Height in pixels")] {
            field.delegate = self
            field.setAccessibilityLabel(label)
            field.widthAnchor.constraint(equalToConstant: 100).isActive = true
        }
        let grid = NSGridView(views: [[NSTextField(labelWithString: "Width (px):"), widthField],
                                     [NSTextField(labelWithString: "Height (px):"), heightField]])
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
            ])
        }
        errorLabel.font = .systemFont(ofSize: 11)
        panel.initialFirstResponder = widthField
        panel.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func create(_ sender: Any?) {
        guard let settings = NewImageSettings(width: widthField.stringValue, height: heightField.stringValue) else {
            validateDimensions()
            return
        }
        onCreate?(settings)
        close()
    }

    @objc private func cancel(_ sender: Any?) { close() }
    func windowWillClose(_ notification: Notification) { onClose?() }
    func controlTextDidChange(_ notification: Notification) { validateDimensions() }

    private func validateDimensions() {
        let valid = NewImageSettings(width: widthField.stringValue, height: heightField.stringValue) != nil
        createButton.isEnabled = valid
        errorLabel.stringValue = valid ? "" : "Enter whole numbers from 1 to 524288."
    }
}
