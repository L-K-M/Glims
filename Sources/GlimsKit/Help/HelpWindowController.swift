import AppKit

/// The Glims Help window: the bundled manual, one section or all of it,
/// with a search field that finds text case-insensitively and steps to the
/// next match. The window is a panel that never becomes main, so opening
/// Help preserves the current document as the target of palettes and
/// document commands (like PreferencesPanel). It shows only the bundled
/// manual; the sole external link is Help > Engine Manual, which opens the
/// user's web browser on explicit request.
@MainActor
final class HelpWindowController: NSWindowController {
    private let manual: HelpManual
    private let searchField = NSSearchField()
    private let sectionPicker = NSPopUpButton()
    private let textView: NSTextView
    private let resultLabel = NSTextField(labelWithString: "")

    /// The query whose search found nothing; nil while the search state is
    /// clear. Drives the "No results" line under the text.
    private(set) var noResultsQuery: String?
    private var lastQuery: String?

    private static let allSectionsTitle = "All Sections"

    init(manual: HelpManual? = nil) {
        self.manual = manual ?? HelpManual.load()
            ?? HelpManual(text: "# Glims Help\n\nThe Glims manual is missing from this copy of the application.")!
        self.textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 608, height: 400))
        let window = HelpPanel(contentRect: NSRect(x: 0, y: 0, width: 640, height: 520),
                               styleMask: [.titled, .closable, .resizable],
                               backing: .buffered, defer: false)
        super.init(window: window)
        window.title = "Glims Help"
        window.isReleasedWhenClosed = false

        searchField.placeholderString = "Search"
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchFieldChanged(_:))
        searchField.setAccessibilityLabel("Search the Glims manual")
        searchField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        sectionPicker.addItems(withTitles: [Self.allSectionsTitle] + self.manual.sections.map(\.title))
        sectionPicker.target = self
        sectionPicker.action = #selector(sectionChanged(_:))
        sectionPicker.setAccessibilityLabel("Manual section")

        let topRow = NSStackView(views: [searchField, sectionPicker])
        topRow.spacing = 12

        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: 12, height: 16)
        textView.setAccessibilityLabel("Glims manual text")
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        resultLabel.font = .systemFont(ofSize: 11)
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.isHidden = true

        let stack = NSStackView(views: [topRow, scroll, resultLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let chrome = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 520))
        window.contentView = chrome
        chrome.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: chrome.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: chrome.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: chrome.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: chrome.bottomAnchor, constant: -16),
            topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        showSection(at: 0)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
                                               name: EditorPreferences.didChange, object: EditorPreferences.shared)
        refresh()
        window.initialFirstResponder = searchField
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows the window, optionally at one section's text. Unknown titles
    /// leave the current section alone.
    func show(section title: String?) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        guard let title, let index = manual.sections.firstIndex(where: { $0.title == title }) else { return }
        sectionPicker.selectItem(at: index + 1)
        showSection(at: index + 1)
    }

    // MARK: Search (exposed for tests)

    /// The search field's query.
    var query: String {
        get { searchField.stringValue }
        set { searchField.stringValue = newValue }
    }

    /// The text shown now: all sections or one of them.
    var displayedText: String { textView.string }

    /// The manual text selection the search moved to.
    var selection: NSRange { textView.selectedRange() }

    @objc func searchFieldChanged(_ sender: Any?) { findNext() }

    /// Selects the next match of the query and scrolls it into view. A new
    /// query searches from the current selection; repeating the action (the
    /// Return key) steps past the current match and wraps at the end. When
    /// nothing matches, the selection stays and the "No results" state is
    /// entered; the next successful search or an empty query clears it.
    func findNext() {
        let query = searchField.stringValue
        let isNewQuery = query != lastQuery
        lastQuery = query
        guard !query.isEmpty else {
            setNoResults(nil)
            return
        }
        let selection = textView.selectedRange()
        let from = isNewQuery ? selection.location : NSMaxRange(selection)
        guard let range = HelpSearch.nextRange(of: query, in: textView.string, from: from) else {
            setNoResults(query)
            return
        }
        setNoResults(nil)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }

    // MARK: Sections

    @objc private func sectionChanged(_ sender: NSPopUpButton) {
        showSection(at: sender.indexOfSelectedItem)
    }

    /// Shows one section by pop-up index (0 shows the whole manual) and
    /// re-runs the current query over the new text.
    private func showSection(at index: Int) {
        textView.string = (1...manual.sections.count).contains(index)
            ? manual.sections[index - 1].text : manual.text
        lastQuery = nil
        if searchField.stringValue.isEmpty {
            setNoResults(nil)
        } else {
            findNext()
        }
    }

    private func setNoResults(_ query: String?) {
        noResultsQuery = query
        resultLabel.isHidden = query == nil
        resultLabel.stringValue = query.map { "No results for “\($0)”." } ?? ""
    }

    @objc private func refresh() {
        window?.appearance = EditorPreferences.shared.chromeAppearance
    }
}

/// Help takes keyboard focus while the current document remains main, so
/// opening Help preserves the document target.
private final class HelpPanel: NSPanel {
    override var canBecomeMain: Bool { false }
}
