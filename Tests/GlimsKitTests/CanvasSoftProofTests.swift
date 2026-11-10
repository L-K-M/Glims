import CoreGraphics
import XCTest
@testable import GlimsKit

final class CanvasSoftProofTests: XCTestCase {
    func testInvalidProfileDataIsRefusedBeforeNativeRendering() {
        XCTAssertThrowsError(try CanvasSoftProof(profileICC: Data(), profileName: "Empty"))
        XCTAssertThrowsError(try CanvasSoftProof(profileICC: Data("invalid ICC".utf8), profileName: "Invalid"))
        XCTAssertThrowsError(try CanvasSoftProof(
            profileICC: Data(count: CanvasSoftProof.maximumICCBytes + 1), profileName: "Oversized"))
    }

    func testProofCapturesImmutableProfileAndIndependentIntents() throws {
        var bytes = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?)
        let original = bytes
        let proof = try CanvasSoftProof(profileICC: bytes, profileName: "Simulation",
            proofIntent: .absoluteColorimetric, displayIntent: .perceptual, blackPointCompensation: true)
        bytes.removeAll()
        XCTAssertEqual(proof.profileICC, original)
        XCTAssertEqual(proof.proofIntent, .absoluteColorimetric)
        XCTAssertEqual(proof.displayIntent, .perceptual)
        XCTAssertTrue(proof.blackPointCompensation)
    }

    func testOptionChangesHaveIndependentWindowValueIdentity() throws {
        let bytes = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data?)
        let first = try CanvasSoftProof(profileICC: bytes, profileName: "Proof")
        let second = try CanvasSoftProof(profileICC: bytes, profileName: "Proof", blackPointCompensation: true)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, try CanvasSoftProof(profileICC: bytes, profileName: "Proof"))
    }
}
