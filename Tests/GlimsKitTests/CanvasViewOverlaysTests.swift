import CoreGraphics
import XCTest
@testable import GlimsKit

/// Deterministic tests of the View ▸ Show Selection Edges / Show Layer
/// Boundary per-window state and of the pure cached geometry behind the
/// layer-boundary outline: defaults, mask/channel/floating precedence,
/// missing-target clearing, invalid extents and zoom/backing mapping.
final class CanvasViewOverlaysTests: XCTestCase {
    private static let accuracy = 1e-9

    private func layer(_ id: Int32, _ bounds: CGRect) -> EngineSession.Layer {
        EngineSession.Layer(id: id, parent: 0, depth: 0, kind: .pixel,
                            name: "L\(id)", mode: "normal", isVisible: true,
                            hasMask: false, isSelected: id == 1, opacity: 1,
                            bounds: bounds, filterCount: 0)
    }

    private let imageSize = CGSize(width: 64, height: 48)
    private lazy var layers = [
        layer(1, CGRect(x: 4, y: 6, width: 20, height: 12)),   // ordinary active layer
        layer(7, CGRect(x: 10, y: 10, width: 8, height: 8)),   // e.g. a floating layer
        layer(9, CGRect(x: -2, y: 30, width: 40, height: 18)), // offset layer
    ]

    // MARK: Per-window view-state defaults

    func testSelectionEdgesDefaultOnAndToggles() {
        var state = SelectionEdgesViewState()
        XCTAssertTrue(state.showsSelectionEdges)
        XCTAssertEqual(state.menuState, .on)
        state.toggle()
        XCTAssertFalse(state.showsSelectionEdges)
        XCTAssertEqual(state.menuState, .off)
        state.toggle()
        XCTAssertTrue(state.showsSelectionEdges)
        XCTAssertEqual(state.menuState, .on)
    }

    func testLayerBoundaryDefaultsOffAndToggles() {
        var state = LayerBoundaryViewState()
        XCTAssertFalse(state.showsLayerBoundary)
        XCTAssertEqual(state.menuState, .off)
        state.toggle()
        XCTAssertTrue(state.showsLayerBoundary)
        XCTAssertEqual(state.menuState, .on)
        state.toggle()
        XCTAssertFalse(state.showsLayerBoundary)
        XCTAssertEqual(state.menuState, .off)
    }

    // MARK: Boundary resolution from the cached paint target

    func testOrdinaryLayerTargetUsesItsAbsoluteBounds() {
        let rect = LayerBoundaryGeometry.boundaryRect(target: .layer(9), layers: layers, imageSize: imageSize)
        XCTAssertEqual(rect, CGRect(x: -2, y: 30, width: 40, height: 18))
    }

    func testFloatingSelectionTargetUsesTheFloatingLayersOwnBounds() {
        // A floating selection reports as .layer(floating id); the
        // floating layer sits in the cached list with its own bounds.
        let rect = LayerBoundaryGeometry.boundaryRect(target: .layer(7), layers: layers, imageSize: imageSize)
        XCTAssertEqual(rect, CGRect(x: 10, y: 10, width: 8, height: 8))
    }

    func testMaskTargetUsesTheOwnerLayersBoundsNotTheMaskDrawable() {
        let rect = LayerBoundaryGeometry.boundaryRect(target: .mask(layer: 9), layers: layers, imageSize: imageSize)
        XCTAssertEqual(rect, CGRect(x: -2, y: 30, width: 40, height: 18))
    }

    func testChannelTargetUsesTheImageBounds() {
        let rect = LayerBoundaryGeometry.boundaryRect(target: .channel(42), layers: layers, imageSize: imageSize)
        XCTAssertEqual(rect, CGRect(origin: .zero, size: imageSize))
    }

    func testMissingTargetClearsTheBoundary() {
        XCTAssertNil(LayerBoundaryGeometry.boundaryRect(target: nil, layers: layers, imageSize: imageSize))
    }

    func testUnknownLayerIdClearsTheBoundary() {
        XCTAssertNil(LayerBoundaryGeometry.boundaryRect(target: .layer(999), layers: layers, imageSize: imageSize))
        XCTAssertNil(LayerBoundaryGeometry.boundaryRect(target: .mask(layer: 999), layers: layers, imageSize: imageSize))
    }

    func testInvalidCachedExtentsClearTheBoundary() {
        let bad = [
            CGRect(x: 1, y: 1, width: 0, height: 5),                 // zero width
            CGRect(x: 1, y: 1, width: 5, height: 0),                 // zero height
            CGRect(x: 1, y: 1, width: -5, height: 5),                // negative width
            CGRect(x: Double.nan, y: 1, width: 5, height: 5),        // NaN origin
            CGRect(x: 1, y: 1, width: Double.infinity, height: 5),   // infinite extent
            CGRect(x: 1, y: Double.infinity, width: 5, height: 5),
        ]
        for bounds in bad {
            let rows = [layer(1, bounds)]
            XCTAssertNil(LayerBoundaryGeometry.boundaryRect(target: .layer(1), layers: rows, imageSize: imageSize),
                         "invalid bounds \(bounds) must clear the outline")
            XCTAssertNil(LayerBoundaryGeometry.boundaryRect(target: .mask(layer: 1), layers: rows, imageSize: imageSize),
                         "invalid owner bounds \(bounds) must clear the outline")
        }
    }

    func testDegenerateImageSizeClearsTheChannelBoundary() {
        XCTAssertNil(LayerBoundaryGeometry.boundaryRect(target: .channel(1), layers: layers,
                                                         imageSize: CGSize(width: 0, height: 10)))
        XCTAssertNil(LayerBoundaryGeometry.boundaryRect(target: .channel(1), layers: layers,
                                                         imageSize: CGSize(width: 10, height: -3)))
    }

    func testIsDisplayable() {
        XCTAssertTrue(LayerBoundaryGeometry.isDisplayable(CGRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertFalse(LayerBoundaryGeometry.isDisplayable(.zero))
        XCTAssertFalse(LayerBoundaryGeometry.isDisplayable(CGRect(x: Double.infinity, y: 0, width: 1, height: 1)))
    }

    // MARK: Zoom/backing mapping of the outline

    func testViewRectMapsImagePixelsThroughThePointScale() {
        // All factors below are exact in binary, so equality is exact.
        let boundary = CGRect(x: 10, y: 20, width: 30, height: 8)
        XCTAssertEqual(LayerBoundaryGeometry.viewRect(for: boundary, zoomPercent: 100, backingFactor: 1),
                       boundary)
        XCTAssertEqual(LayerBoundaryGeometry.viewRect(for: boundary, zoomPercent: 100, backingFactor: 2),
                       CGRect(x: 5, y: 10, width: 15, height: 4))
        // 200% at backing 2 cancels back to one view point per image pixel.
        XCTAssertEqual(LayerBoundaryGeometry.viewRect(for: boundary, zoomPercent: 200, backingFactor: 2),
                       boundary)
        XCTAssertEqual(LayerBoundaryGeometry.viewRect(for: boundary, zoomPercent: 50, backingFactor: 1),
                       CGRect(x: 5, y: 10, width: 15, height: 4))
    }

    func testStrokeStaysInsideFullImageEdgesAtBothBackingDensities() {
        XCTAssertEqual(LayerBoundaryGeometry.strokeRect(for: CGRect(x: 0, y: 0, width: 64, height: 48),
                                                        backingFactor: 1),
                       CGRect(x: 0.5, y: 0.5, width: 63, height: 47))
        XCTAssertEqual(LayerBoundaryGeometry.strokeRect(for: CGRect(x: 0, y: 0, width: 32, height: 24),
                                                        backingFactor: 2),
                       CGRect(x: 0.25, y: 0.25, width: 31.5, height: 23.5))
    }

    func testFractionalBoundaryAlignsToDevicePixelCenters() {
        XCTAssertEqual(LayerBoundaryGeometry.strokeRect(for: CGRect(x: 2.25, y: 3.75, width: 4, height: 5),
                                                        backingFactor: 1),
                       CGRect(x: 2.5, y: 3.5, width: 4, height: 5))
        XCTAssertNil(LayerBoundaryGeometry.strokeRect(for: .zero, backingFactor: 1))
        XCTAssertNil(LayerBoundaryGeometry.strokeRect(for: CGRect(x: 0, y: 0, width: 1, height: 1),
                                                      backingFactor: .infinity))
    }

    func testDeviceLineWidthIsOnePhysicalPixelInViewPoints() {
        XCTAssertEqual(LayerBoundaryGeometry.deviceLineWidth(zoomPercent: 100, backingFactor: 1), 1,
                       accuracy: Self.accuracy)
        XCTAssertEqual(LayerBoundaryGeometry.deviceLineWidth(zoomPercent: 100, backingFactor: 2), 0.5,
                       accuracy: Self.accuracy)
        XCTAssertEqual(LayerBoundaryGeometry.deviceLineWidth(zoomPercent: 200, backingFactor: 2), 0.5,
                       accuracy: Self.accuracy)
        XCTAssertEqual(LayerBoundaryGeometry.deviceLineWidth(zoomPercent: 3200, backingFactor: 3),
                       1.0 / 3.0, accuracy: Self.accuracy)
        // A degenerate backing factor yields no drawable width.
        XCTAssertEqual(LayerBoundaryGeometry.deviceLineWidth(zoomPercent: 100, backingFactor: 0), 0)
    }
}
