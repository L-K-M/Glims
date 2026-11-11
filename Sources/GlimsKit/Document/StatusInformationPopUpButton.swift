import AppKit

/// An editor-specific accessory in Rigi's existing status strip.
@MainActor
final class StatusInformationPopUpButton: NSPopUpButton {
    private(set) var selectedInformation = StatusInformationChoice.dimensions
    private(set) var information = StatusInformationSnapshot()

    init(information: StatusInformationSnapshot = StatusInformationSnapshot()) {
        self.information = information
        super.init(frame: .zero, pullsDown: false)
        controlSize = .mini
        font = .systemFont(ofSize: 10)
        cell?.lineBreakMode = .byTruncatingTail
        cell?.usesSingleLineMode = true
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 190).isActive = true
        for choice in StatusInformationChoice.allCases {
            addItem(withTitle: choice.label)
            lastItem?.tag = choice.rawValue
            lastItem?.toolTip = choice.help
        }
        target = self
        action = #selector(informationChosen)
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ information: StatusInformationSnapshot) {
        self.information = information
        refresh()
    }

    func selectInformation(_ choice: StatusInformationChoice) {
        selectedInformation = choice
        refresh()
    }

    @objc private func informationChosen() {
        guard let choice = StatusInformationChoice(rawValue: selectedTag) else { return }
        selectInformation(choice)
    }

    private func refresh() {
        for choice in StatusInformationChoice.allCases {
            menu?.item(withTag: choice.rawValue)?.title = information.title(for: choice)
        }
        selectItem(withTag: selectedInformation.rawValue)
        setAccessibilityLabel("Status information: \(selectedInformation.label)")
        setAccessibilityHelp(selectedInformation.help)
        let bytes = selectedInformation == .canvasCacheMemory
            ? " (\(information.renderMetrics.cachedPixelBytes) bytes)" : ""
        toolTip = information.title(for: selectedInformation) + bytes + "\n" + selectedInformation.help
    }
}
