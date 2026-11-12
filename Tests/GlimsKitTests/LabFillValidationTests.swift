import XCTest
@testable import GlimsKit

final class LabFillValidationTests: XCTestCase {
    private func rejected(_ amount: String, opacity: String = "100",
                          role: EngineSession.LabAxisRole = .lightness,
                          component: EngineSession.ColorComponent = .u8,
                          file: StaticString = #filePath, line: UInt = #line) {
        switch LabFillValidation.settings(amount: amount, opacity: opacity,
                                         role: role, component: component) {
        case .success(let settings):
            XCTFail("Accepted invalid draft \(amount), opacity \(opacity): \(settings)", file: file, line: line)
        case .failure(let rejection):
            XCTAssertFalse(rejection.message.isEmpty, file: file, line: line)
        }
    }

    func testIntegerNominalEndpointsUsePhysicalUnitsForEveryRole() throws {
        for component in [EngineSession.ColorComponent.u8, .u16] {
            for role in EngineSession.LabAxisRole.allCases {
                let values: [Double] = role == .lightness ? [0, 50, 100] : [-128, 0, 127]
                for value in values {
                    let settings = try LabFillValidation.settings(amount: String(value), opacity: "100",
                        role: role, component: component).get()
                    XCTAssertEqual(settings.value, value)
                    XCTAssertEqual(settings.opacity, 1)
                }
            }
            rejected("-0.01", component: component)
            rejected("100.01", component: component)
            for role in [EngineSession.LabAxisRole.a, .b] {
                rejected("-128.01", role: role, component: component)
                rejected("127.01", role: role, component: component)
            }
        }
    }

    func testAmountsAreNeitherInkPercentNorQuantizedStorageCodes() throws {
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            let lightness = try LabFillValidation.settings(amount: "12.345678901", opacity: "37.5",
                role: .lightness, component: component).get()
            XCTAssertEqual(lightness.value, 12.345678901)
            XCTAssertEqual(lightness.opacity, 0.375)
            let chroma = try LabFillValidation.settings(amount: "-12.345678901", opacity: "0",
                role: .a, component: component).get()
            XCTAssertEqual(chroma.value, -12.345678901)
            XCTAssertEqual(chroma.opacity, 0)
            let neutral = try LabFillValidation.settings(amount: "0", opacity: "100",
                role: .b, component: component).get()
            XCTAssertEqual(neutral.value, 0) // Never encoded to128/32896 or inverted to ink.
        }
    }

    func testFloatAcceptsFiniteExtendedPhysicalValuesWithoutFloatCast() throws {
        let limit = Double(Float.greatestFiniteMagnitude)
        for role in EngineSession.LabAxisRole.allCases {
            for value in [-limit, -160, -5, 110, 160, limit] {
                let settings = try LabFillValidation.settings(amount: String(value), opacity: "100",
                    role: role, component: .float).get()
                XCTAssertEqual(settings.value, value)
            }
        }
        let precise = try LabFillValidation.settings(amount: "1.0000000001", opacity: "100",
            role: .lightness, component: .float).get()
        XCTAssertEqual(precise.value, 1.0000000001)
        XCTAssertNotEqual(precise.value, Double(Float(precise.value)))
        for role in EngineSession.LabAxisRole.allCases {
            rejected(String(limit.nextUp), role: role, component: .float)
            rejected(String(-limit.nextUp), role: role, component: .float)
            rejected("3.5e38", role: role, component: .float)
            rejected("-3.5e38", role: role, component: .float)
        }
    }

    func testStrictDraftsRejectWhitespaceSuffixesNonfiniteAndIncompleteInput() {
        let invalid = ["", " ", " 50", "50 ", "5 0", "50\n", "\t50", "5\u{00a0}0", "50\u{200b}",
                       "50%", "50 L*", "12junk", "1,5", "1_000", ".", "+", "-", "1e", "1e+", "1e-",
                       "--1", "++1", "1.2.3", "0x1p0", "0x10", "NaN", "nan", "+nan", "inf", "-inf",
                       "Infinity", "-Infinity", "1e999", "-1e999", "５０", "−1"]
        for component in [EngineSession.ColorComponent.u8, .u16, .float] {
            for text in invalid {
                rejected(text, component: component)
                rejected("50", opacity: text, component: component)
            }
        }
    }

    func testCompleteDecimalAndScientificDraftsAreAccepted() throws {
        let drafts: [(String, Double)] = [("+50", 50), (".5", 0.5), ("1.", 1),
                                          ("5e1", 50), ("5E+1", 50), ("000.5", 0.5)]
        for (text, value) in drafts {
            let settings = try LabFillValidation.settings(amount: text, opacity: "1e2",
                role: .lightness, component: .u16).get()
            XCTAssertEqual(settings.value, value)
            XCTAssertEqual(settings.opacity, 1)
        }
        let negative = try LabFillValidation.settings(amount: "-1.25e1", opacity: "+.5",
            role: .a, component: .u8).get()
        XCTAssertEqual(negative.value, -12.5)
        XCTAssertEqual(negative.opacity, 0.005)
    }

    func testOpacityRemainsBoundedEvenForExtendedFloatValues() {
        for opacity in ["-0.0001", "100.0001", "101", "1e3", "3.4e38", "-160"] {
            rejected("160", opacity: opacity, role: .b, component: .float)
        }
        // A zero-opacity draft still must contain a valid physical value.
        rejected("nan", opacity: "0", role: .b, component: .float)
        rejected("128", opacity: "0", role: .b, component: .u16)
    }

    func testNegativeZeroAndSmallFiniteValuesAreNotRewritten() throws {
        let zero = try LabFillValidation.settings(amount: "-0.0", opacity: "100",
            role: .a, component: .float).get()
        XCTAssertEqual(zero.value, 0)
        XCTAssertEqual(zero.value.sign, .minus)
        let tiny = try LabFillValidation.settings(amount: "1e-40", opacity: "100",
            role: .lightness, component: .float).get()
        XCTAssertEqual(tiny.value, 1e-40)
        XCTAssertNotEqual(tiny.value, Double(Float(tiny.value)))
    }

    func testUnknownAndUnsupportedPrecisionsRefuseInsteadOfGuessingRanges() {
        for component in [EngineSession.ColorComponent.unknown, .u32, .half, .double] {
            for role in EngineSession.LabAxisRole.allCases {
                rejected("0", role: role, component: component)
            }
        }
    }
}
