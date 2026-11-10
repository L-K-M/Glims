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

    private struct Operation {
        let id = UUID()
        let window: NSWindow
        let checkpoint: ImageDocument.RecorderInstallCheckpoint
    }

    private weak var owner: DocumentWindowController?
    private var active: UUID?
    private var bindingSheet: RecorderBindingSheetController?

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
            confirmReplacement(operation) { [weak self] allowed in
                guard let self else { return }
                if allowed { self.chooseFile(operation) } else { self.finish(operation) }
            }
        default:
            finish(operation)
            throw Refusal.windowUnavailable
        }
    }

    private func current(_ operation: Operation) -> ImageDocument? {
        guard active == operation.id, let owner, owner.window === operation.window,
              !owner.closeStarted, !owner.imageDocument.isClosing else { return nil }
        return owner.imageDocument
    }

    private func verify(_ operation: Operation) throws -> ImageDocument {
        guard let document = current(operation),
              try document.recorderInstallCheckpoint() == operation.checkpoint else { throw Refusal.changed }
        return document
    }

    private func finish(_ operation: Operation, error: Error? = nil) {
        guard active == operation.id else { return }
        if let error { current(operation)?.onError?(error.localizedDescription) }
        active = nil
        bindingSheet = nil
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
        panel.nameFieldStringValue = base.isEmpty || base == "." || base == ".." ? "Recording" : base
        panel.beginSheetModal(for: operation.window) { [weak self] response in
            guard let self else { return completion(false) }
            guard response == .OK, let url = panel.url else { return completion(false) }
            do {
                let captured = try self.verify(operation)
                captured.saveRecording(to: url, checkpoint: operation.checkpoint) { [weak self] result in
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

    private func confirmReplacement(_ operation: Operation, completion: @escaping @MainActor (Bool) -> Void) {
        guard let document = current(operation) else { return completion(false) }
        guard document.hasUnsavedRecordingChanges else { return completion(true) }
        let alert = NSAlert()
        alert.messageText = "Save changes to the current recording?"
        alert.informativeText = "The current recording stays in this image until a new recording is loaded."
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
