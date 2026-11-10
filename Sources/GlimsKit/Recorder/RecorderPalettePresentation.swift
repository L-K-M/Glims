import Foundation

/// The user commands share their names and gates across the palette
/// buttons, its title menu and Edit > Recorder.
enum RecorderPaletteAction: Int, CaseIterable, Hashable {
    case record, stop, replay, cancelReplay, clear
    case nameRecording, saveRecording, loadRecording

    var needsFileSheet: Bool {
        switch self {
        case .nameRecording, .saveRecording, .loadRecording: return true
        default: return false
        }
    }

    var title: String {
        switch self {
        case .record: return "Record"
        case .stop: return "Stop"
        case .replay: return "Replay"
        case .cancelReplay: return "Cancel Replay"
        case .clear: return "Clear"
        case .nameRecording: return "Name Recording…"
        case .saveRecording: return "Save Recording…"
        case .loadRecording: return "Load Recording…"
        }
    }

    @MainActor
    func perform(on document: ImageDocument) throws {
        switch self {
        case .record: try document.startRecording()
        case .stop: try document.stopRecording()
        case .replay: try document.startReplay()
        case .cancelReplay: try document.cancelReplay()
        case .clear:
            guard document.clearRecording() else {
                throw RecorderLog<SemanticImageCommand>.Refusal.replaying
            }
        case .nameRecording, .saveRecording, .loadRecording:
            throw RecorderFileCoordinator.Refusal.windowUnavailable
        }
    }
}

@MainActor
struct RecorderPalettePresentation {
    struct Row: Equatable {
        let ordinal: Int
        let text: String
    }

    static let coverage = "Supported actions: selections, image rotation and flips, image size, canvas size, crop, and layer name, visibility, opacity and blend mode. Replay uses this image only."
    static let replayPolicy = "Replay uses each command's normal Undo behavior. On failure, earlier changes remain."

    let documentName: String
    let recordingName: String
    let rows: [Row]
    let pendingText: String
    let status: String
    private let refusals: [RecorderPaletteAction: String]

    init(document: ImageDocument?, actionError: String? = nil) {
        guard let document else {
            documentName = "No image"
            recordingName = ""
            rows = []
            pendingText = "No commands pending."
            status = actionError ?? "Open an image to use Recorder."
            refusals = Dictionary(uniqueKeysWithValues: RecorderPaletteAction.allCases.map { ($0, "Open an image to use Recorder.") })
            return
        }
        let log = document.recorder
        documentName = document.name
        recordingName = document.recorderFileMetadata.name + (document.hasUnsavedRecordingChanges ? " (Unsaved)" : "")
        rows = log.records.map { record in
            let prefix = "\(record.ordinal + 1). "
            switch record.resolution {
            case .success(let command): return Row(ordinal: record.ordinal, text: prefix + "Recorded: " + command.title)
            case .failure(let reason): return Row(ordinal: record.ordinal, text: prefix + "Failed: " + reason)
            case .cancelled(let reason): return Row(ordinal: record.ordinal, text: prefix + "Cancelled: " + reason)
            }
        }
        pendingText = log.pendingCount == 0 ? "No commands pending."
            : "\(log.pendingCount) command\(log.pendingCount == 1 ? "" : "s") pending."
        if let actionError { status = actionError }
        else if document.isClosing { status = "This image is closing." }
        else {
            switch log.replayStatus {
            case .running(let index, let total): status = "Replaying command \(index + 1) of \(total)."
            case .finished(let total): status = "Replayed \(total) command\(total == 1 ? "" : "s")."
            case .failed(let index, let reason): status = "Replay failed at command \(index + 1): \(reason)"
            case .cancelled(let index): status = "Replay cancelled at command \(index + 1). A command already running may finish."
            case .idle:
                if log.isRecording { status = "Recording supported actions. Stop keeps accepted commands until they finish." }
                else if log.pendingCount > 0 { status = "Waiting for accepted commands to finish." }
                else if log.records.isEmpty { status = "Record starts a new recording for this image." }
                else { status = "\(log.records.count) settled command\(log.records.count == 1 ? "" : "s"). Record replaces this recording." }
            }
        }
        var gates: [RecorderPaletteAction: String] = [:]
        if document.isClosing {
            gates = Dictionary(uniqueKeysWithValues: RecorderPaletteAction.allCases.map { ($0, "This image is closing.") })
        } else {
            if log.isRecording { gates[.record] = "Stop the current recording first." }
            else if log.isReplaying { gates[.record] = "Cancel replay before recording." }
            else if log.pendingCount > 0 || document.pendingWork > 0 { gates[.record] = "Wait for accepted commands to finish before recording." }
            else if !document.acceptsEdits || document.strokeIsActive { gates[.record] = "Finish the current image operation before recording." }

            if !log.isRecording { gates[.stop] = "No recording is running." }
            if !log.isReplaying { gates[.cancelReplay] = "No replay is running." }

            if let refusal = log.replayRefusal { gates[.replay] = Self.reason(for: refusal) }
            else if !document.acceptsEdits || document.strokeIsActive { gates[.replay] = "Finish the current image operation before replaying." }
            else if document.pendingWork > 0 || document.targetCommandIsPending { gates[.replay] = "Wait for accepted image and target changes before replaying." }

            if log.isReplaying { gates[.clear] = "Cancel replay before clearing the recording." }
            else if log.isRecording { gates[.clear] = "Stop recording before clearing it." }
            else if log.pendingCount > 0 { gates[.clear] = "Wait for accepted commands before clearing the recording." }
            else if log.records.isEmpty && log.replayStatus == .idle && document.recorderLoadedFile == nil &&
                        !document.hasUnsavedRecordingChanges { gates[.clear] = "The recording is already empty." }

            let fileReason: String?
            if log.isRecording { fileReason = "Stop recording before using Recorder files." }
            else if log.isReplaying { fileReason = "Cancel replay before using Recorder files." }
            else if log.pendingCount > 0 || document.pendingWork > 0 || document.targetCommandIsPending {
                fileReason = "Wait for accepted commands to finish."
            } else if !document.acceptsEdits || document.strokeIsActive {
                fileReason = "Finish the current image operation before using Recorder files."
            } else { fileReason = nil }
            for action in RecorderPaletteAction.allCases where action.needsFileSheet { gates[action] = fileReason }
            if fileReason == nil && log.records.isEmpty && document.recorderLoadedFile == nil &&
                !document.hasUnsavedRecordingChanges {
                gates[.saveRecording] = "Record a command or name this recording first."
            }
        }
        refusals = gates
    }

    func refusal(for action: RecorderPaletteAction) -> String? { refusals[action] }
    func canPerform(_ action: RecorderPaletteAction) -> Bool { refusal(for: action) == nil }

    static func message(for error: Error) -> String {
        if let refusal = error as? RecorderLog<SemanticImageCommand>.Refusal { return reason(for: refusal) }
        return error.localizedDescription
    }

    private static func reason(for refusal: RecorderLog<SemanticImageCommand>.Refusal) -> String {
        switch refusal {
        case .alreadyRecording: return "Stop recording before replaying."
        case .notRecording: return "No recording is running."
        case .replaying: return "Cancel the current replay first."
        case .pendingReservations: return "Wait for accepted commands to finish before replaying."
        case .unsuccessfulRecording: return "This recording has a failed or cancelled command. Record it again before replaying."
        case .emptyRecording: return "Record commands before replaying."
        case .notReplaying: return "No replay is running."
        case .staleReservation, .alreadyResolved, .awaitingAcknowledgment, .staleReplayStep:
            return "The recording changed. Choose the Recorder command again."
        }
    }
}
