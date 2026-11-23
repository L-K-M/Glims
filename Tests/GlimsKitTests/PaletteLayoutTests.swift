import AppKit
@testable import RigiUI
import XCTest
@testable import GlimsKit

/// The first-launch palette arrangement (docs/design.md, section 2): Tools
/// at the top left with Tool Options docked under it, and one column of two
/// tab groups at the right: the Layers group with Color's group docked under
/// it. Every tab shows its whole title.
@MainActor
final class PaletteLayoutTests: XCTestCase {
    /// The menu bar and a Dock of ordinary size leave about this much of a
    /// 1440 x 900 screen's height.
    private let usableHeight: CGFloat = 800

    private let definitions = Dictionary(uniqueKeysWithValues: [
        ToolsPaletteController.definition,
        ToolOptionsPaletteController.definition,
        LayersPaletteController.definition,
        ChannelsPaletteController.definition,
        PathsPaletteController.definition,
        HistoryPaletteController.definition,
        RecorderPaletteController.definition,
        InfoPaletteController.definition,
        NavigatorPaletteController.definition,
        ColorPaletteController.definition,
        SwatchesPaletteController.definition,
    ].map { ($0.kind, $0) })

    func testTwoColumnsOfReadableGroupsHoldEveryPalette() {
        let tools = ToolsPaletteController.definition.kind
        let options = ToolOptionsPaletteController.definition.kind
        let layers = LayersPaletteController.definition.kind
        let channels = ChannelsPaletteController.definition.kind
        let paths = PathsPaletteController.definition.kind
        let history = HistoryPaletteController.definition.kind
        let recorder = RecorderPaletteController.definition.kind
        let info = InfoPaletteController.definition.kind
        let navigator = NavigatorPaletteController.definition.kind
        let color = ColorPaletteController.definition.kind
        let swatches = SwatchesPaletteController.definition.kind

        XCTAssertEqual(AppController.defaultPaletteLayout, [
            PaletteGroupDefault([tools], placement: .topLeading),
            PaletteGroupDefault([options], placement: .docked(below: tools)),
            PaletteGroupDefault([layers, channels, paths, history, recorder], placement: .topTrailing),
            PaletteGroupDefault([color, swatches, navigator, info], placement: .docked(below: layers)),
        ])
    }

    func testEveryDefaultTabShowsItsWholeTitle() throws {
        for group in AppController.defaultPaletteLayout where group.kinds.count > 1 {
            let tabs = try group.kinds.map { try XCTUnwrap(definitions[$0]) }
            let chrome = PaletteChromeView(title: tabs[0].title)
            chrome.frame.size = PalettePanel.panelSize(forContentSize: contentSize(of: tabs))
            chrome.tabTitles = tabs.map(\.title)
            // The menu triangle takes the most room away from the tabs.
            chrome.showsMenuButton = true

            let rects = chrome.tabRects
            XCTAssertEqual(rects.count, tabs.count)
            for (tab, rect) in zip(tabs, rects) {
                let natural = ceil(ClassicText.engraved(tab.title, size: 10.5, weight: .medium).size().width) + 16
                XCTAssertGreaterThanOrEqual(rect.width, natural, "the \(tab.title) tab cuts off its title")
            }
        }
    }

    /// A narrower group below a wider one leaves a ragged screen edge, and a
    /// wider one runs off the screen: docked groups align on their left.
    func testTheTrailingColumnHasOneWidthAndFitsASmallScreen() throws {
        let layout = AppController.defaultPaletteLayout
        let top = try XCTUnwrap(layout.first { $0.placement == .topTrailing })
        let column = [top] + layout.filter {
            guard case .docked(let below) = $0.placement else { return false }
            return top.kinds.contains(below)
        }
        let panels = try column.map { group in
            PalettePanel.panelSize(forContentSize: contentSize(of: try group.kinds.map { try XCTUnwrap(definitions[$0]) }))
        }

        XCTAssertEqual(Set(panels.map(\.width)).count, 1, "the column's groups differ in width: \(panels)")
        XCTAssertLessThanOrEqual(panels.map(\.height).reduce(0, +), usableHeight)
    }

    /// What Rigi gives a new group: the widest tab's width and the front
    /// tab's height.
    private func contentSize(of tabs: [PaletteDefinition]) -> NSSize {
        NSSize(width: tabs.map(\.contentSize.width).max() ?? 0, height: tabs[0].contentSize.height)
    }
}
