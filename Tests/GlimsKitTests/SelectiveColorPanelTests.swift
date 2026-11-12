import AppKit
import XCTest
@testable import GlimsKit

/// The compact selective-color form's property contract and routing:
/// the nine-range CMYK name grid, the `relative` method flag, percent
/// display over native -1...1 values and menu/layer admission.
@MainActor
final class SelectiveColorPanelTests: XCTestCase {
    private typealias Range = SelectiveColorPanel.ColorRange
    private typealias Channel = SelectiveColorPanel.Channel

    private func operation(_ name: String, title: String = "Selective Color",
                           support: EngineSession.FilterOpSupport = .supported) -> EngineSession.FilterOperation {
        EngineSession.FilterOperation(name: name, title: title, categories: ["color"], blurb: "", support: support)
    }

    private func channelProperty(_ name: String) -> EngineSession.FilterProperty {
        EngineSession.FilterProperty(name: name, label: name, blurb: "", unit: "", kind: .number,
                                     minimum: -1, maximum: 1, uiMinimum: -1, uiMaximum: 1,
                                     uiStepSmall: 0, uiStepBig: 0, uiGamma: 1, uiDigits: -1,
                                     defaultNumber: 0, defaultBool: false, defaultString: "",
                                     defaultColor: .black, choiceCount: 0)
    }

    private var contractProperties: [EngineSession.FilterProperty] {
        Range.allCases.flatMap { range in
            Channel.allCases.map { channelProperty(SelectiveColorPanel.propertyName(range, $0)) }
        } + [EngineSession.FilterProperty(name: "relative", label: "Relative", blurb: "", unit: "",
                                          kind: .boolean, minimum: 0, maximum: 1, uiMinimum: 0, uiMaximum: 1,
                                          uiStepSmall: 0, uiStepBig: 0, uiGamma: 1, uiDigits: -1,
                                          defaultNumber: 0, defaultBool: true, defaultString: "",
                                          defaultColor: .black, choiceCount: 0)]
    }

    func testPropertyGridCoversNineRangesOfFourChannels() {
        XCTAssertEqual(Range.allCases.count, 9)
        XCTAssertEqual(Channel.allCases.map(\.rawValue), ["cyan", "magenta", "yellow", "black"])
        XCTAssertEqual(Range.allCases.map(\.rawValue),
                       ["red", "yellow", "green", "cyan", "blue", "magenta", "white", "neutral", "black"])
        XCTAssertEqual(SelectiveColorPanel.propertyName(.neutral, .yellow), "neutral-yellow")
        XCTAssertEqual(SelectiveColorPanel.propertyName(.black, .black), "black-black")
        XCTAssertEqual(Range.allCases.map(\.title),
                       ["Reds", "Yellows", "Greens", "Cyans", "Blues", "Magentas", "Whites", "Neutrals", "Blacks"])
        let names = Set(Range.allCases.flatMap { range in
            Channel.allCases.map { SelectiveColorPanel.propertyName(range, $0) }
        })
        XCTAssertEqual(names.count, 36, "every range/channel pair is an independent property")
    }

    func testContractMatchesExactlyTheOwnedThirtySevenProperties() {
        XCTAssertTrue(SelectiveColorPanel.matches(contractProperties))

        var duplicated = contractProperties
        duplicated.append(contractProperties[0])
        XCTAssertFalse(SelectiveColorPanel.matches(duplicated), "duplicate keys must not reach dictionary construction")

        var dropped = contractProperties
        dropped.removeAll { $0.name == "neutral-cyan" }
        XCTAssertFalse(SelectiveColorPanel.matches(dropped), "a missing channel falls back")

        var grown = contractProperties
        grown.append(channelProperty("extra-slider"))
        XCTAssertFalse(SelectiveColorPanel.matches(grown), "an unlisted property falls back")

        var mistyped = contractProperties
        mistyped[0] = EngineSession.FilterProperty(name: mistyped[0].name, label: "", blurb: "", unit: "",
                                                   kind: .enumeration, minimum: 0, maximum: 1,
                                                   uiMinimum: 0, uiMaximum: 1, uiStepSmall: 0, uiStepBig: 0,
                                                   uiGamma: 1, uiDigits: -1, defaultNumber: 0,
                                                   defaultBool: false, defaultString: "", defaultColor: .black,
                                                   choiceCount: 0)
        XCTAssertFalse(SelectiveColorPanel.matches(mistyped), "a non-number channel falls back")
    }

    func testUsesSelectiveColorEditorOnlyForOwnedSupportedOperation() {
        let exact = operation("glims:selective-color")
        XCTAssertTrue(NativeFilterMenuLayout.usesSelectiveColorEditor(exact))
        XCTAssertTrue(NativeFilterMenuLayout.supportsParameterEditor(exact))
        XCTAssertEqual(NativeFilterMenuLayout.itemTitle(exact), "Selective Color…")

        let configured = operation("glims:selective-color", support: .needsConfig)
        XCTAssertFalse(NativeFilterMenuLayout.usesSelectiveColorEditor(configured),
                       "a config-reported variant must not hijack the dedicated layout")
        let auxiliary = operation("glims:selective-color", support: .needsAuxInput)
        XCTAssertFalse(NativeFilterMenuLayout.usesSelectiveColorEditor(auxiliary))

        for name in ["gegl:selective-color", "gimp:selective-color", "glims:selective-color-legacy"] {
            XCTAssertFalse(NativeFilterMenuLayout.usesSelectiveColorEditor(operation(name)),
                           "\(name) is not the owned operation")
        }
    }

    /// Percent display over the native fraction: the row shows -100...100
    /// while `show`/`onChange` carry the -1...1 engine value.
    func testPercentRowConvertsBetweenDisplayAndNative() {
        let row = FilterNumberRow(property: channelProperty("red-cyan"), displayScale: 100, unitLabel: "%")
        var reported: Double?
        row.onChange = { reported = $0 }

        row.show(0.25)
        XCTAssertEqual(row.field.stringValue, "25", "the native fraction displays as a percentage")
        XCTAssertEqual(row.value, 0.25, accuracy: 0.0001)

        row.field.stringValue = "-30"
        XCTAssertTrue(row.commitField())
        XCTAssertEqual(reported ?? 0, -0.3, accuracy: 0.0001,
                       "typed percentages write the native value")
        row.show(-0.3)
        XCTAssertEqual(row.field.stringValue, "-30")

        row.field.stringValue = "150"
        XCTAssertTrue(row.commitField())
        XCTAssertEqual(reported ?? 0, 1, accuracy: 0.0001,
                       "typed percentages clamp to the native absolute bounds")
        XCTAssertEqual(row.field.stringValue, "100")
    }

    func testUneditedRoundedPercentDoesNotRewriteStoredValue() {
        let row = FilterNumberRow(property: channelProperty("red-cyan"), displayScale: 100, unitLabel: "%")
        var writes: [Double] = []
        row.onChange = { writes.append($0) }
        row.show(0.123456)
        XCTAssertEqual(row.field.stringValue, "12.3")
        XCTAssertTrue(row.commitField())
        XCTAssertEqual(row.value, 0.123456)
        XCTAssertTrue(writes.isEmpty, "display rounding is not a user edit")
        row.field.stringValue = "-30.1"
        XCTAssertTrue(row.commitField())
        XCTAssertEqual(row.value, -0.301, accuracy: 1e-12)
        XCTAssertTrue(row.commitField())
        XCTAssertEqual(row.value, -0.301, accuracy: 1e-12)
        XCTAssertEqual(writes.count, 1, "Return followed by focus loss commits once")
    }

    func testExplicitlyTypingRoundedPercentCommitsTheTypedValue() {
        let row = FilterNumberRow(property: channelProperty("red-cyan"), displayScale: 100, unitLabel: "%")
        var writes: [Double] = []
        row.onChange = { writes.append($0) }
        row.show(0.123456)
        row.field.stringValue = "12.3"
        row.field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: row.field))
        // A peer acknowledgement may refresh the accepted value while
        // the surrounding panel preserves this field's edited draft.
        row.show(0.123456)
        XCTAssertTrue(row.commitField())
        XCTAssertEqual(row.value, 0.123, accuracy: 1e-12)
        XCTAssertEqual(writes.count, 1, "explicit input is different from simply focusing a rounded display")
        XCTAssertTrue(row.commitField())
        XCTAssertEqual(writes.count, 1)
    }

    /// The Adjust menu's dedicated entry and the New Adjustment Layer
    /// known set both route the owned operation id.
    func testMenuAndAdjustmentLayerAdmission() {
        let catalog = [
            operation("gimp:hue-saturation", title: "Hue-Saturation", support: .needsConfig),
            operation("glims:selective-color"),
            operation("gegl:exposure", title: "Exposure"),
        ]
        let menu = NSMenu(title: "Image")
        let adjust = NSMenuItem(title: MainMenu.adjustTitle, action: nil, keyEquivalent: "")
        adjust.submenu = NSMenu(title: MainMenu.adjustTitle)
        menu.addItem(adjust)
        let imageMenu = NSMenu(title: "Root")
        imageMenu.addItem(NSMenuItem(title: "Image", action: nil, keyEquivalent: ""))
        imageMenu.item(withTitle: "Image")?.submenu = menu
        NativeFilterMenus.install(catalog, in: imageMenu)

        guard let item = adjust.submenu?.item(withTitle: "Selective Color…"),
              let command = item.representedObject as? NativeFilterCommand else {
            return XCTFail("the Adjust submenu lists Selective Color once the catalog offers it")
        }
        XCTAssertEqual(command.operation.name, "glims:selective-color")
        XCTAssertTrue(item.action == #selector(DocumentWindowController.runNativeFilter(_:)))

        XCTAssertEqual(AdjustmentLayerLogic.availableOperations(in: catalog).map(\.name),
                       ["gimp:hue-saturation", "glims:selective-color", "gegl:exposure"],
                       "the known adjustment set offers the owned operation in display order")
    }
}
