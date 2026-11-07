import Foundation

/// GIMP's file and plug-in calls hold the single engine across images.
/// Admit them on the main actor: finish gestures, stop accepting edits,
/// then drain every document's accepted input before entering the engine.
@MainActor
final class EngineActivity {
    static let shared = EngineActivity()

    private final class DocumentReference {
        weak var value: ImageDocument?
        init(_ value: ImageDocument) { self.value = value }
    }

    private var documents: [DocumentReference] = []
    private let queue = DispatchQueue(label: "ch.lkmc.Glims.engine.activity", qos: .userInitiated)
    private var preparing = false
    private var idleActions: [@MainActor () -> Void] = []
    private(set) var label: String?
    var isBusy: Bool { label != nil }

    private var liveDocuments: [ImageDocument] {
        documents.removeAll { $0.value == nil }
        return documents.compactMap(\.value)
    }

    func register(_ document: ImageDocument) {
        guard !liveDocuments.contains(where: { $0 === document }) else { return }
        documents.append(DocumentReference(document))
    }

    func finishPendingInput() {
        liveDocuments.filter { !$0.isClosing }.forEach { $0.finishInputForEngineActivity() }
    }

    /// Background file work may queue behind another operation; the UI's
    /// accepted open requests and their lifecycle counts remain intact.
    func performWhenReady(label: String, work: @escaping () -> Void,
                          completion: @escaping @MainActor () -> Void = {}) {
        guard perform(label: label, work: work, completion: completion) else {
            whenIdle { self.performWhenReady(label: label, work: work, completion: completion) }
            return
        }
    }

    @discardableResult
    func perform(label: String, work: @escaping () -> Void,
                 completion: @escaping @MainActor () -> Void) -> Bool {
        guard !isBusy, !preparing else { return false }
        preparing = true
        finishPendingInput()
        preparing = false
        self.label = label
        let admittedDocuments = liveDocuments
        admittedDocuments.forEach { $0.onStateChange?() }
        let drained = DispatchGroup()
        for document in admittedDocuments {
            drained.enter()
            document.inputQueue.async { drained.leave() }
        }
        queue.async {
            drained.wait()
            work()
            DispatchQueue.main.async {
                self.label = nil
                // Dispatch cleanup first. If completion starts a new
                // activity, its barriers then include that cleanup.
                let actions = self.idleActions
                self.idleActions.removeAll()
                actions.forEach { self.whenIdle($0) }
                completion()
                self.liveDocuments.forEach { $0.onStateChange?() }
            }
        }
        return true
    }

    /// Cleanup (preview cancellation and image destruction) must wait
    /// for the engine, even though new user edits are refused meanwhile.
    func whenIdle(_ action: @escaping @MainActor () -> Void) {
        if isBusy || preparing { idleActions.append(action) } else { action() }
    }

    /// Destruction follows file calls on the same queue. It needs no new
    /// edit gate once this image has drained; input in other images may
    /// continue. A later file call cannot overtake this cleanup.
    func closeImage(_ image: Int32, session: EngineSession,
                    completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        queue.async {
            let result = Result { try session.closeImage(image) }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
