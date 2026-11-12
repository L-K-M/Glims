import XCTest
@testable import GlimsKit

final class InkCurveSamplerNativeOracleTests: XCTestCase {
    private struct Fixture: Decodable {
        let source: String
        let previousSamples: [Double]
        let cases: [Case]
        struct Case: Decodable {
            let name: String
            let points: [Point]
            let samples: [Double]
        }
        struct Point: Decodable {
            let x: Double
            let y: Double
            let kind: UInt32
        }
    }

    func testEverySampleMatchesIndependentNativeCurves() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf:
            repo.appendingPathComponent("Engine/tests/fixtures/ink-curve-sampler.json")))
        XCTAssertTrue(fixture.source.contains("7addd2b77efb798bbdc4d2fb082e786a48478ced"))
        XCTAssertEqual(fixture.cases.count, 21)
        XCTAssertEqual(Set(fixture.cases.map(\.name)).count, 21)
        for item in fixture.cases {
            let points = try item.points.map { point -> EngineSession.CurvePoint in
                let kind = try XCTUnwrap(EngineSession.CurvePointKind(rawValue: point.kind))
                return .init(x: point.x, y: point.y, kind: kind)
            }
            let actual = try InkCurveSampler.samples(points: points, previousSamples: fixture.previousSamples)
            XCTAssertEqual(actual.count, 256, item.name)
            XCTAssertEqual(item.samples.count, 256, item.name)
            for (index, pair) in zip(actual, item.samples).enumerated() {
                XCTAssertEqual(pair.0, pair.1, accuracy: 2e-14, "\(item.name) sample \(index)")
            }
        }
    }
}
