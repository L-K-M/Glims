import AppKit

@MainActor
extension DocumentWindowController {
    /// Select ▸ Float Selected Pixels: cut the selected pixels out of
    /// their target into a floating selection (MOVE).
    @objc func floatSelectedPixels(_ sender: Any?) { floatSelection(.move) }

    /// Select ▸ Float a Copy: float a copy of the selected pixels (COPY);
    /// the target's pixels stay as they are.
    @objc func floatACopy(_ sender: Any?) { floatSelection(.copy) }

    /// Shared Select ▸ Float … command. In-flight text/field edits end
    /// and an active stroke ends first — their jobs land on the
    /// document's serial input queue ahead of the float's target command,
    /// so the float runs on the committed image. The document, the
    /// explicit target drawable and the mode are captured at command time
    /// and the queued work never falls back to the front document or a
    /// layer-0 target. A cached refusal is shown as the status line with
    /// a beep, never silently retried against another target.
    func floatSelection(_ mode: EngineSession.FloatMode) {
        guard !PlugInCommands.isRunning, !imageDocument.isClosing else { return }
        canvas.tools.finishTextEditing()
        if imageDocument.strokeIsActive { imageDocument.endStroke() }
        let readiness = imageDocument.floatReadiness(mode)
        guard let target = readiness.drawable else {
            statusBar.message = readiness.reason ?? "Select an area and a layer, mask or channel to float."
            NSSound.beep()
            return
        }
        statusBar.message = mode == .move ? "Floating the selection…" : "Floating a copy of the selection…"
        imageDocument.floatSelectedPixels(mode: mode, target: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.statusBar.message = mode == .move
                    ? "Floated the selection; the target keeps a transparent hole"
                    : "Floated a copy of the selection"
            case .failure(let error):
                self.statusBar.message = error.localizedDescription
            }
        }
    }
}
