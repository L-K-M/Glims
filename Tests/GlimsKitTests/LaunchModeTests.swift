import XCTest
@testable import GlimsKit

final class LaunchModeTests: XCTestCase {
    func testNoArgumentsIsInteractive() throws {
        XCTAssertEqual(try LaunchMode(arguments: []), .interactive)
    }

    func testRecognisedOptions() throws {
        XCTAssertEqual(try LaunchMode(arguments: ["--smoke-test"]), .smokeTest)
        XCTAssertEqual(try LaunchMode(arguments: ["--version"]), .printVersion)
        XCTAssertEqual(try LaunchMode(arguments: ["--engine-smoke-test"]), .engineSmokeTest)
    }

    func testAppKitArgumentsAreLeftAlone() throws {
        XCTAssertEqual(try LaunchMode(arguments: ["-NSDocumentRevisionsDebugMode", "YES"]), .interactive)
    }

    func testUnknownOptionIsRejected() {
        XCTAssertThrowsError(try LaunchMode(arguments: ["--bogus"])) { error in
            XCTAssertEqual(error as? LaunchMode.UnknownOption, LaunchMode.UnknownOption(option: "--bogus"))
        }
    }
}
