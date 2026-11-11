import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class LensSourceChooserTests: XCTestCase {
    private var chooser: FilterSourceChooserController?
    private var host: NSWindow!

    override func setUp() {
        super.setUp()
        host = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                        styleMask: [.titled], backing: .buffered, defer: false)
    }

    override func tearDown() {
        chooser?.invalidate()
        chooser = nil
        host.orderOut(nil)
        host = nil
        super.tearDown()
    }

    private func makeLens(rows: [FilterSourceChoice],
                          preview: @escaping (Int32?, @escaping (Result<Void, Error>) -> Void) -> Void = { _, reply in reply(.success(())) }) -> FilterSourceChooserController {
        let controller = FilterSourceChooserController(
            lensBlurTargetName: "Layer 1",
            rows: { rows },
            refusal: { nil },
            hostWindow: host,
            previewLensBlur: preview
        )
        chooser = controller
        return controller
    }

    private func firstPopup(in view: NSView?) -> NSPopUpButton? {
        guard let view else { return nil }
        if let popup = view as? NSPopUpButton { return popup }
        for subview in view.subviews {
            if let found = firstPopup(in: subview) { return found }
        }
        return nil
    }

    private func previewButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton, button.title == "Preview" { return button }
        for subview in view.subviews {
            if let found = previewButton(in: subview) { return found }
        }
        return nil
    }

    func testLensBlurSingleOptionalDefaultsToNoneDespiteOfferedPreferredTarget() {
        let controller = makeLens(rows: [FilterSourceChoice(id: 7, name: "Mask")])
        controller.show()

        let popup = firstPopup(in: controller.panel.contentView)
        XCTAssertNotNil(popup)
        XCTAssertEqual(popup?.selectedItem?.title, "None")
        XCTAssertEqual(popup?.accessibilityLabel(), "Blur mask source")
        XCTAssertNil(popup?.selectedItem.flatMap { $0.title == "None" ? nil : $0 })
    }

    func testNonePreviewCallbackGetsNilAndSuccessCloses() {
        var captured: Int32?? = .some(99)
        let controller = makeLens(rows: [FilterSourceChoice(id: 7, name: "Mask")]) { id, reply in
            captured = .some(id)
            reply(.success(()))
        }
        controller.show()

        let button = previewButton(in: controller.panel.contentView)
        XCTAssertNotNil(button)
        XCTAssertTrue(button?.isEnabled ?? false)
        button?.performClick(nil)

        XCTAssertEqual(captured, .some(nil))
        XCTAssertTrue(controller.isInvalidated)
    }

    func testExplicitSelectionInvalidatedOnRowRemovalWithoutSubstitutingNone() {
        var rows = [FilterSourceChoice(id: 7, name: "Mask")]
        let controller = FilterSourceChooserController(lensBlurTargetName: "Layer 1", rows: { rows },
            refusal: { nil }, hostWindow: host, previewLensBlur: { _, reply in reply(.success(())) })
        chooser = controller
        controller.show()

        guard let popup = firstPopup(in: controller.panel.contentView) else {
            return XCTFail("Expected source popup")
        }
        popup.selectItem(at: 1)
        XCTAssertTrue(popup.sendAction(popup.action, to: popup.target))
        XCTAssertTrue(popup.selectedItem?.title.contains("Mask") == true)

        rows = []
        controller.refresh()

        XCTAssertEqual(popup.selectedItem?.title, "Mask")
        XCTAssertFalse(popup.selectedItem?.isEnabled ?? true)
        let button = previewButton(in: controller.panel.contentView)
        XCTAssertFalse(button?.isEnabled ?? true)
        XCTAssertNotEqual(popup.selectedItem?.title, "None")
    }

    func testMandatoryBumpInitializerRemainsPositiveOnly() {
        let controller = FilterSourceChooserController(
            targetName: "Layer 1",
            preferredSource: 0,
            operation: .bumpMap,
            rows: { [FilterSourceChoice(id: 3, name: "Height")] },
            refusal: { nil },
            hostWindow: host,
            preview: { _, reply in reply(.success(())) }
        )
        chooser = controller
        controller.show()

        let popup = firstPopup(in: controller.panel.contentView)
        XCTAssertEqual(popup?.selectedItem?.title, "Height")
        XCTAssertFalse(popup?.itemArray.contains(where: { $0.title == "None" }) ?? true)
    }
}
