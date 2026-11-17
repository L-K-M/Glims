import AppKit
import XCTest
@testable import GlimsKit

final class HistogramSheetTests: XCTestCase {
    func testStatisticsFollowGimpFormulasOnPhotoshopLevels() {
        // 10 pixels at level 0 and 10 at level 255 of 256 bins.
        var bins = [Double](repeating: 0, count: 256)
        bins[0] = 10
        bins[255] = 10
        let statistics = HistogramStatistics(bins: bins)
        XCTAssertEqual(statistics.pixels, 20)
        XCTAssertEqual(statistics.mean, 127.5, accuracy: 1e-9)
        XCTAssertEqual(statistics.standardDeviation, 127.5, accuracy: 1e-9)
        // GIMP's median is the first bin where the running total passes half.
        XCTAssertEqual(statistics.median, 255)

        bins[0] = 11
        XCTAssertEqual(HistogramStatistics(bins: bins).median, 0)
    }

    func testHighBitBinsMapToPhotoshopLevels() {
        var bins = [Double](repeating: 0, count: 1024)
        bins[1023] = 4
        let statistics = HistogramStatistics(bins: bins)
        XCTAssertEqual(statistics.mean, 255, accuracy: 1e-9)
        XCTAssertEqual(statistics.standardDeviation, 0, accuracy: 1e-9)
        XCTAssertEqual(HistogramStatistics.level(ofBin: 0, binCount: 1024), 0)
        XCTAssertEqual(HistogramStatistics.level(ofBin: 1023, binCount: 1024), 255, accuracy: 1e-9)
        XCTAssertEqual(HistogramStatistics.formatLevel(127.5, binCount: 1024), "127.5")
        XCTAssertEqual(HistogramStatistics.formatLevel(127.6, binCount: 256), "128")
    }

    func testEmptyHistogramHasNoMedian() {
        let statistics = HistogramStatistics(bins: [Double](repeating: 0, count: 256))
        XCTAssertEqual(statistics.pixels, 0)
        XCTAssertEqual(statistics.mean, 0)
        XCTAssertEqual(statistics.standardDeviation, 0)
        XCTAssertNil(statistics.median)
        XCTAssertNil(HistogramStatistics(bins: []).median)
    }

    func testProbeReportsCountAndCumulativePercentile() throws {
        var bins = [Double](repeating: 0, count: 256)
        bins[10] = 1
        bins[20] = 3
        let probe = try XCTUnwrap(HistogramStatistics.probe(bins, bin: 10))
        XCTAssertEqual(probe.level, 10)
        XCTAssertEqual(probe.count, 1)
        XCTAssertEqual(probe.percentile, 25, accuracy: 1e-9)
        XCTAssertEqual(HistogramStatistics.probe(bins, bin: 255)?.percentile ?? 0, 100, accuracy: 1e-9)
        XCTAssertNil(HistogramStatistics.probe(bins, bin: 256))
        XCTAssertNil(HistogramStatistics.probe(bins, bin: -1))
        XCTAssertEqual(HistogramStatistics.probe([0, 0], bin: 1)?.percentile, 0)
    }

    func testPointerMapsToTheDrawnBin() {
        XCTAssertEqual(HistogramStatistics.bin(atX: 12, minX: 12, width: 255, binCount: 256), 0)
        XCTAssertEqual(HistogramStatistics.bin(atX: 267, minX: 12, width: 255, binCount: 256), 255)
        XCTAssertEqual(HistogramStatistics.bin(atX: 12 + 127.4, minX: 12, width: 255, binCount: 256), 127)
        XCTAssertNil(HistogramStatistics.bin(atX: 11, minX: 12, width: 255, binCount: 256))
        XCTAssertNil(HistogramStatistics.bin(atX: 268, minX: 12, width: 255, binCount: 256))
        XCTAssertNil(HistogramStatistics.bin(atX: 20, minX: 12, width: 255, binCount: 0))
        XCTAssertNil(HistogramStatistics.bin(atX: .nan, minX: 12, width: 255, binCount: 256))
    }

    func testCountFormatting() {
        XCTAssertEqual(HistogramStatistics.formatCount(0.5), "0.5")
        XCTAssertEqual(HistogramStatistics.formatCount(.infinity), "—")
        XCTAssertEqual(HistogramStatistics.formatCount(800),
                       NumberFormatter.localizedString(from: 800, number: .decimal))
    }

    @MainActor
    func testSheetDefaultsToLuminanceAndListsOnlyPresentChannels() {
        _ = NSApplication.shared
        var bins = [Double](repeating: 0, count: 256)
        bins[100] = 4
        let rgb = EngineSession.InputHistogram(trc: .nonlinear, binCount: 256, channels: [
            .value: bins, .red: bins, .green: bins, .blue: bins, .luminance: bins,
        ])
        XCTAssertEqual(HistogramSheet.channels(of: rgb), [.luminance, .red, .green, .blue, .value])
        let controller = HistogramSheetController(histogram: rgb, subject: "Layer")
        XCTAssertEqual(controller.selectedChannel, .luminance)
        XCTAssertEqual(controller.readout("mean"), "100.00")
        XCTAssertEqual(controller.readout("median"), "100")
        XCTAssertEqual(controller.readout("level"), "—")
        controller.showProbe(100)
        XCTAssertEqual(controller.readout("level"), "100")
        XCTAssertEqual(controller.readout("percentile"), "100.0")
        controller.showProbe(nil)
        XCTAssertEqual(controller.readout("count"), "—")

        let gray = EngineSession.InputHistogram(trc: .nonlinear, binCount: 256, channels: [.value: bins, .alpha: bins])
        XCTAssertEqual(HistogramSheet.channels(of: gray), [.value, .alpha])
        XCTAssertEqual(HistogramSheetController(histogram: gray, subject: "").selectedChannel, .value)
    }

    @MainActor
    func testHistogramItemFollowsImageInformation() throws {
        _ = NSApplication.shared
        let image = try XCTUnwrap(MainMenu.make().item(withTitle: "Image")?.submenu)
        let titles = image.items.map(\.title)
        let information = try XCTUnwrap(titles.firstIndex(of: "Image Information…"))
        XCTAssertEqual(titles[information + 1], "Histogram…")
        let item = try XCTUnwrap(image.item(withTitle: "Histogram…"))
        XCTAssertEqual(item.action, #selector(DocumentWindowController.showHistogram(_:)))
        XCTAssertEqual(item.keyEquivalent, "")
    }
}
