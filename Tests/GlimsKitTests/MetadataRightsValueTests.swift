import XCTest
@testable import GlimsKit

final class MetadataRightsValueTests: XCTestCase {
    func testPresenceAndFalseAreDifferent() {
        XCTAssertEqual(MetadataRightsValue(values: []), .unspecified)
        XCTAssertEqual(MetadataRightsValue(values: ["True"]), .marked)
        XCTAssertEqual(MetadataRightsValue(values: ["False"]), .unmarked)
        XCTAssertNotEqual(MetadataRightsValue(values: []), MetadataRightsValue(values: ["False"]))
    }

    func testOnlyCanonicalNativeStringsAreAccepted() {
        for values in [[""], ["true"], ["false"], ["1"], ["0"], [" True"], ["False "],
                       ["Unknown"], ["True\0"], ["True", "False"], ["True", "True"]] {
            XCTAssertNil(MetadataRightsValue(values: values), "Unexpected coercion of \(values)")
        }
    }

    func testEachChoiceRoundTripsWithoutChangingItsSpelling() {
        for choice in MetadataRightsValue.allCases {
            XCTAssertEqual(MetadataRightsValue(values: choice.values), choice)
        }
        XCTAssertEqual(MetadataRightsValue.marked.values, ["True"])
        XCTAssertEqual(MetadataRightsValue.unmarked.values, ["False"])
        XCTAssertEqual(MetadataRightsValue.unspecified.values, [])
    }
}
