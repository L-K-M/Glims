import XCTest
import CGlimsEngine
@testable import GlimsKit

/// The blend commands' value types: their validation mirrors the engine's
/// INVALID_ARGUMENT refusals, and the raw mappers carry every field across
/// the facade unchanged.
final class BlendSettingsTests: XCTestCase {
    private typealias Ref = EngineSession.ChannelRef
    private typealias ImageSettings = EngineSession.BlendImageSettings
    private typealias ChannelsSettings = EngineSession.BlendChannelsSettings

    private func source(_ kind: EngineSession.ChannelKind = .red) -> Ref {
        Ref(image: 7, layer: 3, kind: kind, item: 9, invert: true)
    }

    private func validImageSettings() -> ImageSettings {
        var value = ImageSettings()
        value.source = source()
        return value
    }

    private func validChannelsSettings() -> ChannelsSettings {
        var value = ChannelsSettings()
        value.first = source(.red)
        value.second = source(.green)
        value.destinationImage = 4
        return value
    }

    func testValidDefaults() {
        XCTAssertNil(validImageSettings().validationError)
        XCTAssertNil(validChannelsSettings().validationError)

        var channels = validChannelsSettings()
        channels.destination = .newImage
        channels.destinationImage = 0
        XCTAssertNil(channels.validationError, "New Document ignores the destination image")
    }

    func testOpacityBoundsAndFiniteness() {
        var value = validImageSettings()
        for accepted in [0.0001, 0.5, 1.0] {
            value.opacity = accepted
            XCTAssertNil(value.validationError, "opacity \(accepted) should be valid")
        }
        for rejected in [0.0, -0.1, 1.0001, .nan, .infinity, -.infinity] {
            value.opacity = rejected
            XCTAssertNotNil(value.validationError, "opacity \(rejected) should be refused")
        }
    }

    func testScaleBoundsAndFiniteness() {
        var value = validImageSettings()
        for accepted in [1.0, 1.5, 2.0] {
            value.scale = accepted
            XCTAssertNil(value.validationError, "scale \(accepted) should be valid")
        }
        for rejected in [0.999, 2.001, 0.0, -1.0, .nan, .infinity] {
            value.scale = rejected
            XCTAssertNotNil(value.validationError, "scale \(rejected) should be refused")
        }
    }

    func testOffsetBoundsAndFiniteness() {
        var value = validImageSettings()
        for accepted in [-1.0, 0.0, 1.0] {
            value.offset = accepted
            XCTAssertNil(value.validationError, "offset \(accepted) should be valid")
        }
        for rejected in [-1.001, 1.001, .nan, .infinity, -.infinity] {
            value.offset = rejected
            XCTAssertNotNil(value.validationError, "offset \(rejected) should be refused")
        }
    }

    func testNoneIsNeverASource() {
        var value = ImageSettings()
        XCTAssertNotNil(value.validationError, "the default NONE source cannot run")

        value.source = source(.none)
        XCTAssertNotNil(value.validationError)

        value.source = source(.composite)
        XCTAssertNil(value.validationError, "COMPOSITE is a valid Apply Image source")
    }

    func testCalculationsInputsAreSingleChannels() {
        var value = validChannelsSettings()

        value.first = source(.composite)
        XCTAssertNotNil(value.validationError, "COMPOSITE cannot be a Calculations input")

        value = validChannelsSettings()
        value.first = source(.none)
        XCTAssertNotNil(value.validationError, "NONE cannot be a Calculations input")

        value = validChannelsSettings()
        value.second = source(.composite)
        XCTAssertNotNil(value.validationError)

        value = validChannelsSettings()
        value.second = source(.gray)
        XCTAssertNil(value.validationError, "GRAY is a single channel")

        for kind: EngineSession.ChannelKind in [.red, .green, .blue, .alpha, .selection, .saved] {
            value.second = source(kind)
            XCTAssertNil(value.validationError, "\(kind.title) is a single channel")
        }
    }

    func testMaskIsOptional() {
        var value = validImageSettings()
        value.mask = .noMask
        XCTAssertNil(value.validationError)

        value.mask = Ref(image: 7, layer: 0, kind: .selection, invert: false)
        XCTAssertNil(value.validationError, "a selection mask is valid")

        value.mask = Ref(image: 7, layer: 2, kind: .composite, invert: true)
        XCTAssertNil(value.validationError, "COMPOSITE contributes its luma as a mask")

        var channels = validChannelsSettings()
        channels.mask = .noMask
        XCTAssertNil(channels.validationError)
    }

    func testDestinationNeedsADocumentUnlessItIsANewImage() {
        var value = validChannelsSettings()
        value.destinationImage = 0
        XCTAssertNotNil(value.validationError, "a new channel needs a destination document")

        value = validChannelsSettings()
        value.destination = .newSelection
        value.destinationImage = 0
        XCTAssertNotNil(value.validationError)

        value = validChannelsSettings()
        value.destination = .newSelection
        value.destinationImage = 4
        XCTAssertNil(value.validationError)
    }

    func testBlendModeTitlesAndValues() {
        XCTAssertEqual(EngineSession.BlendMode.allCases.map(\.title), [
            "Normal", "Multiply", "Screen", "Overlay", "Soft Light", "Hard Light",
            "Darken", "Lighten", "Difference", "Exclusion", "Add", "Subtract",
        ])
        XCTAssertEqual(EngineSession.BlendMode.normal.rawValue, 0)
        XCTAssertEqual(EngineSession.BlendMode.subtract.rawValue, 11)
    }

    func testApplyImageRawMapping() {
        var value = validImageSettings()
        value.mode = .softLight
        value.opacity = 0.25
        value.scale = 1.5
        value.offset = -0.5
        value.mask = Ref(image: 8, layer: 2, kind: .alpha, item: 6, invert: true)

        let raw = EngineSession.applyImageRaw(value)
        XCTAssertEqual(raw.struct_size, UInt32(MemoryLayout<GlimsApplyImageSettings>.size))
        XCTAssertEqual(raw.source.struct_size, UInt32(MemoryLayout<GlimsChannelRef>.size))
        XCTAssertEqual(raw.source.image, 7)
        XCTAssertEqual(raw.source.layer, 3)
        XCTAssertEqual(raw.source.channel, EngineSession.ChannelKind.red.rawValue)
        XCTAssertEqual(raw.source.item, 9)
        XCTAssertEqual(raw.source.invert, 1)
        XCTAssertEqual(raw.mode, EngineSession.BlendMode.softLight.rawValue)
        XCTAssertEqual(raw.opacity, 0.25)
        XCTAssertEqual(raw.scale, 1.5)
        XCTAssertEqual(raw.offset, -0.5)
        XCTAssertEqual(raw.mask.image, 8)
        XCTAssertEqual(raw.mask.layer, 2)
        XCTAssertEqual(raw.mask.channel, EngineSession.ChannelKind.alpha.rawValue)
        XCTAssertEqual(raw.mask.item, 6)
        XCTAssertEqual(raw.mask.invert, 1)
    }

    func testCalculationsRawMapping() {
        var value = validChannelsSettings()
        value.mode = .add
        value.opacity = 0.75
        value.scale = 1.25
        value.offset = 0.5
        value.destination = .newChannel("Alpha 1")
        value.destinationImage = 11

        "Alpha 1".withCString { pointer in
            let raw = EngineSession.calculationsRaw(value, channelName: pointer)
            XCTAssertEqual(raw.struct_size, UInt32(MemoryLayout<GlimsCalculationsSettings>.size))
            XCTAssertEqual(raw.first.image, 7)
            XCTAssertEqual(raw.first.layer, 3)
            XCTAssertEqual(raw.first.channel, EngineSession.ChannelKind.red.rawValue)
            XCTAssertEqual(raw.second.channel, EngineSession.ChannelKind.green.rawValue)
            XCTAssertEqual(raw.mode, EngineSession.BlendMode.add.rawValue)
            XCTAssertEqual(raw.opacity, 0.75)
            XCTAssertEqual(raw.scale, 1.25)
            XCTAssertEqual(raw.offset, 0.5)
            XCTAssertEqual(raw.destination,
                           UInt32(GLIMS_CALCULATIONS_NEW_CHANNEL.rawValue))
            XCTAssertEqual(raw.destination_image, 11)
            XCTAssertEqual(String(cString: raw.channel_name!), "Alpha 1")
        }
    }

    func testDocumentSupportRefusalWording() {
        let command = EngineSession.BlendCommand.withImage
        XCTAssertEqual(EngineSession.blendDocumentRefusal(command, layout: .ordinary, mode: .rgb), nil)
        XCTAssertEqual(EngineSession.blendDocumentRefusal(command, layout: .legacyUnknown, mode: .grayscale), nil)
        XCTAssertEqual(EngineSession.blendDocumentRefusal(command, layout: .ordinary, mode: .indexed),
                       "Blend With Image is unavailable for indexed images.")
        XCTAssertEqual(EngineSession.blendDocumentRefusal(command, layout: .ordinary, mode: .lab),
                       "Blend With Image is not available for component documents.")
        XCTAssertEqual(EngineSession.blendDocumentRefusal(command, layout: .flatComponent, mode: .cmyk),
                       "Blend With Image is available for ordinary layered images only.")

        let channels = EngineSession.BlendCommand.channels
        XCTAssertEqual(EngineSession.blendDocumentRefusal(channels, layout: .ordinary, mode: .multichannel),
                       "Blend Channels is not available for component documents.")
        XCTAssertEqual(EngineSession.blendDocumentRefusal(channels, layout: .ordinary, mode: .rgb), nil)
    }
}
