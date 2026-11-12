import AppKit
import XCTest
@testable import GlimsKit

/// The detached Batch candidate snapshot without an engine: layer kinds and
/// ancestry, mask flags, and channel versus Quick Mask identity all come from
/// the same recorded-target description helpers a capture would use, so a
/// symbol that was recorded against one image can match these candidates on
/// another.
final class RecorderBatchCandidatesTests: XCTestCase {
    private let info = EngineSession.ImageInfo(width: 800, height: 600, layerCount: 0,
                                               isDirty: false, precision: "8-bit")

    private func layer(_ id: Int32, parent: Int32 = 0, kind: EngineSession.LayerKind = .pixel,
                       name: String? = nil) -> EngineSession.Layer {
        EngineSession.Layer(id: id, parent: parent, depth: 0, kind: kind, name: name ?? "Layer \(id)",
                            mode: "normal", isVisible: true, hasMask: false, isSelected: false,
                            opacity: 1, bounds: CGRect(x: 0, y: 0, width: 40, height: 40), filterCount: 0)
    }

    private func channel(_ id: Int32, _ name: String, isQuickMask: Bool = false) -> EngineSession.Channel {
        EngineSession.Channel(id: id, name: name, isVisible: true, isSelected: false,
                              isQuickMask: isQuickMask, opacity: 1, color: .black)
    }

    private func quickMask(enabled: Bool, channel: Int32 = 50) -> EngineSession.QuickMaskState {
        EngineSession.QuickMaskState(enabled: enabled, channel: channel, inverted: false, color: .black)
    }

    private func candidates(layers: [EngineSession.Layer] = [], channels: [EngineSession.Channel] = [],
                            masks: [Int32: EngineSession.MaskState] = [:],
                            quickMask: EngineSession.QuickMaskState? = nil) throws -> [RecorderBatchBindings.Candidate] {
        try ImageDocument.recorderBatchCandidates(layers: layers, channels: channels, masks: masks,
                                                  quickMask: quickMask, info: info)
    }

    private func candidate(_ choice: ImageDocument.RecorderInstallChoice,
                           in candidates: [RecorderBatchBindings.Candidate]) -> RecorderBatchBindings.Candidate? {
        candidates.first { $0.choice == choice }
    }

    private func description(_ name: String = "Subject", kind: RecorderTargetDescription.Kind = .pixel,
                             ancestors: [RecorderTargetDescription.Ancestor] = [],
                             index: Int = 0, width: Double = 40, height: Double = 40) -> RecorderTargetDescription {
        .init(name: name, kind: kind, ancestors: ancestors, siblingIndex: index,
              bounds: .init(x: 0, y: 0, width: width, height: height))
    }

    private func ancestor(_ name: String, kind: RecorderTargetDescription.Kind = .group,
                          index: Int = 0) -> RecorderTargetDescription.Ancestor {
        .init(name: name, kind: kind, siblingIndex: index)
    }

    /// A file whose single record validates under the codec: command and
    /// binding kinds must agree, so each binding gets its own command.
    private func file(symbol: UUID, description: RecorderTargetDescription,
                      binding: RecorderBindingDescription) -> RecorderFileValue {
        let command: RecorderFileCommand
        switch binding {
        case .layer: command = .layerProperties(.init(name: nil, visible: nil, opacity: 0.5, mode: nil))
        case .channel: command = .channelToSelection(.replace)
        case .context: command = .selectColor(.init(x: 1, y: 2), .init(operation: .replace,
            antialias: true, feather: 0, cornerRadius: 0, threshold: 0.1, contiguous: true, sampleMerged: false))
        default: command = .scale(width: 20, height: 30)
        }
        return .init(recordingID: UUID(), name: "Batch",
                     origin: .init(imageLabel: "Source", initialWidth: 40, initialHeight: 40),
                     symbols: [.init(id: symbol, description: description)],
                     records: [.init(ordinal: 0, outcome: .success(command, binding))])
    }

    // MARK: Layers

    func testLayerCandidatesDescribeKindsAndNestedAncestry() throws {
        let layers = [layer(1, kind: .group, name: "Foreground"), layer(2, parent: 1, kind: .group, name: "Inner"),
                      layer(3, parent: 2, name: "Subject"), layer(5, parent: 2, name: "Sibling"),
                      layer(4, kind: .text, name: "Title")]
        let result = try candidates(layers: layers)
        XCTAssertEqual(result.count, 5)
        XCTAssertEqual(Set(result.map(\.choice)), [.layer(1), .layer(2), .layer(3), .layer(5), .layer(4)])

        let subject = try XCTUnwrap(candidate(.layer(3), in: result))
        XCTAssertEqual(subject.description, description("Subject",
            ancestors: [ancestor("Foreground"), ancestor("Inner")]))
        XCTAssertFalse(subject.hasMask)

        let sibling = try XCTUnwrap(candidate(.layer(5), in: result))
        XCTAssertEqual(sibling.description, description("Sibling",
            ancestors: [ancestor("Foreground"), ancestor("Inner")], index: 1))

        let title = try XCTUnwrap(candidate(.layer(4), in: result))
        XCTAssertEqual(title.description.kind, .text)
        XCTAssertEqual(title.description.ancestors, [])
    }

    func testSiblingIndexReflectsOnlySameParentRows() throws {
        let layers = [layer(1, kind: .group, name: "Foreground"), layer(2, parent: 1, kind: .group, name: "Inner"),
                      layer(3, parent: 2, name: "Subject"), layer(5, parent: 2, name: "Sibling"),
                      layer(4, name: "Background")]
        let result = try candidates(layers: layers)
        XCTAssertEqual(result.map(\.description.siblingIndex), [0, 0, 0, 1, 1])
        XCTAssertEqual(candidate(.layer(3), in: result)?.description.ancestors.map(\.siblingIndex), [0, 0])
    }

    func testEveryLayerKindProducesACandidate() throws {
        let layers = [layer(1, kind: .pixel), layer(2, kind: .group), layer(3, kind: .text),
                      layer(4, kind: .link), layer(5, kind: .vector)]
        let result = try candidates(layers: layers)
        XCTAssertEqual(result.map(\.description.kind), [.pixel, .group, .text, .link, .vector])
        XCTAssertEqual(result.map(\.choice), [.layer(1), .layer(2), .layer(3), .layer(4), .layer(5)])
    }

    func testMaskFlagFollowsTheCachedMaskState() throws {
        let layers = [layer(1, name: "Masked"), layer(2, name: "Empty"), layer(3, name: "Bare")]
        let masks: [Int32: EngineSession.MaskState] = [
            1: .init(mask: 42, enabled: true, editing: false, showing: false),
            2: .init(mask: 0, enabled: false, editing: false, showing: false)]
        let result = try candidates(layers: layers, masks: masks)
        XCTAssertEqual(candidate(.layer(1), in: result)?.hasMask, true)
        XCTAssertEqual(candidate(.layer(2), in: result)?.hasMask, false)
        XCTAssertEqual(candidate(.layer(3), in: result)?.hasMask, false)
    }

    func testBrokenAncestryRefusesTheSnapshot() {
        XCTAssertThrowsError(try candidates(layers: [layer(1, parent: 9)]))
        XCTAssertThrowsError(try candidates(layers: [layer(1, parent: 2), layer(2, parent: 1)]))
    }

    // MARK: Channels and Quick Mask

    func testOrdinaryChannelsBecomeChannelCandidates() throws {
        let result = try candidates(channels: [channel(10, "Alpha"), channel(11, "Beta")])
        XCTAssertEqual(result.map(\.choice), [.channel(10), .channel(11)])
        XCTAssertEqual(result.map(\.description.kind), [.channel, .channel])
        XCTAssertEqual(result.map(\.description.name), ["Alpha", "Beta"])
        XCTAssertEqual(result.map(\.description.siblingIndex), [0, 1])
        XCTAssertEqual(result.map(\.description.bounds.width), [800, 800])
        XCTAssertTrue(result.allSatisfy { !$0.hasMask && $0.description.ancestors.isEmpty })
    }

    func testEnabledQuickMaskIsItsOwnCandidateNeverAnOrdinaryChannel() throws {
        let channels = [channel(10, "Alpha"), channel(50, "Quick Mask", isQuickMask: true), channel(11, "Beta")]
        let result = try candidates(channels: channels, quickMask: quickMask(enabled: true))
        XCTAssertEqual(result.map(\.choice), [.channel(10), .channel(11), .quickMask(50)])
        let quick = try XCTUnwrap(candidate(.quickMask(50), in: result))
        XCTAssertEqual(quick.description, description("Quick Mask", kind: .quickMask,
                                                      width: 800, height: 600))
        XCTAssertFalse(quick.hasMask)
        // The Quick Mask row still counts in an ordinary channel's index,
        // matching the recorded channel descriptions.
        XCTAssertEqual(candidate(.channel(11), in: result)?.description.siblingIndex, 2)
        XCTAssertNil(candidate(.channel(50), in: result))
        XCTAssertEqual(result.filter { $0.description.name == "Quick Mask" }.count, 1)
    }

    func testQuickMaskCandidateFallsBackToItsRecordedName() throws {
        // An enabled Quick Mask whose row is absent still snapshots under the
        // recorded fallback name, as the capture-time description would.
        let result = try candidates(channels: [channel(10, "Alpha")], quickMask: quickMask(enabled: true))
        XCTAssertEqual(result.map(\.choice), [.channel(10), .quickMask(50)])
        XCTAssertEqual(candidate(.quickMask(50), in: result)?.description.name, "Quick Mask")
    }

    func testQuickMaskChannelIdIsNeverDuplicatedAsOrdinary() throws {
        // An inconsistent list that carries the live Quick Mask's id on an
        // unflagged row still yields one identity, the Quick Mask's.
        let channels = [channel(10, "Alpha"), channel(50, "QMask Row")]
        let result = try candidates(channels: channels, quickMask: quickMask(enabled: true))
        XCTAssertEqual(result.map(\.choice), [.channel(10), .quickMask(50)])
        XCTAssertEqual(candidate(.quickMask(50), in: result)?.description.name, "QMask Row")
    }

    func testDisabledAbsentOrInvalidQuickMaskProducesNoCandidate() throws {
        let states: [EngineSession.QuickMaskState?] = [nil, quickMask(enabled: false),
            quickMask(enabled: false, channel: 0), quickMask(enabled: true, channel: 0)]
        for state in states {
            let result = try candidates(channels: [channel(10, "Alpha")], quickMask: state)
            XCTAssertEqual(result.map(\.choice), [.channel(10)])
        }
        // A leftover Quick Mask row while the state is disabled is no target.
        let stale = try candidates(channels: [channel(50, "Quick Mask", isQuickMask: true)],
                                   quickMask: quickMask(enabled: false))
        XCTAssertTrue(stale.isEmpty)
    }

    func testEmptyImageProducesNoCandidates() throws {
        XCTAssertTrue(try candidates().isEmpty)
    }

    // MARK: Matcher round trip

    func testCandidatesResolveRecordedSymbols() throws {
        let symbol = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let layers = [layer(1, kind: .group, name: "Background"), layer(2, kind: .group, name: "Foreground"),
                      layer(3, parent: 1, name: "Subject"), layer(4, parent: 2, name: "Subject")]
        let result = try candidates(layers: layers)
        let nested = description("Subject", ancestors: [ancestor("Foreground")])
        XCTAssertEqual(try RecorderBatchBindings.resolve(file: file(symbol: symbol, description: nested,
            binding: .layer(symbol)), candidates: result, policy: .matchingPathsAndKinds), [symbol: .layer(4)])
        XCTAssertThrowsError(try RecorderBatchBindings.resolve(file: file(symbol: symbol, description: nested,
            binding: .layer(symbol)), candidates: result, policy: .matchingNamesAndKinds)) {
            XCTAssertEqual($0 as? RecorderBatchBindings.MatchError, .ambiguous("Subject"))
        }
    }

    func testMaskOwnerRequiresTheMatchedLayerToHaveAMask() throws {
        let symbol = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let context = RecorderBindingDescription.Context(layers: [symbol], channels: [], target: .mask(owner: symbol),
            masks: [.init(owner: symbol, isPresent: true, enabled: true, editing: true, showing: false)],
            quickMask: .init(enabled: false, symbol: nil, inverted: false,
                             color: try .init(red: 1, green: 0, blue: 0, alpha: 0.5)))
        let source = file(symbol: symbol, description: description(), binding: .context(context))
        let layers = [layer(3, name: "Subject"), layer(4, name: "Subject")]
        let masks: [Int32: EngineSession.MaskState] = [4: .init(mask: 9, enabled: true, editing: false, showing: false)]
        let result = try candidates(layers: layers, masks: masks)
        XCTAssertEqual(try RecorderBatchBindings.resolve(file: source, candidates: result,
            policy: .matchingNamesAndKinds), [symbol: .layer(4)])
        let bare = try candidates(layers: [layer(3, name: "Subject")])
        XCTAssertThrowsError(try RecorderBatchBindings.resolve(file: source, candidates: bare,
            policy: .matchingNamesAndKinds)) {
            XCTAssertEqual($0 as? RecorderBatchBindings.MatchError, .missing("Subject"))
        }
    }

    func testChannelAndQuickMaskCandidatesResolveByRole() throws {
        let symbol = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let channels = [channel(10, "Alpha"), channel(50, "Quick Mask", isQuickMask: true)]
        let result = try candidates(channels: channels, quickMask: quickMask(enabled: true))
        let channelSource = file(symbol: symbol, description: description("Alpha", kind: .channel),
                                 binding: .channel(symbol))
        XCTAssertEqual(try RecorderBatchBindings.resolve(file: channelSource, candidates: result,
            policy: .matchingNamesAndKinds), [symbol: .channel(10)])

        let quickMaskSource = file(symbol: symbol, description: description("Quick Mask", kind: .quickMask),
                                   binding: .context(.init(layers: [], channels: [symbol], target: .quickMask(symbol),
                                        masks: [], quickMask: .init(enabled: true, symbol: symbol, inverted: false,
                                            color: try .init(red: 1, green: 0, blue: 0, alpha: 0.5)))))
        XCTAssertEqual(try RecorderBatchBindings.resolve(file: quickMaskSource, candidates: result,
            policy: .matchingNamesAndKinds), [symbol: .quickMask(50)])
    }
}
