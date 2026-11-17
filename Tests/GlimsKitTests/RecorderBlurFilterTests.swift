import XCTest
@testable import GlimsKit

/// Strict recording-format version 26 coverage: a newly applied Gaussian
/// Blur or Unsharp Mask on an explicitly bound layer. Every fixture spells
/// out its own JSON; nothing reuses the production encoder.
final class RecorderBlurFilterTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbol = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
    private let origin = RecorderFileValue.Origin(imageLabel: "A", initialWidth: 41, initialHeight: 29)
    private let layerSymbol = #"{"id":"66666666-6666-6666-6666-666666666666","description":{"name":"Blur target","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let channelSymbol = #"{"id":"66666666-6666-6666-6666-666666666666","description":{"name":"Saved alpha","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}"#
    private let layerBinding = #"{"kind":"layer","symbol":"66666666-6666-6666-6666-666666666666"}"#
    private let maskBinding = #"{"kind":"context","context":{"layers":["66666666-6666-6666-6666-666666666666"],"channels":[],"target":{"kind":"mask","owner":"66666666-6666-6666-6666-666666666666"},"masks":[{"owner":"66666666-6666-6666-6666-666666666666","isPresent":true,"enabled":true,"editing":true,"showing":false}],"quickMask":{"enabled":false,"inverted":false,"color":{"space":"srgb","red":1,"green":0,"blue":0,"alpha":0.5}}}}"#

    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func replace(_ text: String, _ before: String, _ after: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let range = text.range(of: before) else { XCTFail("Fixture mutation did not match: \(before)", file: file, line: line); return text }
        return text.replacingCharacters(in: range, with: after)
    }
    private func rejects(_ text: String, reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(text)), file: file, line: line) {
            XCTAssertTrue($0.localizedDescription.contains(reason), $0.localizedDescription, file: file, line: line)
        }
    }

    private let gaussian = #"{"tag":"applyGaussianBlur","settings":{"deviationX":4.5,"deviationY":2.25,"kernel":"iir","abyss":"black","clipsToInput":false}}"#
    private let unsharp = #"{"tag":"applyUnsharpMask","settings":{"radius":3.5,"amount":1.25,"threshold":0.125}}"#

    private func document(_ rows: String, symbols: String? = nil, version: Int = 26) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Blur","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":["#
            + (symbols ?? layerSymbol) + #"],"records":["# + rows + "]}"
    }
    private func success(_ command: String, binding: String? = nil, ordinal: Int = 0) -> String {
        "{\"ordinal\":\(ordinal),\"outcome\":\"success\",\"command\":\(command),\"binding\":\(binding ?? layerBinding)}"
    }

    private var gaussianFile: RecorderGaussianBlurValue {
        .init(deviationX: 4.5, deviationY: 2.25, kernel: .iir, abyss: .black, clipsToInput: false)
    }
    private var gaussianEngine: EngineSession.GaussianBlurSettings {
        .init(deviationX: 4.5, deviationY: 2.25, kernel: .iir, abyss: .black, clipsToInput: false)
    }
    private var unsharpFile: RecorderUnsharpMaskValue { .init(radius: 3.5, amount: 1.25, threshold: 0.125) }
    private var unsharpEngine: EngineSession.UnsharpMaskSettings { .init(radius: 3.5, amount: 1.25, threshold: 0.125) }

    func testVersion26LiteralsDecodeAndRoundTrip() throws {
        let value = try RecorderFileCodec.decode(bytes(document(success(gaussian) + "," + success(unsharp, ordinal: 1))))
        guard case .success(.applyGaussianBlur(let blur), .layer(let first)) = value.records[0].outcome,
              case .success(.applyUnsharpMask(let sharpen), .layer(let second)) = value.records[1].outcome else {
            return XCTFail("A filter command or its layer binding was lost")
        }
        XCTAssertEqual(blur, gaussianFile)
        XCTAssertEqual(sharpen, unsharpFile)
        XCTAssertEqual([first, second], [symbol, symbol])
        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":26"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
    }

    func testEveryChoiceAndBoundaryRoundTrips() throws {
        for kernel in RecorderGaussianBlurValue.Kernel.allCases {
            for abyss in RecorderGaussianBlurValue.Abyss.allCases {
                for size in [0.0, 1500.0] {
                    let command = #"{"tag":"applyGaussianBlur","settings":{"deviationX":"# + "\(size)"
                        + #","deviationY":0,"kernel":""# + kernel.rawValue + #"","abyss":""# + abyss.rawValue
                        + #"","clipsToInput":true}}"#
                    let value = try RecorderFileCodec.decode(bytes(document(success(command))))
                    XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(value)), value)
                }
            }
        }
        for (radius, amount, threshold) in [(0.0, 0.0, 0.0), (1500.0, 300.0, 1.0)] {
            let command = #"{"tag":"applyUnsharpMask","settings":{"radius":"# + "\(radius),\"amount\":\(amount),\"threshold\":\(threshold)}}"
            let value = try RecorderFileCodec.decode(bytes(document(success(command))))
            XCTAssertEqual(try RecorderFileCodec.decode(RecorderFileCodec.encode(value)), value)
        }
    }

    func testUnknownMissingWrongOrOutOfRangeFieldsReject() {
        let gaussianMutations = [
            (#""tag":"applyGaussianBlur""#, #""tag":"applyGaussianBlur","future":0"#),
            (#""deviationX":4.5"#, #""deviationX":4.5,"future":0"#),
            (#""deviationX":4.5"#, #""deviationX":"4.5""#),
            (#""deviationX":4.5"#, #""deviationX":1500.5"#),
            (#""deviationY":2.25"#, #""deviationY":-0.5"#),
            (#""deviationY":2.25"#, #""deviationY":1e309"#),
            (#""kernel":"iir""#, #""kernel":"box""#),
            (#""abyss":"black""#, #""abyss":"loop""#),
            (#""clipsToInput":false"#, #""clipsToInput":0"#),
            (#","clipsToInput":false"#, ""),
        ]
        for (old, new) in gaussianMutations {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(document(success(gaussian)), old, new))), old)
        }
        let unsharpMutations = [
            (#""radius":3.5"#, #""radius":1501"#),
            (#""amount":1.25"#, #""amount":300.5"#),
            (#""threshold":0.125"#, #""threshold":1.5"#),
            (#""threshold":0.125"#, #""threshold":-0.125"#),
            (#""radius":3.5"#, #""radius":3.5,"radius":4"#),
            (#","threshold":0.125"#, ""),
        ]
        for (old, new) in unsharpMutations {
            XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(replace(document(success(unsharp)), old, new))), old)
        }
    }

    func testVersion26AnchorAndEarlierVersionRejection() {
        rejects(document(success(gaussian), version: 25), reason: "version 26")
        rejects(document(success(unsharp), version: 10), reason: "version 26")
        rejects(document(success(#"{"tag":"scale","width":1,"height":1}"#, binding: #"{"kind":"none"}"#), version: 26),
                reason: "Version 26 requires a successful Gaussian Blur or Unsharp Mask command")
        rejects(document(success(gaussian), version: RecorderFileCodec.scaleInterpolationVersion + 1), reason: "Invalid integer")
    }

    func testExplicitLayerBindingIsMandatoryAndMasksAreRefused() {
        rejects(document(success(gaussian, binding: #"{"kind":"none"}"#)), reason: "binding kinds disagree")
        rejects(document(success(unsharp, binding: #"{"kind":"channel","symbol":"66666666-6666-6666-6666-666666666666"}"#),
                         symbols: channelSymbol), reason: "binding kinds disagree")
        rejects(document(success(gaussian), symbols: channelSymbol), reason: "layer description")
        rejects(document(success(gaussian, binding: maskBinding)), reason: "binding kinds disagree")
        rejects(document(success(unsharp, binding: maskBinding)), reason: "binding kinds disagree")
    }

    func testEncodingRejectsInvalidCallerBuiltValues() {
        let description = RecorderTargetDescription(name: "Target", kind: .pixel, ancestors: [],
            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
        func value(_ command: RecorderFileCommand, binding: RecorderBindingDescription? = nil) -> RecorderFileValue {
            .init(recordingID: recordingID, name: "Blur", origin: origin,
                  symbols: [.init(id: symbol, description: description)],
                  records: [.init(ordinal: 0, outcome: .success(command, binding ?? .layer(symbol)))])
        }
        XCTAssertNoThrow(try RecorderFileCodec.encode(value(.applyGaussianBlur(gaussianFile))))
        XCTAssertNoThrow(try RecorderFileCodec.encode(value(.applyUnsharpMask(unsharpFile))))
        XCTAssertThrowsError(try RecorderFileCodec.encode(value(.applyGaussianBlur(gaussianFile), binding: RecorderBindingDescription.none)))
        for invalid in [Double.nan, .infinity, -.infinity, -0.01, 1500.01] {
            let blur = RecorderGaussianBlurValue(deviationX: invalid, deviationY: 1, kernel: .auto, abyss: .clamp, clipsToInput: true)
            XCTAssertThrowsError(try RecorderFileCodec.encode(value(.applyGaussianBlur(blur))))
            XCTAssertThrowsError(try blur.settings())
            let sharpen = RecorderUnsharpMaskValue(radius: 1, amount: invalid, threshold: 0)
            XCTAssertThrowsError(try RecorderFileCodec.encode(value(.applyUnsharpMask(sharpen))))
            XCTAssertThrowsError(try sharpen.settings())
        }
        var native = unsharpEngine; native.threshold = 2
        XCTAssertThrowsError(try RecorderUnsharpMaskValue(native))
        var blur = gaussianEngine; blur.deviationY = .nan
        XCTAssertThrowsError(try RecorderGaussianBlurValue(blur))
    }

    func testRecordedFiltersSnapshotAndPrepareExactly() throws {
        var log = RecorderLog<SemanticImageCommand>()
        try log.startRecording()
        try log.resolve(try log.reserve(), with: .success(.applyGaussianBlur(gaussianEngine)))
        try log.resolve(try log.reserve(), with: .success(.applyUnsharpMask(unsharpEngine)))
        try log.stopRecording()
        let description = RecorderTargetDescription(name: "Blur target", kind: .pixel, ancestors: [],
            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 41, height: 29))
        var catalog = RecorderDescriptionCatalog()
        catalog.acceptFirst([symbol: .available(description)])
        let snapshot = try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Blur", origin: origin,
            descriptions: catalog, bindings: [0: .layer(symbol), 1: .layer(symbol)])
        let encoded = try RecorderFileCodec.encode(snapshot)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":26"#))
        let prepared = try RecorderFileSemanticBridge.prepare(try RecorderFileCodec.decode(encoded))
        guard case .success(.applyGaussianBlur(let blur)) = prepared.log.records[0].resolution,
              case .success(.applyUnsharpMask(let sharpen)) = prepared.log.records[1].resolution else {
            return XCTFail("A prepared filter command was lost")
        }
        XCTAssertEqual(blur, gaussianEngine)
        XCTAssertEqual(sharpen, unsharpEngine)
        XCTAssertThrowsError(try RecorderFileCodec.snapshot(log, recordingID: recordingID, name: "Blur", origin: origin,
            descriptions: catalog, bindings: [0: .none, 1: .layer(symbol)]))
    }

    func testFiltersAreLayerBoundResolveFirstCommandsButNotMaskAdjustments() {
        for (command, title) in [(SemanticImageCommand.applyGaussianBlur(gaussianEngine), "Gaussian Blur"),
                                 (.applyUnsharpMask(unsharpEngine), "Unsharp Mask")] {
            XCTAssertEqual(command.title, title)
            XCTAssertTrue(command.requiresResolvedFloatingSelection)
            XCTAssertTrue(command.isLayerAdjustment)
            XCTAssertFalse(command.isMaskAdjustment)
        }
    }
}
