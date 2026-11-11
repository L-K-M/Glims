import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseRecorderChannelCaptureContract(_ session: EngineSession, documents: DocumentList) throws {
        func wait(_ condition: () -> Bool) -> Bool {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.005) }
            return condition()
        }
        let image = try session.newImage(width: 41, height: 29)
        try session.select(.ellipse(CGRect(x: 12, y: 6, width: 18, height: 14)), image: image)
        let expected = try session.selectionBounds(image: image)
        let channel = try session.channelFromSelection(image, name: "Explicit source")
        try session.selectItems([], kind: .channel, image: image)
        try session.select(.none, image: image)
        let document = try ImageDocument(session: session, image: image, name: "Channel capture contract")
        documents.items.append(document)
        defer {
            var closed = false
            document.closeImageWhenDrained { closed = true }
            check(wait { closed }, "channel capture contract: owned native image closes")
            documents.items.removeAll { $0 === document }
        }
        check(document.selectedChannelIDs.isEmpty && document.activeLayer != nil,
              "channel capture contract: the paint target is a layer")
        try document.startRecording()
        document.channelToSelection(channel, operation: .replace)
        try document.stopRecording()
        check(wait { document.pendingWork == 0 && document.recorder.pendingCount == 0 },
              "channel capture contract: accepted work settles")
        check(try session.selectionBounds(image: image) == expected,
              "channel capture contract: the real native action applied its explicit channel")
        let labels = document.recorder.records.compactMap { row -> String? in
            if case .success(let command) = row.resolution { return command.title }
            return nil
        }
        check(labels == ["Channel to Selection"],
              "channel capture contract: the accepted channel action produces one successful semantic row")
    }
}
