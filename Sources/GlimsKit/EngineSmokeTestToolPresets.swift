import AppKit

// MARK: - GLIMS_SMOKE_CASE=tool-presets

@MainActor
extension EngineSmokeTest {
    /// Drives the retained presets panel through its real controls (looked up
    /// by accessibility label): the Tool Options "Presets…" entry point, Save
    /// Current / Rename / Update / Delete / Apply / Close, the explicit
    /// All-tools filter, inline store errors, UUID selection across reloads
    /// and reopen, and one bounded worker stroke proving the applied resource
    /// identity resolves (and a missing one is reported) through the ordinary
    /// document queue. Injected ToolState + throwaway UserDefaults stores; no
    /// writes to the real defaults.
    static func exerciseToolPresetControls(_ session: EngineSession, work: URL,
                                           documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(10)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        // Enumerates children recursively even when the root itself matches.
        func allViews<T: NSView>(_ root: NSView?, as type: T.Type) -> [T] {
            guard let root else { return [] }
            var found: [T] = []
            if let match = root as? T { found.append(match) }
            found += root.subviews.flatMap { allViews($0, as: type) }
            return found
        }
        func button(_ win: NSWindow?, _ label: String) -> NSButton? {
            allViews(win?.contentView, as: NSButton.self).first { $0.accessibilityLabel() == label }
        }
        func editableField(_ win: NSWindow?, _ label: String) -> NSTextField? {
            allViews(win?.contentView, as: NSTextField.self)
                .first { $0.isEditable && $0.accessibilityLabel() == label }
        }
        func messageField(_ win: NSWindow?) -> NSTextField? {
            allViews(win?.contentView, as: NSTextField.self)
                .first { !$0.isEditable && $0.accessibilityLabel() == "Preset message" }
        }
        func presetsTable(_ win: NSWindow?) -> NSTableView? {
            allViews(win?.contentView, as: NSTableView.self)
                .first { $0.accessibilityLabel() == "Presets list" }
        }

        // Throwaway stores: the scenario never persists into the real defaults.
        let suite = "ch.lkmc.Glims.smoke.tool-presets.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let presetStore = PaintToolPresetStore(defaults: defaults)
        let state = ToolState(brushStore: BrushSelectionStore(defaults: defaults))

        // Fixture brush identity from the real engine catalog.
        let catalog = try session.resources(.brush)
        guard let soft = catalog.first(where: { $0.displayName == "2. Hardness 025" }) else {
            check(false, "the hard brush fixture exists for the preset scenario")
            return
        }
        let softIdentity = try session.resourceIdentifiers(soft.id)

        // Non-default current paint-tool settings, a deliberate foreground
        // color and a clone source point that must survive every apply.
        state.select(.paintbrush)
        state.setBrushResource(softIdentity, for: .paintbrush)
        state.update(.paintbrush) { brush in
            brush.size = 9
            brush.opacity = 0.5
            brush.hardness = 0.25
            brush.pressureSize = false
        }
        state.foreground = NSColor(srgbRed: 0.25, green: 0.5, blue: 0.75, alpha: 1)
        let cloneSource = EngineSession.Brush.Source(drawable: 7, x: 3, y: 4)
        state.cloneSource = cloneSource
        let capturedSnapshot = state.brush(for: .paintbrush)

        // The actual Tool Options entry point for a paint tool.
        let previousSharedTool = ToolState.shared.current
        ToolState.shared.select(.paintbrush)
        defer { ToolState.shared.select(previousSharedTool) }
        let options = ToolOptionsPaletteController()
        _ = options.view
        let presetsEntry = allViews(options.view, as: NSButton.self).first { $0.accessibilityLabel() == "Presets…" }
        check(presetsEntry != nil, "Tool Options offers an accessible Presets… action for paint tools")
        presetsEntry?.performClick(nil)
        check(PaintToolPresetPanelController.shared.isOpen, "Presets… opens the one retained presets panel")
        PaintToolPresetPanelController.shared.closePanel(nil)
        check(!PaintToolPresetPanelController.shared.isOpen, "the retained panel closes")

        // The injected panel, driven through its real controls.
        let panel = PaintToolPresetPanelController(toolState: state, store: presetStore)
        panel.open()
        defer { panel.closePanel(nil) }
        let win = panel.window
        win?.contentView?.layoutSubtreeIfNeeded()
        for label in ["Save current settings as preset", "Rename selected preset", "Update selected preset with current settings",
                      "Delete selected preset", "Apply selected preset", "Close presets panel"] {
            let control = button(win, label)
            check(control != nil && control!.visibleRect.contains(control!.bounds),
                  "the entire \(label) control fits inside the presets panel")
        }

        check(win != nil && panel.isOpen, "the presets panel opens for the injected ToolState and store")
        if let win {
            // Minimum size must visibly fit every control.
            win.setFrame(NSRect(origin: win.frame.origin, size: win.minSize), display: true)
            for label in ["Save current settings as preset", "Rename selected preset",
                          "Update selected preset with current settings", "Delete selected preset",
                          "Apply selected preset", "Close presets panel",
                          "All tools filter", "Include foreground color"] {
                let control = button(win, label)
                check(control != nil && control!.visibleRect.contains(control!.bounds),
                      "the \"\(label)\" control exists and is fully visible at the minimum size")
            }
            check(editableField(win, "Preset name") != nil, "the preset name field exists with its label")
            check(presetsTable(win) != nil, "the presets table exists with its label")
        }

        // Save Current through the controls, with the deliberate color on.
        editableField(win, "Preset name")?.stringValue = "Smoke soft"
        button(win, "Include foreground color")?.performClick(nil)
        button(win, "Save current settings as preset")?.performClick(nil)
        let stored = try presetStore.load()
        guard let created = stored.first, stored.count == 1 else {
            check(false, "Save Current stores exactly one named preset")
            return
        }
        check(created.name == "Smoke soft", "Save Current stores the name field's text")
        check(panel.selectedPresetID == created.id, "the new preset is selected by its UUID")
        check(presetsTable(win)?.numberOfRows == 1, "the table shows the stored preset")
        check(created.settings.size == 9 && created.settings.opacity == 0.5
                && created.settings.hardness == 0.25 && created.settings.pressureSize == false,
              "Save Current captured every stable setting by value")
        check(created.brushResource?.identity == softIdentity, "the current resource identity is captured")
        check(created.foregroundColor != nil, "the deliberate checkbox captured the foreground color")

        // Strict store error: a duplicate name is refused inline and rewrites
        // nothing — no reset, no replacement data.
        let bytesBefore = presetStore.storedData
        editableField(win, "Preset name")?.stringValue = "Smoke soft"
        button(win, "Save current settings as preset")?.performClick(nil)
        check(panel.lastError != nil && !(messageField(win)?.stringValue ?? "").isEmpty,
              "a duplicate name is refused with the store's inline actionable message")
        check(presetStore.storedData == bytesBefore && panel.rows.count == 1,
              "the failed save left the stored bytes and the rows untouched")
        check(panel.selectedPresetID == created.id, "the selection survived the failed save")

        // Rename through the controls; the UUID and the selection stay.
        presetsTable(win)?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        check(panel.selectedPresetID == created.id, "clicking the row selects its UUID explicitly")
        editableField(win, "Preset name")?.stringValue = "Smoke renamed"
        button(win, "Rename selected preset")?.performClick(nil)
        check(try presetStore.load().first?.name == "Smoke renamed" && panel.selectedPresetID == created.id,
              "Rename stores the new name and keeps the UUID selection")

        // Update through the controls after a live settings change.
        state.update(.paintbrush) { $0.size = 33 }
        button(win, "Update selected preset with current settings")?.performClick(nil)
        check(try presetStore.load().first?.settings.size == 33,
              "Update replaces the snapshot with the current settings")

        // Apply through the controls: tool switch, every stable field, the
        // resource identity (persisted through the brushStore path), and the
        // foreground only because the preset carries an explicit color.
        button(win, "All tools filter")?.performClick(nil)
        state.select(.eraser)
        state.update(.eraser) { $0.size = 77 }
        state.foreground = .green
        presetsTable(win)?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        button(win, "Apply selected preset")?.performClick(nil)
        check(state.current == .paintbrush, "Apply selects the preset's tool")
        let applied = state.brush(for: .paintbrush)
        check(applied.size == 33 && applied.opacity == 0.5 && applied.hardness == 0.25
                && applied.pressureSize == false,
              "Apply copies every stable field from the stored snapshot")
        check(applied.resource == softIdentity, "Apply restores the captured resource identity")
        check(state.brushStore.identity(for: .paintbrush) == softIdentity,
              "the resource choice persists through the existing setBrushResource/brushStore path")
        let appliedRGB = state.foreground.usingColorSpace(.sRGB)
        check(appliedRGB != nil && abs(Double(appliedRGB!.redComponent) - 0.25) < 0.01
                && abs(Double(appliedRGB!.greenComponent) - 0.5) < 0.01
                && abs(Double(appliedRGB!.blueComponent) - 0.75) < 0.01,
              "Apply restores the carried foreground color as sRGB")
        check(state.cloneSource == cloneSource, "the current cloneSource is preserved exactly by Apply")
        check(capturedSnapshot.size == 9 && capturedSnapshot.opacity == 0.5
                && capturedSnapshot.resource == softIdentity && capturedSnapshot.source == cloneSource,
              "the brush captured before the panel session is unchanged by every action")

        // One bounded worker stroke through the ordinary document queue:
        // the applied identity resolves there, never in the panel.
        let image = try session.newImage(width: 64, height: 48)
        let doc = try ImageDocument(session: session, image: image, name: "Preset stroke")
        documents.items.append(doc)
        var errors: [String] = []
        let previousError = doc.onError
        doc.onError = { message in errors.append(message); previousError?(message) }
        defer {
            documents.items.removeAll { $0 === doc }
            var closed = false
            doc.closeImageWhenDrained { closed = true }
            wait { closed }
            check(closed && (try? session.info(image)) == nil,
                  "the preset-stroke image closes before engine shutdown")
        }
        func settle() {
            wait { doc.pendingWork == 0 }
            spin()
        }
        let first = EngineSession.StrokePoint(x: 8, y: 24, pressure: 1, timeMilliseconds: 0)
        let points = (1...8).map {
            EngineSession.StrokePoint(x: 8 + 48 * Double($0) / 8, y: 24, pressure: 1, timeMilliseconds: UInt32($0 * 8))
        }
        let undoBefore = doc.undoInfo.undoCount
        var strokeBrush = state.brush(for: .paintbrush)
        strokeBrush.source = nil
        doc.beginStroke(at: first, brush: strokeBrush)
        doc.continueStroke(points)
        doc.endStroke()
        settle()
        check(errors.isEmpty && doc.undoInfo.undoCount == undoBefore + 1,
              "the applied preset's identity resolves on the normal worker stroke and paints one undoable edit")

        // A missing-resource identity stays selected after Apply (no hidden
        // fallback) and is reported by the existing worker/engine mechanism.
        let missing = EngineSession.ResourceIdentity(name: "Glims missing preset brush",
                                                     collection: nil, isInternal: false)
        let storedSettings = try presetStore.load().first!.settings
        try presetStore.replace(id: created.id, settings: storedSettings,
                                brushResource: PaintToolPreset.BrushResource(missing),
                                foregroundColor: nil)
        panel.reload()
        presetsTable(win)?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        button(win, "Apply selected preset")?.performClick(nil)
        check(state.brush(for: .paintbrush).resource == missing,
              "a missing-resource identity remains selected after Apply — no fallback, no enumeration")
        let undoMissing = doc.undoInfo.undoCount
        var missingBrush = state.brush(for: .paintbrush)
        missingBrush.source = nil
        doc.beginStroke(at: first, brush: missingBrush)
        doc.continueStroke(points)
        doc.endStroke()
        settle()
        check(!errors.isEmpty && doc.undoInfo.undoCount == undoMissing,
              "the missing identity is reported by the ordinary stroke and paints nothing")

        // Return to the current-tool filter after the cross-tool Apply.
        button(win, "All tools filter")?.performClick(nil)
        // The explicit All-tools filter through its real checkbox.
        state.select(.eraser)
        editableField(win, "Preset name")?.stringValue = "Eraser one"
        button(win, "Save current settings as preset")?.performClick(nil)
        check(panel.rows.count == 1 && panel.rows.first?.tool == .eraser,
              "with the filter off only the current paint tool's presets are listed")
        button(win, "All tools filter")?.performClick(nil)
        check(panel.rows.count == 2, "the explicit All-tools filter lists every tool's presets")
        button(win, "All tools filter")?.performClick(nil)
        check(panel.rows.count == 1, "unchecking the filter returns to the current tool's presets")

        // Delete through the controls: the UUID selection is cleared, never
        // substituted by the first row.
        presetsTable(win)?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        let eraserPreset = panel.selectedPresetID
        button(win, "Delete selected preset")?.performClick(nil)
        let remainingCount = (try presetStore.load()).count
        check(panel.rows.isEmpty && panel.selectedPresetID == nil
                && remainingCount == 1 && eraserPreset != nil,
              "Delete removes the selected preset by UUID and clears the selection")

        // Reopen persistence: a fresh panel over the same store sees the
        // stored preset and can select it by UUID; Close hides the window.
        state.select(.paintbrush)
        panel.closePanel(nil)
        check(!panel.isOpen && !(panel.window?.isVisible ?? false), "Close hides the retained panel")
        let reopened = PaintToolPresetPanelController(toolState: state, store: presetStore)
        reopened.open()
        let win2 = reopened.window
        check(reopened.rows.count == 1 && reopened.rows.first?.id == created.id,
              "the stored preset persists across closing and reopening the panel")
        presetsTable(win2)?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        check(reopened.selectedPresetID == created.id, "reopen selects the persisted preset by UUID")
        state.update(.paintbrush) { $0.size = 77 }
        try presetStore.delete(id: created.id)
        reopened.applySelected()
        check(reopened.lastError != nil && state.brush(for: .paintbrush).size == 77,
              "Apply refuses a preset removed since the row was loaded and leaves settings untouched")

        let stale = try presetStore.create(tool: .paintbrush, name: "Already removed", settings: storedSettings)
        reopened.reload()
        presetsTable(win2)?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        try presetStore.delete(id: stale.id)
        reopened.deleteSelected()
        check(reopened.lastError != nil && reopened.rows.isEmpty && reopened.selectedPresetID == nil,
              "a failed Delete refreshes stale rows and keeps its actionable error visible")
        reopened.closePanel(nil)
        check(!reopened.isOpen && !(reopened.window?.isVisible ?? false), "the reopened panel closes")
    }
}
