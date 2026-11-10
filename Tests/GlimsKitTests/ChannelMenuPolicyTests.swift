import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class ChannelMenuPolicyTests: XCTestCase {
    func testSavedTargetUsesTheWholeSelectedListWithoutFallback() {
        let a = EngineSession.Channel(id: 10, name: "A", isVisible: false, isSelected: false,
                                      isQuickMask: false, opacity: 0.4, color: .black)
        let b = EngineSession.Channel(id: 20, name: "B", isVisible: true, isSelected: true,
                                      isQuickMask: false, opacity: 0.8, color: .red)
        let quick = EngineSession.Channel(id: 30, name: "Quick Mask", isVisible: true, isSelected: true,
                                          isQuickMask: true, opacity: 0.5, color: .red)
        let rows = [a, b, quick]
        XCTAssertEqual(ChannelMenuPolicy.savedTarget(in: rows, selectedIDs: [10])?.id, 10)
        let invalid: [[Int32]] = [[], [10, 20], [10, 10], [30], [999]]
        for ids in invalid {
            XCTAssertNil(ChannelMenuPolicy.savedTarget(in: rows, selectedIDs: ids), "\(ids)")
        }
    }

    func testEveryIndependentCachedReadinessGateRefuses() {
        func allowed(_ gates: [Bool]) -> Bool {
            ChannelMenuPolicy.baseEditingAllowed(acceptsEdits: gates[0], isBusy: gates[1],
                previewBusy: gates[2], sheetAttached: gates[3], isClosing: gates[4],
                targetCommandIsPending: gates[5])
        }
        let ready = [true, false, false, false, false, false]
        XCTAssertTrue(allowed(ready))
        for index in ready.indices {
            var blocked = ready
            blocked[index].toggle()
            XCTAssertFalse(allowed(blocked), "gate \(index)")
        }
    }
}
