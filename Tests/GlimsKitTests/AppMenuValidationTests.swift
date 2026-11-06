import AppKit
import XCTest
@testable import GlimsKit

/// Without a running engine there are no documents, so the palettes that
/// show a document are not offered.
@MainActor
final class AppMenuValidationTests: XCTestCase {
    func testDocumentPalettesWaitForTheEngine() {
        let controller = AppController()
        for action in [#selector(AppController.showLayers(_:)), #selector(AppController.showPaths(_:)),
                       #selector(AppController.showTools(_:)), #selector(AppController.showToolOptions(_:))] {
            let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
            XCTAssertFalse(controller.validateMenuItem(item), "\(action) is offered without an engine")
        }
    }
}
