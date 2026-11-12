import XCTest
@testable import GlimsKit

final class RecorderInkBindingTests: XCTestCase {
    private let source = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let destination = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    func testExplicitRebindingPreservesCMYKRoleButUsesDestinationUUID() {
        let cyan = RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: source)
        let rebound = RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: destination)
        XCTAssertTrue(cyan.permitsExplicitBinding(to: rebound))
        XCTAssertFalse(cyan.matchesInOwningDocument(rebound))
        XCTAssertFalse(cyan.permitsExplicitBinding(to: .init(mode: .cmyk, role: .magenta, uuid: source)))
        XCTAssertFalse(cyan.permitsExplicitBinding(to: .init(mode: .multichannel, role: .unspecified, uuid: source)))
    }

    func testMultichannelRuntimeIdentityCannotFollowAnUnrelatedInk() {
        let first = RecorderInkIdentity(mode: .multichannel, role: .unspecified, uuid: source)
        let second = RecorderInkIdentity(mode: .multichannel, role: .unspecified, uuid: destination)
        XCTAssertTrue(first.permitsExplicitBinding(to: second))
        XCTAssertFalse(first.matchesInOwningDocument(second))
        XCTAssertTrue(first.matchesInOwningDocument(first))
    }

    func testBatchNeverInfersInkPermissionFromAnExactDisplayName() throws {
        let symbol = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
        let description = RecorderTargetDescription(name: "Cyan", kind: .channel, ancestors: [],
            siblingIndex: 0, bounds: .init(x: 0, y: 0, width: 12, height: 8))
        for identity in [RecorderInkIdentity(mode: .cmyk, role: .cyan, uuid: source),
                         .init(mode: .multichannel, role: .unspecified, uuid: source)] {
            let file = RecorderFileValue(recordingID: destination, name: "Ink", origin: .init(
                imageLabel: "Source", initialWidth: 12, initialHeight: 8),
                symbols: [.init(id: symbol, description: description)], records: [.init(ordinal: 0,
                    outcome: .success(.editInk(.init(operation: .invert, intensity: 0, opacity: 1)),
                                      .ink(symbol: symbol, identity: identity)))])
            // Ensure the matcher reaches its ink policy, rather than merely
            // throwing on invalid fixture data in the codec preflight.
            XCTAssertNoThrow(try RecorderFileCodec.encode(file))
            for policy in RecorderBatchBindings.Policy.allCases {
                XCTAssertThrowsError(try RecorderBatchBindings.resolve(file: file, candidates: [
                    .init(choice: .channel(70), description: description, hasMask: false)
                ], policy: policy)) {
                    XCTAssertEqual($0 as? RecorderBatchBindings.MatchError, .explicitInkBindingRequired)
                }
            }
        }
    }
}
