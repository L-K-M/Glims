import XCTest
import Foundation
@testable import GlimsKit

final class RecorderInkSemanticTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let symbol = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    private let inkUUID = UUID(uuidString: "01234567-89AB-CDEF-0123-456789ABCDEF")!

    private var origin: RecorderFileValue.Origin {
        RecorderFileValue.Origin(imageLabel: "Ink.tif", initialWidth: 41, initialHeight: 29)
    }

    private var targetDescription: RecorderTargetDescription {
        RecorderTargetDescription(name: "Cyan", kind: .channel, ancestors: [],
                                  siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
    }

    private var catalog: RecorderDescriptionCatalog {
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(targetDescription)])
        return catalog
    }

    private var identity: RecorderInkIdentity {
        RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: inkUUID)
    }

    private var inkBinding: RecorderBindingDescription {
        .ink(symbol: symbol, identity: identity)
    }

    private func inkEditFile(operation: RecorderFileCommand.InkEdit.Operation, intensity: Double, opacity: Double) -> RecorderFileCommand.InkEdit {
        .init(operation: operation, intensity: intensity, opacity: opacity)
    }

    private func engineInkEdit(operation: EngineSession.InkEditOperation, intensity: Double, opacity: Double) -> EngineSession.InkEdit {
        EngineSession.InkEdit(operation: operation, intensity: intensity, opacity: opacity)
    }

    private func inkLevelsFile(lowInput: Double = 0.12, highInput: Double = 0.88, gamma: Double = 1.35,
                               lowOutput: Double = 0.9, highOutput: Double = 0.1,
                               clampInput: Bool = true, clampOutput: Bool = true) -> RecorderFileCommand.InkLevels {
        .init(lowInput: lowInput, highInput: highInput, gamma: gamma,
              lowOutput: lowOutput, highOutput: highOutput,
              clampInput: clampInput, clampOutput: clampOutput)
    }

    private func engineInkLevels(lowInput: Double = 0.12, highInput: Double = 0.88, gamma: Double = 1.35,
                                 lowOutput: Double = 0.9, highOutput: Double = 0.1,
                                 clampInput: Bool = true, clampOutput: Bool = true) -> EngineSession.InkLevelsSettings {
        EngineSession.InkLevelsSettings(
            value: .init(lowInput: lowInput, highInput: highInput, gamma: gamma,
                         lowOutput: lowOutput, highOutput: highOutput),
            clampInput: clampInput, clampOutput: clampOutput)
    }

    private func file(command: RecorderFileCommand, binding: RecorderBindingDescription) -> RecorderFileValue {
        RecorderFileValue(recordingID: recordingID, name: "Ink", origin: origin,
                          symbols: [.init(id: symbol, description: targetDescription)],
                          records: [.init(ordinal: 0, outcome: .success(command, binding))])
    }

    private func record(log: inout RecorderLog<SemanticImageCommand>, _ command: SemanticImageCommand) throws {
        let token = try log.reserve()
        try log.resolve(token, with: .success(command))
    }

    // MARK: - Pure conversion

    func testInkEditConversionsPreserveExactLiteralsForAllOperations() throws {
        let cases: [(RecorderFileCommand.InkEdit.Operation, EngineSession.InkEditOperation, Double, Double, String)] = [
            (.fill, .fill, 0.25, 0.75, "Fill Ink Channel"),
            (.clear, .clear, 1.0, 1.0, "Clear Ink Channel"),
            (.invert, .invert, 0.0, 1.0, "Invert Ink Channel"),
        ]
        for (fileOp, engineOp, intensity, opacity, title) in cases {
            let fileCommand = RecorderFileCommand.editInk(inkEditFile(operation: fileOp, intensity: intensity, opacity: opacity))
            let prepared = try RecorderFileSemanticBridge.prepare(file(command: fileCommand, binding: inkBinding))
            XCTAssertEqual(prepared.log.records.count, 1)
            guard case .success(let semantic) = prepared.log.records[0].resolution else {
                return XCTFail("Missing semantic resolution for \(fileOp)")
            }
            guard case .editInk(let settings) = semantic else {
                return XCTFail("Expected editInk for \(fileOp)")
            }
            XCTAssertEqual(settings.operation, engineOp)
            XCTAssertEqual(settings.intensity, intensity)
            XCTAssertEqual(settings.opacity, opacity)
            XCTAssertEqual(semantic.title, title)

            let roundTripped = try RecorderFileCommand(semantic)
            XCTAssertEqual(roundTripped, fileCommand)
        }
    }

    func testInkLevelsConversionPreservesExactSettingsIncludingDormantFieldsAndClamps() throws {
        let fileLevels = inkLevelsFile(lowInput: 0.12, highInput: 0.88, gamma: 1.35,
                                       lowOutput: 0.9, highOutput: 0.1,
                                       clampInput: true, clampOutput: true)
        let fileCommand = RecorderFileCommand.applyInkLevels(fileLevels)
        let prepared = try RecorderFileSemanticBridge.prepare(file(command: fileCommand, binding: inkBinding))
        guard case .success(let semantic) = prepared.log.records[0].resolution else {
            return XCTFail("Missing semantic resolution")
        }
        guard case .applyInkLevels(let settings) = semantic else {
            return XCTFail("Expected applyInkLevels")
        }
        XCTAssertEqual(settings.value.lowInput, 0.12)
        XCTAssertEqual(settings.value.highInput, 0.88)
        XCTAssertEqual(settings.value.gamma, 1.35)
        XCTAssertEqual(settings.value.lowOutput, 0.9)
        XCTAssertEqual(settings.value.highOutput, 0.1)
        XCTAssertTrue(settings.clampInput)
        XCTAssertTrue(settings.clampOutput)
        XCTAssertEqual(semantic.title, "Ink Levels")

        let roundTripped = try RecorderFileCommand(semantic)
        XCTAssertEqual(roundTripped, fileCommand)

        let equalEndpoints = inkLevelsFile(lowInput: 0.4, highInput: 0.4, gamma: 0.1,
                                           lowOutput: 0.7, highOutput: 0.7,
                                           clampInput: false, clampOutput: true)
        let equalCommand = RecorderFileCommand.applyInkLevels(equalEndpoints)
        let preparedEqual = try RecorderFileSemanticBridge.prepare(file(command: equalCommand, binding: inkBinding))
        guard case .success(.applyInkLevels(let equalSettings)) = preparedEqual.log.records[0].resolution else {
            return XCTFail("Missing semantic resolution for equal endpoints")
        }
        XCTAssertEqual(equalSettings.value.lowInput, 0.4)
        XCTAssertEqual(equalSettings.value.highInput, 0.4)
        XCTAssertEqual(equalSettings.value.lowOutput, 0.7)
        XCTAssertEqual(equalSettings.value.highOutput, 0.7)
        XCTAssertEqual(equalSettings.value.gamma, 0.1)
        XCTAssertFalse(equalSettings.clampInput)
        XCTAssertTrue(equalSettings.clampOutput)
        XCTAssertEqual(try RecorderFileCommand(.applyInkLevels(equalSettings)), equalCommand)
    }

    func testInvalidCapturedInkSettingsRejectedAtConversionBoundary() {
        // File -> semantic (bridge)
        let invalidLevels = inkLevelsFile(gamma: 0.01)
        XCTAssertThrowsError(try RecorderFileSemanticBridge.prepare(file(command: .applyInkLevels(invalidLevels), binding: inkBinding)))

        // Semantic -> file (snapshot conversion)
        var badSettings = engineInkLevels()
        badSettings.value.gamma = 0.01
        XCTAssertThrowsError(try RecorderFileCommand(SemanticImageCommand.applyInkLevels(badSettings)))

        // Ink edit canonical/sanity cases: invalid fill intensity and invalid clear shape
        let badFill = engineInkEdit(operation: .fill, intensity: 1.5, opacity: 0.5)
        XCTAssertThrowsError(try RecorderFileCommand(SemanticImageCommand.editInk(badFill)))
        let badClear = engineInkEdit(operation: .clear, intensity: 0.5, opacity: 1.0)
        XCTAssertThrowsError(try RecorderFileCommand(SemanticImageCommand.editInk(badClear)))
        let invalidEdits: [EngineSession.InkEdit] = [
            .init(operation: .fill, intensity: .nan, opacity: 1),
            .init(operation: .fill, intensity: 0.5, opacity: .infinity),
            .init(operation: .clear, intensity: 1, opacity: 0.5),
            .init(operation: .invert, intensity: 1, opacity: 1),
            .init(operation: .invert, intensity: 0, opacity: 0.5)
        ]
        for edit in invalidEdits {
            XCTAssertThrowsError(try RecorderFileCommand(.editInk(edit)))
        }
        badSettings = engineInkLevels()
        badSettings.value.lowOutput = .nan
        XCTAssertThrowsError(try RecorderFileCommand(.applyInkLevels(badSettings)))
    }

    // MARK: - Command flags

    func testInkCommandTitlesResolvePolicyAndLayerFlags() {
        let fill = SemanticImageCommand.editInk(engineInkEdit(operation: .fill, intensity: 0.25, opacity: 0.75))
        let clear = SemanticImageCommand.editInk(engineInkEdit(operation: .clear, intensity: 1.0, opacity: 1.0))
        let invert = SemanticImageCommand.editInk(engineInkEdit(operation: .invert, intensity: 0.0, opacity: 1.0))
        let levels = SemanticImageCommand.applyInkLevels(engineInkLevels())

        XCTAssertEqual(fill.title, "Fill Ink Channel")
        XCTAssertEqual(clear.title, "Clear Ink Channel")
        XCTAssertEqual(invert.title, "Invert Ink Channel")
        XCTAssertEqual(levels.title, "Ink Levels")

        for command in [fill, clear, invert, levels] {
            XCTAssertTrue(command.requiresResolvedFloatingSelection)
            XCTAssertFalse(command.isLayerAdjustment)
        }
    }

    // MARK: - Detached prepare/snapshot, bindings, failures

    func testDetachedPrepareAndSnapshotRetainInkBindingsAndFailures() throws {
        let fill = RecorderFileCommand.editInk(inkEditFile(operation: .fill, intensity: 0.25, opacity: 0.75))
        let clear = RecorderFileCommand.editInk(inkEditFile(operation: .clear, intensity: 1.0, opacity: 1.0))
        let invert = RecorderFileCommand.editInk(inkEditFile(operation: .invert, intensity: 0.0, opacity: 1.0))
        let levels = RecorderFileCommand.applyInkLevels(inkLevelsFile())

        let fileValue = RecorderFileValue(recordingID: recordingID, name: "Ink", origin: origin,
            symbols: [.init(id: symbol, description: targetDescription)],
            records: [
                .init(ordinal: 0, outcome: .success(fill, inkBinding)),
                .init(ordinal: 1, outcome: .failure("boom")),
                .init(ordinal: 2, outcome: .success(clear, inkBinding)),
                .init(ordinal: 3, outcome: .cancelled("stopped")),
                .init(ordinal: 4, outcome: .success(invert, inkBinding)),
                .init(ordinal: 5, outcome: .success(levels, inkBinding)),
            ])

        let prepared = try RecorderFileSemanticBridge.prepare(fileValue)
        XCTAssertEqual(prepared.log.records.count, 6)
        XCTAssertFalse(prepared.log.isRecording)
        XCTAssertFalse(prepared.log.isReplaying)
        XCTAssertEqual(prepared.log.pendingCount, 0)

        guard case .success(.editInk(let fillSettings)) = prepared.log.records[0].resolution else {
            return XCTFail("Missing fill")
        }
        XCTAssertEqual(fillSettings.operation, .fill)
        XCTAssertEqual(fillSettings.intensity, 0.25)
        XCTAssertEqual(fillSettings.opacity, 0.75)

        guard case .failure(let failureReason) = prepared.log.records[1].resolution else {
            return XCTFail("Missing failure row")
        }
        XCTAssertEqual(failureReason, "boom")

        guard case .success(.editInk(let clearSettings)) = prepared.log.records[2].resolution else {
            return XCTFail("Missing clear")
        }
        XCTAssertEqual(clearSettings.operation, .clear)

        guard case .cancelled(let cancelledReason) = prepared.log.records[3].resolution else {
            return XCTFail("Missing cancelled row")
        }
        XCTAssertEqual(cancelledReason, "stopped")

        guard case .success(.editInk(let invertSettings)) = prepared.log.records[4].resolution else {
            return XCTFail("Missing invert")
        }
        XCTAssertEqual(invertSettings.operation, .invert)

        guard case .success(.applyInkLevels(let levelSettings)) = prepared.log.records[5].resolution else {
            return XCTFail("Missing levels")
        }
        XCTAssertEqual(levelSettings.value.lowInput, 0.12)
        XCTAssertTrue(levelSettings.clampOutput)

        XCTAssertEqual(prepared.file, fileValue)
        let snapshot = try RecorderFileCodec.snapshot(prepared.log, recordingID: recordingID, name: "Ink",
                                                      origin: origin, descriptions: catalog,
                                                      bindings: [0: inkBinding, 2: inkBinding, 4: inkBinding, 5: inkBinding])
        XCTAssertEqual(snapshot, fileValue, "Success, failure, cancellation and original ink bindings must all survive")
    }

    func testMultichannelIdentityAndAllClampCombinationsSurviveConversion() throws {
        let binding = RecorderBindingDescription.ink(symbol: symbol,
            identity: .init(mode: .multichannel, role: .unspecified, uuid: inkUUID))
        for clamps in [(false, false), (false, true), (true, false), (true, true)] {
            let value = RecorderFileCommand.applyInkLevels(inkLevelsFile(
                lowInput: 0.8, highInput: 0.2, gamma: 10, lowOutput: 0.1, highOutput: 0.9,
                clampInput: clamps.0, clampOutput: clamps.1))
            let original = file(command: value, binding: binding)
            let prepared = try RecorderFileSemanticBridge.prepare(original)
            guard case .success(.applyInkLevels(let settings)) = prepared.log.records[0].resolution else {
                return XCTFail("Missing scalar Levels command")
            }
            XCTAssertEqual(settings.value.lowInput, 0.8)
            XCTAssertEqual(settings.value.highInput, 0.2)
            XCTAssertEqual(settings.value.gamma, 10)
            XCTAssertEqual(settings.value.lowOutput, 0.1)
            XCTAssertEqual(settings.value.highOutput, 0.9)
            XCTAssertEqual(settings.clampInput, clamps.0)
            XCTAssertEqual(settings.clampOutput, clamps.1)
            XCTAssertEqual(try RecorderFileCommand(.applyInkLevels(settings)), value)
            let snapshot = try RecorderFileCodec.snapshot(prepared.log, recordingID: recordingID, name: "Ink",
                origin: origin, descriptions: catalog, bindings: [0: binding])
            XCTAssertEqual(snapshot, original)
        }
    }

    func testInkSnapshotRefusesMissingOrWrongBinding() throws {
        for command in [
            SemanticImageCommand.editInk(engineInkEdit(operation: .fill, intensity: 0.25, opacity: 0.75)),
            SemanticImageCommand.applyInkLevels(engineInkLevels()),
        ] {
            var log = RecorderLog<SemanticImageCommand>()
            try log.startRecording()
            try record(log: &log, command)
            try log.stopRecording()

            func snapshot(_ bindings: [Int: RecorderBindingDescription]) throws -> RecorderFileValue {
                try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Ink",
                                               origin: origin, descriptions: catalog, bindings: bindings)
            }
            XCTAssertThrowsError(try snapshot([:]))
            XCTAssertThrowsError(try snapshot([0: .none]))
            XCTAssertThrowsError(try snapshot([0: .unavailable("Capture failed")]))
            XCTAssertThrowsError(try snapshot([0: .layer(symbol)]))
            XCTAssertThrowsError(try snapshot([0: .channel(symbol)]))
        }
    }
}
