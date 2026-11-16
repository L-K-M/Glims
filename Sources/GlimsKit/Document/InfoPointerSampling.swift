import Foundation

/// Keeps a pointer read bounded to one engine request and the latest waiting
/// position. Late results from a previous position or document are discarded.
@MainActor
final class InfoPointerSampling {
    struct Position: Equatable {
        let x: Int
        let y: Int
    }

    typealias Sample = Result<EngineSession.SampledColor, Error>
    typealias Reader = (Position, @escaping @MainActor (Sample) -> Void) -> Void

    private let read: Reader
    private let publish: (Position, Sample) -> Void
    private var generation = UUID()
    private var pending: (Position, UUID)?
    private var reading = false

    init(read: @escaping Reader, publish: @escaping (Position, Sample) -> Void) {
        self.read = read
        self.publish = publish
    }

    func request(_ position: Position) {
        generation = UUID()
        pending = (position, generation)
        startIfNeeded()
    }

    func invalidate() {
        generation = UUID()
        pending = nil
    }

    private func startIfNeeded() {
        guard !reading, let (position, requestGeneration) = pending else { return }
        pending = nil
        reading = true
        read(position) { [weak self] result in
            guard let self else { return }
            self.reading = false
            if self.generation == requestGeneration {
                self.publish(position, result)
            }
            self.startIfNeeded()
        }
    }
}
