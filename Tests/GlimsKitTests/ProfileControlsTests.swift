import AppKit
import XCTest
@testable import GlimsKit

/// The Image ▸ Color Profile controls as they read without a running
/// engine: the menu entries, the form's source/intent choices, the ICC
/// path validation, the indexed conversion guard and the captured
/// settings. The document paths that drive the engine (admission,
/// undo, XCF) are covered by the engine smoke test.
@MainActor
final class ProfileControlsTests: XCTestCase {

    // MARK: Menu structure

    private func imageMenu() -> NSMenu? {
        MainMenu.make().item(withTitle: "Image")?.submenu
    }

    func testTheImageMenuOffersColorProfileAssignAndConvert() throws {
        let image = try XCTUnwrap(imageMenu())
        let profile = try XCTUnwrap(image.item(withTitle: "Color Profile")?.submenu)
        XCTAssertEqual(profile.items.map(\.title), ["Assign…", "Convert…"])
        XCTAssertEqual(profile.items[0].action, #selector(DocumentWindowController.assignColorProfile(_:)))
        XCTAssertEqual(profile.items[1].action, #selector(DocumentWindowController.convertColorProfile(_:)))
        // The color commands sit with Mode and Precision, before the
        // geometry commands.
        let precision = try XCTUnwrap(image.items.firstIndex { $0.action == #selector(DocumentWindowController.imagePrecision(_:)) })
        let profileIndex = try XCTUnwrap(image.items.firstIndex { $0.title == "Color Profile" })
        let size = try XCTUnwrap(image.items.firstIndex { $0.action == #selector(DocumentWindowController.imageSize(_:)) })
        XCTAssertEqual(profileIndex, precision + 1)
        XCTAssertLessThan(profileIndex, size)
    }

    // MARK: Rendering intent choices

    /// The Convert form offers exactly the facade's four intents, in
    /// display order, carrying the facade's own values 1–4.
    func testTheIntentChoicesAreTheFourFacadeValues() {
        let choices = EngineSession.ProfileIntent.conversionChoices
        XCTAssertEqual(choices, [.perceptual, .relativeColorimetric, .saturation, .absoluteColorimetric])
        XCTAssertEqual(choices.map(\.rawValue), [1, 2, 3, 4])
        XCTAssertEqual(choices.map(\.title),
                       ["Perceptual", "Relative Colorimetric", "Saturation", "Absolute Colorimetric"])
    }

    // MARK: Source choices

    func testTheSourceChoicesAreBuiltinThenICCFile() {
        XCTAssertEqual(ProfileForm.Source.allCases, [.builtin, .iccFile])
        XCTAssertEqual(ProfileForm.Source.allCases.map(\.title), ["Built-in profile", "ICC file…"])
    }

    /// The open panel offers only ICC file types.
    func testTheOpenPanelOffersOnlyICCFileTypes() {
        XCTAssertFalse(ProfileForm.iccContentTypes.isEmpty)
        for type in ProfileForm.iccContentTypes {
            XCTAssertTrue(["icc", "icm"].contains(type.preferredFilenameExtension?.lowercased() ?? ""))
        }
    }

    // MARK: Indexed conversion guard

    /// Convert is allowed on RGB, grayscale and unknown modes; indexed
    /// images refuse because their palette conversion ignores intent
    /// and BPC. Assign has no such guard.
    func testConvertIsRefusedForIndexedOnly() {
        XCTAssertTrue(ProfileForm.convertAllowed(mode: .rgb))
        XCTAssertTrue(ProfileForm.convertAllowed(mode: .grayscale))
        XCTAssertTrue(ProfileForm.convertAllowed(mode: .unknown))
        XCTAssertFalse(ProfileForm.convertAllowed(mode: .indexed))
    }

    // MARK: Cached current profile

    private func info(profile: String, embedded: Bool) -> EngineSession.ColorInfo {
        EngineSession.ColorInfo(mode: .rgb, component: .u8, trc: .nonlinear,
                                profileLabel: profile, hasEmbeddedProfile: embedded)
    }

    func testTheCurrentProfileSummaryNamesTheCachedLabel() {
        XCTAssertEqual(ProfileForm.currentProfileSummary(info(profile: "GIMP built-in sRGB", embedded: false)),
                       "GIMP built-in sRGB (built-in default)")
        XCTAssertEqual(ProfileForm.currentProfileSummary(info(profile: "My scanner", embedded: true)),
                       "My scanner (embedded in the image)")
        XCTAssertEqual(ProfileForm.currentProfileSummary(info(profile: "", embedded: false)), "None")
    }

    // MARK: ICC path validation — strings only, no file reads

    func testICCPathsRejectEmbeddedNULBeforeCStringConversion() {
        guard case .failure = ProfileForm.validatedICCPath("/tmp/real.icc\u{0}tail.icc") else {
            return XCTFail("an ICC path must not silently truncate to another file")
        }
    }

    func testAnEmptyICCPathIsRefused() {
        if case .failure(let reason) = ProfileForm.validatedICCPath("   ") {
            XCTAssertFalse(reason.message.isEmpty)
        } else {
            XCTFail("an empty path must not validate")
        }
    }

    /// The facade requires absolute paths; a bare file name refuses
    /// here with a clear reason instead of reaching the engine.
    func testARelativeICCPathIsRefused() {
        guard case .failure(let reason) = ProfileForm.validatedICCPath("profile.icc") else {
            return XCTFail("a relative path must not validate")
        }
        XCTAssertTrue(reason.message.contains("full path"))
    }

    func testANonICCFileExtensionIsRefused() {
        for bad in ["/tmp/profile.png", "/tmp/profile", "/tmp/profile.txt", "/tmp/.icc"] {
            guard case .failure = ProfileForm.validatedICCPath(bad) else {
                return XCTFail("\(bad) must not validate")
            }
        }
    }

    func testAbsoluteICCAndICMPathsValidateTrimmed() {
        guard case .success(let path) = ProfileForm.validatedICCPath("  /Users/you/display.icc ") else {
            return XCTFail("a full .icc path must validate")
        }
        XCTAssertEqual(path, "/Users/you/display.icc")
        guard case .success(let upper) = ProfileForm.validatedICCPath("/Users/you/display.ICM") else {
            return XCTFail("the .icm extension must validate case-insensitively")
        }
        XCTAssertEqual(upper, "/Users/you/display.ICM")
    }

    // MARK: Captured settings

    /// The built-in source carries no path, whatever the field holds.
    func testBuiltinSettingsCarryNoPath() {
        let result = ProfileForm.makeSettings(source: .builtin, iccPath: "/tmp/ignored.icc",
                                              intent: .saturation, blackPointCompensation: false)
        guard case .success(let settings) = result else { return XCTFail("built-in must validate") }
        XCTAssertEqual(settings.source, .builtin)
        XCTAssertEqual(settings.iccPath, "")
        XCTAssertEqual(settings.intent, .saturation)
        XCTAssertFalse(settings.blackPointCompensation)
        XCTAssertNil(ProfileForm.profilePath(settings))
    }

    /// A file source must validate its path before anything is captured.
    func testICCFileSettingsRefuseAnInvalidPath() {
        if case .success = ProfileForm.makeSettings(source: .iccFile, iccPath: " relative.icc ",
                                                    intent: .perceptual, blackPointCompensation: true) {
            XCTFail("a relative path must fail")
        }
        if case .success = ProfileForm.makeSettings(source: .iccFile, iccPath: "/tmp/profile.png",
                                                    intent: .perceptual, blackPointCompensation: true) {
            XCTFail("a non-ICC extension must fail")
        }
    }

    func testICCFileSettingsKeepThePathOnSuccess() {
        guard case .success(let settings) = ProfileForm.makeSettings(source: .iccFile,
                                                                     iccPath: "/tmp/display.icc",
                                                                     intent: .absoluteColorimetric,
                                                                     blackPointCompensation: true),
              case .success(let path) = ProfileForm.validatedICCPath("/tmp/display.icc") else {
            return XCTFail("a full .icc path must validate")
        }
        XCTAssertEqual(settings.iccPath, path)
        XCTAssertEqual(ProfileForm.profilePath(settings), "/tmp/display.icc")
        XCTAssertEqual(settings.intent, .absoluteColorimetric)
        XCTAssertTrue(settings.blackPointCompensation)
    }

    /// The captured form state round-trips through Codable unchanged.
    func testSettingsAreCodable() throws {
        let settings = ProfileForm.Settings(source: .iccFile, iccPath: "/tmp/display.icc",
                                            intent: .relativeColorimetric, blackPointCompensation: true)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(ProfileForm.Settings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    // MARK: Sheet copy

    /// Assign says the pixels are reinterpreted; Convert says the
    /// appearance is preserved by changing the values.
    func testTheCopyExplainsWhatEachOperationDoes() {
        XCTAssertTrue(ProfileForm.Kind.assign.informativeText.contains("reinterpreted"))
        XCTAssertTrue(ProfileForm.Kind.assign.informativeText.contains("does not change the pixel values"))
        XCTAssertTrue(ProfileForm.Kind.convert.informativeText.contains("keeps its appearance"))
        XCTAssertTrue(ProfileForm.Kind.convert.informativeText.contains("changes the pixel values"))
        XCTAssertEqual(ProfileForm.Kind.assign.title, "Assign Color Profile")
        XCTAssertEqual(ProfileForm.Kind.convert.title, "Convert to Color Profile")
        XCTAssertEqual(ProfileForm.Kind.assign.applyTitle, "Assign")
        XCTAssertEqual(ProfileForm.Kind.convert.applyTitle, "Convert")
    }
}
