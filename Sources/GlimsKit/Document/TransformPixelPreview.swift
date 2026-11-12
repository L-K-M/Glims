import CoreGraphics
import Foundation

/// A bounded composite preview. Each request uses an independent image copy;
/// the document's pixels, selection and Undo history remain committed state.
@MainActor
final class TransformPixelPreview {
    struct Request: Equatable {
        let layer: Int32
        let original: CGRect
        let matrix: ProjectiveTransform
        let interpolation: EngineSession.Interpolation
        let imageSize: CGSize
        let sourceRevision: UInt64
        let destination: CanvasDisplayDestination
        let proof: CanvasSoftProof?
        let maximumEdge: Int
        let viewport: CGRect?
        let displayScale: Double

        init(layer: Int32, original: CGRect, matrix: ProjectiveTransform,
             interpolation: EngineSession.Interpolation, imageSize: CGSize,
             sourceRevision: UInt64, destination: CanvasDisplayDestination = .srgbFallback,
             proof: CanvasSoftProof? = nil, maximumEdge: Int = 1536,
             viewport: CGRect? = nil, displayScale: Double = 1) {
            self.layer = layer
            self.original = original
            self.matrix = matrix
            self.interpolation = interpolation
            self.imageSize = imageSize
            self.sourceRevision = sourceRevision
            self.destination = destination
            self.proof = proof
            self.maximumEdge = maximumEdge
            self.viewport = viewport
            self.displayScale = displayScale
        }

        private var region: CGRect { viewport ?? CGRect(origin: .zero, size: imageSize) }

        var renderScale: Double {
            min(displayScale, Double(maximumEdge) / max(region.width, region.height))
        }

        var renderArea: CGRect {
            let left = floor(region.minX * renderScale), top = floor(region.minY * renderScale)
            return CGRect(x: left, y: top, width: ceil(region.maxX * renderScale) - left,
                          height: ceil(region.maxY * renderScale) - top)
        }

        var outputSize: CGSize { renderArea.size }

        var isValid: Bool {
            layer > 0 && (1...4096).contains(maximumEdge)
                && imageSize.width.isFinite && imageSize.height.isFinite
                && imageSize.width >= 1 && imageSize.height >= 1
                && imageSize.width <= Double(Int32.max) && imageSize.height <= Double(Int32.max)
                && displayScale.isFinite && displayScale > 0 && displayScale <= 256
                && region.minX.isFinite && region.minY.isFinite
                && region.width.isFinite && region.height.isFinite && !region.isEmpty
                && CGRect(origin: .zero, size: imageSize).contains(region)
                && renderArea.maxX <= Double(Int32.max) && renderArea.maxY <= Double(Int32.max)
                && matrix.projectedBounds(forSource: original) != nil
        }

        /// While dragging, the last completed matrix may trail the outline.
        /// A different source, target, resampler or color view never may.
        func hasSameSource(as other: Self) -> Bool {
            layer == other.layer && original == other.original && imageSize == other.imageSize
                && sourceRevision == other.sourceRevision && interpolation == other.interpolation
                && destination == other.destination && proof == other.proof && maximumEdge == other.maximumEdge
                && viewport == other.viewport && displayScale == other.displayScale
        }
    }

    typealias Render = (Request, @escaping @MainActor (Result<CGImage, Error>) -> Void) -> Void
    private let render: Render
    private let changed: () -> Void
    private let failed: (Error) -> Void
    private var desired: Request?
    private var completed: Request?
    private var running = false
    private var epoch: UInt64 = 0
    private(set) var image: CGImage?
    private(set) var displayedRequest: Request?
    var isPending: Bool { running || desired != completed }

    init(render: @escaping Render, changed: @escaping () -> Void, failed: @escaping (Error) -> Void) {
        self.render = render
        self.changed = changed
        self.failed = failed
    }

    /// At most one native job and one latest desired request. Pointer samples
    /// replace the latter instead of building an input queue behind the mouse.
    func update(_ request: Request?) {
        guard desired != request else { return }
        if request == nil {
            epoch &+= 1
            completed = nil
        }
        desired = request
        if let displayedRequest, request?.hasSameSource(as: displayedRequest) != true {
            image = nil
            self.displayedRequest = nil
            changed()
        }
        startNext()
    }

    private func startNext() {
        guard !running, let request = desired, request != completed else { return }
        running = true
        let acceptedEpoch = epoch
        render(request) { [self] result in
            running = false
            if acceptedEpoch == epoch, desired?.hasSameSource(as: request) == true {
                completed = request
                switch result {
                case .success(let pixels):
                    image = pixels
                    displayedRequest = request
                    changed()
                case .failure(let error):
                    // One failure per exact request. New geometry or source
                    // can retry; redraw alone cannot create a busy loop.
                    if desired == request { failed(error) }
                }
            }
            startNext()
        }
    }
}
