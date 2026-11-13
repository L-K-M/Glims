import CoreGraphics
import Foundation

/// The canvas owns at most one native preview job and one latest request.
/// Each job reads the same immutable native baseline; replies from a canceled
/// panel cannot restore its pixels or become the next panel's accepted state.
@MainActor
final class ComponentPixelPreview<Settings: ComponentPreviewSettings> {
    struct Request: Equatable {
        let token: UInt64
        let settings: Settings
        let imageSize: CGSize
        let destination: CanvasDisplayDestination
        let proof: CanvasSoftProof?
        let viewport: CGRect
        let displayScale: Double
        var maximumEdge = 2048

        var renderScale: Double {
            min(displayScale, Double(maximumEdge) / max(viewport.width, viewport.height))
        }

        var renderArea: CGRect {
            let x = floor(viewport.minX * renderScale), y = floor(viewport.minY * renderScale)
            return CGRect(x: x, y: y, width: ceil(viewport.maxX * renderScale) - x,
                          height: ceil(viewport.maxY * renderScale) - y)
        }

        var isValid: Bool {
            token != 0 && settings.isValid && (1...4096).contains(maximumEdge)
                && imageSize.width.isFinite && imageSize.height.isFinite
                && imageSize.width >= 1 && imageSize.height >= 1
                && imageSize.width <= Double(Int32.max) && imageSize.height <= Double(Int32.max)
                && displayScale.isFinite && displayScale > 0 && displayScale <= 256
                && viewport.minX.isFinite && viewport.minY.isFinite
                && viewport.width.isFinite && viewport.height.isFinite && !viewport.isEmpty
                && CGRect(origin: .zero, size: imageSize).contains(viewport)
                && renderArea.maxX <= Double(Int32.max) && renderArea.maxY <= Double(Int32.max)
        }

        func sharesView(with other: Self) -> Bool {
            token == other.token && imageSize == other.imageSize && destination == other.destination
                && proof == other.proof && viewport == other.viewport && displayScale == other.displayScale
                && maximumEdge == other.maximumEdge
        }
    }

    typealias Render = (Request, @escaping @MainActor (Result<CGImage, Error>) -> Void) -> Void
    private let render: Render
    private let changed: () -> Void
    private let failed: (Error) -> Void
    private var desired: Request?
    private var completed: Request?
    private var failedRequest: Request?
    private var running = false
    private var epoch: UInt64 = 0
    private(set) var image: CGImage?
    private(set) var displayedRequest: Request?
    var isPending: Bool { running || desired != completed }
    var isCurrent: Bool { image != nil && desired != nil && displayedRequest == desired && !isPending }

    init(render: @escaping Render, changed: @escaping () -> Void, failed: @escaping (Error) -> Void) {
        self.render = render
        self.changed = changed
        self.failed = failed
    }

    func update(_ request: Request?, retryFailure: Bool = false) {
        // Explicit panel actions may retry a transient failure; ordinary draw
        // invalidations must never create an automatic retry loop.
        if desired == request {
            guard retryFailure, request != nil, !running else { return }
            guard failedRequest == request else {
                // An Apply refusal can leave the panel showing an error even
                // though its pixels remain valid. Republish that ready state.
                changed()
                return
            }
            completed = nil
            failedRequest = nil
        }
        desired = request
        if request == nil {
            epoch &+= 1
            completed = nil
            failedRequest = nil
        }
        if let displayedRequest, request?.sharesView(with: displayedRequest) != true {
            image = nil
            self.displayedRequest = nil
        }
        changed()
        startNext()
    }

    private func startNext() {
        guard !running, let request = desired, request != completed else { return }
        running = true
        let acceptedEpoch = epoch
        render(request) { [self] result in
            running = false
            var latestFailure: Error?
            if acceptedEpoch == epoch, desired?.sharesView(with: request) == true {
                completed = request
                switch result {
                case .success(let pixels):
                    failedRequest = nil
                    image = pixels
                    displayedRequest = request
                case .failure(let error):
                    failedRequest = request
                    if desired == request { latestFailure = error }
                }
            }
            changed()
            if let latestFailure, desired == request { failed(latestFailure) }
            startNext()
        }
    }
}

typealias InkPixelPreview<Settings: ComponentPreviewSettings> = ComponentPixelPreview<Settings>

typealias InkLevelsPixelPreview = InkPixelPreview<EngineSession.InkLevelsSettings>
typealias InkCurvesPixelPreview = InkPixelPreview<EngineSession.InkCurvesSettings>

typealias LabCurvesPixelPreview = ComponentPixelPreview<EngineSession.LabCurvesSettings>
