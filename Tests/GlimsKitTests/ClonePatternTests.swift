import XCTest
@testable import GlimsKit

/// Clone's Pattern source: the brush takes the pattern Fill shares and the
/// Aligned choice, and drops the image source; Heal and the Image source
/// are unchanged.
final class ClonePatternTests: XCTestCase {
    private let pine = EngineSession.ResourceIdentity(name: "Pine", collection: nil, isInternal: false)

    @MainActor private func withTools(_ body: (ToolState, PatternFillStore) throws -> Void) rethrows {
        let suite = ScratchDefaults.suiteName("clone-pattern")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let patterns = PatternFillStore(defaults: defaults)
        let tools = ToolState(brushStore: BrushSelectionStore(defaults: defaults),
                              gradientStore: GradientToolStore(defaults: defaults), patternStore: patterns)
        try body(tools, patterns)
    }

    @MainActor func testImageSourceIsTheDefault() {
        withTools { tools, patterns in
            patterns.set(pine)
            tools.cloneSource = .init(drawable: 7, x: 3, y: 4)
            XCTAssertEqual(tools.cloneFrom, .image)
            let brush = tools.brush(for: .clone)
            XCTAssertEqual(brush.source, .init(drawable: 7, x: 3, y: 4))
            XCTAssertNil(brush.clonePattern)
            XCTAssertFalse(brush.hasPaintOptions)
        }
    }

    @MainActor func testPatternSourceTakesTheSharedPatternAndAlignment() {
        withTools { tools, patterns in
            tools.cloneSource = .init(drawable: 7, x: 3, y: 4)
            tools.cloneFrom = .pattern
            XCTAssertNil(tools.brush(for: .clone).clonePattern, "no pattern chosen yet")
            XCTAssertNil(tools.brush(for: .clone).source)

            patterns.set(pine)
            XCTAssertEqual(tools.brush(for: .clone).clonePattern, .init(resource: pine, aligned: true))
            XCTAssertNil(tools.brush(for: .clone).source)
            XCTAssertTrue(tools.brush(for: .clone).hasPaintOptions, "a pattern stroke is not recorded yet")

            tools.cloneAlignment.isAligned = false
            XCTAssertEqual(tools.brush(for: .clone).clonePattern, .init(resource: pine, aligned: false))
        }
    }

    @MainActor func testHealIgnoresThePatternSource() {
        withTools { tools, patterns in
            patterns.set(pine)
            tools.cloneSource = .init(drawable: 7, x: 3, y: 4)
            tools.cloneFrom = .pattern
            let heal = tools.brush(for: .heal)
            XCTAssertNil(heal.clonePattern)
            XCTAssertEqual(heal.source, .init(drawable: 7, x: 3, y: 4))
        }
    }

    @MainActor func testChangingTheSourceNotifiesOnlyOnAChange() {
        withTools { tools, _ in
            var notified = 0
            let token = tools.observe { notified += 1 }
            defer { tools.removeObserver(token) }
            tools.cloneFrom = .image
            XCTAssertEqual(notified, 0)
            tools.cloneFrom = .pattern
            XCTAssertEqual(notified, 1)
        }
    }
}
