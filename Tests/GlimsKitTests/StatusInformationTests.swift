import XCTest
@testable import GlimsKit

final class StatusInformationTests: XCTestCase {
    func testDocumentFieldsUseTheSuppliedCachedSnapshot() {
        let snapshot = StatusInformationSnapshot(width: 1_600, height: 900,
            profileLabel: "Display P3", precisionLabel: "16-bit float · Linear")
        XCTAssertEqual(snapshot.title(for: .dimensions), "Dimensions: 1600 × 900 px")
        XCTAssertEqual(snapshot.value(for: .workingProfile), "Display P3")
        XCTAssertEqual(snapshot.value(for: .precision), "16-bit float · Linear")
    }

    func testUnavailableValuesAreExplicitBeforeTheFirstRender() {
        let snapshot = StatusInformationSnapshot()
        XCTAssertEqual(snapshot.value(for: .dimensions), "Unavailable")
        XCTAssertEqual(snapshot.value(for: .workingProfile), "Unavailable")
        XCTAssertEqual(snapshot.value(for: .precision), "Unavailable")
        XCTAssertEqual(snapshot.value(for: .lastTileTime), "Unavailable")
        XCTAssertEqual(snapshot.value(for: .canvasCacheMemory), "0 B")
    }

    func testPixelPayloadCountsRowPaddingAndHeight() {
        // A 64-pixel RGBA row with 16 bytes of padding is 272 bytes,
        // so the count must not substitute width × 4 or image dimensions.
        let payload = CanvasRenderMetrics.pixelPayloadBytes(bytesPerRow: 272, height: 16)
        XCTAssertEqual(payload, 4_352)
        let snapshot = StatusInformationSnapshot(renderMetrics: CanvasRenderMetrics(cachedPixelBytes: payload))
        XCTAssertEqual(snapshot.title(for: .canvasCacheMemory), "Canvas cache: 4.2 KiB")
        XCTAssertTrue(StatusInformationChoice.canvasCacheMemory.help.contains("Excludes engine and process memory"))
    }

    func testCacheUnitsUseBinaryBoundaries() {
        func value(_ bytes: UInt64) -> String {
            StatusInformationSnapshot(renderMetrics: CanvasRenderMetrics(cachedPixelBytes: bytes))
                .value(for: .canvasCacheMemory)
        }
        XCTAssertEqual(value(1_023), "1023 B")
        XCTAssertEqual(value(1_024), "1.0 KiB")
        XCTAssertEqual(value(1_048_576), "1.0 MiB")
        XCTAssertEqual(value(67_108_864), "64.0 MiB")
    }

    func testTileDurationUsesMonotonicNanoseconds() throws {
        let elapsed = try XCTUnwrap(CanvasRenderMetrics.elapsedSeconds(start: 8_000_000_000, end: 8_001_234_000))
        XCTAssertEqual(elapsed, 0.001234, accuracy: 0.000000001)
        let snapshot = StatusInformationSnapshot(renderMetrics:
            CanvasRenderMetrics(cachedPixelBytes: 1_024, lastTileSeconds: elapsed))
        XCTAssertEqual(snapshot.title(for: .lastTileTime), "Last tile: 1.23 ms")
        XCTAssertNil(CanvasRenderMetrics.elapsedSeconds(start: 20, end: 19))
    }

    func testUnknownOrInvalidDurationNeverBecomesAnEstimate() {
        for value in [Double.nan, .infinity, -.infinity, -1] {
            let metrics = CanvasRenderMetrics(lastTileSeconds: value)
            XCTAssertNil(metrics.lastTileSeconds)
            XCTAssertEqual(StatusInformationSnapshot(renderMetrics: metrics).value(for: .lastTileTime), "Unavailable")
        }
        XCTAssertEqual(StatusInformationSnapshot(renderMetrics: CanvasRenderMetrics(lastTileSeconds: 1.25))
            .value(for: .lastTileTime), "1.25 s")
    }

}
