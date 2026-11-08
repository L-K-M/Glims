import XCTest
@testable import GlimsKit

final class MetadataInputTests: XCTestCase {
    func testEmbeddedNULCannotShortenTagOrValueAtTheBridge() {
        XCTAssertThrowsError(try EngineSession.validateMetadataStrings(tag: "Exif.Image.Artist\0other", values: []))
        XCTAssertThrowsError(try EngineSession.validateMetadataStrings(tag: "Exif.Image.Artist", values: ["Alice\0Bob"]))
    }
    func testUnicodeValuesAndEmptyRemovalArgumentsRemainRepresentable() {
        XCTAssertNoThrow(try EngineSession.validateMetadataStrings(tag: "Exif.Image.Artist", values: ["Élodie", "山"]))
        XCTAssertNoThrow(try EngineSession.validateMetadataStrings(tag: "Exif.Image.Artist", values: []))
    }
}
