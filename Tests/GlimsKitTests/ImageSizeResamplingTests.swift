import AppKit
import XCTest
@testable import GlimsKit

/// Recording version 27 (Image Size with an explicit resampling method) and
/// the Image Size popup's mapping. Fixtures spell out their own JSON.
final class ImageSizeResamplingTests: XCTestCase {
    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func document(_ command: String, binding: String = #"{"kind":"none"}"#, version: Int = 27) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Resample","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":[],"records":[{"ordinal":0,"outcome":"success","command":"#
            + command + #","binding":"# + binding + "}]}"
    }
    private func command(_ interpolation: String = "noHalo", width: Int = 35, height: Int = 43) -> String {
        "{\"tag\":\"scaleWithInterpolation\",\"width\":\(width),\"height\":\(height),\"interpolation\":\"\(interpolation)\"}"
    }

    func testEveryMethodRoundTripsAndPreparesExactly() throws {
        for (name, engine) in [("none", EngineSession.Interpolation.none), ("linear", .linear), ("cubic", .cubic),
                               ("noHalo", .noHalo), ("loHalo", .loHalo)] {
            let value = try RecorderFileCodec.decode(bytes(document(command(name))))
            guard case .success(.scaleWithInterpolation(35, 43, let interpolation), .none) = value.records[0].outcome else {
                return XCTFail("The resampled Image Size was lost for \(name)")
            }
            XCTAssertEqual(interpolation.rawValue, name)
            let encoded = try RecorderFileCodec.encode(value)
            XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":27"#))
            XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
            let prepared = try RecorderFileSemanticBridge.prepare(value)
            guard case .success(.scaleWithInterpolation(35, 43, let restored)) = prepared.log.records[0].resolution else {
                return XCTFail("The prepared resampled Image Size was lost for \(name)")
            }
            XCTAssertEqual(restored, engine)
        }
    }

    func testInvalidFieldsVersionsAndBindingsReject() {
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command("bicubic")))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command(width: 0)))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command(height: 524289)))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(#"{"tag":"scaleWithInterpolation","width":35,"height":43}"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"scaleWithInterpolation","width":35,"height":43,"interpolation":"cubic","future":0}"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command(), version: 26)))) {
            XCTAssertTrue($0.localizedDescription.contains("version 27"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(#"{"tag":"scale","width":1,"height":1}"#)))) {
            XCTAssertTrue($0.localizedDescription.contains("Version 27 requires"), $0.localizedDescription)
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command(), version: 28))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(command(),
            binding: #"{"kind":"layer","symbol":"66666666-6666-6666-6666-666666666666"}"#))))
    }

    func testDefaultScaleKeepsItsOriginalVersion() throws {
        let value = try RecorderFileCodec.decode(bytes(document(#"{"tag":"scale","width":2,"height":3}"#, version: 1)))
        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":1"#))
    }

    func testCommandIsTargetIndependentAndTitledLikeImageSize() {
        let command = SemanticImageCommand.scaleWithInterpolation(width: 2, height: 3, interpolation: .linear)
        XCTAssertEqual(command.title, "Scale Image")
        XCTAssertTrue(command.requiresResolvedFloatingSelection)
        XCTAssertTrue(RecorderFileCommand.scaleWithInterpolation(width: 2, height: 3, interpolation: .linear).isTargetIndependent)
    }

    @MainActor
    func testPopUpDefaultsToBicubicAndMapsEveryChoice() throws {
        let button = ImageSizeResampling.popUpButton()
        XCTAssertEqual(button.titleOfSelectedItem, "Bicubic")
        XCTAssertEqual(ImageSizeResampling.interpolation(of: button), .cubic)
        XCTAssertEqual(button.itemTitles, ["Nearest Neighbor", "Bilinear", "Bicubic", "NoHalo", "LoHalo"])
        let expected: [EngineSession.Interpolation] = [.none, .linear, .cubic, .noHalo, .loHalo]
        for (index, interpolation) in expected.enumerated() {
            button.selectItem(at: index)
            XCTAssertEqual(ImageSizeResampling.interpolation(of: button), interpolation)
        }
    }
}
