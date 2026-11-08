import Foundation

/// The bundled Glims manual (`Resources/GlimsManual.txt`) as sections of
/// plain English text. The file is a sequence of `# Title` headings, each
/// followed by its body; the Help window shows the sections and searches
/// their text. Everything here is pure and engine-free, so the tests can
/// check loading, parsing and search without a window or a document.
struct HelpManual: Equatable {
    struct Section: Equatable {
        let title: String
        /// The section's text without its heading.
        let body: String

        /// What the Help window displays for one section.
        var text: String { "\(title)\n\n\(body)" }
    }

    let sections: [Section]

    /// The whole manual, sections in file order.
    var text: String { sections.map(\.text).joined(separator: "\n\n") }

    /// The section the Help menu's "Keyboard & Mouse Reference" opens.
    static let keyboardReferenceTitle = "Keyboard & Mouse Reference"

    /// The engine's official documentation. Opened in the user's web
    /// browser only when they choose Help > Engine Manual; nothing is
    /// fetched at any other time.
    static let engineManualURL = URL(string: "https://docs.gimp.org/")!

    /// The manual out of `bundle`, or nil when the resource is missing or
    /// contains no sections.
    static func load(from bundle: Bundle = .module) -> HelpManual? {
        guard let url = bundle.url(forResource: "GlimsManual", withExtension: "txt"),
              let data = try? Data(contentsOf: url),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return HelpManual(text: raw)
    }

    /// Parses `text` into sections. Fails when it holds no `# Title`
    /// heading at all.
    init?(text: String) {
        var parsed: [Section] = []
        var title: String?
        var body: [String] = []

        func finishSection() {
            guard let title else { return }
            while body.last?.isEmpty == true { body.removeLast() }
            while body.first?.isEmpty == true { body.removeFirst() }
            parsed.append(Section(title: title, body: body.joined(separator: "\n")))
        }

        for rawLine in text.components(separatedBy: "\n") {
            if rawLine.hasPrefix("# "), !rawLine.dropFirst(2).isEmpty {
                finishSection()
                title = String(rawLine.dropFirst(2))
                body = []
            } else {
                body.append(rawLine)
            }
        }
        finishSection()

        guard !parsed.isEmpty else { return nil }
        sections = parsed
    }

    func section(titled wanted: String) -> Section? {
        sections.first { $0.title == wanted }
    }
}

/// Case-insensitive text search for the Help window's find-next.
enum HelpSearch {
    /// The first match of `query` at or after `location`, wrapping to the
    /// start of the text when the tail holds no match. Returns nil for an
    /// empty query or a query the text does not contain.
    static func nextRange(of query: String, in text: String, from location: Int) -> NSRange? {
        guard !query.isEmpty else { return nil }
        let whole = text as NSString
        let start = max(0, min(location, whole.length))
        let tail = NSRange(location: start, length: whole.length - start)
        let head = NSRange(location: 0, length: start)
        for range in [tail, head] {
            let found = whole.range(of: query, options: .caseInsensitive, range: range)
            if found.length > 0 { return found }
        }
        return nil
    }
}
