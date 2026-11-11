import AppKit
import XCTest
@testable import GlimsKit

final class RecorderQuickMaskColorTests: XCTestCase {
    func testMeasuredThreeStepRedAndFourStepBoundariesCanonicalize() throws {
        let color = try RecorderQuickMaskColor.canonical(red: 1.0000003576278687,
            green: -0.000000476837158203125, blue: 0.375, alpha: 1.0000004768371582)
        XCTAssertEqual(color, try RecorderColor(red: 1, green: 0, blue: 0.375, alpha: 1))
    }

    func testInteriorComponentsStayExactEvenNearEndpoints() throws {
        let color = try RecorderQuickMaskColor.canonical(red: 0.9999999403953552,
            green: 0.000000059604644775390625, blue: 0.25, alpha: 0.5)
        XCTAssertEqual(color.red, 0.9999999403953552)
        XCTAssertEqual(color.green, 0.000000059604644775390625)
        XCTAssertEqual(color.blue, 0.25)
        XCTAssertEqual(color.alpha, 0.5)
    }

    func testFiveStepsBeyondEitherEndpointAndNonfiniteValuesRefuse() {
        let invalid: [Double] = [1.0000005960464478, -0.00000059604644775390625, 1.125, -.infinity, .infinity, .nan]
        for red in invalid {
            XCTAssertThrowsError(try RecorderQuickMaskColor.canonical(red: red, green: 0, blue: 0, alpha: 0.5))
        }
        XCTAssertThrowsError(try RecorderQuickMaskColor.canonical(red: 1, green: 0, blue: 0, alpha: .nan))
        XCTAssertThrowsError(try RecorderColor(red: 1.0000003576278687, green: 0, blue: 0, alpha: 0.5))
    }

    func testReplayComparisonPreservesRoleFlagsAndExactInteriorColor() {
        func state(_ red: CGFloat, enabled: Bool = true, channel: Int32 = 17,
                   inverted: Bool = false) -> EngineSession.QuickMaskState {
            .init(enabled: enabled, channel: channel, inverted: inverted,
                  color: NSColor(srgbRed: red, green: 0, blue: 0, alpha: 0.5))
        }
        let nativeDefault = state(1.0000003576278687)
        let savedDefault = state(1)
        XCTAssertTrue(RecorderQuickMaskColor.matches(nativeDefault, savedDefault))
        XCTAssertFalse(RecorderQuickMaskColor.matches(nativeDefault, state(1, enabled: false)))
        XCTAssertFalse(RecorderQuickMaskColor.matches(nativeDefault, state(1, channel: 18)))
        XCTAssertFalse(RecorderQuickMaskColor.matches(nativeDefault, state(1, inverted: true)))
        XCTAssertFalse(RecorderQuickMaskColor.matches(nativeDefault, state(0.9999999403953552)))
        XCTAssertTrue(RecorderQuickMaskColor.matches(state(0.5), state(0.5)))
        XCTAssertFalse(RecorderQuickMaskColor.matches(state(0.5), state(0.5000000596046448)))
        XCTAssertFalse(RecorderQuickMaskColor.matches(state(1.125), state(1.125)))
    }

    func testWireStillRefusesAnOutOfRangeQuickMaskColor() {
        let literal = #"""
        {"format":"ch.lkmc.Glims.recording","version":1,"recordingID":"11111111-1111-1111-1111-111111111111","name":"Bound color","origin":{"imageLabel":"Source","initialWidth":4,"initialHeight":3},"symbols":[{"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Layer","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":4,"height":3}}}],"records":[{"ordinal":0,"outcome":"success","command":{"tag":"selectCommand","command":"fromAlpha","radius":0},"binding":{"kind":"context","context":{"layers":["22222222-2222-2222-2222-222222222222"],"channels":[],"target":{"kind":"layer","symbol":"22222222-2222-2222-2222-222222222222"},"masks":[{"owner":"22222222-2222-2222-2222-222222222222","isPresent":false,"enabled":false,"editing":false,"showing":false}],"quickMask":{"enabled":false,"inverted":false,"color":{"space":"srgb","red":1.0000003576278687,"green":0,"blue":0,"alpha":0.5}}}}}]}
        """#
        XCTAssertThrowsError(try RecorderFileCodec.decode(Data(literal.utf8))) {
            XCTAssertEqual($0 as? RecorderFileError, .invalid("sRGB components must be finite and inside 0...1."))
        }
        let bounded = literal.replacingOccurrences(of: "1.0000003576278687", with: "1")
        XCTAssertNoThrow(try RecorderFileCodec.decode(Data(bounded.utf8)))
    }
}
