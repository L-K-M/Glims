import XCTest
@testable import GlimsKit

@MainActor
final class LabDocumentPolicyTests: XCTestCase {
    private let axis = EngineSession.LabAxis(id: 42, role: .a, isSelected: true,
                                            uuid: UUID(), name: "Custom name")

    func testLabIsSeparateFromInkAndOrdinaryToolTargets() {
        XCTAssertFalse(EngineSession.ColorMode.lab.usesInkChannels)
        XCTAssertTrue(EngineSession.ColorMode.lab.usesNativeChannels)
        XCTAssertEqual(ToolID.allCases.filter { $0.isAvailable(in: .lab) }, [.hand, .zoom])
        XCTAssertTrue(ToolID.paintbrush.isAvailable(in: .cmyk))
        XCTAssertTrue(ToolID.text.isAvailable(in: .rgb))
    }

    func testOnlyTypedLabSelectionCanLeaveTheChannelsPalette() {
        XCTAssertTrue(ChannelMenuPolicy.permits(.selectLabAxis(axis), multichannel: false, lab: true))
        for action in [ChannelsPaletteView.Action.selectChannel(42), .setChannelVisible(42, false),
                       .editChannel(42), .newChannel, .duplicateChannel(42), .deleteChannel(42),
                       .channelToSelection(42, .replace), .setQuickMask(true), .returnToLayers,
                       .setComponentActive(.red, true), .setComponentVisible(.gray, false)] {
            XCTAssertFalse(ChannelMenuPolicy.permits(action, multichannel: false, lab: true))
        }
        XCTAssertFalse(ChannelMenuPolicy.permits(.selectLabAxis(axis), multichannel: false))
        XCTAssertFalse(ChannelMenuPolicy.permits(.selectLabAxis(axis), multichannel: true))
    }

    func testLabLabelsDescribePhysicalStorageWithoutCarrierGrayTransferCurve() {
        let float = EngineSession.ColorInfo(mode: .lab, component: .float, trc: .unknown,
                                           profileLabel: "D50 Lab", hasEmbeddedProfile: false)
        XCTAssertTrue(ColorForms.precisionLabel(float).contains("Physical Lab"))
        let rows = ColorForms.informationRows(colorInfo: float)
        XCTAssertEqual(rows.first { $0.label == "White point" }?.value, "D50")
        XCTAssertFalse(rows.contains { $0.label == "Profile source" })
        XCTAssertTrue(ColorForms.precisionIsFixed(mode: .lab))
        XCTAssertFalse(ProfileForm.convertAllowed(mode: .lab))
        XCTAssertFalse(AdjustmentLayerLogic.modeAdmission(.lab).allowed)
    }
}
