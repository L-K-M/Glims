import AppKit
import RigiUI

@MainActor
final class PreferencesWindowController: NSWindowController {
    private let preferences: EditorPreferences
    let appearancePicker = NSPopUpButton()
    let surroundPicker = NSPopUpButton()
    let initialViewPicker = NSPopUpButton()

    init(preferences: EditorPreferences? = nil) {
        self.preferences = preferences ?? .shared
        let window = PreferencesPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 230),
                                      styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Preferences"
        window.isReleasedWhenClosed = false
        let chrome = ClassicPanelView(frame: NSRect(x: 0, y: 0, width: 440, height: 230))
        window.contentView = chrome

        appearancePicker.addItems(withTitles: ClassicChromeScheme.allCases.map(\.displayName))
        surroundPicker.addItems(withTitles: EditorPreferences.Surround.allCases.map(\.title))
        initialViewPicker.addItems(withTitles: EditorPreferences.InitialView.allCases.map(\.title))
        let rows = [row("Appearance", appearancePicker, #selector(appearanceChanged(_:))),
                    row("Canvas Surround", surroundPicker, #selector(surroundChanged(_:))),
                    row("Open Images At", initialViewPicker, #selector(initialViewChanged(_:)))]
        let note = NSTextField(wrappingLabelWithString:
            "Appearance and canvas surround apply immediately. The zoom choice applies to newly opened images.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        let reset = NSButton(title: "Restore Defaults", target: self, action: #selector(restoreDefaults(_:)))
        reset.bezelStyle = .rounded
        let stack = NSStackView(views: rows + [note, reset])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        chrome.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 20),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: EditorPreferences.didChange, object: self.preferences)
        refresh()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func row(_ title: String, _ picker: NSPopUpButton, _ action: Selector) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 11)
        label.widthAnchor.constraint(equalToConstant: 120).isActive = true
        picker.font = .systemFont(ofSize: 11)
        picker.target = self
        picker.action = action
        picker.setAccessibilityLabel(title)
        let row = NSStackView(views: [label, picker])
        row.spacing = 12
        picker.widthAnchor.constraint(equalToConstant: 250).isActive = true
        return row
    }

    @objc private func refresh() {
        window?.appearance = preferences.chromeAppearance
        appearancePicker.selectItem(at: ClassicChromeScheme.allCases.firstIndex(of: preferences.appearance) ?? 0)
        surroundPicker.selectItem(at: EditorPreferences.Surround.allCases.firstIndex(of: preferences.surround) ?? 1)
        initialViewPicker.selectItem(at: EditorPreferences.InitialView.allCases.firstIndex(of: preferences.initialView) ?? 0)
    }

    @objc private func appearanceChanged(_ sender: NSPopUpButton) {
        guard ClassicChromeScheme.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        preferences.appearance = ClassicChromeScheme.allCases[sender.indexOfSelectedItem]
    }

    @objc private func surroundChanged(_ sender: NSPopUpButton) {
        guard EditorPreferences.Surround.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        preferences.surround = EditorPreferences.Surround.allCases[sender.indexOfSelectedItem]
    }

    @objc private func initialViewChanged(_ sender: NSPopUpButton) {
        guard EditorPreferences.InitialView.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        preferences.initialView = EditorPreferences.InitialView.allCases[sender.indexOfSelectedItem]
    }

    @objc private func restoreDefaults(_ sender: Any?) { preferences.reset() }
}

/// Preferences takes keyboard focus while the current document remains
/// main, so document palettes keep their target.
private final class PreferencesPanel: NSPanel {
    override var canBecomeMain: Bool { false }
}
