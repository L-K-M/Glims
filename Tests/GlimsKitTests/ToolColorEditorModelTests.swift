import AppKit
import XCTest
@testable import GlimsKit

@MainActor
final class ToolColorEditorModelTests: XCTestCase {

    func testNonconvertiblePatternWellColorIsRefusedWithoutAComponentException() {
        let pattern = NSColor(patternImage: NSImage(size: NSSize(width: 1, height: 1)))
        XCTAssertNil(pattern.usingColorSpace(.sRGB), "the fixture must have no sRGB conversion")
        let initial = NSColor(srgbRed: 0.123456789, green: 0.4, blue: 0.6, alpha: 1)
        let model = ToolColorEditorModel(target: .foreground, color: initial)
        var commits = 0
        model.onCommit = { _, _ in commits += 1 }
        XCTAssertFalse(model.applyWellColor(pattern))
        XCTAssertEqual(model.color, initial)
        XCTAssertEqual(commits, 0)
        XCTAssertTrue(model.lastError?.contains("cannot be converted to sRGB") == true)
    }

    // MARK: Exact fractional roundtrip

    func testPercentAndFloatColumnsRoundtripExactFractionalValues() {
        let color = NSColor(srgbRed: 0.255, green: 1.0 / 3.0, blue: 0.1, alpha: 1)
        let model = ToolColorEditorModel(target: .foreground, color: color)

        // Capture keeps the exact doubles; nothing is quantized to 8 bits.
        XCTAssertEqual(model.component(.red), 0.255)
        XCTAssertEqual(model.component(.green), 1.0 / 3.0)
        XCTAssertEqual(model.component(.blue), 0.1)

        // Both columns render simultaneously at full precision.
        XCTAssertEqual(model.floatText(.red), "0.255")
        XCTAssertEqual(model.percentText(.red), "25.5")
        XCTAssertEqual(Double(model.floatText(.green)), 1.0 / 3.0)
        XCTAssertEqual(Double(model.percentText(.green)), (1.0 / 3.0) * 100)

        // A float draft roundtrips exactly.
        XCTAssertTrue(model.applyFloatDraft("0.255", for: .red))
        XCTAssertEqual(model.component(.red), 0.255)

        // The displayed percent text parses back and reapplies to the exact
        // same float for this value (25.5 / 100 == 0.255 in Double).
        XCTAssertTrue(model.applyPercentDraft(model.percentText(.red), for: .red))
        XCTAssertEqual(model.component(.red), 0.255)

        // Reapplying the displayed float text is always exact.
        XCTAssertTrue(model.applyFloatDraft(model.floatText(.green), for: .green))
        XCTAssertEqual(model.component(.green), 1.0 / 3.0)

        // Fractional percents are not quantized to integers either.
        XCTAssertTrue(model.applyPercentDraft("0.1", for: .blue))
        XCTAssertEqual(model.component(.blue), 0.1 / 100)
        XCTAssertNotEqual(model.component(.blue), 0)
        XCTAssertNotEqual(model.component(.blue), 1.0 / 255.0)
    }

    // MARK: Invalid, nonfinite and out-of-range drafts

    func testInvalidNonfiniteAndOutOfRangeDraftsPreserveColorAndReportActionableError() throws {
        let model = ToolColorEditorModel(target: .background,
                                         color: NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1))
        var committed: [(ToolColorTarget, NSColor)] = []
        model.onCommit = { target, color in committed.append((target, color)) }

        for draft in ["", "   ", "abc", "12x", "nan", "NaN", "inf", "-inf", "100.5", "101", "-0.5"] {
            XCTAssertFalse(model.applyPercentDraft(draft, for: .red), "draft \(draft)")
            XCTAssertEqual(model.component(.red), 0.25, "draft \(draft) must leave the color unchanged")
            XCTAssertNotNil(model.lastError, "draft \(draft) must report an error")
        }
        for draft in ["", "nope", "nan", "inf", "1.0001", "2", "-0.0001"] {
            XCTAssertFalse(model.applyFloatDraft(draft, for: .green), "draft \(draft)")
            XCTAssertEqual(model.component(.green), 0.5, "draft \(draft) must leave the color unchanged")
            XCTAssertNotNil(model.lastError, "draft \(draft) must report an error")
        }
        XCTAssertTrue(committed.isEmpty, "refused drafts never commit")

        // The error names the component and the accepted range.
        XCTAssertFalse(model.applyPercentDraft("150", for: .blue))
        let error = try XCTUnwrap(model.lastError)
        XCTAssertTrue(error.contains("Blue"))
        XCTAssertTrue(error.contains("0 to 100"))
        XCTAssertEqual(model.component(.blue), 0.75)

        // Boundary values are accepted, and an accepted draft clears the error.
        XCTAssertTrue(model.applyPercentDraft("100", for: .blue))
        XCTAssertEqual(model.component(.blue), 1)
        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.applyFloatDraft("0", for: .blue))
        XCTAssertEqual(model.component(.blue), 0)
        XCTAssertEqual(committed.count, 2)
    }

    func testReapplyingAnUnchangedPercentReadoutPreservesTheOriginalDouble() {
        let original = 7.0 / 10001.0
        XCTAssertNotEqual((original * 100) / 100, original,
                          "the fixture must expose multiply/divide rounding")
        let model = ToolColorEditorModel(target: .foreground,
            color: NSColor(srgbRed: original, green: 0.5, blue: 0.75, alpha: 1))
        let before = model.component(.red)
        var commits = 0
        model.onCommit = { _, _ in commits += 1 }
        XCTAssertTrue(model.applyPercentDraft(model.percentText(.red), for: .red))
        XCTAssertEqual(model.component(.red), before)
        XCTAssertEqual(commits, 0)
    }

    // MARK: Captured target identity

    func testCommitAlwaysReportsTheCapturedTargetIdentity() {
        let model = ToolColorEditorModel(target: .background,
                                         color: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1))
        var commits: [(ToolColorTarget, NSColor)] = []
        model.onCommit = { target, color in commits.append((target, color)) }

        XCTAssertTrue(model.applyFloatDraft("0.8", for: .red))
        XCTAssertTrue(model.applyPercentDraft("50", for: .green))
        model.applyWellColor(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 1))

        // Every commit carries the captured target, never the other slot.
        XCTAssertEqual(commits.map(\.0), [.background, .background, .background])
        XCTAssertEqual(model.target, .background)
        // Commits carry full-precision opaque colors.
        for (_, color) in commits {
            XCTAssertEqual(color.alphaComponent, 1)
        }
        XCTAssertEqual(commits[0].1.redComponent, 0.8)
        XCTAssertEqual(commits[1].1.greenComponent, 0.5)
        XCTAssertEqual(commits[2].1.blueComponent, 0.3)
    }

    func testTargetKeyPathsAddressTheGlobalToolStateSlots() {
        let state = ToolState.shared
        let oldForeground = state.foreground
        let oldBackground = state.background
        defer {
            state.foreground = oldForeground
            state.background = oldBackground
            state.notifyChange()
        }
        state[keyPath: ToolColorTarget.foreground.keyPath] = .red
        state[keyPath: ToolColorTarget.background.keyPath] = .blue
        XCTAssertEqual(state.foreground, .red)
        XCTAssertEqual(state.background, .blue)
    }

    // MARK: Well opacity and external sync

    func testWellPickIsForcedOpaqueAndExternalSyncDoesNotCommit() {
        let model = ToolColorEditorModel(target: .foreground, color: .black)
        var commitCount = 0
        model.onCommit = { _, _ in commitCount += 1 }

        // A well pick carrying alpha keeps the tool color opaque.
        model.applyWellColor(NSColor(srgbRed: 0.5, green: 0.25, blue: 0.75, alpha: 0.3))
        XCTAssertEqual(model.color.alphaComponent, 1)
        XCTAssertEqual(model.component(.red), 0.5)
        XCTAssertEqual(model.component(.green), 0.25)
        XCTAssertEqual(commitCount, 1)

        // External sampling re-seeds without committing back (no feedback loop).
        model.syncExternal(NSColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 1))
        XCTAssertEqual(model.component(.red), 0.9)
        XCTAssertEqual(model.component(.green), 0.1)
        XCTAssertEqual(commitCount, 1)
        XCTAssertNil(model.lastError)
        XCTAssertTrue(model.hasSameComponents(as: NSColor(srgbRed: 0.9, green: 0.1, blue: 0.2, alpha: 1)))
        XCTAssertFalse(model.hasSameComponents(as: .black))
    }
}
