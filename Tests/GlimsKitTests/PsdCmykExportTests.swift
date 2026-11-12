import AppKit
import XCTest
@testable import GlimsKit

private struct TestCmykCatalogLoader: PsdCmykProfileCatalogLoading {
    let result: Result<[PsdCmykProfileCatalogEntry], Error>
    func loadCatalog() throws -> [PsdCmykProfileCatalogEntry] { try result.get() }
}

@MainActor
final class PsdCmykExportTests: XCTestCase {
    private func fire(_ control: NSControl) {
        guard let action = control.action else { return XCTFail("control has no action") }
        XCTAssertTrue(control.sendAction(action, to: control.target))
    }

    private func waitForCatalog(_ condition: () -> Bool, timeout: TimeInterval = 5.0) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            // Yield the main actor so the production main-queue reply can run.
            // Polling NSRunLoop synchronously can starve it on hosted macOS.
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }

    private func makeCmykICC(name: String = "TestCMYK", variant: Bool = false) throws -> PsdCmykProfile {
        var data = try XCTUnwrap(NSColorSpace.genericCMYK.iccProfileData)
        if variant {
            // Change the ICC header's manufacturer, preserving its color tables.
            data.replaceSubrange(48..<52, with: Data("GLIM".utf8))
        }
        return try PsdCmykProfile(displayName: name, iccData: data)
    }

    func testDefaultSettingsKeepDocumentPsdBehavior() throws {
        let settings = ExportSettings()
        XCTAssertEqual(settings.format, .png)
        XCTAssertEqual(settings.psdColor, .document)
        XCTAssertNil(settings.psdCmykProfile)
        XCTAssertTrue(settings.isReadyToExport)
        let native = try settings.nativeValue()
        XCTAssertEqual(native.format, 1) // PNG
    }

    func testPsdCmykRequiresExplicitValidProfileAndRejectsInvalid() throws {
        var settings = ExportSettings()
        settings.format = .psd
        settings.psdColor = .cmyk
        XCTAssertFalse(settings.isReadyToExport)
        XCTAssertThrowsError(try settings.validatedPsdCmykProfileData())

        settings.psdCmykProfile = nil
        XCTAssertTrue(ExportSettings.validate(settings), "an unfinished choice is valid form state")
        XCTAssertThrowsError(try PsdCmykProfile(displayName: "Truncated", iccData: Data([0])))
        let small = try makeCmykICC()
        XCTAssertTrue(PsdCmykProfile.isValidICCData(small.iccData))
        let tooBigBytes = Data(repeating: 0, count: 4 * 1024 * 1024 + 1)
        XCTAssertFalse(PsdCmykProfile.isValidICCData(tooBigBytes))
        XCTAssertThrowsError(try PsdCmykProfile(displayName: "Bad", iccData: tooBigBytes))

        let rgbSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let rgbICC = rgbSpace.copyICCData()! as Data
        XCTAssertFalse(PsdCmykProfile.isValidICCData(rgbICC))
        XCTAssertThrowsError(try PsdCmykProfile(displayName: "RGB", iccData: rgbICC))

        settings.psdCmykProfile = small
        XCTAssertTrue(settings.isReadyToExport)
        XCTAssertEqual(try settings.validatedPsdCmykProfileData(), small.iccData)
    }

    func testCapturedProfileBytesAreImmutableForRepeatAndSeed() throws {
        let profileA = try makeCmykICC(name: "A")
        var settings = ExportSettings()
        settings.format = .psd
        settings.psdColor = .cmyk
        settings.psdCmykProfile = profileA
        let seed = settings
        let repeated = settings
        XCTAssertEqual(seed.psdCmykProfile?.iccData, profileA.iccData)
        XCTAssertEqual(repeated.psdCmykProfile?.iccData, profileA.iccData)

        var copy = settings
        copy.psdLayout = .merged
        XCTAssertEqual(settings.psdCmykProfile?.iccData, profileA.iccData)
        XCTAssertEqual(copy.psdCmykProfile?.iccData, profileA.iccData)
        XCTAssertNotEqual(copy, settings)

        let form = ExportOptionsForm(settings: seed)
        XCTAssertEqual(form.settings.psdCmykProfile?.iccData, profileA.iccData)
        XCTAssertEqual(form.settings.psdCmykProfile?.displayName, "A")
    }

    func testFormCommitRequiresProfileOnlyForActivePsdCmyk() throws {
        let form = ExportOptionsForm()
        form.selectFormat(.png)
        XCTAssertTrue(form.commitEditing(), "hidden/missing CMYK profile must not block PNG")

        form.selectFormat(.psd)
        form.psdColorPopup.selectItem(at: 1) // CMYK
        fire(form.psdColorPopup)
        XCTAssertFalse(form.commitEditing(), "active PSD CMYK without profile must refuse")
        XCTAssertNotNil(form.lastError)

        form.selectFormat(.jpeg)
        XCTAssertTrue(form.commitEditing(), "switching away clears active CMYK requirement")
        form.selectFormat(.psd)
        XCTAssertEqual(form.settings.psdColor, .cmyk)
        XCTAssertNil(form.settings.psdCmykProfile)
    }

    func testExplicitPopupChoiceCapturesProfileAndRestoresAfterFormatSwitch() async throws {
        let profile = try makeCmykICC(name: "GenericCMYK")
        let loader = TestCmykCatalogLoader(result: .success([.init(profile: profile)]))
        let form = ExportOptionsForm(psdCmykCatalogLoader: loader)
        form.selectFormat(.psd)
        form.psdColorPopup.selectItem(at: 1)
        fire(form.psdColorPopup)
        let loaded1 = await waitForCatalog { form.psdCmykProfilePopup.numberOfItems >= 2 }
        XCTAssertTrue(loaded1)
        form.psdCmykProfilePopup.selectItem(at: 1)
        fire(form.psdCmykProfilePopup)
        XCTAssertEqual(form.settings.psdCmykProfile?.iccData, profile.iccData)
        XCTAssertTrue(form.commitEditing())

        form.selectFormat(.png)
        form.selectFormat(.psd)
        XCTAssertEqual(form.settings.psdColor, .cmyk)
        XCTAssertEqual(form.settings.psdCmykProfile?.iccData, profile.iccData, "format reselect restores captured choice")
    }

    func testRestorePreviousProfileEvenIfNotInCurrentCatalog() async throws {
        let missing = try makeCmykICC(name: "Old Profile")
        var seed = ExportSettings()
        seed.format = .psd
        seed.psdColor = .cmyk
        seed.psdCmykProfile = missing
        let loader = TestCmykCatalogLoader(result: .success([]))
        let form = ExportOptionsForm(settings: seed, psdCmykCatalogLoader: loader)
        let loaded2 = await waitForCatalog { form.psdCmykProfilePopup.numberOfItems >= 2 || form.lastError != nil || form.messageLabel.stringValue.contains("No installed") }
        XCTAssertTrue(loaded2)
        XCTAssertEqual(form.settings.psdCmykProfile?.iccData, missing.iccData, "captured bytes retained")
        XCTAssertTrue((0..<form.psdCmykProfilePopup.numberOfItems).contains {
            (form.psdCmykProfilePopup.item(at: $0)?.representedObject as? Data) == missing.iccData
        })
    }

    func testAsyncCatalogResultsDoNotClearOrReplaceCapturedProfile() throws {
        let captured = try makeCmykICC(name: "Captured")
        var seed = ExportSettings()
        seed.format = .psd
        seed.psdColor = .cmyk
        seed.psdCmykProfile = captured
        let form = ExportOptionsForm(settings: seed, psdCmykCatalogLoader: TestCmykCatalogLoader(result: .success([])))
        form.applyPsdCmykCatalogForTesting(.success([]))
        XCTAssertEqual(form.settings.psdCmykProfile?.iccData, captured.iccData)
        let other = try makeCmykICC(name: "Other")
        form.applyPsdCmykCatalogForTesting(.success([.init(profile: other)]))
        XCTAssertEqual(form.settings.psdCmykProfile?.iccData, captured.iccData, "catalog must not retarget selection")
        form.applyPsdCmykCatalogForTesting(.failure(NSError(domain: "test", code: 1)))
        XCTAssertEqual(form.settings.psdCmykProfile?.iccData, captured.iccData)
    }

    func testFailedOrEmptyCatalogShowsActionableMessageWithoutFallback() async throws {
        let formEmpty = ExportOptionsForm(psdCmykCatalogLoader: TestCmykCatalogLoader(result: .success([])))
        formEmpty.selectFormat(.psd)
        formEmpty.psdColorPopup.selectItem(at: 1)
        fire(formEmpty.psdColorPopup)
        let loaded3 = await waitForCatalog { formEmpty.messageLabel.stringValue.contains("ColorSync") || formEmpty.lastError != nil }
        XCTAssertTrue(loaded3)
        XCTAssertNil(formEmpty.settings.psdCmykProfile)
        XCTAssertFalse(formEmpty.commitEditing())

        let formFailed = ExportOptionsForm(psdCmykCatalogLoader: TestCmykCatalogLoader(result: .failure(NSError(domain: "test", code: 2))))
        formFailed.selectFormat(.psd)
        formFailed.psdColorPopup.selectItem(at: 1)
        fire(formFailed.psdColorPopup)
        let loaded4 = await waitForCatalog { formFailed.lastError?.contains("ColorSync") == true }
        XCTAssertTrue(loaded4)
        XCTAssertNil(formFailed.settings.psdCmykProfile)
        XCTAssertFalse(formFailed.commitEditing())
        XCTAssertNotEqual(formFailed.settings.psdColor, .document)
    }

    func testPlaceholderMeansNoExportUntilExplicitChoice() async throws {
        let profile = try makeCmykICC(name: "GenericCMYK")
        let form = ExportOptionsForm(settings: {
            var s = ExportSettings(); s.format = .psd; s.psdColor = .cmyk; return s
        }(), psdCmykCatalogLoader: TestCmykCatalogLoader(result: .success([.init(profile: profile)])))
        let loaded5 = await waitForCatalog { form.psdCmykProfilePopup.numberOfItems >= 2 }
        XCTAssertTrue(loaded5)
        XCTAssertEqual(form.psdCmykProfilePopup.indexOfSelectedItem, 0, "placeholder selected")
        XCTAssertFalse(form.commitEditing())
        form.psdCmykProfilePopup.selectItem(at: 1)
        fire(form.psdCmykProfilePopup)
        XCTAssertTrue(form.commitEditing())
    }

    func testProfilesWithTheSameNameRemainDistinctChoices() throws {
        let first = try makeCmykICC(name: "Printer")
        let second = try makeCmykICC(name: "Printer", variant: true)
        XCTAssertNotEqual(first.iccData, second.iccData)
        var settings = ExportSettings()
        settings.format = .psd
        settings.psdColor = .cmyk
        settings.psdCmykProfile = first
        let form = ExportOptionsForm(settings: settings,
            psdCmykCatalogLoader: TestCmykCatalogLoader(result: .success([])))
        form.applyPsdCmykCatalogForTesting(.success([.init(profile: first), .init(profile: second)]))
        XCTAssertEqual(form.psdCmykProfilePopup.numberOfItems, 3)
        XCTAssertEqual(form.psdCmykProfilePopup.selectedItem?.representedObject as? Data, first.iccData)
        form.psdCmykProfilePopup.selectItem(at: 2)
        fire(form.psdCmykProfilePopup)
        XCTAssertEqual(form.settings.psdCmykProfile?.iccData, second.iccData)
    }
}
