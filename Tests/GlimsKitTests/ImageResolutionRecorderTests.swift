import XCTest
@testable import GlimsKit

/// Recording version 31: Image Size's resolution-only and combined
/// commands round trip through the codec and prepare for replay.
final class ImageResolutionRecorderTests: XCTestCase {
    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func document(_ command: String, version: Int = 31,
                          binding: String = #"{"kind":"none"}"#) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Resolution","origin":{"imageLabel":"A","initialWidth":1200,"initialHeight":900},"symbols":[],"records":[{"ordinal":0,"outcome":"success","command":"#
            + command + #","binding":"# + binding + "}]}"
    }

    func testSetResolutionRoundTrips() throws {
        let command = #"{"tag":"setResolution","x":150,"y":150}"#
        let value = try RecorderFileCodec.decode(bytes(document(command)))
        guard case .success(.setResolution(150, 150), .none) = value.records[0].outcome else {
            return XCTFail("The resolution-only command was lost")
        }
        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":31"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
        let prepared = try RecorderFileSemanticBridge.prepare(value)
        guard case .success(.setResolution(150, 150)) = prepared.log.records[0].resolution else {
            return XCTFail("The prepared resolution-only command was lost")
        }
    }

    func testCombinedResizeRoundTrips() throws {
        let command = #"{"tag":"resize","width":1800,"height":1350,"xResolution":300,"yResolution":300,"interpolation":"cubic"}"#
        let value = try RecorderFileCodec.decode(bytes(document(command)))
        guard case .success(.resize(1800, 1350, 300, 300, .cubic), .none) = value.records[0].outcome else {
            return XCTFail("The combined resize was lost")
        }
        let prepared = try RecorderFileSemanticBridge.prepare(value)
        guard case .success(.resize(1800, 1350, 300, 300, .cubic)) = prepared.log.records[0].resolution else {
            return XCTFail("The prepared combined resize was lost")
        }
        XCTAssertEqual(try RecorderFileCodec.decode(try RecorderFileCodec.encode(value)), value)
    }

    func testVersionsAndBindingsReject() {
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"setResolution","x":150,"y":150}"#, version: 30))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"resize","width":1,"height":1,"xResolution":150,"yResolution":150,"interpolation":"cubic"}"#,
            version: 30))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"scale","width":1,"height":1}"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"setResolution","x":150,"y":150}"#,
            binding: #"{"kind":"layer","symbol":"66666666-6666-6666-6666-666666666666"}"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"setResolution","x":0,"y":150}"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"setResolution","x":150,"y":150,"future":0}"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"resize","width":0,"height":1,"xResolution":150,"yResolution":150,"interpolation":"cubic"}"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"resize","width":1,"height":1,"xResolution":150,"yResolution":150,"interpolation":"bicubic"}"#))))
    }

    func testCommandIsTargetIndependentAndTitledLikeImageSize() {
        let resolution = SemanticImageCommand.setResolution(x: 150, y: 150)
        XCTAssertEqual(resolution.title, "Scale Image")
        XCTAssertTrue(resolution.requiresResolvedFloatingSelection)
        let combined = SemanticImageCommand.resize(width: 10, height: 20, xResolution: 150, yResolution: 150,
                                                  interpolation: .linear)
        XCTAssertEqual(combined.title, "Scale Image")
        XCTAssertTrue(RecorderFileCommand.setResolution(x: 150, y: 150).isTargetIndependent)
        XCTAssertTrue(RecorderFileCommand.resize(width: 10, height: 20, xResolution: 150, yResolution: 150,
                                                interpolation: .linear).isTargetIndependent)
    }
}
