import AppKit

@MainActor
extension EngineSmokeTest {
    /// Service-only regression: no windows, sheets, renderers, or AppKit host.
    /// A busy close request queues its decision before the worker's cache reads.
    static func exerciseExclusiveEditClose(_ session: EngineSession, documents: DocumentList) throws {
        func expect(_ value: Bool, _ text: String) { check(value, "exclusive-edit-close: \(text)") }
        func require(_ value: Bool, _ text: String) throws {
            guard value else {
                throw NSError(domain: "ExclusiveEditCloseSmoke", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: text])
            }
        }
        func wait(_ condition: () -> Bool, _ text: String) throws {
            let deadline = Date().addingTimeInterval(15)
            while !condition() && Date() < deadline {
                _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
            }
            try require(condition(), text)
        }
        func pixels(_ image: Int32) throws -> Data {
            let result = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 8, height: 8))
            guard let data = result.dataProvider?.data as Data? else {
                throw NSError(domain: "ExclusiveEditCloseSmoke", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "Missing source pixels"])
            }
            return data
        }
        guard let profile = NSColorSpace.genericCMYK.iccProfileData else {
            throw NSError(domain: "ExclusiveEditCloseSmoke", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Missing real CMYK profile"])
        }
        func exercise(mode: EngineSession.ColorMode, nested: Bool) throws {
            let label = "\(mode) / \(nested ? "nested activity" : "first idle")"
            try require(!EngineActivity.shared.isBusy, "The shared engine must start idle")
            let image = mode == .cmyk
                ? try session.newCmykImage(width: 8, height: 8, component: .u8, profileICC: profile)
                : try session.newMultichannelImage(width: 8, height: 8, component: .u8, channelCount: 4)
            let document: ImageDocument
            do { document = try ImageDocument(session: session, image: image, name: label) }
            catch { try? session.closeImage(image); throw error }
            documents.items.append(document)
            let originalState = document.onStateChange, originalError = document.onError
            var errors: [String] = []
            document.onError = { errors.append($0) }
            defer {
                document.onStateChange = originalState
                var closed = false
                document.closeImageWhenDrained { closed = true }
                do { try wait({ closed && document.pendingWork == 0 && !EngineActivity.shared.isBusy }, "Owned document did not close") }
                catch { expect(false, "\(label): cleanup drains accepted work: \(error)") }
                expect(closed, "\(label): owned native document closes after drain")
                expect(errors.isEmpty, "\(label): no document errors: \(errors)")
                document.onError = originalError
                documents.items.removeAll { $0 === document }
            }
            try require(!document.recorder.isRecording && !document.recorder.isReplaying,
                        "Recorder must remain off for this service witness")
            try require(document.pendingWork == 0 && !document.hasUnsavedChanges && !document.info.isDirty,
                        "The close-decision witness must begin genuinely clean")
            guard let channel = document.activeChannel else {
                throw NSError(domain: "ExclusiveEditCloseSmoke", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "No selected native ink channel"])
            }
            let originalPixels = try pixels(image), originalUndo = try session.undoInfo(image)
            var queued = false, busyDirty: Bool?, firstIdleDirty: Bool?
            var nestedAccepted: Bool?, nestedBusyDirty: Bool?, nestedCompleted = false
            var callbackCount = 0
            document.onStateChange = {
                originalState?()
                guard !queued, EngineActivity.shared.isBusy else { return }
                queued = true
                busyDirty = document.hasUnsavedChanges
                if nested {
                    // This earlier idle action starts another activity. The
                    // close decision below then waits for its idle boundary,
                    // ahead of the original command's deferred dirty read.
                    EngineActivity.shared.whenIdle {
                        nestedAccepted = EngineActivity.shared.perform(label: "Exclusive close fixture barrier",
                            work: {}, completion: { nestedCompleted = true })
                        nestedBusyDirty = document.hasUnsavedChanges
                    }
                }
                EngineActivity.shared.whenIdle {
                    callbackCount += 1
                    firstIdleDirty = document.hasUnsavedChanges
                }
            }
            var result: Result<Void, Error>?
            let accepted = document.editInk(.init(operation: .fill, intensity: 0.25, opacity: 1), channel: channel) {
                result = $0
            }
            expect(accepted && queued, "\(label): real native edit is admitted through the busy observer")
            try wait({ result != nil && document.pendingWork == 0 && !EngineActivity.shared.isBusy &&
                       firstIdleDirty != nil && (!nested || nestedCompleted) }, "Exclusive edit/close witness did not drain")
            try result?.get()
            document.onStateChange = originalState
            expect(busyDirty == true, "\(label): busy admission already counts the accepted edit as unsaved")
            expect(callbackCount == 1 && firstIdleDirty == true,
                   "\(label): the first idle close decision sees unsaved work before cache reconciliation")
            if nested {
                expect(nestedAccepted == true && nestedCompleted,
                       "\(label): an earlier idle action really admitted and completed a second activity")
                expect(nestedBusyDirty == true, "\(label): dirty admission survives the nested activity")
            }
            let updatedPixels = try pixels(image), updatedUndo = try session.undoInfo(image)
            expect(updatedPixels != originalPixels && updatedUndo.undoCount == originalUndo.undoCount + 1,
                   "\(label): native Fill actually changes pixels and creates exactly one Undo step")
            expect(document.hasUnsavedChanges && document.info.isDirty,
                   "\(label): reconciled native state remains dirty after all holds drain")
            expect(!document.recorder.isRecording && document.recorder.records.isEmpty,
                   "\(label): the regression does not start or populate Recorder")
        }
        for mode in [EngineSession.ColorMode.multichannel, .cmyk] {
            try exercise(mode: mode, nested: false)
            try exercise(mode: mode, nested: true)
        }
    }
}
