import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseDuotonePreservation(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        func wait(seconds: TimeInterval = 20, _ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(seconds)
            while !condition() && Date() < deadline { EngineSmokeTestHost.pumpEvents() }
        }
        guard let fixturePath = ProcessInfo.processInfo.environment["GLIMS_DUOTONE_FIXTURE"] else {
            return check(false, "Duotone fixture path is supplied")
        }
        let fixture = URL(fileURLWithPath: fixturePath)
        let input = try Data(contentsOf: fixture)
        guard input.count >= 30 else { return check(false, "Duotone fixture contains a header") }
        let length = input[26..<30].reduce(0) { ($0 << 8) | Int($1) }
        guard length > 0, length <= input.count - 30, input[24] == 0, input[25] == 8 else {
            return check(false, "Duotone fixture contains a bounded color-mode block")
        }
        let block = input.subdata(in: 30..<(30 + length))
        let image = try session.openImage(path: fixture.path)
        let document = try ImageDocument(session: session, image: image, name: "Duotone fixture")
        documents.items.append(document)
        let controller = DocumentWindowController(document: document, exportDirectory: work)
        controller.showWindow(nil)
        defer {
            controller.window?.orderOut(nil)
            var stopped = false
            controller.canvas.stopRendering { stopped = true }; wait { stopped }
            var closed = false
            document.closeImageWhenDrained { closed = true }; wait { closed }
            documents.items.removeAll { $0 === document }
        }
        let before = try session.copyPixels(image, merged: true).pixels
        let undo = try session.undoInfo(image).undoCount
        check(document.colorInfo.mode == .grayscale && undo == 0,
              "Photoshop Duotone opens as a grayscale document without an extra Undo step")
        let output = work.appendingPathComponent("duotone-preserved.xcf")
        var finished = false
        var failure: Error?
        document.save(to: output) { error in failure = error; finished = true }
        wait(seconds: 90) { finished }
        check(finished && failure == nil && FileManager.default.fileExists(atPath: output.path),
              "the document Save pipeline writes XCF")
        guard finished, failure == nil, FileManager.default.fileExists(atPath: output.path) else { return }
        let saved = try Data(contentsOf: output)
        check(saved.range(of: block) != nil, "XCF contains the exact opaque Duotone block")
        check(try session.copyPixels(image, merged: true).pixels == before && session.undoInfo(image).undoCount == undo,
              "saving preserves grayscale pixels and Undo history")
        let reopened = try session.openImage(path: output.path)
        defer { try? session.closeImage(reopened) }
        let again = work.appendingPathComponent("duotone-preserved-again.xcf")
        try session.save(reopened, to: again.path)
        let second = try Data(contentsOf: again)
        let originalAfter = try Data(contentsOf: fixture)
        check(second.range(of: block) != nil && originalAfter == input,
              "reopening and resaving retains the block without changing the source PSD")
    }
}
