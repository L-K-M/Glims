import AppKit

@MainActor
extension EngineSmokeTest {
    static func exerciseInkIdentity(_ session: EngineSession) throws {
        let legacy = ProcessInfo.processInfo.environment["GLIMS_SMOKE_INK_IDENTITY_LEGACY"] == "1"
        check(session.supportsInkChannelIdentity == !legacy, "ink identity prefix capability matches producer")
        check(session.supportsInkLevels, "direct ink Levels supports its independent slot184 prefix")
        if legacy { check(!session.supportsInkLevelSnapshots, "legacy producer has no snapshot API") }
        guard let profile = NSColorSpace.genericCMYK.iccProfileData else {
            throw ImageDocument.DocumentError.targetChanged
        }
        func pixels(_ image: Int32) throws -> Data {
            let rendered = try session.render(image, scale: 1, area: CGRect(x: 0, y: 0, width: 8, height: 4))
            return rendered.dataProvider!.data! as Data
        }
        for mode in [EngineSession.ColorMode.cmyk, .multichannel] {
            for component in [EngineSession.ColorComponent.u8, .u16, .float] {
                let image = try mode == .cmyk
                    ? session.newCmykImage(width: 8, height: 4, component: component, profileICC: profile)
                    : session.newMultichannelImage(width: 8, height: 4, component: component, channelCount: 4)
                defer { try? session.closeImage(image) }
                let channels = try session.channels(image)
                let target = channels[0].id
                try session.channelCommand(.select, channel: target, image: image)
                try session.editInk(image, channel: target, settings: .init(operation: .fill, intensity: 0.25, opacity: 1))
                let before = try pixels(image)
                let undo = try session.undoInfo(image)
                if !legacy {
                    var ids = Set<UUID>()
                    for (index, channel) in channels.enumerated() {
                        let identity = try session.inkChannelIdentity(image, channel: channel.id)
                        check(identity.colorMode == mode && identity.ordinal == UInt32(index) && identity.count == 4,
                              "Swift identity preserves native mode and ordered ink position")
                        check(identity.role.rawValue == (mode == .cmyk ? UInt32(index + 1) : 0),
                              "Swift identity returns canonical CMYK role or unspecified spot role")
                        check(ids.insert(identity.uuid).inserted, "separate planes have distinct UUID values within this document")
                    }
                    let afterRead = try pixels(image), afterUndo = try session.undoInfo(image)
                    check(afterRead == before && afterUndo.undoCount == undo.undoCount,
                          "Swift identity reads change neither visible pixels nor Undo")
                }
                let expectedImage = try session.duplicateImage(image)
                defer { try? session.closeImage(expectedImage) }
                let expectedTarget = try session.channels(expectedImage)[0].id
                try session.channelCommand(.select, channel: expectedTarget, image: expectedImage)
                try session.editInk(expectedImage, channel: expectedTarget,
                    settings: .init(operation: .fill, intensity: component == .u8 ? 128.0 / 255 : 0.5, opacity: 1))
                let expected = try pixels(expectedImage)
                try session.applyInkLevels(image, channel: target, settings: .init(value: .init(gamma: 2)))
                let applied = try pixels(image), afterUndo = try session.undoInfo(image)
                check(applied == expected && applied != before, "direct Swift Levels matches an independent scalar Fill oracle")
                check(afterUndo.undoCount == undo.undoCount + 1, "direct Swift Levels creates one native Undo")
                try session.undo(image)
                check(try pixels(image) == before, "direct Swift Levels Undo restores original pixels")
                try session.redo(image)
                check(try pixels(image) == expected, "direct Swift Levels Redo restores expected pixels")
            }
        }
    }
}
