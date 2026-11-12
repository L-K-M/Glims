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
    @objc func pasteInto(_ sender: Any?) { pasteIntoImage(from: .general) }

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
        statusBar.message = "Pasting pixels…"
        imageDocument.pastePixels(payload, origin: { pixels in
            placement == .originalPosition ? pixels.origin
                : CGPoint(x: (center.x - Double(pixels.width) / 2).rounded(),
                          y: (center.y - Double(pixels.height) / 2).rounded())
        }) { [weak self] result in
            switch result {
            case .success:
                self?.statusBar.message = "Pasted as a new layer"
            case .failure(let error):
                self?.statusBar.message = error.localizedDescription
            }
        }
    }

    /// Edit ▸ Paste Into: the clipboard's pixels become a floating
    /// selection clipped to the current selection. The document, the
    /// explicit target drawable and the payload are captured here, at
    /// command time — the queued work never falls back to the front
    /// document or a layer-0 target — and the payload decodes on the
    /// input queue like an ordinary Paste's.
    func pasteIntoImage(from pasteboard: NSPasteboard = .general) {
        guard !PlugInCommands.isRunning, !imageDocument.isClosing else { return }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        let payload: ClipboardImage.Payload
        do { payload = try ClipboardImage.readPayload(from: pasteboard) } catch {
            statusBar.message = error.localizedDescription
            return
        }
        let readiness = imageDocument.pasteIntoReadiness
        guard let target = readiness.drawable else {
            statusBar.message = readiness.reason ?? "Select a layer, mask or channel to paste into."
            NSSound.beep()
            return
        }
        statusBar.message = "Pasting into the selection…"
        imageDocument.pasteIntoPixels(payload, target: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.statusBar.message = "Pasted into the selection"
            case .failure(let error):
                self.statusBar.message = error.localizedDescription
            }
        }
    }

    @objc func clearPixels(_ sender: Any?) {
        if imageDocument.colorInfo.mode.usesInkChannels {
            performInkEdit(.clear)
            return
        }
        guard !PlugInCommands.isRunning, !imageDocument.isClosing else { return }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        let background = ToolState.shared.background
        imageDocument.runOnPaintTarget { session, image in try session.clearPixels(image, background: background) }
    }

    func canPerformClipboardCommand(_ action: Selector?) -> Bool {
        guard !PlugInCommands.isRunning, !imageDocument.isClosing, !EngineActivity.shared.isBusy,
              !imageDocument.isTransferringClipboard, !imageDocument.isSavingForClose else { return false }
        // Copy/Cut/Clear of the active layer and an ordinary Paste are
        // single-layer commands: they would silently act on the primary
        // layer alone under a multi-selection. Copy Merged reads the
        // whole composite and stays available. Paste Into also requires
        // one selected layer before capturing its explicit target.
        let singleLayerClipboard = action == #selector(cut(_:)) || action == #selector(copy(_:))
            || action == #selector(paste(_:)) || action == #selector(pasteInPlace(_:))
            || action == #selector(deleteBackward(_:)) || action == #selector(pasteInto(_:))
        if singleLayerClipboard, imageDocument.hasMultipleSelectedLayers { return false }
        switch action {
        case #selector(paste(_:)), #selector(pasteInPlace(_:)):
            // An ordinary Paste would implicitly anchor an active
            // floating selection, so it waits for a resolution; without
            // one its behavior is unchanged.
            return !imageDocument.filterPreviewIsOpen
                && !imageDocument.floatingState.isActive
                && NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
        case #selector(pasteInto(_:)):
            return !imageDocument.filterPreviewIsOpen
                && NSPasteboard.general.availableType(from: [.png, .tiff]) != nil
                && imageDocument.pasteIntoReadiness.allowed
        case #selector(cut(_:)):
            // A cut clears pixels; the preview owns its drawable meanwhile.
            return !imageDocument.filterPreviewIsOpen && imageDocument.activeDrawable != nil
        case #selector(copyMerged(_:)):
            return true
        default:
            return imageDocument.activeDrawable != nil
        }
    }
}
