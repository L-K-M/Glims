import XCTest
@testable import GlimsKit

final class ScratchDefaultsTests: XCTestCase {
    func testASuiteLivesInTheTemporaryDirectory() throws {
        let suite = ScratchDefaults.suiteName("self-test")
        let file = URL(fileURLWithPath: suite + ".plist")
        defer { try? FileManager.default.removeItem(at: file) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))

        defaults.set("value", forKey: "key")
        defaults.synchronize()

        XCTAssertEqual(UserDefaults(suiteName: suite)?.string(forKey: "key"), "value")
        XCTAssertTrue(suite.hasPrefix(FileManager.default.temporaryDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testEachSuiteIsItsOwn() {
        XCTAssertNotEqual(ScratchDefaults.suiteName("a"), ScratchDefaults.suiteName("a"))
    }
}
