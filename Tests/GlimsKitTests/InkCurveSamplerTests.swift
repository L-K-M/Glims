import XCTest
@testable import GlimsKit

final class InkCurveSamplerTests: XCTestCase {
    typealias Point = EngineSession.CurvePoint

    private let previous = (0..<256).map { Double($0) / 255.0 }

    func testCanonicalIdentityReturnsExactTable() throws {
        let points = [Point(x: 0, y: 0), Point(x: 1, y: 1)]
        let samples = try InkCurveSampler.samples(points: points, previousSamples: previous)
        XCTAssertEqual(samples.count, 256)
        for index in 0..<256 {
            XCTAssertEqual(samples[index], Double(index) / 255.0, "index \(index)")
        }
    }

    func testZeroPointsReturnsExactPreviousTable() throws {
        let samples = try InkCurveSampler.samples(points: [], previousSamples: previous)
        XCTAssertEqual(samples, previous)
    }

    func testSinglePointReturnsConstantTable() throws {
        let samples = try InkCurveSampler.samples(points: [Point(x: 0.3, y: 0.25)], previousSamples: previous)
        XCTAssertEqual(samples, Array(repeating: 0.25, count: 256))
    }

    func testTwoCornerLinearEndpoints() throws {
        let points = [Point(x: 0, y: 0, kind: .corner), Point(x: 1, y: 1, kind: .corner)]
        let samples = try InkCurveSampler.samples(points: points, previousSamples: previous)
        XCTAssertEqual(samples.count, 256)
        for index in 0..<256 {
            XCTAssertEqual(samples[index], Double(index) / 255.0, accuracy: 1e-12, "index \(index)")
        }
        XCTAssertEqual(samples[0], 0.0)
        XCTAssertEqual(samples[255], 1.0)
    }

    func testTwoCornerInversion() throws {
        let points = [Point(x: 0, y: 1, kind: .corner), Point(x: 1, y: 0, kind: .corner)]
        let samples = try InkCurveSampler.samples(points: points, previousSamples: previous)
        XCTAssertEqual(samples.count, 256)
        for index in 0..<256 {
            XCTAssertEqual(samples[index], 1.0 - Double(index) / 255.0, accuracy: 1e-12, "index \(index)")
        }
        XCTAssertEqual(samples[0], 1.0)
        XCTAssertEqual(samples[255], 0.0)
    }

    func testEndpointExtensionFillsOutsideRange() throws {
        let points = [Point(x: 0.25, y: 0.2, kind: .corner), Point(x: 0.75, y: 0.8, kind: .corner)]
        let samples = try InkCurveSampler.samples(points: points, previousSamples: previous)
        let leftBoundary = 64 // round(0.25 * 255)
        let rightBoundary = 191 // round(0.75 * 255)
        for index in 0..<leftBoundary {
            XCTAssertEqual(samples[index], 0.2, accuracy: 1e-12, "index \(index)")
        }
        // Rounded segment length extends one bin past the rounded endpoint.
        for index in 193..<256 {
            XCTAssertEqual(samples[index], 0.8, accuracy: 1e-12, "index \(index)")
        }
        XCTAssertEqual(samples[leftBoundary], 0.2, accuracy: 1e-12)
        XCTAssertEqual(samples[rightBoundary], 0.8, accuracy: 1e-12)
        // 1/5 + (3/5)*(126/255), and the one-bin endpoint overlap.
        XCTAssertEqual(samples[127], 0.4964705882352941, accuracy: 1e-12)
        XCTAssertEqual(samples[192], 0.8023529411764706, accuracy: 1e-12)
    }

    func testDuplicateXCollapsedSegmentAndLaterControlPointWins() throws {
        let points = [
            Point(x: 0.0, y: 0.0, kind: .corner),
            Point(x: 0.5, y: 1.0, kind: .corner),
            Point(x: 0.5, y: 0.0, kind: .corner),
            Point(x: 1.0, y: 1.0, kind: .corner),
        ]
        let samples = try InkCurveSampler.samples(points: points, previousSamples: previous)
        let mid = 128 // round(0.5 * 255)
        XCTAssertEqual(samples[mid], 0.0, accuracy: 1e-12)
        XCTAssertEqual(samples[0], 0.0, accuracy: 1e-12)
        XCTAssertEqual(samples[255], 1.0, accuracy: 1e-12)
        XCTAssertEqual(samples[64], 0.5019607843137255, accuracy: 1e-12) // 128/255
        XCTAssertEqual(samples[191], 0.49411764705882355, accuracy: 1e-12) // 126/255
    }

    func testInvalidPreviousSamplesRejected() {
        XCTAssertThrowsError(try InkCurveSampler.samples(points: [], previousSamples: Array(repeating: 0.0, count: 255))) { error in
            XCTAssertEqual(error as? InkCurveSampler.Error, .invalidPreviousSamples)
        }
        var bad = previous
        bad[10] = .nan
        XCTAssertThrowsError(try InkCurveSampler.samples(points: [], previousSamples: bad)) { error in
            XCTAssertEqual(error as? InkCurveSampler.Error, .invalidPreviousSamples)
        }
        bad[10] = 1.01
        XCTAssertThrowsError(try InkCurveSampler.samples(points: [], previousSamples: bad)) { error in
            XCTAssertEqual(error as? InkCurveSampler.Error, .invalidPreviousSamples)
        }
    }

    func testInvalidPointsRejected() {
        XCTAssertThrowsError(try InkCurveSampler.samples(points: [Point(x: .nan, y: 0)], previousSamples: previous)) { error in
            XCTAssertEqual(error as? InkCurveSampler.Error, .invalidPoint(index: 0))
        }
        XCTAssertThrowsError(try InkCurveSampler.samples(points: [Point(x: 0.2, y: -0.1)], previousSamples: previous)) { error in
            XCTAssertEqual(error as? InkCurveSampler.Error, .invalidPoint(index: 0))
        }
        XCTAssertThrowsError(try InkCurveSampler.samples(points: [Point(x: 1.0, y: 0), Point(x: 0.0, y: 1)], previousSamples: previous)) { error in
            XCTAssertEqual(error as? InkCurveSampler.Error, .nondecreasingX(previousIndex: 0, index: 1))
        }
        let tooMany = (0...256).map { Point(x: Double($0) / 256.0, y: 0) }
        XCTAssertThrowsError(try InkCurveSampler.samples(points: tooMany, previousSamples: previous)) { error in
            XCTAssertEqual(error as? InkCurveSampler.Error, .invalidPointCount(257))
        }
    }
}
