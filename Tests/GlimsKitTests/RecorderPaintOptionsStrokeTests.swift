import XCTest
@testable import GlimsKit

/// Admission, settings round trips and strict file-version rules for
/// recorded paint options. Identities and digests are authored fixtures.
final class RecorderPaintOptionsStrokeTests: XCTestCase {
    private let recordingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let symbolID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

    private func brush(_ tool: EngineSession.Brush.Tool) -> EngineSession.Brush {
        var value = EngineSession.Brush()
        value.tool = tool
        value.size = 8.5
        value.opacity = 0.75
        value.red = 0.2
        value.green = 0.4
        value.blue = 0.6
        value.hardness = 0.25
        return value
    }

    private func settings(tool: RecorderStrokeCommand.Tool, paintMode: String? = nil,
                          spacing: Double? = nil, fade: EngineSession.Brush.Fade? = nil,
                          fadeBackground: EngineSession.Brush.EraserBackground? = nil) -> RecorderStrokeCommand.Settings? {
        .init(tool: tool, size: 8.5, opacity: 0.75, red: 0.2, green: 0.4, blue: 0.6,
              hardness: 0.25, pressureSize: true, antiErase: tool == .eraser,
              paintMode: paintMode, spacing: spacing, fade: fade, fadeBackground: fadeBackground)
    }

    private func trace() throws -> RecorderStrokeTrace {
        try .init(first: .init(x: -1.5, y: 3.5, pressure: 0.25, xTilt: -0.5, yTilt: 0.5,
                               timeMilliseconds: 1), batches: [
            [.init(x: 2.25, y: 4, pressure: 0.75, xTilt: 0.25, yTilt: 0, timeMilliseconds: 7)],
        ])
    }

    private func facts() -> EngineSession.StrokeCaptureFacts {
        .init(brush: .init(name: "Authored brush identity", collection: "fixture", isInternal: false),
              fingerprint: digest)
    }

    private func file(_ stroke: RecorderStrokeCommand) -> RecorderFileValue {
        .init(recordingID: recordingID, name: "Options fixture",
              origin: .init(imageLabel: "A", initialWidth: 32, initialHeight: 24),
              symbols: [.init(id: symbolID, description: .init(name: "Original pixel layer", kind: .pixel,
                  ancestors: [], siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 32, height: 24)))],
              records: [.init(ordinal: 0, outcome: .success(.completeStroke(stroke), .layer(symbolID)))])
    }

    private func literal(tool: String = "pencil", tag: String = "completeStroke",
                         version: Int = RecorderFileCodec.paintOptionsStrokeVersion, settingsExtra: String = "") -> Data {
        let binding = tag == "completeInkStroke"
            ? #"{"kind":"ink","symbol":"33333333-3333-3333-3333-333333333333","mode":"cmyk","role":"cyan","uuid":"01234567-89ab-cdef-0123-456789abcdef"}"#
            : #"{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"}"#
        let symbol = tag == "completeInkStroke"
            ? #"{"id":"33333333-3333-3333-3333-333333333333","description":{"name":"Cyan","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":32,"height":24}}}"#
            : #"{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Original pixel layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":32,"height":24}}}"#
        let text = """
        {"format":"ch.lkmc.Glims.recording","version":\(version),"recordingID":"11111111-1111-1111-1111-111111111111","name":"Options fixture","origin":{"imageLabel":"A","initialWidth":32,"initialHeight":24},"symbols":[\(symbol)],"records":[{"ordinal":0,"outcome":"success","binding":\(binding),"command":{"tag":"\(tag)","settings":{"tool":"\(tool)","size":8.5,"opacity":0.75,"red":0.2,"green":0.4,"blue":0.6,"hardness":0.25,"pressureSize":true,"antiErase":false\(settingsExtra)},"facts":{"brush":{"name":"Authored brush identity","collection":"fixture","isInternal":false},"fingerprint":"\(digest)"},"first":{"x":-1.5,"y":3.5,"pressure":0.25,"xTilt":-0.5,"yTilt":0.5,"timeMilliseconds":1},"batches":[[{"x":2.25,"y":4,"pressure":0.75,"xTilt":0.25,"yTilt":0,"timeMilliseconds":7}]]}}]}
        """
        return Data(text.utf8)
    }

    func testAdmissionKeepsOptionsForPencilAndPaintbrush() throws {
        var pencil = brush(.pencil)
        pencil.paintMode = "multiply"
        pencil.spacing = 0.5
        pencil.fade = .init(steps: 4, target: .transparent)
        let pencilSettings = try XCTUnwrap(RecorderStrokeCommand.Settings(pencil))
        XCTAssertEqual(pencilSettings.paintMode, "multiply")
        XCTAssertEqual(pencilSettings.spacing, 0.5)
        XCTAssertEqual(pencilSettings.fade, .init(steps: 4, target: .transparent))
        XCTAssertTrue(pencilSettings.hasRecordedPaintOptions)

        var paintbrush = brush(.paintbrush)
        paintbrush.fade = .init(steps: 8, target: .background)
        paintbrush.fadeBackground = .init(red: 1, green: 0.5, blue: 0)
        let brushSettings = try XCTUnwrap(RecorderStrokeCommand.Settings(paintbrush))
        XCTAssertEqual(brushSettings.fadeBackground, .init(red: 1, green: 0.5, blue: 0))
    }

    func testAdmissionKeepsOnlySpacingForEraserAndNothingForSponge() {
        var eraser = brush(.eraser)
        eraser.spacing = 0.5
        XCTAssertNotNil(RecorderStrokeCommand.Settings(eraser))
        eraser.paintMode = "screen"
        XCTAssertNil(RecorderStrokeCommand.Settings(eraser), "the Eraser records no blend mode")
        eraser.paintMode = "normal"
        eraser.fade = .init(steps: 4, target: .transparent)
        XCTAssertNil(RecorderStrokeCommand.Settings(eraser), "the Eraser records no fade")
        for tool in [EngineSession.Brush.Tool.spongeDesaturate, .spongeSaturate] {
            var sponge = brush(tool)
            sponge.spacing = 0.5
            XCTAssertNil(RecorderStrokeCommand.Settings(sponge), "\(tool) records no options")
        }
        var airbrush = brush(.airbrush)
        airbrush.spacing = 0.5
        XCTAssertNil(RecorderStrokeCommand.Settings(airbrush))
        var clone = brush(.pencil)
        clone.clonePattern = .init(resource: .init(name: "Pine", collection: nil, isInternal: false),
                                   aligned: true)
        XCTAssertNil(RecorderStrokeCommand.Settings(clone), "a clone pattern stays unrecorded")
    }

    func testSettingsValidationFollowsTheToolRules() {
        let normal = settings(tool: .pencil, paintMode: "normal")
        XCTAssertNotNil(normal)
        XCTAssertNil(normal?.paintMode, "an explicit Normal stores as absent")
        XCTAssertNil(settings(tool: .pencil, paintMode: "erase"))
        XCTAssertNil(settings(tool: .eraser, paintMode: "multiply"))
        XCTAssertNil(settings(tool: .spongeDesaturate, paintMode: "multiply"))
        XCTAssertNotNil(settings(tool: .pencil, spacing: 0.5))
        XCTAssertNotNil(settings(tool: .eraser, spacing: 0.5))
        XCTAssertNil(settings(tool: .pencil, spacing: 0.005))
        XCTAssertNil(settings(tool: .pencil, spacing: 10.01))
        XCTAssertNil(settings(tool: .pencil, spacing: .nan))
        XCTAssertNil(settings(tool: .spongeDesaturate, spacing: 0.5))
        XCTAssertNotNil(settings(tool: .pencil, fade: .init(steps: 4, target: .transparent)))
        XCTAssertNotNil(settings(tool: .paintbrush, fade: .init(steps: 4, target: .background),
                                 fadeBackground: .init(red: 1, green: 0.5, blue: 0)))
        XCTAssertNil(settings(tool: .pencil, fade: .init(steps: 0, target: .transparent)))
        XCTAssertNil(settings(tool: .pencil, fade: .init(steps: 10_000, target: .transparent)))
        XCTAssertNil(settings(tool: .eraser, fade: .init(steps: 4, target: .transparent)))
        XCTAssertNil(settings(tool: .pencil, fade: .init(steps: 4, target: .background)))
        XCTAssertNil(settings(tool: .pencil, fade: .init(steps: 4, target: .transparent),
                              fadeBackground: .init(red: 1, green: 0.5, blue: 0)))
        XCTAssertNil(settings(tool: .pencil, fadeBackground: .init(red: 1, green: 0.5, blue: 0)))
        XCTAssertNil(settings(tool: .pencil, fade: .init(steps: 4, target: .background),
                              fadeBackground: .init(red: 1.5, green: 0.5, blue: 0)))
    }

    func testSettingsRoundTripThroughBrush() throws {
        var pencil = brush(.pencil)
        pencil.paintMode = "multiply"
        pencil.spacing = 0.5
        pencil.fade = .init(steps: 4, target: .background)
        pencil.fadeBackground = .init(red: 1, green: 0.5, blue: 0)
        XCTAssertEqual(try XCTUnwrap(RecorderStrokeCommand.Settings(pencil)).brush, pencil)
        var eraser = brush(.eraser)
        eraser.spacing = 0.5
        eraser.eraserBackground = .init(red: 1, green: 1, blue: 1)
        XCTAssertEqual(try XCTUnwrap(RecorderStrokeCommand.Settings(eraser)).brush, eraser)
    }

    func testEncodingWritesPaintOptionsVersionOnlyWhenAStrokeCarriesOptions() throws {
        var pencil = brush(.pencil)
        pencil.spacing = 0.5
        let options = file(try .init(settings: XCTUnwrap(RecorderStrokeCommand.Settings(pencil)),
                                     trace: trace(), facts: facts()))
        let encoded = try RecorderFileCodec.encode(options)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, RecorderFileCodec.paintOptionsStrokeVersion)
        let decoded = try RecorderFileCodec.decode(encoded)
        XCTAssertEqual(decoded, options)
        guard case .success(.completeStroke(let stroke), .layer) = decoded.records.first?.outcome else {
            return XCTFail("missing the option stroke")
        }
        XCTAssertEqual(stroke.settings.spacing, 0.5)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains(#""spacing":0.5"#))

        let plain = file(try .init(settings: XCTUnwrap(RecorderStrokeCommand.Settings(brush(.pencil))),
                                   trace: trace(), facts: facts()))
        let plainJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: RecorderFileCodec.encode(plain)) as? [String: Any])
        XCTAssertEqual(plainJSON["version"] as? Int, 2)
    }

    func testVersion29RefusesTheOptionFields() {
        for extra in [#""paintMode":"multiply""#, #""spacing":0.5"#,
                      #""fade":{"steps":4,"target":"transparent"}"#] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(literal(version: RecorderFileCodec.paintOptionsStrokeVersion - 1, settingsExtra: ",\(extra)")), extra)
        }
        XCTAssertThrowsError(try RecorderFileCodec.decode(literal(version: 2, settingsExtra: #", "spacing":0.5"#)))
    }

    func testPaintOptionsVersionRequiresAnOptionStroke() throws {
        XCTAssertThrowsError(try RecorderFileCodec.decode(literal()),
                             "the paint-options version needs a stroke that carries paint options")
        XCTAssertThrowsError(try RecorderFileCodec.decode(literal(settingsExtra: #","paintMode":"normal""#)),
                             "an explicit Normal is no option")
        let decoded = try RecorderFileCodec.decode(literal(settingsExtra: #","spacing":0.5"#))
        guard case .success(.completeStroke(let stroke), .layer) = decoded.records.first?.outcome else {
            return XCTFail("missing the option stroke")
        }
        XCTAssertEqual(stroke.settings.spacing, 0.5)
        XCTAssertNil(stroke.settings.paintMode)
    }

    func testPaintOptionsVersionRoundTripsModeAndFade() throws {
        let extra = #","paintMode":"multiply","spacing":0.5,"fade":{"steps":4,"target":"background","background":{"red":1,"green":0.5,"blue":0}}"#
        let decoded = try RecorderFileCodec.decode(literal(version: RecorderFileCodec.paintOptionsStrokeVersion, settingsExtra: extra))
        guard case .success(.completeStroke(let stroke), .layer) = decoded.records.first?.outcome else {
            return XCTFail("missing the option stroke")
        }
        XCTAssertEqual(stroke.settings.paintMode, "multiply")
        XCTAssertEqual(stroke.settings.spacing, 0.5)
        XCTAssertEqual(stroke.settings.fade, .init(steps: 4, target: .background))
        XCTAssertEqual(stroke.settings.fadeBackground, .init(red: 1, green: 0.5, blue: 0))
        let encoded = try RecorderFileCodec.encode(decoded)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["version"] as? Int, RecorderFileCodec.paintOptionsStrokeVersion)
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), decoded)
    }

    func testPaintOptionsVersionRefusesMalformedOptionFields() {
        for extra in [
            #","paintMode":"erase""#,
            #","spacing":0.005"#,
            #","fade":{"steps":0,"target":"transparent"}"#,
            #","fade":{"steps":4,"target":"magenta"}"#,
            #","fade":{"steps":4,"target":"transparent","background":{"red":1,"green":0.5,"blue":0}}"#,
            #","fade":{"steps":4,"target":"background"}"#,
            #","fade":{"steps":4,"target":"background","background":{"red":1.5,"green":0.5,"blue":0}}"#,
        ] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(literal(version: RecorderFileCodec.paintOptionsStrokeVersion, settingsExtra: extra)), extra)
        }
    }

    func testOptionFieldsStayRefusedInInkAndLabLayerSettings() throws {
        XCTAssertThrowsError(try RecorderFileCodec.decode(
            literal(tool: "paintbrush", tag: "completeInkStroke", version: 16, settingsExtra: #","spacing":0.5"#)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(
            literal(tag: "completeLabLayerStroke", version: 18, settingsExtra: #","spacing":0.5"#)))
    }

    func testTabletStrokeParity() throws {
        let decoded = try RecorderFileCodec.decode(literal(tag: "completeTabletStroke", version: RecorderFileCodec.paintOptionsStrokeVersion,
            settingsExtra: #","spacing":0.5"#))
        guard case .success(.completeTabletStroke(let stroke), .layer) = decoded.records.first?.outcome else {
            return XCTFail("missing the tablet option stroke")
        }
        XCTAssertEqual(stroke.settings.spacing, 0.5)
        XCTAssertNoThrow(try stroke.validated())
        let encoded = try RecorderFileCodec.encode(decoded)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: encoded) as? [String: Any])?["version"] as? Int, RecorderFileCodec.paintOptionsStrokeVersion)
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), decoded)
        XCTAssertThrowsError(try RecorderFileCodec.decode(
            literal(tag: "completeTabletStroke", version: 21, settingsExtra: #","spacing":0.5"#)))
        XCTAssertThrowsError(try RecorderFileCodec.decode(
            literal(tool: "eraser", tag: "completeTabletStroke", version: RecorderFileCodec.paintOptionsStrokeVersion, settingsExtra: #","paintMode":"multiply""#)))
    }
}
