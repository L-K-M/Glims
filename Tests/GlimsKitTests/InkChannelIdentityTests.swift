import XCTest
import Foundation
import CGlimsEngine
@testable import GlimsKit

final class InkChannelIdentityTests: XCTestCase {
    private let knownUUID: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
         0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10)
    private let knownUUIDString = "01020304-0506-0708-090A-0B0C0D0E0F10"

    private func makeIdentity(colorMode: EngineSession.ColorMode = .cmyk,
                              role: EngineSession.InkRole = .cyan,
                              ordinal: UInt32 = 0,
                              count: UInt32 = 4,
                              uuid: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                     UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)? = nil,
                              structSize: UInt32? = nil) -> GlimsInkChannelIdentity {
        var out = GlimsInkChannelIdentity()
        out.struct_size = structSize ?? UInt32(MemoryLayout<GlimsInkChannelIdentity>.size)
        out.color_mode = colorMode.rawValue
        out.role = role.rawValue
        out.ordinal = ordinal
        out.count = count
        out.uuid = uuid ?? knownUUID
        return out
    }

    private func assertMalformed(_ out: GlimsInkChannelIdentity,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) {
        XCTAssertThrowsError(try EngineSession.decodeInkChannelIdentity(from: out), file: file, line: line) { error in
            guard let engineError = error as? EngineSession.EngineError else {
                return XCTFail("Expected EngineError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(engineError.status, Int32(GLIMS_STATUS_FAILED.rawValue), file: file, line: line)
        }
    }

    func testInkRoleRawValuesMatchFacade() {
        XCTAssertEqual(EngineSession.InkRole.unspecified.rawValue, GLIMS_INK_ROLE_UNSPECIFIED.rawValue)
        XCTAssertEqual(EngineSession.InkRole.cyan.rawValue, GLIMS_INK_ROLE_CYAN.rawValue)
        XCTAssertEqual(EngineSession.InkRole.magenta.rawValue, GLIMS_INK_ROLE_MAGENTA.rawValue)
        XCTAssertEqual(EngineSession.InkRole.yellow.rawValue, GLIMS_INK_ROLE_YELLOW.rawValue)
        XCTAssertEqual(EngineSession.InkRole.black.rawValue, GLIMS_INK_ROLE_BLACK.rawValue)
        XCTAssertNil(EngineSession.InkRole(rawValue: 99))
    }

    func testDecodeCMYKChannelsWithLiteralUUIDMapping() throws {
        let cases: [(EngineSession.InkRole, UInt32)] = [
            (.cyan, 0),
            (.magenta, 1),
            (.yellow, 2),
            (.black, 3)
        ]
        for (role, ordinal) in cases {
            let out = makeIdentity(colorMode: .cmyk, role: role, ordinal: ordinal, count: 4)
            let identity = try EngineSession.decodeInkChannelIdentity(from: out)
            XCTAssertEqual(identity.colorMode, .cmyk)
            XCTAssertEqual(identity.role, role)
            XCTAssertEqual(identity.ordinal, ordinal)
            XCTAssertEqual(identity.count, 4)
            XCTAssertEqual(identity.uuid.uuidString, knownUUIDString)
        }
    }

    func testDecodeMultichannelCountBoundaries() throws {
        let minOut = makeIdentity(colorMode: .multichannel, role: .unspecified, ordinal: 0, count: 1)
        let minIdentity = try EngineSession.decodeInkChannelIdentity(from: minOut)
        XCTAssertEqual(minIdentity.colorMode, .multichannel)
        XCTAssertEqual(minIdentity.role, .unspecified)
        XCTAssertEqual(minIdentity.ordinal, 0)
        XCTAssertEqual(minIdentity.count, 1)
        XCTAssertEqual(minIdentity.uuid.uuidString, knownUUIDString)

        let maxOut = makeIdentity(colorMode: .multichannel, role: .unspecified, ordinal: 31, count: 32)
        let maxIdentity = try EngineSession.decodeInkChannelIdentity(from: maxOut)
        XCTAssertEqual(maxIdentity.colorMode, .multichannel)
        XCTAssertEqual(maxIdentity.role, .unspecified)
        XCTAssertEqual(maxIdentity.ordinal, 31)
        XCTAssertEqual(maxIdentity.count, 32)
        XCTAssertEqual(maxIdentity.uuid.uuidString, knownUUIDString)
    }

    func testMalformedStructSize() {
        assertMalformed(makeIdentity(structSize: 0))
        assertMalformed(makeIdentity(structSize: .max))
        let small = makeIdentity(structSize: UInt32(MemoryLayout<GlimsInkChannelIdentity>.size) - 1)
        assertMalformed(small)
        let large = makeIdentity(structSize: UInt32(MemoryLayout<GlimsInkChannelIdentity>.size) + 1)
        assertMalformed(large)
    }

    func testMalformedColorMode() {
        var out = makeIdentity()
        out.color_mode = EngineSession.ColorMode.rgb.rawValue
        assertMalformed(out)

        out.color_mode = EngineSession.ColorMode.grayscale.rawValue
        assertMalformed(out)

        out.color_mode = EngineSession.ColorMode.indexed.rawValue
        assertMalformed(out)

        out.color_mode = EngineSession.ColorMode.unknown.rawValue
        assertMalformed(out)

        out.color_mode = 999
        assertMalformed(out)
    }

    func testMalformedCMYKRoleOrderAndCount() {
        assertMalformed(makeIdentity(colorMode: .cmyk, role: .cyan, ordinal: 0, count: 3))
        assertMalformed(makeIdentity(colorMode: .cmyk, role: .cyan, ordinal: 0, count: 5))
        assertMalformed(makeIdentity(colorMode: .cmyk, role: .cyan, ordinal: 4, count: 4))
        assertMalformed(makeIdentity(colorMode: .cmyk, role: .cyan, ordinal: .max, count: 4))
        assertMalformed(makeIdentity(colorMode: .cmyk, role: .magenta, ordinal: 0, count: 4))
        assertMalformed(makeIdentity(colorMode: .cmyk, role: .unspecified, ordinal: 0, count: 4))
        assertMalformed(makeIdentity(colorMode: .cmyk, role: .black, ordinal: 2, count: 4))
    }

    func testMalformedMultichannelRoleOrdinalAndCount() {
        assertMalformed(makeIdentity(colorMode: .multichannel, role: .cyan, ordinal: 0, count: 1))
        assertMalformed(makeIdentity(colorMode: .multichannel, role: .unspecified, ordinal: 0, count: 0))
        assertMalformed(makeIdentity(colorMode: .multichannel, role: .unspecified, ordinal: 0, count: 33))
        assertMalformed(makeIdentity(colorMode: .multichannel, role: .unspecified, ordinal: 1, count: 1))
        assertMalformed(makeIdentity(colorMode: .multichannel, role: .unspecified, ordinal: 32, count: 32))
        assertMalformed(makeIdentity(colorMode: .multichannel, role: .unspecified, ordinal: 0, count: .max))
        assertMalformed(makeIdentity(colorMode: .multichannel, role: .unspecified, ordinal: .max, count: 32))
    }

    func testMalformedUUID() {
        let zeroUUID: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                       UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        assertMalformed(makeIdentity(uuid: zeroUUID))

        // Non-zero bytes accepted without RFC version/variant restrictions.
        let nonRfcUUID: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                         UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
            (0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
             0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00)
        XCTAssertNoThrow(try EngineSession.decodeInkChannelIdentity(from: makeIdentity(uuid: nonRfcUUID)))
        // A nonzero final byte is sufficient; all 16 bytes participate in the zero check.
        XCTAssertNoThrow(try EngineSession.decodeInkChannelIdentity(from: makeIdentity(
            uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))))
    }

    func testMalformedUnknownRoleValue() {
        var out = makeIdentity()
        out.role = 99
        assertMalformed(out)
    }

}
