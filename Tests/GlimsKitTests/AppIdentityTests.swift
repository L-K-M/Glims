import XCTest
@testable import GlimsKit

/// The committed Info.plist is copied into the bundle as-is, so it must agree
/// with the identity the code assumes and with the project license.
final class AppIdentityTests: XCTestCase {
    private func committedInfoPlist() throws -> [String: Any] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try XCTUnwrap(plist as? [String: Any])
    }

    func testInfoPlistMatchesAppIdentity() throws {
        let info = try committedInfoPlist()
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, AppIdentity.bundleIdentifier)
        XCTAssertEqual(info["CFBundleExecutable"] as? String, AppIdentity.name)
        XCTAssertEqual(info["CFBundleName"] as? String, AppIdentity.name)
    }

    func testInfoPlistNamesTheCommittedIcon() throws {
        let info = try committedInfoPlist()
        XCTAssertEqual(info["CFBundleIconFile"] as? String, "AppIcon")
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Resources/AppIcon.icns").path))
    }

    func testFinderCanOfferGlimsForLayeredAndImportedImages() throws {
        let info = try committedInfoPlist()
        let types = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        let identifiers = types.flatMap { $0["LSItemContentTypes"] as? [String] ?? [] }
        XCTAssertTrue(identifiers.contains("org.gimp.xcf"))
        XCTAssertTrue(identifiers.contains("public.image"))
        XCTAssertTrue(types.allSatisfy { $0["CFBundleTypeRole"] as? String == "Editor" })
    }

    func testInfoPlistStatesTheProjectLicense() throws {
        let info = try committedInfoPlist()
        XCTAssertEqual(info["NSHumanReadableCopyright"] as? String, "Licensed under GPL-3.0-or-later")
    }
}
