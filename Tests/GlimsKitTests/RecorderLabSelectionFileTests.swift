import XCTest
import CoreGraphics
@testable import GlimsKit

final class RecorderLabSelectionFileTests: XCTestCase {
    private let recordingID = UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")!
    private let symbol = UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")!
    private let origin = RecorderFileValue.Origin(imageLabel: "Source", initialWidth: 16, initialHeight: 9)

    private func bytes(_ text: String) -> Data { Data(text.utf8) }

    private func document(_ rows: String, symbols: String = "", name: String = "Lab selection", version: Int = 15) -> String {
        #"{"format":"ch.lkmc.Glims.recording","version":"# + String(version) +
        #","recordingID":"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa","name":""# + name +
        #"","origin":{"imageLabel":"Source","initialWidth":16,"initialHeight":9},"symbols":["# + symbols +
        #"],"records":["# + rows + "]}"
    }

    private func success(_ command: String, binding: String = #"{"kind":"none"}"#, ordinal: Int = 0) -> String {
        #"{"ordinal":"# + String(ordinal) + #","outcome":"success","command":"# + command + #","binding":"# + binding + "}"
    }

    private func decodeRejects(_ text: String, reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try RecorderFileCodec.decode(bytes(text)), reason, file: file, line: line)
    }

    private func decodeAndEncode(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> RecorderFileValue {
        let decoded = try RecorderFileCodec.decode(bytes(text))
        let encoded = try RecorderFileCodec.encode(decoded)
        let roundtrip = try RecorderFileCodec.decode(encoded)
        XCTAssertEqual(roundtrip, decoded, "Decoded value did not survive encode/decode", file: file, line: line)
        return decoded
    }

    private func labOptionsJSON(operation: String, antialias: Bool, feather: String, cornerRadius: String) -> String {
        #"{"operation":""# + operation + #"","antialias":"# + (antialias ? "true" : "false") +
        #","feather":"# + feather + #","cornerRadius":"# + cornerRadius + "}"
    }

    private func labShapeJSON(shape: String, payload: String, options: String) -> String {
        #"{"tag":"labSelectionShape","shape":{"tag":""# + shape + #"","# + payload + #"},"options":"# + options + "}"
    }

    private func mutateObject(_ json: String, key: String, mutate: (inout [String: Any]) -> Void,
                              file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let data = json.data(using: .utf8),
              var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Could not parse JSON object for mutation", file: file, line: line)
            return json
        }
        let before = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        mutate(&object)
        let after = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        XCTAssertNotEqual(before, after, "Mutation for key \(key) was a no-op", file: file, line: line)
        guard let result = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: result, encoding: .utf8) else {
            XCTFail("Could not serialize mutated JSON", file: file, line: line)
            return json
        }
        return text
    }

    private func mutateNestedObject(in json: String, path: [String], mutate: (inout [String: Any]) -> Void,
                                    file: StaticString = #filePath, line: UInt = #line) -> String {
        guard !path.isEmpty else {
            return mutateObject(json, key: "root", mutate: mutate, file: file, line: line)
        }
        guard let data = json.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Could not parse root JSON for nested mutation", file: file, line: line)
            return json
        }
        func walk(_ container: inout [String: Any], index: Int) {
            let key = path[index]
            if index == path.count - 1 {
                guard var object = container[key] as? [String: Any] else {
                    XCTFail("Missing nested object at \(key)", file: file, line: line)
                    return
                }
                mutate(&object)
                container[key] = object
            } else {
                guard var object = container[key] as? [String: Any] else {
                    XCTFail("Missing nested path at \(key)", file: file, line: line)
                    return
                }
                walk(&object, index: index + 1)
                container[key] = object
            }
        }
        let before = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        walk(&root, index: 0)
        let after = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        XCTAssertNotEqual(before, after, "Nested mutation at \(path.joined(separator: ".")) was a no-op", file: file, line: line)
        guard let result = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]),
              let text = String(data: result, encoding: .utf8) else {
            XCTFail("Could not serialize nested mutated JSON", file: file, line: line)
            return json
        }
        return text
    }

    private var rectangleShapeCommand: String {
        let options = labOptionsJSON(operation: "replace", antialias: true, feather: "2.5", cornerRadius: "0")
        return labShapeJSON(shape: "rectangle",
                            payload: #""rect":{"x":-1048576,"y":1.25,"width":2097152,"height":-3}"#,
                            options: options)
    }

    private var ellipseShapeCommand: String {
        let options = labOptionsJSON(operation: "add", antialias: false, feather: "0", cornerRadius: "4")
        return labShapeJSON(shape: "ellipse",
                            payload: #""rect":{"x":0.25,"y":0.25,"width":0,"height":1}"#,
                            options: options)
    }

    private var polygonShapeCommand: String {
        let options = labOptionsJSON(operation: "subtract", antialias: true, feather: "1000", cornerRadius: "1000")
        return labShapeJSON(shape: "polygon",
                            payload: #""points":[{"x":-1,"y":-1},{"x":2,"y":-1},{"x":0,"y":3}]"#,
                            options: options)
    }

    private var intersectRectangleCommand: String {
        let options = labOptionsJSON(operation: "intersect", antialias: false, feather: "1", cornerRadius: "0.5")
        return labShapeJSON(shape: "rectangle",
                            payload: #""rect":{"x":-5,"y":-6,"width":4,"height":7}"#,
                            options: options)
    }

    private func selectCommand(_ name: String) -> String {
        #"{"tag":"labSelectCommand","command":""# + name + "\"}"
    }

    func testLabSelectionShapeAndCommandLiteralsRoundtripWithExactKeysAndOwnedValues() throws {
        let rows = [
            success(rectangleShapeCommand, ordinal: 0),
            success(ellipseShapeCommand, ordinal: 1),
            success(polygonShapeCommand, ordinal: 2),
            success(intersectRectangleCommand, ordinal: 3),
            success(selectCommand("all"), ordinal: 4),
            success(selectCommand("none"), ordinal: 5),
            success(selectCommand("invert"), ordinal: 6),
        ].joined(separator: ",")
        let decoded = try decodeAndEncode(document(rows))
        XCTAssertEqual(decoded.records.count, 7)

        guard case .success(.labSelection(.shape(.rectangle(let rectangle), let rectOptions)), .none) = decoded.records[0].outcome else {
            return XCTFail("Expected rectangle lab selection with none binding")
        }
        XCTAssertEqual(rectangle, .init(x: -1048576, y: 1.25, width: 2097152, height: -3))
        XCTAssertEqual(rectOptions.operation, .replace)
        XCTAssertEqual(rectOptions.antialias, true)
        XCTAssertEqual(rectOptions.feather, 2.5)
        XCTAssertEqual(rectOptions.cornerRadius, 0)

        guard case .success(.labSelection(.shape(.ellipse(let ellipse), let ellipseOptions)), .none) = decoded.records[1].outcome else {
            return XCTFail("Expected ellipse lab selection with none binding")
        }
        XCTAssertEqual(ellipse, .init(x: 0.25, y: 0.25, width: 0, height: 1))
        XCTAssertEqual(ellipseOptions.operation, .add)
        XCTAssertEqual(ellipseOptions.antialias, false)
        XCTAssertEqual(ellipseOptions.feather, 0)
        XCTAssertEqual(ellipseOptions.cornerRadius, 4)

        guard case .success(.labSelection(.shape(.polygon(let points), let polygonOptions)), .none) = decoded.records[2].outcome else {
            return XCTFail("Expected polygon lab selection with none binding")
        }
        XCTAssertEqual(points, [.init(x: -1, y: -1), .init(x: 2, y: -1), .init(x: 0, y: 3)])
        XCTAssertEqual(polygonOptions.operation, .subtract)
        XCTAssertEqual(polygonOptions.antialias, true)
        XCTAssertEqual(polygonOptions.feather, 1000)
        XCTAssertEqual(polygonOptions.cornerRadius, 1000)

        guard case .success(.labSelection(.shape(.rectangle(let intersectRect), let intersectOptions)), .none) = decoded.records[3].outcome else {
            return XCTFail("Expected intersect rectangle lab selection")
        }
        XCTAssertEqual(intersectRect, .init(x: -5, y: -6, width: 4, height: 7))
        XCTAssertEqual(intersectOptions.operation, .intersect)
        XCTAssertEqual(intersectOptions.antialias, false)
        XCTAssertEqual(intersectOptions.feather, 1)
        XCTAssertEqual(intersectOptions.cornerRadius, 0.5)

        guard case .success(.labSelection(.command(.all)), .none) = decoded.records[4].outcome,
              case .success(.labSelection(.command(.none)), .none) = decoded.records[5].outcome,
              case .success(.labSelection(.command(.invert)), .none) = decoded.records[6].outcome else {
            return XCTFail("Expected lab selection commands with none bindings")
        }

        let encoded = try RecorderFileCodec.encode(decoded)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(root["version"] as? Int, 15)
        XCTAssertEqual((root["symbols"] as? [Any])?.count, 0)
        let encodedRows = try XCTUnwrap(root["records"] as? [[String: Any]])
        guard encodedRows.count == 7 else { return XCTFail("Encoder must retain all seven commands") }
        let shapeTags = ["rectangle", "ellipse", "polygon", "rectangle"]
        for (index, row) in encodedRows.enumerated() {
            let binding = try XCTUnwrap(row["binding"] as? [String: Any])
            XCTAssertEqual(Set(binding.keys), Set(["kind"]))
            XCTAssertEqual(binding["kind"] as? String, "none")
            let command = try XCTUnwrap(row["command"] as? [String: Any])
            if index < 4 {
                XCTAssertEqual(Set(command.keys), Set(["tag", "shape", "options"]))
                XCTAssertEqual(command["tag"] as? String, "labSelectionShape")
                let options = try XCTUnwrap(command["options"] as? [String: Any])
                XCTAssertEqual(Set(options.keys), Set(["operation", "antialias", "feather", "cornerRadius"]))
                let shape = try XCTUnwrap(command["shape"] as? [String: Any])
                XCTAssertEqual(shape["tag"] as? String, shapeTags[index])
                if index == 2 {
                    XCTAssertEqual(Set(shape.keys), Set(["tag", "points"]))
                    let points = try XCTUnwrap(shape["points"] as? [[String: Any]])
                    XCTAssertEqual(points.count, 3)
                    for point in points { XCTAssertEqual(Set(point.keys), Set(["x", "y"])) }
                } else {
                    XCTAssertEqual(Set(shape.keys), Set(["tag", "rect"]))
                    let rect = try XCTUnwrap(shape["rect"] as? [String: Any])
                    XCTAssertEqual(Set(rect.keys), Set(["x", "y", "width", "height"]))
                }
            } else {
                XCTAssertEqual(Set(command.keys), Set(["tag", "command"]))
                XCTAssertEqual(command["tag"] as? String, "labSelectCommand")
                XCTAssertEqual(command["command"] as? String, ["all", "none", "invert"][index - 4])
            }
        }
    }

    func testLegacyVersionsRejectLabSelectionTagsAndVersion15RequiresSuccessfulNewCommand() throws {
        let shapeRow = success(rectangleShapeCommand)
        let commandRow = success(selectCommand("all"))
        for version in 1...14 {
            decodeRejects(document(shapeRow, version: version), reason: "recording version 15")
            decodeRejects(document(commandRow, version: version), reason: "recording version 15")
        }
        let ordinary = success(#"{"tag":"scale","width":2,"height":2}"#)
        let mixedOrdinary = ordinary + "," + success(selectCommand("invert"), ordinal: 1)
        XCTAssertNoThrow(try decodeAndEncode(document(mixedOrdinary, version: 15)))
        decodeRejects(document(ordinary, version: 15), reason: "Version 15 requires a successful Lab selection command")
        let onlyFailure = #"{"ordinal":0,"outcome":"failure","reason":"nope"}"#
        decodeRejects(document(onlyFailure, version: 15), reason: "Version 15 requires a successful Lab selection command")
    }

    func testNewLabSelectionCommandsRejectWrongBindingsButStillRequireValidReferences() throws {
        let channelSymbol = #"{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","description":{"name":"Channel","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1}}}"#
        let pixelSymbol = channelSymbol.replacingOccurrences(of: #""kind":"channel""#, with: #""kind":"pixel""#)
        let bindings = [
            (#"{"kind":"layer","symbol":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}"#, pixelSymbol),
            (#"{"kind":"channel","symbol":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}"#, channelSymbol),
            (#"{"kind":"lab","symbol":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","role":"lightness","precision":"u8","uuid":"cccccccc-cccc-cccc-cccc-cccccccccccc"}"#, channelSymbol),
        ]
        for command in [rectangleShapeCommand, selectCommand("invert")] {
            let row = success(command)
            XCTAssertNoThrow(try decodeAndEncode(document(row)))
            for (binding, symbols) in bindings {
                let changed = success(command, binding: binding)
                XCTAssertNotEqual(changed, row)
                decodeRejects(document(changed, symbols: symbols), reason: "Lab selections require none binding")
            }
            let missing = #"{"kind":"layer","symbol":"dddddddd-dddd-dddd-dddd-dddddddddddd"}"#
            decodeRejects(document(success(command, binding: missing)), reason: "Missing symbol must refuse")
        }
    }

    func testMalformedLabSelectionMatrixRejectsWhileValidBaselineDecodes() throws {
        let validShape = rectangleShapeCommand
        XCTAssertNoThrow(try decodeAndEncode(document(success(validShape))))

        let shapeWithNullRect = mutateNestedObject(in: validShape, path: ["shape"]) { shape in
            shape["rect"] = NSNull()
        }
        decodeRejects(document(success(shapeWithNullRect)), reason: "Expected a JSON object")

        let shapeWithWrongRectType = mutateNestedObject(in: validShape, path: ["shape"]) { shape in
            shape["rect"] = "bad"
        }
        decodeRejects(document(success(shapeWithWrongRectType)), reason: "Expected a JSON object")

        let shapeMissingRectWidth = mutateNestedObject(in: validShape, path: ["shape", "rect"]) { rect in
            rect.removeValue(forKey: "width")
        }
        decodeRejects(document(success(shapeMissingRectWidth)), reason: "Missing or unknown object fields")

        let shapeExtraRectKey = mutateNestedObject(in: validShape, path: ["shape", "rect"]) { rect in
            rect["extra"] = 1
        }
        decodeRejects(document(success(shapeExtraRectKey)), reason: "Missing or unknown object fields")

        let unknownShape = mutateNestedObject(in: validShape, path: ["shape"]) { shape in
            shape["tag"] = "star"
        }
        decodeRejects(document(success(unknownShape)), reason: "Unknown Lab selection shape")

        let unknownOperation = mutateNestedObject(in: validShape, path: ["options"]) { options in
            options["operation"] = "xor"
        }
        decodeRejects(document(success(unknownOperation)), reason: "Unknown selection operation")

        let unknownCommand = mutateNestedObject(in: selectCommand("all"), path: []) { command in
            command["command"] = "toggle"
        }
        decodeRejects(document(success(unknownCommand)), reason: "Unknown Lab selection command")

        let coordinateOverflow = mutateNestedObject(in: validShape, path: ["shape", "rect"]) { rect in
            rect["x"] = -1048576.1
        }
        decodeRejects(document(success(coordinateOverflow)), reason: "invalid or empty bounds")

        let endpointOverflow = mutateNestedObject(in: validShape, path: ["shape", "rect"]) { rect in
            rect["x"] = 1048576
            rect["width"] = 0.1
        }
        decodeRejects(document(success(endpointOverflow)), reason: "invalid or empty bounds")

        let emptyIntegerRectangle = mutateNestedObject(in: validShape, path: ["shape", "rect"]) { rect in
            rect["x"] = 5
            rect["y"] = 6
            rect["width"] = 0
            rect["height"] = 0
        }
        decodeRejects(document(success(emptyIntegerRectangle)), reason: "invalid or empty bounds")

        let validFractional = mutateNestedObject(in: validShape, path: ["shape", "rect"]) { rect in
            rect["x"] = 0.25
            rect["y"] = 0.25
            rect["width"] = 0
            rect["height"] = 1
        }
        XCTAssertNoThrow(try decodeAndEncode(document(success(validFractional))),
                         "Fractional origin with raw zero width can still span a positive integer interval")

        let invalidPointJSON = mutateNestedObject(in: polygonShapeCommand, path: ["shape"]) { shape in
            shape["points"] = [["x": 0, "y": 0], ["x": 1, "y": 1], ["x": 1_048_576.1, "y": 2]]
        }
        decodeRejects(document(success(invalidPointJSON)), reason: "Out-of-range polygon coordinate")
        let nullOption = mutateNestedObject(in: validShape, path: ["options"]) { $0["antialias"] = NSNull() }
        decodeRejects(document(success(nullOption)), reason: "Null Boolean must refuse")
        let missingOptions = mutateObject(validShape, key: "options") { $0.removeValue(forKey: "options") }
        decodeRejects(document(success(missingOptions)), reason: "Required options must be present")
        let extraMode = mutateObject(validShape, key: "mode") { $0["mode"] = "rgb" }
        decodeRejects(document(success(extraMode)), reason: "Closed command schema rejects mode")
        let extraOrdinaryOption = mutateNestedObject(in: validShape, path: ["options"]) { $0["threshold"] = 0.5 }
        decodeRejects(document(success(extraOrdinaryOption)), reason: "Ordinary-only options must refuse")
        let nullCommand = mutateObject(selectCommand("all"), key: "command") { $0["command"] = NSNull() }
        decodeRejects(document(success(nullCommand)), reason: "Null command must refuse")
        let extraCommandKey = mutateObject(selectCommand("all"), key: "options") { $0["options"] = [String: Any]() }
        decodeRejects(document(success(extraCommandKey)), reason: "Simple commands have no options")
        let invalidOptions: [(String, Any)] = [
            ("feather", -0.1), ("feather", 1000.1), ("cornerRadius", -1), ("cornerRadius", 1001),
        ]
        for (field, badValue) in invalidOptions {
            let mutated = mutateNestedObject(in: validShape, path: ["options"]) { options in
                options[field] = badValue
            }
            decodeRejects(document(success(mutated)), reason: "0...1000")
        }
    }

    func testPolygonCountsAndSharedPointBudgetBoundaries() throws {
        func polygonCommand(pointCount: Int) -> String {
            let pointRows: [String] = (0..<pointCount).map { index -> String in
                "{\"x\":\(index),\"y\":\(index % 3)}"
            }
            let points = pointRows.joined(separator: ",")
            let options = labOptionsJSON(operation: "replace", antialias: true, feather: "0", cornerRadius: "0")
            return labShapeJSON(shape: "polygon", payload: #""points":["# + points + "]", options: options)
        }
        func ordinaryPolygon(pointCount: Int, ordinal: Int) -> String {
            let pointRows: [String] = (0..<pointCount).map { index -> String in
                "{\"x\":\(index),\"y\":\(index % 5)}"
            }
            let points = pointRows.joined(separator: ",")
            let command = #"{"tag":"selectionShape","shape":{"tag":"polygon","points":["# + points + #"]},"options":{"operation":"replace","antialias":true,"feather":0,"cornerRadius":0,"threshold":0,"contiguous":true,"sampleMerged":true}}"#
            return success(command, ordinal: ordinal)
        }
        func strokeCommand(pointCount: Int, ordinal: Int) -> String {
            let extra = max(0, pointCount - 1)
            let batches: String
            if extra == 0 {
                batches = "[]"
            } else {
                let sample = #"{"x":0,"y":0,"pressure":0.5,"xTilt":0,"yTilt":0,"timeMilliseconds":0}"#
                batches = "[[" + Array(repeating: sample, count: extra).joined(separator: ",") + "]]"
            }
            let symbolJSON = #"{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1}}}"#
            _ = symbolJSON
            let command = #"{"tag":"completeStroke","settings":{"tool":"pencil","size":2,"opacity":1,"red":0,"green":0,"blue":0,"pressureSize":false,"antiErase":false},"facts":{"brush":{"name":"B","isInternal":false},"fingerprint":"0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"},"first":{"x":0,"y":0,"pressure":0.5,"xTilt":0,"yTilt":0,"timeMilliseconds":0},"batches":"# + batches + "}"
            return success(command, binding: #"{"kind":"layer","symbol":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"}"#, ordinal: ordinal)
        }

        XCTAssertNoThrow(try decodeAndEncode(document(success(polygonCommand(pointCount: 3)))))
        XCTAssertNoThrow(try decodeAndEncode(document(success(polygonCommand(pointCount: 65536)))))
        decodeRejects(document(success(polygonCommand(pointCount: 2))), reason: "point count")
        decodeRejects(document(success(polygonCommand(pointCount: 65537))), reason: "oversized array")

        let pixelSymbol = #"{"id":"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":1,"height":1}}}"#
        let boundaryRows = ordinaryPolygon(pointCount: 50_000, ordinal: 0) + "," + strokeCommand(pointCount: 1, ordinal: 1) + "," + success(polygonCommand(pointCount: 49_999), ordinal: 2)
        XCTAssertNoThrow(try decodeAndEncode(document(boundaryRows, symbols: pixelSymbol, version: 15)))

        let overRows = ordinaryPolygon(pointCount: 50_000, ordinal: 0) + "," + strokeCommand(pointCount: 1, ordinal: 1) + "," + success(polygonCommand(pointCount: 50_000), ordinal: 2)
        decodeRejects(document(overRows, symbols: pixelSymbol, version: 15), reason: "point count")
    }

    func testSemanticBridgeAndNativeInitializerPreserveSignedGeometryAndOptions() throws {
        let rect = CGRect(x: -10.5, y: 4.25, width: -3.0, height: -2.0)
        let options = EngineSession.SelectOptions(operation: .subtract, antialias: false, feather: 1.5, cornerRadius: 2.25,
                                                  threshold: 0.75, contiguous: false, sampleMerged: true)
        let command = try RecorderLabSelectionCommand(shape: .rectangle(rect), options: options)
        guard case .shape(.rectangle(let stored), let storedOptions) = command else {
            return XCTFail("Expected rectangle lab selection command")
        }
        XCTAssertEqual(stored.x, -10.5)
        XCTAssertEqual(stored.y, 4.25)
        XCTAssertEqual(stored.width, -3.0, "Native initializer must preserve signed raw width")
        XCTAssertEqual(stored.height, -2.0, "Native initializer must preserve signed raw height")
        XCTAssertEqual(storedOptions.operation, .subtract)
        XCTAssertEqual(storedOptions.antialias, false)
        XCTAssertEqual(storedOptions.feather, 1.5)
        XCTAssertEqual(storedOptions.cornerRadius, 2.25)

        let semantic = SemanticImageCommand.labSelection(command)
        let fileCommand = try RecorderFileCommand(semantic)
        guard case .labSelection(let fromSemantic) = fileCommand,
              case .shape(.rectangle(let semanticRect), let semanticOptions) = fromSemantic else {
            return XCTFail("Semantic to file conversion lost lab selection")
        }
        XCTAssertEqual(semanticRect, stored)
        XCTAssertEqual(semanticOptions, storedOptions)

        let file = RecorderFileValue(recordingID: recordingID, name: "Lab", origin: origin, symbols: [],
                                     records: [.init(ordinal: 0, outcome: .success(fileCommand, .none))])
        let prepared = try RecorderFileSemanticBridge.prepare(file)
        let preparedResolution = try XCTUnwrap(prepared.log.records.first?.resolution)
        guard case .success(.labSelection(let preparedCommand)) = preparedResolution,
              case .shape(.rectangle(let preparedRect), let preparedOptions) = preparedCommand else {
            return XCTFail("Prepared semantic record lost lab selection")
        }
        XCTAssertEqual(preparedRect, stored)
        XCTAssertEqual(preparedOptions, storedOptions)

        let invert = try RecorderLabSelectionCommand(command: .invert)
        let invertFile = try RecorderFileCommand(SemanticImageCommand.labSelection(invert))
        guard case .labSelection(.command(.invert)) = invertFile else {
            return XCTFail("Lab selection command conversion lost invert command")
        }
    }

    func testOlderVersionOneOrdinarySelectionShapeRemainsFullyOwnedAndEncodesVersionOne() throws {
        let options = #"{"operation":"intersect","antialias":false,"feather":-2.5,"cornerRadius":0,"threshold":1.5,"contiguous":false,"sampleMerged":true}"#
        let row = #"{"ordinal":0,"outcome":"success","command":{"tag":"selectionShape","shape":{"tag":"rectangle","rect":{"x":-2,"y":3,"width":4,"height":5}},"options":"# + options + #"},"binding":{"kind":"none"}}"#
        let decoded = try decodeAndEncode(document(row, version: 1))
        guard case .success(.selectionShape(.rectangle(let rect), let decodedOptions), .none) = decoded.records[0].outcome else {
            return XCTFail("Expected ordinary selection shape")
        }
        XCTAssertEqual(rect, .init(x: -2, y: 3, width: 4, height: 5))
        XCTAssertEqual(decodedOptions, .init(operation: .intersect, antialias: false, feather: -2.5, cornerRadius: 0,
                                             threshold: 1.5, contiguous: false, sampleMerged: true))
        let encoded = String(decoding: try RecorderFileCodec.encode(decoded), as: UTF8.self)
        XCTAssertTrue(encoded.contains(#""version":1"#), "Ordinary v1 selection must still encode as version 1")
        XCTAssertTrue(encoded.contains(#""threshold":1.5"#))
        XCTAssertTrue(encoded.contains(#""contiguous":false"#))
        XCTAssertTrue(encoded.contains(#""sampleMerged":true"#))
    }
}
