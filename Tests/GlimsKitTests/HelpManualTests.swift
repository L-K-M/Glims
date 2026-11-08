import XCTest
@testable import GlimsKit

/// The bundled manual: loading from the package resource, parsing into
/// sections, and the Help window's find-next search.
final class HelpManualTests: XCTestCase {
    func testManualLoadsFromThePackageBundle() {
        let manual = HelpManual.load()
        XCTAssertNotNil(manual, "Resources/GlimsManual.txt did not load from the bundle")
        guard let manual else { return }
        XCTAssertFalse(manual.sections.isEmpty)
        XCTAssertGreaterThan(manual.text.count, 3000, "the manual is too short to be useful")
        XCTAssertEqual(manual.sections.first?.title, "Glims Help")
        XCTAssertNotNil(manual.section(titled: HelpManual.keyboardReferenceTitle))
    }

    /// The manual must describe the current features and not advertise the
    /// ones that are missing (the assigned help slice's topic list).
    func testManualCoversTheCurrentFeatures() {
        // The manual wraps lines, so phrases may span a line break.
        let text = (HelpManual.load()?.text ?? "").replacingOccurrences(of: "\n", with: " ")
        for phrase in ["Save As…", "Export…", "clipboard", "Paint Bucket",
                       "New Layer Group", "Lock Transparency",
                       "not part of this release", "History palette", "New Snapshot",
                       "live preview", "Apply", "Cancel",
                       "Workspaces", "Preferences…",
                       "physical pixels", "Actual Pixels"] {
            XCTAssertTrue(text.contains(phrase), "the manual never mentions \(phrase)")
        }
    }

    func testSectionsParse() throws {
        let manual = try XCTUnwrap(HelpManual(text: "# One\n\nfirst line\n\n# Two\n\nsecond"))
        XCTAssertEqual(manual.sections, [
            HelpManual.Section(title: "One", body: "first line"),
            HelpManual.Section(title: "Two", body: "second"),
        ])
        XCTAssertEqual(manual.text, "One\n\nfirst line\n\nTwo\n\nsecond")
    }

    func testTextWithoutAHeadingDoesNotParse() {
        XCTAssertNil(HelpManual(text: "just prose"))
    }

    // MARK: Search

    private let sample = "one two ONE two"

    func testSearchIsCaseInsensitive() {
        XCTAssertEqual(HelpSearch.nextRange(of: "OnE", in: sample, from: 0), NSRange(location: 0, length: 3))
    }

    func testSearchStepsToTheNextMatch() {
        XCTAssertEqual(HelpSearch.nextRange(of: "one", in: sample, from: 3), NSRange(location: 8, length: 3))
    }

    func testSearchWrapsToTheFirstMatch() {
        XCTAssertEqual(HelpSearch.nextRange(of: "one", in: sample, from: sample.count),
                       NSRange(location: 0, length: 3))
    }

    func testSearchReturnsNilWithoutAMatch() {
        XCTAssertNil(HelpSearch.nextRange(of: "three", in: sample, from: 0))
    }

    func testSearchRejectsAnEmptyQuery() {
        XCTAssertNil(HelpSearch.nextRange(of: "", in: sample, from: 0))
    }
}
