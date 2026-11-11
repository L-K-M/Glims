import CoreGraphics
import Foundation
import XCTest
@testable import GlimsKit

final class RecorderFileSemanticBridgeTests: XCTestCase {
    private typealias Log = RecorderLog<SemanticImageCommand>
    private let layer = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let options = #"{"operation":"intersect","antialias":false,"feather":-2.5,"cornerRadius":0,"threshold":1.5,"contiguous":false,"sampleMerged":false}"#
    private let symbols = #"""
    {"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Original text","kind":"text","ancestors":[{"name":"Original group","kind":"group","siblingIndex":0}],"siblingIndex":1,"bounds":{"x":-4,"y":7,"width":41,"height":29}}},
    {"id":"33333333-3333-3333-3333-333333333333","description":{"name":"Unused saved alpha","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}
    """#
    private let context = #"{"kind":"context","context":{"layers":["22222222-2222-2222-2222-222222222222"],"channels":[],"target":{"kind":"mask","owner":"22222222-2222-2222-2222-222222222222"},"masks":[{"owner":"22222222-2222-2222-2222-222222222222","isPresent":true,"enabled":true,"editing":true,"showing":false}],"quickMask":{"enabled":false,"inverted":true,"color":{"space":"srgb","red":1,"green":0,"blue":0,"alpha":0.5}}}}"#

    private func wire(_ rows: String, symbols: String = "") -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":1,"recordingID":"11111111-1111-1111-1111-111111111111","name":"Bridge","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":["# + symbols + #"],"records":["# + rows + "]}"
    }
    private func success(_ command: String, ordinal: Int = 0, binding: String = #"{"kind":"none"}"#) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding)}"
    }
    private func decode(_ rows: String, symbols: String = "") throws -> RecorderFileValue {
        try RecorderFileCodec.decode(Data(wire(rows, symbols: symbols).utf8))
    }
    private func prepare(_ rows: String, symbols: String = "") throws -> RecorderFileSemanticBridge.PreparedRecording {
        try RecorderFileSemanticBridge.prepare(decode(rows, symbols: symbols))
    }
    private var allFamilies: String {
        [
            success(#"{"tag":"selectionShape","shape":{"tag":"polygon","points":[{"x":-4,"y":0.5},{"x":8.25,"y":2},{"x":2,"y":10}]},"options":"# + options + "}"),
            success(#"{"tag":"selectColor","point":{"x":-1.5,"y":9.75},"options":"# + options + "}", ordinal: 1, binding: context),
            success(#"{"tag":"selectCommand","command":"fromAlpha","radius":0}"#, ordinal: 2, binding: context),
            success(#"{"tag":"transformImage","transform":"flipVertical"}"#, ordinal: 3),
            success(#"{"tag":"scale","width":35,"height":43}"#, ordinal: 4),
            success(#"{"tag":"resizeCanvas","width":45,"height":49,"offset":{"x":-4.75,"y":2.25},"fill":{"space":"srgb","red":0.2,"green":0.35,"blue":0.6,"alpha":0.8}}"#, ordinal: 5),
            success(#"{"tag":"crop","rect":{"x":9,"y":11,"width":-3,"height":-5}}"#, ordinal: 6),
            success(#"{"tag":"layerProperties","properties":{"name":"","visible":false,"opacity":0,"mode":"multiply"}}"#, ordinal: 7,
                    binding: #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#),
            #"{"ordinal":8,"outcome":"failure","reason":"Native refused\nold state"}"#,
            #"{"ordinal":9,"outcome":"cancelled","reason":""}"#,
        ].joined(separator: ",")
    }

    func testIndependentAllFamilyLiteralPreservesEveryPayloadAndUnsuccessfulRow() throws {
        let input = try decode(allFamilies, symbols: symbols)
        let prepared = try RecorderFileSemanticBridge.prepare(input)
        let log = prepared.log
        XCTAssertEqual(prepared.file, input)
        XCTAssertEqual(log.records.map(\.ordinal), Array(0..<10))
        guard log.records.count == 10 else { return XCTFail("Expected every literal row") }
        guard case .success(.selectionShape(.polygon(let vertices), let shapeOptions)) = log.records[0].resolution,
              case .success(.selectColor(let colorPoint, let colorOptions)) = log.records[1].resolution,
              case .success(.selectCommand(.fromAlpha, let radius)) = log.records[2].resolution,
              case .success(.transformImage(.flipVertical)) = log.records[3].resolution,
              case .success(.scale(let width, let height)) = log.records[4].resolution,
              case .success(.resizeCanvas(let canvasWidth, let canvasHeight, let offset, let fill)) = log.records[5].resolution,
              case .success(.crop(let crop)) = log.records[6].resolution,
              case .success(.layerProperties(let properties)) = log.records[7].resolution,
              case .failure(let failed) = log.records[8].resolution,
              case .cancelled(let cancelled) = log.records[9].resolution else { return XCTFail("The complete literal was not preserved") }
        XCTAssertEqual(vertices, [CGPoint(x: -4, y: 0.5), CGPoint(x: 8.25, y: 2), CGPoint(x: 2, y: 10)])
        let expectedOptions = EngineSession.SelectOptions(operation: .intersect, antialias: false, feather: -2.5,
            cornerRadius: 0, threshold: 1.5, contiguous: false, sampleMerged: false)
        XCTAssertEqual(shapeOptions, expectedOptions); XCTAssertEqual(colorOptions, expectedOptions)
        XCTAssertEqual(colorPoint, CGPoint(x: -1.5, y: 9.75)); XCTAssertEqual(radius, 0)
        XCTAssertEqual([width, height, canvasWidth, canvasHeight], [35, 43, 45, 49])
        XCTAssertEqual(offset, CGPoint(x: -4.75, y: 2.25))
        XCTAssertEqual([fill.red, fill.green, fill.blue, fill.alpha], [0.2, 0.35, 0.6, 0.8])
        XCTAssertEqual([crop.origin.x, crop.origin.y, crop.size.width, crop.size.height], [9, 11, -3, -5])
        XCTAssertEqual([crop.minX, crop.minY, crop.width, crop.height], [6, 6, 3, 5])
        XCTAssertEqual(properties.name, ""); XCTAssertEqual(properties.isVisible, false)
        XCTAssertEqual(properties.opacity, 0); XCTAssertEqual(properties.mode, "multiply")
        XCTAssertEqual(failed, "Native refused\nold state"); XCTAssertEqual(cancelled, "")
        XCTAssertEqual(log.replayRefusal, .unsuccessfulRecording)
        XCTAssertFalse(log.isRecording); XCTAssertFalse(log.isReplaying)
        XCTAssertEqual(log.pendingCount, 0); XCTAssertEqual(log.replayStatus, .idle)
    }

    func testPreparationRetainsBindingsAndUnusedOriginalDescriptionsWithoutResolvingThem() throws {
        let prepared = try prepare(allFamilies, symbols: symbols)
        XCTAssertEqual(prepared.file.symbols.count, 2)
        guard prepared.file.symbols.count == 2, prepared.file.records.count == 10 else { return XCTFail("File metadata was lost") }
        XCTAssertEqual(prepared.file.symbols[0].description.name, "Original text")
        XCTAssertEqual(prepared.file.symbols[0].description.ancestors.first?.name, "Original group")
        XCTAssertEqual(prepared.file.symbols[1].description.name, "Unused saved alpha")
        guard case .success(_, .context(let color)) = prepared.file.records[1].outcome,
              case .success(_, .context(let alpha)) = prepared.file.records[2].outcome,
              case .success(_, .layer(let explicit)) = prepared.file.records[7].outcome else { return XCTFail("Original bindings were lost") }
        XCTAssertEqual(color, alpha)
        XCTAssertEqual(color.target, .mask(owner: layer)); XCTAssertEqual(color.layers, [layer])
        XCTAssertEqual(explicit, layer)
        // Preparation has no native image/session/ID input, and cannot authorize
        // these descriptions as executable bindings in any open document.
    }

    func testAllShapesAndOwnedSelectionOperationsHaveLiteralFrontendValues() throws {
        let operations: [(String, EngineSession.SelectOperation)] = [("replace", .replace), ("add", .add), ("subtract", .subtract), ("intersect", .intersect)]
        let shapes: [(String, EngineSession.SelectShape)] = [
            (#"{"tag":"rectangle","rect":{"x":-1.5,"y":0.5,"width":0,"height":0}}"#, .rectangle(CGRect(x: -1.5, y: 0.5, width: 0, height: 0))),
            (#"{"tag":"ellipse","rect":{"x":9,"y":11,"width":-3,"height":-5}}"#, .ellipse(CGRect(x: 9, y: 11, width: -3, height: -5))),
            (#"{"tag":"polygon","points":[{"x":-4,"y":0},{"x":2,"y":1},{"x":0,"y":3}]}"#, .polygon([CGPoint(x: -4, y: 0), CGPoint(x: 2, y: 1), CGPoint(x: 0, y: 3)])),
        ]
        for (name, operation) in operations {
            let settings = options.replacingOccurrences(of: "\"intersect\"", with: "\"\(name)\"")
            for (literal, expected) in shapes {
                let prepared = try prepare(success("{\"tag\":\"selectionShape\",\"shape\":\(literal),\"options\":\(settings)}"))
                guard let row = prepared.log.records.first, case .success(.selectionShape(let actual, let options)) = row.resolution else { return XCTFail("Missing selection shape") }
                XCTAssertEqual(actual, expected); XCTAssertEqual(options.operation, operation)
            }
        }
    }

    func testAllOwnedSelectionCommandsMapExplicitlyWithoutNumericWireEnums() throws {
        let commands: [(String, Double, EngineSession.SelectCommand)] = [
            ("all", -2.5, .all), ("none", 0, .none), ("invert", 0, .invert), ("feather", 0.1, .feather),
            ("grow", 0.1, .grow), ("shrink", 2.5, .shrink), ("border", 3, .border), ("sharpen", 0, .sharpen), ("fromAlpha", 0, .fromAlpha),
        ]
        for (name, radius, expected) in commands {
            let binding = name == "fromAlpha" ? context : #"{"kind":"none"}"#
            let prepared = try prepare(success("{\"tag\":\"selectCommand\",\"command\":\"\(name)\",\"radius\":\(radius)}", binding: binding), symbols: symbols)
            guard let row = prepared.log.records.first, case .success(.selectCommand(let actual, let actualRadius)) = row.resolution else { return XCTFail("Missing selection command") }
            XCTAssertEqual(actual, expected); XCTAssertEqual(actualRadius, radius)
        }
    }

    func testAllOwnedTransformsMapToTheirNamedFrontendCases() throws {
        let cases: [(String, EngineSession.Transform)] = [("rotate90", .rotate90), ("rotate180", .rotate180), ("rotate270", .rotate270), ("flipHorizontal", .flipHorizontal), ("flipVertical", .flipVertical)]
        for (name, expected) in cases {
            let prepared = try prepare(success("{\"tag\":\"transformImage\",\"transform\":\"\(name)\"}"))
            guard let row = prepared.log.records.first, case .success(.transformImage(let actual)) = row.resolution else { return XCTFail("Missing transform") }
            XCTAssertEqual(actual, expected)
        }
    }

    func testAbsentLayerPropertiesRemainAbsentWhileExplicitZeroValuesRemainExplicit() throws {
        let binding = #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#
        let prepared = try prepare(success(#"{"tag":"layerProperties","properties":{}}"#, binding: binding), symbols: symbols)
        guard let row = prepared.log.records.first, case .success(.layerProperties(let value)) = row.resolution else { return XCTFail("Missing layer change") }
        XCTAssertNil(value.name); XCTAssertNil(value.isVisible); XCTAssertNil(value.opacity); XCTAssertNil(value.mode)
        XCTAssertEqual(value.change, EngineSession.LayerChange())
        // Explicit empty/false/zero were independently asserted in allFamilies.
    }

    func testInvalidTailNeverReplacesAnExistingPreparedCandidateWithAPrefix() throws {
        let original = try decode(success(#"{"tag":"scale","width":35,"height":43}"#))
        var retained = try RecorderFileSemanticBridge.prepare(original)
        let options = RecorderFileCommand.Options(operation: .replace, antialias: true, feather: 0, cornerRadius: 0,
            threshold: 0, contiguous: true, sampleMerged: true)
        let invalid: [RecorderFileValue.Record] = [
            .init(ordinal: 1, outcome: .success(.scale(width: 0, height: 1), .none)),
            .init(ordinal: 2, outcome: .failure("ordinal gap")),
            .init(ordinal: 1, outcome: .success(.layerProperties(.init(name: "changed", visible: nil, opacity: nil, mode: nil)), .layer(layer))),
            .init(ordinal: 1, outcome: .success(.selectColor(.init(x: .nan, y: 0), options), .none)),
            .init(ordinal: 1, outcome: .cancelled(String(repeating: "x", count: RecorderFileLimits.stringBytes + 1))),
        ]
        for tail in invalid {
            let input = RecorderFileValue(recordingID: original.recordingID, name: original.name, origin: original.origin,
                symbols: [], records: original.records + [tail])
            XCTAssertThrowsError(retained = try RecorderFileSemanticBridge.prepare(input)) { XCTAssertTrue($0 is RecorderFileError) }
            XCTAssertEqual(retained.file, original)
            XCTAssertEqual(retained.log.records.count, 1)
            guard let row = retained.log.records.first, case .success(.scale(width: 35, height: 43)) = row.resolution else { return XCTFail("A failed prepare changed the old candidate") }
        }
    }

    func testSuccessfulPreparedLogUsesExistingReplayOrderWithoutRecording() throws {
        let rows = success(#"{"tag":"scale","width":35,"height":43}"#) + "," + success(#"{"tag":"transformImage","transform":"rotate270"}"#, ordinal: 1)
        var log = try prepare(rows).log
        try log.beginReplay()
        let first = try log.nextReplayStep()
        XCTAssertEqual(first.index, 0)
        guard case .scale(width: 35, height: 43) = first.command else { return XCTFail("First step changed") }
        XCTAssertThrowsError(try log.reserve()) { XCTAssertEqual($0 as? Log.Refusal, .replaying) }
        try log.acknowledgeReplay(first.token, outcome: .success)
        let second = try log.nextReplayStep()
        XCTAssertEqual(second.index, 1)
        guard case .transformImage(.rotate270) = second.command else { return XCTFail("Second step changed") }
        try log.acknowledgeReplay(second.token, outcome: .success)
        XCTAssertEqual(log.replayStatus, .finished(total: 2))
        XCTAssertEqual(log.records.count, 2); XCTAssertFalse(log.isRecording); XCTAssertEqual(log.pendingCount, 0)
    }

    func testNamedEmptyCandidateIsIdleAndCannotReplay() throws {
        let prepared = try prepare("")
        XCTAssertEqual(prepared.file.name, "Bridge")
        XCTAssertTrue(prepared.log.records.isEmpty)
        XCTAssertFalse(prepared.log.isRecording); XCTAssertFalse(prepared.log.isReplaying)
        XCTAssertEqual(prepared.log.pendingCount, 0); XCTAssertEqual(prepared.log.replayStatus, .idle)
        XCTAssertEqual(prepared.log.replayRefusal, .emptyRecording)
    }

    func testGenericSettledConstructorRetainsFailuresCancellationAndValueOwnership() throws {
        typealias Generic = RecorderLog<String>
        var rows: [Generic.Record] = [.init(ordinal: 0, resolution: .success("one")),
            .init(ordinal: 1, resolution: .failure("failed exactly")), .init(ordinal: 2, resolution: .cancelled(""))]
        var log = try Generic(settledRecords: rows)
        rows[0] = .init(ordinal: 0, resolution: .success("different"))
        guard log.records.count == 3 else { return XCTFail("A settled row was lost") }
        guard case .success("one") = log.records[0].resolution,
              case .failure("failed exactly") = log.records[1].resolution,
              case .cancelled("") = log.records[2].resolution else { return XCTFail("Settled records were lost or aliased") }
        XCTAssertFalse(log.isRecording); XCTAssertFalse(log.isReplaying)
        XCTAssertEqual(log.pendingCount, 0); XCTAssertEqual(log.replayStatus, .idle)
        XCTAssertThrowsError(try log.beginReplay()) { XCTAssertEqual($0 as? Generic.Refusal, .unsuccessfulRecording) }
        XCTAssertThrowsError(try log.reserve()) { XCTAssertEqual($0 as? Generic.Refusal, .notRecording) }
    }

    func testMalformedGenericOrdinalsDoNotReplaceOrInvalidateExistingReplay() throws {
        typealias Generic = RecorderLog<String>
        var log = try Generic(settledRecords: [.init(ordinal: 0, resolution: .success("kept"))])
        try log.beginReplay()
        let step = try log.nextReplayStep()
        let invalid: [[Generic.Record]] = [
            [.init(ordinal: -1, resolution: .success("negative"))],
            [.init(ordinal: 1, resolution: .success("missing zero"))],
            [.init(ordinal: 0, resolution: .success("one")), .init(ordinal: 0, resolution: .success("duplicate"))],
            [.init(ordinal: 0, resolution: .success("one")), .init(ordinal: 2, resolution: .failure("gap"))],
        ]
        for rows in invalid {
            XCTAssertThrowsError(log = try Generic(settledRecords: rows)) {
                XCTAssertEqual($0 as? Generic.SettledRecordsError, .noncontiguousOrdinals)
            }
            XCTAssertEqual(log.replayStatus, .running(index: 0, total: 1))
            guard let row = log.records.first, case .success("kept") = row.resolution else { return XCTFail("Invalid construction changed the existing log") }
        }
        try log.acknowledgeReplay(step.token, outcome: .success)
        XCTAssertEqual(log.replayStatus, .finished(total: 1))
    }

    func testFreshConstructionFencesOldReservationsAndReplayAcknowledgments() throws {
        typealias Generic = RecorderLog<String>
        var old = Generic()
        try old.startRecording()
        let reservation = try old.reserve()
        var fresh = try Generic(settledRecords: [.init(ordinal: 0, resolution: .success("new"))])
        XCTAssertThrowsError(try fresh.resolve(reservation, with: .success("late old"))) {
            XCTAssertEqual($0 as? Generic.Refusal, .staleReservation)
        }
        try old.resolve(reservation, with: .success("old"))
        try old.stopRecording(); try old.beginReplay()
        let oldStep = try old.nextReplayStep()
        try fresh.beginReplay()
        let newStep = try fresh.nextReplayStep()
        XCTAssertThrowsError(try fresh.acknowledgeReplay(oldStep.token, outcome: .success)) {
            XCTAssertEqual($0 as? Generic.Refusal, .staleReplayStep)
        }
        XCTAssertEqual(fresh.replayStatus, .running(index: 0, total: 1))
        try fresh.acknowledgeReplay(newStep.token, outcome: .success)
        XCTAssertEqual(fresh.replayStatus, .finished(total: 1))
        guard let row = fresh.records.first, case .success("new") = row.resolution else { return XCTFail("Old callbacks entered the new log") }
    }
}
