import XCTest
@testable import GlimsKit

@MainActor
final class OpenedImageOwnershipTests: XCTestCase {
    private enum Failure: Error, Equatable {
        case load, construction, close
    }

    func testFailedDocumentConstructionClosesOnlyItsLoadedImage() {
        let loaded: Int32 = 41
        let existing: Int32 = 12
        var liveImages: Set<Int32> = [loaded, existing]
        var closeCalls: [Int32] = []
        XCTAssertThrowsError(try AppController.adoptOpenedImage(.success(loaded), adopt: { image in
            XCTAssertEqual(image, loaded)
            XCTAssertTrue(liveImages.contains(image))
            throw Failure.construction
        }, close: { image in
            closeCalls.append(image)
            liveImages.remove(image)
        })) { error in
            XCTAssertEqual(error as? Failure, .construction)
            XCTAssertEqual(liveImages, [existing], "cleanup must finish before the error is reported")
        }
        XCTAssertEqual(closeCalls, [loaded])
    }

    func testFailedNativeLoadNeitherAdoptsNorClosesAnImage() {
        XCTAssertThrowsError(try AppController.adoptOpenedImage(.failure(Failure.load), adopt: { _ in
            XCTFail("a failed load produced no image to adopt")
        }, close: { _ in
            XCTFail("a failed load produced no owned image to close")
        })) { XCTAssertEqual($0 as? Failure, .load) }
    }

    func testSuccessfulAdoptionKeepsItsImageAlive() throws {
        let loaded: Int32 = 41
        var adopted: [Int32] = []
        try AppController.adoptOpenedImage(.success(loaded), adopt: { adopted.append($0) }, close: { _ in
            XCTFail("the adopted document owns this image")
        })
        XCTAssertEqual(adopted, [loaded])
    }

    func testCleanupFailurePreservesConstructionErrorWithoutRetryingClose() {
        var closeCalls: [Int32] = []
        XCTAssertThrowsError(try AppController.adoptOpenedImage(.success(41), adopt: { _ in
            throw Failure.construction
        }, close: { image in
            closeCalls.append(image)
            throw Failure.close
        })) { XCTAssertEqual($0 as? Failure, .construction) }
        XCTAssertEqual(closeCalls, [41])
    }
}
