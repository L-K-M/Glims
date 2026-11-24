import XCTest
@testable import GlimsKit

/// The Crop tool's Fixed Target Size model: unit conversions, the drag's
/// proportion constraint in every direction, validation and the Front
/// Image fill, plus the recording version 32 rules.
final class CropTargetTests: XCTestCase {
    private func bytes(_ text: String) -> Data { Data(text.utf8) }
    private func document(_ command: String, version: Int = 32,
                          binding: String = #"{"kind":"none"}"#) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version)
            + #","recordingID":"11111111-1111-1111-1111-111111111111","name":"Crop","origin":{"imageLabel":"A","initialWidth":200,"initialHeight":150},"symbols":[],"records":[{"ordinal":0,"outcome":"success","command":"#
            + command + #","binding":"# + binding + "}]}"
    }

    private func settings(width: String, height: String,
                          unit: ImageSizeModel.SizeUnit = .pixels,
                          resolution: String = "",
                          resolutionUnit: ImageSizeModel.ResolutionUnit = .pixelsPerInch) -> CropTargetSettings {
        var settings = CropTargetSettings()
        settings.enabled = true
        settings.width = width
        settings.height = height
        settings.unit = unit
        settings.resolution = resolution
        settings.resolutionUnit = resolutionUnit
        return settings
    }

    func testPixelTargetResolves() {
        let target = settings(width: "60", height: "40").resolved(imageResolution: nil)
        XCTAssertEqual(target?.width, 60)
        XCTAssertEqual(target?.height, 40)
        XCTAssertNil(target?.resolution)
        XCTAssertEqual(target?.interpolation, .cubic)
    }

    func testPhysicalUnitsConvertAtTheResolution() {
        let inches = settings(width: "5", height: "2.5", unit: .inches, resolution: "144")
            .resolved(imageResolution: nil)
        XCTAssertEqual(inches?.width, 720)
        XCTAssertEqual(inches?.height, 360)
        XCTAssertEqual(inches?.resolution?.x, 144)
        let centimeters = settings(width: "10", height: "5", unit: .centimeters, resolution: "118.11",
                                   resolutionUnit: .pixelsPerCentimeter)
            .resolved(imageResolution: nil)
        XCTAssertEqual(centimeters?.width ?? 0, 1181, accuracy: 1)
        XCTAssertEqual(centimeters?.height ?? 0, 591, accuracy: 1)
        let millimeters = settings(width: "100", height: "50", unit: .millimeters, resolution: "100")
            .resolved(imageResolution: nil)
        XCTAssertEqual(millimeters?.width ?? 0, 394, accuracy: 1)
        XCTAssertEqual(millimeters?.height ?? 0, 197, accuracy: 1)
    }

    func testEmptyResolutionUsesTheImages() {
        let resolution = EngineSession.ImageResolution(x: 300, y: 300)
        let target = settings(width: "1", height: "1", unit: .inches)
            .resolved(imageResolution: resolution)
        XCTAssertEqual(target?.width, 300)
        XCTAssertNil(target?.resolution)
    }

    func testValidation() {
        XCTAssertNil(CropTargetSettings().resolved(imageResolution: nil),
                     "the option off resolves nothing")
        XCTAssertNil(settings(width: "", height: "40").resolved(imageResolution: nil))
        XCTAssertNil(settings(width: "abc", height: "40").resolved(imageResolution: nil))
        XCTAssertNil(settings(width: "0", height: "40").resolved(imageResolution: nil))
        XCTAssertNil(settings(width: "999999", height: "40").resolved(imageResolution: nil))
        XCTAssertNil(settings(width: "60", height: "40", resolution: "abc").resolved(imageResolution: nil))
        XCTAssertNil(settings(width: "60", height: "40", resolution: "0").resolved(imageResolution: nil))
        XCTAssertNil(settings(width: "5.5", height: "40").resolved(imageResolution: nil),
                     "pixels must be whole numbers")
    }

    func testConstraintInEveryDirection() {
        let target = CropTarget(width: 60, height: 40, resolution: nil, interpolation: .none)
        let start = CGPoint(x: 10, y: 10)
        // Height-driven: the drag's height forces the width to 3:2.
        var end = target.constrainedEnd(CGPoint(x: 70, y: 60), from: start)
        XCTAssertEqual(end.x, 85, accuracy: 0.001)
        XCTAssertEqual(end.y, 60, accuracy: 0.001)
        // Width-driven: the width forces the height to 3:2.
        end = target.constrainedEnd(CGPoint(x: 40, y: 12), from: start)
        XCTAssertEqual(end.x, 40, accuracy: 0.001)
        XCTAssertEqual(end.y, 30, accuracy: 0.001)
        // Left-down, left-up and right-up keep the signs.
        end = target.constrainedEnd(CGPoint(x: -50, y: 60), from: start)
        XCTAssertEqual(end.x, -65, accuracy: 0.001)
        XCTAssertEqual(end.y, 60, accuracy: 0.001)
        end = target.constrainedEnd(CGPoint(x: -50, y: -40), from: start)
        XCTAssertEqual(end.x, -65, accuracy: 0.001)
        XCTAssertEqual(end.y, -40, accuracy: 0.001)
        end = target.constrainedEnd(CGPoint(x: 70, y: -40), from: start)
        XCTAssertEqual(end.x, 85, accuracy: 0.001)
        XCTAssertEqual(end.y, -40, accuracy: 0.001)
        // A dragged zero stays zero.
        end = target.constrainedEnd(start, from: start)
        XCTAssertEqual(end, start)
    }

    func testFrontImageFill() {
        var target = CropTargetSettings()
        target.unit = .inches
        target.resolutionUnit = .pixelsPerCentimeter
        target.fillFromImage(width: 200, height: 150,
                             resolution: .init(x: 144, y: 144))
        XCTAssertEqual(target.unit, .pixels)
        XCTAssertEqual(target.width, "200")
        XCTAssertEqual(target.height, "150")
        XCTAssertEqual(target.resolutionUnit, .pixelsPerInch)
        XCTAssertEqual(target.resolution, "144")
        // One field cannot hold 300 x 150; leaving it empty keeps the
        // image's own resolution instead of setting 300 x 300.
        target.fillFromImage(width: 200, height: 150, resolution: .init(x: 300, y: 150))
        XCTAssertEqual(target.resolution, "")
        target.enabled = true
        XCTAssertNil(target.resolved(imageResolution: .init(x: 300, y: 150))?.resolution)
    }

    func testCropResizeRoundTrips() throws {
        let command = #"{"tag":"cropResize","rect":{"x":10,"y":10,"width":100,"height":80},"width":60,"height":40,"xResolution":144,"yResolution":144,"interpolation":"cubic"}"#
        let value = try RecorderFileCodec.decode(bytes(document(command)))
        guard case .success(.cropResize(_, 60, 40, 144?, 144?, .cubic), .none) = value.records[0].outcome else {
            return XCTFail("The crop target command was lost")
        }
        let encoded = try RecorderFileCodec.encode(value)
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains(#""version":32"#))
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
        let prepared = try RecorderFileSemanticBridge.prepare(value)
        guard case .success(.cropResize(_, 60, 40, 144?, 144?, .cubic)) = prepared.log.records[0].resolution else {
            return XCTFail("The prepared crop target command was lost")
        }
    }

    func testAbsentResolutionKeepsTheImagesOwn() throws {
        // No resolution in the file means the receiving image keeps its own.
        let command = #"{"tag":"cropResize","rect":{"x":10,"y":10,"width":100,"height":80},"width":60,"height":40,"interpolation":"cubic"}"#
        let value = try RecorderFileCodec.decode(bytes(document(command)))
        guard case .success(.cropResize(_, 60, 40, nil, nil, .cubic), .none) = value.records[0].outcome else {
            return XCTFail("The crop target command without a resolution was lost")
        }
        let encoded = String(decoding: try RecorderFileCodec.encode(value), as: UTF8.self)
        XCTAssertFalse(encoded.contains("xResolution"))
        XCTAssertEqual(try RecorderFileCodec.decode(Data(encoded.utf8)), value)
        // One resolution without the other is refused, reading and writing.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"cropResize","rect":{"x":0,"y":0,"width":10,"height":10},"width":10,"height":10,"xResolution":144,"interpolation":"cubic"}"#))))
        let half = RecorderFileValue(
            recordingID: value.recordingID, name: value.name, origin: value.origin, symbols: [],
            records: [.init(ordinal: 0, outcome: .success(
                .cropResize(rect: .init(x: 0, y: 0, width: 10, height: 10), width: 10, height: 10,
                            xResolution: 144, yResolution: nil, interpolation: .cubic), .none))])
        XCTAssertThrowsError(try RecorderFileCodec.encode(half))
    }

    func testVersionRules() throws {
        // A version 31 file with the command is refused.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"cropResize","rect":{"x":0,"y":0,"width":10,"height":10},"width":10,"height":10,"xResolution":144,"yResolution":144,"interpolation":"cubic"}"#,
            version: 31))))
        // A version 32 file without the command is refused.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"setResolution","x":150,"y":150}"#, version: 32))))
        // A plain crop alone does not write version 32.
        let plain = try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"crop","rect":{"x":0,"y":0,"width":10,"height":10}}"#, version: 1)))
        XCTAssertFalse(String(decoding: try RecorderFileCodec.encode(plain), as: UTF8.self)
            .contains(#""version":32"#))
        // Strict fields: unknown keys, bad sizes, resolutions and methods.
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"cropResize","rect":{"x":0,"y":0,"width":10,"height":10},"width":0,"height":10,"xResolution":144,"yResolution":144,"interpolation":"cubic"}"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"cropResize","rect":{"x":0,"y":0,"width":10,"height":10},"width":10,"height":10,"xResolution":0,"yResolution":144,"interpolation":"cubic"}"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"cropResize","rect":{"x":0,"y":0,"width":10,"height":10},"width":10,"height":10,"xResolution":144,"yResolution":144,"interpolation":"bicubic"}"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"cropResize","rect":{"x":0,"y":0,"width":0,"height":10},"width":10,"height":10,"xResolution":144,"yResolution":144,"interpolation":"cubic"}"#))))
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(document(
            #"{"tag":"cropResize","rect":{"x":0,"y":0,"width":10,"height":10},"width":10,"height":10,"xResolution":144,"yResolution":144,"interpolation":"cubic","future":0}"#))))
    }

    func testCommandIsTargetIndependentAndTitledLikeItsUndoStep() {
        let command = SemanticImageCommand.cropResize(rect: CGRect(x: 0, y: 0, width: 10, height: 10),
                                                      width: 60, height: 40, xResolution: 144,
                                                      yResolution: 144, interpolation: .linear)
        XCTAssertEqual(command.title, "Crop Image")
        XCTAssertTrue(command.requiresResolvedFloatingSelection)
        XCTAssertTrue(RecorderFileCommand.cropResize(rect: .init(x: 0, y: 0, width: 10, height: 10),
                                                   width: 60, height: 40, xResolution: 144,
                                                   yResolution: 144, interpolation: .linear).isTargetIndependent)
    }
}
