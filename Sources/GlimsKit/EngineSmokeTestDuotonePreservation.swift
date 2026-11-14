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
        // Independently locate the fixture's resource rather than relying on
        // the engine's metadata reader to supply the expected bytes.
        func alternateResource() -> Data? {
            let start = 30 + length
            guard input.count - start >= 4 else { return nil }
            let resourceSize = input[start..<(start + 4)].reduce(0) { ($0 << 8) | Int($1) }
            var position = start + 4
            guard resourceSize <= input.count - position else { return nil }
            let end = position + resourceSize
            var found: Data?
            while position < end {
                guard end - position >= 12,
                      input[position..<(position + 4)].elementsEqual([0x38, 0x42, 0x49, 0x4d]) else { return nil }
                let id = (Int(input[position + 4]) << 8) | Int(input[position + 5])
                let nameSize = (Int(input[position + 6]) + 2) & ~1
                guard nameSize <= end - position - 6, end - position - 6 - nameSize >= 4 else { return nil }
                let sizeOffset = position + 6 + nameSize
                let count = input[sizeOffset..<(sizeOffset + 4)].reduce(0) { ($0 << 8) | Int($1) }
                let dataStart = sizeOffset + 4
                guard count <= end - dataStart, count % 2 == 0 || count < end - dataStart else { return nil }
                if id == 1066 {
                    guard found == nil else { return nil }
                    found = input.subdata(in: dataStart..<(dataStart + count))
                }
                position = dataStart + count + count % 2
            }
            return position == end ? found : nil
        }
        guard let alternate = alternateResource(), alternate.count == 794 else {
            return check(false, "Duotone fixture contains bounded alternate colors")
        }
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
        check(saved.range(of: alternate) != nil, "XCF contains the exact alternate Duotone colors")
        check(try session.copyPixels(image, merged: true).pixels == before && session.undoInfo(image).undoCount == undo,
              "saving preserves grayscale pixels and Undo history")
        let reopened = try session.openImage(path: output.path)
        defer { try? session.closeImage(reopened) }
        let again = work.appendingPathComponent("duotone-preserved-again.xcf")
        try session.save(reopened, to: again.path)
        let second = try Data(contentsOf: again)
        let originalAfter = try Data(contentsOf: fixture)
        check(second.range(of: block) != nil && second.range(of: alternate) != nil && originalAfter == input,
              "reopening and resaving retains both Duotone blocks without changing the source PSD")
    }
}
