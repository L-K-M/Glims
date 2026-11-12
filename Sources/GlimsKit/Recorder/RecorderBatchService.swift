import Foundation

/// Runs one private document at a time. Cancel fences future files and output
/// publication; already accepted native work drains before its image is closed.
@MainActor
final class RecorderBatchService {
    enum Output {
        case native
        case exported(ExportSettings)

        var fileExtension: String {
            switch self {
            case .native: return "xcf"
            case .exported(let settings): return settings.format.preferredExtension
            }
        }
    }

    struct Item {
        enum Outcome {
            case saved(URL, warning: String?)
            case failed(String)
            case cancelled(warning: String?)
        }
        let source: URL
        let outcome: Outcome
    }

    struct Progress {
        let completed: Int
        let total: Int
        let current: URL?
        let message: String
    }

    enum Failure: LocalizedError {
        case alreadyRunning, noInputs, tooManyInputs, invalidInput, invalidOutputSettings, cancelled, replay(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: return "A Batch is already running."
            case .noInputs: return "Choose at least one input image."
            case .tooManyInputs: return "Choose at most 10,000 input images for one Batch."
            case .invalidInput: return "Batch inputs must be local files."
            case .invalidOutputSettings: return "Correct the export settings before starting Batch."
            case .cancelled: return "Batch was cancelled."
            case .replay(let reason): return reason
            }
        }
    }

    private(set) var isRunning = false
    private(set) var cancellationRequested = false
    private let session: EngineSession
    private let fileQueue = DispatchQueue(label: "ch.lkmc.Glims.recorder.batch.files", qos: .userInitiated)
    private var currentDocument: ImageDocument?

    init(session: EngineSession) { self.session = session }

    /// The owner retains this service through completion, including application
    /// termination. Completion means native close and temporary cleanup drained.
    func start(recording: URL, inputs: [URL], directory: URL,
               output: Output, matching: RecorderBatchBindings.Policy,
               progress: @escaping (Progress) -> Void,
               completion: @escaping (Result<[Item], Error>) -> Void) throws {
        guard !isRunning else { throw Failure.alreadyRunning }
        guard !inputs.isEmpty else { throw Failure.noInputs }
        guard inputs.count <= 10_000 else { throw Failure.tooManyInputs }
        if case .exported(let settings) = output, !ExportSettings.validate(settings) { throw Failure.invalidOutputSettings }
        guard inputs.allSatisfy({ $0.isFileURL && (($0.host ?? "").isEmpty || $0.host == "localhost")
            && $0.query == nil && $0.fragment == nil && !$0.path.utf8.contains(0) }) else { throw Failure.invalidInput }
        isRunning = true
        cancellationRequested = false
        Task {
            let result: Result<[Item], Error>
            do {
                let (prepared, sources) = try await files {
                    let file = try RecorderFileStore.load(from: recording)
                    guard !file.records.isEmpty else { throw RecorderBatchBindings.MatchError.emptyRecording }
                    for row in file.records {
                        guard case .success = row.outcome else { throw RecorderBatchBindings.MatchError.unsuccessfulCommand(row.ordinal + 1) }
                    }
                    if case .requireNoTargets = matching {
                        _ = try RecorderBatchBindings.resolve(file: file, candidates: [], policy: matching)
                    }
                    return (try RecorderFileSemanticBridge.prepare(file), try RecorderBatchInputs.resolve(inputs))
                }
                var items: [Item] = []
                for source in sources {
                    if cancellationRequested { break }
                    progress(.init(completed: items.count, total: sources.count, current: source, message: "Opening \(source.lastPathComponent)"))
                    let item = await process(source, inputs: sources, directory: directory, output: output,
                                             matching: matching, prepared: prepared) { message in
                        progress(.init(completed: items.count, total: sources.count, current: source, message: message))
                    }
                    items.append(item)
                }
                progress(.init(completed: items.count, total: sources.count, current: nil,
                               message: cancellationRequested ? "Batch cancelled" : "Batch finished"))
                result = .success(items)
            } catch { result = .failure(error) }
            isRunning = false
            completion(result)
        }
    }

    func cancel() {
        guard isRunning else { return }
        cancellationRequested = true
        if let currentDocument, case .running = currentDocument.replayStatus { try? currentDocument.cancelReplay() }
    }

    private func process(_ source: URL, inputs: [URL], directory: URL, output: Output,
                         matching: RecorderBatchBindings.Policy,
                         prepared: RecorderFileSemanticBridge.PreparedRecording,
                         progress: (String) -> Void) async -> Item {
        var stage: RecorderBatchOutput?
        var outcome: Item.Outcome
        var commandError: String?
        do {
            try checkCancellation()
            let image = try await open(source)
            await engineReady()
            do { currentDocument = try ImageDocument(session: session, image: image, name: source.lastPathComponent, openedFrom: source) }
            catch {
                await withCheckedContinuation { continuation in
                    EngineActivity.shared.closeImage(image, session: session) { _ in continuation.resume() }
                }
                throw error
            }
            let document = currentDocument!
            // Batch owns error presentation; no modal alert may interrupt a run.
            document.onError = { commandError = $0 }
            try checkCancellation()
            let candidates = try document.recorderBatchCandidates()
            let choices = try await files {
                try RecorderBatchBindings.resolve(file: prepared.file, candidates: candidates, policy: matching)
            }
            await settled(document)
            try checkCancellation()
            let checkpoint = try document.recorderInstallCheckpoint()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                document.installRecording(prepared, checkpoint: checkpoint, choices: choices) { continuation.resume(with: $0) }
            }
            await settled(document)
            try checkCancellation()
            progress("Replaying \(source.lastPathComponent)")
            try checkCancellation()
            try document.startReplay(engineActivity: .wait)
            while case .running = document.replayStatus { await tick() }
            await settled(document)
            switch document.replayStatus {
            case .finished: break
            case .failed(let index, let reason): throw Failure.replay("Command \(index + 1): \(reason)")
            case .cancelled:
                if let commandError { throw Failure.replay(commandError) }
                throw Failure.cancelled
            default: throw Failure.replay("The recording did not finish. No output was published.")
            }
            try checkCancellation()
            stage = try await files { try RecorderBatchOutput(directory: directory, source: source, inputs: inputs, extension: output.fileExtension) }
            let preparedOutput = stage!
            try checkCancellation()
            progress("Exporting \(source.lastPathComponent)")
            try checkCancellation()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let done: @MainActor (Error?) -> Void = { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
                switch output {
                case .native: document.saveCopy(to: preparedOutput.stagingURL, completion: done)
                case .exported(let settings): document.export(to: preparedOutput.stagingURL, settings: settings, completion: done)
                }
            }
            await settled(document)
            try checkCancellation()
            // Once publication starts, a successful rename is a saved result,
            // including when Cancel arrives before its main-queue reply.
            let published = try await files { try preparedOutput.publish() }
            outcome = .saved(published.url, warning: published.cleanupWarning)
        } catch {
            if let failure = error as? Failure, case .cancelled = failure {
                outcome = .cancelled(warning: nil)
            } else { outcome = .failed(error.localizedDescription) }
        }
        if let stage {
            let warning = try? await files { stage.discard() }
            if let warning { outcome = adding(warning, to: outcome) }
        }
        if let document = currentDocument {
            var closeError: String?
            document.onError = { closeError = $0 }
            await withCheckedContinuation { continuation in
                document.closeImageWhenDrained { continuation.resume() }
            }
            if let closeError { outcome = adding("Image cleanup: " + closeError, to: outcome) }
            currentDocument = nil
        }
        return Item(source: source, outcome: outcome)
    }

    private func open(_ source: URL) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            EngineActivity.shared.performWhenReady(label: "Opening \(source.lastPathComponent) for Batch", work: { [session] in
                let result = Result { try session.openImage(path: source.path) }
                DispatchQueue.main.async { continuation.resume(with: result) }
            })
        }
    }

    private func engineReady() async {
        await withCheckedContinuation { continuation in
            EngineActivity.shared.whenReadyForSynchronousRead { continuation.resume() }
        }
    }

    private func settled(_ document: ImageDocument) async {
        while document.pendingWork > 0 || EngineActivity.shared.isBusy || EngineActivity.shared.isRenderingTransformPreview { await tick() }
    }

    private func tick() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { continuation.resume() }
        }
    }

    private func files<Value>(_ work: @escaping () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            fileQueue.async { continuation.resume(with: Result(catching: work)) }
        }
    }

    private func checkCancellation() throws { if cancellationRequested { throw Failure.cancelled } }

    private func adding(_ warning: String, to outcome: Item.Outcome) -> Item.Outcome {
        switch outcome {
        case .saved(let url, let previous): return .saved(url, warning: [previous, warning].compactMap { $0 }.joined(separator: "\n"))
        case .failed(let reason): return .failed(reason + "\n" + warning)
        case .cancelled(let previous): return .cancelled(warning: [previous, warning].compactMap { $0 }.joined(separator: "\n"))
        }
    }
}
