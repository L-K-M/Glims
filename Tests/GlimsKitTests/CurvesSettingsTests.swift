import XCTest
@testable import GlimsKit

final class CurvesSettingsTests: XCTestCase {
    typealias Settings = EngineSession.CurvesSettings
    typealias Point = EngineSession.CurvePoint
    typealias Edit = EngineSession.CurveEdit

    func testDefaultChannelsHaveOrderedIdentityTablesAndPerceptualTRC() {
        let settings = Settings()
        XCTAssertEqual(settings.trc, .perceptual)
        XCTAssertTrue(settings.isValid)
        for channel in EngineSession.CurveChannel.allCases {
            XCTAssertEqual(settings[channel].points, [Point(x: 0, y: 0), Point(x: 1, y: 1)])
            XCTAssertEqual(settings[channel].samples.count, 256)
            XCTAssertEqual(settings[channel].samples[127], 127.0 / 255)
        }
    }
    func testSmoothAcceptsZeroSingleAndDuplicateXPointsWithoutSorting() {
        for points in [[], [Point(x: 0.5, y: 1)],
                       [Point(x: 0.5, y: 1, kind: .corner), Point(x: 0.5, y: 0)]] {
            XCTAssertTrue(Edit.smooth(channel: .alpha, points: points).isValid)
        }
        XCTAssertFalse(Edit.smooth(channel: .red, points: [.init(x: 1, y: 0), .init(x: 0, y: 1)]).isValid)
    }
    func testPointDomainsRejectNonfiniteAndOutOfRangeInput() {
        for number in [Double.nan, .infinity, -.infinity, -0.01, 1.01] {
            XCTAssertFalse(Edit.smooth(channel: .value, points: [Point(x: number, y: 0.5)]).isValid)
            XCTAssertFalse(Edit.smooth(channel: .value, points: [Point(x: 0.5, y: number)]).isValid)
        }
    }
    func testFreeRequiresCompleteFiniteTable() {
        var samples = Array(repeating: 0.5, count: 256)
        XCTAssertTrue(Edit.free(channel: .blue, samples: samples).isValid)
        XCTAssertFalse(Edit.free(channel: .blue, samples: Array(samples.dropLast())).isValid)
        for invalid in [Double.nan, .infinity, -0.01, 1.01] {
            samples[128] = invalid
            XCTAssertFalse(Edit.free(channel: .blue, samples: samples).isValid)
        }
    }
    func testDraftKeepsIndependentChannelsWhileNativeReplyArrives() {
        var store = CurvesDraft(Settings())
        let red = [Point(x: 0, y: 1), Point(x: 1, y: 0)]
        let blue = [Point(x: 0.2, y: 0.3, kind: .corner)]
        let first = store.submit(.curve(.smooth(channel: .red, points: red)))
        let second = store.submit(.curve(.smooth(channel: .blue, points: blue)))
        var native = Settings(); native.red.points = red; native.red.samples = Array(repeating: 0.3, count: 256)
        store.receive(first, result: .success(native))
        XCTAssertEqual(store.settings.blue.points, blue)
        XCTAssertEqual(store.settings.red.samples, native.red.samples)
        store.receive(second, result: .failure(TestFailure()))
        XCTAssertEqual(store.settings.blue, Settings().blue)
        XCTAssertEqual(store.settings.red, native.red)
    }
    func testNewerNativeSnapshotCannotBeOverwrittenByOlderReplyOrPatch() {
        var store = CurvesDraft(Settings())
        let first = store.submit(.trc(.linear))
        let second = store.submit(.trc(.nonlinear))
        var native = Settings(); native.trc = .nonlinear
        store.receive(second, result: .success(native))
        XCTAssertEqual(store.settings.trc, .nonlinear)
        var older = Settings(); older.trc = .linear
        store.receive(first, result: .success(older))
        XCTAssertEqual(store.settings.trc, .nonlinear)
    }
    func testRejectedPatchDoesNotDiscardASeparateQueuedTransferChoice() {
        var store = CurvesDraft(Settings())
        let first = store.submit(.curve(.reset(channel: .green)))
        let second = store.submit(.trc(.linear))
        store.receive(first, result: .failure(TestFailure()))
        XCTAssertEqual(store.settings.trc, .linear)
        XCTAssertEqual(store.settings.green, Settings().green)
        var native = Settings(); native.trc = .linear
        store.receive(second, result: .success(native))
        XCTAssertEqual(store.settings, native)
    }
    @MainActor
    func testDedicatedCurvesEditorRequiresExactOperationAndConfigSupport() {
        func operation(_ name: String, _ support: EngineSession.FilterOpSupport) -> EngineSession.FilterOperation {
            .init(name: name, title: "Curves", categories: [], blurb: "", support: support)
        }
        let exact = operation("gimp:curves", .needsConfig)
        XCTAssertTrue(NativeFilterMenuLayout.usesCurvesEditor(exact))
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(exact))
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(exact), "Curves…")
        for name in ["gegl:curves", "GIMP:CURVES", "gimp:curves-legacy"] {
            XCTAssertFalse(NativeFilterMenuLayout.usesCurvesEditor(operation(name, .needsConfig)))
            XCTAssertFalse(NativeFilterMenuLayout.supportsParameterEditor(operation(name, .needsConfig)))
        }
        XCTAssertFalse(NativeFilterMenuLayout.usesCurvesEditor(operation("gimp:curves", .supported)))
        XCTAssertFalse(NativeFilterMenuLayout.supportsParameterEditor(operation("gimp:curves", .needsAuxInput)))
    }
    private struct TestFailure: Error {}
}
