import CGlimsEngine
import XCTest
@testable import GlimsKit

/// Pure checks for the Fill sheet's embedded pattern picker: the model's
/// search, selection, missing-identity and generation rules; the lazy
/// thumbnail queue's bounded batches; and the persisted identity store.
/// No engine, no AppKit.
final class PatternFillChooserTests: XCTestCase {
    private func identity(_ name: String, collection: String? = "Patterns",
                          isInternal: Bool = false) -> EngineSession.ResourceIdentity {
        EngineSession.ResourceIdentity(name: name, collection: collection, isInternal: isInternal)
    }

    private func row(_ id: UInt64, _ name: String) -> PatternRow {
        PatternRow(id: id, name: name, identity: identity(name))
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ch.lkmc.Glims.tests.patternfill.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    // MARK: Store

    func testStorePersistsOnlyTheIdentity() throws {
        withDefaults { defaults in
            let store = PatternFillStore(defaults: defaults)
            XCTAssertNil(store.identity)
            let choice = identity("Bricks", collection: nil)
            store.set(choice)
            XCTAssertEqual(PatternFillStore(defaults: defaults).identity, choice,
                           "the choice survives a fresh store instance")
            let raw = String(decoding: defaults.data(forKey: PatternFillStore.selectionKey)!, as: UTF8.self)
            XCTAssertTrue(raw.contains("\"name\":\"Bricks\""))
            XCTAssertFalse(raw.contains("collection"), "a NULL collection persists as no key")
            store.set(nil)
            XCTAssertNil(store.identity, "clearing removes the entry")
        }
    }

    func testStoreToleratesCorruptData() {
        withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: PatternFillStore.selectionKey)
            XCTAssertNil(PatternFillStore(defaults: defaults).identity,
                         "corrupt data reads as no choice, not a crash")
        }
    }

    // MARK: Catalog delivery and selection

    func testDeliveryPreselectsTheResolvedCurrentPattern() {
        let model = PatternChooserModel(currentIdentity: identity("Bricks"))
        XCTAssertTrue(model.deliver(generation: 0,
                                    rows: [row(1, "Bricks"), row(2, "Pine")],
                                    resolvedCurrent: 1, error: nil))
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.selection, 1, "the resolved row is highlighted")
        XCTAssertNil(model.missingIdentity)
        XCTAssertEqual(model.pendingIdentity(), identity("Bricks"))
    }

    func testMissingCurrentPatternIsReportedAndNeverSubstituted() {
        let model = PatternChooserModel(currentIdentity: identity("Gone"))
        model.deliver(generation: 0, rows: [row(1, "Bricks")], resolvedCurrent: nil, error: nil)
        XCTAssertEqual(model.missingIdentity, identity("Gone"),
                       "a NOT_FOUND persisted pattern is shown as missing")
        XCTAssertNil(model.resolutionError)
        XCTAssertNil(model.pendingIdentity(),
                     "no fill may proceed until the user picks a live pattern")
        model.select(1)
        XCTAssertEqual(model.pendingIdentity(), identity("Bricks"))
    }

    func testNonNotFoundResolutionErrorIsNotMissing() {
        let model = PatternChooserModel(currentIdentity: identity("Bricks"))
        let failure = EngineSession.EngineError(status: Int32(GLIMS_STATUS_BUSY.rawValue),
                                                message: "engine busy")
        model.deliver(generation: 0, rows: [row(1, "Bricks")], resolvedCurrent: nil,
                      resolutionError: failure, error: nil)
        XCTAssertEqual(model.resolutionError, "engine busy")
        XCTAssertNil(model.missingIdentity, "a busy failure is not a missing pattern")
        XCTAssertNil(model.pendingIdentity())
    }

    func testSelectionOutsideRowsKeepsAValidCurrentChoice() {
        // The persisted pattern resolved but its row is not in the loaded
        // list: the identity remains committable (valid resolvedCurrent).
        let model = PatternChooserModel(currentIdentity: identity("Bricks"))
        model.deliver(generation: 0, rows: [row(2, "Pine")], resolvedCurrent: 9, error: nil)
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.pendingIdentity(), identity("Bricks"))
    }

    func testNoPersistedChoiceRequiresAPick() {
        let model = PatternChooserModel(currentIdentity: nil)
        model.deliver(generation: 0, rows: [row(1, "Bricks")], resolvedCurrent: nil, error: nil)
        XCTAssertNil(model.pendingIdentity(), "nothing is filled without an explicit pick")
        model.select(1)
        XCTAssertEqual(model.pendingIdentity(), identity("Bricks"))
    }

    func testStaleDeliveriesAreDropped() {
        let model = PatternChooserModel(currentIdentity: nil)
        model.invalidate()
        XCTAssertFalse(model.deliver(generation: 0, rows: [row(1, "Bricks")],
                                     resolvedCurrent: nil, error: nil),
                       "a delivery from before invalidation changes nothing")
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertFalse(model.deliverThumbnails(generation: 0, rendered: [:], failed: [:]))
    }

    func testLoadErrorIsReported() {
        let model = PatternChooserModel(currentIdentity: nil)
        model.deliver(generation: 0, rows: [], resolvedCurrent: nil, error: "engine exploded")
        XCTAssertEqual(model.state, .error("engine exploded"))
    }

    // MARK: Search over the full catalog

    func testSearchFiltersBySubstringWithoutCapping() {
        let model = PatternChooserModel(currentIdentity: nil)
        let rows = (0..<200).map { row(UInt64($0), "Pattern \($0)") } + [row(999, "brIck wall")]
        model.deliver(generation: 0, rows: rows, resolvedCurrent: nil, error: nil)
        XCTAssertEqual(model.rows(matching: "").count, 201, "the full catalog is kept")
        XCTAssertEqual(model.rows(matching: "pattern").count, 200, "every match is reported")
        XCTAssertEqual(model.rows(matching: "brick").map(\.name), ["brIck wall"],
                       "search is case-insensitive")
        XCTAssertTrue(model.rows(matching: "nothing matches").isEmpty)
    }

    // MARK: Lazy thumbnail queue

    func testThumbnailQueueBatchesAndDeduplicates() {
        let queue = PatternThumbnailQueue()
        queue.begin(generation: 1)
        XCTAssertEqual(queue.request([3, 1, 2]), 3)
        XCTAssertEqual(queue.request([1, 4]), 1, "requested ids are not duplicated")
        let batch = queue.beginBatch(max: 2)
        XCTAssertEqual(batch, [3, 1], "bounded batches keep request order")
        XCTAssertTrue(queue.beginBatch().isEmpty, "no overlapping batches")
        XCTAssertTrue(queue.complete(generation: 1, rendered: [3], failed: [1: "bad"]))
        XCTAssertEqual(queue.status(of: 3), .rendered)
        XCTAssertEqual(queue.status(of: 1), .failed("bad"))
        XCTAssertEqual(queue.request([3, 1]), 0, "finished ids are never re-requested")
        XCTAssertEqual(queue.beginBatch(), [2, 4].prefix(2).map { $0 }, "the rest stay pending")
    }

    func testThumbnailQueuePriorityAndStaleCompletion() {
        let queue = PatternThumbnailQueue()
        queue.begin(generation: 2)
        queue.request([5, 6])
        queue.request([9], priority: true)
        XCTAssertEqual(queue.beginBatch(), [9, 5, 6])
        XCTAssertFalse(queue.complete(generation: 1, rendered: [9], failed: [:]),
                       "a stale generation's completion is dropped")
        queue.invalidate()
        XCTAssertTrue(queue.isIdle)
        XCTAssertFalse(queue.complete(generation: 2, rendered: [9], failed: [:]))
    }

    func testThumbnailQueueRequeuesARefusedBatch() {
        let queue = PatternThumbnailQueue()
        queue.begin(generation: 0)
        queue.request([1, 2, 3])
        let batch = queue.beginBatch(max: 2)
        queue.requeue(batch)
        XCTAssertEqual(queue.beginBatch(max: 2), batch, "a refused batch returns to the front")
        XCTAssertTrue(queue.complete(generation: 0, rendered: batch, failed: [:]))
        XCTAssertEqual(queue.beginBatch(), [3], "the remaining request stays queued")
    }
}
