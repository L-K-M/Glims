import AppKit
import CGlimsEngine
import XCTest
@testable import GlimsKit

/// Pure checks for the brush chooser's model and its persistence: the
/// per-tool identity encode/restore (never a session handle), the in-memory
/// search, and the captured-tool / cancel / missing semantics. No engine,
/// no AppKit windows.
final class BrushChooserTests: XCTestCase {
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ch.lkmc.Glims.tests.brushchooser.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    private static func identity(_ name: String) -> EngineSession.ResourceIdentity {
        EngineSession.ResourceIdentity(name: name, collection: nil, isInternal: false)
    }

    private static func row(_ id: UInt64, _ name: String) -> BrushRow {
        BrushRow(id: id, name: name, identity: identity(name))
    }

    private static func tinyImage() -> CGImage {
        let provider = CGDataProvider(data: Data([0, 0, 0, 255]) as CFData)!
        return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }

    func testCatalogMutationInvalidatesOnlyMatchingPresentation() {
        let removed = Self.identity("Removed"), other = Self.identity("Other")
        var cache = BrushChoiceCache()
        cache.setPreview(Self.tinyImage(), identity: removed, for: .paintbrush)
        cache.setMissing(removed, for: .paintbrush)
        cache.setPreview(Self.tinyImage(), identity: other, for: .eraser)
        cache.invalidate(identity: removed)
        XCTAssertNil(cache.preview(for: .paintbrush, choice: removed))
        XCTAssertNil(cache.missingIdentity(for: .paintbrush, choice: removed))
        XCTAssertNotNil(cache.preview(for: .eraser, choice: other))
    }

    // MARK: Persistence

    func testIdentitiesPersistPerToolAcrossInstances() {
        withDefaults { defaults in
            let store = BrushSelectionStore(defaults: defaults)
            XCTAssertNil(store.identity(for: .paintbrush))
            store.set(Self.identity("2. Hardness 025"), for: .paintbrush)
            store.set(Self.identity("2. Block 01"), for: .eraser)
            let reopened = BrushSelectionStore(defaults: defaults)
            XCTAssertEqual(reopened.identity(for: .paintbrush), Self.identity("2. Hardness 025"))
            XCTAssertEqual(reopened.identity(for: .eraser), Self.identity("2. Block 01"))
            XCTAssertNil(reopened.identity(for: .pencil), "an unset tool stays the native default")
        }
    }

    func testResetToNativeDefaultRemovesTheStoredIdentity() {
        withDefaults { defaults in
            let store = BrushSelectionStore(defaults: defaults)
            store.set(Self.identity("2. Hardness 025"), for: .paintbrush)
            store.set(nil, for: .paintbrush)
            XCTAssertNil(store.identity(for: .paintbrush))
            XCTAssertNil(BrushSelectionStore(defaults: defaults).identity(for: .paintbrush))
            let json = String(decoding: defaults.data(forKey: BrushSelectionStore.selectionsKey) ?? Data(), as: UTF8.self)
            XCTAssertFalse(json.contains("paintbrush"), "a nil choice is removed, not stored as null")
        }
    }

    /// The encoded form carries only identities keyed by tool — never a
    /// session ResourceID handle, which is local to the running engine.
    func testEncodingStoresIdentitiesNeverSessionHandles() throws {
        try withDefaults { defaults in
            let store = BrushSelectionStore(defaults: defaults)
            store.set(EngineSession.ResourceIdentity(name: "Round", collection: "Brushes", isInternal: true),
                      for: .paintbrush)
            let data = try XCTUnwrap(defaults.data(forKey: BrushSelectionStore.selectionsKey))
            let json = String(decoding: data, as: UTF8.self)
            XCTAssertTrue(json.contains("\"paintbrush\""))
            XCTAssertTrue(json.contains("\"name\":\"Round\""))
            XCTAssertTrue(json.contains("\"collection\":\"Brushes\""))
            XCTAssertTrue(json.contains("\"isInternal\":true"))
            XCTAssertFalse(json.contains("\"id\""), "no numeric session handle is persisted")
            let decoded = try JSONDecoder().decode([String: EngineSession.ResourceIdentity].self, from: data)
            XCTAssertEqual(decoded["paintbrush"],
                           EngineSession.ResourceIdentity(name: "Round", collection: "Brushes", isInternal: true))
        }
    }

    func testInvalidStoredDataReadsAsEmpty() {
        withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: BrushSelectionStore.selectionsKey)
            XCTAssertNil(BrushSelectionStore(defaults: defaults).identity(for: .paintbrush))
            defaults.set(["paintbrush": 42], forKey: BrushSelectionStore.selectionsKey)
            XCTAssertNil(BrushSelectionStore(defaults: defaults).identity(for: .paintbrush))
        }
    }

    // MARK: Search

    func testSearchFiltersInMemoryCaseInsensitively() {
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: nil)
        model.deliver(generation: model.generation, rows: [
            Self.row(1, "2. Hardness 025"),
            Self.row(2, "2. Block 01"),
            Self.row(3, "1. Pixel"),
        ], thumbnails: [:], resolvedCurrent: nil, error: nil)
        XCTAssertEqual(model.rows(matching: "").count, 3)
        XCTAssertEqual(model.rows(matching: "  ").count, 3)
        XCTAssertEqual(model.rows(matching: "hardness").map(\.name), ["2. Hardness 025"])
        XCTAssertEqual(model.rows(matching: "2.").count, 2)
        XCTAssertEqual(model.rows(matching: "no such brush"), [])
    }

    // MARK: Captured tool, cancel, missing

    @MainActor
    func testTableRowsHaveVisibleNamesAndThumbnails() throws {
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: nil)
        let provider = try XCTUnwrap(CGDataProvider(data: Data([0, 0, 0, 255]) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        model.deliver(generation: model.generation, rows: [Self.row(7, "Stock Brush")],
                      thumbnails: [7: image], resolvedCurrent: nil, error: nil)
        let picker = BrushChooserPanel(document: nil, model: model)
        defer { picker.dismiss() }
        func findTable(_ view: NSView) -> NSTableView? {
            if let table = view as? NSTableView { return table }
            return view.subviews.lazy.compactMap(findTable).first
        }
        let content = try XCTUnwrap(picker.window?.contentView)
        content.layoutSubtreeIfNeeded()
        let table = try XCTUnwrap(findTable(content))
        XCTAssertEqual(table.numberOfRows, 2)
        let defaultCell = try XCTUnwrap(table.view(atColumn: 0, row: 0, makeIfNecessary: true) as? NSTableCellView)
        let brushCell = try XCTUnwrap(table.view(atColumn: 0, row: 1, makeIfNecessary: true) as? NSTableCellView)
        XCTAssertEqual(defaultCell.textField?.stringValue, "Default")
        XCTAssertEqual(brushCell.textField?.stringValue, "Stock Brush")
        XCTAssertNotNil(brushCell.imageView?.image, "the native brush preview must be visible in its row")
    }

    func testStaleGenerationDeliveryChangesNothing() {
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: nil)
        model.invalidate()
        let applied = model.deliver(generation: model.generation - 1, rows: [Self.row(1, "A")],
                                    thumbnails: [:], resolvedCurrent: nil, error: nil)
        XCTAssertFalse(applied)
        XCTAssertTrue(model.rows.isEmpty)
        XCTAssertEqual(model.state, .loading, "a late native result cannot restore a stale view")
    }

    func testDeliverSelectsTheCurrentIdentityOrMarksItMissing() {
        let current = Self.identity("2. Hardness 025")
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: current)
        model.deliver(generation: model.generation, rows: [Self.row(7, "2. Hardness 025")],
                      thumbnails: [:], resolvedCurrent: 7, error: nil)
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.selection, .resource(7))
        XCTAssertNil(model.missingIdentity)
        XCTAssertEqual(model.pendingIdentity(), current)

        let missing = BrushChooserModel(capturedTool: .pencil, currentIdentity: Self.identity("Gone"))
        missing.deliver(generation: missing.generation, rows: [Self.row(1, "Other")],
                        thumbnails: [:], resolvedCurrent: nil, error: nil)
        XCTAssertEqual(missing.missingIdentity, Self.identity("Gone"),
                       "a persisted identity that no longer resolves is shown as missing")
        XCTAssertEqual(missing.selection, .none)
        XCTAssertEqual(missing.pendingIdentity(), Self.identity("Gone"),
                       "missing is never silently replaced by the default")
    }

    func testResolvedCurrentOutsideLoadedRowsStaysValidAndUnchanged() {
        let current = Self.identity("Brush beyond first page")
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: current)
        model.deliver(generation: model.generation, rows: [Self.row(1, "First page")],
                      thumbnails: [:], resolvedCurrent: 513, error: nil)
        XCTAssertNil(model.missingIdentity, "an engine-resolved brush is present even outside the loaded rows")
        XCTAssertEqual(model.pendingIdentity(), current, "an unlisted current choice must never reset to Default")
    }

    func testCachedPreviewAndMissingMarkerNeverDescribeAnotherChoiceOrDefault() throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data([0, 0, 0, 255]) as CFData))
        let image = try XCTUnwrap(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                                        bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let first = Self.identity("First"), second = Self.identity("Second")
        var cache = BrushChoiceCache()
        cache.setPreview(image, identity: first, for: .paintbrush)
        cache.setMissing(first, for: .paintbrush)
        XCTAssertNotNil(cache.preview(for: .paintbrush, choice: first))
        XCTAssertEqual(cache.missingIdentity(for: .paintbrush, choice: first), first)
        for newerChoice in [nil, second] {
            XCTAssertNil(cache.preview(for: .paintbrush, choice: newerChoice))
            XCTAssertNil(cache.missingIdentity(for: .paintbrush, choice: newerChoice))
        }
        cache.reset(.paintbrush)
        XCTAssertNil(cache.preview(for: .paintbrush, choice: first))
        XCTAssertNil(cache.missingIdentity(for: .paintbrush, choice: first))
    }

    func testPendingIdentityCoversDefaultRowAndNoSelection() {
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: Self.identity("A"))
        model.select(.nativeDefault)
        XCTAssertNil(model.pendingIdentity(), "the Default row applies the native default (nil)")
        model.select(.none)
        XCTAssertEqual(model.pendingIdentity(), Self.identity("A"), "no highlight keeps the current choice")
    }

    @MainActor
    func testApplyWritesOnlyTheCapturedToolAndCancelPreservesThePreviousChoice() {
        withDefaults { defaults in
            let state = ToolState(brushStore: BrushSelectionStore(defaults: defaults))
            state.select(.paintbrush)
            let model = BrushChooserModel(capturedTool: state.current, currentIdentity: nil)
            model.deliver(generation: model.generation, rows: [Self.row(11, "Soft"), Self.row(12, "Block")],
                          thumbnails: [:], resolvedCurrent: nil, error: nil)
            model.select(.resource(11))
            // Switching tools while the chooser is open must not retarget.
            state.select(.eraser)
            XCTAssertEqual(model.capturedTool, .paintbrush)
            state.setBrushResource(model.pendingIdentity(), for: model.capturedTool)
            XCTAssertEqual(state.brush(for: .paintbrush).resource, Self.identity("Soft"))
            XCTAssertNil(state.brush(for: .eraser).resource, "the other tool's brush is untouched")

            // Cancel: a second chooser picks another row but applies nothing.
            let cancelled = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: Self.identity("Soft"))
            cancelled.deliver(generation: cancelled.generation, rows: [Self.row(12, "Block")],
                              thumbnails: [:], resolvedCurrent: nil, error: nil)
            cancelled.select(.resource(12))
            XCTAssertEqual(cancelled.pendingIdentity(), Self.identity("Block"), "it would have applied Block")
            XCTAssertEqual(state.brush(for: .paintbrush).resource, Self.identity("Soft"),
                           "cancel preserves the previous selection")

            // Applying then persists the identity, restored by a fresh state.
            state.setBrushResource(cancelled.pendingIdentity(), for: cancelled.capturedTool)
            XCTAssertEqual(state.brush(for: .paintbrush).resource, Self.identity("Block"))
            let restored = ToolState(brushStore: BrushSelectionStore(defaults: defaults))
            XCTAssertEqual(restored.brush(for: .paintbrush).resource, Self.identity("Block"),
                           "the persisted identity restores into settings after a restart")
            XCTAssertNil(restored.brush(for: .eraser).resource)

            // Reset to the native Default persists nil.
            state.setBrushResource(nil, for: .paintbrush)
            XCTAssertNil(state.brush(for: .paintbrush).resource)
            XCTAssertNil(ToolState(brushStore: BrushSelectionStore(defaults: defaults)).brush(for: .paintbrush).resource)
        }
    }

    // MARK: Full catalog (no 512 cap)

    /// A catalog larger than any former page cap is loaded, searched and
    /// selectable in full.
    func testFullCatalogBeyondAnyPageSearchesSelectsAndCounts() {
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: nil)
        let many = (1...600).map { Self.row(UInt64($0), "Brush page \($0)") }
        model.deliver(generation: model.generation, rows: many, thumbnails: [:],
                      resolvedCurrent: nil, error: nil)
        XCTAssertEqual(model.rows.count, 600, "no catalog cap: every engine brush is listed")
        XCTAssertEqual(model.rows(matching: "").count, 600)
        XCTAssertEqual(model.rows(matching: "PAGE 600").map(\.id), [600],
                       "search reaches past any 512-row page")
        XCTAssertEqual(model.rows(matching: "page 5").count, 111)
        model.select(.resource(600))
        XCTAssertEqual(model.pendingIdentity(), Self.identity("Brush page 600"),
                       "a row beyond any former page is a valid selection")
    }

    // MARK: Missing vs other resolution errors

    /// Missing is reported ONLY when native resolution returns NOT_FOUND;
    /// any other error is distinguished and never resets the choice.
    func testMissingOnlyOnNativeNotFoundOtherErrorsDistinguished() {
        let current = Self.identity("Gone")
        let rows = [Self.row(1, "Other")]

        let notFound = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: current)
        notFound.deliver(generation: notFound.generation, rows: rows, thumbnails: [:],
                         resolvedCurrent: nil,
                         resolutionError: EngineSession.EngineError(
                             status: Int32(GLIMS_STATUS_NOT_FOUND.rawValue), message: "no such resource"),
                         error: nil)
        XCTAssertEqual(notFound.missingIdentity, current, "NOT_FOUND is reported as missing")
        XCTAssertNil(notFound.resolutionError)
        XCTAssertEqual(notFound.selection, .none)
        XCTAssertEqual(notFound.pendingIdentity(), current, "missing never resets to Default")

        let failed = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: current)
        failed.deliver(generation: failed.generation, rows: rows, thumbnails: [:],
                       resolvedCurrent: nil,
                       resolutionError: EngineSession.EngineError(
                           status: Int32(GLIMS_STATUS_FAILED.rawValue), message: "engine exploded"),
                       error: nil)
        XCTAssertNil(failed.missingIdentity, "a non-NOT_FOUND failure is not reported as missing")
        XCTAssertEqual(failed.resolutionError, "engine exploded", "other errors are distinguished")
        XCTAssertEqual(failed.selection, .none)
        XCTAssertEqual(failed.pendingIdentity(), current, "other errors never reset the choice either")

        let busy = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: current)
        busy.deliver(generation: busy.generation, rows: rows, thumbnails: [:],
                     resolvedCurrent: nil,
                     resolutionError: EngineSession.EngineError(
                         status: Int32(GLIMS_STATUS_BUSY.rawValue), message: "busy"),
                     error: nil)
        XCTAssertNil(busy.missingIdentity)
        XCTAssertEqual(busy.resolutionError, "busy")
        XCTAssertEqual(busy.pendingIdentity(), current)

        // The legacy call without resolution detail behaves as NOT_FOUND.
        let legacy = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: current)
        legacy.deliver(generation: legacy.generation, rows: rows, thumbnails: [:],
                       resolvedCurrent: nil, error: nil)
        XCTAssertEqual(legacy.missingIdentity, current)
    }

    /// An engine-resolved current identity selects its row when present and
    /// stays valid when outside the loaded rows.
    func testResolvedCurrentSelectsRowWhenPresent() {
        let current = Self.identity("Listed")
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: current)
        model.deliver(generation: model.generation, rows: [Self.row(4, "Listed")], thumbnails: [:],
                      resolvedCurrent: 4, error: nil)
        XCTAssertEqual(model.selection, .resource(4))
        XCTAssertEqual(model.resolvedCurrentID, 4)
        XCTAssertNil(model.missingIdentity)
        XCTAssertNil(model.resolutionError)
        XCTAssertEqual(model.pendingIdentity(), current)
    }

    // MARK: Lazy thumbnail queue

    func testThumbnailQueueDedupesBatchesBoundedlyAndCachesOutcomes() {
        let queue = BrushThumbnailQueue()
        queue.begin(generation: 1)
        XCTAssertEqual(queue.request([1, 2, 2, 3, 1]), 3, "duplicates are requested once")
        XCTAssertEqual(queue.request([1, 2]), 0)
        XCTAssertEqual(queue.pendingCount, 3)

        queue.request(Array(10...80)) // 71 more ids
        let batch = queue.beginBatch()
        XCTAssertEqual(batch.count, BrushThumbnailQueue.batchSize, "one bounded batch")
        XCTAssertEqual(queue.inFlightCount, BrushThumbnailQueue.batchSize)
        XCTAssertEqual(queue.pendingCount, 3 + 71 - BrushThumbnailQueue.batchSize)
        XCTAssertEqual(queue.beginBatch(), [], "no overlapping batch while one is in flight")

        // A refused batch returns to the front of the queue, order kept.
        queue.requeue(batch)
        XCTAssertEqual(queue.inFlightCount, 0)
        XCTAssertEqual(queue.pendingCount, 3 + 71)
        let batch2 = queue.beginBatch()
        XCTAssertEqual(batch2.first, batch.first)

        // One bad thumbnail fails only itself and is cached; the rest render.
        let image = Self.tinyImage()
        let good = Array(batch2.prefix(BrushThumbnailQueue.batchSize - 1))
        let bad = batch2.last!
        var rendered: [EngineSession.ResourceID: CGImage] = [:]
        for id in good { rendered[id] = image }
        XCTAssertTrue(queue.complete(generation: 1, rendered: Array(rendered.keys), failed: [bad: "engine exploded"]))
        XCTAssertEqual(queue.status(of: bad), .failed("engine exploded"))
        XCTAssertEqual(queue.status(of: good[0]), .rendered)
        XCTAssertEqual(queue.request([bad, good[0]]), 0,
                       "failed and rendered attempts are never re-requested")

        // A stale generation changes nothing.
        XCTAssertFalse(queue.complete(generation: 99, rendered: [999], failed: [998: "x"]))
        XCTAssertNil(queue.status(of: 999))
        XCTAssertNil(queue.status(of: 998))

        // Closing invalidates: late results are dropped.
        queue.invalidate()
        XCTAssertFalse(queue.complete(generation: 1, rendered: [5], failed: [:]))
        XCTAssertTrue(queue.isIdle)
        XCTAssertEqual(queue.pendingCount, 0)
    }

    func testThumbnailQueuePriorityJumpsTheQueue() {
        let queue = BrushThumbnailQueue()
        queue.begin(generation: 0)
        queue.request([1, 2, 3])
        XCTAssertEqual(queue.request([9], priority: true), 1)
        XCTAssertEqual(queue.beginBatch(max: 1), [9])
        XCTAssertTrue(queue.complete(generation: 0, rendered: [9], failed: [:]))
        XCTAssertEqual(queue.beginBatch(max: 2), [1, 2])
        XCTAssertTrue(queue.complete(generation: 0, rendered: [1, 2], failed: [:]))
        XCTAssertEqual(queue.beginBatch(max: 8), [3])
        XCTAssertTrue(queue.complete(generation: 0, rendered: [3], failed: [:]))
        XCTAssertEqual(queue.beginBatch(), [])
    }

    /// The model merges lazy batches into its thumbnail cache and drops
    /// stale-generation results after close.
    func testModelDeliverThumbnailsMergesAndDropsStaleGeneration() {
        let model = BrushChooserModel(capturedTool: .paintbrush, currentIdentity: nil)
        model.deliver(generation: model.generation, rows: [Self.row(1, "A"), Self.row(2, "B")],
                      thumbnails: [:], resolvedCurrent: nil, error: nil)
        model.thumbnailQueue.request([1, 2])
        XCTAssertEqual(model.thumbnailQueue.beginBatch(), [1, 2])
        let image = Self.tinyImage()
        XCTAssertTrue(model.deliverThumbnails(generation: model.generation,
                                              rendered: [1: image], failed: [2: "bad"]))
        XCTAssertNotNil(model.thumbnail(1))
        XCTAssertNil(model.thumbnail(2), "a failed thumbnail stays a placeholder")
        XCTAssertEqual(model.thumbnailQueue.status(of: 2), .failed("bad"))

        model.invalidate()
        XCTAssertFalse(model.deliverThumbnails(generation: model.generation - 1,
                                               rendered: [2: image], failed: [:]),
                       "late results after close are dropped")
        XCTAssertNil(model.thumbnail(2))
    }
}
