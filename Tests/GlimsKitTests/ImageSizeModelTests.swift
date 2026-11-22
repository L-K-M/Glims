import XCTest
@testable import GlimsKit

/// The pure Image Size arithmetic: unit round trips, rounding, limits,
/// non-finite input, differing x/y resolution and the two resample modes.
final class ImageSizeModelTests: XCTestCase {
    private func model(width: Int = 1200, height: Int = 900,
                       resolutionX: Double = 300, resolutionY: Double = 300,
                       constrain: Bool = true, resample: Bool = true) -> ImageSizeModel {
        ImageSizeModel(width: width, height: height, resolutionX: resolutionX, resolutionY: resolutionY,
                       constrainProportions: constrain, resample: resample)!
    }

    func testPixelsPrintRoundTripInEveryLengthUnit() {
        for unit in ImageSizeModel.LengthUnit.allCases {
            var value = model()
            let printWidth = value.printWidth(in: unit)
            let printHeight = value.printHeight(in: unit)
            XCTAssertTrue(value.setPrintWidth(printWidth, unit: unit))
            XCTAssertTrue(value.setPrintHeight(printHeight, unit: unit))
            XCTAssertEqual(value.width, 1200, unit.title)
            XCTAssertEqual(value.height, 900, unit.title)
        }
    }

    func testLengthUnitsConvertFromInches() {
        let value = model(width: 720, height: 1440, resolutionX: 72, resolutionY: 72)
        XCTAssertEqual(value.printWidth(in: .inches), 10, accuracy: 1e-9)
        XCTAssertEqual(value.printWidth(in: .centimeters), 25.4, accuracy: 1e-9)
        XCTAssertEqual(value.printWidth(in: .millimeters), 254, accuracy: 1e-9)
        XCTAssertEqual(value.printWidth(in: .points), 720, accuracy: 1e-9)
        XCTAssertEqual(value.printWidth(in: .picas), 60, accuracy: 1e-9)
        XCTAssertEqual(value.printHeight(in: .inches), 20, accuracy: 1e-9)
    }

    func testResolutionUnitsRoundTrip() {
        var value = model(resolutionX: 300, resolutionY: 300)
        XCTAssertEqual(value.resolutionX(in: .pixelsPerCentimeter), 300 / 2.54, accuracy: 1e-9)
        XCTAssertTrue(value.setResolution(300 / 2.54, unit: .pixelsPerCentimeter))
        XCTAssertEqual(value.resolutionX, 300, accuracy: 1e-9)
        XCTAssertEqual(value.resolutionY, 300, accuracy: 1e-9)
    }

    func testRoundingAndConstrainProportions() {
        var value = model(width: 100, height: 101)
        XCTAssertTrue(value.setPixelWidth(200))
        XCTAssertEqual(value.width, 200)
        XCTAssertEqual(value.height, 202)
        XCTAssertTrue(value.setPixelHeight(50))
        XCTAssertEqual(value.height, 50)
        XCTAssertEqual(value.width, 50)
        value.setConstrainProportions(false)
        XCTAssertTrue(value.setPixelWidth(10))
        XCTAssertEqual(value.width, 10)
        XCTAssertEqual(value.height, 50)
    }

    func testResolutionChangeWithAndWithoutResample() {
        var resampled = model(width: 1200, height: 900, resolutionX: 300, resolutionY: 300, resample: true)
        XCTAssertTrue(resampled.setResolution(150, unit: .pixelsPerInch))
        XCTAssertEqual(resampled.width, 600)
        XCTAssertEqual(resampled.height, 450)
        XCTAssertEqual(resampled.printWidthInInches, 4, accuracy: 1e-9)

        var fixed = model(width: 1200, height: 900, resolutionX: 300, resolutionY: 300, resample: false)
        XCTAssertTrue(fixed.setResolution(150, unit: .pixelsPerInch))
        XCTAssertEqual(fixed.width, 1200)
        XCTAssertEqual(fixed.height, 900)
        XCTAssertEqual(fixed.printWidthInInches, 8, accuracy: 1e-9)
    }

    func testPrintSizeEditWithAndWithoutResample() {
        var resampled = model(width: 1200, height: 900, resolutionX: 300, resolutionY: 300, resample: true)
        XCTAssertTrue(resampled.setPrintWidth(8, unit: .inches))
        XCTAssertEqual(resampled.width, 2400)
        XCTAssertEqual(resampled.resolutionX, 300)

        var fixed = model(width: 1200, height: 900, resolutionX: 300, resolutionY: 300, resample: false)
        XCTAssertTrue(fixed.setPrintWidth(8, unit: .inches))
        XCTAssertEqual(fixed.width, 1200)
        XCTAssertEqual(fixed.resolutionX, 150)
    }

    func testDifferingResolutionIsPreservedUntilEdited() {
        var value = model(resolutionX: 300, resolutionY: 150)
        XCTAssertTrue(value.setPrintWidth(2, unit: .inches))
        XCTAssertEqual([value.width, value.height], [600, 450])
        XCTAssertEqual(value.resolutionX, 300)
        XCTAssertEqual(value.resolutionY, 150)
        XCTAssertTrue(value.setPrintHeight(6, unit: .inches))
        XCTAssertEqual([value.width, value.height], [1200, 900])
        XCTAssertEqual(value.resolutionY, 150)
        XCTAssertTrue(value.setResolution(200, unit: .pixelsPerInch))
        XCTAssertEqual(value.resolutionX, 200)
        XCTAssertEqual(value.resolutionY, 200)
    }

    func testLimitsAndNonFiniteInput() {
        XCTAssertNil(ImageSizeModel(width: 0, height: 10, resolutionX: 300, resolutionY: 300))
        XCTAssertNil(ImageSizeModel(width: 10, height: 524_289, resolutionX: 300, resolutionY: 300))
        XCTAssertNil(ImageSizeModel(width: 10, height: 10, resolutionX: 0, resolutionY: 300))
        XCTAssertNil(ImageSizeModel(width: 10, height: 10, resolutionX: .nan, resolutionY: 300))
        XCTAssertNil(ImageSizeModel(width: 10, height: 10, resolutionX: .infinity, resolutionY: 300))
        var value = model()
        for invalid in [0.0, -1, ImageSizeModel.minimumResolution / 2,
                        ImageSizeModel.maximumResolution * 2, .nan, .infinity, -.infinity] {
            XCTAssertFalse(value.setResolution(invalid, unit: .pixelsPerInch), "\(invalid)")
        }
        for invalid in [0.0, -1, .nan, .infinity, -.infinity] {
            XCTAssertFalse(value.setPrintWidth(invalid, unit: .inches), "\(invalid)")
            XCTAssertFalse(value.setPrintHeight(invalid, unit: .inches), "\(invalid)")
        }
        XCTAssertFalse(value.setPixelWidth(0))
        XCTAssertFalse(value.setPixelWidth(524_289))
        XCTAssertFalse(value.setPixelHeight(-1))
        XCTAssertEqual(value.width, 1200)
        XCTAssertEqual(value.height, 900)
        XCTAssertEqual(value.resolutionX, 300)
        // A print width whose pixels would exceed the maximum is refused.
        XCTAssertFalse(value.setPrintWidth(1e9, unit: .inches))
        XCTAssertEqual(value.width, 1200)
    }

    func testSizeUnitPixelConversion() {
        XCTAssertEqual(ImageSizeModel.SizeUnit.pixels.pixels(100, resolution: 300), 100)
        XCTAssertNil(ImageSizeModel.SizeUnit.pixels.pixels(100.5, resolution: 300))
        XCTAssertNil(ImageSizeModel.SizeUnit.pixels.pixels(0, resolution: 300))
        XCTAssertEqual(ImageSizeModel.SizeUnit.inches.pixels(5, resolution: 300), 1500)
        XCTAssertEqual(ImageSizeModel.SizeUnit.centimeters.pixels(5, resolution: 300), 591)
        XCTAssertEqual(ImageSizeModel.SizeUnit.millimeters.pixels(25.4, resolution: 300), 300)
        XCTAssertEqual(ImageSizeModel.SizeUnit.inches.pixels(1, resolution: 72), 72)
        XCTAssertNil(ImageSizeModel.SizeUnit.inches.pixels(-1, resolution: 300))
        XCTAssertNil(ImageSizeModel.SizeUnit.inches.pixels(1, resolution: .nan))
        XCTAssertNil(ImageSizeModel.SizeUnit.inches.pixels(1e9, resolution: 300))
        XCTAssertEqual(ImageSizeModel.SizeUnit.allCases.map(\.title), ["px", "in", "cm", "mm"])
    }

    func testScaledPixelsAcceptValuesRoundingToTheMaximum() {
        var value = model(width: 1200, height: 900, resolutionX: 300, resolutionY: 300)
        XCTAssertTrue(value.setPrintWidth(1747.626, unit: .inches))
        XCTAssertEqual(value.width, 524_288)
        XCTAssertTrue(value.setPrintWidth(1747.627, unit: .inches))
        XCTAssertEqual(value.width, 524_288)
        XCTAssertFalse(value.setPrintWidth(1747.629, unit: .inches))
        XCTAssertEqual(value.width, 524_288)
    }

    func testNewImageDefaults() {
        XCTAssertEqual(ImageSizeModel.defaultResolution, 72)
        XCTAssertEqual(ImageSizeModel.minimumResolution, 0.005)
        XCTAssertEqual(ImageSizeModel.maximumResolution, 1_048_576)
    }

    func testLockingAgainKeepsTheShownShape() {
        var pixels = model(width: 1000, height: 1, resolutionX: 300, resolutionY: 300, resample: true)
        XCTAssertTrue(pixels.setResolution(0.005, unit: .pixelsPerInch))
        pixels.setConstrainProportions(false)
        XCTAssertTrue(pixels.setPixelHeight(100))
        XCTAssertEqual([pixels.width, pixels.height], [1, 100])
        pixels.setConstrainProportions(true)
        XCTAssertTrue(pixels.setPixelWidth(2))
        XCTAssertEqual([pixels.width, pixels.height], [2, 200])

        var printed = model(width: 1000, height: 1, resolutionX: 100, resolutionY: 100, resample: true)
        XCTAssertTrue(printed.setPixelWidth(100))
        printed.setConstrainProportions(false)
        XCTAssertTrue(printed.setPrintWidth(0.5, unit: .inches))
        XCTAssertEqual([printed.width, printed.height], [50, 1])
        printed.setConstrainProportions(true)
        XCTAssertTrue(printed.setPrintHeight(0.02, unit: .inches))
        XCTAssertEqual([printed.width, printed.height], [100, 2])
    }

    func testTypingThroughASubPixelSideKeepsTheProportions() {
        var pixels = model(width: 1000, height: 1, resolutionX: 72, resolutionY: 72, resample: true)
        for value in [1, 10, 100, 1000] { XCTAssertTrue(pixels.setPixelWidth(value)) }
        XCTAssertEqual([pixels.width, pixels.height], [1000, 1])
        XCTAssertTrue(pixels.setPixelHeight(2))
        XCTAssertEqual(pixels.width, 2000)
    }

    func testTypingDigitByDigitKeepsTheProportions() {
        var pixels = model(width: 1000, height: 333, resolutionX: 72, resolutionY: 72, resample: true)
        for value in [5, 50, 500] { XCTAssertTrue(pixels.setPixelWidth(value)) }
        XCTAssertEqual(pixels.height, 167)

        var resolution = model(width: 1000, height: 333, resolutionX: 72, resolutionY: 72, resample: true)
        for value in [1.0, 14, 144] { XCTAssertTrue(resolution.setResolution(value, unit: .pixelsPerInch)) }
        XCTAssertEqual(resolution.width, 2000)
        XCTAssertEqual(resolution.height, 666)
    }

    func testTurningResampleOffRestoresTheImagesPixels() {
        var value = model(width: 1200, height: 900, resolutionX: 300, resolutionY: 300, resample: true)
        XCTAssertTrue(value.setPixelWidth(600))
        value.setResample(false)
        XCTAssertEqual(value.width, 1200)
        XCTAssertEqual(value.height, 900)
    }

    func testPrintEditWithoutResampleKeepsTheAspect() {
        var wide = model(width: 1200, height: 900, resolutionX: 300, resolutionY: 300, resample: false)
        XCTAssertTrue(wide.setPrintWidth(8, unit: .inches))
        XCTAssertEqual(wide.resolutionY, 150)

        var tall = model(width: 1200, height: 900, resolutionX: 300, resolutionY: 150, resample: false)
        XCTAssertTrue(tall.setPrintHeight(3, unit: .inches))
        XCTAssertEqual(tall.resolutionX, 600)
    }

    func testResamplingToAResolutionKeepsBothPrintDimensions() {
        var value = model(width: 1200, height: 900, resolutionX: 300, resolutionY: 150, resample: true)
        XCTAssertTrue(value.setResolution(300, unit: .pixelsPerInch))
        XCTAssertEqual(value.width, 1200)
        XCTAssertEqual(value.height, 1800)
    }
}
