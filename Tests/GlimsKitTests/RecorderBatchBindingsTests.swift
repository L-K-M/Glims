import XCTest
@testable import GlimsKit

final class RecorderBatchBindingsTests: XCTestCase {
    typealias Matcher = RecorderBatchBindings
    private let first = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let second = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    private func description(_ name: String = "Subject", kind: RecorderTargetDescription.Kind = .pixel,
                             parent: String? = nil, index: Int = 0, size: Double = 40) -> RecorderTargetDescription {
        .init(name: name, kind: kind, ancestors: parent.map {
            [.init(name: $0, kind: .group, siblingIndex: index)]
        } ?? [], siblingIndex: index, bounds: .init(x: 0, y: 0, width: size, height: size))
    }

    private func file(_ bindings: [RecorderBindingDescription],
                      symbols: [RecorderFileValue.Symbol]? = nil) -> RecorderFileValue {
        let records = bindings.enumerated().map { index, binding -> RecorderFileValue.Record in
            let command: RecorderFileCommand
            switch binding {
            case .layer: command = .layerProperties(.init(name: nil, visible: nil, opacity: 0.5, mode: nil))
            case .channel: command = .channelToSelection(.replace)
            case .context: command = .selectColor(.init(x: 1, y: 2), .init(operation: .replace,
                antialias: true, feather: 0, cornerRadius: 0, threshold: 0.1, contiguous: true, sampleMerged: false))
            default: command = .scale(width: 20, height: 30)
            }
            return .init(ordinal: index, outcome: .success(command, binding))
        }
        return .init(recordingID: UUID(), name: "Batch", origin: .init(imageLabel: "Source", initialWidth: 40, initialHeight: 40),
                     symbols: symbols ?? [.init(id: first, description: description())], records: records)
    }

    private func candidate(_ id: Int32, _ name: String = "Subject", parent: String? = nil,
                           index: Int = 9, size: Double = 800, hasMask: Bool = false) -> Matcher.Candidate {
        .init(choice: .layer(id), description: description(name, parent: parent, index: index, size: size), hasMask: hasMask)
    }

    func testTargetIndependentRecordingNeedsNoMatching() throws {
        XCTAssertEqual(try Matcher.resolve(file: file([.none]), candidates: [], policy: .requireNoTargets), [:])
        XCTAssertThrowsError(try Matcher.resolve(file: file([.layer(first)]), candidates: [candidate(70)], policy: .requireNoTargets)) {
            XCTAssertEqual($0 as? Matcher.MatchError, .matchingRequired)
        }
    }

    func testNamesMatchWithoutGuessingFromBoundsOrIndices() throws {
        let result = try Matcher.resolve(file: file([.layer(first)]), candidates: [candidate(70)], policy: .matchingNamesAndKinds)
        XCTAssertEqual(result, [first: .layer(70)])
        for name in ["subject", "Subject ", "Other"] {
            XCTAssertThrowsError(try Matcher.resolve(file: file([.layer(first)]), candidates: [candidate(70, name)], policy: .matchingNamesAndKinds)) {
                XCTAssertEqual($0 as? Matcher.MatchError, .missing("Subject"))
            }
        }
    }

    func testHierarchyDisambiguatesButNeverUsesSiblingOrdinals() throws {
        let source = file([.layer(first)], symbols: [.init(id: first, description: description(parent: "Foreground"))])
        let candidates = [candidate(70, parent: "Background"), candidate(80, parent: "Foreground")]
        XCTAssertEqual(try Matcher.resolve(file: source, candidates: candidates, policy: .matchingPathsAndKinds), [first: .layer(80)])
        XCTAssertThrowsError(try Matcher.resolve(file: source, candidates: candidates, policy: .matchingNamesAndKinds)) {
            XCTAssertEqual($0 as? Matcher.MatchError, .ambiguous("Subject"))
        }
        XCTAssertThrowsError(try Matcher.resolve(file: source,
            candidates: [candidate(70, parent: "Foreground", index: 0), candidate(80, parent: "Foreground", index: 8)],
            policy: .matchingPathsAndKinds)) {
            XCTAssertEqual($0 as? Matcher.MatchError, .ambiguous("Subject"))
        }
    }

    func testMissingAndInvalidRuntimeRolesRefuse() {
        let source = file([.layer(first)])
        for candidates in [[], [candidate(0)], [candidate(-1)],
                           [Matcher.Candidate(choice: .channel(70), description: description(), hasMask: false)],
                           [Matcher.Candidate(choice: .layer(70), description: description(kind: .group), hasMask: false)]] {
            XCTAssertThrowsError(try Matcher.resolve(file: source, candidates: candidates, policy: .matchingNamesAndKinds)) {
                XCTAssertEqual($0 as? Matcher.MatchError, .missing("Subject"))
            }
        }
    }

    func testTwoSymbolsCannotAliasOneRuntimeLayer() {
        let source = file([.layer(first), .layer(second)], symbols: [
            .init(id: first, description: description()), .init(id: second, description: description())])
        XCTAssertThrowsError(try Matcher.resolve(file: source, candidates: [candidate(70)], policy: .matchingNamesAndKinds)) {
            XCTAssertEqual($0 as? Matcher.MatchError, .duplicateTarget("Subject"))
        }
    }

    func testUnreferencedSymbolsDoNotRequireCandidates() throws {
        let source = file([.layer(first)], symbols: [.init(id: first, description: description()),
            .init(id: second, description: description("Unused"))])
        XCTAssertEqual(try Matcher.resolve(file: source, candidates: [candidate(70)], policy: .matchingNamesAndKinds), [first: .layer(70)])
    }

    func testMaskContextRequiresTheMatchedLayerToHaveAMask() throws {
        let context = RecorderBindingDescription.Context(layers: [first], channels: [], target: .mask(owner: first),
            masks: [.init(owner: first, isPresent: true, enabled: true, editing: true, showing: false)],
            quickMask: .init(enabled: false, symbol: nil, inverted: false,
                             color: try .init(red: 1, green: 0, blue: 0, alpha: 0.5)))
        let source = file([.context(context)])
        XCTAssertThrowsError(try Matcher.resolve(file: source, candidates: [candidate(70)], policy: .matchingNamesAndKinds))
        XCTAssertEqual(try Matcher.resolve(file: source, candidates: [candidate(70, hasMask: true)], policy: .matchingNamesAndKinds), [first: .layer(70)])
    }

    func testSavedChannelAndQuickMaskStayDifferentRoles() throws {
        let channel = description("Alpha", kind: .channel)
        let source = file([.channel(first)], symbols: [.init(id: first, description: channel)])
        let valid = Matcher.Candidate(choice: .channel(70), description: channel, hasMask: false)
        XCTAssertEqual(try Matcher.resolve(file: source, candidates: [valid], policy: .matchingNamesAndKinds), [first: .channel(70)])
        let wrong = Matcher.Candidate(choice: .quickMask(70), description: channel, hasMask: false)
        XCTAssertThrowsError(try Matcher.resolve(file: source, candidates: [wrong], policy: .matchingNamesAndKinds))

        let quick = description("Quick Mask", kind: .quickMask)
        let context = RecorderBindingDescription.Context(layers: [], channels: [first], target: .quickMask(first), masks: [],
            quickMask: .init(enabled: true, symbol: first, inverted: false,
                             color: try .init(red: 1, green: 0, blue: 0, alpha: 0.5)))
        let quickSource = file([.context(context)], symbols: [.init(id: first, description: quick)])
        XCTAssertEqual(try Matcher.resolve(file: quickSource,
            candidates: [.init(choice: .quickMask(90), description: quick, hasMask: false)], policy: .matchingNamesAndKinds), [first: .quickMask(90)])
        XCTAssertThrowsError(try Matcher.resolve(file: quickSource,
            candidates: [.init(choice: .channel(90), description: quick, hasMask: false)], policy: .matchingNamesAndKinds))
    }

    func testIncompleteAndInvalidRecordingsRefuseBeforeMatching() {
        XCTAssertThrowsError(try Matcher.resolve(file: file([]), candidates: [], policy: .requireNoTargets)) {
            XCTAssertEqual($0 as? Matcher.MatchError, .emptyRecording)
        }
        for outcome in [RecorderFileValue.Outcome.failure("Failed"), .cancelled("Cancelled")] {
            let source = RecorderFileValue(recordingID: UUID(), name: "Incomplete",
                origin: .init(imageLabel: "Source", initialWidth: 40, initialHeight: 40), symbols: [],
                records: [.init(ordinal: 0, outcome: outcome)])
            XCTAssertThrowsError(try Matcher.resolve(file: source, candidates: [], policy: .requireNoTargets)) {
                XCTAssertEqual($0 as? Matcher.MatchError, .unsuccessfulCommand(1))
            }
        }
        XCTAssertThrowsError(try Matcher.resolve(file: file([.unavailable("Missing")]), candidates: [], policy: .matchingNamesAndKinds))
        XCTAssertThrowsError(try Matcher.resolve(file: file([.layer(second)]), candidates: [candidate(70)], policy: .matchingNamesAndKinds))
    }
}
