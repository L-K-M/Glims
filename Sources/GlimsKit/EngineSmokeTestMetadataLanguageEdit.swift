import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseMetadataLanguageEdit(_ session: EngineSession, work: URL, documents: DocumentList) throws {
        guard let fixture = ProcessInfo.processInfo.environment["GLIMS_LANGUAGE_FIXTURE"] else {
            return check(false, "the language-edit check needs its independent known XCF fixture")
        }
        let image = try session.openImage(path: fixture)
        let document = try ImageDocument(session: session, image: image, name: "Language edit")
        documents.items.append(document)
        var isClosed = false
        func wait(_ condition: () -> Bool) {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline { spin(0.01) }
        }
        func settle() {
            document.inputQueue.sync {}
            wait { document.pendingWork == 0 && !EngineActivity.shared.isBusy }
        }
        defer {
            if !isClosed {
                document.closeImageWhenDrained { isClosed = true }
                wait { isClosed }
            }
            documents.items.removeAll { $0 === document }
        }
        let original = try session.metadataLanguages(image, tag: "Xmp.dc.title")
        let rights = try session.metadataLanguages(image, tag: "Xmp.dc.rights")
        let pixels = try session.copyPixels(image, merged: true).pixels
        let undo = try session.undoInfo(image)
        let readGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { readGate.wait() }
        var read: Result<[EngineSession.MetadataLanguageValue], Error>?
        let workBefore = document.pendingWork
        document.readMetadataLanguages("Xmp.dc.title") { read = $0 }
        check(document.pendingWork == workBefore + 1 && read == nil,
              "a language-map read is counted behind previously accepted input")
        readGate.signal()
        settle()
        check((try? read?.get()) == original, "the document read returns the independently known complete map")
        var result: Result<Void, Error>?
        document.editMetadataLanguage("Xmp.dc.title", language: "fr", text: "Bonjour 山") { result = $0 }
        check(document.pendingWork >= 2 && result == nil, "a language edit counts native work and deferred state refresh")
        settle()
        let changed = try session.metadataLanguages(image, tag: "Xmp.dc.title")
        check(try result.map { if case .success = $0 { return true }; return false } == true
                && changed.contains(.init(language: "fr", text: "Bonjour 山"))
                && changed.filter { $0.language != "fr" } == original.filter { $0.language != "fr" }
                && session.metadataLanguages(image, tag: "Xmp.dc.rights") == rights,
              "the real document edit replaces only its captured existing language")
        check(try document.undoInfo.undoCount == undo.undoCount + 1 && document.info.isDirty
                && session.copyPixels(image, merged: true).pixels == pixels,
              "the completion refreshes dirty state and exactly one Undo without changing pixels")
        document.undo(); settle()
        check(try session.metadataLanguages(image, tag: "Xmp.dc.title") == original,
              "one document Undo restores every original language")
        document.redo(); settle()
        check(try session.metadataLanguages(image, tag: "Xmp.dc.title") == changed,
              "one document Redo restores every edited language")
        let history = try session.undoInfo(image)
        result = nil
        document.editMetadataLanguage("Xmp.dc.title", language: "fr", text: "Bonjour 山") { result = $0 }
        settle()
        check(try result.map { if case .success = $0 { return true }; return false } == true
                && session.undoInfo(image) == history, "a document no-op succeeds without another Undo step")
        result = nil
        document.editMetadataLanguage("Xmp.dc.title", language: "zz", text: "Missing") { result = $0 }
        settle()
        check(try result.map { if case .failure = $0 { return true }; return false } == true
                && session.metadataLanguages(image, tag: "Xmp.dc.title") == changed
                && session.undoInfo(image) == history,
              "a native missing-language refusal reaches completion without a false update")
        let copy = work.appendingPathComponent("language-edited.xcf")
        try session.saveCopy(image, to: copy.path)
        let reopened = try session.openImage(path: copy.path)
        check(try session.metadataLanguages(reopened, tag: "Xmp.dc.title") == changed
                && session.metadataLanguages(reopened, tag: "Xmp.dc.rights") == rights,
              "the document's changed and unrelated language maps survive native save/reopen")
        try session.closeImage(reopened)
        let closeGate = DispatchSemaphore(value: 0)
        document.inputQueue.async { closeGate.wait() }
        result = nil
        document.editMetadataLanguage("Xmp.dc.title", language: "fr", text: "Final text") { result = $0 }
        document.closeImageWhenDrained { isClosed = true }
        check(!isClosed && result == nil, "close waits for an already accepted language edit")
        closeGate.signal()
        wait { isClosed }
        check(isClosed && result.map { if case .success = $0 { return true }; return false } == true
                && (try? session.info(image)) == nil, "close drains the write and completion before destroying the image")
        var late: Result<[EngineSession.MetadataLanguageValue], Error>?
        document.readMetadataLanguages("Xmp.dc.title") { late = $0 }
        result = nil
        document.editMetadataLanguage("Xmp.dc.title", language: "fr", text: "Late") { result = $0 }
        check(late.map { if case .failure = $0 { return true }; return false } == true
                && result.map { if case .failure = $0 { return true }; return false } == true,
              "late language reads and edits after close fail through their completions")
    }
}
