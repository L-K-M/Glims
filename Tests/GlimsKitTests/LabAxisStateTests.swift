import CGlimsEngine
import XCTest
@testable import GlimsKit

final class LabAxisStateTests: XCTestCase {
    private func fixture(component: UInt32 = 1) -> GlimsLabAxes {
        var state = GlimsLabAxes()
        state.struct_size = UInt32(MemoryLayout<GlimsLabAxes>.size)
        state.component = component
        state.count = 3
        func axis(_ index: UInt32, name: String) -> GlimsLabAxisInfo {
            var row = GlimsLabAxisInfo()
            row.id = Int32(index + 41)
            row.role = index
            row.selected = index == 1 ? 1 : 0
            withUnsafeMutableBytes(of: &row.uuid) { $0[15] = UInt8(index + 1) }
            withUnsafeMutableBytes(of: &row.name) { $0.copyBytes(from: name.utf8) }
            return row
        }
        state.axes = (axis(0, name: "Lightness"), axis(1, name: "同じ"), axis(2, name: "同じ"))
        return state
    }

    private func assertMalformed(_ state: GlimsLabAxes, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try EngineSession.decodeLabAxes(from: state), file: file, line: line) {
            XCTAssertEqual(($0 as? EngineSession.EngineError)?.status,
                           Int32(GLIMS_STATUS_FAILED.rawValue), file: file, line: line)
        }
    }

    func testPhysicalAxesUseOwnedRolesAndDistinctIdentitiesDespiteDuplicateNames() throws {
        XCTAssertEqual(EngineSession.LabAxisRole.lightness.rawValue, GLIMS_LAB_AXIS_LIGHTNESS.rawValue)
        XCTAssertEqual(EngineSession.LabAxisRole.a.rawValue, GLIMS_LAB_AXIS_A.rawValue)
        XCTAssertEqual(EngineSession.LabAxisRole.b.rawValue, GLIMS_LAB_AXIS_B.rawValue)
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let decoded = try EngineSession.decodeLabAxes(from: fixture(component: component.rawValue))
            XCTAssertEqual(decoded.component, component)
            XCTAssertEqual(decoded.axes.map(\.id), [41, 42, 43])
            XCTAssertEqual(decoded.axes.map(\.role), [.lightness, .a, .b])
            XCTAssertEqual(decoded.axes.map(\.isSelected), [false, true, false])
            XCTAssertEqual(decoded.axes.map(\.name), ["Lightness", "同じ", "同じ"])
            XCTAssertEqual(decoded.axes.map { $0.uuid.uuidString }, [
                "00000000-0000-0000-0000-000000000001",
                "00000000-0000-0000-0000-000000000002",
                "00000000-0000-0000-0000-000000000003"])
        }
    }

    func testRejectsMalformedSizeCountAndComponent() {
        for size in [UInt32(0), UInt32(MemoryLayout<GlimsLabAxes>.size - 1),
                     UInt32(MemoryLayout<GlimsLabAxes>.size + 1), UInt32.max] {
            var out = fixture(); out.struct_size = size; assertMalformed(out)
        }
        for count in [UInt32(0), 1, 2, 4, .max] {
            var out = fixture(); out.count = count; assertMalformed(out)
        }
        for component in [UInt32(0), 3, 4, 6, .max] {
            assertMalformed(fixture(component: component))
        }
    }

    func testRejectsUnknownOrNoncanonicalRoles() {
        var out = fixture(); out.axes.0.role = 1; assertMalformed(out)
        out = fixture(); out.axes.1.role = 2; assertMalformed(out)
        out = fixture(); out.axes.2.role = UInt32.max; assertMalformed(out)
        out = fixture(); let first = out.axes.0; out.axes.0 = out.axes.1; out.axes.1 = first
        assertMalformed(out)
    }

    func testRejectsNonbooleanSelectionAndMissingOrRepeatedHandles() {
        var out = fixture(); out.axes.0.selected = 2; assertMalformed(out)
        out = fixture(); out.axes.1.selected = UInt32.max; assertMalformed(out)
        for id in [Int32(0), -1, Int32.min] {
            out = fixture(); out.axes.2.id = id; assertMalformed(out)
        }
        out = fixture(); out.axes.1.id = out.axes.0.id; assertMalformed(out)
    }

    func testRejectsMissingOrRepeatedDurableIdentity() {
        var out = fixture()
        withUnsafeMutableBytes(of: &out.axes.0.uuid) { $0.initializeMemory(as: UInt8.self, repeating: 0) }
        assertMalformed(out)
        out = fixture(); out.axes.2.uuid = out.axes.1.uuid; assertMalformed(out)
    }

    func testNamesAreBoundedUTF8AndNeverReadPastTheirArray() throws {
        var out = fixture()
        withUnsafeMutableBytes(of: &out.axes.1.name) { $0.initializeMemory(as: UInt8.self, repeating: 65) }
        assertMalformed(out) // No terminator in the fixed array.
        out = fixture()
        withUnsafeMutableBytes(of: &out.axes.1.name) { $0[0] = 0xc3; $0[1] = 0 }
        assertMalformed(out) // Truncated two-byte character.
        out = fixture()
        withUnsafeMutableBytes(of: &out.axes.1.name) {
            $0.initializeMemory(as: UInt8.self, repeating: 65); $0[255] = 0
        }
        XCTAssertEqual(try EngineSession.decodeLabAxes(from: out).axes[1].name.count, 255)
        out = fixture()
        withUnsafeMutableBytes(of: &out.axes.1.name) { $0[0] = 0 }
        XCTAssertEqual(try EngineSession.decodeLabAxes(from: out).axes[1].name, "")
    }
}
