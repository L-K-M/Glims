import XCTest
import AppKit
@testable import GlimsKit

@MainActor
final class DuplicateImageFormTests: XCTestCase {
    func testMergedLayersOnlyNeedsTheOptionAndSeveralLayers() {
        let form = DuplicateImageForm(name: "Art copy", offersMerged: true, layerCount: 2)
        XCTAssertEqual(form.name.stringValue, "Art copy")
        XCTAssertTrue(form.offersMerged)
        XCTAssertFalse(form.mergedLayersOnly)
        form.merged.state = .on
        XCTAssertTrue(form.mergedLayersOnly)

        let single = DuplicateImageForm(name: "One copy", offersMerged: true, layerCount: 1)
        single.merged.state = .on
        XCTAssertFalse(single.merged.isEnabled)
        XCTAssertFalse(single.mergedLayersOnly)

        let unavailable = DuplicateImageForm(name: "Old copy", offersMerged: false, layerCount: 4)
        unavailable.merged.state = .on
        XCTAssertFalse(unavailable.offersMerged)
        XCTAssertFalse(unavailable.mergedLayersOnly)
    }
}
