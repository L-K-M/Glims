import Foundation

/// Stable tags for View ▸ Tools, its color commands and View ▸ Move Target.
/// Every tool owns an explicit, immutable tag so shortcut ids and menu
/// dispatch never depend on `allCases` order or hashing. The groups derive
/// from `ToolID.paletteSlots`, so the menu mirrors the palette arrangement.
enum ToolMenuCatalog {
    /// The tag of the Swap Colors command. Distinct from every tool tag.
    static let swapColorsTag = 1001
    /// The tag of the Default Colors command. Distinct from every tool tag.
    static let defaultColorsTag = 1002
    static let foregroundColorTag = 1005
    static let backgroundColorTag = 1006

    static func moveTargetTag(for mode: MoveTargetMode) -> Int {
        switch mode {
        case .currentLayer: return 1003
        case .pickLayerOrGuide: return 1004
        }
    }

    static func moveTarget(forTag tag: Int) -> MoveTargetMode? {
        switch tag {
        case 1003: return .currentLayer
        case 1004: return .pickLayerOrGuide
        default: return nil
        }
    }

    /// One palette slot: the tools it offers, in palette order. Single-tool
    /// slots become direct commands; multi-tool slots become one submenu whose
    /// leaves are the slot's tools.
    struct SlotGroup {
        let tools: [ToolID]
        var isMultiChoice: Bool { tools.count > 1 }
    }

    /// The sixteen palette slots, in palette order.
    static let slotGroups: [SlotGroup] = ToolID.paletteSlots.map { SlotGroup(tools: $0) }

    /// The explicit tag owned by each tool. Stable and never derived from
    /// iteration order.
    static func tag(for tool: ToolID) -> Int {
        switch tool {
        case .move: return 1
        case .transform: return 2
        case .crop: return 3
        case .rectangleSelect: return 4
        case .ellipseSelect: return 5
        case .lasso: return 6
        case .magicWand: return 7
        case .selectByColor: return 8
        case .eyedropper: return 9
        case .text: return 10
        case .path: return 11
        case .paintbrush: return 12
        case .pencil: return 13
        case .airbrush: return 14
        case .eraser: return 15
        case .clone: return 16
        case .heal: return 17
        case .smudge: return 18
        case .blur: return 19
        case .sharpen: return 20
        case .dodge: return 21
        case .burn: return 22
        case .gradient: return 23
        case .bucketFill: return 24
        case .hand: return 25
        case .zoom: return 26
        case .spongeDesaturate: return 27
        case .spongeSaturate: return 28
        }
    }

    /// The tool a menu item tag identifies, or nil for a non-tool tag.
    static func tool(forTag tag: Int) -> ToolID? {
        switch tag {
        case 1: return .move
        case 2: return .transform
        case 3: return .crop
        case 4: return .rectangleSelect
        case 5: return .ellipseSelect
        case 6: return .lasso
        case 7: return .magicWand
        case 8: return .selectByColor
        case 9: return .eyedropper
        case 10: return .text
        case 11: return .path
        case 12: return .paintbrush
        case 13: return .pencil
        case 14: return .airbrush
        case 15: return .eraser
        case 16: return .clone
        case 17: return .heal
        case 18: return .smudge
        case 19: return .blur
        case 20: return .sharpen
        case 21: return .dodge
        case 22: return .burn
        case 23: return .gradient
        case 24: return .bucketFill
        case 25: return .hand
        case 26: return .zoom
        case 27: return .spongeDesaturate
        case 28: return .spongeSaturate
        default: return nil
        }
    }
}
