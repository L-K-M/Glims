import XCTest
@testable import GlimsKit

final class RecorderLabValuesTests: XCTestCase {
    private let symbol = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private let axisID = UUID(uuidString: "01234567-89ab-cdef-0123-456789abcdef")!
    private let nilID = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
    private func identity(_ role: RecorderLabIdentity.Role = .a, _ precision: RecorderLabIdentity.Precision = .u16) -> RecorderLabIdentity {
        .init(role: role, precision: precision, uuid: axisID)
    }
    private func file(_ command: RecorderFileCommand, identity: RecorderLabIdentity? = nil) -> RecorderFileValue {
        .init(recordingID: UUID(), name: "Lab recording", origin: .init(imageLabel: "Lab.xcf", initialWidth: 7, initialHeight: 9),
              symbols: [.init(id: symbol, description: .init(name: "a*", kind: .channel, ancestors: [], siblingIndex: 1,
                                                            bounds: .init(x: 0, y: 0, width: 7, height: 9)))],
              records: [.init(ordinal: 0, outcome: .success(command, .lab(symbol: symbol, identity: identity ?? self.identity())))])
    }
    private func literal(_ command: String = #"{"tag":"fillLab","value":-0.5,"opacity":0.75}"#,
                         role: String = "a", precision: String = "u16", version: Int = 13) -> Data {
        Data("""
        {"format":"ch.lkmc.Glims.recording","version":\(version),"recordingID":"11111111-2222-3333-4444-555555555555","name":"Lab recording",
        "origin":{"imageLabel":"Lab.xcf","initialWidth":7,"initialHeight":9},
        "symbols":[{"id":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","description":{"name":"a*","kind":"channel","ancestors":[],"siblingIndex":1,"bounds":{"x":0,"y":0,"width":7,"height":9}}}],
        "records":[{"ordinal":0,"outcome":"success","command":\(command),"binding":{"kind":"lab","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","role":"\(role)","precision":"\(precision)","uuid":"01234567-89ab-cdef-0123-456789abcdef"}}]}
        """.utf8)
    }

    func testPhysicalIdentityDoesNotAutomaticallyBindDifferentDocuments() throws {
        let source = identity()
        let other = RecorderLabIdentity(role: .a, precision: .u16, uuid: UUID())
        XCTAssertTrue(source.permitsExplicitBinding(to: other))
        XCTAssertFalse(source.matchesInOwningDocument(other))
        XCTAssertTrue(source.matchesInOwningDocument(source))
        XCTAssertFalse(source.permitsExplicitBinding(to: identity(.b)))
        XCTAssertFalse(source.permitsExplicitBinding(to: identity(.a, .float)))
        XCTAssertFalse(RecorderLabIdentity(role: .a, precision: .u16, uuid: nilID).isValid)
        for role in EngineSession.LabAxisRole.allCases {
            let axis = EngineSession.LabAxis(id: 99, role: role, isSelected: true, uuid: axisID, name: "renamable")
            for precision: EngineSession.ColorComponent in [.u8, .u16, .float] {
                let recorded = try RecorderLabIdentity(axis: axis, component: precision)
                XCTAssertEqual(recorded.nativeRole, role)
                XCTAssertEqual(recorded.uuid, axisID)
            }
            for precision: EngineSession.ColorComponent in [.unknown, .u32, .half, .double] {
                XCTAssertThrowsError(try RecorderLabIdentity(axis: axis, component: precision))
            }
        }
    }

    func testLiteralFillUsesPhysicalSignedValueAndVersion13() throws {
        let value = try RecorderFileCodec.decode(literal())
        guard case .success(.fillLab(let fill), .lab(let id, let target)) = value.records[0].outcome else {
            return XCTFail("Expected physical Lab command")
        }
        XCTAssertEqual(id, symbol); XCTAssertEqual(target, identity())
        XCTAssertEqual(fill.value, -0.5); XCTAssertEqual(fill.opacity, 0.75)
        let encoded = try RecorderFileCodec.encode(value)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 13)
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), value)
        for old in 1...12 { XCTAssertThrowsError(try RecorderFileCodec.decode(literal(version: old))) }
    }

    func testFillRangeDependsOnPhysicalRoleAndPrecision() throws {
        for (role, low, high) in [(RecorderLabIdentity.Role.lightness, 0.0, 100.0), (.a, -128.0, 127.0), (.b, -128.0, 127.0)] {
            for precision in RecorderLabIdentity.Precision.allCases {
                let target = identity(role, precision)
                for value in [low, high, (low + high) / 2] {
                    XCTAssertNoThrow(try RecorderFileCodec.encode(file(.fillLab(.init(value: value, opacity: 1)), identity: target)))
                }
                for value in [low - 1, high + 1] {
                    let out = file(.fillLab(.init(value: value, opacity: 1)), identity: target)
                    if precision == .float { XCTAssertNoThrow(try RecorderFileCodec.encode(out)) }
                    else { XCTAssertThrowsError(try RecorderFileCodec.encode(out)) }
                }
            }
        }
        for (value, opacity) in [(Double.nan, 1.0), (.infinity, 1), (0, .nan), (0, -0.1), (0, 1.1), (Double(Float.greatestFiniteMagnitude) * 2, 1)] {
            XCTAssertThrowsError(try RecorderFileCodec.encode(file(.fillLab(.init(value: value, opacity: opacity)), identity: identity(.a, .float))))
        }
    }

    func testExactCurvesTableAndSemanticBridge() throws {
        let table = (0..<256).map { Double(($0 * 37) % 256) / 255 }
        let command = "{\"tag\":\"applyLabCurves\",\"samples\":[" + table.map(String.init(describing:)).joined(separator: ",") + "]}"
        let decoded = try RecorderFileCodec.decode(literal(command))
        guard case .success(.applyLabCurves(let value), _) = decoded.records[0].outcome else { return XCTFail() }
        XCTAssertEqual(value.samples, table)
        let encoded = try RecorderFileCodec.encode(decoded)
        XCTAssertEqual(try RecorderFileCodec.decode(encoded), decoded)
        let semantic = SemanticImageCommand.applyLabCurves(.init(samples: table))
        XCTAssertEqual(try RecorderFileCommand(semantic), .applyLabCurves(.init(samples: table)))
        for bad in [Array(table.dropLast()), table + [0], Array(repeating: Double.nan, count: 256), Array(repeating: -0.01, count: 256)] {
            XCTAssertThrowsError(try RecorderFileCodec.encode(file(.applyLabCurves(.init(samples: bad)))))
        }
    }

    func testUnknownFieldsRolesAndMismatchedBindingsAreRejected() throws {
        for role in ["cyan", "unspecified", "L", ""] { XCTAssertThrowsError(try RecorderFileCodec.decode(literal(role: role))) }
        for precision in ["half", "u32", "double", ""] { XCTAssertThrowsError(try RecorderFileCodec.decode(literal(precision: precision))) }
        let base = String(decoding: literal(), as: UTF8.self)
        for invalid in [base.replacingOccurrences(of: "\"kind\":\"lab\"", with: "\"kind\":\"ink\""),
                        base.replacingOccurrences(of: "\"tag\":\"fillLab\"", with: "\"tag\":\"editInk\""),
                        base.replacingOccurrences(of: "\"opacity\":0.75", with: "\"opacity\":true"),
                        base.replacingOccurrences(of: "\"opacity\":0.75", with: "\"opacity\":0.75,\"nativeAxis\":42") ] {
            XCTAssertThrowsError(try RecorderFileCodec.decode(Data(invalid.utf8)))
        }
        var rows = file(.fillLab(.init(value: 1, opacity: 1))).records
        rows.append(.init(ordinal: 1, outcome: .success(.fillLab(.init(value: 1, opacity: 1)), .lab(symbol: symbol, identity: identity(.b)))))
        let original = file(.fillLab(.init(value: 1, opacity: 1)))
        let mixed = RecorderFileValue(recordingID: original.recordingID, name: original.name, origin: original.origin, symbols: original.symbols, records: rows)
        XCTAssertThrowsError(try RecorderFileCodec.encode(mixed))
        let crossMode = RecorderFileValue(recordingID: original.recordingID, name: original.name,
            origin: original.origin, symbols: original.symbols, records: [original.records[0],
                .init(ordinal: 1, outcome: .success(.editInk(.init(operation: .fill, intensity: 0.5, opacity: 1)),
                      .ink(symbol: symbol, identity: .init(mode: .cmyk, role: .cyan, uuid: axisID))))])
        XCTAssertThrowsError(try RecorderFileCodec.encode(crossMode))
        let noLab = base.replacingOccurrences(of: #"{"tag":"fillLab","value":-0.5,"opacity":0.75}"#,
            with: #"{"tag":"selectCommand","command":"all","radius":0}"#)
        let generic = noLab.replacingOccurrences(of:
            #"{"kind":"lab","symbol":"aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee","role":"a","precision":"u16","uuid":"01234567-89ab-cdef-0123-456789abcdef"}"#,
            with: #"{"kind":"none"}"#)
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(generic.utf8))) { error in
            XCTAssertEqual(error as? RecorderFileError, .invalid("Version 13 requires a successful Lab command."))
        }
        XCTAssertNoThrow(try RecorderFileCodec.decode(Data(generic.replacingOccurrences(of: "\"version\":13", with: "\"version\":1").utf8)))
    }
}
