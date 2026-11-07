import AppKit
import XCTest
@testable import GlimsKit

/// The recovery panel's window behavior and states: a non-main list of
/// prior records, multi-selection, busy/error/empty states, and a
/// discard that asks before it deletes. Records are fabricated through
/// a prior run's own store so the panel shows real discovered rows.
@MainActor
final class RecoveryPanelTests: XCTestCase {
    private var base: URL!
    private let files = FileManager.default

    override func setUp() {
        _ = NSApplication.shared
        base = files.temporaryDirectory
            .appendingPathComponent("glims-recovery-panel-\(UUID().uuidString)", isDirectory: true)
        try? files.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? files.removeItem(at: base)
        base = nil
    }

    /// A dead run's two committed records, discovered by this run's store.
    private func makeRecords() throws -> (store: RecoveryStore, records: [RecoveryStore.RecoveredDocument]) {
        let prior = RecoveryStore(base: base, runID: UUID(), ownerPID: 4242,
                                  processIsAlive: { _ in false })
        try prior.prepare()
        for (id, name, native) in [(UUID(), "First.xcf", "/tmp/first.xcf"),
                                   (UUID(), "Second.xcf", nil)] {
            let temp = prior.temporaryCopyURL(for: id)
            try Data("xcf".utf8).write(to: temp)
            _ = try prior.commitCopy(at: temp, for: id, metadata: .init(
                name: name, nativeURL: native.map { URL(fileURLWithPath: $0) },
                importedSourceURL: nil, revision: 1))
        }
        let store = RecoveryStore(base: base, runID: UUID(), processIsAlive: { _ in false })
        try store.prepare()
        return (store, store.discoverRecoverableDocuments())
    }

    func testPanelIsNonMainAndListsRecords() throws {
        let (_, records) = try makeRecords()
        XCTAssertEqual(records.count, 2)
        let panel = RecoveryPanelController()
        defer { panel.close() }
        panel.setRecords(records)
        panel.showWindow(nil)
        XCTAssertFalse(panel.window!.canBecomeMain,
                       "the recovery panel must not retarget the document palettes")
        XCTAssertTrue(panel.window!.isVisible)
        XCTAssertEqual(panel.tableView.numberOfRows, 2)
        XCTAssertFalse(panel.recoverButton.isEnabled, "nothing acts without a selection")
        XCTAssertFalse(panel.discardButton.isEnabled)

        panel.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        XCTAssertTrue(panel.recoverButton.isEnabled && panel.discardButton.isEnabled)
        panel.tableView.selectRowIndexes(IndexSet(integersIn: 0...1), byExtendingSelection: true)
        XCTAssertEqual(panel.selectedRecords.count, 2, "several records can be selected")

        // Sensible actual frames: a scrollable list inside a resizable
        // window with a real minimum size.
        XCTAssertNotNil(panel.tableView.enclosingScrollView)
        XCTAssertTrue(panel.tableView.enclosingScrollView?.hasVerticalScroller ?? false)
        XCTAssertGreaterThanOrEqual(panel.window!.frame.width, 460)
        XCTAssertGreaterThanOrEqual(panel.window!.frame.height, 240)
        XCTAssertEqual(panel.window!.minSize, NSSize(width: 460, height: 240))
        XCTAssertEqual(panel.window?.title, "Recover Documents")

        let nameColumn = panel.tableView.tableColumns[0]
        let row = records.firstIndex { $0.name == "First.xcf" }!
        let cell = panel.tableView(panel.tableView, viewFor: nameColumn, row: row) as? NSTableCellView
        XCTAssertEqual(cell?.textField?.stringValue, "First.xcf")
        let sourceColumn = panel.tableView.tableColumns[2]
        let sourceCell = panel.tableView(panel.tableView, viewFor: sourceColumn, row: row) as? NSTableCellView
        XCTAssertEqual(sourceCell?.textField?.stringValue, "/tmp/first.xcf")
    }

    func testSourceDescriptionsAreInformational() {
        var record = RecoveryStore.RecoveredDocument(runID: UUID(), documentID: UUID(), name: "A",
                                                     nativeURL: nil, importedSourceURL: nil,
                                                     copyURL: URL(fileURLWithPath: "/x"),
                                                     date: Date(), revision: nil)
        XCTAssertEqual(RecoveryPanelController.sourceDescription(record), "Never saved to a file")
        record.nativeURL = URL(fileURLWithPath: "/tmp/a.xcf")
        XCTAssertEqual(RecoveryPanelController.sourceDescription(record), "/tmp/a.xcf")
        record.nativeURL = nil
        record.importedSourceURL = URL(fileURLWithPath: "/tmp/a.png")
        XCTAssertEqual(RecoveryPanelController.sourceDescription(record), "Imported from /tmp/a.png")
    }

    func testEmptyAndBusyStates() throws {
        let (_, records) = try makeRecords()
        let panel = RecoveryPanelController()
        defer { panel.close() }
        panel.setRecords([])
        XCTAssertEqual(panel.statusText, "No recovery copies were found.")
        panel.showStatus("The store could not be read.")
        XCTAssertEqual(panel.statusText, "The store could not be read.")

        panel.setRecords(records)
        panel.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        panel.setBusy(true)
        XCTAssertTrue(panel.busy)
        XCTAssertFalse(panel.recoverButton.isEnabled && panel.discardButton.isEnabled,
                       "busy work disables both actions")
        panel.setBusy(false)
        XCTAssertTrue(panel.recoverButton.isEnabled && panel.discardButton.isEnabled)
    }

    func testRecoverSendsTheSelectedRecordsOnly() throws {
        let (_, records) = try makeRecords()
        let panel = RecoveryPanelController()
        defer { panel.close() }
        var recovered: [RecoveryStore.RecoveredDocument] = []
        panel.onRecover = { recovered = $0 }
        panel.setRecords(records)
        panel.showWindow(nil)
        panel.recoverButton.performClick(nil)
        XCTAssertTrue(recovered.isEmpty, "no selection recovers nothing")
        panel.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        panel.recoverButton.performClick(nil)
        XCTAssertEqual(recovered.map(\.documentID), [records[0].documentID],
                       "only the selected record is sent")
    }

    func testDiscardAsksForExplicitConfirmation() throws {
        let (_, records) = try makeRecords()
        let panel = RecoveryPanelController()
        defer { panel.close() }
        var discarded: [RecoveryStore.RecoveredDocument] = []
        panel.onDiscard = { discarded = $0 }
        panel.setRecords(records)
        panel.showWindow(nil)
        panel.tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        panel.discardButton.performClick(nil)
        let sheet = try XCTUnwrap(panel.window?.attachedSheet)
        panel.window?.endSheet(sheet, returnCode: .alertSecondButtonReturn)
        XCTAssertTrue(discarded.isEmpty, "Cancel discards nothing")

        panel.discardButton.performClick(nil)
        let sheetAgain = try XCTUnwrap(panel.window?.attachedSheet)
        panel.window?.endSheet(sheetAgain, returnCode: .alertFirstButtonReturn)
        XCTAssertEqual(discarded.map(\.documentID), [records[0].documentID],
                       "only the confirmed records are sent")
    }

    func testLaterClosesThePanelAndKeepsEveryRecord() throws {
        let (store, records) = try makeRecords()
        let panel = RecoveryPanelController()
        defer { panel.close() }
        panel.setRecords(records)
        panel.showWindow(nil)
        panel.laterButton.performClick(nil)
        XCTAssertFalse(panel.window!.isVisible, "Later closes the panel")
        XCTAssertEqual(store.discoverRecoverableDocuments().count, 2,
                       "Later keeps every record on disk")
    }
}
