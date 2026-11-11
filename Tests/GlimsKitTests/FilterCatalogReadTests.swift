import Darwin
import CGlimsEngine
import XCTest
@testable import GlimsKit

/// Pure callback tests for the bounded whole-catalog read behind
/// `filterOperations()`: literal growth preserves every row in order,
/// shrinking and empty catalogs are honored, impossible counts are refused
/// before any allocation, a catalog that keeps growing fails explicitly,
/// and a callback's own error propagates unchanged. No engine is started.
final class FilterCatalogReadTests: XCTestCase {

    /// Copies a NUL-terminated C string into a fixed-size C char array
    /// field of a struct, exactly as the adapter would have left it.
    private func fill<T>(_ field: inout T, _ string: String) {
        string.withCString { cString in
            withUnsafeMutableBytes(of: &field) { buffer in
                let count = min(buffer.count, strlen(cString) + 1)
                buffer.copyBytes(from: UnsafeRawBufferPointer(start: cString, count: count))
            }
        }
    }

    private func row(_ name: String, _ title: String, categories: String = "blur",
                     blurb: String = "", support: UInt32 = GLIMS_FILTER_OP_SUPPORTED.rawValue)
        -> GlimsOperationInfo {
        var info = GlimsOperationInfo()
        fill(&info.name, name)
        fill(&info.title, title)
        fill(&info.categories, categories)
        fill(&info.blurb, blurb)
        info.support = support
        return info
    }

    /// A scripted stand-in for the native `filter_operations` callback: one
    /// entry per call, recording the capacities it saw. `write` rows are
    /// copied into the buffer, never past its capacity, as the adapter does.
    private final class Script {
        struct Step {
            let capacity: Int32
            let count: Int32
            let write: [GlimsOperationInfo]
        }

        private let steps: [Step]
        private var index = 0
        private(set) var calls: [Int32] = []

        init(_ steps: [Step]) { self.steps = steps }

        func call(_ rows: UnsafeMutablePointer<GlimsOperationInfo>?,
                  _ capacity: Int32,
                  _ count: inout Int32) throws {
            calls.append(capacity)
            guard index < steps.count else {
                XCTFail("unexpected read call with capacity \(capacity)")
                count = 0
                return
            }
            let step = steps[index]
            index += 1
            XCTAssertEqual(capacity, step.capacity)
            count = step.count
            for (offset, row) in step.write.enumerated() where offset < Int(capacity) {
                rows?[offset] = row
            }
        }
    }

    func testLiteralGrowthPreservesEveryRowInOrder() throws {
        let catalog = [
            row("gegl:alpha", "Alpha", categories: "color", blurb: "first",
                support: GLIMS_FILTER_OP_SUPPORTED.rawValue),
            row("gegl:blur", "Blur", categories: "blur", blurb: "second",
                support: GLIMS_FILTER_OP_AUX_INPUT.rawValue),
            row("gegl:curve", "Curve", categories: "color", blurb: "third",
                support: GLIMS_FILTER_OP_CONFIG.rawValue),
        ]
        let script = Script([
            .init(capacity: 0, count: 2, write: []),
            .init(capacity: 2, count: 3, write: Array(catalog.prefix(2))),
            .init(capacity: 3, count: 3, write: catalog),
        ])
        let read = try EngineSession.readWholeFilterOperationRows { rows, capacity, count in
            try script.call(rows, capacity, &count)
        }
        XCTAssertEqual(script.calls, [0, 2, 3])
        XCTAssertEqual(read.count, 3)
        XCTAssertEqual(read.map { EngineSession.string($0.name) },
                       ["gegl:alpha", "gegl:blur", "gegl:curve"])
        XCTAssertEqual(read.map { EngineSession.string($0.title) }, ["Alpha", "Blur", "Curve"])
        XCTAssertEqual(read.map { EngineSession.string($0.categories) }, ["color", "blur", "color"])
        XCTAssertEqual(read.map { EngineSession.string($0.blurb) }, ["first", "second", "third"])
        XCTAssertEqual(read.map(\.support),
                       [GLIMS_FILTER_OP_SUPPORTED.rawValue, GLIMS_FILTER_OP_AUX_INPUT.rawValue,
                        GLIMS_FILTER_OP_CONFIG.rawValue])
    }

    func testZeroProbeThatGrowsIsRetried() throws {
        let catalog = [row("gegl:blur", "Blur"), row("gegl:curve", "Curve")]
        let script = Script([
            .init(capacity: 0, count: 0, write: []),
            .init(capacity: 0, count: 2, write: []),
            .init(capacity: 2, count: 2, write: catalog),
        ])
        let read = try EngineSession.readWholeFilterOperationRows { rows, capacity, count in
            try script.call(rows, capacity, &count)
        }
        XCTAssertEqual(script.calls, [0, 0, 2])
        XCTAssertEqual(read.map { EngineSession.string($0.name) }, ["gegl:blur", "gegl:curve"])
    }

    func testShrinkingCatalogReturnsOnlyTheReportedRows() throws {
        let script = Script([
            .init(capacity: 0, count: 5, write: []),
            .init(capacity: 5, count: 2, write: [row("gegl:blur", "Blur"), row("gegl:curve", "Curve")]),
        ])
        let read = try EngineSession.readWholeFilterOperationRows { rows, capacity, count in
            try script.call(rows, capacity, &count)
        }
        XCTAssertEqual(script.calls, [0, 5])
        XCTAssertEqual(read.map { EngineSession.string($0.name) }, ["gegl:blur", "gegl:curve"])
    }

    func testEmptyCatalogReturnsNoRows() throws {
        let script = Script([
            .init(capacity: 0, count: 0, write: []),
            .init(capacity: 0, count: 0, write: []),
        ])
        let read = try EngineSession.readWholeFilterOperationRows { rows, capacity, count in
            try script.call(rows, capacity, &count)
        }
        XCTAssertEqual(script.calls, [0, 0])
        XCTAssertTrue(read.isEmpty)
    }

    func testImpossibleProbeCountIsRejectedBeforeAllocation() throws {
        let expected = EngineSession.EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                                                message: "The engine reported an impossible number of filter operations.")
        for impossible in [Int32(-1), Int32(10_001)] {
            let script = Script([.init(capacity: 0, count: impossible, write: [])])
            XCTAssertThrowsError(try EngineSession.readWholeFilterOperationRows { rows, capacity, count in
                try script.call(rows, capacity, &count)
            }) { error in
                XCTAssertEqual(error as? EngineSession.EngineError, expected)
            }
            XCTAssertEqual(script.calls, [0], "an impossible probe count must not reach a fill")
        }
    }

    func testImpossibleFillCountIsRejected() throws {
        let expected = EngineSession.EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                                                message: "The engine reported an impossible number of filter operations.")
        for impossible in [Int32(-1), Int32(10_001)] {
            let script = Script([
                .init(capacity: 0, count: 2, write: []),
                .init(capacity: 2, count: impossible, write: []),
            ])
            XCTAssertThrowsError(try EngineSession.readWholeFilterOperationRows { rows, capacity, count in
                try script.call(rows, capacity, &count)
            }) { error in
                XCTAssertEqual(error as? EngineSession.EngineError, expected)
            }
            XCTAssertEqual(script.calls, [0, 2], "an impossible fill count must not be retried or allocated")
        }
    }

    func testContinuingGrowthFailsExplicitly() throws {
        let script = Script([
            .init(capacity: 0, count: 2, write: []),
            .init(capacity: 2, count: 3, write: [row("op:1", "One"), row("op:2", "Two")]),
            .init(capacity: 3, count: 4, write: [row("op:1", "One"), row("op:2", "Two"), row("op:3", "Three")]),
            .init(capacity: 4, count: 5, write: [row("op:1", "One"), row("op:2", "Two"), row("op:3", "Three"),
                                                  row("op:4", "Four")]),
        ])
        XCTAssertThrowsError(try EngineSession.readWholeFilterOperationRows { rows, capacity, count in
            try script.call(rows, capacity, &count)
        }) { error in
            XCTAssertEqual(error as? EngineSession.EngineError,
                           EngineSession.EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                                                     message: "The filter operation catalog kept changing while it was being read."))
        }
        XCTAssertEqual(script.calls, [0, 2, 3, 4])
    }

    func testNativeErrorPropagatesUnchanged() throws {
        let native = EngineSession.EngineError(status: Int32(GLIMS_STATUS_FAILED.rawValue),
                                               message: "native catalog failure")
        let script = Script([.init(capacity: 0, count: 2, write: [])])
        XCTAssertThrowsError(try EngineSession.readWholeFilterOperationRows { rows, capacity, count in
            guard capacity > 0 else {
                try script.call(rows, capacity, &count)
                return
            }
            throw native
        }) { error in
            XCTAssertEqual(error as? EngineSession.EngineError, native)
        }
        XCTAssertEqual(script.calls, [0])
    }
}
