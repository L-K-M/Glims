import Foundation

// MARK: - GLIMS_SMOKE_CASE=linked-close

@MainActor
extension EngineSmokeTest {
    /// Installs the generated slow-loader Python plug-in named by
    /// `GLIMS_SMOKE_SLOW_LOADER_SCRIPT` into the throwaway user directory
    /// (`<work>/user/plug-ins/glims-slow-load/glims-slow-load.py`, one
    /// directory per plug-in, executable .py inside — the layout the
    /// engine's own plug-in scan expects), points `GLIMS_SLOWLOAD_DIR` at
    /// the smoke work directory so the plug-in's load parks on the
    /// markers there, and leaves the release marker present so any load
    /// outside the armed window returns at once. Runs before the engine
    /// starts, so the first plug-in query already sees the loader.
    /// Returns false when the script named by the environment is missing.
    static func installLinkedCloseSlowLoader(work: URL) -> Bool {
        guard let script = ProcessInfo.processInfo.environment["GLIMS_SMOKE_SLOW_LOADER_SCRIPT"],
              let source = FileManager.default.contents(atPath: script) else {
            check(false, "GLIMS_SMOKE_SLOW_LOADER_SCRIPT names no readable slow-loader script")
            return false
        }
        let files = FileManager.default
        let plugInDirectory = work.appendingPathComponent("user/plug-ins/glims-slow-load")
        let plugInFile = plugInDirectory.appendingPathComponent("glims-slow-load.py")
        do {
            try files.createDirectory(at: plugInDirectory, withIntermediateDirectories: true)
            try source.write(to: plugInFile)
            try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: plugInFile.path)
        } catch {
            check(false, "the slow-loader plug-in installs into the throwaway user directory (\(error))")
            return false
        }
        // The plug-in process inherits this environment; it reads the
        // marker directory from it.
        setenv("GLIMS_SLOWLOAD_DIR", work.path, 1)
        files.createFile(atPath: work.appendingPathComponent("slow-load-release").path,
                         contents: Data("x".utf8))
        return true
    }

    /// Parks the native link monitor's own reload of a changed `.gslow`
    /// file inside the slow loader's nested main loop, then closes the
    /// image through the interface's `closeImageWhenDrained`.
    /// `EngineActivity.closeImage` answers the engine's BUSY with a 0.05 s
    /// main-queue retry, so while the loader is parked the close must stay
    /// deferred, the image must stay alive and the main loop must keep
    /// advancing; once the release marker returns, the close completes
    /// exactly once and the image is gone. Liveness is asserted through
    /// the facade's own read-only calls (`info`, `layers`) — the native
    /// oracle — never the document's cached state, and the only calls made
    /// while the engine is busy are those reads plus the close itself
    /// (cancellation stays deliverable). Engines without link layers
    /// (before 3.2) skip explicitly.
    static func exerciseLinkedClose(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        if session.supportsLinkLayers == false {
            check(true, "linked-close skipped on engine \(session.version): link layers need GIMP 3.2+ (supported skip)")
            return
        }
        let files = FileManager.default
        let enteredPath = work.appendingPathComponent("slow-load-entered").path
        let donePath = work.appendingPathComponent("slow-load-done").path
        let releasePath = work.appendingPathComponent("slow-load-release").path
        func markerExists(_ path: String) -> Bool { files.fileExists(atPath: path) }
        func removeMarker(_ path: String) { try? files.removeItem(atPath: path) }
        func writeMarker(_ path: String) { files.createFile(atPath: path, contents: Data("x".utf8)) }
        func wait(_ condition: () -> Bool, _ seconds: TimeInterval = 15) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { spin(0.02) }
        }

        func imageIsMissing(_ image: Int32) -> Bool {
            do {
                _ = try session.info(image)
                return false
            } catch let error as EngineSession.EngineError {
                return error.isNotFound
            } catch {
                return false
            }
        }

        let gslow = work.appendingPathComponent("slow-source.gslow")
        try "glims slow load fixture\n".write(to: gslow, atomically: false, encoding: .utf8)

        let image = try session.newImage(width: 8, height: 8)
        let document = try ImageDocument(session: session, image: image, name: "Linked close")
        documents.items.append(document)
        var completions = 0
        defer {
            // Finite cleanup on every path: let a parked loader finish,
            // then drain the close so the engine never stops under it.
            writeMarker(releasePath)
            documents.items.removeAll { $0 === document }
            if !document.isClosing {
                document.closeImageWhenDrained { completions += 1 }
            }
            wait { completions > 0 }
            // The deliberately old close implementation used by the red
            // regression may report BUSY as a completed close. Clean up
            // that live image after releasing the loader as well.
            let deadline = Date().addingTimeInterval(15)
            while !imageIsMissing(image) && Date() < deadline {
                do { try session.closeImage(image) }
                catch let error as EngineSession.EngineError where error.isBusy { spin(0.02) }
                catch { break }
            }
            check(imageIsMissing(image), "linked-close cleanup leaves no live image")
        }

        // The release marker is present, so this first load returns at
        // once; it also proves the installed fixture plug-in works.
        var placed: Result<ImageDocument.ImportOutcome, Error>?
        document.placeLink(from: gslow) { placed = $0 }
        wait { placed != nil && document.pendingWork == 0 }
        guard case .success(.placedLink) = placed else {
            check(false, "a link layer on the .gslow file is placed through the slow loader (\(placed as Any))")
            return
        }
        check((try? session.layers(image))?.contains { $0.kind == .link } == true,
              "the native oracle sees the placed link layer")

        // Arm the pause: no markers at all, then rewrite the file in place
        // so the link monitor reloads it with no facade call around the
        // load. From here on, every exit releases the marker.
        removeMarker(enteredPath)
        removeMarker(donePath)
        removeMarker(releasePath)
        defer { writeMarker(releasePath) }
        try "glims slow load fixture, changed\n".write(to: gslow, atomically: false, encoding: .utf8)
        wait { markerExists(enteredPath) }
        guard markerExists(enteredPath) else {
            check(false, "the link monitor's reload entered the paused slow loader")
            return
        }
        check(true, "the link monitor's reload entered the paused slow loader")
        check(!EngineActivity.shared.isBusy && document.pendingWork == 0,
              "the paused reload is native monitor work outside an app activity")

        // Close while the native automatic monitor load is parked.
        document.closeImageWhenDrained { completions += 1 }
        var loopTick = false
        DispatchQueue.main.async { loopTick = true }
        wait { loopTick }
        check(loopTick, "the main loop advances while the close is deferred")
        spin(0.6) // several 0.05 s retry ticks
        check(completions == 0, "the close completion is deferred while the native load is paused")
        check((try? session.info(image)) != nil,
              "the native read-only oracle still reports the image alive during the paused load")

        // Release the loader; the close must then complete exactly once.
        writeMarker(releasePath)
        wait { completions == 1 }
        check(completions == 1, "the close completes exactly once after the loader is released")
        spin(0.3)
        check(completions == 1, "no retry fires a second completion")
        check(imageIsMissing(image),
              "the native oracle reports NOT_FOUND after the single completion")
    }
}
