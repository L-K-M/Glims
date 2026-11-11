import XCTest
@testable import GlimsKit

final class RecorderFileBindingTests: XCTestCase {
    private let layer = "22222222-2222-2222-2222-222222222222"
    private let channel = "33333333-3333-3333-3333-333333333333"
    private let quick = "44444444-4444-4444-4444-444444444444"

    private func fixture(target: String? = nil, selectedChannel: String? = nil, quickEnabled: Bool = false, editingMask: Bool = true) -> String {
        let symbols = #"""
        {"id":"22222222-2222-2222-2222-222222222222","description":{"name":"Target","kind":"pixel","ancestors":[],"siblingIndex":0,"bounds":{"x":-4,"y":7,"width":41,"height":29}}},
        {"id":"33333333-3333-3333-3333-333333333333","description":{"name":"Saved alpha","kind":"channel","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}},
        {"id":"44444444-4444-4444-4444-444444444444","description":{"name":"Quick Mask","kind":"quickMask","ancestors":[],"siblingIndex":0,"bounds":{"x":0,"y":0,"width":41,"height":29}}}
        """#
        let primary = target ?? "{\"kind\":\"mask\",\"owner\":\"\(layer)\"}"
        let channels = selectedChannel.map { "[\"\($0)\"]" } ?? "[]"
        let quickSymbol = quickEnabled ? ",\"symbol\":\"\(quick)\"" : ""
        let context = "{\"layers\":[\"\(layer)\"],\"channels\":\(channels),\"target\":\(primary),\"masks\":[{\"owner\":\"\(layer)\",\"isPresent\":true,\"enabled\":false,\"editing\":\(editingMask),\"showing\":false}],\"quickMask\":{\"enabled\":\(quickEnabled),\"inverted\":true,\"color\":{\"space\":\"srgb\",\"red\":1,\"green\":0,\"blue\":0,\"alpha\":0.5}\(quickSymbol)}}"
        return #"{"format":"ch.lkmc.Glims.recording","version":1,"recordingID":"11111111-1111-1111-1111-111111111111","name":"Bound","origin":{"imageLabel":"A","initialWidth":41,"initialHeight":29},"symbols":["# + symbols + #"],"records":[{"ordinal":0,"outcome":"success","command":{"tag":"selectColor","point":{"x":0,"y":0},"options":{"operation":"replace","antialias":true,"feather":0,"cornerRadius":0,"threshold":0,"contiguous":true,"sampleMerged":false}},"binding":{"kind":"context","context":"# + context + "}}]}"
    }
    private func decode(_ text: String) throws -> RecorderFileValue { try RecorderFileCodec.decode(Data(text.utf8)) }
    private func replace(_ text: String, _ old: String, _ new: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let range = text.range(of: old) else { XCTFail("Fixture mutation did not match", file: file, line: line); return text }
        return text.replacingCharacters(in: range, with: new)
    }

    func testIndependentMaskContextKeepsOwnerFlagsOrderAndColor() throws {
        let file = try decode(fixture())
        guard case .success(_, .context(let context)) = file.records[0].outcome else { return XCTFail("Missing literal mask context") }
        let symbol = UUID(uuidString: layer)!
        XCTAssertEqual(context.layers, [symbol]); XCTAssertEqual(context.channels, [])
        XCTAssertEqual(context.target, .mask(owner: symbol))
        XCTAssertEqual(context.masks, [.init(owner: symbol, isPresent: true, enabled: false, editing: true, showing: false)])
        XCTAssertFalse(context.quickMask.enabled); XCTAssertNil(context.quickMask.symbol); XCTAssertTrue(context.quickMask.inverted)
        XCTAssertEqual([context.quickMask.color.red, context.quickMask.color.green, context.quickMask.color.blue, context.quickMask.color.alpha], [1, 0, 0, 0.5])
    }

    func testIndependentSavedChannelAndQuickMaskRolesRemainDistinct() throws {
        for (name, enabled) in [(channel, false), (quick, true)] {
            let kind = enabled ? "quickMask" : "channel"
            let value = try decode(fixture(target: "{\"kind\":\"\(kind)\",\"symbol\":\"\(name)\"}", selectedChannel: name, quickEnabled: enabled, editingMask: false))
            guard case .success(_, .context(let context)) = value.records[0].outcome else { return XCTFail("Missing channel context") }
            let symbol = UUID(uuidString: name)!
            XCTAssertEqual(context.channels, [symbol])
            XCTAssertEqual(context.target, enabled ? .quickMask(symbol) : .channel(symbol))
            XCTAssertEqual(context.quickMask.symbol, enabled ? symbol : nil)
        }
    }

    func testUnknownContextFieldsAtEveryNestedObjectReject() {
        let mutations = [
            (#""layers":["#, #""future":0,"layers":["#),
            (#""target":{"kind""#, #""target":{"future":0,"kind""#),
            (#""masks":[{"owner""#, #""masks":[{"future":0,"owner""#),
            (#""quickMask":{"enabled""#, #""quickMask":{"future":0,"enabled""#),
            (#""color":{"space""#, #""color":{"future":0,"space""#),
        ]
        for (old, new) in mutations { XCTAssertThrowsError(try decode(replace(fixture(), old, new)), old) }
    }

    func testInconsistentMissingDuplicatedOrFutureRolesReject() {
        let original = fixture()
        let mutations = [
            (#""editing":true"#, #""editing":false"#),
            (#""isPresent":true"#, #""isPresent":false"#),
            (#""kind":"mask""#, #""kind":"futureRole""#),
            (#""enabled":false,"inverted""#, #""enabled":true,"inverted""#),
            (#""sampleMerged":false"#, #""sampleMerged":true"#),
            (#""owner":"22222222-2222-2222-2222-222222222222""#, #""owner":"33333333-3333-3333-3333-333333333333""#),
            (#""masks":[{"owner":"22222222-2222-2222-2222-222222222222""#, #""masks":[{"owner":"33333333-3333-3333-3333-333333333333""#),
            (#""layers":["22222222-2222-2222-2222-222222222222"]"#, #""layers":["22222222-2222-2222-2222-222222222222","22222222-2222-2222-2222-222222222222"]"#),
        ]
        for (old, new) in mutations { XCTAssertThrowsError(try decode(replace(original, old, new)), old) }
        let layerTarget = "{\"kind\":\"layer\",\"symbol\":\"\(layer)\"}"
        XCTAssertThrowsError(try decode(fixture(target: layerTarget)))
        XCTAssertNoThrow(try decode(fixture(target: layerTarget, editingMask: false)))
        let quickTarget = "{\"kind\":\"quickMask\",\"symbol\":\"\(quick)\"}"
        XCTAssertThrowsError(try decode(fixture(target: quickTarget, selectedChannel: quick, quickEnabled: false, editingMask: false)))
    }

    func testSelectAlphaUsesTheSameOwnedContextAndNoNumericEnums() throws {
        let text = replace(fixture(), #""tag":"selectColor","point":{"x":0,"y":0},"options":{"operation":"replace","antialias":true,"feather":0,"cornerRadius":0,"threshold":0,"contiguous":true,"sampleMerged":false}"#,
                           #""tag":"selectCommand","command":"fromAlpha","radius":0"#)
        let file = try decode(text)
        guard case .success(.selectCommand(.fromAlpha, radius: 0), .context) = file.records[0].outcome else { return XCTFail("Select Alpha binding lost") }
        XCTAssertThrowsError(try decode(replace(text, #""command":"fromAlpha""#, #""command":9"#)))
    }
}
