import XCTest
@testable import GlimsKit

/// Pure checks for the resource catalog types: a persisted identity keeps
/// the NULL and empty collection values apart, and the kind tags are the
/// facade's own stable numbers. No engine, no AppKit.
final class ResourceIdentityTests: XCTestCase {

    func testPersistedIdentityKeepsNullAndEmptyCollectionsApart() throws {
        let withoutCollection = EngineSession.ResourceIdentity(name: "Round", collection: nil, isInternal: false)
        let emptyCollection = EngineSession.ResourceIdentity(name: "Round", collection: "", isInternal: false)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let withoutJSON = try encoder.encode(withoutCollection)
        let emptyJSON = try encoder.encode(emptyCollection)
        XCTAssertFalse(String(decoding: withoutJSON, as: UTF8.self).contains("collection"),
                       "a NULL collection persists as no key, not an empty string")
        XCTAssertTrue(String(decoding: emptyJSON, as: UTF8.self).contains(#""collection":"""#),
                      "an empty collection persists as an empty string")
        XCTAssertEqual(try decoder.decode(EngineSession.ResourceIdentity.self, from: withoutJSON),
                       withoutCollection)
        XCTAssertEqual(try decoder.decode(EngineSession.ResourceIdentity.self, from: emptyJSON),
                       emptyCollection)
        XCTAssertNotEqual(withoutCollection, emptyCollection, "nil and \"\" are different identities")
    }

    func testExplicitNullCollectionJSONDecodesToNil() throws {
        let json = Data(#"{"name":"Round","collection":null,"isInternal":true}"#.utf8)
        let decoded = try JSONDecoder().decode(EngineSession.ResourceIdentity.self, from: json)
        XCTAssertNil(decoded.collection, "an explicit JSON null is a NULL collection")
        XCTAssertEqual(decoded, EngineSession.ResourceIdentity(name: "Round", collection: nil, isInternal: true))
    }

    func testKindTagsAreTheFacadeValues() {
        XCTAssertEqual(EngineSession.ResourceKind.brush.rawValue, 1)
        XCTAssertEqual(EngineSession.ResourceKind.pattern.rawValue, 2)
        XCTAssertEqual(EngineSession.ResourceKind.gradient.rawValue, 3)
        XCTAssertNil(EngineSession.ResourceKind(rawValue: 0))
        XCTAssertNil(EngineSession.ResourceKind(rawValue: 4))
        XCTAssertNil(EngineSession.ResourceKind(rawValue: .max))
    }
}
