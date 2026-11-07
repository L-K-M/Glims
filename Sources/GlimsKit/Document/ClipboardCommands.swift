import AppKit

@MainActor
extension DocumentWindowController {
    typealias CopyOperation = ImageDocument.ClipboardOperation
    enum PastePlacement { case centered, originalPosition }

    @objc func copy(_ sender: Any?) { copyImage(.layer) }
    @objc func copyMerged(_ sender: Any?) { copyImage(.merged) }
    @objc func cut(_ sender: Any?) { copyImage(.cutLayer) }
    @objc func paste(_ sender: Any?) { pasteImage(.centered) }
    @objc func pasteInPlace(_ sender: Any?) { pasteImage(.originalPosition) }

    /// Queue the whole copy/cut transaction with pointer input. A cut only
    /// clears pixels after the system clipboard accepted their encoded copy;
    /// later input cannot change the selection in between those operations.
    func copyImage(_ operation: CopyOperation, to pasteboard: NSPasteboard = .general) {
        guard !PlugInCommands.isRunning, !imageDocument.isClosing else { return }
        if operation == .cutLayer, imageDocument.filterPreviewIsOpen {
            statusBar.message = "Apply or cancel the filter preview first."
            NSSound.beep()
            return
        }
        NSApp.windows.forEach { $0.endEditing(for: nil) }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        let background = ToolState.shared.background
        statusBar.message = "Copying pixels…"
        imageDocument.copyPixels(operation, background: background,
                                 consume: { try $0.write(to: pasteboard) }) { [weak self] error in
            guard let self else { return }
            if let error {
                self.statusBar.message = error.localizedDescription
                if let window = self.window, window.isVisible, window.attachedSheet == nil {
                    NSAlert(error: error).beginSheetModal(for: window)
                }
            } else {
                self.statusBar.message = operation == .cutLayer ? "Cut pixels" : "Copied pixels"
            }
        }
    }

    func pasteImage(_ placement: PastePlacement, from pasteboard: NSPasteboard = .general) {
        guard !PlugInCommands.isRunning, !imageDocument.isClosing else { return }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        let payload: ClipboardImage.Payload
        do { payload = try ClipboardImage.readPayload(from: pasteboard) } catch {
            statusBar.message = error.localizedDescription
            return
        }
        let visible = canvas.visibleRect
        let center = visible.isEmpty
            ? CGPoint(x: Double(imageDocument.info.width) / 2, y: Double(imageDocument.info.height) / 2)
            : CGPoint(x: visible.midX / canvas.scale, y: visible.midY / canvas.scale)
        let document = imageDocument
        // The paste is a layer creation: only auto-select its layer while
        // the user has not picked another one since.
        let intent = document.noteSelectionIntent()
        statusBar.message = "Pasting pixels…"
        document.run { [weak self] session, image in
            let pixels = try payload.decoded()
            let origin = placement == .originalPosition ? pixels.origin
                : CGPoint(x: (center.x - Double(pixels.width) / 2).rounded(),
                          y: (center.y - Double(pixels.height) / 2).rounded())
            let layer = try session.pastePixels(image, pixels: pixels, at: origin)
            DispatchQueue.main.async {
                do {
                    try document.reload()
                    document.selectLayerIfLatest(layer, intent: intent)
                    self?.statusBar.message = "Pasted as a new layer"
                } catch {
                    document.onError?(error.localizedDescription)
                }
            }
        }
    }

    @objc func clearPixels(_ sender: Any?) {
        guard !PlugInCommands.isRunning, !imageDocument.isClosing else { return }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        let background = ToolState.shared.background
        imageDocument.run { session, image in try session.clearPixels(image, background: background) }
    }

    func canPerformClipboardCommand(_ action: Selector?) -> Bool {
        guard !PlugInCommands.isRunning, !imageDocument.isClosing, !EngineActivity.shared.isBusy,
              !imageDocument.isTransferringClipboard, !imageDocument.isSavingForClose else { return false }
        switch action {
        case #selector(paste(_:)), #selector(pasteInPlace(_:)):
            return !imageDocument.filterPreviewIsOpen
                && NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
        case #selector(cut(_:)):
            // A cut clears pixels; the preview owns its drawable meanwhile.
            return !imageDocument.filterPreviewIsOpen && imageDocument.activeLayer != nil
        case #selector(copyMerged(_:)):
            return true
        default:
            return imageDocument.activeLayer != nil
        }
    }
}
