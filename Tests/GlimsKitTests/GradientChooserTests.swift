import AppKit
import CGlimsEngine
import XCTest
@testable import GlimsKit

/// Pure checks for the Gradient tool's chooser layer: the preference
/// store's default/reset and identity-only persistence, the allowed
/// settings (blend popup without RGB Linear, all three shapes), the
/// per-gesture snapshot's capture semantics, and the shared
/// kind-parameterized resource model. No engine, no AppKit windows.
final class GradientChooserTests: XCTestCase {
    private func identity(_ name: String, collection: String? = "Gradients",
                          isInternal: Bool = false) -> EngineSession.ResourceIdentity {
        EngineSession.ResourceIdentity(name: name, collection: collection, isInternal: isInternal)
    }

    private func row(_ id: UInt64, _ name: String) -> ResourceRow {
        ResourceRow(id: id, name: name, identity: identity(name))
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suite = "ch.lkmc.Glims.tests.gradientchooser.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }

    // MARK: Preference store: default and reset

    func testStoreDefaultsToForegroundBackgroundDefaultAndPerceptualSettings() {
        withDefaults { defaults in
            let prefs = GradientToolStore(defaults: defaults).preferences
            XCTAssertNil(prefs.identity, "no stored choice is the Foreground-to-Background Default")
            XCTAssertEqual(prefs.shape, .linear)
            XCTAssertFalse(prefs.reverse)
            XCTAssertEqual(prefs.blendSpace, .rgbPerceptual, "the default blend preserves the old appearance")
            XCTAssertEqual(prefs.opacity, 1)
            XCTAssertEqual(GradientToolPreferences.default.identity, nil)
        }
    }

    func testStorePersistsIdentityAndPrimitiveSettingsOnly() throws {
        withDefaults { defaults in
            let store = GradientToolStore(defaults: defaults)
            var prefs = store.preferences
            prefs.identity = identity("Pastel")
            prefs.shape = .radial
            prefs.reverse = true
            prefs.blendSpace = .cieLab
            prefs.opacity = 0.5
            store.set(prefs)
            XCTAssertEqual(GradientToolStore(defaults: defaults).preferences, prefs,
                           "the preferences survive a fresh store instance")
            let raw = String(decoding: defaults.data(forKey: GradientToolStore.preferencesKey)!, as: UTF8.self)
            XCTAssertTrue(raw.contains("\"name\":\"Pastel\""))
            XCTAssertFalse(raw.contains("\"id\""), "no numeric session handle is persisted")
            XCTAssertFalse(raw.contains("foreground"), "the FG/BG colors are never persisted")
            XCTAssertFalse(raw.contains("image"), "no rendered preview is persisted")
        }
    }

    func testSetIdentityKeepsTheOtherSettings() {
        withDefaults { defaults in
            let store = GradientToolStore(defaults: defaults)
            var prefs = store.preferences
            prefs.shape = .bilinear
            prefs.opacity = 0.25
            store.set(prefs)
            store.setIdentity(identity("Pastel"))
            let read = store.preferences
            XCTAssertEqual(read.identity, identity("Pastel"))
            XCTAssertEqual(read.shape, .bilinear)
            XCTAssertEqual(read.opacity, 0.25)
        }
    }

    func testResetRestoresTheDefaults() {
        withDefaults { defaults in
            let store = GradientToolStore(defaults: defaults)
            var prefs = store.preferences
            prefs.identity = identity("Pastel")
            prefs.reverse = true
            store.set(prefs)
            store.reset()
            XCTAssertNil(defaults.data(forKey: GradientToolStore.preferencesKey),
                         "reset removes the entry rather than storing a null")
            XCTAssertEqual(store.preferences, .default, "reset is the Foreground-to-Background Default")
            XCTAssertNil(GradientToolStore(defaults: defaults).preferences.identity)
        }
    }

    func testCorruptDataReadsAsDefaults() {
        withDefaults { defaults in
            defaults.set(Data("not json".utf8), forKey: GradientToolStore.preferencesKey)
            XCTAssertEqual(GradientToolStore(defaults: defaults).preferences, .default,
                           "corrupt data reads as the defaults, not a crash")
        }
    }

    // MARK: Allowed settings

    func testBlendPopupOffersOnlyPerceptualRGBAndLab() {
        XCTAssertEqual(EngineSession.GradientBlendSpace.selectable, [.rgbPerceptual, .cieLab])
        XCTAssertFalse(EngineSession.GradientBlendSpace.selectable.contains(.rgbLinear),
                       "RGB Linear is UNSUPPORTED by the backend and never offered")
        XCTAssertEqual(EngineSession.GradientBlendSpace.rgbPerceptual.name, "Perceptual RGB")
        XCTAssertEqual(EngineSession.GradientBlendSpace.cieLab.name, "Lab")
    }

    func testAllThreeGradientShapesRemainAvailable() {
        XCTAssertEqual(EngineSession.GradientShape.allCases, [.linear, .bilinear, .radial])
        XCTAssertEqual(EngineSession.GradientShape.allCases.map(\.rawValue), [0, 1, 2])
    }

    // MARK: The Default's built-in identity

    func testDefaultForegroundBackgroundIdentityIsTheBuiltin() {
        let d = EngineSession.ResourceIdentity.defaultForegroundBackground
        XCTAssertEqual(d.collection, "gimp-gradient-fg-bg-rgb")
        XCTAssertTrue(d.isInternal)
        XCTAssertFalse(d.name.isEmpty, "native ignores an internal resource's name, but it must be nonempty")
    }

    // MARK: Gesture snapshot capture semantics

    func testSnapshotCapturesDefaultIdentityAndForcesOpaqueColors() {
        let snap = GradientGestureSnapshot.capture(
            identity: nil, shape: .radial, reverse: true, blendSpace: .cieLab, opacity: 0.25,
            foreground: NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.4),
            background: .white,
            from: CGPoint(x: 1, y: 2), to: CGPoint(x: 9, y: 8))
        XCTAssertEqual(snap.identity, .defaultForegroundBackground,
                       "a nil choice captures the built-in FG-to-BG identity so reverse/blend/opacity still work")
        XCTAssertEqual(snap.settings.shape, .radial)
        XCTAssertTrue(snap.settings.reverse)
        XCTAssertEqual(snap.settings.blendSpace, .cieLab)
        XCTAssertEqual(snap.settings.opacity, 0.25)
        XCTAssertEqual(snap.settings.foreground.alphaComponent, 1,
                       "FG/BG are opaque per the backend contract; stop types provide transparency")
        XCTAssertEqual(snap.settings.background.alphaComponent, 1)
        XCTAssertEqual(snap.settings.foreground.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(snap.settings.foreground.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(snap.from, CGPoint(x: 1, y: 2))
        XCTAssertEqual(snap.to, CGPoint(x: 9, y: 8))
    }

    func testSnapshotIsAValueUnaffectedByLaterInputChanges() {
        var foreground = NSColor.black
        let chosen = identity("Pastel")
        let snap = GradientGestureSnapshot.capture(
            identity: chosen, shape: .linear, reverse: false, blendSpace: .rgbPerceptual, opacity: 1,
            foreground: foreground, background: .white, from: .zero, to: .zero)
        foreground = .red
        XCTAssertEqual(snap.settings.foreground.redComponent, 0, accuracy: 0.01,
                       "mutating the source color after capture does not change the snapshot")
        XCTAssertEqual(snap.identity, chosen)
        let moved = snap.withEndpoints(from: CGPoint(x: 5, y: 5), to: CGPoint(x: 50, y: 5))
        XCTAssertEqual(moved.from, CGPoint(x: 5, y: 5))
        XCTAssertEqual(moved.to, CGPoint(x: 50, y: 5))
        XCTAssertEqual(moved.identity, snap.identity)
        XCTAssertEqual(moved.settings, snap.settings, "only the endpoints move with the drag")
    }

    @MainActor
    func testToolStateGradientSnapshotCapturesOnceAndPersistsThroughTheStore() {
        withDefaults { defaults in
            let state = ToolState(gradientStore: GradientToolStore(defaults: defaults))
            state.foreground = .black
            state.background = .white
            state.gradientShape = .bilinear
            state.gradientReverse = true
            state.gradientBlendSpace = .cieLab
            state.gradientOpacity = 0.5
            state.setGradientResource(identity("Pastel"))
            let snap = state.gradientSnapshot(from: CGPoint(x: 0, y: 0), to: CGPoint(x: 10, y: 0))
            XCTAssertEqual(snap.identity, identity("Pastel"))
            XCTAssertEqual(snap.settings.shape, .bilinear)
            XCTAssertTrue(snap.settings.reverse)
            XCTAssertEqual(snap.settings.blendSpace, .cieLab)
            XCTAssertEqual(snap.settings.opacity, 0.5)
            XCTAssertEqual(snap.settings.foreground.alphaComponent, 1)
            // Only identity + own primitives persisted, never handles or colors.
            XCTAssertEqual(GradientToolStore(defaults: defaults).preferences.identity, identity("Pastel"))
            XCTAssertEqual(GradientToolStore(defaults: defaults).preferences.shape, .bilinear)
            // Changing live preferences after the capture cannot redirect it.
            state.setGradientResource(nil)
            state.gradientOpacity = 1
            XCTAssertEqual(snap.identity, identity("Pastel"))
            XCTAssertEqual(snap.settings.opacity, 0.5)
            // The Default (nil) snapshot uses the built-in identity.
            let d = state.gradientSnapshot(from: .zero, to: .zero)
            XCTAssertEqual(d.identity, .defaultForegroundBackground)
            XCTAssertEqual(d.settings.blendSpace, .cieLab, "settings still come from the store")
            // A fresh state restores the persisted choice after a "restart".
            state.setGradientResource(identity("Pastel"))
            XCTAssertEqual(ToolState(gradientStore: GradientToolStore(defaults: defaults)).gradientResource,
                           identity("Pastel"))
        }
    }

    // MARK: Shared model, parameterized by resource kind

    func testResourceModelIsKindParameterizedAndPatternAliasesHold() {
        let pattern: PatternChooserModel = ResourceChooserModel(kind: .pattern, currentIdentity: nil)
        let gradient = ResourceChooserModel(kind: .gradient, currentIdentity: identity("Pastel"))
        XCTAssertEqual(pattern.kind, .pattern)
        XCTAssertEqual(gradient.kind, .gradient)
        XCTAssertEqual(PatternChooserModel(currentIdentity: nil).kind, .pattern,
                       "the pattern alias keeps the pattern default kind")
        let patternRow: PatternRow = ResourceRow(id: 1, name: "Bricks", identity: identity("Bricks", collection: "Patterns"))
        XCTAssertEqual(patternRow.name, "Bricks")
        let state: PatternChooserState = .ready
        XCTAssertEqual(state, .ready)
        XCTAssertEqual(ResourceThumbnailQueue.batchSize, 32)
        XCTAssertEqual(PatternThumbnailQueue.batchSize, 32, "the lazy batch bound stays 32")
    }

    func testGradientModelKeepsThePendingChoiceThroughSearchAndStaleDeliveries() {
        let model = ResourceChooserModel(kind: .gradient, currentIdentity: identity("Pastel"))
        XCTAssertTrue(model.deliver(generation: 0,
                                    rows: [row(1, "Pastel"), row(2, "Sky"), row(3, "Flare")],
                                    resolvedCurrent: 1, error: nil))
        XCTAssertEqual(model.state, .ready)
        XCTAssertEqual(model.selection, 1)
        XCTAssertEqual(model.pendingIdentity(), identity("Pastel"))
        // Search hides the selected row: the pending identity is retained.
        XCTAssertEqual(model.rows(matching: "sky").map(\.id), [2])
        XCTAssertEqual(model.pendingIdentity(), identity("Pastel"),
                       "filtering is not a new choice; the explicit pick persists")
        // A programmatic reload keeps it too.
        model.select(nil)
        XCTAssertEqual(model.pendingIdentity(), identity("Pastel"),
                       "a resolved current choice stays committable without a highlighted row")
        // Close-generation invalidation drops late results.
        model.invalidate()
        XCTAssertFalse(model.deliver(generation: 0, rows: [row(9, "Other")], resolvedCurrent: nil, error: nil))
        XCTAssertFalse(model.deliverThumbnails(generation: 0, rendered: [9: image1x1()], failed: [:]))
        XCTAssertTrue(model.rows.contains(where: { $0.id == 1 }), "the stale delivery changed nothing")
    }

    func testGradientModelReportsMissingOnlyOnVerifiedNotFound() {
        let missing = ResourceChooserModel(kind: .gradient, currentIdentity: identity("Gone"))
        missing.deliver(generation: 0, rows: [row(1, "Pastel")], resolvedCurrent: nil, error: nil)
        XCTAssertEqual(missing.missingIdentity, identity("Gone"))
        XCTAssertNil(missing.resolutionError)
        XCTAssertNil(missing.pendingIdentity(), "a missing gradient is refused, never substituted")

        let busy = ResourceChooserModel(kind: .gradient, currentIdentity: identity("Pastel"))
        busy.deliver(generation: 0, rows: [row(1, "Pastel")], resolvedCurrent: nil,
                     resolutionError: EngineSession.EngineError(status: Int32(GLIMS_STATUS_BUSY.rawValue),
                                                                message: "engine busy"),
                     error: nil)
        XCTAssertNil(busy.missingIdentity, "a busy failure is not a missing gradient")
        XCTAssertEqual(busy.resolutionError, "engine busy")
        XCTAssertNil(busy.pendingIdentity())
    }

    func testThumbnailQueueBatchesBoundedlyForAnyKind() {
        let queue = ResourceThumbnailQueue()
        queue.begin(generation: 3)
        XCTAssertEqual(queue.request((1...40).map { UInt64($0) }), 40)
        let batch = queue.beginBatch()
        XCTAssertEqual(batch.count, 32, "one native batch renders at most 32 thumbnails")
        XCTAssertTrue(queue.beginBatch().isEmpty, "no overlapping batches")
        XCTAssertTrue(queue.complete(generation: 3, rendered: Array(batch), failed: [:]))
        XCTAssertEqual(queue.beginBatch().count, 8, "the rest stay pending")
        XCTAssertFalse(queue.complete(generation: 2, rendered: [40], failed: [:]),
                       "a stale generation's completion is dropped")
    }

    private func image1x1() -> CGImage {
        let provider = CGDataProvider(data: Data([0, 0, 0, 255]) as CFData)!
        return CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false,
                       intent: .defaultIntent)!
    }
}
