import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseStatusInformation(_ session: EngineSession, documents: DocumentList) throws {
        var owners: [DocumentWindowController] = []
        var orphan: Int32?
        var gates: [DispatchSemaphore] = []
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if condition() { return true }
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            return false
        }
        defer {
            gates.forEach { $0.signal() }
            for owner in owners {
                owner.closeDiscardingChanges()
                check(wait { owner.imageDocument.pendingWork == 0
                    && (try? session.info(owner.imageDocument.image)) == nil },
                    "status information: owned document drains and closes")
                documents.items.removeAll { $0 === owner.imageDocument }
            }
            if let orphan { try? session.closeImage(orphan) }
        }
        for (index, component) in [EngineSession.ColorComponent.float, .u16].enumerated() {
            let image = try session.newImage(width: index == 0 ? 16 : 9, height: index == 0 ? 12 : 7)
            orphan = image
            try session.convertPrecision(image, component: component, trc: .nonlinear)
            let document = try ImageDocument(session: session, image: image, name: "Status information \(index)")
            let owner = DocumentWindowController(document: document)
            owners.append(owner); orphan = nil; documents.items.append(document)
            owner.showWindow(nil)
            owner.zoom(to: 100)
        }
        let a = owners[0], b = owners[1], document = a.imageDocument
        check(a.statusInformation.superview != nil && b.statusInformation.superview != nil,
              "status information: both actual status strips contain their chooser")
        check(wait { a.canvas.renderedTileCount > 0 && !a.canvas.hasPendingRender
            && b.canvas.renderedTileCount > 0 && !b.canvas.hasPendingRender },
              "status information: asynchronous native tiles reach both windows")
        check(a.canvas.renderMetrics.cachedPixelBytes == 16 * 12 * 4,
              "status information: one actual RGBA tile reports its exact pixel payload")
        check(a.canvas.renderMetrics.lastTileSeconds.map { $0.isFinite && $0 >= 0 } == true,
              "status information: an accepted successful native tile supplies measured time")
        let before = try session.info(document.image), history = try session.undoInfo(document.image)
        let pixels = try session.copyPixels(document.image, merged: true).pixels
        let color = try session.colorInfo(document.image)
        b.window?.makeKeyAndOrderFront(nil)
        for choice in StatusInformationChoice.allCases {
            a.statusInformation.selectItem(withTag: choice.rawValue)
            if let action = a.statusInformation.action {
                _ = NSApp.sendAction(action, to: a.statusInformation.target, from: a.statusInformation)
            }
            check(a.statusInformation.selectedInformation == choice
                && a.statusInformation.titleOfSelectedItem == a.statusInformation.information.title(for: choice),
                "status information: the actual \(choice.label) action displays its owning cached value")
            check(b.statusInformation.selectedInformation == .dimensions,
                  "status information: choosing \(choice.label) does not redirect to the front window")
        }
        check(a.statusInformation.information.precisionLabel != b.statusInformation.information.precisionLabel,
              "status information: the two precision values belong to their actual source images")

        // Block an older generation before native rendering, then supersede it.
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        gates.append(release)
        a.canvas.enqueueRenderBarrier { entered.signal(); release.wait() }
        check(wait { entered.wait(timeout: .now()) == .success },
              "status information: the old render is held behind an actual worker barrier")
        let previous = a.canvas.onRenderMetricsChange
        var observed: [CanvasRenderMetrics] = []
        a.canvas.onRenderMetricsChange = { value in observed.append(value); previous?(value) }
        a.zoom(to: 200)
        a.zoom(to: 150)
        check(a.canvas.renderMetrics.cachedPixelBytes == 0 && a.canvas.renderMetrics.lastTileSeconds == nil
            && a.statusInformation.information.renderMetrics.lastTileSeconds == nil,
              "status information: generation changes immediately clear cache bytes and tile time")
        release.signal()
        check(wait { !a.canvas.hasPendingRender && a.canvas.renderedTileCount > 0 },
              "status information: fresh-generation native rendering settles")
        check(!observed.contains { $0.cachedPixelBytes == 32 * 24 * 4 },
              "status information: the stale 200-percent tile never publishes metrics")
        check(a.canvas.renderMetrics.cachedPixelBytes == 24 * 18 * 4,
              "status information: only the accepted 150-percent tile contributes pixel bytes")
        a.canvas.onRenderMetricsChange = previous
        a.window?.setContentSize(NSSize(width: 360, height: 260))
        a.showProgress(EngineSession.Progress(fraction: 0.5, text: "Checking the narrow status strip"))
        a.window?.contentView?.layoutSubtreeIfNeeded()
        let trailing = a.statusBar.subviews.compactMap { $0 as? NSStackView }.first
        print("     status information minimum-width check: window=\(a.window?.frame.width ?? 0), status=\(a.statusBar.bounds.width), controls=\(trailing?.frame ?? .zero)")
        check(a.statusBar.bounds.width <= 361,
              "status information: showing progress preserves the requested minimum window width")
        check(a.statusInformation.isHidden,
              "status information: the narrow busy strip gives progress and Cancel priority")
        check(trailing.map { $0.frame.minX >= -0.5 && $0.frame.maxX <= a.statusBar.bounds.maxX + 0.5 } == true,
              "status information: progress, Cancel, information and zoom fit the minimum-width window")
        a.showProgress(nil)
        a.window?.contentView?.layoutSubtreeIfNeeded()
        check(!a.statusInformation.isHidden && a.statusInformation.selectedInformation == .lastTileTime,
              "status information: finishing progress restores the same selected readout")
        check((try? session.info(document.image)) == before && (try? session.undoInfo(document.image)) == history
            && (try? session.colorInfo(document.image)) == color
            && (try? session.copyPixels(document.image, merged: true).pixels) == pixels,
              "status information: choices, timing, zoom and progress preserve native image state and Undo")
    }
}
