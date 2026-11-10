import AppKit
import UniformTypeIdentifiers

/// Per-window Recorder file and naming sheets. The source document and
/// recording checkpoint stay fixed for the entire operation.
@MainActor
final class RecorderFileCoordinator {
    private static let recordingType = UTType(exportedAs: "ch.lkmc.glims.recording", conformingTo: .json)

    enum Refusal: LocalizedError {
        case windowUnavailable, changed
        var errorDescription: String? {
            switch self {
            case .windowUnavailable: return "Finish the current sheet before using Recorder files."
            case .changed: return "The recording changed. Choose the Recorder command again."
            }
        }
    }

    enum Loss: Equatable {
        case replace, close, revert

        var allowsActiveRecording: Bool { self != .replace }
        var detail: String {
            switch self {
            case .replace: return "The current recording stays in this image until a new recording replaces it."
            case .close: return "Closing the image removes its recording."
            case .revert: return "Reverting the image removes its recording."
            }
        }
    }

    private struct Operation {
        var id = UUID()
        let window: NSWindow
        let checkpoint: ImageDocument.RecorderInstallCheckpoint
        var allowsActiveRecording = false
    }

    private weak var owner: DocumentWindowController?
    private var active: UUID?
    private var bindingSheet: RecorderBindingSheetController?
    private weak var waitingDocument: ImageDocument?
    private var waitObserver: UUID?

    init(owner: DocumentWindowController) { self.owner = owner }

    var canPresent: Bool {
        guard let owner, let window = owner.window else { return false }
        return active == nil && window.attachedSheet == nil && !owner.closeStarted
    }

    func perform(_ action: RecorderPaletteAction) throws {
        guard canPresent, let owner, let window = owner.window else { throw Refusal.windowUnavailable }
        let document = owner.imageDocument
        let operation = Operation(window: window, checkpoint: try document.recorderInstallCheckpoint())
        active = operation.id
        switch action {
        case .nameRecording: name(operation)
        case .saveRecording: save(operation) { [weak self] _ in self?.finish(operation) }
        case .loadRecording:
            confirmReplacement(operation, detail: Loss.replace.detail) { [weak self] allowed in
                guard let self else { return }
                if allowed { self.chooseFile(operation) } else { self.finish(operation) }
            }
        default:
            finish(operation)
            throw Refusal.windowUnavailable
        }
    }

    /// Wait for already accepted commands without stopping or replacing the
    /// live recording. Only a later, verified decision authorizes loss.
    func confirmLoss(_ loss: Loss,
                     completion: @escaping @MainActor (ImageDocument.RecorderInstallCheckpoint?) -> Void) {
        guard canPresent, let owner, let window = owner.window else { return completion(nil) }
        let id = UUID()
        active = id
        continueLoss(loss, id: id, window: window, completion: completion)
    }

    private func continueLoss(_ loss: Loss, id: UUID, window: NSWindow,
                              completion: @escaping @MainActor (ImageDocument.RecorderInstallCheckpoint?) -> Void) {
        guard active == id else { return }
        guard let owner, owner.window === window, !owner.closeStarted, !owner.imageDocument.isClosing else {
            clearWait()
            active = nil
            return completion(nil)
        }
        let document = owner.imageDocument
        if document.pendingWork > 0 || document.strokeIsActive {
            guard waitObserver == nil else { return }
            waitingDocument = document
            owner.statusBar.message = "Waiting for accepted recording commands…"
            waitObserver = document.addRecorderObserver(scope: .presentation) { [weak self, weak document] in
                guard let self, let document, document.pendingWork == 0, !document.strokeIsActive else { return }
                self.clearWait()
                DispatchQueue.main.async { self.continueLoss(loss, id: id, window: window, completion: completion) }
            }
            return
        }
        clearWait()
        guard window.attachedSheet == nil else {
            active = nil
            return completion(nil)
        }
        guard document.hasUnsavedRecordingChanges else {
            active = nil
            return completion(document.recorderContentCheckpoint())
        }
        do {
            let checkpoint = try document.recorderSaveCheckpoint(allowActiveRecording: loss.allowsActiveRecording)
            let operation = Operation(id: id, window: window, checkpoint: checkpoint,
                                      allowsActiveRecording: loss.allowsActiveRecording)
            confirmReplacement(operation, detail: loss.detail) { [weak self] allowed in
                guard let self else { return completion(nil) }
                let current = self.current(operation)
                let approved = allowed && current?.recorderContentCheckpoint() == checkpoint
                self.finish(operation, error: allowed && !approved ? Refusal.changed : nil)
                completion(approved ? checkpoint : nil)
            }
        } catch {
            active = nil
            document.onError?(error.localizedDescription)
            completion(nil)
        }
    }

    private func clearWait() {
        if let waitObserver { waitingDocument?.removeRecorderObserver(waitObserver) }
        waitObserver = nil
        waitingDocument = nil
    }

    private func current(_ operation: Operation) -> ImageDocument? {
        guard active == operation.id, let owner, owner.window === operation.window,
              !owner.closeStarted, !owner.imageDocument.isClosing else { return nil }
        return owner.imageDocument
    }

    private func verify(_ operation: Operation) throws -> ImageDocument {
        guard let document = current(operation),
              try document.recorderSaveCheckpoint(allowActiveRecording: operation.allowsActiveRecording) == operation.checkpoint else {
            throw Refusal.changed
        }
        return document
    }

    private func finish(_ operation: Operation, error: Error? = nil) {
        guard active == operation.id else { return }
        if let error { current(operation)?.onError?(error.localizedDescription) }
        active = nil
        bindingSheet = nil
        clearWait()
    }

    private func name(_ operation: Operation) {
        guard let document = current(operation) else { return finish(operation) }
        let alert = NSAlert()
        alert.messageText = "Name Recording"
        alert.informativeText = "The recording name is independent of its filename."
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 320, height: 25))
        field.stringValue = document.recorderFileMetadata.name
        field.setAccessibilityLabel("Recording name")
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Name")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: operation.window) { [weak self] response in
            guard let self else { return }
            defer { self.finish(operation) }
            guard response == .alertFirstButtonReturn else { return }
            do { try self.verify(operation).renameRecording(field.stringValue) }
            catch { self.finish(operation, error: error) }
        }
    }

    private func save(_ operation: Operation, completion: @escaping @MainActor (Bool) -> Void) {
        guard let document = current(operation) else { return completion(false) }
        let panel = NSSavePanel()
        panel.title = "Save Recording"
        panel.allowedContentTypes = [Self.recordingType]
        panel.canCreateDirectories = true
        // Filename suggestions are only presentation; the intrinsic title
        // stays exact, including spelling or punctuation not used in paths.
        let base = String(document.recorderFileMetadata.name.prefix(180))
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let suggested = base.isEmpty || base == "." || base == ".." ? "Recording" : base
        panel.nameFieldStringValue = suggested + ".glimsrecording"
        panel.beginSheetModal(for: operation.window) { [weak self] response in
            guard let self else { return completion(false) }
            guard response == .OK, let url = panel.url else { return completion(false) }
            do {
                let captured = try self.verify(operation)
                captured.saveRecording(to: url, checkpoint: operation.checkpoint,
                                       allowActiveRecording: operation.allowsActiveRecording) { [weak self] result in
                    // The backend's work count drains after this callback.
                    DispatchQueue.main.async {
                        guard let self, self.current(operation) === captured else { return completion(false) }
                        switch result {
                        case .success(.savedCurrentRevision):
                            self.owner?.statusBar.message = "Saved recording to \(url.lastPathComponent)"
                            completion(true)
                        case .success(.savedEarlierRevision):
                            captured.onError?("Saved the earlier recording. The current recording still has unsaved changes.")
                            completion(false)
                        case .failure(let error):
                            captured.onError?(error.localizedDescription)
                            completion(false)
                        }
                    }
                }
            } catch {
                self.current(operation)?.onError?(error.localizedDescription)
                completion(false)
            }
        }
    }

    private func confirmReplacement(_ operation: Operation, detail: String,
                                    completion: @escaping @MainActor (Bool) -> Void) {
        guard let document = current(operation) else { return completion(false) }
        guard document.hasUnsavedRecordingChanges else { return completion(true) }
        let alert = NSAlert()
        alert.messageText = "Save changes to the current recording?"
        alert.informativeText = detail
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Discard Changes")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: operation.window) { [weak self] response in
            guard let self else { return completion(false) }
            // End this alert before presenting a second sheet on the owner.
            DispatchQueue.main.async {
                guard self.current(operation) != nil else { return completion(false) }
                switch response {
                case .alertFirstButtonReturn: self.save(operation, completion: completion)
                case .alertSecondButtonReturn: completion(true)
                default: completion(false)
                }
            }
        }
    }

    private func chooseFile(_ operation: Operation) {
        do { _ = try verify(operation) }
        catch { return finish(operation, error: error) }
        let panel = NSOpenPanel()
        panel.title = "Load Recording"
        panel.allowedContentTypes = [Self.recordingType]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: operation.window) { [weak self] response in
            guard let self else { return }
            guard response == .OK, let url = panel.url else { return self.finish(operation) }
            do {
                let captured = try self.verify(operation)
                captured.prepareRecordingFile(at: url, checkpoint: operation.checkpoint) { [weak self] result in
                    DispatchQueue.main.async {
                        guard let self, self.current(operation) === captured else { return }
                        switch result {
                        case .success(let prepared): self.bind(prepared, operation)
                        case .failure(let error): self.finish(operation, error: error)
                        }
                    }
                }
            } catch { self.finish(operation, error: error) }
        }
    }

    private func bind(_ prepared: RecorderFileSemanticBridge.PreparedRecording, _ operation: Operation) {
        do {
            let document = try verify(operation)
            guard operation.window.attachedSheet == nil else { throw Refusal.windowUnavailable }
            let sheet = try RecorderBindingSheetController(file: prepared.file, document: document)
            bindingSheet = sheet
            sheet.begin(on: operation.window) { [weak self] choices in
                guard let self else { return }
                guard let choices else { return self.finish(operation) }
                do {
                    let captured = try self.verify(operation)
                    captured.installRecording(prepared, checkpoint: operation.checkpoint, choices: choices) { [weak self] result in
                        guard let self else { return }
                        switch result {
                        case .success:
                            if self.current(operation) === captured {
                                self.owner?.statusBar.message = "Loaded recording \(prepared.file.name)"
                            }
                            self.finish(operation)
                        case .failure(let error): self.finish(operation, error: error)
                        }
                    }
                } catch { self.finish(operation, error: error) }
            }
        } catch { finish(operation, error: error) }
    }
}
