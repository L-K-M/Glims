import AppKit

/// `--smoke-test`: build the workspace, lay it out, exercise zoom, and report.
/// Returns 0 on success and 1 with a message on stderr otherwise.
@MainActor
enum SmokeTest {
    static func run(_ controller: WorkspaceWindowController) -> Int32 {
        var failures: [String] = []
        func check(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        guard let window = controller.window, let content = window.contentView else {
            FileHandle.standardError.write(Data("smoke test: workspace window has no content\n".utf8))
            return 1
        }
        content.layoutSubtreeIfNeeded()

        // Rigi's chrome is drawn light; system-colored text on it must be
        // too, whatever the Mac's own appearance (docs/design.md).
        check(controller.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua,
              "the window is not in the light Aqua appearance")
        check(controller.canvas.frame.height > 0, "canvas has no height")
        check(HelpManual.load() != nil, "the bundled manual did not load")
        check(controller.statusBar.frame.height > 0, "status bar has no height")
        check(controller.canvas.frame.minY >= controller.statusBar.frame.maxY
              || controller.canvas.frame.maxY <= controller.statusBar.frame.minY,
              "canvas overlaps the status bar")

        controller.zoomIn()
        check(controller.zoomPercent == ZoomLadder.zoomIn(from: ZoomLadder.actualPixels), "zoom in did not step")
        controller.resetZoom()
        check(controller.zoomPercent == ZoomLadder.actualPixels, "zoom reset did not return to 100%")

        if failures.isEmpty {
            print("smoke test passed")
            return 0
        }
        FileHandle.standardError.write(Data(("smoke test failed:\n" + failures.map { "- \($0)\n" }.joined()).utf8))
        return 1
    }
}
